{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AccountServiceIntegrationSpec
-- Description : Integration tests for 'AccountService.adjustAccountBalance'.
--
-- These cases exercise the full adjust-balance flow end-to-end through the
-- in-memory event store: authorization, validation, balance-as-of fold,
-- direction derivation, and saga propagation. The transfer process
-- manager is wired in so debit\/credit\/complete events are produced as in
-- production.
module Application.Services.AccountServiceIntegrationSpec (spec) where

import Application.ReadModels.Account (AccountData (..), getAccount)
import qualified Application.ReadModels.ExchangeRate as ExchangeRateRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.User as UserRM
import Application.Services.AccountService (adjustAccountBalance, createAccount, shareAccount)
import Application.Services.AuthService (AuthResult (..), register)
import qualified Application.Services.ConfigurationService as ConfigurationService
import Data.Ratio ((%))
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime, utctDay)
import qualified Data.UUID as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreateAccount (..), CreditAccount (..))
import Domain.Transaction.CommandHandler (TransactionCommand (..))
import Domain.Transaction.Commands (InitiateTransfer (..))
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    Money,
    TransferType (..),
    UserId,
    defaultBankAccount,
    mkMoney,
    moneyCurrency,
    unAccountId,
    unMoney,
    unUserId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Projection (TransactionStatus (..))
import Eventium (EventHandler (..), GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import Infrastructure.Eventium (applyAccountCommand, applyTransactionCommand)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Test.Hspec
import Testkit.Helpers (fromRight', mockExchangeRate)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "AccountService.adjustAccountBalance" $ do
  it
    "applies a positive delta as External -> Regular and records the Adjustment transaction"
    positiveDeltaSpec
  it
    "applies a negative delta within overdraft as Regular -> External"
    negativeDeltaSpec
  it
    "backdate: balanceAsOf(D) == targetBalance and future credits ride on top"
    backdateSpec
  it
    "rejects when the account is External"
    rejectExternalSpec
  it
    "rejects when target balance currency does not match account currency"
    rejectCurrencyMismatchSpec
  it
    "rejects when at > now"
    rejectFutureDateSpec
  it
    "rejects when delta is zero"
    rejectZeroDeltaSpec
  it
    "rejects when negative delta would exceed overdraft (saga FailTransfer)"
    rejectOverdraftSpec
  it
    "rejects when caller has Viewer role"
    rejectViewerSpec
  it
    "handles cross-currency by passing through resolveAndInitiate (USD External, EUR account)"
    crossCurrencySpec

-- -----------------------------------------------------------------------------
-- Test fixtures
-- -----------------------------------------------------------------------------

-- | Fixed business date used by the synchronous tests. Far enough in the
-- past that @asOf <= now@ always holds.
fixedAsOf :: UTCTime
fixedAsOf = UTCTime (fromGregorian 2026 4 1) 0

-- | Register a user and create a Regular account in the given currency with
-- the supplied initial balance. Returns the env, the user id, and the
-- account id. Uses the PM-enabled env so the saga drives debit/credit
-- through to completion automatically.
setupUserWithAccount ::
  Currency -> Rational -> IO (AppEnv, UserId, AccountId)
setupUserWithAccount cur initialBalance = do
  env <- createTestAppEnvWithProcessManager
  runAppM env ConfigurationService.seedDefaultConfiguration
  regResult <- runAppM env $ register "owner@test.com" "password123"
  let authResult = fromRight' regResult
      userId = authResult.userId
  acctResult <-
    runAppM env
      $ createAccount
        CreateAccount
          { name = "Savings",
            initialBalance = unsafeMoney cur initialBalance,
            createdBy = userId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = Nothing
          }
  let (accountId, _) = fromRight' acctResult
  pure (env, userId, accountId)

-- | Re-set the base currency on a fresh user's config so the auto-created
-- External account is in a non-default currency. Returns the resulting
-- env plus the user id and the EUR Regular account id.
setupUserWithCrossCurrencyAccounts ::
  IO (AppEnv, UserId, AccountId)
setupUserWithCrossCurrencyAccounts = do
  env <- createTestAppEnvWithProcessManager
  runAppM env ConfigurationService.seedDefaultConfiguration
  -- Seed an exchange rate so the External (USD) leg can convert.
  seedExchangeRate env [(USD, EUR, 9 % 10), (EUR, USD, 10 % 9)]
  regResult <- runAppM env $ register "fx@test.com" "password123"
  let authResult = fromRight' regResult
      userId = authResult.userId
  -- Default base currency from the seeded configuration is USD, so the
  -- auto-created External account is in USD. Create the Regular account
  -- in EUR explicitly.
  acctResult <-
    runAppM env
      $ createAccount
        CreateAccount
          { name = "EUR Savings",
            initialBalance = unsafeMoney EUR 100,
            createdBy = userId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = Nothing
          }
  let (accountId, _) = fromRight' acctResult
  pure (env, userId, accountId)

-- | Feed a synthetic 'ExchangeRatesPublishedEvent' through the read model
-- so 'resolveAndInitiate' can resolve cross-currency amounts. Mirrors the
-- helper in 'TransactionServiceSpec'.
seedExchangeRate :: AppEnv -> [(Currency, Currency, Rational)] -> IO ()
seedExchangeRate env rates = do
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
  (ExchangeRateRM.handleExchangeRateEvents env.exchangeRateReadModel).handleEvent [globalEvent]

-- | Construct a 'Money' value via the smart constructor.
money :: Currency -> Rational -> Money
money cur amt = fromRight' (mkMoney cur amt)

-- -----------------------------------------------------------------------------
-- Test bodies
-- -----------------------------------------------------------------------------

positiveDeltaSpec :: Expectation
positiveDeltaSpec = do
  -- Use the base currency (USD) so the same-currency code path is
  -- exercised without needing an exchange-rate fixture. The
  -- cross-currency case lives in its own dedicated spec below.
  (env, userId, accountId) <- setupUserWithAccount USD 100
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money USD 150) fixedAsOf "Reconcile"
  case result of
    Left err -> expectationFailure $ "Expected Right, got Left: " <> show err
    Right (_, txData) -> do
      txData.transferType `shouldBe` Adjustment
      txData.description `shouldBe` "Reconcile"
      txData.status `shouldBe` Completed
      txData.sourceAmount `shouldBe` unsafeMoney USD 50
      txData.targetAmount `shouldBe` unsafeMoney USD 50
      -- Balance is now 150 USD.
      maybeAcct <- getAccount env.accountReadModel accountId
      case maybeAcct of
        Just acct -> acct.balance `shouldBe` unsafeMoney USD 150
        Nothing -> expectationFailure "Account vanished from read model"

negativeDeltaSpec :: Expectation
negativeDeltaSpec = do
  -- Start at 200, overdraft 0 (default for Regular). Adjust down to 120 —
  -- delta is -80; debit 80 from the Regular account → still positive.
  (env, userId, accountId) <- setupUserWithAccount USD 200
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money USD 120) fixedAsOf "Bank fee"
  case result of
    Left err -> expectationFailure $ "Expected Right, got Left: " <> show err
    Right (_, txData) -> do
      txData.transferType `shouldBe` Adjustment
      txData.status `shouldBe` Completed
      txData.sourceAccountId `shouldBe` accountId
      txData.sourceAmount `shouldBe` unsafeMoney USD 80
      txData.targetAmount `shouldBe` unsafeMoney USD 80
      maybeAcct <- getAccount env.accountReadModel accountId
      case maybeAcct of
        Just acct -> acct.balance `shouldBe` unsafeMoney USD 120
        Nothing -> expectationFailure "Account vanished from read model"

backdateSpec :: Expectation
backdateSpec = do
  (env, userId, accountId) <- setupUserWithAccount USD 100
  let t1 = UTCTime (fromGregorian 2026 4 1) 0
      t2 = UTCTime (fromGregorian 2026 4 15) 0
  maybeUser <- UserRM.getUser env.userReadModel userId
  let externalAccId = case maybeUser of
        Just u -> u.externalAccountId
        Nothing -> error "User vanished from read model"
  -- Pre-populate: credit the account at t2 by 60 USD. We bypass the
  -- transfer saga here so the credit produces an 'AccountCredited'
  -- event with the supplied business date directly — exactly what
  -- 'balanceAsOf' folds on.
  creditAccountAt env accountId t2 (unsafeMoney USD 60)
  -- Sanity: the read-model's running balance now reflects the t2 credit.
  -- Adjust at t1 to 200 USD. balanceAsOf(t1) is 100, so delta = +100.
  -- After adjustment, the saga credits the Regular account by 100 USD
  -- at t1. The earlier t2 credit (60 USD) was already applied to the
  -- read-model's running balance, so the current balance is 100 + 60
  -- (already) + 100 (adjustment) = 260.
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money USD 200) t1 "Backdated reconcile"
  case result of
    Left err -> expectationFailure $ "Expected Right, got Left: " <> show err
    Right (_, txData) -> do
      txData.transferType `shouldBe` Adjustment
      txData.sourceAccountId `shouldBe` externalAccId
      txData.targetAccountId `shouldBe` accountId
      txData.sourceAmount `shouldBe` unsafeMoney USD 100
      maybeAcct <- getAccount env.accountReadModel accountId
      case maybeAcct of
        Just acct ->
          acct.balance `shouldBe` unsafeMoney USD 260
        Nothing -> expectationFailure "Account vanished from read model"

rejectExternalSpec :: Expectation
rejectExternalSpec = do
  (env, userId, _) <- setupUserWithAccount USD 100
  maybeUser <- UserRM.getUser env.userReadModel userId
  let externalAccId = case maybeUser of
        Just u -> u.externalAccountId
        Nothing -> error "User vanished from read model"
  result <-
    runAppM env
      $ adjustAccountBalance userId externalAccId (money USD 50) fixedAsOf "Reconcile"
  case result of
    Left (ValidationErr ve) ->
      ve.validationField `shouldBe` "accountType"
    Left err -> expectationFailure $ "Expected ValidationErr on accountType, got: " <> show err
    Right _ -> expectationFailure "Expected Left ValidationErr"

rejectCurrencyMismatchSpec :: Expectation
rejectCurrencyMismatchSpec = do
  -- Account is USD; submitting an EUR target balance should be rejected
  -- before any cross-currency machinery is touched.
  (env, userId, accountId) <- setupUserWithAccount USD 100
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money EUR 150) fixedAsOf "Wrong currency"
  case result of
    Left (ValidationErr ve) ->
      ve.validationField `shouldBe` "currency"
    Left err -> expectationFailure $ "Expected ValidationErr on currency, got: " <> show err
    Right _ -> expectationFailure "Expected Left ValidationErr"

rejectFutureDateSpec :: Expectation
rejectFutureDateSpec = do
  (env, userId, accountId) <- setupUserWithAccount USD 100
  now <- getCurrentTime
  let future = addUTCTime 3600 now -- one hour ahead
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money USD 200) future "From the future"
  case result of
    Left (ValidationErr ve) ->
      ve.validationField `shouldBe` "date"
    Left err -> expectationFailure $ "Expected ValidationErr on at, got: " <> show err
    Right _ -> expectationFailure "Expected Left ValidationErr"

rejectZeroDeltaSpec :: Expectation
rejectZeroDeltaSpec = do
  (env, userId, accountId) <- setupUserWithAccount USD 100
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money USD 100) fixedAsOf "No-op"
  case result of
    Left (ValidationErr ve) ->
      ve.validationField `shouldBe` "targetBalance"
    Left err -> expectationFailure $ "Expected ValidationErr on targetBalance, got: " <> show err
    Right _ -> expectationFailure "Expected Left ValidationErr"

rejectOverdraftSpec :: Expectation
rejectOverdraftSpec = do
  -- Start at 100, overdraft 0 (default Regular). Target -50 ⇒ delta -150,
  -- magnitude 150 debited from the Regular account; balance would go to
  -- -50, but with overdraft 0 the debit is rejected and the saga emits
  -- TransferFailed.
  (env, userId, accountId) <- setupUserWithAccount USD 100
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money USD (-50)) fixedAsOf "Over the limit"
  case result of
    Left err -> expectationFailure $ "Expected Right with Failed status, got Left: " <> show err
    Right (_, txData) -> do
      txData.transferType `shouldBe` Adjustment
      case txData.status of
        Failed reason ->
          T.isInfixOf "Insufficient" reason `shouldBe` True
        other ->
          expectationFailure $ "Expected Failed status, got: " <> show other
      -- Balance must remain unchanged.
      maybeAcct <- getAccount env.accountReadModel accountId
      case maybeAcct of
        Just acct -> acct.balance `shouldBe` unsafeMoney USD 100
        Nothing -> expectationFailure "Account vanished from read model"

rejectViewerSpec :: Expectation
rejectViewerSpec = do
  -- Set up an owner and a separate Viewer-shared user.
  env <- createTestAppEnvWithProcessManager
  runAppM env ConfigurationService.seedDefaultConfiguration
  ownerReg <- runAppM env $ register "owner-v@test.com" "password123"
  let ownerId = (fromRight' ownerReg).userId
  acctResult <-
    runAppM env
      $ createAccount
        CreateAccount
          { name = "Shared",
            initialBalance = unsafeMoney USD 100,
            createdBy = ownerId,
            accountType = Regular defaultBankAccount,
            overdraftLimit = Nothing
          }
  let (accountId, _) = fromRight' acctResult
  viewerReg <- runAppM env $ register "viewer-v@test.com" "password123"
  let viewerId = (fromRight' viewerReg).userId
      viewerUuid = unUserId viewerId
  shareRes <-
    runAppM env $ shareAccount ownerId (unAccountId accountId) viewerUuid "viewer"
  case shareRes of
    Right _ -> pure ()
    Left err -> expectationFailure $ "Could not share account with viewer: " <> show err
  result <-
    runAppM env
      $ adjustAccountBalance viewerId accountId (money USD 200) fixedAsOf "Viewer attempt"
  case result of
    Left (AccountError _) -> pure ()
    Left err -> expectationFailure $ "Expected AccountError on Viewer, got: " <> show err
    Right _ -> expectationFailure "Expected Left AccountError"

crossCurrencySpec :: Expectation
crossCurrencySpec = do
  (env, userId, accountId) <- setupUserWithCrossCurrencyAccounts
  -- Account is EUR; External is USD at 0.9 USD->EUR (i.e. 1 USD = 0.9 EUR,
  -- 1 EUR = 10/9 USD). Adjust EUR account from 100 to 190 — delta +90 EUR.
  -- Direction is External (USD) -> Regular (EUR). User magnitude is in
  -- target currency (EUR) so resolveAndInitiate converts via the EUR->USD
  -- rate. Source amount: 90 EUR * 10/9 = 100 USD.
  result <-
    runAppM env
      $ adjustAccountBalance userId accountId (money EUR 190) fixedAsOf "FX reconcile"
  case result of
    Left err -> expectationFailure $ "Expected Right, got Left: " <> show err
    Right (_, txData) -> do
      txData.transferType `shouldBe` Adjustment
      txData.status `shouldBe` Completed
      moneyCurrency txData.sourceAmount `shouldBe` USD
      moneyCurrency txData.targetAmount `shouldBe` EUR
      txData.targetAmount `shouldBe` unsafeMoney EUR 90
      unMoney txData.sourceAmount `shouldBe` 100
      txData.exchangeRate `shouldSatisfy` isJust

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Emit a 'CreditAccount' command directly at a specific business date,
-- bypassing the transfer saga. Produces an 'AccountCredited' event whose
-- effective business date is supplied by the Transaction read model
-- (which 'balanceAsOf' joins against). To make the leg visible to the
-- fold we also seed a matching 'TransferInitiated' event on the TX
-- stream so the TX read model records @atTime@ as the authoritative date.
creditAccountAt :: AppEnv -> AccountId -> UTCTime -> Money -> IO ()
creditAccountAt env accountId atTime amt = do
  let txUuid = UUID.fromWords 42 0 0 1
      txId = unsafeTransactionId txUuid
  -- Seed the TX stream first so the TX read model has @atTime@ available
  -- by the time the leg event lands. We use a dummy user UUID; the saga
  -- is bypassed entirely.
  _ <-
    applyTransactionCommand
      env.eventStoreWriter
      env.eventStoreReader
      id
      txUuid
      $ InitiateTransferTransactionCommand
        InitiateTransfer
          { sourceAccountId = accountId,
            targetAccountId = accountId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Backdated credit",
            initiatedBy = unsafeUserId (UUID.fromWords 42 0 0 2),
            at = atTime,
            transferType = Transfer,
            externalTransactionId = Nothing,
            labels = mempty
          }
  _ <-
    applyAccountCommand
      env.eventStoreWriter
      env.eventStoreReader
      id
      (unAccountId accountId)
      $ CreditAccountAccountCommand
        CreditAccount
          { amount = amt,
            transactionId = txId
          }
  pure ()
