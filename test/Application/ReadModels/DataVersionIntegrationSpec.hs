{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.DataVersionIntegrationSpec
-- Description : Persistence guarantees of the per-user data-version counter,
--               plus the effectful classify->resolve-users->bump handler.
--
-- Exercises the @sync_data_version@ table added for the "data changed" signal
-- (tracker#45): a fresh user reads as version 0 with no row materialized,
-- 'bumpVersions' is an atomic per-user +1 (never a clamp/max), and a
-- duplicate user in one 'bumpVersions' call is only counted once ('nub').
--
-- The second half of the spec drives 'applyDataVersionEvent' directly against
-- account/user state seeded through the real service layer ('Testkit.Fixtures')
-- so the @account_access@ rows it resolves against are exactly what production
-- would produce -- in particular the CRITICAL edge this signal must get right:
-- income/expense transactions carry the user's own External sentinel account
-- on the opposite leg (see 'Application.Services.TransactionService'), and
-- 'applyDataVersionEvent' resolves accessors over /both/ legs. Since External
-- accounts can never be shared (see 'Application.Services.AccountService'),
-- their only @account_access@ row is the owner's own -- so resolving over the
-- sentinel leg can never leak the signal to another user. The
-- "income/expense bumps only the owner" test below is the guard that proves
-- this stays true.
module Application.ReadModels.DataVersionIntegrationSpec (spec) where

import Application.ReadModels.DataVersion
  ( applyDataVersionEvent,
    bumpVersions,
    getDataVersion,
    migrateDataVersion,
  )
import Application.ReadModels.Transaction (applyTransactionEvent)
import qualified Application.Services.AccountService as AccountService
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Database.Persist.Sql (Single (..), SqlPersistT, rawSql, runMigrationSilent)
import Domain.Account.Events (AccountAccessGranted (..), AccountAccessRevoked (..))
import Domain.Configuration.Events (ConfigurationCreated (..))
import Domain.Core.Types
  ( AccountRole (..),
    Allocation (..),
    CreatedBy (..),
    Currency (..),
    TransactionId,
    TransactionType (..),
    UserId,
    mkExpenseAllocations,
    mkIncomeAllocations,
    unAccountId,
    unUserId,
    unsafeMoney,
  )
import Domain.Localization.Language (Language (..))
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionLabelsSet (..), TransactionPostingCompleted (..))
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (registerUser, registerWithAccount, userExternalAccountId)
import Testkit.Helpers (globalEvent, mockDictionaryEntryId, mockTransactionId, mockUserIdN)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.TransactionEvents (postingInitiatedGlobal, transactionEditGlobal)

-- | Total row count of @sync_data_version@ in a fresh (per-test) env — a
-- direct count avoids depending on any exported filter/unique constructor.
rowCount :: (MonadIO m) => SqlPersistT m Int
rowCount = do
  rows <- rawSql "SELECT COUNT(*) FROM sync_data_version" []
  pure (case rows of [Single n] -> n; _ -> -1)

-- | Run @action@ and return, per user in @uids@, how much that user's
-- data-version counter grew across it (@after - before@).
--
-- The DataVersion model is registered in the shared test harness, so the
-- seeding steps (register / createAccount / shareAccount / ...) already bump
-- counters in-transaction before the action under test. Measuring the /delta/
-- around a single action is therefore the honest "did THIS event bump the
-- right users" assertion — immune to that seeding noise — while still keeping
-- every negative (a user who must NOT be signalled has delta 0). All befores
-- are captured before the single @action@, so a multi-user event is never
-- double-counted.
deltasAround :: AppEnv -> [UserId] -> IO () -> IO [Word64]
deltasAround env uids action = do
  befores <- runDbIn env (mapM getDataVersion uids)
  action
  afters <- runDbIn env (mapM getDataVersion uids)
  pure (zipWith (-) afters befores)

spec :: Spec
spec = do
  describe "sync_data_version persistence" $ do
    it "a fresh user reads as version 0" $ do
      env <- createTestAppEnvWithProcessManager
      runDbIn env (void (runMigrationSilent migrateDataVersion))
      let uid = mockUserIdN 1
      runDbIn env (getDataVersion uid) `shouldReturn` 0

    it "bumpVersions increments a user's counter by 1 each call: 0 -> 1 -> 2" $ do
      env <- createTestAppEnvWithProcessManager
      runDbIn env (void (runMigrationSilent migrateDataVersion))
      let uid = mockUserIdN 2
      runDbIn env (bumpVersions [uid])
      runDbIn env (getDataVersion uid) `shouldReturn` 1
      runDbIn env (bumpVersions [uid])
      runDbIn env (getDataVersion uid) `shouldReturn` 2

    it "a user with no row reads as 0 and does not materialize a row" $ do
      env <- createTestAppEnvWithProcessManager
      runDbIn env (void (runMigrationSilent migrateDataVersion))
      let stranger = mockUserIdN 3
      runDbIn env (getDataVersion stranger) `shouldReturn` 0
      runDbIn env rowCount `shouldReturn` 0

    it "bumpVersions [a, b, a] bumps each of a and b exactly once (nub)" $ do
      env <- createTestAppEnvWithProcessManager
      runDbIn env (void (runMigrationSilent migrateDataVersion))
      let a = mockUserIdN 4
          b = mockUserIdN 5
      runDbIn env (bumpVersions [a, b, a])
      runDbIn env (getDataVersion a) `shouldReturn` 1
      runDbIn env (getDataVersion b) `shouldReturn` 1

  -- Delta assertions: the DataVersion model is registered in the shared
  -- harness, so seeding (register/createAccount/shareAccount/...) already bumps
  -- counters in-transaction before the action under test. Each test measures
  -- the growth of each user's counter across the single 'applyDataVersionEvent'
  -- call (1 for a signalled user, 0 for one that must NOT be) — immune to
  -- seeding noise, negatives preserved. See 'deltasAround'.
  describe "applyDataVersionEvent (classify -> resolve users -> bump)" $ do
    it "an account event on an account shared owner<->editor bumps both; an unrelated third user stays at 0" $ do
      env <- createTestAppEnvWithProcessManager
      (owner, acct) <- registerWithAccount env "owner@test.com" "Joint"
      editor <- registerUser env "editor@test.com"
      third <- registerUser env "third@test.com"

      shareRes <-
        runAppM env $ AccountService.shareAccount owner (unAccountId acct) (unUserId editor) "editor"
      shareRes `shouldBe` Right ()

      let event =
            globalEvent
              (unAccountId acct)
              1
              (AccountAccessGrantedEvent AccountAccessGranted {userId = editor, role = Editor, by = owner})
              0
      deltas <- deltasAround env [owner, editor, third] (runDbIn env (applyDataVersionEvent event))
      deltas `shouldBe` [1, 1, 0]

    it "a plain income on user U's account bumps only U, not an unrelated user (External-sentinel guard)" $ do
      env <- createTestAppEnvWithProcessManager
      (userU, regularAcct) <- registerWithAccount env "u@test.com" "Wallet"
      externalAcct <- userExternalAccountId env userU
      other <- registerUser env "other@test.com"

      let incomeType =
            Income (mkIncomeAllocations (Allocation (mockDictionaryEntryId (UUID.fromWords 1 0 0 0)) (unsafeMoney USD 100) Nothing NE.:| []))
          event = postingInitiatedGlobal (tx 1) externalAcct regularAcct incomeType Set.empty day day 0 Nothing
      deltas <- deltasAround env [userU, other] (runDbIn env (applyDataVersionEvent event))
      deltas `shouldBe` [1, 0]

    it "a plain expense on user U's account bumps only U, not an unrelated user (External-sentinel guard)" $ do
      env <- createTestAppEnvWithProcessManager
      (userU, regularAcct) <- registerWithAccount env "u2@test.com" "Wallet2"
      externalAcct <- userExternalAccountId env userU
      other <- registerUser env "other2@test.com"

      let expenseType =
            Expense (mkExpenseAllocations (Allocation (mockDictionaryEntryId (UUID.fromWords 2 0 0 0)) (unsafeMoney USD 50) Nothing NE.:| []))
          event = postingInitiatedGlobal (tx 2) regularAcct externalAcct expenseType Set.empty day day 0 Nothing
      deltas <- deltasAround env [userU, other] (runDbIn env (applyDataVersionEvent event))
      deltas `shouldBe` [1, 0]

    it "a transfer between account A (user U) and account B (user V) bumps both U and V" $ do
      env <- createTestAppEnvWithProcessManager
      (userU, acctA) <- registerWithAccount env "transferu@test.com" "A"
      (userV, acctB) <- registerWithAccount env "transferv@test.com" "B"

      let event = postingInitiatedGlobal (tx 3) acctA acctB Transfer Set.empty day day 0 Nothing
      deltas <- deltasAround env [userU, userV] (runDbIn env (applyDataVersionEvent event))
      deltas `shouldBe` [1, 1]

    it "a label edit (carries only a transactionId) bumps the transaction's account users" $ do
      env <- createTestAppEnvWithProcessManager
      (userU, acctA) <- registerWithAccount env "labelu@test.com" "A"
      (userV, acctB) <- registerWithAccount env "labelv@test.com" "B"

      -- Seed the transaction row so 'transactionAccounts' can resolve it. Fed
      -- straight through the transaction read model's apply (not the writer),
      -- so this seeding does not itself fire the DataVersion handler.
      let seedEvent = postingInitiatedGlobal (tx 4) acctA acctB Transfer Set.empty day day 0 Nothing
      runDbIn env (applyTransactionEvent seedEvent)

      let labelEvent =
            transactionEditGlobal
              (tx 4)
              (TransactionLabelsSetEvent TransactionLabelsSet {transactionId = tx 4, labels = Set.empty})
              1
      deltas <- deltasAround env [userU, userV] (runDbIn env (applyDataVersionEvent labelEvent))
      deltas `shouldBe` [1, 1]

    it "AccountAccessRevoked bumps the revoked user even though they are no longer in account_access" $ do
      env <- createTestAppEnvWithProcessManager
      (owner, acct) <- registerWithAccount env "revoker@test.com" "Joint2"
      editor <- registerUser env "revokee@test.com"

      shareRes <-
        runAppM env $ AccountService.shareAccount owner (unAccountId acct) (unUserId editor) "editor"
      shareRes `shouldBe` Right ()
      revokeRes <-
        runAppM env $ AccountService.revokeAccountAccess owner (unAccountId acct) (unUserId editor)
      revokeRes `shouldBe` Right ()

      let event =
            globalEvent
              (unAccountId acct)
              2
              (AccountAccessRevokedEvent AccountAccessRevoked {userId = editor, by = owner})
              0
      -- Owner still has access (signalled via the account's current access
      -- list); the revoked editor is signalled via 'extraUsers' even though
      -- their account_access row is already gone.
      deltas <- deltasAround env [owner, editor] (runDbIn env (applyDataVersionEvent event))
      deltas `shouldBe` [1, 1]

    it "a pure system signal and a Configuration event bump nobody" $ do
      env <- createTestAppEnvWithProcessManager

      let systemEvent = transactionEditGlobal (tx 5) (TransactionPostingCompletedEvent TransactionPostingCompleted) 0
          configEvent =
            globalEvent
              (UUID.fromWords 999 0 0 0)
              0
              ( ConfigurationCreatedEvent
                  ConfigurationCreated {baseCurrency = USD, defaultCurrency = USD, language = En, country = Nothing, createdBy = System}
              )
              1
      -- No seeding here, so no user rows exist; both events classify to the
      -- empty scope, so the row count must not change across them.
      before <- runDbIn env rowCount
      runDbIn env (applyDataVersionEvent systemEvent)
      runDbIn env (applyDataVersionEvent configEvent)
      after <- runDbIn env rowCount
      after `shouldBe` before

-- | A fixed calendar date at midnight UTC, matching the seed fixtures in
-- 'Testkit.TransactionEvents'.
day :: UTCTime
day = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime 0)

-- | A synthetic transaction id at a distinct 'UUID' word position, mirroring
-- the @tx@ helper in the sibling persistent-transaction specs.
tx :: Word32 -> TransactionId
tx n = mockTransactionId (UUID.fromWords n 0 0 0)
