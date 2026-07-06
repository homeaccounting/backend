{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Transaction.Handler
-- Description : Effectful execution of the @create_transaction@ intent.
--
-- This is the AppM-layer glue between the pure resolver
-- ('Application.Services.Prompt.Transaction.Resolve') and the write path
-- ('Application.Services.TransactionService'). It gathers the user's real
-- accounts, categories, and labels into the contexts the resolver and prompt
-- need ('gatherContext'), then resolves and commits a decoded intent
-- ('runCreateTransaction'). All failures surface as @Left DomainError@ for the
-- caller (the router) to lift; the Web boundary maps them to the right HTTP
-- status. This layer imports nothing from @Web.*@.
module Application.Services.Prompt.Transaction.Handler
  ( gatherContext,
    runCreateTransaction,
  )
where

import Application.ReadModels.Account (RegularAccountData (..), getUserRegularAccounts)
import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    DictionaryData (..),
  )
import Application.Services.ConfigurationService
  ( getConfigurationForUser,
    labelsDictId,
  )
import Application.Services.Prompt.Transaction.Intent
  ( PromptContext (..),
    TransactionIntent,
  )
import Application.Services.Prompt.Transaction.Resolve
  ( ResolveContext (..),
    Resolved (..),
    resolveIntent,
  )
import Application.Services.Prompt.Types
  ( PromptResult (..),
    ResolveError (..),
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Map.Strict as Map
import Domain.Configuration.Defaults
  ( expenseCategoryDictId,
    incomeCategoryDictId,
  )
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountId,
    DictionaryEntryId,
    DictionaryId,
    EntryName,
    UserId,
    unEntryName,
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
  [RegularAccountData] ->
  ConfigurationData ->
  Maybe AccountId ->
  (PromptContext, ResolveContext)
buildContexts accts cfg selected =
  let entriesOf dictId =
        [ (cid, unEntryName nm)
        | (cid, nm) <- entriesOfDict dictId cfg
        ]
      incomeCats = entriesOf incomeCategoryDictId
      expenseCats = entriesOf expenseCategoryDictId
      labelEntries = entriesOf labelsDictId
      pctx =
        PromptContext
          { accountNames = [a.name | a <- accts],
            incomeCategoryNames = [n | (_, n) <- incomeCats],
            expenseCategoryNames = [n | (_, n) <- expenseCats],
            labelNames = [n | (_, n) <- labelEntries]
          }
      rctx =
        ResolveContext
          { accounts = accts,
            incomeCategories = incomeCats,
            expenseCategories = expenseCats,
            labels = labelEntries,
            defaults = cfg.defaults,
            selectedAccount = selected
          }
   in (pctx, rctx)

-- | Look up a dictionary's entries as an association list, empty when absent.
entriesOfDict ::
  DictionaryId ->
  ConfigurationData ->
  [(DictionaryEntryId, EntryName)]
entriesOfDict dictId cfg =
  maybe [] (Map.toList . (.entries)) (Map.lookup dictId cfg.dictionaries)

-- | Resolve a decoded 'TransactionIntent' against the user's data and commit it.
--
-- A resolution failure becomes a @ValidationErr@ (naming the offending field); a
-- write-path 'DomainError' is returned as-is. On success the committed
-- transaction is returned wrapped in 'TransactionCreated' with the resolver's
-- human-readable interpretation. All failures surface as @Left DomainError@;
-- this layer never throws or maps to HTTP.
runCreateTransaction :: UserId -> ResolveContext -> Text -> TransactionIntent -> AppM (Either DomainError PromptResult)
runCreateTransaction uid rctx userText ti =
  case resolveIntent rctx userText ti of
    Left (ResolveError f m) ->
      pure (Left (ValidationErr (mkValidationError f m userText)))
    Right (resolved, interp) -> do
      committed <- dispatch resolved
      case committed of
        Left e -> pure (Left e)
        Right (tid, tdata) -> pure (Right (TransactionCreated interp tid tdata))
  where
    dispatch = \case
      ResolvedIncome target total allocs labels desc date ->
        TransactionService.initiateIncome uid target total allocs labels desc date Nothing
      ResolvedExpense source total allocs labels desc date ->
        TransactionService.initiateExpense uid source total allocs labels desc date Nothing
      ResolvedTransfer source dest amount labels desc date ->
        TransactionService.initiateTransfer uid source dest amount labels desc Nothing date Nothing
