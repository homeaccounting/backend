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

import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.AccountService (createAccount)
import Application.Services.TransactionService
import Data.Ratio ((%))
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Domain.Transaction.Commands (InitiateTransfer (..))
import Infrastructure.App (AppEnv (..), AppM, runAppM)
import Infrastructure.ExchangeRate.Provider (ExchangeRateCache, ExchangeRateMap, RateProvider (..), newExchangeRateCache, refreshCache)
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (fromRight', mockExchangeRate, mockMoney, mockMoneyWith, mockUserId, shouldBeLeft, shouldBeRight)
import Testkit.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid1 :: UUID
testUserUuid1 = UUID.fromWords 1 0 0 0

testUserId1 :: UserId
testUserId1 = mockUserId testUserUuid1

mkCreateAccount :: Text -> UserId -> AccountKind -> CreateAccount
mkCreateAccount acctName userId kind =
  CreateAccount
    { name = acctName,
      initialBalance = mockMoney 5000,
      createdBy = userId,
      kind = kind,
      overdraftLimit = Nothing
    }

mkCreateAccountWith :: Currency -> Rational -> Text -> UserId -> AccountKind -> CreateAccount
mkCreateAccountWith currency balance acctName userId kind =
  CreateAccount
    { name = acctName,
      initialBalance = mockMoneyWith currency balance,
      createdBy = userId,
      kind = kind,
      overdraftLimit = Nothing
    }

-- | Create a mock provider that returns fixed rates.
mockRateProvider :: ExchangeRateMap -> RateProvider
mockRateProvider rates =
  RateProvider
    { providerName = "Mock",
      fetchRates = pure (Right rates)
    }

-- | Create a test exchange rate cache pre-populated with known rates.
mkTestExchangeRateCache :: [(Currency, Currency, Rational)] -> IO ExchangeRateCache
mkTestExchangeRateCache rates = do
  let rateMap = Map.fromList [((src, tgt), mockExchangeRate src tgt r) | (src, tgt, r) <- rates]
  cache <- newExchangeRateCache (mockRateProvider rateMap)
  -- Force a refresh to populate the cache
  void $ refreshCache cache
  return cache

-- | Create a test env with a pre-populated exchange rate cache.
createTestAppEnvWithRates :: [(Currency, Currency, Rational)] -> IO AppEnv
createTestAppEnvWithRates rates = do
  env <- createTestAppEnv
  cache <- mkTestExchangeRateCache rates
  return env {exchangeRateCache = cache}

-- | Helper to create two accounts in different currencies.
setupCrossCurrencyAccounts :: [(Currency, Currency, Rational)] -> Currency -> Currency -> IO (AppEnv, AccountId, AccountId)
setupCrossCurrencyAccounts rates srcCurrency tgtCurrency = do
  env <- createTestAppEnvWithRates rates
  (fromAccId, toAccId) <- runAppM env $ do
    result1 <- createAccount (mkCreateAccountWith srcCurrency 5000 "Source" testUserId1 (Regular defaultCash))
    let (fromId, _) = fromRight' result1
    result2 <- createAccount (mkCreateAccountWith tgtCurrency 5000 "Target" testUserId1 (Regular defaultCash))
    let (toId, _) = fromRight' result2
    return (fromId, toId)
  return (env, fromAccId, toAccId)

-- | Helper to create two accounts and return their IDs for transfer tests.
setupTwoAccounts :: IO (AppEnv, AccountId, AccountId)
setupTwoAccounts = do
  env <- createTestAppEnv
  (fromAccId, toAccId) <- runAppM env $ do
    result1 <- createAccount (mkCreateAccount "Source" testUserId1 (Regular defaultCash))
    let (fromId, _) = fromRight' result1
    result2 <- createAccount (mkCreateAccount "Target" testUserId1 (Regular defaultCash))
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
              { fromAccountId = fromAccId,
                toAccountId = toAccId,
                sourceAmount = mockMoney 100,
                targetAmount = mockMoney 100,
                exchangeRate = Nothing,
                reason = "Test transfer",
                initiatedBy = testUserId1,
                transferType = InternalTransfer,
                category = InternalCat
              }
      result <- runAppM env $ initiateTransfer transferCmd
      shouldBeRight result
      let (_, summary) = fromRight' result
      summary.fromAccountId `shouldBe` fromAccId
      summary.toAccountId `shouldBe` toAccId
      summary.sourceAmount `shouldBe` mockMoney 100
      summary.reason `shouldBe` "Test transfer"

  describe "getTransaction" $ do
    it "retrieves a previously created transaction" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts
      let transferCmd =
            InitiateTransfer
              { fromAccountId = fromAccId,
                toAccountId = toAccId,
                sourceAmount = mockMoney 250,
                targetAmount = mockMoney 250,
                exchangeRate = Nothing,
                reason = "Retrieve test",
                initiatedBy = testUserId1,
                transferType = InternalTransfer,
                category = InternalCat
              }
      createResult <- runAppM env $ initiateTransfer transferCmd
      let (txId, _) = fromRight' createResult
      result <- runAppM env $ getTransaction (unTransactionId txId)
      shouldBeRight result
      let (retId, summary) = fromRight' result
      retId `shouldBe` txId
      summary.sourceAmount `shouldBe` mockMoney 250
      summary.reason `shouldBe` "Retrieve test"

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
      let mkTransferCmd amt rsn =
            InitiateTransfer
              { fromAccountId = fromAccId,
                toAccountId = toAccId,
                sourceAmount = mockMoney amt,
                targetAmount = mockMoney amt,
                exchangeRate = Nothing,
                reason = rsn,
                initiatedBy = testUserId1,
                transferType = InternalTransfer,
                category = InternalCat
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
      s1.reason `shouldBe` "First"
      s2.reason `shouldBe` "Second"

  describe "initiateInternalTransfer (cross-currency)" $ do
    it "converts USD to EUR using cached exchange rate" $ do
      -- USD -> EUR at rate 9/10 (i.e. 1 USD = 0.9 EUR, exact rational)
      let rates = [(USD, EUR, 9 % 10), (EUR, USD, 10 % 9)]
      (env, fromAccId, toAccId) <- setupCrossCurrencyAccounts rates USD EUR

      result <- runAppM env $ initiateInternalTransfer testUserId1 fromAccId toAccId (mockMoneyWith USD 100) "Cross-currency transfer" Nothing
      shouldBeRight result
      let (_, summary) = fromRight' result
      -- Source: 100 USD, Target: 90 EUR (100 * 9/10)
      summary.sourceAmount `shouldBe` mockMoneyWith USD 100
      summary.targetAmount `shouldBe` mockMoneyWith EUR 90
      summary.exchangeRate `shouldSatisfy` isJust

    it "skips conversion for same-currency transfer" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts -- both USD
      result <- runAppM env $ initiateInternalTransfer testUserId1 fromAccId toAccId (mockMoney 100) "Same currency" Nothing
      shouldBeRight result
      let (_, summary) = fromRight' result
      summary.sourceAmount `shouldBe` mockMoney 100
      summary.targetAmount `shouldBe` mockMoney 100
      summary.exchangeRate `shouldSatisfy` isNothing

    it "uses user-provided exchange rate instead of cache" $ do
      -- Cache has USD->EUR at 9/10, but user provides 17/20 (0.85 exact)
      let rates = [(USD, EUR, 9 % 10), (EUR, USD, 10 % 9)]
      (env, fromAccId, toAccId) <- setupCrossCurrencyAccounts rates USD EUR

      result <- runAppM env $ initiateInternalTransfer testUserId1 fromAccId toAccId (mockMoneyWith USD 100) "User rate" (Just (17 % 20))
      shouldBeRight result
      let (_, summary) = fromRight' result
      summary.sourceAmount `shouldBe` mockMoneyWith USD 100
      summary.targetAmount `shouldBe` mockMoneyWith EUR 85
      summary.exchangeRate `shouldSatisfy` isJust

    it "returns ExchangeRateUnavailable when rate not found" $ do
      -- Cache has rates but NOT for USD->EUR (only GBP->EUR)
      let rates = [(GBP, EUR, 6 % 5)]
      (env, fromAccId, toAccId) <- setupCrossCurrencyAccounts rates USD EUR

      result <- runAppM env $ initiateInternalTransfer testUserId1 fromAccId toAccId (mockMoneyWith USD 100) "No rate for pair" Nothing
      shouldBeLeft result
      case result of
        Left (ExchangeRateUnavailable _) -> pure ()
        Left err -> expectationFailure $ "Expected ExchangeRateUnavailable, got: " <> show err
        Right _ -> expectationFailure "Expected Left"
