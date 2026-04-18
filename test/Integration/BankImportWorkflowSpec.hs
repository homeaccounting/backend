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

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.ReadModels.User (UserData (..), UserReadModel (..))
import Application.Services.AccountService (createAccount)
import Application.Services.BankImportService
  ( AccountResyncResult (..),
    ResyncResult (..),
    resync,
  )
import qualified Control.Concurrent.STM as STM
import Data.List (nubBy)
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    DictionaryEntryId,
    ExternalTransactionId,
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
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (NonEmptyList (..), Positive (..), ioProperty, (===))
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Helpers
  ( fromRight',
    mockDictionaryEntryId,
    mockMoneyWith,
    mockUserId,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
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

testDefaultCategoryUuid :: UUID
testDefaultCategoryUuid = UUID.fromWords 40 0 0 0

testDefaultCategory :: DictionaryEntryId
testDefaultCategory = mockDictionaryEntryId testDefaultCategoryUuid

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
          then ClassifiedIncome Nothing
          else ClassifiedExpense Nothing
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
            -- Without an overdraft, every transfer would emit TransferFailed
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
        summaryData = Map.singleton testUserId userData,
        emailIndex = Map.singleton "test@example.com" testUserId,
        telegramIndex = Map.empty,
        oauthIndex = Map.empty
      }

  let accountLink :: [(BankAccountId, AccountId)]
      accountLink = [("mono-acc-1", bankAccId)]

  return (env, externalAccId, bankAccId, accountLink)

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Bank Import Workflow" $ do
  it "imports transactions and deduplicates on re-run" $ do
    (env, externalAccId, bankAccId, accountLink) <- setupTestEnv

    -- Mock statements: 1 expense, 1 income, 1 hold (should be skipped)
    let expenseTx = mkTestTransaction (-50) "tx-expense-1"
        incomeTx = mkTestTransaction 100 "tx-income-1"
        holdTx = mkHoldTransaction (-30) "tx-hold-1"
        statements = [expenseTx, incomeTx, holdTx]
        provider = mockProvider statements

    -- First resync: should import 2 transactions (hold skipped)
    result1 <- runAppM env $ resync provider testUserId accountLink testDefaultCategory testFromTime testToTime
    let importedIds = concatMap (.imported) result1.accounts
    length importedIds `shouldBe` 2

    -- Extract the two imported IDs
    case importedIds of
      [expenseId, incomeId] -> do
        -- Verify expense transfer: source = bank account, target = external
        txRM <- runAppM env $ view transactionReadModelL
        expenseData <- fromJustIO "expense transaction" =<< TransactionRM.getTransaction txRM expenseId
        expenseData.sourceAccountId `shouldBe` bankAccId
        expenseData.targetAccountId `shouldBe` externalAccId
        expenseData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 50)
        expenseData.transferType `shouldBe` Expense testDefaultCategory
        expenseData.description `shouldBe` "Test transaction"
        expenseData.date `shouldBe` testTime

        -- Verify income transfer: source = external, target = bank account
        incomeData <- fromJustIO "income transaction" =<< TransactionRM.getTransaction txRM incomeId
        incomeData.sourceAccountId `shouldBe` externalAccId
        incomeData.targetAccountId `shouldBe` bankAccId
        incomeData.sourceAmount `shouldBe` fromRight' (mkMoney UAH 100)
        incomeData.transferType `shouldBe` Income testDefaultCategory
        incomeData.description `shouldBe` "Test transaction"
        incomeData.date `shouldBe` testTime

        -- Second resync (dedup): same statements should produce no new imports
        result2 <- runAppM env $ resync provider testUserId accountLink testDefaultCategory testFromTime testToTime
        concatMap (.imported) result2.accounts `shouldBe` []
        concatMap (.failures) result2.accounts `shouldBe` []
      _ -> expectationFailure $ "Expected exactly 2 imported IDs, got " <> show (length importedIds)

  it "skips all hold transactions" $ do
    (env, _externalAccId, _bankAccId, accountLink) <- setupTestEnv

    -- All statements are holds
    let statements =
          [ mkHoldTransaction (-10) "hold-1",
            mkHoldTransaction 20 "hold-2",
            mkHoldTransaction (-5) "hold-3"
          ]
        provider = mockProvider statements

    result <- runAppM env $ resync provider testUserId accountLink testDefaultCategory testFromTime testToTime
    concatMap (.imported) result.accounts `shouldBe` []
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
              $ resync provider testUserId accountLink testDefaultCategory testFromTime testToTime
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
