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
import qualified Application.ReadModels.ExchangeRate as ExchangeRateRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.ReadModels.User (UserData (..), UserReadModel (..))
import Application.Services.AccountService (createAccount)
import Application.Services.BankImportService
  ( AccountResyncResult (..),
    ResyncResult (..),
    resync,
  )
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Control.Concurrent.STM as STM
import Data.List (nubBy)
import Data.Time (Day, UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
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
    Money,
    UserId,
    defaultBankAccount,
    defaultConfigurationId,
    mkMoney,
    moneyCurrency,
    unsafeExternalTransactionId,
  )
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Projection (TransactionStatus (Completed))
import Eventium (EventHandler (..), GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import Infrastructure.App (AppEnv (..), HasReadModel (..), runAppM)
import Infrastructure.Banking.Provider
  ( BankAccountId,
    BankProvider (..),
    BankTransaction (..),
    TransactionClassification (..),
  )
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (NonEmptyList (..), Positive (..), ioProperty, (===))
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
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

-- | A mock bank provider that returns the given statements and classifies
-- based on the sign of the amount.
mockProvider :: [BankTransaction] -> BankProvider
mockProvider statements =
  BankProvider
    { providerName = "mock",
      fetchAccounts = return $ Right [],
      fetchStatements = \_ _ _ -> return $ Right statements,
      registerWebhook = \_ -> return $ Right (),
      classifyTransaction = \tx ->
        if tx.amount >= 0
          then ClassifiedIncome
          else ClassifiedExpense
    }

-- | Create a bank transaction for testing. Amount is in major units.
mkTestTransaction :: Rational -> Text -> BankTransaction
mkTestTransaction amount extId =
  BankTransaction
    { externalId = unsafeExternalTransactionId extId,
      accountId = "mono-acc-1",
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

-- | Set up a full test environment with user, accounts, and link mapping.
-- Returns (env, externalAccountId, bankAccountId, link).
setupTestEnv :: IO (AppEnv, AccountId, AccountId, [(BankAccountId, AccountId)])
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

  -- Populate UserReadModel
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
        users = Map.singleton testUserId userData,
        emailIndex = Map.singleton "test@example.com" testUserId,
        telegramIndex = Map.empty,
        oauthIndex = Map.empty
      }

  let accountLink :: [(BankAccountId, AccountId)]
      accountLink = [("mono-acc-1", bankAccId)]

  return (env, externalAccId, bankAccId, accountLink)

-- | Set up a CROSS-CURRENCY test environment: the per-user External account
-- is in USD (the user's base currency) while the linked bank account is in
-- UAH (the bank-transaction currency). This is the configuration that
-- triggered the original bug: income/expense post a UAH amount to the USD
-- External leg, which the saga rejects with 'CurrencyMismatch' unless the
-- import resolves per-leg amounts + an exchange rate.
--
-- Returns (env, usdExternalAccId, uahBankAccId, link).
setupCrossCurrencyEnv :: IO (AppEnv, AccountId, AccountId, [(BankAccountId, AccountId)])
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
        users = Map.singleton testUserId userData,
        emailIndex = Map.singleton "test@example.com" testUserId,
        telegramIndex = Map.empty,
        oauthIndex = Map.empty
      }
  let accountLink :: [(BankAccountId, AccountId)]
      accountLink = [("mono-acc-1", bankAccId)]
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
  (ExchangeRateRM.handleExchangeRateEvents env.exchangeRateReadModel).handleEvent [globalEvent]

-- | The business day of 'testTime', used as the default rate date.
testDay :: Day
testDay = fromGregorian 2026 4 10

-- | Look up an account's current balance from the read model.
accountBalanceOf :: AppEnv -> AccountId -> IO Money
accountBalanceOf env accId = do
  mData <- runDbIn env (AccountRM.getAccount accId)
  d <- fromJustIO "account" mData
  pure d.balance

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
    result1 <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
    let importedIds = concatMap (.imported) result1.accounts
    length importedIds `shouldBe` 3

    -- Extract the three imported IDs (expense, income, hold-as-expense)
    case importedIds of
      [expenseId, incomeId, holdId] -> do
        -- Verify expense transfer: source = bank account, target = external
        txRM <- runAppM env $ view transactionReadModelL
        expenseData <- fromJustIO "expense transaction" =<< TransactionRM.getTransaction txRM expenseId
        expenseData.sourceAccountId `shouldBe` bankAccId
        expenseData.targetAccountId `shouldBe` externalAccId
        expenseData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 50)
        -- No MCC on tx → falls back to defaultExpenseCategory (expense.other)
        expenseData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 50))
        expenseData.description `shouldBe` "Test transaction"
        expenseData.date `shouldBe` testTime

        -- Verify income transfer: source = external, target = bank account
        incomeData <- fromJustIO "income transaction" =<< TransactionRM.getTransaction txRM incomeId
        incomeData.sourceAccountId `shouldBe` externalAccId
        incomeData.targetAccountId `shouldBe` bankAccId
        incomeData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
        -- Income always uses defaultIncomeCategory (income.other)
        incomeData.transactionType `shouldBe` singletonIncome income.other.entryId (fromRight' (mkMoney UAH 100))
        incomeData.description `shouldBe` "Test transaction"
        incomeData.date `shouldBe` testTime

        -- Verify the hold was imported as a normal expense (negative amount)
        holdData <- fromJustIO "hold transaction" =<< TransactionRM.getTransaction txRM holdId
        holdData.sourceAccountId `shouldBe` bankAccId
        holdData.targetAccountId `shouldBe` externalAccId
        holdData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 30)
        holdData.transactionType `shouldBe` singletonExpense expense.other.entryId (fromRight' (mkMoney UAH 30))

        -- Second resync (dedup): same statements should produce no new imports
        result2 <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
        concatMap (.imported) result2.accounts `shouldBe` []
        concatMap (.failures) result2.accounts `shouldBe` []
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

    result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
    length (concatMap (.imported) result.accounts) `shouldBe` 3
    concatMap (.failures) result.accounts `shouldBe` []

  prop "concurrent resyncs of the same statement produce one transfer per external id"
    $ \(txSeeds :: NonEmptyList (Positive Int)) -> ioProperty $ do
      (env, _externalAccId, _bankAccId, accountLink) <- setupTestEnv
      let txs =
            zipWith
              ( \i (Positive n) ->
                  mkSameCurrencyBankTx
                    (unsafeExternalTransactionId (T.pack ("tx-" <> show (i :: Int))))
                    "mono-acc-1"
                    (fromIntegral n)
              )
              [0 ..]
              (getNonEmpty txSeeds)
          provider = mockProvider txs
          runOnce =
            runAppM env
              $ resync provider testUserId accountLink testFromTime testToTime
          extIdOf :: BankTransaction -> ExternalTransactionId
          extIdOf t = t.externalId
          expected = length (nubBy ((==) `on` extIdOf) txs)
      (r1, r2) <- Async.concurrently runOnce runOnce
      -- Sum of imported IDs across both calls must equal the number of
      -- unique external IDs. A TOCTOU race lets two resyncs both emit for
      -- the same external id, producing a total greater than `expected`.
      let importedIn r = length (concatMap (.imported) r.accounts)
          totalImported = importedIn r1 + importedIn r2
      allTxs <- TransactionRM.getAllTransactions env.transactionReadModel
      pure
        $ (totalImported, Map.size allTxs)
        === (expected, expected)

  describe "cross-currency import (External account currency != bank tx currency)" $ do
    it "posts a cross-currency income successfully with per-leg amounts and a resolved rate" $ do
      -- USD External, UAH bank account, a published USD<->UAH rate (41).
      (env, externalAccId, bankAccId, accountLink) <- setupCrossCurrencyEnv
      seedExchangeRateAt env testDay [(USD, UAH, 41), (UAH, USD, 1 / 41)]

      let incomeTx = mkTestTransaction 100 "xc-income" -- +100 UAH income
          provider = mockProvider [incomeTx]
      result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
      concatMap (.failures) result.accounts `shouldBe` []
      txId <- case concatMap (.imported) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"

      txRM <- runAppM env $ view transactionReadModelL
      txData <- fromJustIO "income tx" =<< TransactionRM.getTransaction txRM txId
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
      result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
      concatMap (.failures) result.accounts `shouldBe` []
      expenseId <- case concatMap (.imported) result.accounts of
        [_fundId, eId] -> pure eId
        other -> expectationFailure ("expected two imported ids, got " <> show (length other)) >> error "unreachable"

      txRM <- runAppM env $ view transactionReadModelL
      txData <- fromJustIO "expense tx" =<< TransactionRM.getTransaction txRM expenseId
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
      result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
      concatMap (.failures) result.accounts `shouldBe` []
      txId <- case concatMap (.imported) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"

      txRM <- runAppM env $ view transactionReadModelL
      txData <- fromJustIO "income tx" =<< TransactionRM.getTransaction txRM txId
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
      result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
      concatMap (.imported) result.accounts `shouldBe` []
      length (concatMap (.failures) result.accounts) `shouldBe` 1

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
            users = Map.singleton testUserId userData,
            emailIndex = Map.singleton "test@example.com" testUserId,
            telegramIndex = Map.empty,
            oauthIndex = Map.empty
          }
      let accountLink :: [(BankAccountId, AccountId)]
          accountLink = [("mono-acc-1", bankAccId)]

      -- A UAH transaction (currencyCode 980) mapped to a USD account.
      let incomeTx = mkTestTransaction 100 "xc-mismatch"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
      -- Skipped, not imported, not failed.
      concatMap (.imported) result.accounts `shouldBe` []
      concatMap (.failures) result.accounts `shouldBe` []
      sum (map (.skipped) result.accounts) `shouldBe` 1
      -- No transaction was ever initiated.
      allTxs <- TransactionRM.getAllTransactions env.transactionReadModel
      Map.size allTxs `shouldBe` 0
      -- The account balance is unchanged.
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney USD 0)

    it "same-currency import is unchanged: exchangeRate Nothing and equal amounts" $ do
      -- Guard against regression: UAH External + UAH bank → no rate, amounts equal.
      (env, _externalAccId, bankAccId, accountLink) <- setupTestEnv
      let incomeTx = mkTestTransaction 100 "xc-same"
          provider = mockProvider [incomeTx]
      result <- runAppM env $ resync provider testUserId accountLink testFromTime testToTime
      concatMap (.failures) result.accounts `shouldBe` []
      txId <- case concatMap (.imported) result.accounts of
        [i] -> pure i
        other -> expectationFailure ("expected one imported id, got " <> show (length other)) >> error "unreachable"
      txRM <- runAppM env $ view transactionReadModelL
      txData <- fromJustIO "income tx" =<< TransactionRM.getTransaction txRM txId
      txData.exchangeRate `shouldBe` Nothing
      txData.sourceAmount `shouldBe` txData.targetAmount
      txData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
      txData.status `shouldBe` Completed
      bankBalance <- accountBalanceOf env bankAccId
      bankBalance `shouldBe` fromRight' (mkMoney UAH 100)
