{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionServiceSpec
-- Description : Unit tests for TransactionService orchestration
--
-- Tests the TransactionService layer which orchestrates transaction operations
-- using in-memory event stores. Validates that the service correctly:
--   - Initiates transfers and returns domain types
--   - Queries transactions from the read model
--   - Returns appropriate DomainErrors for invalid operations
module Application.Services.TransactionServiceSpec (spec) where

import Application.ReadModels.TransactionSummary (TransactionSummaryData (..))
import Application.Services.AccountService (createAccount)
import Application.Services.TransactionService
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Domain.Transaction.Commands (InitiateTransfer (..))
import Infrastructure.App (AppEnv, AppM, runAppM)
import RIO
import Test.Hspec
import TestSupport.Helpers (fromRight', mockMoney, mockUserId, shouldBeLeft, shouldBeRight)
import TestSupport.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid1 :: UUID
testUserUuid1 = UUID.fromWords 1 0 0 0

testUserId1 :: UserId
testUserId1 = mockUserId testUserUuid1

mkCreateAccount :: Text -> UserId -> AccountType -> CreateAccount
mkCreateAccount name userId accType =
  CreateAccount
    { createAccountName = name,
      createAccountInitialBalance = mockMoney 5000,
      createAccountCreatedBy = userId,
      createAccountType = accType
    }

-- | Helper to create two accounts and return their IDs for transfer tests.
setupTwoAccounts :: IO (AppEnv, AccountId, AccountId)
setupTwoAccounts = do
  env <- createTestAppEnv
  (fromAccId, toAccId) <- runAppM env $ do
    result1 <- createAccount (mkCreateAccount "Source" testUserId1 RegularAccount)
    let (fromId, _) = fromRight' result1
    result2 <- createAccount (mkCreateAccount "Target" testUserId1 RegularAccount)
    let (toId, _) = fromRight' result2
    return (fromId, toId)
  return (env, fromAccId, toAccId)

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService" $ do
  describe "initiateTransfer" $ do
    it "creates a transfer and returns TransactionId and summary" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts
      let transferCmd =
            InitiateTransfer
              { initiateTransferFromAccountId = fromAccId,
                initiateTransferToAccountId = toAccId,
                initiateTransferAmount = mockMoney 100,
                initiateTransferReason = "Test transfer",
                initiateTransferBy = testUserId1
              }
      result <- runAppM env $ initiateTransfer transferCmd
      shouldBeRight result
      let (_, summary) = fromRight' result
      transactionSummaryDataFromAccountId summary `shouldBe` fromAccId
      transactionSummaryDataToAccountId summary `shouldBe` toAccId
      transactionSummaryDataAmount summary `shouldBe` mockMoney 100
      transactionSummaryDataReason summary `shouldBe` "Test transfer"

  describe "getTransaction" $ do
    it "retrieves a previously created transaction" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts
      let transferCmd =
            InitiateTransfer
              { initiateTransferFromAccountId = fromAccId,
                initiateTransferToAccountId = toAccId,
                initiateTransferAmount = mockMoney 250,
                initiateTransferReason = "Retrieve test",
                initiateTransferBy = testUserId1
              }
      createResult <- runAppM env $ initiateTransfer transferCmd
      let (txId, _) = fromRight' createResult
      result <- runAppM env $ getTransaction (unTransactionId txId)
      shouldBeRight result
      let (retId, summary) = fromRight' result
      retId `shouldBe` txId
      transactionSummaryDataAmount summary `shouldBe` mockMoney 250
      transactionSummaryDataReason summary `shouldBe` "Retrieve test"

    it "returns NotFound for non-existent transaction" $ do
      env <- createTestAppEnv
      let nonExistentUuid = UUID.fromWords 99 99 99 99
      result <- runAppM env $ getTransaction nonExistentUuid
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "initiates multiple transfers and retrieves each" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts
      let mkTransferCmd amt reason =
            InitiateTransfer
              { initiateTransferFromAccountId = fromAccId,
                initiateTransferToAccountId = toAccId,
                initiateTransferAmount = mockMoney amt,
                initiateTransferReason = reason,
                initiateTransferBy = testUserId1
              }
      result1 <- runAppM env $ initiateTransfer (mkTransferCmd 100 "First")
      result2 <- runAppM env $ initiateTransfer (mkTransferCmd 200 "Second")
      let (txId1, _) = fromRight' result1
      let (txId2, _) = fromRight' result2

      getResult1 <- runAppM env $ getTransaction (unTransactionId txId1)
      getResult2 <- runAppM env $ getTransaction (unTransactionId txId2)

      shouldBeRight getResult1
      shouldBeRight getResult2

      let (_, s1) = fromRight' getResult1
      let (_, s2) = fromRight' getResult2
      transactionSummaryDataReason s1 `shouldBe` "First"
      transactionSummaryDataReason s2 `shouldBe` "Second"
