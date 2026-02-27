{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransferWorkflowSpec
-- Description : Integration tests for complete transfer workflows
--
-- These tests exercise the transfer workflow through the event store,
-- command handlers, projections, and read models using in-memory stores.
--
-- Test Coverage:
--   - Successful transfer: Complete workflow between regular accounts
--   - Transfer from External: Income flow (External -> Regular)
--   - Transfer to External: Expense flow (Regular -> External)
--   - RBAC: Authorization enforcement via AuthorizationService
--   - Balance updates: Verify account balances change after transfer
--   - External account negative balance: External can go negative
--   - Insufficient funds: Regular account rejects oversized debit
--
-- Architecture:
--   1. Create in-memory test environment (no database required)
--   2. Create accounts via event store commands
--   3. Initiate and complete transfers via event store commands
--   4. Verify read model state
--   5. Test authorization via pure AuthorizationService functions
module Integration.TransferWorkflowSpec (spec) where

import Application.ReadModels.AccountSummary
  ( AccountSummaryData (..),
    getAccountSummary,
  )
import Application.ReadModels.TransactionSummary
  ( TransactionSummaryData (..),
    getTransactionSummary,
  )
import Application.Services.AuthorizationService
  ( AccountAuthData (..),
    TransferAuthResult (..),
    TransferDenialReason (..),
    canTransfer,
  )
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (CreateAccountAccountCommand))
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types
  ( AccountAccess (..),
    AccountRole (..),
    AccountType (..),
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand
      ( CompleteTransferTransactionCommand,
        InitiateTransferTransactionCommand
      ),
  )
import Domain.Transaction.Commands (CompleteTransfer (..), InitiateTransfer (..))
import Domain.Transaction.Projection (TransactionStatus (..))
import Infrastructure.App (AppEnv (..))
import Infrastructure.Eventium (applyAccountCommand, applyTransactionCommand)
import RIO
import Test.Hspec
import TestSupport.InMemoryEventStore (createTestAppEnv, createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Test Helpers
-- -----------------------------------------------------------------------------

-- | Create a test environment with two regular accounts.
--
-- Returns the environment, both account UUIDs, and the owner user UUID.
setupRegularAccounts :: IO (AppEnv, UUID, UUID, UUID)
setupRegularAccounts = do
  env <- createTestAppEnv
  let writer = appEventStoreWriter env
      reader = appEventStoreReader env

  userUuid <- UUID.nextRandom
  acctUuid1 <- UUID.nextRandom
  acctUuid2 <- UUID.nextRandom

  -- Create source account with initial balance of 1000
  _ <-
    applyAccountCommand writer reader acctUuid1
      $ CreateAccountAccountCommand
        CreateAccount
          { createAccountName = "Source Account",
            createAccountInitialBalance = unsafeMoney 1000,
            createAccountCreatedBy = unsafeUserId userUuid,
            createAccountType = RegularAccount
          }

  -- Create target account with initial balance of 500
  _ <-
    applyAccountCommand writer reader acctUuid2
      $ CreateAccountAccountCommand
        CreateAccount
          { createAccountName = "Target Account",
            createAccountInitialBalance = unsafeMoney 500,
            createAccountCreatedBy = unsafeUserId userUuid,
            createAccountType = RegularAccount
          }

  return (env, acctUuid1, acctUuid2, userUuid)

-- | Same as setupRegularAccounts but uses a process-manager-enabled env.
setupRegularAccountsWithPM :: IO (AppEnv, UUID, UUID, UUID)
setupRegularAccountsWithPM = do
  env <- createTestAppEnvWithProcessManager
  let writer = appEventStoreWriter env
      reader = appEventStoreReader env

  userUuid <- UUID.nextRandom
  acctUuid1 <- UUID.nextRandom
  acctUuid2 <- UUID.nextRandom

  _ <-
    applyAccountCommand writer reader acctUuid1
      $ CreateAccountAccountCommand
        CreateAccount
          { createAccountName = "Source Account",
            createAccountInitialBalance = unsafeMoney 1000,
            createAccountCreatedBy = unsafeUserId userUuid,
            createAccountType = RegularAccount
          }

  _ <-
    applyAccountCommand writer reader acctUuid2
      $ CreateAccountAccountCommand
        CreateAccount
          { createAccountName = "Target Account",
            createAccountInitialBalance = unsafeMoney 500,
            createAccountCreatedBy = unsafeUserId userUuid,
            createAccountType = RegularAccount
          }

  return (env, acctUuid1, acctUuid2, userUuid)

-- | Initiate and complete a transfer between two accounts.
--
-- Simulates the full transfer workflow by issuing InitiateTransfer
-- followed by CompleteTransfer (mimicking the process manager behavior).
--
-- Returns the transaction UUID.
initiateAndCompleteTransfer ::
  AppEnv ->
  UUID ->
  UUID ->
  UUID ->
  Rational ->
  Text ->
  IO UUID
initiateAndCompleteTransfer env fromUuid toUuid userUuid amount reason = do
  let writer = appEventStoreWriter env
      reader = appEventStoreReader env

  txUuid <- UUID.nextRandom

  -- Step 1: Initiate the transfer
  _ <-
    applyTransactionCommand writer reader txUuid
      $ InitiateTransferTransactionCommand
        InitiateTransfer
          { initiateTransferFromAccountId = unsafeAccountId fromUuid,
            initiateTransferToAccountId = unsafeAccountId toUuid,
            initiateTransferAmount = unsafeMoney amount,
            initiateTransferReason = reason,
            initiateTransferBy = unsafeUserId userUuid
          }

  -- Step 2: Complete the transfer (simulates TransferManager behavior)
  _ <-
    applyTransactionCommand writer reader txUuid
      $ CompleteTransferTransactionCommand CompleteTransfer

  return txUuid

-- | Initiate a transfer only (don't manually complete).
-- Used with the PM-enabled env where the saga auto-completes.
initiateTransferOnly ::
  AppEnv ->
  UUID ->
  UUID ->
  UUID ->
  Rational ->
  Text ->
  IO UUID
initiateTransferOnly env fromUuid toUuid userUuid amount reason = do
  let writer = appEventStoreWriter env
      reader = appEventStoreReader env

  txUuid <- UUID.nextRandom

  _ <-
    applyTransactionCommand writer reader txUuid
      $ InitiateTransferTransactionCommand
        InitiateTransfer
          { initiateTransferFromAccountId = unsafeAccountId fromUuid,
            initiateTransferToAccountId = unsafeAccountId toUuid,
            initiateTransferAmount = unsafeMoney amount,
            initiateTransferReason = reason,
            initiateTransferBy = unsafeUserId userUuid
          }

  return txUuid

-- -----------------------------------------------------------------------------
-- Test Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Transfer Workflow Integration" $ do
  successfulTransferSpec
  incomeFlowSpec
  expenseFlowSpec
  authorizationSpec
  processManagerDrivenSpec

-- -----------------------------------------------------------------------------
-- Successful Transfer
-- -----------------------------------------------------------------------------

successfulTransferSpec :: Spec
successfulTransferSpec =
  describe "Successful Transfer" $ do
    it "completes transfer between regular accounts" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccounts

      -- Initiate and complete transfer of 200
      txUuid <- initiateAndCompleteTransfer env acct1Uuid acct2Uuid userUuid 200 "Test transfer"

      -- Verify transaction in read model
      let txReadModel = appTransactionSummaryReadModel env
      maybeTx <- getTransactionSummary txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found in read model"
        Just txData -> do
          transactionSummaryDataFromAccountId txData `shouldBe` unsafeAccountId acct1Uuid
          transactionSummaryDataToAccountId txData `shouldBe` unsafeAccountId acct2Uuid
          transactionSummaryDataAmount txData `shouldBe` unsafeMoney 200
          transactionSummaryDataStatus txData `shouldBe` Completed

-- -----------------------------------------------------------------------------
-- Income Flow (External -> Regular)
-- -----------------------------------------------------------------------------

incomeFlowSpec :: Spec
incomeFlowSpec =
  describe "Income Flow (External -> Regular)" $ do
    it "allows transfer from external account" $ do
      env <- createTestAppEnv
      let writer = appEventStoreWriter env
          reader = appEventStoreReader env

      userUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom

      -- Create external account (income source)
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { createAccountName = "External",
                createAccountInitialBalance = unsafeMoney 0,
                createAccountCreatedBy = unsafeUserId userUuid,
                createAccountType = ExternalAccount
              }

      -- Create regular account (income destination)
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { createAccountName = "Wallet",
                createAccountInitialBalance = unsafeMoney 0,
                createAccountCreatedBy = unsafeUserId userUuid,
                createAccountType = RegularAccount
              }

      -- Transfer from external to regular (income flow)
      txUuid <- initiateAndCompleteTransfer env extUuid regUuid userUuid 500 "Salary"

      -- Verify transaction completed with correct data
      let txReadModel = appTransactionSummaryReadModel env
      maybeTx <- getTransactionSummary txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Income transaction not found in read model"
        Just txData -> do
          transactionSummaryDataFromAccountId txData `shouldBe` unsafeAccountId extUuid
          transactionSummaryDataToAccountId txData `shouldBe` unsafeAccountId regUuid
          transactionSummaryDataAmount txData `shouldBe` unsafeMoney 500
          transactionSummaryDataReason txData `shouldBe` "Salary"
          transactionSummaryDataStatus txData `shouldBe` Completed

-- -----------------------------------------------------------------------------
-- Expense Flow (Regular -> External)
-- -----------------------------------------------------------------------------

expenseFlowSpec :: Spec
expenseFlowSpec =
  describe "Expense Flow (Regular -> External)" $ do
    it "allows transfer to external account" $ do
      env <- createTestAppEnv
      let writer = appEventStoreWriter env
          reader = appEventStoreReader env

      userUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom

      -- Create regular account (expense source)
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { createAccountName = "Checking",
                createAccountInitialBalance = unsafeMoney 1000,
                createAccountCreatedBy = unsafeUserId userUuid,
                createAccountType = RegularAccount
              }

      -- Create external account (expense destination)
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { createAccountName = "External",
                createAccountInitialBalance = unsafeMoney 0,
                createAccountCreatedBy = unsafeUserId userUuid,
                createAccountType = ExternalAccount
              }

      -- Transfer from regular to external (expense flow)
      txUuid <- initiateAndCompleteTransfer env regUuid extUuid userUuid 300 "Groceries"

      -- Verify transaction completed with correct data
      let txReadModel = appTransactionSummaryReadModel env
      maybeTx <- getTransactionSummary txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Expense transaction not found in read model"
        Just txData -> do
          transactionSummaryDataFromAccountId txData `shouldBe` unsafeAccountId regUuid
          transactionSummaryDataToAccountId txData `shouldBe` unsafeAccountId extUuid
          transactionSummaryDataAmount txData `shouldBe` unsafeMoney 300
          transactionSummaryDataReason txData `shouldBe` "Groceries"
          transactionSummaryDataStatus txData `shouldBe` Completed

-- -----------------------------------------------------------------------------
-- Authorization
-- -----------------------------------------------------------------------------

authorizationSpec :: Spec
authorizationSpec =
  describe "Authorization" $ do
    it "requires Editor+ role on both accounts" $ do
      let userId = unsafeUserId (UUID.fromWords 1 0 0 1)
          otherUser = unsafeUserId (UUID.fromWords 2 0 0 2)
          srcId = unsafeAccountId (UUID.fromWords 3 0 0 3)
          tgtId = unsafeAccountId (UUID.fromWords 4 0 0 4)

      -- Owner on source, Editor on target -> Authorized
      let sourceOwnerData =
            AccountAuthData
              { accountAuthDataCreatedBy = userId,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Owner]
              }
          targetEditorData =
            AccountAuthData
              { accountAuthDataCreatedBy = otherUser,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Editor]
              }
      canTransfer userId sourceOwnerData targetEditorData srcId tgtId
        `shouldBe` TransferAuthorized

      -- Editor on source, Editor on target -> Authorized
      let sourceEditorData =
            AccountAuthData
              { accountAuthDataCreatedBy = otherUser,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Editor]
              }
      canTransfer userId sourceEditorData targetEditorData srcId tgtId
        `shouldBe` TransferAuthorized

      -- Owner on both -> Authorized
      let targetOwnerData =
            AccountAuthData
              { accountAuthDataCreatedBy = userId,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Owner]
              }
      canTransfer userId sourceOwnerData targetOwnerData srcId tgtId
        `shouldBe` TransferAuthorized

    it "rejects unauthorized transfers" $ do
      let userId = unsafeUserId (UUID.fromWords 1 0 0 1)
          otherUser = unsafeUserId (UUID.fromWords 2 0 0 2)
          srcId = unsafeAccountId (UUID.fromWords 3 0 0 3)
          tgtId = unsafeAccountId (UUID.fromWords 4 0 0 4)

      -- Viewer on source -> Denied (InsufficientRoleOnSource)
      let sourceViewerData =
            AccountAuthData
              { accountAuthDataCreatedBy = otherUser,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Viewer]
              }
          targetEditorData =
            AccountAuthData
              { accountAuthDataCreatedBy = otherUser,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Editor]
              }
      canTransfer userId sourceViewerData targetEditorData srcId tgtId
        `shouldBe` TransferDenied (InsufficientRoleOnSource Viewer)

      -- No access to target -> Denied (NoAccessToTarget)
      let sourceOwnerData =
            AccountAuthData
              { accountAuthDataCreatedBy = userId,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = [AccountAccess userId Owner]
              }
          targetNoAccessData =
            AccountAuthData
              { accountAuthDataCreatedBy = otherUser,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = []
              }
      canTransfer userId sourceOwnerData targetNoAccessData srcId tgtId
        `shouldBe` TransferDenied NoAccessToTarget

      -- No access to source -> Denied (NoAccessToSource)
      let sourceNoAccessData =
            AccountAuthData
              { accountAuthDataCreatedBy = otherUser,
                accountAuthDataType = RegularAccount,
                accountAuthDataAccessList = []
              }
      canTransfer userId sourceNoAccessData targetEditorData srcId tgtId
        `shouldBe` TransferDenied NoAccessToSource

      -- Same account -> Denied (SameSourceAndTarget)
      canTransfer userId sourceOwnerData sourceOwnerData srcId srcId
        `shouldBe` TransferDenied SameSourceAndTarget

-- -----------------------------------------------------------------------------
-- Process Manager Driven Tests
-- -----------------------------------------------------------------------------

processManagerDrivenSpec :: Spec
processManagerDrivenSpec =
  describe "Process Manager Driven (full saga)" $ do
    it "auto-completes transfer when only InitiateTransfer is issued" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Only issue InitiateTransfer - the PM should auto-complete
      txUuid <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 200 "PM test transfer"

      -- Verify transaction reached Completed status
      let txReadModel = appTransactionSummaryReadModel env
      maybeTx <- getTransactionSummary txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found in read model after PM processing"
        Just txData -> do
          transactionSummaryDataStatus txData `shouldBe` Completed
          transactionSummaryDataAmount txData `shouldBe` unsafeMoney 200

    it "updates both account balances correctly" $ do
      (env, acct1Uuid, acct2Uuid, _userUuid) <- setupRegularAccountsWithPM

      -- Source: 1000, Target: 500. Transfer 200.
      _ <- initiateTransferOnly env acct1Uuid acct2Uuid _userUuid 200 "Balance test"

      let acctReadModel = appAccountSummaryReadModel env
      -- Source should be 1000 - 200 = 800
      maybeSrc <- getAccountSummary acctReadModel (unsafeAccountId acct1Uuid)
      case maybeSrc of
        Nothing -> expectationFailure "Source account not found in read model"
        Just srcData ->
          accountSummaryDataBalance srcData `shouldBe` unsafeMoney 800

      -- Target should be 500 + 200 = 700
      maybeTgt <- getAccountSummary acctReadModel (unsafeAccountId acct2Uuid)
      case maybeTgt of
        Nothing -> expectationFailure "Target account not found in read model"
        Just tgtData ->
          accountSummaryDataBalance tgtData `shouldBe` unsafeMoney 700

    it "external account can go negative" $ do
      env <- createTestAppEnvWithProcessManager
      let writer = appEventStoreWriter env
          reader = appEventStoreReader env

      userUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom

      -- Create external account with 0 balance
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { createAccountName = "External",
                createAccountInitialBalance = unsafeMoney 0,
                createAccountCreatedBy = unsafeUserId userUuid,
                createAccountType = ExternalAccount
              }

      -- Create regular account
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { createAccountName = "Wallet",
                createAccountInitialBalance = unsafeMoney 0,
                createAccountCreatedBy = unsafeUserId userUuid,
                createAccountType = RegularAccount
              }

      -- Income: External(0) -> Regular(0), amount 500
      -- External should go to -500
      _ <- initiateTransferOnly env extUuid regUuid userUuid 500 "Salary"

      let acctReadModel = appAccountSummaryReadModel env
      maybeExt <- getAccountSummary acctReadModel (unsafeAccountId extUuid)
      case maybeExt of
        Nothing -> expectationFailure "External account not found in read model"
        Just extData ->
          accountSummaryDataBalance extData `shouldBe` unsafeMoney (-500)

      maybeReg <- getAccountSummary acctReadModel (unsafeAccountId regUuid)
      case maybeReg of
        Nothing -> expectationFailure "Regular account not found in read model"
        Just regData ->
          accountSummaryDataBalance regData `shouldBe` unsafeMoney 500

    it "fails transfer when regular account has insufficient funds" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Source has 1000, try to transfer 5000
      txUuid <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 5000 "Too much"

      -- Transaction should be Failed
      let txReadModel = appTransactionSummaryReadModel env
      maybeTx <- getTransactionSummary txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found in read model"
        Just txData ->
          transactionSummaryDataStatus txData `shouldBe` Failed "Insufficient funds"

      -- Balances should be unchanged
      let acctReadModel = appAccountSummaryReadModel env
      maybeSrc <- getAccountSummary acctReadModel (unsafeAccountId acct1Uuid)
      case maybeSrc of
        Nothing -> expectationFailure "Source account not found"
        Just srcData ->
          accountSummaryDataBalance srcData `shouldBe` unsafeMoney 1000

      maybeTgt <- getAccountSummary acctReadModel (unsafeAccountId acct2Uuid)
      case maybeTgt of
        Nothing -> expectationFailure "Target account not found"
        Just tgtData ->
          accountSummaryDataBalance tgtData `shouldBe` unsafeMoney 500

    it "handles multiple sequential transfers correctly" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Source: 1000, Target: 500
      _ <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 100 "Transfer 1"
      _ <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 200 "Transfer 2"
      _ <- initiateTransferOnly env acct2Uuid acct1Uuid userUuid 50 "Transfer back"

      -- Source: 1000 - 100 - 200 + 50 = 750
      -- Target: 500 + 100 + 200 - 50 = 750
      let acctReadModel = appAccountSummaryReadModel env
      maybeSrc <- getAccountSummary acctReadModel (unsafeAccountId acct1Uuid)
      case maybeSrc of
        Nothing -> expectationFailure "Source not found"
        Just srcData ->
          accountSummaryDataBalance srcData `shouldBe` unsafeMoney 750

      maybeTgt <- getAccountSummary acctReadModel (unsafeAccountId acct2Uuid)
      case maybeTgt of
        Nothing -> expectationFailure "Target not found"
        Just tgtData ->
          accountSummaryDataBalance tgtData `shouldBe` unsafeMoney 750
