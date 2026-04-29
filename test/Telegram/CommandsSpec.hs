{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.CommandsSpec
-- Description : Integration tests for Telegram bot command handlers.
--
-- These tests use the in-memory event store so they run without a database.
-- Outgoing Telegram messages are silently dropped (telegramClientEnv = Nothing)
-- so tests assert only on read-model side-effects, not reply text.
module Telegram.CommandsSpec (spec) where

import Application.LinkCodeStore (mkLinkCodeToken)
import Application.ReadModels.User (getUserByTelegramId)
import Application.Services.AuthService
  ( TelegramLinkCodeResult (..),
    findOrCreateTelegramBotUser,
    issueTelegramLinkCode,
  )
import Domain.Core.Types
  ( TelegramId (..),
    TelegramIdentity (..),
  )
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import RIO
import qualified RIO.Text as T
import Telegram.Commands (handleSignup, handleStart)
import Telegram.Types (emptyBotState)
import Test.Hspec
import Testkit.Fixtures (registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Extract the raw token text from a deep-link URL of the form
-- @https://t.me/<bot>?start=LINK_<token>@.
extractTokenText :: TelegramLinkCodeResult -> TelegramConfig -> Text
extractTokenText result tgCfg =
  let prefix = "https://t.me/" <> tgCfg.botUsername <> "?start=LINK_"
   in T.drop (T.length prefix) result.deepLink

-- | A test Telegram identity that is NOT yet registered in the store.
freshTgIdent :: TelegramIdentity
freshTgIdent =
  TelegramIdentity
    { id = TelegramId 987654321,
      username = Just "fresh_user",
      firstName = "Fresh"
    }

-- | Dummy chat id used for all sendMsg calls (silently dropped in tests).
testChatId :: Int64
testChatId = 100

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "handleStart" $ do
    it "/start LINK_<valid-token> attaches the Telegram identity to the issuing user" $ do
      env <- createTestAppEnv
      uid <- registerUser env "alice@example.com"

      -- Issue a link code for the registered user.
      issueRes <- runAppM env $ issueTelegramLinkCode uid
      tokText <- case issueRes of
        Left err -> fail $ "issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ extractTokenText r env.telegramConfig

      -- Call handleStart with the LINK_ payload.
      botState <- newTVarIO emptyBotState
      runAppM env $ handleStart botState freshTgIdent testChatId (Just ("LINK_" <> tokText))

      -- The Telegram identity must now be linked to the issuing user.
      linked <- getUserByTelegramId env.userReadModel freshTgIdent.id
      case linked of
        Nothing -> expectationFailure "expected Telegram identity to be linked after handleStart LINK_"
        Just (linkedUid, _) -> linkedUid `shouldBe` uid

    it "/start LINK_<garbage> does NOT attach the Telegram identity and does NOT create a new user" $ do
      env <- createTestAppEnv
      _uid <- registerUser env "bob@example.com"

      botState <- newTVarIO emptyBotState
      runAppM env $ handleStart botState freshTgIdent testChatId (Just "LINK_not-a-real-token")

      -- The fresh Telegram identity must not be linked to anyone.
      linked <- getUserByTelegramId env.userReadModel freshTgIdent.id
      linked `shouldBe` Nothing

    it "/start (no payload) from an unknown Telegram ID does NOT create a user" $ do
      env <- createTestAppEnv

      botState <- newTVarIO emptyBotState
      runAppM env $ handleStart botState freshTgIdent testChatId Nothing

      -- The fresh Telegram identity must remain absent from the read model.
      result <- getUserByTelegramId env.userReadModel freshTgIdent.id
      result `shouldBe` Nothing

    it "/start (no payload) from an already-linked Telegram ID is idempotent" $ do
      env <- createTestAppEnv

      -- Register the Telegram user explicitly via the /signup path.
      registerResult <- runAppM env $ findOrCreateTelegramBotUser freshTgIdent
      uid <- case registerResult of
        Left err -> fail $ "findOrCreateTelegramBotUser failed: " <> show err
        Right (userId, _) -> pure userId

      botState <- newTVarIO emptyBotState
      runAppM env $ handleStart botState freshTgIdent testChatId Nothing

      -- The user must still be present and unchanged.
      result <- getUserByTelegramId env.userReadModel freshTgIdent.id
      case result of
        Nothing -> expectationFailure "expected Telegram identity to still be linked after /start"
        Just (linkedUid, _) -> linkedUid `shouldBe` uid

  describe "handleSignup" $ do
    it "/signup from an unknown Telegram ID creates the user" $ do
      env <- createTestAppEnv

      botState <- newTVarIO emptyBotState
      runAppM env $ handleSignup botState freshTgIdent testChatId Nothing

      -- The Telegram identity must now be present in the read model.
      result <- getUserByTelegramId env.userReadModel freshTgIdent.id
      result `shouldSatisfy` (/= Nothing)

    it "/signup from an already-linked Telegram ID is idempotent" $ do
      env <- createTestAppEnv

      -- Register first.
      registerResult <- runAppM env $ findOrCreateTelegramBotUser freshTgIdent
      uid <- case registerResult of
        Left err -> fail $ "findOrCreateTelegramBotUser failed: " <> show err
        Right (userId, _) -> pure userId

      -- Call /signup again.
      botState <- newTVarIO emptyBotState
      runAppM env $ handleSignup botState freshTgIdent testChatId Nothing

      -- Must still map to the same user ID — no duplicate creation.
      result <- getUserByTelegramId env.userReadModel freshTgIdent.id
      case result of
        Nothing -> expectationFailure "expected Telegram identity to still be linked after /signup"
        Just (linkedUid, _) -> linkedUid `shouldBe` uid
