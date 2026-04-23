{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
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
--   - Transfer command creation and delegation to TransactionService
module Application.Services.BankImportService
  ( resync,
    importTransaction,
    ResyncResult (..),
    AccountResyncResult (..),
  )
where

import Application.ReadModels.BankImportReadModel (isImported)
import qualified Application.ReadModels.User as UserRM
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (ToJSON)
import qualified Data.Set as Set
import Data.Time (UTCTime)
import Domain.Core.Errors (DomainError (..), renderDomainError)
import Domain.Core.Types
  ( AccountId,
    CategoryId,
    TransactionId,
    TransferType (..),
    UserId,
    currencyFromNumericCode,
    mkMoney,
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
  CategoryId ->
  UTCTime ->
  UTCTime ->
  AppM ResyncResult
resync provider userId link defaultCategory fromTime toTime =
  withUserLock userId $ do
    logInfo $ "Resyncing bank transactions for user " <> displayShow userId
    accountResults <- forM link processAccount
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
      perTx <- forM txns (importTransaction provider userId link defaultCategory)
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
--   8. Create and execute InitiateTransfer command
importTransaction ::
  BankProvider ->
  UserId ->
  [(BankAccountId, AccountId)] ->
  CategoryId ->
  BankTransaction ->
  AppM (Either DomainError (Maybe TransactionId))
importTransaction provider userId link defaultCategory tx = do
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
        else case lookup tx.accountId link of
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

                        -- 8. Classify transaction
                        let (sourceAccId, targetAccId, transferType) =
                              classifyEndpoints localAccId externalAccId

                            -- 9. Create InitiateTransfer command. Phase 1 always sets
                            -- exchangeRate = Nothing and sourceAmount == targetAmount — see
                            -- docs/specs/2026-04-10-bank-integration-design.md
                            -- (amendment 2026-04-16).
                            cmd = buildTransferCmd sourceAccId targetAccId money transferType

                            -- 10. Metadata enricher (business timestamp).
                            -- Note: correlationId not set — external IDs are opaque strings,
                            -- not UUIDs. Tracing uses externalTransactionId on the event
                            -- instead.
                            enricher m = m {occurredAt = Just tx.time}

                        -- 11. Execute transfer
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

    classifyEndpoints localAccId externalAccId =
      case provider.classifyTransaction tx of
        ClassifiedExpense maybeCat ->
          (localAccId, externalAccId, Expense (fromMaybe defaultCategory maybeCat))
        ClassifiedIncome maybeCat ->
          (externalAccId, localAccId, Income (fromMaybe defaultCategory maybeCat))

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
