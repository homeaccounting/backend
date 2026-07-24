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

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.BankImportReadModel
  ( bankImportReadModel,
    isImported,
  )
import Application.ReadModels.Configuration (ConfigurationData (..), dictionaryItems)
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.Services.AccountService (createAccount)
import Application.Services.BankImportService
  ( AccountImportResult (..),
    ImportOutcome (..),
    ImportResult (..),
    SkipReason (..),
    importMany,
    importTransaction,
  )
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Database.Persist (insert_)
import Domain.Account.Commands (CreateAccount (..))
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Configuration.Defaults
  ( DefaultEntry (..),
    ExpenseDefaults (..),
    IncomeDefaults (..),
    expense,
    income,
  )
import Domain.Configuration.Dictionary (EntryRole (ItemRole))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    DictionaryEntryId,
    ExternalTransactionId,
    ImportInfo (..),
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    defaultBankAccount,
    mkMoney,
    unTransactionId,
    unsafeEntryName,
    unsafeExternalTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionPostingFailed (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Projection (TransactionStatus (Completed))
import Eventium (Codec (..), EventHandler (..), GlobalStreamEvent, ReadModel (..), SequenceNumber, StreamEvent (..), catchUpReadModel, emptyMetadata, rebuildReadModel)
import Eventium.Store.Postgresql (jsonStringCodec)
import Eventium.Store.Sql (SqlEvent (..), defaultSqlEventStoreConfig)
import Infrastructure.App (AppEnv (..), runAppM, runDb)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
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

-- | Assert an outcome imported a transaction and return its id; fail otherwise.
expectImported :: ImportOutcome -> IO TransactionId
expectImported (Imported i) = pure i
expectImported other = expectationFailure ("expected Imported, got " <> show other) >> error "unreachable"

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

-- | Create a bank transaction for testing with a specific raw description.
-- Built via full record construction (not update) to sidestep the
-- 'description' field being ambiguous across 'BankTransaction',
-- 'TransactionData' and 'TransactionPostingInitiated', all in scope here.
mkTestTransactionWithDescription :: Rational -> Text -> Text -> BankTransaction
mkTestTransactionWithDescription amount extId desc =
  BankTransaction
    { externalId = unsafeExternalTransactionId extId,
      externalAccountId = unsafeExternalAccountId "mono-acc-1",
      time = testTime,
      amount = amount,
      currencyCode = 840, -- USD, matching setupContactTestEnv's bank account currency
      description = desc,
      hold = False,
      mcc = Nothing,
      originalAmount = Nothing,
      notes = Nothing,
      categoryHint = Nothing
    }

mkTestTransactionWithAccount' :: Text -> Rational -> Text -> BankTransaction
mkTestTransactionWithAccount' acctId amount extId =
  BankTransaction
    { externalId = unsafeExternalTransactionId extId,
      externalAccountId = unsafeExternalAccountId acctId,
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
      externalAccountId = unsafeExternalAccountId "mono-acc-1",
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
--
-- The bank account is given a generous overdraft so the imported transfers
-- clear: bank imports debit the BankAccount from a zero initial balance. Most
-- of these service-level tests are about dedup / classification / field
-- mapping, so a roomy overdraft keeps the saga green and the focus off balance
-- accounting. Tests that specifically exercise the underfunded path use
-- 'setupTestEnvWithBankOverdraft' with a tighter limit.
setupTestEnv :: IO (AppEnv, AccountId)
setupTestEnv = setupTestEnvWithBankOverdraft (Just (Just (mockMoneyWith UAH 1000000)))

-- | 'setupTestEnv' with a configurable bank-account overdraft limit, so a test
-- can import into an account that cannot cover the transaction and observe the
-- import-bypasses-balance behaviour end to end.
setupTestEnvWithBankOverdraft :: Maybe (Maybe Money) -> IO (AppEnv, AccountId)
setupTestEnvWithBankOverdraft bankOverdraft = do
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

    bankResult <-
      createAccount
        CreateAccount
          { name = "Monobank UAH",
            initialBalance = mockMoneyWith UAH 0,
            createdBy = testUserId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = bankOverdraft
          }
    let (bankId, _) = fromRight' bankResult
    return (extId, bankId)

  -- Seed the persistent User read model with the test user.
  Fixtures.seedRegisteredUser env testUserId externalAccId "test@example.com"

  return (env, bankAccId)

-- | Set up a test environment for contact-resolution tests: a fully
-- REGISTERED user (via 'Fixtures.seedDefaultAndRegister', going through the
-- real 'RegisterUser' + 'AssignConfiguration' commands) plus a bank account.
--
-- Unlike 'setupTestEnv' (which only seeds the User read model directly via
-- 'Fixtures.seedRegisteredUser'), contact resolution needs
-- 'ConfigurationService.addDictionaryEntry' to succeed, and that clones the
-- user's configuration via a real domain command chain that requires the
-- User aggregate to actually exist — hence the heavier, real registration
-- flow here. The bank account is funded generously (rather than granted
-- overdraft, which 'Testkit.Fixtures.createAccount' has no knob for) so
-- imported expenses clear.
setupContactTestEnv :: IO (AppEnv, UserId, AccountId)
setupContactTestEnv = do
  env <- createTestAppEnvWithProcessManager
  userId <- Fixtures.seedDefaultAndRegister env "contact-test@example.com"
  bankAccId <- Fixtures.createAccount env userId "Monobank USD" defaultBankAccount USD 100000
  pure (env, userId, bankAccId)

-- | Seed a single contact dictionary entry, mirroring how category entries
-- are seeded elsewhere in these tests via 'ConfigurationService.addDictionaryEntry'.
seedContact :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
seedContact env userId name = do
  result <- runAppM env $ ConfigurationService.addDictionaryEntry userId ConfigurationService.contactsDictKind (unsafeEntryName name) ItemRole Nothing
  case result of
    Right eid -> pure eid
    Left err -> expectationFailure ("failed to seed contact: " <> show err) >> error "unreachable"

-- | Number of entries currently in the user's contact dictionary — used to
-- assert bank import never creates a new contact (MATCH-ONLY).
contactDictionaryCount :: AppEnv -> UserId -> IO Int
contactDictionaryCount env userId = do
  result <- runAppM env $ ConfigurationService.getConfigurationForUser userId
  case result of
    Right cfg -> pure (length (maybe [] dictionaryItems (Map.lookup ConfigurationService.contactsDictKind cfg.dictionaries)))
    Left err -> expectationFailure ("failed to load configuration: " <> show err) >> error "unreachable"

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "BankImportService" $ do
  describe "importTransaction" $ do
    it "imports hold transactions like settled ones (Mono leaves some accounts stuck on hold)" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let holdTx = mkHoldTransaction (-50) "tx-hold"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink holdTx
      case result of
        Imported _ -> pure ()
        _ -> expectationFailure "expected hold transaction to be imported"

    it "skips already-imported transactions (dedup)" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]

      -- First import should succeed
      let tx = mkTestTransaction (-50) "tx-dedup-1"
      result1 <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      case result1 of
        Imported _ -> pure ()
        _ -> expectationFailure "expected successful import"

      -- Second import of the same transaction should be skipped
      result2 <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      result2 `shouldBe` Skipped AlreadyImported

    it "skips transactions with unmatched account" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      -- Transaction with a different account ID that has no mapping
      let unmatchedTx = mkTestTransactionWithAccount (-50) "tx-unmatched" "unknown-acc"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink unmatchedTx
      result `shouldBe` Skipped Unmapped

    it "imports an expense transaction with correct fields" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      -- Negative amount = expense (50.00 UAH in major units), no MCC → defaultExpenseCategory
      let tx = mkTestTransaction (-50) "tx-expense-1"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

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
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      -- Positive amount = income (100.00 UAH in major units)
      let tx = mkTestTransaction 100 "tx-income-1"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

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

    it "posts an expense import even when the account cannot cover it (bypasses the balance guard)" $ do
      -- Zero balance, zero overdraft: a manual transfer this size would be
      -- rejected for insufficient funds, but a bank import records money that
      -- already moved at the bank and must post regardless, driving the local
      -- balance negative. This is the end-to-end guard for the retry-blocked-by-
      -- dedup fix: the import no longer Fails, so it never leaves a permanent
      -- dedup tombstone that blocks re-import.
      (env, bankAccId) <- setupTestEnvWithBankOverdraft (Just (Just (mockMoneyWith UAH 0)))
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = mkTestTransaction (-50) "tx-underfunded"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

      -- The posting saga runs synchronously in the test harness: the transaction
      -- reached the Completed terminal state rather than Failed.
      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.status `shouldBe` Completed

      -- The debit posted against the underfunded account, taking it negative.
      maybeBank <- runDbIn env (AccountRM.getAccount bankAccId)
      case maybeBank of
        Just bankData ->
          let AccountData {balance = bankBalance} = bankData
           in bankBalance `shouldBe` mockMoneyWith UAH (-50)
        Nothing -> expectationFailure "bank account not found"

  describe "importMany" $ do
    it "imports every transaction whose externalAccountId is in the link" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx1 = mkTestTransaction (-50) "tx-many-1"
          tx2 = mkTestTransaction 100 "tx-many-2"
      result <- runAppM env $ importMany mockClassify testUserId accountLink [tx1, tx2]
      result.unresolved `shouldBe` []
      length (concatMap (.succeeded) result.accounts) `shouldBe` 2

    it "collects an external account id absent from the link into unresolved, without committing it" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithAccount (-50) "tx-unresolved-1" "unknown-acc"
      result <- runAppM env $ importMany mockClassify testUserId accountLink [tx]
      result.unresolved `shouldBe` ["unknown-acc"]
      concatMap (.succeeded) result.accounts `shouldBe` []
      allTxCount <- runDbIn env TransactionRM.countTransactions
      allTxCount `shouldBe` 0

    it "imports transactions from several card ids mapped to the same local account" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink =
            [ (unsafeExternalAccountId "card-1", bankAccId),
              (unsafeExternalAccountId "card-2", bankAccId)
            ]
          tx1 = mkTestTransactionWithAccount (-50) "tx-card-1" "card-1"
          tx2 = mkTestTransactionWithAccount 100 "tx-card-2" "card-2"
      result <- runAppM env $ importMany mockClassify testUserId accountLink [tx1, tx2]
      result.unresolved `shouldBe` []
      length (concatMap (.succeeded) result.accounts) `shouldBe` 2

  describe "importTransaction cross-currency" $ do
    it "same currency: exchangeRate is Nothing" $ do
      -- Local UAH account; Mono tx where adapter set originalAmount = Nothing
      -- (amount == operationAmount). Expect emitted TransactionPostingInitiated to have
      -- exchangeRate = Nothing and sourceAmount == targetAmount.
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      -- originalAmount = Nothing indicates same-currency tx
      let tx = (mkTestTransaction (-50) "tx-same-ccy") {originalAmount = Nothing}
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

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
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = (mkTestTransaction 1000 "tx-cross-ccy") {originalAmount = Just 25}
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 1000)

    it "skips a transaction whose currency differs from the mapped local account" $ do
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          -- The mapped local account is UAH, but the transaction is USD (840).
          tx = (mkTestTransaction (-50) "tx-ccy-mismatch") {currencyCode = 840}
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      case result of
        Skipped (CurrencyMismatch _) -> pure ()
        _ -> expectationFailure ("expected a currency-mismatch skip, got " <> show result)

  describe "category resolution (Phase 2)" $ do
    it "maps a known MCC to the configured category id" $ do
      -- MCC 5411 → expense.groceries in the default MCC map
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = mkTestTransactionWithMcc (-50) "tx-mcc-food" "5411"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonExpense expense.groceries.entryId (fromRight' (mkMoney UAH 50))
      -- The original MCC is retained on the imported transaction.
      txData.mcc `shouldBe` Just "5411"

    it "falls back to defaultExpenseCategory when MCC is not in the map" $ do
      -- MCC "9999" is not in the default MCC map → falls back to expense.other
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = mkTestTransactionWithMcc (-50) "tx-mcc-unknown" "9999"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))

    it "falls back to defaultExpenseCategory when mcc is Nothing" $ do
      -- No MCC on the transaction → uses expense.other
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = mkTestTransaction (-50) "tx-no-mcc"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))
      -- A transaction with no MCC records no MCC.
      txData.mcc `shouldBe` Nothing

    it "records BankingError in AccountImportResult.failed when no expense default is configured" $ do
      -- Seed a configuration without defaultExpenseCategory set, then import
      -- with one expense transaction. Expect: no transfer, failure in result.
      env <- createTestAppEnvWithProcessManager
      (externalAccId, bankAccId) <- runAppM env $ do
        -- Seed config normally then clear the expense default by checking the
        -- import result with a stripped config. To keep things simple, we use
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
        -- returns Left → importMany collects it as a failure.
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

      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = mkTestTransaction (-50) "tx-no-config"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      -- Config not found → Failed outcome
      case result of
        Failed _ -> pure () -- expected: some domain error
        _ -> expectationFailure "expected Failed when configuration is missing"

    it "income direction uses defaultIncomeCategory" $ do
      -- Positive amount, banking.defaultIncomeCategory = income.other (from seed)
      (env, bankAccId) <- setupTestEnv
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
      let tx = mkTestTransaction 200 "tx-income-cat"
      result <- runAppM env $ importTransaction mockClassify testUserId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.transactionType `shouldBe` singletonIncome income.other.entryId (fromRight' (mkMoney UAH 200))

  describe "contact resolution (match-only)" $ do
    it "links an existing contact on an expense import when the description matches" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      contactId <- seedContact env userId "Landlord"
      countBefore <- contactDictionaryCount env userId
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-expense" "Landlord"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Just contactId

      -- Match-only: importing never creates a new dictionary entry.
      countAfter <- contactDictionaryCount env userId
      countAfter `shouldBe` countBefore

    it "links an existing contact on an income import when the description matches" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      contactId <- seedContact env userId "Employer"
      countBefore <- contactDictionaryCount env userId
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription 200 "tx-contact-income" "Employer"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Just contactId

      countAfter <- contactDictionaryCount env userId
      countAfter `shouldBe` countBefore

    it "leaves contactId Nothing when the description matches no existing contact" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      _ <- seedContact env userId "Landlord"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-nomatch" "Some Random Shop"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Nothing

    it "leaves contactId Nothing for a blank description" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      _ <- seedContact env userId "Landlord"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-blank" "   "
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Nothing

    it "matches case-insensitively and ignores surrounding/collapsed whitespace" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      contactId <- seedContact env userId "Netflix"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-casefold" "  netflix "
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Just contactId

    it "links an existing contact when its name appears as a substring of the description" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      contactId <- seedContact env userId "Netflix"
      countBefore <- contactDictionaryCount env userId
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-substring" "payment to netflix europe"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Just contactId

      -- Match-only: substring resolution never creates a dictionary entry.
      countAfter <- contactDictionaryCount env userId
      countAfter `shouldBe` countBefore

    it "prefers an exact match over a substring match" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      _netId <- seedContact env userId "Net"
      netflixId <- seedContact env userId "Netflix"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-exact-over-substring" "Netflix"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Just netflixId

    it "prefers the longest matching substring among several candidate contacts" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      _amazonId <- seedContact env userId "Amazon"
      amazonPrimeId <- seedContact env userId "Amazon Prime"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-longest-substring" "amazon prime video subscription"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Just amazonPrimeId

    it "leaves contactId Nothing when two equal-length substring matches tie" $ do
      (env, userId, bankAccId) <- setupContactTestEnv
      _uberId <- seedContact env userId "Uber"
      _boltId <- seedContact env userId "Bolt"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]
          tx = mkTestTransactionWithDescription (-50) "tx-contact-ambiguous-substring" "uber and bolt ride"
      result <- runAppM env $ importTransaction mockClassify userId accountLink tx
      txId <- expectImported result

      maybeTxData <- runDbIn env (TransactionRM.getTransaction txId)
      txData <- case maybeTxData of
        Just d -> pure d
        Nothing -> expectationFailure "transaction not found" >> error "unreachable"
      txData.contactId `shouldBe` Nothing

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
                  importInfo = fmap (\e -> ImportInfo {externalTransactionId = e, mcc = Nothing}) mExtId,
                  labels = Set.empty,
                  contactId = Nothing
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
              importInfo = Just ImportInfo {externalTransactionId = extId, mcc = Nothing},
              labels = Set.empty,
              contactId = Nothing
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
