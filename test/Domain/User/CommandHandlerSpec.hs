{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.User.CommandHandlerSpec
-- Description : Unit tests for User command handler
--
-- This module tests the User aggregate command handler business logic.
--
-- Test Coverage:
--   - RegisterUser: User registration with email and password
--   - RegisterViaTelegram: User registration via Telegram
--   - LinkOAuthAccount: Linking OAuth identities
--   - LinkTelegramAccount: Linking Telegram accounts
--   - UnlinkOAuthAccount: Unlinking OAuth identities
--   - UnlinkTelegramAccount: Unlinking Telegram accounts
--   - ChangePassword: Password changes
--   - State transitions and invariants
module Domain.User.CommandHandlerSpec (spec) where

import Data.Either (isLeft)
import Data.Text.Encoding (encodeUtf8)
import Domain.Core.Types
import Domain.User
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Testkit.Generators ()
import Testkit.Helpers
import Prelude (head, read)

spec :: Spec
spec = do
  registerUserSpec
  registerViaTelegramSpec
  linkOAuthAccountSpec
  linkTelegramAccountSpec
  unlinkOAuthAccountSpec
  unlinkTelegramAccountSpec
  changePasswordSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get user state
applyEvents :: [UserEvent] -> User
applyEvents = latestProjection userProjection

-- | Create a default empty user (no events applied)
emptyUser :: User
emptyUser = applyEvents []

-- | Create test password hash
testPasswordHash :: PasswordHash
testPasswordHash = mockPasswordHash $ encodeUtf8 "argon2id$test-hash-bytes"

-- | Create a second password hash for testing changes
testPasswordHash2 :: PasswordHash
testPasswordHash2 = mockPasswordHash $ encodeUtf8 "argon2id$different-hash"

-- | Create a test external account ID
testExternalAccountId :: AccountId
testExternalAccountId = mockAccountId (read "12345678-1234-1234-1234-123456789abc")

-- | Create a test user with email/password
registeredUser :: User
registeredUser =
  applyEvents
    [ UserRegisteredUserEvent
        $ UserRegistered
          { email = "test@example.com",
            passwordHash = testPasswordHash,
            externalAccountId = testExternalAccountId
          }
    ]

-- | Create a test user registered via Telegram
telegramUser :: User
telegramUser =
  applyEvents
    [ UserRegisteredViaTelegramUserEvent
        $ UserRegisteredViaTelegram
          { identity = testTelegramIdentity,
            externalAccountId = testExternalAccountId
          }
    ]

-- | Test Telegram identity
testTelegramIdentity :: TelegramIdentity
testTelegramIdentity =
  TelegramIdentity
    { id = mockTelegramId 123456789,
      username = Just "testuser",
      firstName = "Test"
    }

-- | Test OAuth identity
testOAuthIdentity :: OAuthIdentity
testOAuthIdentity =
  OAuthIdentity
    { provider = Google,
      subject = "google-subject-12345"
    }

-- | Create user with multiple login methods (password + OAuth)
userWithMultipleLogins :: User
userWithMultipleLogins =
  applyEvents
    [ UserRegisteredUserEvent
        $ UserRegistered
          { email = "multi@example.com",
            passwordHash = testPasswordHash,
            externalAccountId = testExternalAccountId
          },
      OAuthAccountLinkedUserEvent
        $ OAuthAccountLinked
          { identity = testOAuthIdentity
          }
    ]

-- -----------------------------------------------------------------------------
-- RegisterUser Tests
-- -----------------------------------------------------------------------------

registerUserSpec :: Spec
registerUserSpec = describe "RegisterUser Command" $ do
  context "Given empty user" $ do
    describe "When registering with valid email and password" $ do
      it "Then emits UserRegistered event" $ do
        let user = emptyUser
        let command =
              RegisterUserUserCommand
                $ RegisterUser
                  { email = "new@example.com",
                    passwordHash = testPasswordHash,
                    externalAccountId = testExternalAccountId
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              UserRegisteredUserEvent registered -> do
                registered.email `shouldBe` "new@example.com"
                registered.passwordHash `shouldBe` testPasswordHash
                registered.externalAccountId `shouldBe` testExternalAccountId
              _ -> expectationFailure "Expected UserRegistered event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then created user has correct state" $ do
        let user = emptyUser
        let command =
              RegisterUserUserCommand
                $ RegisterUser
                  { email = "new@example.com",
                    passwordHash = testPasswordHash,
                    externalAccountId = testExternalAccountId
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            let newUser = applyEvents events
            newUser ^. #email `shouldBe` "new@example.com"
            newUser ^. #passwordHash `shouldBe` Just testPasswordHash
            newUser ^. #externalAccountId `shouldBe` testExternalAccountId
            newUser ^. #isRegistered `shouldBe` True
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given existing user" $ do
    describe "When attempting to register again" $ do
      it "Then ignores command (no events)" $ do
        let user = registeredUser
        let command =
              RegisterUserUserCommand
                $ RegisterUser
                  { email = "another@example.com",
                    passwordHash = testPasswordHash,
                    externalAccountId = testExternalAccountId
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- RegisterViaTelegram Tests
-- -----------------------------------------------------------------------------

registerViaTelegramSpec :: Spec
registerViaTelegramSpec = describe "RegisterViaTelegram Command" $ do
  context "Given empty user" $ do
    describe "When registering via Telegram" $ do
      it "Then emits UserRegisteredViaTelegram event" $ do
        let user = emptyUser
        let command =
              RegisterViaTelegramUserCommand
                $ RegisterViaTelegram
                  { identity = testTelegramIdentity,
                    externalAccountId = testExternalAccountId
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              UserRegisteredViaTelegramUserEvent registered -> do
                registered.identity `shouldBe` testTelegramIdentity
                registered.externalAccountId `shouldBe` testExternalAccountId
              _ -> expectationFailure "Expected UserRegisteredViaTelegram event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then created user has Telegram identity" $ do
        let user = emptyUser
        let command =
              RegisterViaTelegramUserCommand
                $ RegisterViaTelegram
                  { identity = testTelegramIdentity,
                    externalAccountId = testExternalAccountId
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            let newUser = applyEvents events
            newUser ^. #telegramIdentity `shouldBe` Just testTelegramIdentity
            newUser ^. #passwordHash `shouldBe` Nothing -- No password for Telegram users
            newUser ^. #externalAccountId `shouldBe` testExternalAccountId
            newUser ^. #isRegistered `shouldBe` True
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given existing user" $ do
    describe "When attempting to register via Telegram" $ do
      it "Then ignores command (no events)" $ do
        let user = registeredUser
        let command =
              RegisterViaTelegramUserCommand
                $ RegisterViaTelegram
                  { identity = testTelegramIdentity,
                    externalAccountId = testExternalAccountId
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- LinkOAuthAccount Tests
-- -----------------------------------------------------------------------------

linkOAuthAccountSpec :: Spec
linkOAuthAccountSpec = describe "LinkOAuthAccount Command" $ do
  context "Given registered user" $ do
    describe "When linking OAuth account" $ do
      it "Then emits OAuthAccountLinked event" $ do
        let user = registeredUser
        let command =
              LinkOAuthAccountUserCommand
                $ LinkOAuthAccount
                  { identity = testOAuthIdentity
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              OAuthAccountLinkedUserEvent linked ->
                linked.identity `shouldBe` testOAuthIdentity
              _ -> expectationFailure "Expected OAuthAccountLinked event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then user has OAuth identity in list" $ do
        let user = registeredUser
        let command =
              LinkOAuthAccountUserCommand
                $ LinkOAuthAccount
                  { identity = testOAuthIdentity
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            let updatedUser = latestProjection userProjection (toUserEvents registeredUser <> events)
            testOAuthIdentity `elem` (updatedUser ^. #oauthIdentities) `shouldBe` True
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given unregistered user" $ do
    describe "When attempting to link OAuth" $ do
      it "Then ignores command (no events)" $ do
        let user = emptyUser
        let command =
              LinkOAuthAccountUserCommand
                $ LinkOAuthAccount
                  { identity = testOAuthIdentity
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

  context "Given user with OAuth already linked" $ do
    describe "When attempting to link same provider" $ do
      it "Then ignores command (no events)" $ do
        let user = userWithMultipleLogins
        let command =
              LinkOAuthAccountUserCommand
                $ LinkOAuthAccount
                  { identity = testOAuthIdentity -- Same provider (Google)
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- LinkTelegramAccount Tests
-- -----------------------------------------------------------------------------

linkTelegramAccountSpec :: Spec
linkTelegramAccountSpec = describe "LinkTelegramAccount Command" $ do
  context "Given registered user without Telegram" $ do
    describe "When linking Telegram account" $ do
      it "Then emits TelegramAccountLinked event" $ do
        let user = registeredUser
        let command =
              LinkTelegramAccountUserCommand
                $ LinkTelegramAccount
                  { identity = testTelegramIdentity
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TelegramAccountLinkedUserEvent linked ->
                linked.identity `shouldBe` testTelegramIdentity
              _ -> expectationFailure "Expected TelegramAccountLinked event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then user has Telegram identity" $ do
        let user = registeredUser
        let command =
              LinkTelegramAccountUserCommand
                $ LinkTelegramAccount
                  { identity = testTelegramIdentity
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            let updatedUser = latestProjection userProjection (toUserEvents registeredUser <> events)
            updatedUser ^. #telegramIdentity `shouldBe` Just testTelegramIdentity
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given unregistered user" $ do
    describe "When attempting to link Telegram" $ do
      it "Then ignores command (no events)" $ do
        let user = emptyUser
        let command =
              LinkTelegramAccountUserCommand
                $ LinkTelegramAccount
                  { identity = testTelegramIdentity
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

  context "Given user with Telegram already linked" $ do
    describe "When attempting to link again" $ do
      it "Then ignores command (no events)" $ do
        let user = telegramUser
        let differentTelegram =
              TelegramIdentity
                { id = mockTelegramId 987654321,
                  username = Just "otheruser",
                  firstName = "Other"
                }
        let command =
              LinkTelegramAccountUserCommand
                $ LinkTelegramAccount
                  { identity = differentTelegram
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- UnlinkOAuthAccount Tests
-- -----------------------------------------------------------------------------

unlinkOAuthAccountSpec :: Spec
unlinkOAuthAccountSpec = describe "UnlinkOAuthAccount Command" $ do
  context "Given user with multiple login methods" $ do
    describe "When unlinking OAuth account" $ do
      it "Then emits OAuthAccountUnlinked event" $ do
        let user = userWithMultipleLogins
        let command =
              UnlinkOAuthAccountUserCommand
                $ UnlinkOAuthAccount
                  { identity = testOAuthIdentity
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              OAuthAccountUnlinkedUserEvent unlinked ->
                unlinked.identity `shouldBe` testOAuthIdentity
              _ -> expectationFailure "Expected OAuthAccountUnlinked event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then OAuth identity is removed" $ do
        let user = userWithMultipleLogins
        let command =
              UnlinkOAuthAccountUserCommand
                $ UnlinkOAuthAccount
                  { identity = testOAuthIdentity
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            let updatedUser = latestProjection userProjection (toUserEvents userWithMultipleLogins <> events)
            testOAuthIdentity `elem` (updatedUser ^. #oauthIdentities) `shouldBe` False
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given user with only OAuth login" $ do
    describe "When attempting to unlink OAuth" $ do
      it "Then ignores command (would leave user without login)" $ do
        -- Create user with only OAuth
        let oauthOnlyUser =
              latestProjection
                userProjection
                [ UserRegisteredUserEvent
                    $ UserRegistered
                      { email = "oauth@example.com",
                        passwordHash = testPasswordHash,
                        externalAccountId = testExternalAccountId
                      }
                ]
        -- This user has password + no OAuth yet, so we need a different test
        -- Actually, we need to test that when loginMethodCount <= 1, we reject
        -- For a user with only OAuth (no password), we can't create that state
        -- through normal commands since RegisterUser requires password.
        -- So we test with a user that has password + OAuth but would be left with
        -- password only (which is fine).
        -- The real test for "only one login method" is when we try to remove
        -- the last method, which would be covered by UnlinkTelegramAccount
        pendingWith
          "OAuth-only users not supported through standard registration"

-- -----------------------------------------------------------------------------
-- UnlinkTelegramAccount Tests
-- -----------------------------------------------------------------------------

unlinkTelegramAccountSpec :: Spec
unlinkTelegramAccountSpec = describe "UnlinkTelegramAccount Command" $ do
  context "Given user with password and Telegram" $ do
    describe "When unlinking Telegram" $ do
      it "Then emits TelegramAccountUnlinked event" $ do
        -- Create user with both password and Telegram
        let userWithBoth =
              latestProjection
                userProjection
                [ UserRegisteredUserEvent
                    $ UserRegistered
                      { email = "both@example.com",
                        passwordHash = testPasswordHash,
                        externalAccountId = testExternalAccountId
                      },
                  TelegramAccountLinkedUserEvent
                    $ TelegramAccountLinked
                      { identity = testTelegramIdentity
                      }
                ]
        let command = UnlinkTelegramAccountUserCommand UnlinkTelegramAccount
        let result = handleUserCommand userWithBoth command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              TelegramAccountUnlinkedUserEvent TelegramAccountUnlinked -> pure ()
              _ -> expectationFailure "Expected TelegramAccountUnlinked event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given user with only Telegram login" $ do
    describe "When attempting to unlink Telegram" $ do
      it "Then ignores command (would leave user without login)" $ do
        let user = telegramUser -- Only has Telegram, no password
        let command = UnlinkTelegramAccountUserCommand UnlinkTelegramAccount
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

  context "Given user without Telegram linked" $ do
    describe "When attempting to unlink Telegram" $ do
      it "Then ignores command (nothing to unlink)" $ do
        let user = registeredUser -- No Telegram linked
        let command = UnlinkTelegramAccountUserCommand UnlinkTelegramAccount
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- ChangePassword Tests
-- -----------------------------------------------------------------------------

changePasswordSpec :: Spec
changePasswordSpec = describe "ChangePassword Command" $ do
  context "Given registered user" $ do
    describe "When changing password" $ do
      it "Then emits PasswordChanged event" $ do
        let user = registeredUser
        let command =
              ChangePasswordUserCommand
                $ ChangePassword
                  { newHash = testPasswordHash2
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              PasswordChangedUserEvent changed ->
                changed.newHash `shouldBe` testPasswordHash2
              _ -> expectationFailure "Expected PasswordChanged event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then user has new password" $ do
        let user = registeredUser
        let command =
              ChangePasswordUserCommand
                $ ChangePassword
                  { newHash = testPasswordHash2
                  }
        let result = handleUserCommand user command

        case result of
          Right events -> do
            let updatedUser = latestProjection userProjection (toUserEvents registeredUser <> events)
            updatedUser ^. #passwordHash `shouldBe` Just testPasswordHash2
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given unregistered user" $ do
    describe "When attempting to change password" $ do
      it "Then ignores command (no events)" $ do
        let user = emptyUser
        let command =
              ChangePasswordUserCommand
                $ ChangePassword
                  { newHash = testPasswordHash2
                  }
        let result = handleUserCommand user command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- Helper to convert User state to events
-- -----------------------------------------------------------------------------

-- | Convert a registered user back to its events for testing projections
toUserEvents :: User -> [UserEvent]
toUserEvents user
  | not (user ^. #isRegistered) = []
  | otherwise =
      baseEvent : oauthEvents <> telegramEvent
  where
    baseEvent =
      UserRegisteredUserEvent
        $ UserRegistered
          { email = user ^. #email,
            passwordHash = fromMaybe testPasswordHash (user ^. #passwordHash),
            externalAccountId = user ^. #externalAccountId
          }
    oauthEvents =
      map
        ( \ident ->
            OAuthAccountLinkedUserEvent
              $ OAuthAccountLinked {identity = ident}
        )
        (user ^. #oauthIdentities)
    telegramEvent =
      case user ^. #telegramIdentity of
        Just ident ->
          [ TelegramAccountLinkedUserEvent
              $ TelegramAccountLinked {identity = ident}
          ]
        Nothing -> []
