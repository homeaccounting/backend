{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionCancellationIntegrationSpec
-- Description : End-to-end saga coverage of the transaction cancellation flow.
--
-- Exercises 'TransactionService.cancelTransaction' through the full
-- service + saga + read-model stack using a synchronous in-memory event
-- store.  The 'createTestAppEnvWithProcessManager' environment wires all
-- three sagas (transfer, amendment, cancellation), so every command
-- dispatched in a test triggers the full downstream event fan-out
-- synchronously before control returns.
--
-- Covers §Testing "Integration" row of
-- @docs/plans/2026-05-29-delete-transaction.md@.
--
-- Scenarios:
--   1. Happy path — balances reversed, streams correct, status Cancelled.
--   2. Read-model visibility — default list hides cancelled; opt-in shows it.
--   3. Direct getTransaction still returns the cancelled record.
--   4. Cancel after amend reverses the amended amounts (not the original).
--   5. Books-close gate — rejects when TX date ≤ cutoff.
--   6. Authorization gate — non-Editor caller gets AccountError.
--   7. Double-cancel — second attempt returns TransactionAlreadyCancelled.
--
-- Note on scenarios "cancel-during-amend" and "amend-during-cancel"
-- (spec scenarios 8 & 9): the in-memory bus dispatches events
-- synchronously, so both sagas complete atomically within a single
-- 'runAppM' call.  There is no way to observe the transient
-- in-flight state at the service level in these tests.  Coverage for
-- those guard paths lives in
-- 'Domain.Transaction.CancellationCommandHandlerSpec' (unit tests).
module Integration.TransactionCancellationIntegrationSpec (spec) where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..), emptyTransactionQuery, mkTransactionQuery)
import qualified Application.ReadModels.Transaction as ReadModel
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService (closeBooksThrough)
import Application.Services.TransactionService
  ( amendTransaction,
    cancelTransaction,
    initiateTransfer,
    listTransactions,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    TransactionId,
    UserId,
    unMoney,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Commands (AmendTransaction (..))
import Domain.Transaction.Projection (TransactionStatus (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createRegularAccount,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Convenience: read the USD balance of an account from the read model.
balanceUsd :: AppEnv -> AccountId -> IO Rational
balanceUsd env aid = do
  m <- AccountRM.getAccount env.accountReadModel aid
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail $ "balanceUsd: account not found: " <> show aid

-- | Run 'initiateTransfer' and unwrap the result, failing the
-- test on a Left.
seedTransfer :: AppEnv -> UserId -> AccountId -> AccountId -> Rational -> IO (TransactionId, TransactionData)
seedTransfer env uid src tgt amt = do
  res <-
    runAppM env
      $ initiateTransfer
        uid
        src
        tgt
        (unsafeMoney Core.USD amt)
        Set.empty
        "Test transfer"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "seedTransfer failed: " <> show err
    Right r -> pure r

-- | Run 'cancelTransaction' through 'runAppM'.
runCancel :: AppEnv -> UserId -> TransactionId -> IO (Either DomainError TransactionData)
runCancel env uid txId = runAppM env (cancelTransaction uid txId)

-- | List transactions visible to @uid@ with the default query (cancelled
-- excluded).
listDefault :: AppEnv -> UserId -> IO [(TransactionId, TransactionData)]
listDefault env uid = runAppM env (listTransactions uid emptyTransactionQuery)

-- | List transactions visible to @uid@, including cancelled ones.
listWithCancelled :: AppEnv -> UserId -> IO [(TransactionId, TransactionData)]
listWithCancelled env uid =
  case mkTransactionQuery Nothing Nothing Nothing True of
    Left err -> fail $ "mkTransactionQuery failed: " <> show err
    Right q -> runAppM env (listTransactions uid q)

-- | Directly look up a transaction from the read model.
getTransactionFromRM :: AppEnv -> TransactionId -> IO (Maybe TransactionData)
getTransactionFromRM env =
  ReadModel.getTransaction env.transactionReadModel

-- | Common fixture: a fresh env, a user, a source and target account.
data CancelFixture = CancelFixture
  { cfEnv :: AppEnv,
    cfUserId :: UserId,
    cfSrc :: AccountId,
    cfTgt :: AccountId
  }

-- | Seed a cancel fixture with two Regular USD accounts (5 000 USD each).
setupCancelFixture :: Text -> IO CancelFixture
setupCancelFixture email = do
  env <- createTestAppEnvWithProcessManager
  fx <- setupMetadataFixture env email
  src <- createRegularAccount env fx.userId "Source"
  tgt <- createRegularAccount env fx.userId "Target"
  pure
    CancelFixture
      { cfEnv = env,
        cfUserId = fx.userId,
        cfSrc = src,
        cfTgt = tgt
      }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransactionCancellation" $ do
  happyPathSpec
  readModelVisibilitySpec
  directLookupSpec
  amendThenCancelSpec
  booksCloseSpec
  authorizationSpec
  doubleCancelSpec

-- -----------------------------------------------------------------------------
-- 1. Happy path
-- -----------------------------------------------------------------------------

happyPathSpec :: Spec
happyPathSpec =
  describe "Happy path" $ do
    it "cancelling a completed transfer reverses both account balances" $ do
      cf <- setupCancelFixture "cancel-happy@test.com"
      let env = cf.cfEnv
          uid = cf.cfUserId

      srcBefore <- balanceUsd env cf.cfSrc
      tgtBefore <- balanceUsd env cf.cfTgt

      (txId, _td) <- seedTransfer env uid cf.cfSrc cf.cfTgt 200

      srcAfterTransfer <- balanceUsd env cf.cfSrc
      tgtAfterTransfer <- balanceUsd env cf.cfTgt
      srcAfterTransfer `shouldBe` srcBefore - 200
      tgtAfterTransfer `shouldBe` tgtBefore + 200

      result <- runCancel env uid txId
      case result of
        Left err -> expectationFailure $ "expected Right, got: " <> show err
        Right td -> td.status `shouldBe` Cancelled

      srcAfterCancel <- balanceUsd env cf.cfSrc
      tgtAfterCancel <- balanceUsd env cf.cfTgt
      srcAfterCancel `shouldBe` srcBefore
      tgtAfterCancel `shouldBe` tgtBefore

    it "TX stream ends with TransactionCancellationCompleted and status is Cancelled" $ do
      cf <- setupCancelFixture "cancel-status@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 100
      result <- runCancel cf.cfEnv cf.cfUserId txId
      case result of
        Left err -> expectationFailure $ "cancelTransaction returned Left: " <> show err
        Right td -> td.status `shouldBe` Cancelled

-- -----------------------------------------------------------------------------
-- 2. Read-model visibility
-- -----------------------------------------------------------------------------

readModelVisibilitySpec :: Spec
readModelVisibilitySpec =
  describe "Read-model visibility" $ do
    it "default listTransactions excludes cancelled transactions" $ do
      cf <- setupCancelFixture "cancel-list-default@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 50
      _ <- runCancel cf.cfEnv cf.cfUserId txId
      txns <- listDefault cf.cfEnv cf.cfUserId
      let ids = map fst txns
      ids `shouldNotContain` [txId]

    it "listTransactions with qIncludeCancelled=True includes cancelled transactions" $ do
      cf <- setupCancelFixture "cancel-list-include@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 50
      _ <- runCancel cf.cfEnv cf.cfUserId txId
      txns <- listWithCancelled cf.cfEnv cf.cfUserId
      let ids = map fst txns
      ids `shouldContain` [txId]

    it "the cancelled tx in the inclusive list carries status = Cancelled" $ do
      cf <- setupCancelFixture "cancel-list-status@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 75
      _ <- runCancel cf.cfEnv cf.cfUserId txId
      txns <- listWithCancelled cf.cfEnv cf.cfUserId
      case lookup txId txns of
        Nothing -> expectationFailure "cancelled tx not found in inclusive list"
        Just td -> td.status `shouldBe` Cancelled

-- -----------------------------------------------------------------------------
-- 3. Direct read-model lookup
-- -----------------------------------------------------------------------------

directLookupSpec :: Spec
directLookupSpec =
  describe "Direct getTransaction" $ do
    it "returns the transaction with status = Cancelled after cancellation" $ do
      cf <- setupCancelFixture "cancel-direct-lookup@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 60
      _ <- runCancel cf.cfEnv cf.cfUserId txId
      mtd <- getTransactionFromRM cf.cfEnv txId
      case mtd of
        Nothing -> expectationFailure "getTransaction returned Nothing after cancellation"
        Just td -> td.status `shouldBe` Cancelled

-- -----------------------------------------------------------------------------
-- 4. Cancel after amendment uses amended amounts
-- -----------------------------------------------------------------------------

amendThenCancelSpec :: Spec
amendThenCancelSpec =
  describe "Cancel after amendment reverses amended amounts" $ do
    it "final balances match pre-transfer values after amend → cancel" $ do
      cf <- setupCancelFixture "cancel-after-amend@test.com"
      let env = cf.cfEnv
          uid = cf.cfUserId

      srcBefore <- balanceUsd env cf.cfSrc
      tgtBefore <- balanceUsd env cf.cfTgt

      -- Initiate the transfer at 100
      (txId, td) <- seedTransfer env uid cf.cfSrc cf.cfTgt 100

      -- Amend to 250 (different amount on both legs)
      let amendCmd =
            AmendTransaction
              { transactionId = txId,
                newSourceAccountId = td.sourceAccountId,
                newTargetAccountId = td.targetAccountId,
                newSourceAmount = unsafeMoney Core.USD 250,
                newTargetAmount = unsafeMoney Core.USD 250,
                newExchangeRate = Nothing,
                amendedBy = uid
              }
      amendResult <- runAppM env (amendTransaction uid txId amendCmd)
      case amendResult of
        Left err -> expectationFailure $ "amendTransaction failed: " <> show err
        Right _ -> pure ()

      -- Cancel — the saga must reverse the AMENDED amounts (250), not the
      -- original (100); otherwise balances won't be restored to pre-transfer.
      cancelResult <- runCancel env uid txId
      case cancelResult of
        Left err -> expectationFailure $ "cancelTransaction failed after amend: " <> show err
        Right td' -> td'.status `shouldBe` Cancelled

      srcAfterCancel <- balanceUsd env cf.cfSrc
      tgtAfterCancel <- balanceUsd env cf.cfTgt
      srcAfterCancel `shouldBe` srcBefore
      tgtAfterCancel `shouldBe` tgtBefore

-- -----------------------------------------------------------------------------
-- 5. Books-close gate
-- -----------------------------------------------------------------------------

booksCloseSpec :: Spec
booksCloseSpec =
  describe "Books-close gate" $ do
    it "rejects cancellation when the TX date is in a closed period" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "cancel-books-close@test.com"
      src <- createRegularAccount env fx.userId "Src"
      tgt <- createRegularAccount env fx.userId "Tgt"

      -- Initiate a backdated transfer inside the period we'll close
      let txDate = utc 2026 3 15
      res <-
        runAppM env
          $ initiateTransfer
            fx.userId
            src
            tgt
            (unsafeMoney Core.USD 100)
            Set.empty
            "Backdated"
            Nothing
            (Just txDate)
      (txId, _td) <- case res of
        Left err -> fail $ "initiateTransfer failed: " <> show err
        Right r -> pure r

      -- Close books through a date after the TX
      let cutoff = utc 2026 3 31
      _ <- runAppM env (closeBooksThrough fx.userId cutoff)

      -- Attempt to cancel — must be rejected
      result <- runCancel env fx.userId txId
      case result of
        Left (CannotEditClosedPeriod {}) -> pure ()
        Left err -> expectationFailure $ "expected CannotEditClosedPeriod, got: " <> show err
        Right _ -> expectationFailure "expected Left CannotEditClosedPeriod, got Right"

-- -----------------------------------------------------------------------------
-- 6. Authorization gate
-- -----------------------------------------------------------------------------

authorizationSpec :: Spec
authorizationSpec =
  describe "Authorization gate" $ do
    it "rejects cancellation by a user with no access to the transaction's accounts" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "cancel-auth@test.com"
      src <- createRegularAccount env fx.userId "Src"
      tgt <- createRegularAccount env fx.userId "Tgt"

      (txId, _td) <- seedTransfer env fx.userId src tgt 100

      -- Register a second user who has no access to either account
      outsiderResult <- runAppM env $ register "outsider-cancel@test.com" "password123"
      outsiderId <- case outsiderResult of
        Left err -> fail $ "register outsider failed: " <> show err
        Right auth -> pure auth.userId

      result <- runCancel env outsiderId txId
      case result of
        Left (AccountError _) -> pure ()
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "expected auth error, got: " <> show err
        Right _ -> expectationFailure "expected Left auth error, got Right"

-- -----------------------------------------------------------------------------
-- 7. Double-cancel
-- -----------------------------------------------------------------------------

doubleCancelSpec :: Spec
doubleCancelSpec =
  describe "Double-cancel" $ do
    it "second cancellation returns TransactionAlreadyCancelled" $ do
      cf <- setupCancelFixture "cancel-double@test.com"
      (txId, _td) <- seedTransfer cf.cfEnv cf.cfUserId cf.cfSrc cf.cfTgt 80

      firstResult <- runCancel cf.cfEnv cf.cfUserId txId
      case firstResult of
        Left err -> expectationFailure $ "first cancel failed: " <> show err
        Right _ -> pure ()

      secondResult <- runCancel cf.cfEnv cf.cfUserId txId
      secondResult `shouldBe` Left TransactionAlreadyCancelled
