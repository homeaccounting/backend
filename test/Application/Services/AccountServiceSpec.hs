{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AccountServiceSpec
-- Description : Unit tests for AccountService orchestration
--
-- Tests the AccountService layer which orchestrates account operations
-- using in-memory event stores. Validates that the service correctly:
--   - Creates accounts and returns domain types
--   - Queries accounts from the read model
--   - Enforces ownership rules for sharing/revoking
--   - Returns appropriate DomainErrors for invalid operations
module Application.Services.AccountServiceSpec (spec) where

import Application.ReadModels.Account (AccountData (..))
import Application.Services.AccountService
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Testkit.Helpers (fromRight', mockMoney, mockUserId, shouldBeLeft, shouldBeRight)
import Testkit.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid1 :: UUID
testUserUuid1 = UUID.fromWords 1 0 0 0

testUserUuid2 :: UUID
testUserUuid2 = UUID.fromWords 2 0 0 0

testUserId1 :: UserId
testUserId1 = mockUserId testUserUuid1

testUserId2 :: UserId
testUserId2 = mockUserId testUserUuid2

validCreateAccount :: CreateAccount
validCreateAccount =
  CreateAccount
    { name = "Savings",
      initialBalance = mockMoney 1000,
      createdBy = testUserId1,
      accountCategory = Regular defaultCash,
      overdraftLimit = Nothing
    }

-- | Helper to create an account and extract the AccountId.
createTestAccount :: CreateAccount -> IO (AppEnv, AccountId)
createTestAccount cmd = do
  env <- createTestAppEnv
  result <- runAppM env $ createAccount cmd
  let (aid, _) = fromRight' result
  return (env, aid)

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "AccountService" $ do
  describe "createAccount" $ do
    it "creates an account and returns AccountId and AccountData" $ do
      env <- createTestAppEnv
      result <- runAppM env $ createAccount validCreateAccount
      shouldBeRight result
      let (_, summary) = fromRight' result
      summary.name `shouldBe` "Savings"
      summary.balance `shouldBe` mockMoney 1000
      summary.createdBy `shouldBe` testUserId1
      summary.accountCategory `shouldBe` Regular defaultCash

    it "creates an account with zero initial balance" $ do
      env <- createTestAppEnv
      let cmd = validCreateAccount {initialBalance = mockMoney 0}
      result <- runAppM env $ createAccount cmd
      shouldBeRight result
      let (_, summary) = fromRight' result
      summary.balance `shouldBe` mockMoney 0

    it "creates an External account" $ do
      env <- createTestAppEnv
      let cmd = (validCreateAccount :: CreateAccount) {accountCategory = External}
      result <- runAppM env $ createAccount cmd
      shouldBeRight result
      let (_, summary) = fromRight' result
      summary.accountCategory `shouldBe` External

  describe "getAccount" $ do
    it "retrieves a previously created account" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      result <- runAppM env $ getAccount (unAccountId accountId)
      shouldBeRight result
      let (retId, summary) = fromRight' result
      retId `shouldBe` accountId
      summary.name `shouldBe` "Savings"

    it "returns NotFound for non-existent account" $ do
      env <- createTestAppEnv
      let nonExistentUuid = UUID.fromWords 99 99 99 99
      result <- runAppM env $ getAccount nonExistentUuid
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

  describe "listAccountsForUser" $ do
    it "returns empty list when no accounts exist" $ do
      env <- createTestAppEnv
      result <- runAppM env $ listAccountsForUser testUserId1
      result `shouldBe` []

    it "returns only accounts accessible to the user" $ do
      env <- createTestAppEnv
      _ <- runAppM env $ do
        _ <- createAccount validCreateAccount
        createAccount validCreateAccount {name = "Checking"}
      result <- runAppM env $ listAccountsForUser testUserId1
      length result `shouldBe` 2

    it "does not return accounts owned by other users" $ do
      env <- createTestAppEnv
      _ <- runAppM env $ do
        _ <- createAccount validCreateAccount
        createAccount
          validCreateAccount
            { name = "Other User Account",
              createdBy = testUserId2
            }
      user1Accounts <- runAppM env $ listAccountsForUser testUserId1
      user2Accounts <- runAppM env $ listAccountsForUser testUserId2
      length user1Accounts `shouldBe` 1
      length user2Accounts `shouldBe` 1

    it "returns shared accounts" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      _ <- runAppM env $ shareAccount testUserId1 (unAccountId accountId) testUserUuid2 "viewer"
      user2Accounts <- runAppM env $ listAccountsForUser testUserId2
      length user2Accounts `shouldBe` 1

  describe "shareAccount" $ do
    it "shares an account with another user" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      result <- runAppM env $ shareAccount testUserId1 (unAccountId accountId) testUserUuid2 "editor"
      shouldBeRight result

    it "rejects sharing by non-owner" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      result <- runAppM env $ shareAccount testUserId2 (unAccountId accountId) testUserUuid1 "viewer"
      shouldBeLeft result
      case result of
        Left (AccountError _) -> pure ()
        Left err -> expectationFailure $ "Expected AccountError, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "rejects sharing External accounts" $ do
      let externalCmd = (validCreateAccount :: CreateAccount) {accountCategory = External}
      (env, accountId) <- createTestAccount externalCmd
      result <- runAppM env $ shareAccount testUserId1 (unAccountId accountId) testUserUuid2 "editor"
      shouldBeLeft result
      case result of
        Left (AccountError msg) -> msg `shouldBe` "External accounts cannot be shared"
        Left err -> expectationFailure $ "Expected AccountError, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "rejects sharing with invalid role" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      result <- runAppM env $ shareAccount testUserId1 (unAccountId accountId) testUserUuid2 "admin"
      shouldBeLeft result
      case result of
        Left (ValidationErr _) -> pure ()
        Left err -> expectationFailure $ "Expected ValidationErr, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "returns NotFound for non-existent account" $ do
      env <- createTestAppEnv
      let nonExistentUuid = UUID.fromWords 99 99 99 99
      result <- runAppM env $ shareAccount testUserId1 nonExistentUuid testUserUuid2 "editor"
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

  describe "revokeAccountAccess" $ do
    it "revokes a shared user's access" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      _ <- runAppM env $ shareAccount testUserId1 (unAccountId accountId) testUserUuid2 "editor"
      result <- runAppM env $ revokeAccountAccess testUserId1 (unAccountId accountId) testUserUuid2
      shouldBeRight result

    it "rejects revocation by non-owner" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      result <- runAppM env $ revokeAccountAccess testUserId2 (unAccountId accountId) testUserUuid1
      shouldBeLeft result
      case result of
        Left (AccountError _) -> pure ()
        Left err -> expectationFailure $ "Expected AccountError, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "rejects revoking owner's own access" $ do
      (env, accountId) <- createTestAccount validCreateAccount
      result <- runAppM env $ revokeAccountAccess testUserId1 (unAccountId accountId) testUserUuid1
      shouldBeLeft result
      case result of
        Left (AccountError msg) -> msg `shouldBe` "Cannot revoke owner's access"
        Left err -> expectationFailure $ "Expected AccountError, got: " <> show err
        Right _ -> expectationFailure "Expected Left"
