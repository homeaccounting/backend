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

import Application.ReadModels.ExchangeRate (applyExchangeRateEvent)
import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.AccountService (createAccount)
import Application.Services.TransactionService
import Data.Ratio ((%))
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, utctDay)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Commands (InitiateTransactionPosting (..))
import Eventium (GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (fromRight', mockExchangeRate, mockMoney, mockMoneyWith, mockUserId, shouldBeLeft, shouldBeRight)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid1 :: UUID
testUserUuid1 = UUID.fromWords 1 0 0 0

testUserId1 :: UserId
testUserId1 = mockUserId testUserUuid1

-- | Fixed business time used for transfer fixtures.
mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

mkCreateAccount :: Text -> UserId -> AccountType -> CreateAccount
mkCreateAccount acctName userId accountType =
  CreateAccount
    { name = acctName,
      initialBalance = mockMoney 5000,
      createdBy = userId,
      accountType = accountType,
      overdraftLimit = Nothing
    }

mkCreateAccountWith :: Currency -> Rational -> Text -> UserId -> AccountType -> CreateAccount
mkCreateAccountWith currency balance acctName userId accountType =
  CreateAccount
    { name = acctName,
      initialBalance = mockMoneyWith currency balance,
      createdBy = userId,
      accountType = accountType,
      overdraftLimit = Nothing
    }

-- | Create a test env whose exchange-rate read model is pre-populated
-- with the supplied rates for today under the default ECB provider
-- name used by 'createTestAppEnv'. Feeds a synthetic
-- 'ExchangeRatesPublishedEvent' through 'applyExchangeRateEvent' so
-- the projection sees the rates exactly as it would in production.
createTestAppEnvWithRates :: [(Currency, Currency, Rational)] -> IO AppEnv
createTestAppEnvWithRates rates = do
  env <- createTestAppEnv
  today <- utctDay <$> getCurrentTime
  let rateMap = Map.fromList [((src, tgt), mockExchangeRate src tgt r) | (src, tgt, r) <- rates]
      providerName = env.config.exchangeRate.provider
      payload =
        ExchangeRatesPublishedEvent
          ExchangeRatesPublished
            { provider = providerName,
              rates = rateMap,
              at = today
            }
      versionedEvent = StreamEvent UUID.nil 0 (emptyMetadata mempty) payload
      globalEvent :: GlobalStreamEvent AccountingEvent
      globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
  runDbIn env (applyExchangeRateEvent globalEvent)
  pure env

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
  describe "initiateTransaction" $ do
    it "creates a transfer and returns TransactionId and TransactionData" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts
      let transferCmd =
            InitiateTransactionPosting
              { sourceAccountId = fromAccId,
                targetAccountId = toAccId,
                sourceAmount = mockMoney 100,
                targetAmount = mockMoney 100,
                exchangeRate = Nothing,
                description = "Test transfer",
                initiatedBy = testUserId1,
                at = mockTime,
                transactionType = Transfer,
                importInfo = Nothing,
                labels = Set.empty,
                contactId = Nothing,
                relation = Nothing
              }
      result <- runAppM env $ initiateTransaction transferCmd
      shouldBeRight result
      let (_, transaction) = fromRight' result
      transaction.sourceAccountId `shouldBe` fromAccId
      transaction.targetAccountId `shouldBe` toAccId
      transaction.sourceAmount `shouldBe` mockMoney 100
      transaction.description `shouldBe` "Test transfer"

  describe "getTransaction" $ do
    it "retrieves a previously created transaction" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts
      let transferCmd =
            InitiateTransactionPosting
              { sourceAccountId = fromAccId,
                targetAccountId = toAccId,
                sourceAmount = mockMoney 250,
                targetAmount = mockMoney 250,
                exchangeRate = Nothing,
                description = "Retrieve test",
                initiatedBy = testUserId1,
                at = mockTime,
                transactionType = Transfer,
                importInfo = Nothing,
                labels = Set.empty,
                contactId = Nothing,
                relation = Nothing
              }
      createResult <- runAppM env $ initiateTransaction transferCmd
      let (txId, _) = fromRight' createResult
      result <- runAppM env $ getTransaction (unTransactionId txId)
      shouldBeRight result
      let (retId, transaction) = fromRight' result
      retId `shouldBe` txId
      transaction.sourceAmount `shouldBe` mockMoney 250
      transaction.description `shouldBe` "Retrieve test"

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
            InitiateTransactionPosting
              { sourceAccountId = fromAccId,
                targetAccountId = toAccId,
                sourceAmount = mockMoney amt,
                targetAmount = mockMoney amt,
                exchangeRate = Nothing,
                description = rsn,
                initiatedBy = testUserId1,
                at = mockTime,
                transactionType = Transfer,
                importInfo = Nothing,
                labels = Set.empty,
                contactId = Nothing,
                relation = Nothing
              }
      result1 <- runAppM env $ initiateTransaction (mkTransferCmd 100 "First")
      result2 <- runAppM env $ initiateTransaction (mkTransferCmd 200 "Second")
      let (txId1, _) = fromRight' result1
      let (txId2, _) = fromRight' result2

      getResult1 <- runAppM env $ getTransaction (unTransactionId txId1)
      getResult2 <- runAppM env $ getTransaction (unTransactionId txId2)

      shouldBeRight getResult1
      shouldBeRight getResult2

      let (_, s1) = fromRight' getResult1
      let (_, s2) = fromRight' getResult2
      s1.description `shouldBe` "First"
      s2.description `shouldBe` "Second"

  describe "initiateTransfer (cross-currency)" $ do
    it "converts USD to EUR using cached exchange rate" $ do
      -- USD -> EUR at rate 9/10 (i.e. 1 USD = 0.9 EUR, exact rational)
      let rates = [(USD, EUR, 9 % 10), (EUR, USD, 10 % 9)]
      (env, fromAccId, toAccId) <- setupCrossCurrencyAccounts rates USD EUR

      now <- getCurrentTime
      result <- runAppM env $ initiateTransfer testUserId1 fromAccId toAccId (mockMoneyWith USD 100) Set.empty "Cross-currency transfer" Nothing (Just now) Nothing
      shouldBeRight result
      let (_, transaction) = fromRight' result
      -- Source: 100 USD, Target: 90 EUR (100 * 9/10)
      transaction.sourceAmount `shouldBe` mockMoneyWith USD 100
      transaction.targetAmount `shouldBe` mockMoneyWith EUR 90
      transaction.exchangeRate `shouldSatisfy` isJust

    it "skips conversion for same-currency transfer" $ do
      (env, fromAccId, toAccId) <- setupTwoAccounts -- both USD
      now <- getCurrentTime
      result <- runAppM env $ initiateTransfer testUserId1 fromAccId toAccId (mockMoney 100) Set.empty "Same currency" Nothing (Just now) Nothing
      shouldBeRight result
      let (_, transaction) = fromRight' result
      transaction.sourceAmount `shouldBe` mockMoney 100
      transaction.targetAmount `shouldBe` mockMoney 100
      transaction.exchangeRate `shouldSatisfy` isNothing

    it "uses user-provided exchange rate instead of cache" $ do
      -- Cache has USD->EUR at 9/10, but user provides 17/20 (0.85 exact)
      let rates = [(USD, EUR, 9 % 10), (EUR, USD, 10 % 9)]
      (env, fromAccId, toAccId) <- setupCrossCurrencyAccounts rates USD EUR

      now <- getCurrentTime
      result <- runAppM env $ initiateTransfer testUserId1 fromAccId toAccId (mockMoneyWith USD 100) Set.empty "User rate" (Just (17 % 20)) (Just now) Nothing
      shouldBeRight result
      let (_, transaction) = fromRight' result
      transaction.sourceAmount `shouldBe` mockMoneyWith USD 100
      transaction.targetAmount `shouldBe` mockMoneyWith EUR 85
      transaction.exchangeRate `shouldSatisfy` isJust

    it "returns ExchangeRateUnavailable when rate not found" $ do
      -- Cache has rates but NOT for USD->EUR (only GBP->EUR)
      let rates = [(GBP, EUR, 6 % 5)]
      (env, fromAccId, toAccId) <- setupCrossCurrencyAccounts rates USD EUR

      now <- getCurrentTime
      result <- runAppM env $ initiateTransfer testUserId1 fromAccId toAccId (mockMoneyWith USD 100) Set.empty "No rate for pair" Nothing (Just now) Nothing
      shouldBeLeft result
      case result of
        Left (ExchangeRateUnavailable _) -> pure ()
        Left err -> expectationFailure $ "Expected ExchangeRateUnavailable, got: " <> show err
        Right _ -> expectationFailure "Expected Left"
