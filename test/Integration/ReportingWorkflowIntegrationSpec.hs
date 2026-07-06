{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.ReportingWorkflowIntegrationSpec
-- Description : Integration tests for the reporting service orchestration
--
-- These tests exercise the reporting service functions
-- ('incomeVsExpense', 'spendingByCategory') end-to-end through the event
-- store, command handlers, process manager (saga), projections, and read
-- models using in-memory stores.
--
-- The flow:
--   1. Create an in-memory PM-enabled test environment
--   2. Create an External account and a Regular account owned by one user
--   3. Post one categorised income (External -> Regular) and one categorised
--      expense (Regular -> External); the saga drives both to 'Completed'
--   4. Run the reporting service inside 'runRIO' and assert the aggregates
module Integration.ReportingWorkflowIntegrationSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..), getTransaction)
import Application.Services.ExchangeRatePublisher (publishRates)
import qualified Application.Services.ReportingService as ReportingService
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler
  ( AccountCommand
      ( CreateAccountAccountCommand,
        ShareAccountAccountCommand
      ),
  )
import Domain.Account.Commands (CreateAccount (..), ShareAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountRole (..),
    AccountType (..),
    Currency (..),
    DictionaryEntryId,
    ExchangeRate,
    TransactionType,
    defaultCash,
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeExchangeRate,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.ExchangeRate.Events (ExchangeRateMap, Provider)
import Domain.Transaction.CommandHandler
  ( TransactionCommand (InitiateTransactionTransactionCommand),
  )
import Domain.Transaction.Commands (InitiateTransaction (..))
import Domain.Transaction.Projection (TransactionStatus (..))
import Infrastructure.App (AppEnv (..))
import Infrastructure.Eventium (applyAccountCommand, applyTransactionCommand)
import Infrastructure.ExchangeRate.Provider (RateProvider (..))
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Testkit.Helpers (mockExchangeRate, singletonExpense, singletonIncome)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Web.API.ReportingAPI (incomeVsExpenseHandler)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types (IncomeVsExpenseResponse (..))

-- | Fixed business time used for reporting fixtures.
mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

-- | Test category for "Salary" income.
testSalaryCatId :: DictionaryEntryId
testSalaryCatId = unsafeDictionaryEntryId (UUID.fromWords 100 0 0 1)

-- | Test category for "Rent" expense.
testRentCatId :: DictionaryEntryId
testRentCatId = unsafeDictionaryEntryId (UUID.fromWords 200 0 0 2)

-- | Provision a PM-enabled env with an External and a Regular account owned
-- by a single user. Returns the env plus the user, external, and regular
-- account UUIDs.
setupReportingEnv :: IO (AppEnv, UUID, UUID, UUID)
setupReportingEnv = do
  env <- createTestAppEnvWithProcessManager
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader

  userUuid <- UUID.nextRandom
  extUuid <- UUID.nextRandom
  regUuid <- UUID.nextRandom

  _ <-
    applyAccountCommand writer reader id extUuid
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "External",
            initialBalance = unsafeMoney USD 0,
            createdBy = unsafeUserId userUuid,
            accountType = External,
            overdraftLimit = Nothing
          }

  _ <-
    applyAccountCommand writer reader id regUuid
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "Wallet",
            initialBalance = unsafeMoney USD 1000,
            createdBy = unsafeUserId userUuid,
            accountType = Regular defaultCash,
            overdraftLimit = Nothing
          }

  return (env, userUuid, extUuid, regUuid)

-- | Issue a single InitiateTransaction and rely on the saga to complete it.
postTransaction ::
  AppEnv ->
  UUID ->
  UUID ->
  UUID ->
  Rational ->
  Currency ->
  Text ->
  TransactionType ->
  IO UUID
postTransaction env fromUuid toUuid userUuid amt cur desc txType = do
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader
  txUuid <- UUID.nextRandom
  _ <-
    applyTransactionCommand writer reader id txUuid
      $ InitiateTransactionTransactionCommand
        InitiateTransaction
          { sourceAccountId = unsafeAccountId fromUuid,
            targetAccountId = unsafeAccountId toUuid,
            sourceAmount = unsafeMoney cur amt,
            targetAmount = unsafeMoney cur amt,
            exchangeRate = Nothing,
            description = desc,
            initiatedBy = unsafeUserId userUuid,
            at = mockTime,
            transactionType = txType,
            externalTransactionId = Nothing,
            labels = Set.empty,
            relation = Nothing
          }
  return txUuid

-- | Issue a cross-currency InitiateTransaction with explicit, distinct legs.
--
-- Unlike 'postTransaction' (which posts equal same-currency legs), this lets
-- the regular and external legs carry different currencies and amounts plus an
-- explicit 'ExchangeRate'. The saga debits the source by @srcAmt\/srcCur@ and
-- credits the target by @tgtAmt\/tgtCur@, so each account's currency must match
-- its leg. Allocations are denominated in the regular-leg currency.
postCrossCurrencyTransaction ::
  AppEnv ->
  UUID ->
  UUID ->
  UUID ->
  (Rational, Currency) ->
  (Rational, Currency) ->
  ExchangeRate ->
  Text ->
  TransactionType ->
  IO UUID
postCrossCurrencyTransaction env fromUuid toUuid userUuid (srcAmt, srcCur) (tgtAmt, tgtCur) rate desc txType = do
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader
  txUuid <- UUID.nextRandom
  _ <-
    applyTransactionCommand writer reader id txUuid
      $ InitiateTransactionTransactionCommand
        InitiateTransaction
          { sourceAccountId = unsafeAccountId fromUuid,
            targetAccountId = unsafeAccountId toUuid,
            sourceAmount = unsafeMoney srcCur srcAmt,
            targetAmount = unsafeMoney tgtCur tgtAmt,
            exchangeRate = Just rate,
            description = desc,
            initiatedBy = unsafeUserId userUuid,
            at = mockTime,
            transactionType = txType,
            externalTransactionId = Nothing,
            labels = Set.empty,
            relation = Nothing
          }
  return txUuid

-- | Grant @granteeUuid@ the given role on the account owned by @ownerUuid@.
shareAccount :: AppEnv -> UUID -> UUID -> AccountRole -> UUID -> IO ()
shareAccount env accUuid ownerUuid role granteeUuid = do
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader
  _ <-
    applyAccountCommand writer reader id accUuid
      $ ShareAccountAccountCommand
        ShareAccount
          { userId = unsafeUserId granteeUuid,
            role = role,
            grantedBy = unsafeUserId ownerUuid
          }
  return ()

-- | Create a Regular, Opened account with an explicit owner, currency, and
-- starting balance. Returns the new account UUID.
createRegularAccount :: AppEnv -> UUID -> Currency -> Rational -> IO UUID
createRegularAccount env ownerUuid cur initial = do
  let writer = env.eventStoreWriter
      reader = env.eventStoreReader
  accUuid <- UUID.nextRandom
  _ <-
    applyAccountCommand writer reader id accUuid
      $ CreateAccountAccountCommand
        CreateAccount
          { name = "Wallet",
            initialBalance = unsafeMoney cur initial,
            createdBy = unsafeUserId ownerUuid,
            accountType = Regular defaultCash,
            overdraftLimit = Nothing
          }
  return accUuid

-- | Publish a single fixed rate for the test provider ("ecb", per
-- 'Testkit.InMemoryEventStore.testAppConfig') through the event store. The
-- synchronous writer projects the resulting 'ExchangeRatesPublishedEvent' into
-- the persistent @exchange_rates@ read model, which is what 'netWorth' consults.
publishFixedRate :: AppEnv -> Currency -> Currency -> Rational -> IO ()
publishFixedRate env src tgt rate = do
  let rates :: ExchangeRateMap
      rates = Map.singleton (src, tgt) (mockExchangeRate src tgt rate)
      prov =
        RateProvider
          { providerName = "ecb" :: Provider,
            fetchRates = pure (Right rates)
          }
  result <-
    publishRates
      prov
      env.eventStoreWriter
      env.eventStoreReader
      env.dbPool
  result `shouldBe` Right ()

-- | Assert a transaction reached 'Completed' in the read model.
expectCompleted :: AppEnv -> UUID -> IO ()
expectCompleted env txUuid = do
  maybeTx <- runDbIn env (getTransaction (unsafeTransactionId txUuid))
  case maybeTx of
    Nothing -> expectationFailure "Transaction not found in read model"
    Just txData -> txData.status `shouldBe` Completed

spec :: Spec
spec = describe "Reporting Workflow Integration" $ do
  it "incomeVsExpense aggregates completed income and expense in base currency" $ do
    (env, userUuid, extUuid, regUuid) <- setupReportingEnv

    -- Income: External -> Regular, salary 500
    incomeTx <-
      postTransaction
        env
        extUuid
        regUuid
        userUuid
        500
        USD
        "Salary"
        (singletonIncome testSalaryCatId (unsafeMoney USD 500))
    -- Expense: Regular -> External, rent 200
    expenseTx <-
      postTransaction
        env
        regUuid
        extUuid
        userUuid
        200
        USD
        "Rent"
        (singletonExpense testRentCatId (unsafeMoney USD 200))

    expectCompleted env incomeTx
    expectCompleted env expenseTx

    let userId = unsafeUserId userUuid
    (inc, expn, net) <- runRIO env (ReportingService.incomeVsExpense userId Nothing Nothing)
    inc `shouldBe` unsafeMoney USD 500
    expn `shouldBe` unsafeMoney USD 200
    net `shouldBe` unsafeMoney USD 300

    -- Exercise the HTTP handler path end-to-end (handler -> service -> DTO).
    let authUser = AuthenticatedUser {userId = userId, email = "reporter@example.com"}
    resp <- runRIO env (incomeVsExpenseHandler authUser Nothing Nothing)
    resp.income `shouldBe` unsafeMoney USD 500
    resp.expense `shouldBe` unsafeMoney USD 200
    resp.net `shouldBe` unsafeMoney USD 300

  it "spendingByCategory totals the expense category in base currency" $ do
    (env, userUuid, extUuid, regUuid) <- setupReportingEnv

    incomeTx <-
      postTransaction
        env
        extUuid
        regUuid
        userUuid
        500
        USD
        "Salary"
        (singletonIncome testSalaryCatId (unsafeMoney USD 500))
    expenseTx <-
      postTransaction
        env
        regUuid
        extUuid
        userUuid
        200
        USD
        "Rent"
        (singletonExpense testRentCatId (unsafeMoney USD 200))

    expectCompleted env incomeTx
    expectCompleted env expenseTx

    let userId = unsafeUserId userUuid
    (total, perCat) <- runRIO env (ReportingService.spendingByCategory userId Nothing Nothing)
    total `shouldBe` unsafeMoney USD 200
    lookup testRentCatId perCat `shouldBe` Just (unsafeMoney USD 200)

  it "normalises a cross-currency expense and income to base currency" $ do
    -- Base currency is USD (default config). The user holds a EUR Regular
    -- account; the External account is USD. We post cross-currency legs with
    -- an explicit EUR->USD rate of 2.0 (exactly representable as a Double, so
    -- it survives the rate event's JSON round-trip) and assert the reports
    -- normalise to base via the transaction's own external leg.
    env <- createTestAppEnvWithProcessManager
    let writer = env.eventStoreWriter
        reader = env.eventStoreReader
    userUuid <- UUID.nextRandom
    extUuid <- UUID.nextRandom
    _ <-
      applyAccountCommand writer reader id extUuid
        $ CreateAccountAccountCommand
          CreateAccount
            { name = "External",
              initialBalance = unsafeMoney USD 0,
              createdBy = unsafeUserId userUuid,
              accountType = External,
              overdraftLimit = Nothing
            }
    eurUuid <- createRegularAccount env userUuid EUR 1000

    -- Publish the EUR->USD rate (the net-worth path consults this; here it
    -- documents the rate the legs encode). Rate 2.0: 1 EUR = 2 USD.
    publishFixedRate env EUR USD 2.0
    let eurUsd = unsafeExchangeRate EUR USD 2.0

    -- Cross-currency expense: Regular(EUR) -> External(USD). Regular leg is
    -- 100 EUR; external (base) leg is 200 USD. Allocations are in EUR.
    expenseTx <-
      postCrossCurrencyTransaction
        env
        eurUuid
        extUuid
        userUuid
        (100, EUR)
        (200, USD)
        eurUsd
        "Groceries abroad"
        (singletonExpense testRentCatId (unsafeMoney EUR 100))
    -- Cross-currency income: External(USD) -> Regular(EUR). Regular leg is
    -- 300 EUR; external (base) leg is 600 USD. Allocations are in EUR.
    incomeTx <-
      postCrossCurrencyTransaction
        env
        extUuid
        eurUuid
        userUuid
        (600, USD)
        (300, EUR)
        eurUsd
        "Foreign salary"
        (singletonIncome testSalaryCatId (unsafeMoney EUR 300))

    expectCompleted env expenseTx
    expectCompleted env incomeTx

    let userId = unsafeUserId userUuid
    -- spendingByCategory: the EUR 100 expense reports as its USD external leg, 200.
    (total, perCat) <- runRIO env (ReportingService.spendingByCategory userId Nothing Nothing)
    total `shouldBe` unsafeMoney USD 200
    lookup testRentCatId perCat `shouldBe` Just (unsafeMoney USD 200)

    -- incomeVsExpense: income normalises to 600 USD, expense to 200 USD.
    (inc, expn, net) <- runRIO env (ReportingService.incomeVsExpense userId Nothing Nothing)
    inc `shouldBe` unsafeMoney USD 600
    expn `shouldBe` unsafeMoney USD 200
    net `shouldBe` unsafeMoney USD 400

  it "includes shared-account txns in reports but excludes them from net worth" $ do
    -- The test user is GRANTED Editor access to an account OWNED by another
    -- user. Reporting (income/expense, spending) is accessible-scoped, so the
    -- shared account's transactions appear; net worth is owner-scoped, so the
    -- shared account is excluded.
    env <- createTestAppEnvWithProcessManager
    let writer = env.eventStoreWriter
        reader = env.eventStoreReader
    userUuid <- UUID.nextRandom
    otherUuid <- UUID.nextRandom

    -- An account the test user owns (USD base) so net worth is non-empty.
    ownedUuid <- createRegularAccount env userUuid USD 500

    -- An External account owned by the other user, plus a Regular account also
    -- owned by the other user, shared TO the test user as Editor.
    extUuid <- UUID.nextRandom
    _ <-
      applyAccountCommand writer reader id extUuid
        $ CreateAccountAccountCommand
          CreateAccount
            { name = "External",
              initialBalance = unsafeMoney USD 0,
              createdBy = unsafeUserId otherUuid,
              accountType = External,
              overdraftLimit = Nothing
            }
    sharedUuid <- createRegularAccount env otherUuid USD 1000
    shareAccount env sharedUuid otherUuid Editor userUuid

    -- The other user posts an expense on the shared account: Regular -> External.
    expenseTx <-
      postTransaction
        env
        sharedUuid
        extUuid
        otherUuid
        150
        USD
        "Shared rent"
        (singletonExpense testRentCatId (unsafeMoney USD 150))
    expectCompleted env expenseTx

    let userId = unsafeUserId userUuid

    -- Accessible-scoped: the shared account's expense IS reported.
    (total, perCat) <- runRIO env (ReportingService.spendingByCategory userId Nothing Nothing)
    total `shouldBe` unsafeMoney USD 150
    lookup testRentCatId perCat `shouldBe` Just (unsafeMoney USD 150)

    (_inc, expn, _net) <- runRIO env (ReportingService.incomeVsExpense userId Nothing Nothing)
    expn `shouldBe` unsafeMoney USD 150

    -- Owner-scoped: net worth includes ONLY the user's own account, not the
    -- shared one.
    result <- runRIO env (ReportingService.netWorth userId)
    case result of
      Left err -> expectationFailure ("expected Right, got Left " <> show err)
      Right (nwTotal, rows) -> do
        nwTotal `shouldBe` unsafeMoney USD 500
        map (\(aid, _, _) -> aid) rows `shouldBe` [unsafeAccountId ownedUuid]

  describe "netWorth" $ do
    it "converts a non-base owned balance to base via the published rate" $ do
      -- Base currency is USD (default config). Owned account is in EUR.
      env <- createTestAppEnvWithProcessManager
      userUuid <- UUID.nextRandom
      eurUuid <- createRegularAccount env userUuid EUR 100
      -- 1.5 is exactly representable as a Double, so it survives the
      -- exchange-rate event's JSON round-trip (rate is serialised via
      -- 'fromRational ... :: Double') without precision loss.
      publishFixedRate env EUR USD 1.5

      let userId = unsafeUserId userUuid
      result <- runRIO env (ReportingService.netWorth userId)
      case result of
        Left err -> expectationFailure ("expected Right, got Left " <> show err)
        Right (total, rows) -> do
          total `shouldBe` unsafeMoney USD 150
          rows
            `shouldBe` [ ( unsafeAccountId eurUuid,
                           unsafeMoney EUR 100,
                           unsafeMoney USD 150
                         )
                       ]

    it "fails with ExchangeRateUnavailable when an owned currency has no rate" $ do
      env <- createTestAppEnvWithProcessManager
      userUuid <- UUID.nextRandom
      _ <- createRegularAccount env userUuid EUR 100
      -- No rate published for EUR -> USD.

      let userId = unsafeUserId userUuid
      result <- runRIO env (ReportingService.netWorth userId)
      case result of
        Left (ExchangeRateUnavailable _) -> pure ()
        Left err -> expectationFailure ("expected ExchangeRateUnavailable, got " <> show err)
        Right ok -> expectationFailure ("expected Left, got Right " <> show ok)

    it "excludes accounts created by another user" $ do
      -- Both accounts are USD (base) so no FX is needed; only the owned
      -- account should contribute to the total.
      env <- createTestAppEnvWithProcessManager
      userUuid <- UUID.nextRandom
      otherUuid <- UUID.nextRandom
      ownedUuid <- createRegularAccount env userUuid USD 300
      _foreignUuid <- createRegularAccount env otherUuid USD 999

      let userId = unsafeUserId userUuid
      result <- runRIO env (ReportingService.netWorth userId)
      case result of
        Left err -> expectationFailure ("expected Right, got Left " <> show err)
        Right (total, rows) -> do
          total `shouldBe` unsafeMoney USD 300
          map (\(aid, _, _) -> aid) rows `shouldBe` [unsafeAccountId ownedUuid]
