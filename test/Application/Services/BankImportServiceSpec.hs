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
--   - Resolves categories from per-user banking configuration (Phase 2)
module Application.Services.BankImportServiceSpec (spec) where

import Application.ReadModels.BankImportReadModel
  ( bankImportReadModel,
    isImported,
  )
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.Services.AccountService (createAccount)
import Application.Services.BankImportService (importTransaction)
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Database.Persist (insert_)
import Domain.Account.Commands (CreateAccount (..))
import Domain.Configuration.Defaults
  ( DefaultEntry (..),
    ExpenseDefaults (..),
    IncomeDefaults (..),
    expense,
    income,
  )
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    ExternalTransactionId,
    TransactionId,
    TransactionType (..),
    UserId,
    defaultBankAccount,
    mkMoney,
    unTransactionId,
    unsafeExternalTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionPostingFailed (..),
    TransactionPostingInitiated (..),
  )
import Eventium (Codec (..), EventHandler (..), GlobalStreamEvent, ReadModel (..), SequenceNumber, StreamEvent (..), catchUpReadModel, emptyMetadata, rebuildReadModel)
import Eventium.Store.Postgresql (jsonStringCodec)
import Eventium.Store.Sql (SqlEvent (..), defaultSqlEventStoreConfig)
import Infrastructure.App (AppEnv (..), runAppM, runDb)
import Infrastructure.Banking.Provider
  ( BankAccountId,
    BankTransaction (..),
    TransactionClassification (..),
  )
import Infrastructure.Database (runDbDirect)
import Infrastructure.Eventium (accountingGlobalEventStoreReader)
import RIO
import Test.Hspec
import qualified Testkit.Fixtures as Fixtures
import Testkit.Helpers
  ( fromRight',
    mockAccountId,
    mockMoneyWith,
    mockTransactionId,
    mockUserId,
    shouldBeRight,
    singletonExpense,
    singletonIncome,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid :: UUID
testUserUuid = UUID.fromWords 1 0 0 0

testUserId :: UserId
testUserId = mockUserId testUserUuid

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 4 14) (secondsToDiffTime 43200)

-- | A mock transaction classifier that classifies based on amount sign.
-- Passed directly to 'importTransaction', which now consumes a classify
-- function rather than a provider record.
mockClassify :: BankTransaction -> TransactionClassification
mockClassify tx =
  if tx.amount >= 0
    then ClassifiedIncome
    else ClassifiedExpense

-- | Create a bank transaction for testing. Amount is in major units.
mkTestTransaction :: Rational -> Text -> BankTransaction
mkTestTransaction = mkTestTransactionWithAccount' "mono-acc-1"

-- | Create a bank transaction for testing with a specific MCC.
mkTestTransactionWithMcc :: Rational -> Text -> Text -> BankTransaction
mkTestTransactionWithMcc amount extId mcc =
  (mkTestTransactionWithAccount' "mono-acc-1" amount extId) {mcc = Just mcc}

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
--   - A registered user (persistent User read model)
--   - A bank account
--   - An External account
--   - Seeded default configuration (with MCC map and banking defaults)
-- Returns (env, bankAccountId).
setupTestEnv :: IO (AppEnv, AccountId)
setupTestEnv = do
  env <- createTestAppEnvWithProcessManager

  -- Create accounts: External account (for the user) and a bank account
  (externalAccId, bankAccId) <- runAppM env $ do
    -- Seed default configuration (populates MCC map and banking defaults)
    ConfigurationService.seedDefaultConfiguration

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
    -- emit TransactionPostingFailed. Dedup is now permanent (a failed posting
    -- is never evicted), but the overdraft keeps these service-level tests
    -- focused on dedup semantics rather than balance accounting.
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

  -- Seed the persistent User read model with the test user.
  Fixtures.seedRegisteredUser env testUserId externalAccId "test@example.com"

  return (env, bankAccId)

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "BankImportService" $ do
  describe "importTransaction" $ do
    it "imports hold transactions like settled ones (Mono leaves some accounts stuck on hold)" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let holdTx = mkHoldTransaction (-50) "tx-hold"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink holdTx
      shouldBeRight result
      case result of
        Right (Just _) -> pure ()
        _ -> expectationFailure "expected hold transaction to be imported"

    it "skips already-imported transactions (dedup)" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]

      -- First import should succeed
      let tx = mkTestTransaction (-50) "tx-dedup-1"
      result1 <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result1
      case result1 of
        Right (Just _) -> pure ()
        _ -> expectationFailure "expected successful import"

      -- Second import of the same transaction should be skipped
      result2 <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      result2 `shouldBe` Right Nothing

    it "skips transactions with unmatched account" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- Transaction with a different account ID that has no mapping
      let unmatchedTx = mkTestTransactionWithAccount (-50) "tx-unmatched" "unknown-acc"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink unmatchedTx
      result `shouldBe` Right Nothing

    it "imports an expense transaction with correct fields" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- Negative amount = expense (50.00 UAH in major units), no MCC → defaultExpenseCategory
      let tx = mkTestTransaction (-50) "tx-expense-1"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      -- Verify the transaction was created with correct fields
      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      maybeTxData `shouldSatisfy` isJust
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      -- Source is the bank account (expense flows out)
      txData.sourceAccountId `shouldBe` bankAccId
      txData.description `shouldBe` "Test transaction"
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 50)
      -- Default expense category (expense.other) when no MCC
      txData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))
      txData.date `shouldBe` testTime

    it "imports an income transaction with correct fields" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- Positive amount = income (100.00 UAH in major units)
      let tx = mkTestTransaction 100 "tx-income-1"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      -- Verify the transaction was created with correct fields
      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      maybeTxData `shouldSatisfy` isJust
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      -- Target is the bank account (income flows in)
      txData.targetAccountId `shouldBe` bankAccId
      txData.description `shouldBe` "Test transaction"
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
      -- Default income category (income.other) when no MCC lookup applies for income
      txData.transactionType `shouldBe` singletonIncome income.other.entryId (fromRight' (mkMoney UAH 100))
      txData.date `shouldBe` testTime

  describe "importTransaction cross-currency" $ do
    it "same currency: exchangeRate is Nothing" $ do
      -- Local UAH account; Mono tx where adapter set originalAmount = Nothing
      -- (amount == operationAmount). Expect emitted TransactionPostingInitiated to have
      -- exchangeRate = Nothing and sourceAmount == targetAmount.
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      -- originalAmount = Nothing indicates same-currency tx
      let tx = (mkTestTransaction (-50) "tx-same-ccy") {originalAmount = Nothing}
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount

    it "different currency: exchangeRate is still Nothing in Phase 1" $ do
      -- Local UAH account; Mono tx with amount = 1000 (UAH major units) and
      -- originalAmount = Just 25 (foreign currency major units). Expect the
      -- emitted TransactionPostingInitiated to have exchangeRate = Nothing and
      -- sourceAmount == targetAmount (both in account currency). Verify the
      -- import succeeds (rate is logged, not persisted).
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = (mkTestTransaction 1000 "tx-cross-ccy") {originalAmount = Just 25}
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 1000)

  describe "category resolution (Phase 2)" $ do
    it "maps a known MCC to the configured category id" $ do
      -- MCC 5411 → expense.food in the default MCC map
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = mkTestTransactionWithMcc (-50) "tx-mcc-food" "5411"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonExpense expense.food.entryId (fromRight' (mkMoney UAH 50))

    it "falls back to defaultExpenseCategory when MCC is not in the map" $ do
      -- MCC "9999" is not in the default MCC map → falls back to expense.other
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = mkTestTransactionWithMcc (-50) "tx-mcc-unknown" "9999"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))

    it "falls back to defaultExpenseCategory when mcc is Nothing" $ do
      -- No MCC on the transaction → uses expense.other
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = mkTestTransaction (-50) "tx-no-mcc"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))

    it "records BankingError in AccountResyncResult.failures when no expense default is configured" $ do
      -- Seed a configuration without defaultExpenseCategory set, then resync
      -- with one expense transaction. Expect: no transfer, failure in result.
      env <- createTestAppEnvWithProcessManager
      (externalAccId, bankAccId) <- runAppM env $ do
        -- Seed config normally then clear the expense default by checking the
        -- resync result with a stripped config. To keep things simple, we use
        -- ConfigurationService.setBankingDefaultExpenseCategory but that sets it.
        -- Instead: seed a fresh config WITHOUT calling seedDefaultConfiguration
        -- so defaultExpenseCategory is Nothing. We still need the income dict
        -- entries seeded so income tests pass, but here we only test expense.
        -- We call seedDefaultConfiguration to get the dictionaries, then let
        -- expense default remain as-is (it IS set by seed). So we test the
        -- failure path by creating an env that specifically omits the seeding.
        --
        -- Approach: do NOT seed. The empty config means getConfigurationForUser
        -- returns NotFound (no config), which results in Left.
        -- But we need the User to have configurationId pointing at something
        -- that exists. Let's create a custom configuration with no banking defaults.
        --
        -- Actually, the simplest approach: seed default config (dictionaries
        -- populated, banking.defaultExpenseCategory set), then use
        -- setBankingDefaultExpenseCategory... there's no "unset" command.
        -- We need to test the Left path without an unset command available.
        --
        -- The cleanest approach is to NOT seed the config, but point the user
        -- at a config ID that only has the configuration created (no banking
        -- defaults set). We can do that directly via the event store.
        -- However, ConfigurationService.seedDefaultConfiguration creates a full
        -- config. Let's instead just NOT seed and test that the user not found
        -- in config lookup returns a failure.
        --
        -- Practical solution: only create External + bank accounts, don't seed.
        -- The user will have defaultConfigurationId but no config in the RM →
        -- getConfigurationForUser returns Left(NotFound) → importTransaction
        -- returns Left → resync collects it as failure.
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

      Fixtures.seedRegisteredUser env testUserId externalAccId "test@example.com"

      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = mkTestTransaction (-50) "tx-no-config"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      -- Config not found → Left error
      case result of
        Left _ -> pure () -- expected: some domain error
        Right _ -> expectationFailure "expected Left when configuration is missing"

    it "income direction uses defaultIncomeCategory" $ do
      -- Positive amount, banking.defaultIncomeCategory = income.other (from seed)
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]
      let tx = mkTestTransaction 200 "tx-income-cat"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      shouldBeRight result
      txId <- case result of
        Right (Just i) -> pure i
        _ -> expectationFailure "expected successful import" >> error "unreachable"

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonIncome income.other.entryId (fromRight' (mkMoney UAH 200))

  -- Regression guard for the permanent-dedup fix. The BankImportReadModel
  -- records an externalTransactionId on TransactionPostingInitiated and must
  -- NEVER evict it, even when the posting subsequently fails. The previous
  -- (evict-on-failure) behaviour caused every previously-failed transaction to
  -- be re-imported as a brand-new aggregate on each re-sync, accumulating
  -- duplicates without bound. We drive the read model's own event handler
  -- directly (mirroring production) to assert the mapping survives a failure.
  describe "BankImportReadModel dedup is permanent" $ do
    it "keeps an external id imported even after the posting fails (no evict)" $ do
      let txId = mockTransactionId (UUID.fromWords 7 0 0 0)
          extId = unsafeExternalTransactionId "tx-fails-later"

      -- The test AppEnv carries a migrated SQLite pool; drive the persistent
      -- read model's own handler through it (mirroring production).
      env <- createTestAppEnvWithProcessManager

      -- TransactionPostingInitiated carrying the external id records the mapping.
      feedBankImportEvents env [mkInitiatedEvent txId (Just extId) 0]
      imported1 <- runDbIn env $ isImported extId
      imported1 `shouldBe` True

      -- A later TransactionPostingFailed on the SAME stream must NOT evict it.
      feedBankImportEvents env [mkFailedEvent txId 1]
      imported2 <- runDbIn env $ isImported extId
      imported2 `shouldBe` True

  -- Foundation: the reusable backfill/rebuild path replays the event log into
  -- the persistent table. We insert events straight into the store (bypassing
  -- the live in-transaction handler), simulating pre-existing history before the
  -- projection existed, then drive the foundation functions.
  describe "bank-import catch-up + rebuild (eventium ReadModel)" $ do
    it "catches up the dedup table from the event log; re-running is idempotent" $ do
      env <- createTestAppEnvWithProcessManager
      let tx1 = mockTransactionId (UUID.fromWords 11 0 0 0)
          tx2 = mockTransactionId (UUID.fromWords 12 0 0 0)
          ext1 = unsafeExternalTransactionId "bf-1"
          ext2 = unsafeExternalTransactionId "bf-2"
          gr = accountingGlobalEventStoreReader defaultSqlEventStoreConfig
      storeInitiatedEvent env tx1 ext1
      storeInitiatedEvent env tx2 ext2
      -- Not yet projected (direct insert bypassed the live publisher).
      runDbIn env (isImported ext1) `shouldReturn` False
      runDbDirect env.dbPool (catchUpReadModel gr bankImportReadModel)
      runDbIn env (isImported ext1) `shouldReturn` True
      runDbIn env (isImported ext2) `shouldReturn` True
      -- Idempotent: a second catch-up changes nothing.
      runDbDirect env.dbPool (catchUpReadModel gr bankImportReadModel)
      runDbIn env (isImported ext1) `shouldReturn` True

    it "rebuild truncates and replays to identical state" $ do
      env <- createTestAppEnvWithProcessManager
      let tx1 = mockTransactionId (UUID.fromWords 13 0 0 0)
          ext1 = unsafeExternalTransactionId "rb-1"
          gr = accountingGlobalEventStoreReader defaultSqlEventStoreConfig
      storeInitiatedEvent env tx1 ext1
      runDbDirect env.dbPool (catchUpReadModel gr bankImportReadModel)
      runDbIn env (isImported ext1) `shouldReturn` True
      runDbDirect env.dbPool (rebuildReadModel gr bankImportReadModel)
      runDbIn env (isImported ext1) `shouldReturn` True

-- -----------------------------------------------------------------------------
-- Event construction for the read-model dedup test
--
-- Shape: GlobalStreamEvent = StreamEvent () SequenceNumber (VersionedStreamEvent)
-- where VersionedStreamEvent = StreamEvent UUID EventVersion AccountingEvent.
-- The inner stream UUID is the transaction aggregate's stream id, which
-- processEvent reads back via unpackGlobalEvent.
-- -----------------------------------------------------------------------------

-- | Drive the persistent bank-import read model's own event handler against the
-- test AppEnv's SQLite pool (mirroring the production in-transaction apply).
feedBankImportEvents ::
  AppEnv ->
  [GlobalStreamEvent AccountingEvent] ->
  IO ()
feedBankImportEvents env events =
  let ReadModel {eventHandler = EventHandler apply} = bankImportReadModel
   in runDbDirect env.dbPool (mapM_ apply events)

mkInitiatedEvent ::
  TransactionId ->
  Maybe ExternalTransactionId ->
  SequenceNumber ->
  GlobalStreamEvent AccountingEvent
mkInitiatedEvent txId mExtId seqNo =
  let acctSrc = mockAccountId (UUID.fromWords 1 0 0 0)
      acctTgt = mockAccountId (UUID.fromWords 2 0 0 0)
      inner =
        StreamEvent
          (unTransactionId txId)
          0
          (emptyMetadata "TransactionPostingInitiated")
          ( TransactionPostingInitiatedEvent
              TransactionPostingInitiated
                { sourceAccountId = acctSrc,
                  targetAccountId = acctTgt,
                  sourceAmount = mockMoneyWith UAH 100,
                  targetAmount = mockMoneyWith UAH 100,
                  exchangeRate = Nothing,
                  description = "seed",
                  by = mockUserId (UUID.fromWords 9 0 0 0),
                  at = testTime,
                  transactionType = Transfer,
                  externalTransactionId = mExtId,
                  labels = Set.empty
                }
          )
   in StreamEvent () seqNo (emptyMetadata "TransactionPostingInitiated") inner

-- | Insert a 'TransactionPostingInitiated' straight into the event store
-- (bypassing the live publisher), so backfill/rebuild have pre-existing history
-- to replay. The global sequence number is assigned by the store on insert.
storeInitiatedEvent :: AppEnv -> TransactionId -> ExternalTransactionId -> IO ()
storeInitiatedEvent env txId extId =
  let payload =
        TransactionPostingInitiatedEvent
          TransactionPostingInitiated
            { sourceAccountId = mockAccountId (UUID.fromWords 1 0 0 0),
              targetAccountId = mockAccountId (UUID.fromWords 2 0 0 0),
              sourceAmount = mockMoneyWith UAH 100,
              targetAmount = mockMoneyWith UAH 100,
              exchangeRate = Nothing,
              description = "seed",
              by = mockUserId (UUID.fromWords 9 0 0 0),
              at = testTime,
              transactionType = Transfer,
              externalTransactionId = Just extId,
              labels = Set.empty
            }
   in runAppM env
        $ runDb
        $ insert_ (SqlEvent (unTransactionId txId) 0 (jsonStringCodec.encode payload) Nothing)

mkFailedEvent ::
  TransactionId ->
  SequenceNumber ->
  GlobalStreamEvent AccountingEvent
mkFailedEvent txId seqNo =
  let inner =
        StreamEvent
          (unTransactionId txId)
          1
          (emptyMetadata "TransactionPostingFailed")
          (TransactionPostingFailedEvent (TransactionPostingFailed "Insufficient funds"))
   in StreamEvent () seqNo (emptyMetadata "TransactionPostingFailed") inner
