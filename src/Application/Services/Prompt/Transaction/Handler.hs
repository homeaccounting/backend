{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Transaction.Handler
-- Description : Effectful execution of the @record_transactions@ intent.
--
-- This is the AppM-layer glue between the pure resolver
-- ('Application.Services.Prompt.Transaction.Resolve') and the write path
-- ('Application.Services.TransactionService'). It gathers the user's real
-- accounts, categories, and labels into the contexts the resolver and prompt
-- need ('gatherContext'), then resolves and commits each decoded transaction
-- independently ('runRecordTransactions'), collecting the recorded and failed
-- rows. This layer imports nothing from @Web.*@.
module Application.Services.Prompt.Transaction.Handler
  ( gatherContext,
    runRecordTransactions,
  )
where

import Application.ReadModels.Account (RegularAccountData (..), getUserRegularAccounts)
import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    dictionaryGroupFallbacks,
    dictionaryItemPaths,
  )
import Application.Services.ConfigurationService
  ( getConfigurationForUser,
    labelsDictKind,
  )
import Application.Services.Prompt.Transaction.Intent
  ( PromptContext (..),
    TransactionDecodeError (..),
    TransactionIntent,
  )
import Application.Services.Prompt.Transaction.Resolve
  ( ResolveContext (..),
    Resolved (..),
    resolveIntent,
  )
import Application.Services.Prompt.Types
  ( FailedTransaction (..),
    PromptResult (..),
    RecordedTransaction (..),
    ResolveError (..),
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Map.Strict as Map
import Domain.Configuration.Defaults
  ( expenseCategoryDictKind,
    incomeCategoryDictKind,
  )
import Domain.Configuration.Dictionary (DictionaryKind)
import Domain.Core.Errors (DomainError (..), renderDomainError)
import Domain.Core.Types
  ( AccountId,
    DictionaryEntryId,
    UserId,
  )
import Infrastructure.App (AppM, runDb)
import RIO

-- | Gather the user's real data into the two contexts the intent pipeline needs:
-- the 'PromptContext' (name lists embedded in the prompt) and the
-- 'ResolveContext' (ids + names + defaults the resolver matches against).
--
-- Regular accounts come from the account read model; income/expense categories
-- and labels come from the user's configuration. A missing configuration is a
-- genuine inconsistency and is surfaced as @Left DomainError@.
-- The @selected@ argument is the account the client currently has selected
-- (issue #28), threaded into the 'ResolveContext' so the resolver can prefer it
-- over inference for the primary account slot.
gatherContext :: UserId -> Maybe AccountId -> AppM (Either DomainError (PromptContext, ResolveContext))
gatherContext uid selected = do
  accts <- runDb (getUserRegularAccounts uid)
  getConfigurationForUser uid >>= \case
    Left e -> pure (Left e)
    Right cfg -> pure (Right (buildContexts accts cfg selected))

-- | Assemble the prompt and resolve contexts from the user's accounts and
-- configuration. Pure given the fetched data.
buildContexts ::
  [(AccountId, RegularAccountData)] ->
  ConfigurationData ->
  Maybe AccountId ->
  (PromptContext, ResolveContext)
buildContexts accts cfg selected =
  let entriesOf dictKind = entriesOfDict dictKind cfg
      groupFallbacksOf dictKind =
        maybe [] dictionaryGroupFallbacks (Map.lookup dictKind cfg.dictionaries)
      -- The prompt lists only leaf name-paths, but the resolver ALSO accepts a
      -- bare group name, mapping it to that group's first item — a better guess
      -- than the global default when the model names a group.
      resolveCatsOf dictKind = entriesOf dictKind <> groupFallbacksOf dictKind
      incomeCats = entriesOf incomeCategoryDictKind
      expenseCats = entriesOf expenseCategoryDictKind
      labelEntries = entriesOf labelsDictKind
      pctx =
        PromptContext
          { accountNames = [a.name | (_, a) <- accts],
            incomeCategoryNames = [n | (_, n) <- incomeCats],
            expenseCategoryNames = [n | (_, n) <- expenseCats],
            labelNames = [n | (_, n) <- labelEntries]
          }
      rctx =
        ResolveContext
          { accounts = accts,
            incomeCategories = resolveCatsOf incomeCategoryDictKind,
            expenseCategories = resolveCatsOf expenseCategoryDictKind,
            labels = resolveCatsOf labelsDictKind,
            defaults = cfg.defaults,
            selectedAccount = selected
          }
   in (pctx, rctx)

-- | The dictionary's assignable (item) entries as @(leaf id, group-qualified
-- name-path)@ pairs, empty when absent. The name-path (e.g. @"Food / Groceries"@)
-- gives the LLM the group context it needs to map free text to the right leaf,
-- while the id still points at the assignable leaf.
entriesOfDict ::
  DictionaryKind ->
  ConfigurationData ->
  [(DictionaryEntryId, Text)]
entriesOfDict dictKind cfg =
  maybe [] dictionaryItemPaths (Map.lookup dictKind cfg.dictionaries)

-- | Resolve and commit each decoded transaction independently against the
-- user's data, tagging each with its zero-based position in list order.
--
-- Per element: a resolution failure (naming the offending field) or a
-- write-path 'DomainError' becomes a 'FailedTransaction'; a success becomes a
-- 'RecordedTransaction' carrying the resolver's human-readable interpretation.
-- Both share the transaction's 'index'. Transactions are independent — one
-- failure never blocks the others (no dedup, so no @skipped@). Returns
-- @Right (TransactionsRecorded …)@ even when some transactions failed;
-- @Left DomainError@ is reserved for a whole-request failure (none in the
-- normal per-transaction path). This layer never throws or maps to HTTP.
runRecordTransactions ::
  UserId -> ResolveContext -> Text -> [Either TransactionDecodeError TransactionIntent] -> AppM (Either DomainError PromptResult)
runRecordTransactions uid rctx userText rows = do
  outcomes <- traverse (uncurry runOne) (zip [0 ..] rows)
  pure (Right (TransactionsRecorded {succeeded = rights outcomes, failed = lefts outcomes}))
  where
    runOne :: Int -> Either TransactionDecodeError TransactionIntent -> AppM (Either FailedTransaction RecordedTransaction)
    -- A transaction that failed to decode: report it at its list position
    -- ('index', assigned here by the enumeration), don't block the others.
    runOne idx (Left (TransactionDecodeError msg)) =
      pure (Left (FailedTransaction {index = idx, reason = msg}))
    runOne idx (Right ti) =
      case resolveIntent rctx userText ti of
        Left (ResolveError f m) ->
          pure (Left (FailedTransaction {index = idx, reason = f <> ": " <> m}))
        Right (resolved, interp) -> do
          committed <- dispatch resolved
          case committed of
            Left e -> pure (Left (FailedTransaction {index = idx, reason = renderDomainError e}))
            Right (tid, tdata) ->
              pure (Right (RecordedTransaction {index = idx, interpretation = interp, txId = tid, tx = tdata}))
    dispatch = \case
      ResolvedIncome target total allocs labels desc date ->
        TransactionService.initiateIncome uid target total allocs labels desc date Nothing
      ResolvedExpense source total allocs labels desc date ->
        TransactionService.initiateExpense uid source total allocs labels desc date Nothing
      ResolvedTransfer source dest amount labels desc date ->
        TransactionService.initiateTransfer uid source dest amount labels desc Nothing date Nothing
