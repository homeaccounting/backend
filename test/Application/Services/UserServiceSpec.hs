{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.UserServiceSpec
-- Description : Unit tests for UserService orchestration
--
-- Tests the UserService layer which orchestrates user profile operations
-- using in-memory event stores. Validates that the service correctly:
--   - Retrieves user profiles from the read model
--   - Changes passwords with validation
--   - Unlinks OAuth/Telegram with login method safety checks
--   - Returns appropriate DomainErrors for invalid operations
module Application.Services.UserServiceSpec (spec) where

import Application.ReadModels.UserSummary (UserSummaryData (..))
import Application.Services.UserService
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Domain.User.CommandHandler (UserCommand (..))
import Domain.User.Commands
  ( LinkOAuthAccount (..),
    LinkTelegramAccount (..),
    RegisterUser (..),
  )
import Infrastructure.App (AppEnv, HasEventStore (..), runAppM)
import Infrastructure.Eventium (applyUserCommand)
import RIO
import Test.Hspec
import TestSupport.Helpers
  ( fromRight',
    mockAccountId,
    mockPasswordHash,
    mockUserId,
    shouldBeLeft,
    shouldBeRight,
  )
import TestSupport.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid :: UUID
testUserUuid = UUID.fromWords 1 0 0 0

testUserId :: UserId
testUserId = mockUserId testUserUuid

testExternalAccountId :: AccountId
testExternalAccountId = mockAccountId (UUID.fromWords 10 0 0 0)

testOAuthIdentity :: OAuthIdentity
testOAuthIdentity =
  OAuthIdentity
    { provider = Google,
      subject = "google-subject-123"
    }

testTelegramIdentity :: TelegramIdentity
testTelegramIdentity =
  TelegramIdentity
    { id = TelegramId 123456789,
      username = Just "testuser",
      firstName = "Test"
    }

-- | Register a test user with password via event store.
registerTestUser :: AppEnv -> IO ()
registerTestUser env = runAppM env $ do
  let registerCmd =
        RegisterUserUserCommand
          RegisterUser
            { email = "test@example.com",
              passwordHash = mockPasswordHash "hashed-password",
              externalAccountId = testExternalAccountId
            }
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  _ <- liftIO $ applyUserCommand writer reader testUserUuid registerCmd
  return ()

-- | Link an OAuth identity to the test user.
linkOAuth :: AppEnv -> OAuthIdentity -> IO ()
linkOAuth env ident = runAppM env $ do
  let linkCmd =
        LinkOAuthAccountUserCommand
          LinkOAuthAccount
            { identity = ident
            }
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  _ <- liftIO $ applyUserCommand writer reader testUserUuid linkCmd
  return ()

-- | Link Telegram to the test user.
linkTelegram :: AppEnv -> IO ()
linkTelegram env = runAppM env $ do
  let linkCmd =
        LinkTelegramAccountUserCommand
          LinkTelegramAccount
            { identity = testTelegramIdentity
            }
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  _ <- liftIO $ applyUserCommand writer reader testUserUuid linkCmd
  return ()

-- -----------------------------------------------------------------------------
-- Tests
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "UserService" $ do
  describe "getProfile" $ do
    it "returns user profile for registered user" $ do
      env <- createTestAppEnv
      registerTestUser env
      result <- runAppM env $ getProfile testUserId
      shouldBeRight result
      let (retId, userData) = fromRight' result
      retId `shouldBe` testUserId
      userData.email `shouldBe` Just "test@example.com"
      userData.hasPassword `shouldBe` True

    it "returns NotFound for non-existent user" $ do
      env <- createTestAppEnv
      let unknownUserId = mockUserId (UUID.fromWords 99 99 99 99)
      result <- runAppM env $ getProfile unknownUserId
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

  describe "changePassword" $ do
    it "changes password successfully" $ do
      env <- createTestAppEnv
      registerTestUser env
      result <- runAppM env $ changePassword testUserId "old-password" "new-secure-password"
      shouldBeRight result

    it "rejects password shorter than 8 characters" $ do
      env <- createTestAppEnv
      registerTestUser env
      result <- runAppM env $ changePassword testUserId "old-password" "short"
      shouldBeLeft result
      case result of
        Left (ValidationErr _) -> pure ()
        Left err -> expectationFailure $ "Expected ValidationErr, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

  describe "unlinkOAuth" $ do
    it "unlinks an OAuth provider when user has another login method" $ do
      env <- createTestAppEnv
      registerTestUser env -- has password
      linkOAuth env testOAuthIdentity -- add OAuth
      result <- runAppM env $ unlinkOAuth testUserId "google"
      shouldBeRight result

    it "rejects unlinking unknown OAuth provider" $ do
      env <- createTestAppEnv
      registerTestUser env
      result <- runAppM env $ unlinkOAuth testUserId "unknown-provider"
      shouldBeLeft result
      case result of
        Left (ValidationErr _) -> pure ()
        Left err -> expectationFailure $ "Expected ValidationErr, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "rejects unlinking OAuth provider that is not linked" $ do
      env <- createTestAppEnv
      registerTestUser env
      result <- runAppM env $ unlinkOAuth testUserId "github"
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "returns NotFound for non-existent user" $ do
      env <- createTestAppEnv
      let unknownUserId = mockUserId (UUID.fromWords 99 99 99 99)
      result <- runAppM env $ unlinkOAuth unknownUserId "google"
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

  describe "unlinkTelegram" $ do
    it "unlinks Telegram when user has another login method" $ do
      env <- createTestAppEnv
      registerTestUser env -- has password
      linkTelegram env -- add Telegram
      result <- runAppM env $ unlinkTelegram testUserId
      shouldBeRight result

    it "rejects unlinking Telegram when not linked" $ do
      env <- createTestAppEnv
      registerTestUser env
      result <- runAppM env $ unlinkTelegram testUserId
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "returns NotFound for non-existent user" $ do
      env <- createTestAppEnv
      let unknownUserId = mockUserId (UUID.fromWords 99 99 99 99)
      result <- runAppM env $ unlinkTelegram unknownUserId
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"
