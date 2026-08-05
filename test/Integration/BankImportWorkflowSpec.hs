{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.BankImportWorkflowSpec
-- Description : Integration tests for the bank import workflow
--
-- End-to-end tests that exercise the full bank import pipeline:
--   - Account creation via AccountService
--   - Resync with a mock provider returning test statements
--   - Transfer creation verification via TransactionReadModel
--   - Deduplication on re-run
--   - Hold transaction filtering
module Integration.BankImportWorkflowSpec (spec) where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import qualified Application.ReadModels.Configuration as ConfigRM
import qualified Application.ReadModels.ExchangeRate as ExchangeRateRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (createAccount)
import Application.Services.BankImportService
  ( AccountImportResult (..),
    ImportResult (..),
    importConnection,
  )
import qualified Application.Services.ConfigurationService as ConfigurationService
import Data.List (nubBy)
import Data.Time (Day, UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import Domain.Account.Commands (CreateAccount (..))
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Configuration.CommandHandler (ConfigurationCommand (..))
import Domain.Configuration.Commands (AddDictionaryEntry (..))
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
    Money,
    TransactionType (Transfer),
    UserId,
    defaultBankAccount,
    defaultConfigurationId,
    mkMoney,
    moneyCurrency,
    unConfigurationId,
    unsafeDictionaryEntryId,
    unsafeEntryName,
    unsafeExternalTransactionId,
  )
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Projection (TransactionStatus (Completed))
import Eventium (GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    PullCapability (..),
    TransactionClassification (..),
    TransactionInterpretation (..),
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import Infrastructure.Eventium (applyConfigurationCommand)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (NonEmptyList (..), Positive (..), ioProperty, (===))
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import qualified Testkit.Fixtures as Fixtures
import Testkit.Helpers
  ( fromRight',
    mockExchangeRate,
    mockMoneyWith,
    mockUserId,
    singletonExpense,
    singletonIncome,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import qualified UnliftIO.Async as Async

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Extract a Just value or fail the test with a descriptive message.
fromJustIO :: String -> Maybe a -> IO a
fromJustIO label Nothing = expectationFailure (label <> " not found") >> error "unreachable"
fromJustIO _ (Just a) = return a

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid :: UUID
testUserUuid = UUID.fromWords 10 0 0 0

testUserId :: UserId
testUserId = mockUserId testUserUuid

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 4 10) (secondsToDiffTime 43200)

testFromTime :: UTCTime
testFromTime = UTCTime (fromGregorian 2026 4 1) 0

testToTime :: UTCTime
testToTime = UTCTime (fromGregorian 2026 4 14) 0

-- -----------------------------------------------------------------------------
-- Mock Provider
-- -----------------------------------------------------------------------------

-- | A mock pull capability that returns the given statements.
mockProvider :: [BankTransaction] -> PullCapability
mockProvider statements =
  PullCapability
    { fetchAccounts = return $ Right [],
      fetchStatements = \_ _ _ -> return $ Right statements,
      registerWebhook = \_ -> return $ Right ()
    }

-- | A mock pull capability that returns per-external-account statements, so a
-- connection spanning several accounts can be exercised. Accounts absent from
-- the map fetch an empty statement list.
mockProviderPerAccount :: [(ExternalAccountId, [BankTransaction])] -> PullCapability
mockProviderPerAccount perAccount =
  PullCapability
    { fetchAccounts = return $ Right [],
      fetchStatements = \extAccId _ _ -> return $ Right (fromMaybe [] (lookup extAccId perAccount)),
      registerWebhook = \_ -> return $ Right ()
    }

-- | The classifier the mock provider pairs with: income for non-negative
-- amounts, expense otherwise (the Monobank sign rule).
mockClassify :: BankTransaction -> TransactionClassification
mockClassify tx =
  if tx.amount >= 0
    then ClassifiedIncome
    else ClassifiedExpense

-- | The interpretation the mock provider pairs with: 'mockClassify' plus the
-- generic (default) transfer matcher over the default pairing window.
interp :: TransactionInterpretation
interp = TransactionInterpretation mockClassify (defaultTransferMatcher defaultTransferPairingWindow) mempty

-- | Create a bank transaction for testing. Amount is in major units.
mkTestTransaction :: Rational -> Text -> BankTransaction
mkTestTransaction amount extId =
  BankTransaction
    { externalId = unsafeExternalTransactionId extId,
      externalAccountId = unsafeExternalAccountId "mono-acc-1",
      time = testTime,
      amount = amount,
      currencyCode = 980, -- UAH
      description = "Test transaction",
      hold = False,
      category = Nothing,
      originalAmount = Nothing,
      notes = Nothing
    }

-- | Create a bank transaction with a caller-chosen description, for testing
-- contact resolution (which matches on the statement's @description@).
mkDescribedTransaction :: Rational -> Text -> Text -> BankTransaction
mkDescribedTransaction amount extId desc = (mkTestTransaction amount extId) {description = desc}

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
      category = Nothing,
      originalAmount = Nothing,
      notes = Nothing
    }

-- -----------------------------------------------------------------------------
-- Test Setup
-- -----------------------------------------------------------------------------

-- | Set up a full test environment with user, accounts, and link mapping.
-- Returns (env, externalAccountId, bankAccountId, link).
setupTestEnv :: IO (AppEnv, AccountId, AccountId, [(ExternalAccountId, AccountId)])
setupTestEnv = do
  env <- createTestAppEnvWithProcessManager

  -- Seed default configuration (provides MCC map and banking defaults)
  runAppM env ConfigurationService.seedDefaultConfiguration

  -- Create accounts via AccountService
  (externalAccId, bankAccId) <- runAppM env $ do
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
            -- Bank account starts at 0 and the saga debits it for each imported tx.
            -- Without an overdraft, every transfer would emit TransactionPostingFailed
            -- (Insufficient Funds), which the new dedup eviction reclaims --
            -- breaking these dedup-focused tests. Give the account enough
            -- headroom so transfers actually complete and stay deduped.
            overdraftLimit = Just (Just (mockMoneyWith UAH 1000000))
          }
    let (bankId, _) = fromRight' bankResult
    return (extId, bankId)

  -- Seed the persistent User read model with the test user.
  Fixtures.seedRegisteredUser env testUserId externalAccId "test@example.com"

  let accountLink :: [(ExternalAccountId, AccountId)]
      accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]

  return (env, externalAccId, bankAccId, accountLink)

-- | Set up an environment with TWO linked bank accounts (A and B) plus the
-- per-user External account, so an internal transfer between A and B can be
-- detected and paired at import time. Both bank accounts carry overdraft
-- headroom so the debit leg posts. Returns (env, bankAccIdA, bankAccIdB, link)
-- with the link in [A, B] order.
setupTwoBankAccountEnv :: IO (AppEnv, AccountId, AccountId, [(ExternalAccountId, AccountId)])
setupTwoBankAccountEnv = do
  env <- createTestAppEnvWithProcessManager
  runAppM env ConfigurationService.seedDefaultConfiguration
  (externalAccId, bankAccIdA, bankAccIdB) <- runAppM env $ do
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
    aResult <-
      createAccount
        CreateAccount
          { name = "Monobank A",
            initialBalance = mockMoneyWith UAH 0,
            createdBy = testUserId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = Just (Just (mockMoneyWith UAH 1000000))
          }
    let (aId, _) = fromRight' aResult
    bResult <-
      createAccount
        CreateAccount
          { name = "Monobank B",
            initialBalance = mockMoneyWith UAH 0,
            createdBy = testUserId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = Just (Just (mockMoneyWith UAH 1000000))
          }
    let (bId, _) = fromRight' bResult
    return (extId, aId, bId)
  Fixtures.seedRegisteredUser env testUserId externalAccId "test@example.com"
  let accountLink :: [(ExternalAccountId, AccountId)]
      accountLink =
        [ (unsafeExternalAccountId "mono-acc-A", bankAccIdA),
          (unsafeExternalAccountId "mono-acc-B", bankAccIdB)
        ]
  return (env, bankAccIdA, bankAccIdB, accountLink)

-- | Set up a CROSS-CURRENCY test environment: the per-user External account
-- is in USD (the user's base currency) while the linked bank account is in
-- UAH (the bank-transaction currency). This is the configuration that
-- triggered the original bug: income/expense post a UAH amount to the USD
-- External leg, which the saga rejects with 'CurrencyMismatch' unless the
-- import resolves per-leg amounts + an exchange rate.
--
-- Returns (env, usdExternalAccId, uahBankAccId, link).
setupCrossCurrencyEnv :: IO (AppEnv, AccountId, AccountId, [(ExternalAccountId, AccountId)])
setupCrossCurrencyEnv = do
  env <- createTestAppEnvWithProcessManager
  runAppM env ConfigurationService.seedDefaultConfiguration
  (externalAccId, bankAccId) <- runAppM env $ do
    extResult <-
      createAccount
        CreateAccount
          { name = "External",
            initialBalance = mockMoneyWith USD 0,
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
  return (env, externalAccId, bankAccId, accountLink)

-- | Feed a synthetic 'ExchangeRatesPublishedEvent' (dated @day@) through the
-- exchange-rate read model under the env's configured provider, exactly as
-- the manual-flow tests do (mirrors the helper in 'TransactionServiceSpec').
seedExchangeRateAt :: AppEnv -> Day -> [(Currency, Currency, Rational)] -> IO ()
seedExchangeRateAt env day rates = do
  let rateMap = Map.fromList [((src, tgt), mockExchangeRate src tgt r) | (src, tgt, r) <- rates]
      providerName = env.config.exchangeRate.provider
      payload =
        ExchangeRatesPublishedEvent
          ExchangeRatesPublished
            { provider = providerName,
              rates = rateMap,
              at = day
            }
      versionedEvent = StreamEvent UUID.nil 0 (emptyMetadata mempty) payload
      globalEvent :: GlobalStreamEvent AccountingEvent
      globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
  runDbIn env (ExchangeRateRM.applyExchangeRateEvent globalEvent)

-- | The business day of 'testTime', used as the default rate date.
testDay :: Day
testDay = fromGregorian 2026 4 10

-- | Look up an account's current balance from the read model.
accountBalanceOf :: AppEnv -> AccountId -> IO Money
accountBalanceOf env accId = do
  mData <- runDbIn env (AccountRM.getAccount accId)
  d <- fromJustIO "account" mData
  pure d.balance

-- | Add a contact-dictionary entry directly to the shared default
-- configuration (dispatched straight to its aggregate stream, bypassing the
-- per-user clone-on-write). The test user is seeded via
-- 'Fixtures.seedRegisteredUser', which writes only the read model and never
-- the User aggregate's event stream, so 'ConfigurationService.addDictionaryEntry'
-- (which clone-on-writes via a User command) is not usable here; this
-- mirrors the direct-dispatch idiom in 'Application.Services.ConfigurationServiceSpec'.
addContact :: AppEnv -> Text -> IO DictionaryEntryId
addContact env name = do
  entryUuid <- UUIDv4.nextRandom
  let entryId = unsafeDictionaryEntryId entryUuid
      cmd =
        AddDictionaryEntryConfigurationCommand
          AddDictionaryEntry
            { dictionaryKind = ConfigurationService.contactsDictKind,
              entryId = entryId,
              name = unsafeEntryName name,
              role = ItemRole,
              parentId = Nothing
            }
  result <-
    applyConfigurationCommand
      env.eventStoreWriter
      env.eventStoreReader
      id
      (unConfigurationId defaultConfigurationId)
      cmd
  case result of
    Left err -> fail $ "addDictionaryEntry " <> show name <> " failed: " <> show err
    Right _ -> pure entryId

-- | Every entry id currently in the test user's contacts dictionary.
userContactDictionaryEntryIds :: AppEnv -> IO [DictionaryEntryId]
userContactDictionaryEntryIds env = do
  mUser <- runDbIn env (getUser testUserId)
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- runDbIn env (ConfigRM.getConfiguration ud.configurationId)
      case mCfg of
        Nothing -> fail "configuration not found"
        Just cfg ->
          pure
            $ maybe
              []
              (map fst . ConfigRM.dictionaryItems)
              (Map.lookup ConfigurationService.contactsDictKind cfg.dictionaries)

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Bank Import Workflow" $ do
  it "imports transactions (including holds) and deduplicates on re-run" $ do
    (env, externalAccId, bankAccId, accountLink) <- setupTestEnv

    -- Mock statements: 1 expense, 1 income, 1 hold (all imported — Mono leaves
    -- some accounts stuck on hold, so we no longer filter on the hold flag)
    let expenseTx = mkTestTransaction (-50) "tx-expense-1"
        incomeTx = mkTestTransaction 100 "tx-income-1"
        holdTx = mkHoldTransaction (-30) "tx-hold-1"
        statements = [expenseTx, incomeTx, holdTx]
        provider = mockProvider statements

    -- First resync: should import all 3 transactions (hold no longer filtered)
    result1 <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
    let importedIds = concatMap (.succeeded) result1.accounts
    length importedIds `shouldBe` 3

    -- Extract the three imported IDs (expense, income, hold-as-expense)
    case importedIds of
      [expenseId, incomeId, holdId] -> do
        -- Verify expense transfer: source = bank account, target = external
        expenseData <- fromJustIO "expense transaction" =<< runDbIn env (TransactionRM.getTransaction expenseId)
        expenseData.sourceAccountId `shouldBe` bankAccId
        expenseData.targetAccountId `shouldBe` externalAccId
        expenseData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 50)
        -- No MCC on tx → falls back to defaultExpenseCategory (expense.other)
        expenseData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))
        expenseData.description `shouldBe` "Test transaction"
        expenseData.date `shouldBe` testTime

        -- Verify income transfer: source = external, target = bank account
        incomeData <- fromJustIO "income transaction" =<< runDbIn env (TransactionRM.getTransaction incomeId)
        incomeData.sourceAccountId `shouldBe` externalAccId
        incomeData.targetAccountId `shouldBe` bankAccId
        incomeData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
        -- Income always uses defaultIncomeCategory (income.other)
        incomeData.transactionType `shouldBe` singletonIncome income.other.entryId (fromRight' (mkMoney UAH 100))
        incomeData.description `shouldBe` "Test transaction"
        incomeData.date `shouldBe` testTime

        -- Verify the hold was imported as a normal expense (negative amount)
        holdData <- fromJustIO "hold transaction" =<< runDbIn env (TransactionRM.getTransaction holdId)
        holdData.sourceAccountId `shouldBe` bankAccId
        holdData.targetAccountId `shouldBe` externalAccId
        holdData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 30)
        holdData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 30))

        -- Second resync (dedup): same statements should produce no new imports
        result2 <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
        concatMap (.succeeded) result2.accounts `shouldBe` []
        concatMap (.failed) result2.accounts `shouldBe` []
      _ -> expectationFailure $ "Expected exactly 3 imported IDs, got " <> show (length importedIds)

  it "imports hold transactions as if they were settled" $ do
    (env, _externalAccId, _bankAccId, accountLink) <- setupTestEnv

    -- All statements are holds; with the hold filter removed every one
    -- should land in the read model. This guards against the filter
    -- being reintroduced if Mono ever fixes their settlement worker.
    let statements =
          [ mkHoldTransaction (-10) "hold-1",
            mkHoldTransaction 20 "hold-2",
            mkHoldTransaction (-5) "hold-3"
          ]
        provider = mockProvider statements

    result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
    length (concatMap (.succeeded) result.accounts) `shouldBe` 3
    concatMap (.failed) result.accounts `shouldBe` []

  it "pairs opposite legs across two of the connection's own accounts into a single transfer" $ do
    (env, bankAccIdA, bankAccIdB, accountLink) <- setupTwoBankAccountEnv

    -- A debit leg on account A and the matching credit leg on account B:
    -- equal magnitude, same currency, same timestamp (within the window).
    -- Each is fetched under its own external account, yet a single import
    -- over the union must collapse them into ONE internal Transfer.
    let debitLeg =
          mkSameCurrencyBankTx
            (unsafeExternalTransactionId "transfer-debit")
            (unsafeExternalAccountId "mono-acc-A")
            (-100)
        creditLeg =
          mkSameCurrencyBankTx
            (unsafeExternalTransactionId "transfer-credit")
            (unsafeExternalAccountId "mono-acc-B")
            100
        provider =
          mockProviderPerAccount
            [ (unsafeExternalAccountId "mono-acc-A", [debitLeg]),
              (unsafeExternalAccountId "mono-acc-B", [creditLeg])
            ]

    result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime

    -- Still one row per link entry, in link order [A, B].
    length result.accounts `shouldBe` 2
    -- Exactly one transaction was created (a transfer, not two legs).
    allTxCount <- runDbIn env TransactionRM.countTransactions
    allTxCount `shouldBe` 1

    -- The transfer's id appears under BOTH accounts (same id on each row).
    case map (.succeeded) result.accounts of
      [[idA], [idB]] -> do
        idA `shouldBe` idB
        txData <- fromJustIO "transfer tx" =<< runDbIn env (TransactionRM.getTransaction idA)
        txData.transactionType `shouldBe` Transfer
        -- Debit leg (A) is the source, credit leg (B) is the target.
        txData.sourceAccountId `shouldBe` bankAccIdA
        txData.targetAccountId `shouldBe` bankAccIdB
        txData.status `shouldBe` Completed
        -- A decreased by 100, B increased by 100 (no External double count).
        balA <- accountBalanceOf env bankAccIdA
        balB <- accountBalanceOf env bankAccIdB
        balA `shouldBe` fromRight' (mkMoney UAH (-100))
        balB `shouldBe` fromRight' (mkMoney UAH 100)
      other -> expectationFailure $ "expected one tx id under each of the two link rows, got " <> show other

  prop "concurrent resyncs of the same statement produce one transfer per external id"
    $ \(txSeeds :: NonEmptyList (Positive Int)) -> ioProperty $ do
      (env, _externalAccId, _bankAccId, accountLink) <- setupTestEnv
      let txs =
            zipWith
              ( \i (Positive n) ->
                  mkSameCurrencyBankTx
                    (unsafeExternalTransactionId (T.pack ("tx-" <> show (i :: Int))))
                    (unsafeExternalAccountId "mono-acc-1")
                    (fromIntegral n)
              )
              [0 ..]
              (getNonEmpty txSeeds)
          provider = mockProvider txs
          runOnce =
            runAppM env
              $ importConnection interp provider testUserId accountLink testFromTime testToTime
          extIdOf :: BankTransaction -> ExternalTransactionId
          extIdOf t = t.externalId
          expected = length (nubBy ((==) `on` extIdOf) txs)
      (r1, r2) <- Async.concurrently runOnce runOnce
      -- Sum of imported IDs across both calls must equal the number of
      -- unique external IDs. A TOCTOU race lets two resyncs both emit for
      -- the same external id, producing a total greater than `expected`.
      let importedIn r = length (concatMap (.succeeded) r.accounts)
          totalImported = importedIn r1 + importedIn r2
      allTxCount <- runDbIn env TransactionRM.countTransactions
      pure
        $ (totalImported, allTxCount)
        === (expected, expected)

  describe "cross-currency import (External account currency != bank tx currency)" $ do
    it "posts a cross-currency income successfully with per-leg amounts and a resolved rate" $ do
      -- USD External, UAH bank account, a published USD<->UAH rate (41).
      (env, externalAccId, bankAccId, accountLink) <- setupCrossCurrencyEnv
      seedExchangeRateAt env testDay [(USD, UAH, 41), (UAH, USD, 1 / 41)]

      let incomeTx = mkTestTransaction 100 "xc-income" -- +100 UAH income
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.failed) result.accounts `shouldBe` []
      txId <- case concatMap (.succeeded) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"

      txData <- fromJustIO "income tx" =<< runDbIn env (TransactionRM.getTransaction txId)
      -- Income: source = USD External, target = UAH bank account.
      txData.sourceAccountId `shouldBe` externalAccId
      txData.targetAccountId `shouldBe` bankAccId
      -- The known bank amount (100 UAH) is the TARGET leg.
      moneyCurrency txData.targetAmount `shouldBe` UAH
      txData.targetAmount `shouldBe` fromRight' (mkMoney UAH 100)
      -- The source leg is in the External account's currency (USD) with a rate.
      moneyCurrency txData.sourceAmount `shouldBe` USD
      txData.exchangeRate `shouldNotBe` Nothing
      -- The posting saga COMPLETED (the bug left it Failed via CurrencyMismatch).
      txData.status `shouldBe` Completed
      -- The bank (UAH) account balance grew by the imported income.
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney UAH 100)

    it "posts a cross-currency expense successfully after funding the account" $ do
      (env, externalAccId, bankAccId, accountLink) <- setupCrossCurrencyEnv
      seedExchangeRateAt env testDay [(USD, UAH, 41), (UAH, USD, 1 / 41)]

      -- First an income to fund, then an expense (both UAH on the bank account).
      let incomeTx = mkTestTransaction 500 "xc-fund"
          expenseTx = mkTestTransaction (-200) "xc-expense"
          provider = mockProvider [incomeTx, expenseTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.failed) result.accounts `shouldBe` []
      expenseId <- case concatMap (.succeeded) result.accounts of
        [_fundId, eId] -> pure eId
        other -> expectationFailure ("expected two imported ids, got " <> show (length other)) >> error "unreachable"

      txData <- fromJustIO "expense tx" =<< runDbIn env (TransactionRM.getTransaction expenseId)
      -- Expense: source = UAH bank account, target = USD External.
      txData.sourceAccountId `shouldBe` bankAccId
      txData.targetAccountId `shouldBe` externalAccId
      -- The known bank amount (200 UAH) is the SOURCE leg here.
      moneyCurrency txData.sourceAmount `shouldBe` UAH
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 200)
      moneyCurrency txData.targetAmount `shouldBe` USD
      txData.exchangeRate `shouldNotBe` Nothing
      txData.status `shouldBe` Completed
      -- Bank balance = 500 funded - 200 spent = 300 UAH.
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney UAH 300)

    it "uses the nearest published rate when no rate exists on the tx date" $ do
      -- Publish a rate a week AFTER the tx; lookupNearestDate should still
      -- resolve it, so the import posts (inherited fallback behaviour).
      (env, _externalAccId, bankAccId, accountLink) <- setupCrossCurrencyEnv
      seedExchangeRateAt env (fromGregorian 2026 4 17) [(USD, UAH, 41)]

      let incomeTx = mkTestTransaction 100 "xc-nearest"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.failed) result.accounts `shouldBe` []
      txId <- case concatMap (.succeeded) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"

      txData <- fromJustIO "income tx" =<< runDbIn env (TransactionRM.getTransaction txId)
      txData.exchangeRate `shouldNotBe` Nothing
      txData.status `shouldBe` Completed
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney UAH 100)

    it "records a per-tx failure when no rate exists for the pair and does not abort the batch" $ do
      -- No rate published at all → that cross-currency tx fails, but a
      -- same-currency-style tx in the same batch is unaffected.
      (env, _externalAccId, _bankAccId, accountLink) <- setupCrossCurrencyEnv
      -- intentionally seed nothing
      let incomeTx = mkTestTransaction 100 "xc-no-rate"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.succeeded) result.accounts `shouldBe` []
      length (concatMap (.failed) result.accounts) `shouldBe` 1

    it "skips a tx whose currency does not match the mapped account's currency" $ do
      -- USD bank account ("Black card") but a UAH transaction. Importing a
      -- UAH tx into a USD account is unsupported, so the import must SKIP it
      -- (counted in `skipped`, never initiated) rather than initiate a
      -- transfer that the posting saga rejects with a cryptic CurrencyMismatch.
      env <- createTestAppEnvWithProcessManager
      runAppM env ConfigurationService.seedDefaultConfiguration
      (externalAccId, bankAccId) <- runAppM env $ do
        extResult <-
          createAccount
            CreateAccount
              { name = "External",
                initialBalance = mockMoneyWith USD 0,
                createdBy = testUserId,
                accountType = External,
                overdraftLimit = Nothing
              }
        let (extId, _) = fromRight' extResult
        bankResult <-
          createAccount
            CreateAccount
              { name = "Black card",
                initialBalance = mockMoneyWith USD 0,
                createdBy = testUserId,
                accountType = Regular defaultBankAccount,
                overdraftLimit = Just (Just (mockMoneyWith USD 1000000))
              }
        let (bankId, _) = fromRight' bankResult
        return (extId, bankId)
      Fixtures.seedRegisteredUser env testUserId externalAccId "test@example.com"
      let accountLink :: [(ExternalAccountId, AccountId)]
          accountLink = [(unsafeExternalAccountId "mono-acc-1", bankAccId)]

      -- A UAH transaction (currencyCode 980) mapped to a USD account.
      let incomeTx = mkTestTransaction 100 "xc-mismatch"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      -- Skipped, not imported, not failed.
      concatMap (.succeeded) result.accounts `shouldBe` []
      concatMap (.failed) result.accounts `shouldBe` []
      sum (map (length . (.skipped)) result.accounts) `shouldBe` 1
      -- No transaction was ever initiated.
      allTxCount <- runDbIn env TransactionRM.countTransactions
      allTxCount `shouldBe` 0
      -- The account balance is unchanged.
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney USD 0)

    it "same-currency import is unchanged: exchangeRate Nothing and equal amounts" $ do
      -- Guard against regression: UAH External + UAH bank → no rate, amounts equal.
      (env, _externalAccId, bankAccId, accountLink) <- setupTestEnv
      let incomeTx = mkTestTransaction 100 "xc-same"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.failed) result.accounts `shouldBe` []
      txId <- case concatMap (.succeeded) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"
      txData <- fromJustIO "income tx" =<< runDbIn env (TransactionRM.getTransaction txId)
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
      txData.status `shouldBe` Completed
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney UAH 100)

  describe "contact resolution on import" $ do
    it "links a pre-seeded contact when the statement description matches" $ do
      (env, _externalAccId, _bankAccId, accountLink) <- setupTestEnv
      contactId <- addContact env "Acme Corp"

      let incomeTx = mkDescribedTransaction 100 "contact-match" "Acme Corp"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.failed) result.accounts `shouldBe` []
      txId <- case concatMap (.succeeded) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"

      txData <- fromJustIO "matched-contact tx" =<< runDbIn env (TransactionRM.getTransaction txId)
      txData.contactId `shouldBe` Just contactId

    it "leaves the transaction without a contact and the dictionary unchanged when the description does not match" $ do
      (env, _externalAccId, _bankAccId, accountLink) <- setupTestEnv
      contactId <- addContact env "Acme Corp"

      let incomeTx = mkDescribedTransaction 100 "contact-no-match" "Some Other Merchant"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ importConnection interp provider testUserId accountLink testFromTime testToTime
      concatMap (.failed) result.accounts `shouldBe` []
      txId <- case concatMap (.succeeded) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"

      txData <- fromJustIO "unmatched-contact tx" =<< runDbIn env (TransactionRM.getTransaction txId)
      txData.contactId `shouldBe` Nothing

      -- The contacts dictionary is unchanged: still exactly the one
      -- pre-seeded entry, no entry auto-created for the unmatched
      -- description.
      contactIds <- userContactDictionaryEntryIds env
      contactIds `shouldBe` [contactId]
