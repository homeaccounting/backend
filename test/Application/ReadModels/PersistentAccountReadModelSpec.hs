{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.PersistentAccountReadModelSpec
-- Description : Guarantees of the persistent, indexed Account read model.
--
-- These integration tests exercise the properties that the persistent
-- @accounts@ / @account_access@ projection exists to provide — the payoff of
-- moving the account read model off an in-memory map and onto indexed tables:
--
--   * __Per-tenant isolation__ — @getAccountIds@ for one user never
--     leaks accounts owned by another. The query is an indexed
--     @WHERE user_id = ?@ over @account_access@, not a scan that could
--     accidentally include foreign rows.
--   * __Shared-account visibility__ — granting access makes the account show up
--     for the grantee with the correct role, via the same access table.
--   * __Version recorded from the event__ — each row's @version@ is the event's
--     real per-stream 'EventVersion' (0-based, monotone with the stream), not a
--     value derived by incrementing inside the projection.
module Application.ReadModels.PersistentAccountReadModelSpec (spec) where

import Application.ReadModels.Account
  ( AccountData (..),
    getAccount,
    getAccountIds,
    getAccounts,
    getRegularAccounts,
  )
import Application.Services.AccountService (shareAccount)
import Application.Services.AuthService (AuthResult (..), register)
import qualified Application.Services.ConfigurationService as ConfigurationService
import Domain.Core.Types
  ( AccountRole (..),
    Currency (..),
    unAccountId,
    unUserId,
    unsafeMoney,
  )
import Infrastructure.App (runAppM)
import RIO
import qualified RIO.Set as Set
import Test.Hspec
import qualified Testkit.Fixtures as Fixtures
import Testkit.Helpers (fromRight')
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Persistent Account read model" $ do
  describe "per-tenant isolation (getAccountIds)" $ do
    it "scopes accessible accounts to the owning user; no cross-tenant leakage" $ do
      env <- createTestAppEnvWithProcessManager
      runAppM env ConfigurationService.seedDefaultConfiguration
      (userA, acctA) <- Fixtures.registerWithAccount env "alice@test.com" "Alice Savings"
      (userB, acctB) <- Fixtures.registerWithAccount env "bob@test.com" "Bob Savings"

      idsA <- runDbIn env (getAccountIds userA)
      idsB <- runDbIn env (getAccountIds userB)

      -- Each owner sees their own Regular account.
      Set.member acctA idsA `shouldBe` True
      Set.member acctB idsB `shouldBe` True
      -- And neither sees the other's — the access table is partitioned by user.
      Set.member acctB idsA `shouldBe` False
      Set.member acctA idsB `shouldBe` False

  describe "shared-account visibility (getAccounts)" $ do
    it "surfaces a shared account to the grantee with the granted role" $ do
      env <- createTestAppEnvWithProcessManager
      runAppM env ConfigurationService.seedDefaultConfiguration
      (owner, acct) <- Fixtures.registerWithAccount env "owner@test.com" "Joint"
      granteeReg <- runAppM env $ register "grantee@test.com" "password123"
      let grantee = (fromRight' granteeReg).userId

      -- Before sharing, the grantee cannot see the account.
      idsBefore <- runDbIn env (getAccountIds grantee)
      Set.member acct idsBefore `shouldBe` False

      shareRes <-
        runAppM env
          $ shareAccount owner (unAccountId acct) (unUserId grantee) "editor"
      shareRes `shouldBe` Right ()

      -- After sharing, the account shows up for the grantee as Editor.
      visible <- runDbIn env (getAccounts grantee)
      let roleFor = lookup acct [(aid, role) | (aid, _, role) <- visible]
      roleFor `shouldBe` Just Editor

    it "surfaces a shared account to the grantee in the regular-account list" $ do
      env <- createTestAppEnvWithProcessManager
      runAppM env ConfigurationService.seedDefaultConfiguration
      (owner, acct) <- Fixtures.registerWithAccount env "sharer@test.com" "Shared"
      granteeReg <- runAppM env $ register "regular-grantee@test.com" "password123"
      let grantee = (fromRight' granteeReg).userId

      -- Before sharing, the account is not in the grantee's regular-account list.
      before <- runDbIn env (getRegularAccounts grantee)
      (acct `elem` map fst before) `shouldBe` False

      shareRes <-
        runAppM env
          $ shareAccount owner (unAccountId acct) (unUserId grantee) "editor"
      shareRes `shouldBe` Right ()

      -- After sharing, it shows up in the grantee's regular-account list.
      after <- runDbIn env (getRegularAccounts grantee)
      (acct `elem` map fst after) `shouldBe` True

  describe "version recorded from the event (not version + 1)" $ do
    it "row version tracks the real per-stream EventVersion (0-based, monotone)" $ do
      env <- createTestAppEnvWithProcessManager
      runAppM env ConfigurationService.seedDefaultConfiguration
      (_, acct) <- Fixtures.registerWithAccount env "ver@test.com" "Tracked"

      -- AccountCreated is the first event on the stream → version 0.
      v0 <- runDbIn env (fmap (fmap (.version)) (getAccount acct))
      v0 `shouldBe` Just 0

      -- Each subsequent command appends exactly one event, so the recorded
      -- version follows the stream: 0 → 1 → 2.
      Fixtures.creditAccount env acct 1 (unsafeMoney USD 10)
      v1 <- runDbIn env (fmap (fmap (.version)) (getAccount acct))
      v1 `shouldBe` Just 1

      Fixtures.creditAccount env acct 2 (unsafeMoney USD 10)
      v2 <- runDbIn env (fmap (fmap (.version)) (getAccount acct))
      v2 `shouldBe` Just 2
