{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.BankImportService
-- Description : Orchestration service for bank transaction imports
--
-- This module implements the core orchestration logic for importing bank
-- transactions into the accounting system. It processes transactions from a
-- 'BankProvider' and creates 'InitiateTransaction' commands.
--
-- Key Functions:
--   - resync: Fetch statements for a date range and import each transaction
--   - importTransaction: Core import logic for a single bank transaction
--
-- The service handles:
--   - Deduplication via BankImportReadModel
--   - Account mapping via a caller-supplied [(BankAccountId, AccountId)] list
--   - Currency conversion from numeric codes
--   - Transaction classification (income/expense)
--   - MCC→CategoryId resolution from per-user banking configuration
--   - Transfer command creation and delegation to TransactionService
--
-- The 'hold' flag on incoming transactions is intentionally ignored — see
-- 'importTransaction' for details.
module Application.Services.BankImportService
  ( resync,
    importTransaction,
    ResyncResult (..),
    AccountResyncResult (..),
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.BankImportReadModel (isImported)
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import qualified Application.ReadModels.User as UserRM
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Application.Services.TransactionService as TransactionService
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (ToJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime, utctDay)
import Domain.Configuration.Defaults (expenseCategoryDictId, incomeCategoryDictId)
import Domain.Configuration.Projection (BankingConfiguration (..))
import Domain.Core.Errors (DomainError (..), renderDomainError)
import Domain.Core.Types
  ( AccountId,
    CategoryId,
    MCC,
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    currencyFromNumericCode,
    mkAllocation,
    mkExpenseAllocations,
    mkIncomeAllocations,
    mkMoney,
    moneyCurrency,
    unEntryName,
  )
import Domain.Transaction.Commands (InitiateTransaction (..))
import Infrastructure.App
  ( AppM,
    runDb,
    withUserLock,
  )
import Infrastructure.Banking.Provider
  ( BankAccountId,
    BankProvider (..),
    BankTransaction (..),
    TransactionClassification (..),
  )
import RIO

-- -----------------------------------------------------------------------------
-- Result Types
-- -----------------------------------------------------------------------------

-- | Per-account outcome of a resync call.
--
-- Captures both the IDs of successfully imported transactions and the per-tx
-- failures. @failures@ holds human-readable messages (rendered from
-- 'DomainError' via 'renderDomainError', plus any top-level fetch failure).
-- Using 'Text' keeps the type JSON-serializable without dragging 'DomainError'
-- into the response contract.
data AccountResyncResult = AccountResyncResult
  { externalAccountId :: !BankAccountId,
    localAccountId :: !AccountId,
    imported :: ![TransactionId],
    skipped :: !Int,
    failures :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountResyncResult

-- | Aggregated result of a resync call.
--
-- One 'AccountResyncResult' per account in the caller-supplied link, in the
-- same order. Failures in one account do not short-circuit the others.
data ResyncResult = ResyncResult
  { accounts :: ![AccountResyncResult]
  }
  deriving (Show, Eq, Generic)

instance ToJSON ResyncResult

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Fetch statements for a date range and import each transaction.
--
-- For each account mapping supplied by the caller, fetches statements from
-- the provider and imports each transaction individually. Returns a
-- structured per-account breakdown. A fetch failure for one account does not
-- abort processing of the other accounts; per-tx import failures are
-- collected into 'failures' rather than aborting the fetch's remaining
-- transactions.
resync ::
  BankProvider ->
  UserId ->
  [(BankAccountId, AccountId)] ->
  UTCTime ->
  UTCTime ->
  AppM ResyncResult
resync provider userId accountLink fromTime toTime =
  withUserLock userId $ do
    logInfo $ "Resyncing bank transactions for user " <> displayShow userId
    accountResults <- forM accountLink processAccount
    pure (ResyncResult {accounts = accountResults})
  where
    processAccount (extAccId, localAccId) = do
      fetchResult <- liftIO $ provider.fetchStatements extAccId fromTime toTime
      case fetchResult of
        Left err -> fetchFailed extAccId localAccId err
        Right txns -> fetchSucceeded extAccId localAccId txns

    fetchFailed extAccId localAccId err = do
      logWarn
        $ "Failed to fetch statements for account "
        <> display extAccId
        <> ": "
        <> display err
      pure
        AccountResyncResult
          { externalAccountId = extAccId,
            localAccountId = localAccId,
            imported = [],
            skipped = 0,
            failures = [err]
          }

    fetchSucceeded extAccId localAccId txns = do
      logInfo
        $ "Fetched "
        <> displayShow (length txns)
        <> " transactions for account "
        <> display extAccId
      perTx <- forM txns (importTransaction provider userId accountLink)
      let (errs, oks) = partitionEithers perTx
          importedIds = catMaybes oks
          skippedCount = length oks - length importedIds
      pure
        AccountResyncResult
          { externalAccountId = extAccId,
            localAccountId = localAccId,
            imported = importedIds,
            skipped = skippedCount,
            failures = map renderDomainError errs
          }

-- | How the resolver arrived at its 'CategoryId'.
--
-- Exposed alongside the resolved id so the caller can log the provenance
-- (MCC hit vs fallback) without re-deriving it.
data CategoryResolution
  = -- | An MCC present on the transaction matched the user's MCC map.
    MccHit !MCC
  | -- | Fell back to the direction-appropriate default category. Carries
    --   the transaction's MCC (if any) so the caller can spot unmapped
    --   MCCs worth adding to the map.
    DefaultFallback !(Maybe MCC)
  deriving (Show, Eq)

-- | Resolve the category for a transaction from the user's banking configuration.
--
-- Resolution order:
--   1. For expenses: look up tx.mcc in mccExpenseCategoryMap; verify the hit
--      exists in the expense dictionary. Income always skips the MCC map.
--   2. Fall back to the direction-appropriate banking default category.
--   3. If no default is configured, return a 'BankingError'.
resolveCategory ::
  BankingConfiguration ->
  ConfigurationData ->
  TransactionClassification ->
  Maybe MCC ->
  Either DomainError (CategoryId, CategoryResolution)
resolveCategory banking cfg direction maybeMcc =
  let (dictId, deflt) = case direction of
        ClassifiedIncome -> (incomeCategoryDictId, cfg.defaultIncomeCategory)
        ClassifiedExpense -> (expenseCategoryDictId, cfg.defaultExpenseCategory)
      dictEntries =
        maybe Map.empty (.entries) (Map.lookup dictId cfg.dictionaries)
      mccHit = case direction of
        ClassifiedExpense -> maybeMcc >>= \m -> (m,) <$> Map.lookup m banking.mccExpenseCategoryMap
        ClassifiedIncome -> Nothing
      existsInDict eid = Map.member eid dictEntries
   in case mccHit of
        Just (mcc, eid) | existsInDict eid -> Right (eid, MccHit mcc)
        _ -> case deflt of
          Just eid -> Right (eid, DefaultFallback maybeMcc)
          Nothing ->
            Left
              $ BankingError
              $ "No banking "
              <> directionName direction
              <> " category configured"
  where
    directionName ClassifiedIncome = "income"
    directionName ClassifiedExpense = "expense"

-- | Emit a grep-friendly structured log line recording how a bank transaction
--   was categorised: its MCC, the resolution path (MCC hit vs default
--   fallback), the resolved category id and its dictionary name.
--
-- Lets an operator grep for @resolution=DefaultFallback:unmapped-mcc@ to
-- surface MCCs worth adding to the user's map, or for a specific @mcc=…@
-- to audit individual decisions.
logCategoryResolution ::
  BankTransaction ->
  TransactionClassification ->
  ConfigurationData ->
  CategoryId ->
  CategoryResolution ->
  AppM ()
logCategoryResolution tx direction cfg categoryId resolution =
  logInfo
    $ "Category resolved tx="
    <> display tx.externalId
    <> " mcc="
    <> display mccField
    <> " resolution="
    <> display resolutionTag
    <> " category="
    <> display categoryName
    <> " merchant="
    <> display tx.description
  where
    dictId = case direction of
      ClassifiedIncome -> incomeCategoryDictId
      ClassifiedExpense -> expenseCategoryDictId
    categoryName =
      maybe "<unknown>" unEntryName
        $ Map.lookup dictId cfg.dictionaries
        >>= Map.lookup categoryId
        . (.entries)
    resolutionTag :: Text
    resolutionTag = case resolution of
      MccHit _ -> "MccHit"
      DefaultFallback (Just _) -> "DefaultFallback:unmapped-mcc"
      DefaultFallback Nothing -> "DefaultFallback:no-mcc"
    mccField :: Text
    mccField = case resolution of
      MccHit m -> m
      DefaultFallback (Just m) -> m
      DefaultFallback Nothing -> "none"

-- | Core import logic for a single bank transaction.
--
-- The 'hold' flag is deliberately ignored: in April 2026 Monobank stopped
-- transitioning many accounts out of hold, so filtering on it caused recent
-- transactions to never reach the read model. The downside is that an
-- amount adjusted at settlement (tip, FX correction) won't update the
-- imported transfer — users can correct those manually.
--
-- Flow:
--   1. Check deduplication via BankImportReadModel
--   2. Match external account to local account via the supplied mappings
--   3. Look up user's External account from the User read model
--   4. Convert currency from numeric code
--   5. Take absolute value of major-unit amount
--   6. Classify transaction (income/expense)
--   7. Resolve category from user's banking configuration
--   8. Create and execute InitiateTransaction command
importTransaction ::
  BankProvider ->
  UserId ->
  [(BankAccountId, AccountId)] ->
  BankTransaction ->
  AppM (Either DomainError (Maybe TransactionId))
importTransaction provider userId accountLink tx = do
  alreadyImported <- runDb $ isImported tx.externalId
  if alreadyImported
    then do
      logDebug $ "Skipping already-imported transaction: " <> display tx.externalId
      pure (Right Nothing)
    else case lookup tx.accountId accountLink of
      Nothing -> do
        logWarn $ "No account mapping for external account: " <> display tx.accountId
        pure (Right Nothing)
      Just localAccId -> importMatchedTransaction provider userId localAccId tx

-- | Continue an import after the cheap dispatcher checks have matched the
-- external account. Handles the two remaining @Right Nothing@ skip-paths
-- (unsupported currency code, money construction failure) before delegating
-- the genuinely-fallible work to 'commitImport'.
importMatchedTransaction ::
  BankProvider ->
  UserId ->
  AccountId ->
  BankTransaction ->
  AppM (Either DomainError (Maybe TransactionId))
importMatchedTransaction provider userId localAccId tx = do
  maybeUser <- runDb (UserRM.getUser userId)
  case maybeUser of
    Nothing -> do
      logWarn $ "User not found: " <> displayShow userId
      pure (Left (NotFound "User" (tshow userId)))
    Just userData ->
      case currencyFromNumericCode tx.currencyCode of
        Left err -> do
          logWarn $ "Unsupported currency code " <> displayShow tx.currencyCode <> ": " <> display err
          pure (Right Nothing)
        Right currency ->
          case mkMoney currency (abs tx.amount) of
            Left err -> do
              logWarn $ "Failed to create money: " <> display err
              pure (Right Nothing)
            Right money -> runExceptT (commitImport provider userId userData localAccId tx money)

-- | Commit the genuinely-fallible suffix of the import: configuration lookup,
-- category resolution, and transfer initiation. All errors short-circuit via
-- 'ExceptT', so this layer reads as a flat sequence of binds.
commitImport ::
  BankProvider ->
  UserId ->
  UserRM.UserData ->
  AccountId ->
  BankTransaction ->
  Money ->
  ExceptT DomainError AppM (Maybe TransactionId)
commitImport provider userId userData localAccId tx money = do
  let externalAccId = userData.externalAccountId
      direction = provider.classifyTransaction tx
      txCurrency = moneyCurrency money
  -- Guard: a card's transactions can only be imported into a local account of
  -- the SAME currency (a UAH card → a UAH account). Mapping a card to a
  -- different-currency local account is unsupported. Detect it up front and
  -- SKIP the transaction with a clear reason, rather than initiating it and
  -- letting the posting saga fail with a cryptic 'CurrencyMismatch'.
  localData <-
    ExceptT
      $ maybe (Left (NotFound "Account" (tshow localAccId))) Right
      <$> runDb (AccountRM.getAccount localAccId)
  let localCurrency = moneyCurrency localData.balance
  if localCurrency /= txCurrency
    then do
      lift
        $ logWarn
        $ "Skipping bank tx "
        <> display tx.externalId
        <> ": account '"
        <> display localData.name
        <> "' is "
        <> displayShow localCurrency
        <> " but the transaction is "
        <> displayShow txCurrency
        <> ". Map this card to a "
        <> displayShow txCurrency
        <> " account."
      pure Nothing
    else commitMatchingCurrencyImport userId externalAccId localAccId tx money direction

-- | Continue an import once the LOCAL account's currency has been confirmed to
-- match the transaction currency. Handles configuration lookup, category
-- resolution, and transfer initiation. The source/target ACCOUNT currencies may
-- still differ (e.g. local UAH → External USD), which 'resolveAmounts' handles.
commitMatchingCurrencyImport ::
  UserId ->
  AccountId ->
  AccountId ->
  BankTransaction ->
  Money ->
  TransactionClassification ->
  ExceptT DomainError AppM (Maybe TransactionId)
commitMatchingCurrencyImport userId externalAccId localAccId tx money direction = do
  cfg <- ExceptT $ do
    result <- ConfigurationService.getConfigurationForUser userId
    case result of
      Left err -> do
        logWarn $ "Failed to load configuration for user " <> displayShow userId <> ": " <> displayShow err
        pure (Left err)
      Right c -> pure (Right c)
  (categoryId, resolution) <- case resolveCategory cfg.banking cfg direction tx.mcc of
    Left err -> do
      lift $ logWarn $ "Category resolution failed for tx " <> display tx.externalId <> ": " <> displayShow err
      throwE err
    Right ok -> pure ok
  lift $ logCategoryResolution tx direction cfg categoryId resolution
  allocation <- case mkAllocation categoryId money of
    Right a -> pure a
    Left err -> do
      lift $ logWarn $ "Allocation construction failed for tx " <> display tx.externalId <> ": " <> displayShow err
      throwE err
  -- The single resolved allocation goes into the bucket matching the flow
  -- direction: income categories on income, expense categories on expense.
  let allocations = case direction of
        ClassifiedIncome -> mkIncomeAllocations (allocation :| [])
        ClassifiedExpense -> mkExpenseAllocations (allocation :| [])
      (sourceAccId, targetAccId, transactionType) =
        classifyEndpoints localAccId externalAccId direction allocations
  -- Resolve per-leg amounts and the historical exchange rate exactly like the
  -- manual income/expense flow ('TransactionService.resolveAmounts'). The
  -- External account is created in the user's BASE currency, which can differ
  -- from the bank transaction's currency; without this, the External leg would
  -- post an amount in the wrong currency and the posting saga would reject it
  -- with 'CurrencyMismatch'. See 'resolveAmounts' for same-currency handling
  -- (returns the amount unchanged with a 'Nothing' rate) and nearest-date
  -- fallback semantics.
  srcData <-
    ExceptT
      $ maybe (Left (NotFound "Account" (tshow sourceAccId))) Right
      <$> runDb (AccountRM.getAccount sourceAccId)
  tgtData <-
    ExceptT
      $ maybe (Left (NotFound "Account" (tshow targetAccId))) Right
      <$> runDb (AccountRM.getAccount targetAccId)
  let srcCurrency = moneyCurrency srcData.balance
      tgtCurrency = moneyCurrency tgtData.balance
      -- The known bank amount 'money' is in the LOCAL account's currency. For
      -- an expense the local account is the source leg; for an income it is
      -- the target leg.
      userAmountIsSource = direction == ClassifiedExpense
      rateDay = utctDay tx.time
  (srcAmt, tgtAmt, rate) <-
    ExceptT (TransactionService.resolveAmounts money srcCurrency tgtCurrency userAmountIsSource Nothing rateDay)
  let cmd = buildTransferCmd userId tx sourceAccId targetAccId srcAmt tgtAmt rate transactionType
  (txId, _) <- ExceptT (TransactionService.initiateTransaction cmd)
  lift $ logInfo $ "Imported transaction " <> display tx.externalId <> " as " <> displayShow txId
  pure (Just txId)
  where
    classifyEndpoints localAcc externalAcc dir allocs =
      case dir of
        ClassifiedExpense ->
          (localAcc, externalAcc, Expense allocs)
        ClassifiedIncome ->
          (externalAcc, localAcc, Income allocs)

    buildTransferCmd uid bankTx sourceAccId targetAccId srcAmt tgtAmt rate transactionType =
      InitiateTransaction
        { sourceAccountId = sourceAccId,
          targetAccountId = targetAccId,
          sourceAmount = srcAmt,
          targetAmount = tgtAmt,
          exchangeRate = rate,
          description = bankTx.description,
          initiatedBy = uid,
          at = bankTx.time,
          transactionType = transactionType,
          externalTransactionId = Just bankTx.externalId,
          labels = Set.empty
        }
