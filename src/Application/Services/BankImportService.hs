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
-- 'BankProvider' and creates 'InitiateTransfer' commands.
--
-- Key Functions:
--   - resync: Fetch statements for a date range and import each transaction
--   - importTransaction: Core import logic for a single bank transaction
--
-- The service handles:
--   - Hold transaction filtering (skipped)
--   - Deduplication via BankImportReadModel
--   - Account mapping via a caller-supplied [(BankAccountId, AccountId)] list
--   - Currency conversion from numeric codes
--   - Transaction classification (income/expense)
--   - MCC→CategoryId resolution from per-user banking configuration
--   - Transfer command creation and delegation to TransactionService
module Application.Services.BankImportService
  ( resync,
    importTransaction,
    ResyncResult (..),
    AccountResyncResult (..),
  )
where

import Application.ReadModels.BankImportReadModel (isImported)
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..))
import qualified Application.ReadModels.User as UserRM
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (ToJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime)
import Domain.Configuration.Defaults (expenseCategoryDictId, incomeCategoryDictId)
import Domain.Configuration.Projection (BankingConfiguration (..))
import Domain.Core.Errors (DomainError (..), renderDomainError)
import Domain.Core.Types
  ( AccountId,
    CategoryId,
    MCC,
    TransactionId,
    TransferType (..),
    UserId,
    currencyFromNumericCode,
    mkMoney,
    unEntryName,
  )
import Domain.Transaction.Commands (InitiateTransfer (..))
import Eventium (EventMetadata (..))
import Infrastructure.App
  ( AppM,
    HasBankImportReadModel (..),
    HasReadModel (..),
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
        ClassifiedIncome -> (incomeCategoryDictId, banking.defaultIncomeCategory)
        ClassifiedExpense -> (expenseCategoryDictId, banking.defaultExpenseCategory)
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
-- Flow:
--   1. Skip hold transactions
--   2. Check deduplication via BankImportReadModel
--   3. Match external account to local account via the supplied mappings
--   4. Look up user's External account from UserReadModel
--   5. Convert currency from numeric code
--   6. Take absolute value of major-unit amount
--   7. Classify transaction (income/expense)
--   8. Resolve category from user's banking configuration
--   9. Create and execute InitiateTransfer command
importTransaction ::
  BankProvider ->
  UserId ->
  [(BankAccountId, AccountId)] ->
  BankTransaction ->
  AppM (Either DomainError (Maybe TransactionId))
importTransaction provider userId accountLink tx = do
  -- 1. Skip hold transactions
  if tx.hold
    then do
      logDebug $ "Skipping hold transaction: " <> display tx.externalId
      pure (Right Nothing)
    else do
      -- 2. Check deduplication
      bankImportRM <- view bankImportReadModelL
      alreadyImported <- isImported bankImportRM tx.externalId
      if alreadyImported
        then do
          logDebug $ "Skipping already-imported transaction: " <> display tx.externalId
          pure (Right Nothing)
        else case lookup tx.accountId accountLink of
          -- 3. Match external account to local account
          Nothing -> do
            logWarn $ "No account mapping for external account: " <> display tx.accountId
            pure (Right Nothing)
          Just localAccId -> do
            -- 4. Look up user's External account
            userRM <- view userReadModelL
            maybeUser <- UserRM.getUser userRM userId
            case maybeUser of
              Nothing -> do
                logWarn $ "User not found: " <> displayShow userId
                pure (Left (NotFound "User" (tshow userId)))
              Just userData -> do
                let externalAccId = userData.externalAccountId
                -- 5. Convert currency
                case currencyFromNumericCode tx.currencyCode of
                  Left err -> do
                    logWarn $ "Unsupported currency code " <> displayShow tx.currencyCode <> ": " <> display err
                    pure (Right Nothing)
                  Right currency ->
                    -- 6 + 7. Amount is already major-unit Rational; take absolute value, build Money
                    case mkMoney currency (abs tx.amount) of
                      Left err -> do
                        logWarn $ "Failed to create money: " <> display err
                        pure (Right Nothing)
                      Right money -> do
                        -- Phase 1: Monobank does not report the foreign currency code, so an
                        -- ExchangeRate refinement (which requires distinct source/target
                        -- currencies) cannot be constructed. Log the raw rate for diagnostic
                        -- visibility; do not persist. See
                        -- docs/specs/2026-04-10-bank-integration-design.md (amendment
                        -- 2026-04-16) for the rationale.
                        logCrossCurrencyRate

                        -- 8. Classify transaction direction
                        let direction = provider.classifyTransaction tx

                        -- 9. Resolve category from user's banking configuration
                        cfgResult <- ConfigurationService.getConfigurationForUser userId
                        case cfgResult of
                          Left err -> do
                            logWarn $ "Failed to load configuration for user " <> displayShow userId <> ": " <> displayShow err
                            pure (Left err)
                          Right cfg -> do
                            let categoryResult = resolveCategory cfg.banking cfg direction tx.mcc
                            case categoryResult of
                              Left err -> do
                                logWarn $ "Category resolution failed for tx " <> display tx.externalId <> ": " <> displayShow err
                                pure (Left err)
                              Right (categoryId, resolution) -> do
                                logCategoryResolution tx direction cfg categoryId resolution
                                let (sourceAccId, targetAccId, transferType) =
                                      classifyEndpoints localAccId externalAccId direction categoryId

                                    -- 10. Create InitiateTransfer command. Phase 1 always sets
                                    -- exchangeRate = Nothing and sourceAmount == targetAmount — see
                                    -- docs/specs/2026-04-10-bank-integration-design.md
                                    -- (amendment 2026-04-16).
                                    cmd = buildTransferCmd sourceAccId targetAccId money transferType

                                    -- 11. Metadata enricher (business timestamp).
                                    -- Note: correlationId not set — external IDs are opaque strings,
                                    -- not UUIDs. Tracing uses externalTransactionId on the event
                                    -- instead.
                                    enricher m = m {occurredAt = Just tx.time}

                                -- 12. Execute transfer
                                result <- TransactionService.initiateTransfer enricher cmd
                                case result of
                                  Left err -> do
                                    logError $ "Failed to import transaction " <> display tx.externalId <> ": " <> displayShow err
                                    pure (Left err)
                                  Right (txId, _) -> do
                                    logInfo $ "Imported transaction " <> display tx.externalId <> " as " <> displayShow txId
                                    pure (Right (Just txId))
  where
    logCrossCurrencyRate = case tx.originalAmount of
      Nothing -> pure () -- same currency
      Just _ | tx.amount == 0 -> pure () -- defensive
      Just origAmt ->
        let rate = abs origAmt / abs tx.amount
         in logInfo
              $ "Cross-currency Mono tx "
              <> display tx.externalId
              <> ": rate="
              <> displayShow rate
              <> " (not persisted in Phase 1)"

    classifyEndpoints localAccId externalAccId direction categoryId =
      case direction of
        ClassifiedExpense ->
          (localAccId, externalAccId, Expense categoryId)
        ClassifiedIncome ->
          (externalAccId, localAccId, Income categoryId)

    buildTransferCmd sourceAccId targetAccId money transferType =
      InitiateTransfer
        { sourceAccountId = sourceAccId,
          targetAccountId = targetAccId,
          sourceAmount = money,
          targetAmount = money,
          exchangeRate = Nothing,
          description = tx.description,
          initiatedBy = userId,
          transferType = transferType,
          externalTransactionId = Just tx.externalId,
          labels = Set.empty
        }
