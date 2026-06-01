{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionHistoryServiceSpec
-- Description : Service-layer tests for 'getTransactionHistory'.
--
-- Exercises the audit-history surface end-to-end against the in-memory
-- event store. Amendment-event coverage lives in the integration tests
-- (Task 14) because it requires the TransferAmendmentManager saga to be
-- wired into the test event bus.
module Application.Services.TransactionHistoryServiceSpec (spec) where

import Application.Services.ConfigurationService (seedDefaultConfiguration)
import Application.Services.TransactionHistoryService
  ( TransactionHistory (..),
    TransactionHistoryEntry (..),
    getTransactionHistory,
  )
import Application.Services.TransactionService
  ( initiateIncome,
    setTransactionLabels,
  )
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (TransactionId, unsafeMoney, unsafeTransactionId)
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    incomeAllocs,
    registerUser,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)

-- | A fixed TX id used for the not-found case.
bogusTxId :: TransactionId
bogusTxId = unsafeTransactionId (UUID.fromWords 0xdead 0xbeef 0xdead 0xbeef)

spec :: Spec
spec = describe "TransactionHistoryService.getTransactionHistory" $ do
  it "returns NotFound for a transaction that does not exist" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "audit-notfound@test.com"
    result <- runAppM env (getTransactionHistory fx.userId bogusTxId)
    case result of
      Left (NotFound "Transaction" _) -> pure ()
      Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
      Right _ -> expectationFailure "Expected Left NotFound"

  it "returns history with TransferInitiated and TransferCompleted in order" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "audit-completed@test.com"
    create <-
      runAppM env
        $ initiateIncome
          fx.userId
          fx.regularAccountId
          (unsafeMoney Core.USD 100)
          (incomeAllocs fx (unsafeMoney Core.USD 100))
          Set.empty
          "Audit-base"
          Nothing
    (txId, _) <- case create of
      Right r -> pure r
      Left err -> fail $ "initiateIncome failed: " <> show err

    result <- runAppM env (getTransactionHistory fx.userId txId)
    case result of
      Right (Just hist) -> do
        hist.transactionId `shouldBe` txId
        case hist.entries of
          (HistoryInitiated _ : HistoryCompleted : _) -> pure ()
          other ->
            expectationFailure
              $ "Expected [Initiated, Completed, ...], got entries: "
              <> show other
      Right Nothing -> expectationFailure "Expected Just"
      Left err -> expectationFailure $ "Expected Right, got: " <> show err

  it "includes a TransactionLabelsSet entry after editing labels" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "audit-labels@test.com"
    create <-
      runAppM env
        $ initiateIncome
          fx.userId
          fx.regularAccountId
          (unsafeMoney Core.USD 25)
          (incomeAllocs fx (unsafeMoney Core.USD 25))
          Set.empty
          "With labels"
          Nothing
    (txId, _) <- case create of
      Right r -> pure r
      Left err -> fail $ "initiateIncome failed: " <> show err

    _ <- runAppM env (setTransactionLabels fx.userId txId Set.empty)
    result <- runAppM env (getTransactionHistory fx.userId txId)
    case result of
      Right (Just hist) -> do
        let isLabels HistoryLabelsSet {} = True
            isLabels _ = False
        any isLabels hist.entries `shouldBe` True
      Right Nothing -> expectationFailure "Expected Just"
      Left err -> expectationFailure $ "Expected Right, got: " <> show err

  it "denies access when caller has no role on either account" $ do
    env <- createTestAppEnvWithProcessManager
    runAppM env seedDefaultConfiguration
    owner <- setupMetadataFixture env "audit-owner@test.com"
    stranger <- registerUser env "audit-stranger@test.com"
    create <-
      runAppM env
        $ initiateIncome
          owner.userId
          owner.regularAccountId
          (unsafeMoney Core.USD 10)
          (incomeAllocs owner (unsafeMoney Core.USD 10))
          Set.empty
          "Owner only"
          Nothing
    (txId, _) <- case create of
      Right r -> pure r
      Left err -> fail $ "initiateIncome failed: " <> show err

    result <- runAppM env (getTransactionHistory stranger txId)
    case result of
      Left (AccountError _) -> pure ()
      Left err -> expectationFailure $ "Expected AccountError, got: " <> show err
      Right _ -> expectationFailure "Expected Left AccountError"
