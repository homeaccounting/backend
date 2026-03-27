{-# LANGUAGE OverloadedRecordDot #-}
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

import Application.ReadModels.Account
  ( AccountData (..),
    getAccount,
  )
import Application.ReadModels.Transaction
  ( TransactionData (..),
    getTransaction,
  )
import Application.Services.AuthorizationService
  ( AccountAuthData (..),
    TransferAuthResult (..),
    TransferDenialReason (..),
    canTransfer,
  )
import Data.Either (isLeft)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (CreateAccountAccountCommand))
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types
  ( AccountAccess (..),
    AccountRole (..),
    AccountType (..),
    Currency (..),
    ExpenseCategory (..),
    IncomeCategory (..),
    InternalCategory (..),
    TransferCategory (..),
    TransferType (..),
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
import Testkit.InMemoryEventStore (createTestAppEnv, createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Test Helpers
-- -----------------------------------------------------------------------------

-- | Create a test environment with two regular accounts.
--
-- Returns the environment, both account UUIDs, and the owner user UUID.
setupRegularAccounts :: IO (AppEnv, UUID, UUID, UUID)
setupRegularAccounts = do
  env <- createTestAppEnv
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader

  userUuid <- UUID.nextRandom
  acctUuid1 <- UUID.nextRandom
  acctUuid2 <- UUID.nextRandom

  -- Create source account with initial balance of 1000
  _ <-
    applyAccountCommand writer reader acctUuid1
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "Source Account",
            initialBalance = unsafeMoney USD 1000,
            createdBy = unsafeUserId userUuid,
            accountType = RegularAccount,
            overdraftLimit = Nothing
          }

  -- Create target account with initial balance of 500
  _ <-
    applyAccountCommand writer reader acctUuid2
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "Target Account",
            initialBalance = unsafeMoney USD 500,
            createdBy = unsafeUserId userUuid,
            accountType = RegularAccount,
            overdraftLimit = Nothing
          }

  return (env, acctUuid1, acctUuid2, userUuid)

-- | Same as setupRegularAccounts but uses a process-manager-enabled env.
setupRegularAccountsWithPM :: IO (AppEnv, UUID, UUID, UUID)
setupRegularAccountsWithPM = do
  env <- createTestAppEnvWithProcessManager
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader

  userUuid <- UUID.nextRandom
  acctUuid1 <- UUID.nextRandom
  acctUuid2 <- UUID.nextRandom

  _ <-
    applyAccountCommand writer reader acctUuid1
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "Source Account",
            initialBalance = unsafeMoney USD 1000,
            createdBy = unsafeUserId userUuid,
            accountType = RegularAccount,
            overdraftLimit = Nothing
          }

  _ <-
    applyAccountCommand writer reader acctUuid2
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "Target Account",
            initialBalance = unsafeMoney USD 500,
            createdBy = unsafeUserId userUuid,
            accountType = RegularAccount,
            overdraftLimit = Nothing
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
initiateAndCompleteTransfer env fromUuid toUuid userUuid amt rsn = do
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader

  txUuid <- UUID.nextRandom

  -- Step 1: Initiate the transfer
  _ <-
    applyTransactionCommand writer reader txUuid
      $ InitiateTransferTransactionCommand
        InitiateTransfer
          { fromAccountId = unsafeAccountId fromUuid,
            toAccountId = unsafeAccountId toUuid,
            sourceAmount = unsafeMoney USD amt,
            targetAmount = unsafeMoney USD amt,
            exchangeRate = Nothing,
            reason = rsn,
            initiatedBy = unsafeUserId userUuid,
            transferType = InternalTransfer,
            category = InternalCat InternalOther
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
initiateTransferOnly env fromUuid toUuid userUuid amt rsn = do
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader

  txUuid <- UUID.nextRandom

  _ <-
    applyTransactionCommand writer reader txUuid
      $ InitiateTransferTransactionCommand
        InitiateTransfer
          { fromAccountId = unsafeAccountId fromUuid,
            toAccountId = unsafeAccountId toUuid,
            sourceAmount = unsafeMoney USD amt,
            targetAmount = unsafeMoney USD amt,
            exchangeRate = Nothing,
            reason = rsn,
            initiatedBy = unsafeUserId userUuid,
            transferType = InternalTransfer,
            category = InternalCat InternalOther
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
  categorizedTransferSpec

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
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found in read model"
        Just txData -> do
          txData.fromAccountId `shouldBe` unsafeAccountId acct1Uuid
          txData.toAccountId `shouldBe` unsafeAccountId acct2Uuid
          txData.sourceAmount `shouldBe` unsafeMoney USD 200
          txData.status `shouldBe` Completed

-- -----------------------------------------------------------------------------
-- Income Flow (External -> Regular)
-- -----------------------------------------------------------------------------

incomeFlowSpec :: Spec
incomeFlowSpec =
  describe "Income Flow (External -> Regular)" $ do
    it "allows transfer from external account" $ do
      env <- createTestAppEnv
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader

      userUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom

      -- Create external account (income source)
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "External",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = ExternalAccount,
                overdraftLimit = Nothing
              }

      -- Create regular account (income destination)
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "Wallet",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount,
                overdraftLimit = Nothing
              }

      -- Transfer from external to regular (income flow)
      txUuid <- initiateAndCompleteTransfer env extUuid regUuid userUuid 500 "Salary"

      -- Verify transaction completed with correct data
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Income transaction not found in read model"
        Just txData -> do
          txData.fromAccountId `shouldBe` unsafeAccountId extUuid
          txData.toAccountId `shouldBe` unsafeAccountId regUuid
          txData.sourceAmount `shouldBe` unsafeMoney USD 500
          txData.reason `shouldBe` "Salary"
          txData.status `shouldBe` Completed

-- -----------------------------------------------------------------------------
-- Expense Flow (Regular -> External)
-- -----------------------------------------------------------------------------

expenseFlowSpec :: Spec
expenseFlowSpec =
  describe "Expense Flow (Regular -> External)" $ do
    it "allows transfer to external account" $ do
      env <- createTestAppEnv
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader

      userUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom

      -- Create regular account (expense source)
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "Checking",
                initialBalance = unsafeMoney USD 1000,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount,
                overdraftLimit = Nothing
              }

      -- Create external account (expense destination)
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "External",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = ExternalAccount,
                overdraftLimit = Nothing
              }

      -- Transfer from regular to external (expense flow)
      txUuid <- initiateAndCompleteTransfer env regUuid extUuid userUuid 300 "Groceries"

      -- Verify transaction completed with correct data
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Expense transaction not found in read model"
        Just txData -> do
          txData.fromAccountId `shouldBe` unsafeAccountId regUuid
          txData.toAccountId `shouldBe` unsafeAccountId extUuid
          txData.sourceAmount `shouldBe` unsafeMoney USD 300
          txData.reason `shouldBe` "Groceries"
          txData.status `shouldBe` Completed

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
              { createdBy = userId,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Owner]
              }
          targetEditorData =
            AccountAuthData
              { createdBy = otherUser,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Editor]
              }
      canTransfer userId sourceOwnerData targetEditorData srcId tgtId
        `shouldBe` TransferAuthorized

      -- Editor on source, Editor on target -> Authorized
      let sourceEditorData =
            AccountAuthData
              { createdBy = otherUser,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Editor]
              }
      canTransfer userId sourceEditorData targetEditorData srcId tgtId
        `shouldBe` TransferAuthorized

      -- Owner on both -> Authorized
      let targetOwnerData =
            AccountAuthData
              { createdBy = userId,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Owner]
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
              { createdBy = otherUser,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Viewer]
              }
          targetEditorData =
            AccountAuthData
              { createdBy = otherUser,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Editor]
              }
      canTransfer userId sourceViewerData targetEditorData srcId tgtId
        `shouldBe` TransferDenied (InsufficientRoleOnSource Viewer)

      -- No access to target -> Denied (NoAccessToTarget)
      let sourceOwnerData =
            AccountAuthData
              { createdBy = userId,
                accountType = RegularAccount,
                accessList = [AccountAccess userId Owner]
              }
          targetNoAccessData =
            AccountAuthData
              { createdBy = otherUser,
                accountType = RegularAccount,
                accessList = []
              }
      canTransfer userId sourceOwnerData targetNoAccessData srcId tgtId
        `shouldBe` TransferDenied NoAccessToTarget

      -- No access to source -> Denied (NoAccessToSource)
      let sourceNoAccessData =
            AccountAuthData
              { createdBy = otherUser,
                accountType = RegularAccount,
                accessList = []
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
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found in read model after PM processing"
        Just txData -> do
          txData.status `shouldBe` Completed
          txData.sourceAmount `shouldBe` unsafeMoney USD 200

    it "updates both account balances correctly" $ do
      (env, acct1Uuid, acct2Uuid, _userUuid) <- setupRegularAccountsWithPM

      -- Source: 1000, Target: 500. Transfer 200.
      _ <- initiateTransferOnly env acct1Uuid acct2Uuid _userUuid 200 "Balance test"

      let acctReadModel = env.accountReadModel
      -- Source should be 1000 - 200 = 800
      maybeSrc <- getAccount acctReadModel (unsafeAccountId acct1Uuid)
      case maybeSrc of
        Nothing -> expectationFailure "Source account not found in read model"
        Just srcData ->
          srcData.balance `shouldBe` unsafeMoney USD 800

      -- Target should be 500 + 200 = 700
      maybeTgt <- getAccount acctReadModel (unsafeAccountId acct2Uuid)
      case maybeTgt of
        Nothing -> expectationFailure "Target account not found in read model"
        Just tgtData ->
          tgtData.balance `shouldBe` unsafeMoney USD 700

    it "external account can go negative" $ do
      env <- createTestAppEnvWithProcessManager
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader

      userUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom

      -- Create external account with 0 balance
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "External",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = ExternalAccount,
                overdraftLimit = Nothing
              }

      -- Create regular account
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "Wallet",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount,
                overdraftLimit = Nothing
              }

      -- Income: External(0) -> Regular(0), amount 500
      -- External should go to -500
      _ <- initiateTransferOnly env extUuid regUuid userUuid 500 "Salary"

      let acctReadModel = env.accountReadModel
      maybeExt <- getAccount acctReadModel (unsafeAccountId extUuid)
      case maybeExt of
        Nothing -> expectationFailure "External account not found in read model"
        Just extData ->
          extData.balance `shouldBe` unsafeMoney USD (-500)

      maybeReg <- getAccount acctReadModel (unsafeAccountId regUuid)
      case maybeReg of
        Nothing -> expectationFailure "Regular account not found in read model"
        Just regData ->
          regData.balance `shouldBe` unsafeMoney USD 500

    it "rejects transfer exceeding balance for regular account (default overdraft 0)" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Source has 1000, transfer 5000 — rejected because Regular accounts default to Just 0 overdraft
      txUuid <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 5000 "Overdraft"

      -- Transaction should be Failed (insufficient funds)
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found in read model"
        Just txData ->
          txData.status `shouldBe` Failed "Insufficient funds"

      -- Balances should remain unchanged
      let acctReadModel = env.accountReadModel
      maybeSrc <- getAccount acctReadModel (unsafeAccountId acct1Uuid)
      case maybeSrc of
        Nothing -> expectationFailure "Source account not found"
        Just srcData ->
          srcData.balance `shouldBe` unsafeMoney USD 1000

      maybeTgt <- getAccount acctReadModel (unsafeAccountId acct2Uuid)
      case maybeTgt of
        Nothing -> expectationFailure "Target account not found"
        Just tgtData ->
          tgtData.balance `shouldBe` unsafeMoney USD 500

    it "handles multiple sequential transfers correctly" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Source: 1000, Target: 500
      _ <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 100 "Transfer 1"
      _ <- initiateTransferOnly env acct1Uuid acct2Uuid userUuid 200 "Transfer 2"
      _ <- initiateTransferOnly env acct2Uuid acct1Uuid userUuid 50 "Transfer back"

      -- Source: 1000 - 100 - 200 + 50 = 750
      -- Target: 500 + 100 + 200 - 50 = 750
      let acctReadModel = env.accountReadModel
      maybeSrc <- getAccount acctReadModel (unsafeAccountId acct1Uuid)
      case maybeSrc of
        Nothing -> expectationFailure "Source not found"
        Just srcData ->
          srcData.balance `shouldBe` unsafeMoney USD 750

      maybeTgt <- getAccount acctReadModel (unsafeAccountId acct2Uuid)
      case maybeTgt of
        Nothing -> expectationFailure "Target not found"
        Just tgtData ->
          tgtData.balance `shouldBe` unsafeMoney USD 750

-- -----------------------------------------------------------------------------
-- Categorized Transfer Tests (Income, Expense, Internal with categories)
-- -----------------------------------------------------------------------------

categorizedTransferSpec :: Spec
categorizedTransferSpec =
  describe "Categorized Transfers (type + category)" $ do
    it "income flow with Salary category completes correctly" $ do
      env <- createTestAppEnvWithProcessManager
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader

      userUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom

      -- Create external account (income source)
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "External",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = ExternalAccount,
                overdraftLimit = Nothing
              }

      -- Create regular account (income destination)
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "Wallet",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount,
                overdraftLimit = Nothing
              }

      -- Initiate income transfer with Income type and Salary category
      txUuid <- UUID.nextRandom
      _ <-
        applyTransactionCommand writer reader txUuid
          $ InitiateTransferTransactionCommand
            InitiateTransfer
              { fromAccountId = unsafeAccountId extUuid,
                toAccountId = unsafeAccountId regUuid,
                sourceAmount = unsafeMoney USD 3000,
                targetAmount = unsafeMoney USD 3000,
                exchangeRate = Nothing,
                reason = "Monthly salary",
                initiatedBy = unsafeUserId userUuid,
                transferType = Income,
                category = IncomeCat Salary
              }

      -- Verify transaction read model has correct type and category
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Income transaction not found in read model"
        Just txData -> do
          txData.transferType `shouldBe` Income
          txData.category `shouldBe` IncomeCat Salary
          txData.status `shouldBe` Completed

      -- Verify account balances
      let acctReadModel = env.accountReadModel
      maybeExt <- getAccount acctReadModel (unsafeAccountId extUuid)
      case maybeExt of
        Nothing -> expectationFailure "External account not found"
        Just extData ->
          extData.balance `shouldBe` unsafeMoney USD (-3000)

      maybeReg <- getAccount acctReadModel (unsafeAccountId regUuid)
      case maybeReg of
        Nothing -> expectationFailure "Regular account not found"
        Just regData ->
          regData.balance `shouldBe` unsafeMoney USD 3000

    it "expense flow with Food category completes correctly" $ do
      env <- createTestAppEnvWithProcessManager
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader

      userUuid <- UUID.nextRandom
      regUuid <- UUID.nextRandom
      extUuid <- UUID.nextRandom

      -- Create regular account (expense source) with balance
      _ <-
        applyAccountCommand writer reader regUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "Checking",
                initialBalance = unsafeMoney USD 5000,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount,
                overdraftLimit = Nothing
              }

      -- Create external account (expense destination)
      _ <-
        applyAccountCommand writer reader extUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "External",
                initialBalance = unsafeMoney USD 0,
                createdBy = unsafeUserId userUuid,
                accountType = ExternalAccount,
                overdraftLimit = Nothing
              }

      -- Initiate expense transfer with Expense type and Food category
      txUuid <- UUID.nextRandom
      _ <-
        applyTransactionCommand writer reader txUuid
          $ InitiateTransferTransactionCommand
            InitiateTransfer
              { fromAccountId = unsafeAccountId regUuid,
                toAccountId = unsafeAccountId extUuid,
                sourceAmount = unsafeMoney USD 150,
                targetAmount = unsafeMoney USD 150,
                exchangeRate = Nothing,
                reason = "Grocery shopping",
                initiatedBy = unsafeUserId userUuid,
                transferType = Expense,
                category = ExpenseCat Food
              }

      -- Verify transaction read model has correct type and category
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Expense transaction not found in read model"
        Just txData -> do
          txData.transferType `shouldBe` Expense
          txData.category `shouldBe` ExpenseCat Food
          txData.status `shouldBe` Completed

      -- Verify account balances
      let acctReadModel = env.accountReadModel
      maybeReg <- getAccount acctReadModel (unsafeAccountId regUuid)
      case maybeReg of
        Nothing -> expectationFailure "Regular account not found"
        Just regData ->
          regData.balance `shouldBe` unsafeMoney USD 4850

      maybeExt <- getAccount acctReadModel (unsafeAccountId extUuid)
      case maybeExt of
        Nothing -> expectationFailure "External account not found"
        Just extData ->
          extData.balance `shouldBe` unsafeMoney USD 150

    it "internal transfer with Savings category completes correctly" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Initiate internal transfer with Savings category
      txUuid <- UUID.nextRandom
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader
      _ <-
        applyTransactionCommand writer reader txUuid
          $ InitiateTransferTransactionCommand
            InitiateTransfer
              { fromAccountId = unsafeAccountId acct1Uuid,
                toAccountId = unsafeAccountId acct2Uuid,
                sourceAmount = unsafeMoney USD 300,
                targetAmount = unsafeMoney USD 300,
                exchangeRate = Nothing,
                reason = "Move to savings",
                initiatedBy = unsafeUserId userUuid,
                transferType = InternalTransfer,
                category = InternalCat Savings
              }

      -- Verify transaction read model has correct type and category
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Internal transfer not found in read model"
        Just txData -> do
          txData.transferType `shouldBe` InternalTransfer
          txData.category `shouldBe` InternalCat Savings
          txData.status `shouldBe` Completed

    it "rejects transfer with mismatched type and category" $ do
      (env, acct1Uuid, acct2Uuid, userUuid) <- setupRegularAccountsWithPM

      -- Attempt Income type with ExpenseCat Food (mismatch)
      txUuid <- UUID.nextRandom
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader
      result <-
        applyTransactionCommand writer reader txUuid
          $ InitiateTransferTransactionCommand
            InitiateTransfer
              { fromAccountId = unsafeAccountId acct1Uuid,
                toAccountId = unsafeAccountId acct2Uuid,
                sourceAmount = unsafeMoney USD 100,
                targetAmount = unsafeMoney USD 100,
                exchangeRate = Nothing,
                reason = "Mismatched category",
                initiatedBy = unsafeUserId userUuid,
                transferType = Income,
                category = ExpenseCat Food
              }

      -- Should be rejected
      result `shouldSatisfy` isLeft

      -- Transaction should not exist in read model
      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      maybeTx `shouldBe` Nothing
