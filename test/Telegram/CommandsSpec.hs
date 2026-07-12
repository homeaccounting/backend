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

import Application.ReadModels.Account (RegularAccountData (..), getUserRegularAccounts)
import Application.ReadModels.User (getUserByTelegramId)
import Application.Services.AuthService
  ( TelegramLinkCodeResult (..),
    findOrCreateTelegramBotUser,
    issueTelegramLinkCode,
  )
import Application.Services.ConfigurationService (seedDefaultConfiguration)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    TelegramId (..),
    TelegramIdentity (..),
    defaultCash,
    unMoney,
    unsafeAccountId,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Telegram.Commands (handleClearSelection, handleMessage, handleSignup, handleStart, parseCallbackData)
import Telegram.Types (BotState (..), CallbackData (..), emptyBotState)
import Test.Hspec
import Testkit.Fixtures (createAccount, registerUser)
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
    runDbIn,
  )
import Testkit.Llm (constLlmClient, withLlmClient)

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

-- | A fixed AccountId for seeding a selection in bot state.
someAccountId :: AccountId
someAccountId =
  unsafeAccountId (fromMaybe (error "bad uuid") (UUID.fromString "00000000-0000-0000-0000-000000000001"))

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
      linked <- runDbIn env (getUserByTelegramId freshTgIdent.id)
      case linked of
        Nothing -> expectationFailure "expected Telegram identity to be linked after handleStart LINK_"
        Just (linkedUid, _) -> linkedUid `shouldBe` uid

    it "/start LINK_<garbage> does NOT attach the Telegram identity and does NOT create a new user" $ do
      env <- createTestAppEnv
      _uid <- registerUser env "bob@example.com"

      botState <- newTVarIO emptyBotState
      runAppM env $ handleStart botState freshTgIdent testChatId (Just "LINK_not-a-real-token")

      -- The fresh Telegram identity must not be linked to anyone.
      linked <- runDbIn env (getUserByTelegramId freshTgIdent.id)
      linked `shouldBe` Nothing

    it "/start (no payload) from an unknown Telegram ID does NOT create a user" $ do
      env <- createTestAppEnv

      botState <- newTVarIO emptyBotState
      runAppM env $ handleStart botState freshTgIdent testChatId Nothing

      -- The fresh Telegram identity must remain absent from the read model.
      result <- runDbIn env (getUserByTelegramId freshTgIdent.id)
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
      result <- runDbIn env (getUserByTelegramId freshTgIdent.id)
      case result of
        Nothing -> expectationFailure "expected Telegram identity to still be linked after /start"
        Just (linkedUid, _) -> linkedUid `shouldBe` uid

  describe "handleMessage (natural-language prompt)" $ do
    it "records a free-text expense against the currently-selected account" $ do
      baseEnv <- createTestAppEnvWithProcessManager
      runAppM baseEnv seedDefaultConfiguration
      registered <- runAppM baseEnv (findOrCreateTelegramBotUser freshTgIdent)
      uid <- case registered of
        Left err -> fail ("findOrCreateTelegramBotUser failed: " <> show err)
        Right (userId, _) -> pure userId

      -- Two accounts: the expense must land on the *selected* one (Card), not
      -- the other, proving the selection is threaded through the bot path.
      -- USD matches the auto-created External account, so the expense is
      -- same-currency and needs no seeded exchange rate. Both start at 100 so
      -- the expense posts (no overdraft) and the debited account is unambiguous.
      cash <- createAccount baseEnv uid "Cash" defaultCash Core.USD 100
      card <- createAccount baseEnv uid "Card" defaultCash Core.USD 100

      botState <-
        newTVarIO
          emptyBotState {selectedAccounts = Map.singleton freshTgIdent.id (card, "Card")}

      -- The LLM returns an expense with no account named; the selection fills it.
      let json =
            "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"allocations\":[{\"amount\":\"42\",\"category\":\"Food\",\"comment\":\"snack\"}]}]}"
          env = withLlmClient (constLlmClient json) baseEnv
      runAppM env (handleMessage botState freshTgIdent.id testChatId "snack 42")

      accounts <- runDbIn env (getUserRegularAccounts uid)
      let balanceOf nm =
            listToMaybe [unMoney bal | (_, RegularAccountData {name = n, balance = bal}) <- accounts, n == nm]
      -- The selected account (Card) is debited; the other (Cash) is untouched.
      balanceOf "Card" `shouldBe` Just 58
      balanceOf "Cash" `shouldBe` Just 100
      cash `shouldNotBe` card

  describe "parseCallbackData" $ do
    it "parses \"unselect\" as ClearSelection"
      $ parseCallbackData "unselect"
      `shouldBe` Just ClearSelection

  describe "handleClearSelection" $ do
    it "removes the user's selected account from bot state" $ do
      env <- createTestAppEnv
      botState <-
        newTVarIO
          emptyBotState
            { selectedAccounts =
                Map.singleton freshTgIdent.id (someAccountId, "Cash")
            }
      runAppM env $ handleClearSelection botState freshTgIdent.id testChatId
      s <- readTVarIO botState
      Map.lookup freshTgIdent.id s.selectedAccounts `shouldBe` Nothing

    it "is a no-op when nothing was selected" $ do
      env <- createTestAppEnv
      botState <- newTVarIO emptyBotState
      runAppM env $ handleClearSelection botState freshTgIdent.id testChatId
      s <- readTVarIO botState
      s.selectedAccounts `shouldBe` Map.empty

  describe "handleSignup" $ do
    it "/signup from an unknown Telegram ID creates the user" $ do
      env <- createTestAppEnv

      botState <- newTVarIO emptyBotState
      runAppM env $ handleSignup botState freshTgIdent testChatId Nothing

      -- The Telegram identity must now be present in the read model.
      result <- runDbIn env (getUserByTelegramId freshTgIdent.id)
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
      result <- runDbIn env (getUserByTelegramId freshTgIdent.id)
      case result of
        Nothing -> expectationFailure "expected Telegram identity to still be linked after /signup"
        Just (linkedUid, _) -> linkedUid `shouldBe` uid
