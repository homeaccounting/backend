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

import Application.ReadModels.User (UserData (..))
import Application.Services.UserService
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
import Domain.User.CommandHandler (UserCommand (..))
import Domain.User.Commands
  ( LinkOAuthAccount (..),
    LinkTelegramAccount (..),
    RegisterUser (..),
    RegisterViaTelegram (..),
  )
import Domain.User.Projection (User (..))
import Infrastructure.App (AppEnv, HasEventStore (..), runAppM)
import Infrastructure.Auth.Password (hashPassword, verifyPassword)
import Infrastructure.Eventium (applyUserCommand, loadUserAggregate)
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.Helpers
  ( fromRight',
    mockAccountId,
    mockPasswordHash,
    mockUserId,
    shouldBeLeft,
    shouldBeRight,
  )
import Testkit.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test Data
-- -----------------------------------------------------------------------------

testUserUuid :: UUID
testUserUuid = UUID.fromWords 1 0 0 0

testUserId :: UserId
testUserId = mockUserId testUserUuid

testExternalAccountId :: AccountId
testExternalAccountId = mockAccountId (UUID.fromWords 10 0 0 0)

-- | The password 'registerTestUserWithPassword' stores a real Argon2 hash of,
-- so that the current-password check has something genuine to verify against.
testCurrentPassword :: Text
testCurrentPassword = "current-password"

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

-- | Register a test user with a placeholder hash via the event store. Use this
-- when the test does not exercise the password itself — it skips the Argon2
-- work that 'registerTestUserWithPassword' pays for.
registerTestUser :: AppEnv -> IO ()
registerTestUser env = registerTestUserWithHash env (mockPasswordHash "hashed-password")

-- | Register the test user with a real Argon2 hash of @password@, so that
-- 'changePassword' can verify a current password against it.
registerTestUserWithPassword :: AppEnv -> Text -> IO ()
registerTestUserWithPassword env password =
  hashPassword password >>= registerTestUserWithHash env

-- | Read the password hash currently recorded on the user's aggregate.
storedPasswordHash :: AppEnv -> IO (Maybe PasswordHash)
storedPasswordHash env = runAppM env $ do
  reader <- view eventStoreReaderL
  user <- liftIO (loadUserAggregate reader testUserUuid)
  pure user.passwordHash

registerTestUserWithHash :: AppEnv -> PasswordHash -> IO ()
registerTestUserWithHash env hash = runAppM env $ do
  let registerCmd =
        RegisterUserUserCommand
          RegisterUser
            { email = "test@example.com",
              passwordHash = hash,
              externalAccountId = testExternalAccountId
            }
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  _ <- liftIO $ applyUserCommand writer reader id testUserUuid registerCmd
  return ()

-- | Register the test user through Telegram, i.e. with no password at all.
registerTestUserViaTelegram :: AppEnv -> IO ()
registerTestUserViaTelegram env = runAppM env $ do
  let registerCmd =
        RegisterViaTelegramUserCommand
          RegisterViaTelegram
            { identity = testTelegramIdentity,
              externalAccountId = testExternalAccountId
            }
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  _ <- liftIO $ applyUserCommand writer reader id testUserUuid registerCmd
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
  _ <- liftIO $ applyUserCommand writer reader id testUserUuid linkCmd
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
  _ <- liftIO $ applyUserCommand writer reader id testUserUuid linkCmd
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
    it "changes the password when the current password is correct" $ do
      env <- createTestAppEnv
      registerTestUserWithPassword env testCurrentPassword
      result <- runAppM env $ changePassword testUserId testCurrentPassword "new-secure-password"
      shouldBeRight result
      stored <- storedPasswordHash env
      (verifyPassword "new-secure-password" <$> stored) `shouldBe` Just True

    -- Reported against the @currentPassword@ field, not as a bare message: the
    -- web form maps 'fieldErrors' back onto its inputs.
    it "rejects the change when the current password is wrong" $ do
      env <- createTestAppEnv
      registerTestUserWithPassword env testCurrentPassword
      result <- runAppM env $ changePassword testUserId "not-the-current-password" "new-secure-password"
      shouldBeLeft result
      case result of
        Left (ValidationErr ve) -> ve.validationField `shouldBe` "currentPassword"
        other -> expectationFailure $ "Expected ValidationErr on currentPassword, got: " <> show other

    it "does not echo the rejected password back in the error" $ do
      env <- createTestAppEnv
      registerTestUserWithPassword env testCurrentPassword
      result <- runAppM env $ changePassword testUserId "not-the-current-password" "new-secure-password"
      case result of
        Left (ValidationErr ve) -> do
          ve.validationValue `shouldBe` ""
          ve.validationMessage `shouldNotSatisfy` T.isInfixOf "not-the-current-password"
        other -> expectationFailure $ "Expected ValidationErr, got: " <> show other

    -- The rejection above is only worth anything if nothing was written. A
    -- service that validates and then issues the command anyway would pass the
    -- previous test and still hand the account over.
    it "leaves the old password in place when the current password is wrong" $ do
      env <- createTestAppEnv
      registerTestUserWithPassword env testCurrentPassword
      _ <- runAppM env $ changePassword testUserId "not-the-current-password" "new-secure-password"
      stored <- storedPasswordHash env
      (verifyPassword testCurrentPassword <$> stored) `shouldBe` Just True
      (verifyPassword "new-secure-password" <$> stored) `shouldBe` Just False

    it "rejects a password change for a user with no password set" $ do
      env <- createTestAppEnv
      registerTestUserViaTelegram env
      result <- runAppM env $ changePassword testUserId "anything" "new-secure-password"
      shouldBeLeft result
      case result of
        Left (AccountError _) -> pure ()
        Left err -> expectationFailure $ "Expected AccountError, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "returns NotFound for non-existent user" $ do
      env <- createTestAppEnv
      let unknownUserId = mockUserId (UUID.fromWords 99 99 99 99)
      result <- runAppM env $ changePassword unknownUserId testCurrentPassword "new-secure-password"
      shouldBeLeft result
      case result of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "Expected NotFound, got: " <> show err
        Right _ -> expectationFailure "Expected Left"

    it "rejects password shorter than 8 characters" $ do
      env <- createTestAppEnv
      registerTestUserWithPassword env testCurrentPassword
      result <- runAppM env $ changePassword testUserId testCurrentPassword "short"
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
