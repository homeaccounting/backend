{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.BankImportServiceSpec
-- Description : Tests for BankImportService orchestration
--
-- Tests the BankImportService layer which orchestrates bank transaction
-- import operations using in-memory event stores. Validates that the service
-- correctly:
--   - Skips hold transactions
--   - Deduplicates already-imported transactions
--   - Skips transactions with unmatched accounts
--   - Creates transfers with correct fields for successful imports
module Application.Services.BankImportServiceSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.ReadModels.User (UserData (..), UserReadModel (..))
import Application.Services.AccountService (createAccount)
import Application.Services.BankImportService (importTransaction)
import qualified Control.Concurrent.STM as STM
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    DictionaryEntryId,
    TransferType (..),
    UserId,
    defaultBankAccount,
    defaultConfigurationId,
    mkMoney,
    unsafeExternalTransactionId,
  )
import Infrastructure.App (AppEnv (..), HasReadModel (..), runAppM)
import Infrastructure.Banking.Provider
  ( BankAccountId,
    BankProvider (..),
    BankTransaction (..),
    TransactionClassification (..),
  )
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers
  ( fromRight',
    mockAccountId,
    mockDictionaryEntryId,
    mockMoneyWith,
    mockUserId,
    shouldBeRight,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid :: UUID
testUserUuid = UUID.fromWords 1 0 0 0

testUserId :: UserId
testUserId = mockUserId testUserUuid

testBankAccountUuid :: UUID
testBankAccountUuid = UUID.fromWords 3 0 0 0

testDefaultCategoryUuid :: UUID
testDefaultCategoryUuid = UUID.fromWords 4 0 0 0

testDefaultCategory :: DictionaryEntryId
testDefaultCategory = mockDictionaryEntryId testDefaultCategoryUuid

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 4 14) (secondsToDiffTime 43200)

-- | A mock bank provider that classifies based on amount sign.
mockProvider :: BankProvider
mockProvider =
  BankProvider
    { providerName = "mock",
      fetchAccounts = return $ Right [],
      fetchStatements = \_ _ _ -> return $ Right [],
      registerWebhook = \_ -> return $ Right (),
      classifyTransaction = \tx ->
        if tx.amount >= 0
          then ClassifiedIncome Nothing
          else ClassifiedExpense Nothing
    }

-- | Create a bank transaction for testing. Amount is in major units.
mkTestTransaction :: Rational -> Text -> BankTransaction
mkTestTransaction = mkTestTransactionWithAccount' "mono-acc-1"

-- | Create a bank transaction with a specific account ID for testing.
mkTestTransactionWithAccount :: Rational -> Text -> Text -> BankTransaction
mkTestTransactionWithAccount amount extId acctId = mkTestTransactionWithAccount' acctId amount extId

mkTestTransactionWithAccount' :: Text -> Rational -> Text -> BankTransaction
mkTestTransactionWithAccount' acctId amount extId =
  BankTransaction
    { externalId = unsafeExternalTransactionId extId,
      accountId = acctId,
      time = testTime,
      amount = amount,
      currencyCode = 980, -- UAH
      description = "Test transaction",
      hold = False,
      mcc = Nothing,
      originalAmount = Nothing,
      notes = Nothing,
      categoryHint = Nothing
    }

-- | Create a hold bank transaction for testing. Amount is in major units.
mkHoldTransaction :: Rational -> Text -> BankTransaction
mkHoldTransaction amount extId =
  BankTransaction
    { externalId = unsafeExternalTransactionId extId,
      accountId = "mono-acc-1",
      time = testTime,
      amount = amount,
      currencyCode = 980,
      description = "Hold transaction",
      hold = True,
      mcc = Nothing,
      originalAmount = Nothing,
      notes = Nothing,
      categoryHint = Nothing
    }

-- -----------------------------------------------------------------------------
-- Test Setup
-- -----------------------------------------------------------------------------

-- | Set up a test environment with:
--   - A user in the UserReadModel
--   - A bank account
--   - An External account
-- Returns (env, bankAccountId).
setupTestEnv :: IO (AppEnv, AccountId)
setupTestEnv = do
  env <- createTestAppEnvWithProcessManager

  -- Create accounts: External account (for the user) and a bank account
  (externalAccId, bankAccId) <- runAppM env $ do
    -- Create external account
    extResult <-
      createAccount
        CreateAccount
          { name = "External",
            initialBalance = mockMoneyWith UAH 0,
            createdBy = testUserId,
            accountType = External,
            overdraftLimit = Nothing
          }
    let (extId, _) = fromRight' extResult

    -- Create bank account. Give it a generous overdraft so the imported
    -- transfers clear: bank imports debit the BankAccount from a zero
    -- initial balance; without room to overdraw, every expense saga would
    -- emit TransferFailed, which the dedup read model now evicts (so the
    -- same tx could be re-imported). The overdraft keeps the test focused
    -- on dedup semantics rather than balance accounting.
    bankResult <-
      createAccount
        CreateAccount
          { name = "Monobank UAH",
            initialBalance = mockMoneyWith UAH 0,
            createdBy = testUserId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = Just (Just (mockMoneyWith UAH 1000000))
          }
    let (bankId, _) = fromRight' bankResult
    return (extId, bankId)

  -- Populate UserReadModel with test user data
  let userData =
        UserData
          { email = Just "test@example.com",
            hasPassword = True,
            oauthIdentities = [],
            telegramIdentity = Nothing,
            externalAccountId = externalAccId,
            configurationId = defaultConfigurationId,
            version = 1
          }
  STM.atomically
    $ STM.writeTVar env.userReadModel
    $ UserReadModel
      { latestSequence = 0,
        summaryData = Map.singleton testUserId userData,
        emailIndex = Map.singleton "test@example.com" testUserId,
        telegramIndex = Map.empty,
        oauthIndex = Map.empty
      }

  return (env, bankAccId)

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "BankImportService" $ do
  describe "importTransaction" $ do
    it "skips hold transactions" $ do
      (env, _bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", mockAccountId testBankAccountUuid)]
      let holdTx = mkHoldTransaction (-50) "tx-hold"
      result <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory holdTx
      result `shouldBe` Right Nothing

    it "skips already-imported transactions (dedup)" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]

      -- First import should succeed
      let tx = mkTestTransaction (-50) "tx-dedup-1"
      result1 <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory tx
      shouldBeRight result1
      case result1 of
        Right (Just _) -> pure ()
        _ -> expectationFailure "expected successful import"

      -- Second import of the same transaction should be skipped
      result2 <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory tx
      result2 `shouldBe` Right Nothing

    it "skips transactions with unmatched account" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- Transaction with a different account ID that has no mapping
      let unmatchedTx = mkTestTransactionWithAccount (-50) "tx-unmatched" "unknown-acc"
      result <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory unmatchedTx
      result `shouldBe` Right Nothing

    it "imports an expense transaction with correct fields" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- Negative amount = expense (50.00 UAH in major units)
      let tx = mkTestTransaction (-50) "tx-expense-1"
      result <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      -- Verify the transaction was created with correct fields
      txRM <- runAppM env $ view transactionReadModelL
      maybeTxData <- TransactionRM.getTransaction txRM txId
      maybeTxData `shouldSatisfy` isJust
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      -- Source is the bank account (expense flows out)
      txData.sourceAccountId `shouldBe` bankAccId
      txData.description `shouldBe` "Test transaction"
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 50)
      txData.transferType `shouldBe` Expense testDefaultCategory
      txData.date `shouldBe` testTime

    it "imports an income transaction with correct fields" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- Positive amount = income (100.00 UAH in major units)
      let tx = mkTestTransaction 100 "tx-income-1"
      result <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      -- Verify the transaction was created with correct fields
      txRM <- runAppM env $ view transactionReadModelL
      maybeTxData <- TransactionRM.getTransaction txRM txId
      maybeTxData `shouldSatisfy` isJust
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      -- Target is the bank account (income flows in)
      txData.targetAccountId `shouldBe` bankAccId
      txData.description `shouldBe` "Test transaction"
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
      txData.transferType `shouldBe` Income testDefaultCategory
      txData.date `shouldBe` testTime

  describe "importTransaction cross-currency" $ do
    it "same currency: exchangeRate is Nothing" $ do
      -- Local UAH account; Mono tx where adapter set originalAmount = Nothing
      -- (amount == operationAmount). Expect emitted TransferInitiated to have
      -- exchangeRate = Nothing and sourceAmount == targetAmount.
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- originalAmount = Nothing indicates same-currency tx
      let tx = (mkTestTransaction (-50) "tx-same-ccy") {originalAmount = Nothing}
      result <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      txRM <- runAppM env $ view transactionReadModelL
      maybeTxData <- TransactionRM.getTransaction txRM txId
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount

    it "different currency: exchangeRate is still Nothing in Phase 1" $ do
      -- Local UAH account; Mono tx with amount = 1000 (UAH major units) and
      -- originalAmount = Just 25 (foreign currency major units). Expect the
      -- emitted TransferInitiated to have exchangeRate = Nothing and
      -- sourceAmount == targetAmount (both in account currency). Verify the
      -- import succeeds (rate is logged, not persisted).
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = (mkTestTransaction 1000 "tx-cross-ccy") {originalAmount = Just 25}
      result <- runAppM env $ importTransaction mockProvider testUserId accountLink testDefaultCategory tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      txRM <- runAppM env $ view transactionReadModelL
      maybeTxData <- TransactionRM.getTransaction txRM txId
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 1000)
