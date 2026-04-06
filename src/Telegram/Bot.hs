{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.Bot
-- Description : Telegram bot initialization and main loop
--
-- This module provides bot initialization, polling loop, and update
-- processing for the Telegram bot using the telegram-bot-api library.
--
-- Modes:
--   - Polling: For development (periodically fetches updates)
--   - Webhook: For production (receives updates via HTTP POST)
module Telegram.Bot
  ( -- * Bot Initialization
    initBot,
    setupBotCommands,
    runBotPolling,

    -- * Update Processing
    processUpdate,
  )
where

import Domain.Core.Types (TelegramId (..), TelegramIdentity (..))
import Infrastructure.App (AppM, HasTelegramClient (..))
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import RIO
import qualified RIO.Text as T
import Servant.Client (ClientEnv)
import Telegram.Api (fetchUpdates, registerCommands)
import qualified Telegram.Bot.API as TG
import Telegram.Commands (handleCallbackQuery, handleCommand, handleMessage)
import Telegram.Types (BotState (..), emptyBotState)

-- -----------------------------------------------------------------------------
-- Bot Initialization
-- -----------------------------------------------------------------------------

-- | Initialize the bot and return the bot state.
--
-- This sets up conversation state tracking.
initBot :: (MonadIO m) => TelegramConfig -> m (TVar BotState)
initBot _config = liftIO $ newTVarIO emptyBotState

-- | Register bot commands with Telegram (shows the menu in the chat).
--
-- Should be called once at startup when a client environment is available.
setupBotCommands :: (MonadIO m, MonadReader env m, HasLogFunc env) => ClientEnv -> m ()
setupBotCommands clientEnv = do
  result <- registerCommands clientEnv
  case result of
    Right True -> logInfo "Bot commands registered with Telegram"
    Right False -> logWarn "Telegram returned false for setMyCommands"
    Left err -> logWarn $ "Failed to register bot commands: " <> displayShow err

-- -----------------------------------------------------------------------------
-- Polling Mode
-- -----------------------------------------------------------------------------

-- | Run the bot in polling mode (for development).
--
-- This periodically fetches updates from Telegram and processes them.
-- Uses long polling with timeout for efficiency.
runBotPolling :: TelegramConfig -> TVar BotState -> AppM ()
runBotPolling config botState = do
  logInfo $ "Starting bot polling for @" <> display config.botUsername

  maybeClientEnv <- view telegramClientEnvL
  case maybeClientEnv of
    Nothing -> do
      logError "Telegram client environment not initialized"
      liftIO $ threadDelay 5000000 -- Wait 5 seconds before retrying
      runBotPolling config botState
    Just clientEnv ->
      pollingLoop clientEnv botState config.pollingTimeout Nothing

-- | Polling loop that fetches and processes updates.
pollingLoop :: ClientEnv -> TVar BotState -> Int -> Maybe Int -> AppM ()
pollingLoop clientEnv botState pollingTimeout maybeOffset = do
  result <- fetchUpdates clientEnv maybeOffset pollingTimeout
  case result of
    Left err -> do
      logError $ "Failed to fetch updates: " <> displayShow err
      liftIO $ threadDelay 5000000 -- Wait 5 seconds on error
      pollingLoop clientEnv botState pollingTimeout maybeOffset
    Right updates -> do
      -- Process each update
      mapM_ (processUpdate botState) updates

      -- Calculate new offset (last update ID + 1)
      let newOffset = case updates of
            [] -> maybeOffset
            _ -> Just $ foldl' max 0 (map getUpdateId updates) + 1

      -- Continue polling
      pollingLoop clientEnv botState pollingTimeout newOffset

-- | Extract update ID from a TG.Update.
getUpdateId :: TG.Update -> Int
getUpdateId update =
  let TG.UpdateId uid = TG.updateUpdateId update
   in uid

-- -----------------------------------------------------------------------------
-- Update Processing
-- -----------------------------------------------------------------------------

-- | Process a single Telegram update.
--
-- Routes the update to the appropriate handler based on type:
--   - Message: Text messages or commands
--   - Callback Query: Inline keyboard button presses
--   - Other: Ignored
processUpdate :: TVar BotState -> TG.Update -> AppM ()
processUpdate botState update = do
  forM_ (TG.updateMessage update) (processMessage botState)
  forM_ (TG.updateCallbackQuery update) (processCallbackQuery botState)

-- | Process a message update.
processMessage :: TVar BotState -> TG.Message -> AppM ()
processMessage botState message = do
  let TG.ChatId rawChatId = TG.chatId (TG.messageChat message)
      chatId = fromIntegral rawChatId
      maybeUser = TG.messageFrom message
      maybeText = TG.messageText message

  case maybeUser of
    Nothing -> return () -- Ignore messages without user
    Just user -> do
      let telegramId = TelegramId (getUserIdInt user)
          tgIdentity =
            TelegramIdentity
              { id = telegramId,
                firstName = TG.userFirstName user,
                username = TG.userUsername user
              }
      case maybeText of
        Just text | "/" `T.isPrefixOf` text -> handleCommand botState tgIdentity chatId text
        Just text -> handleMessage botState telegramId chatId text
        Nothing -> return ()

-- | Process a callback query (inline keyboard button press).
processCallbackQuery :: TVar BotState -> TG.CallbackQuery -> AppM ()
processCallbackQuery botState callback = do
  let callbackQueryId = TG.callbackQueryId callback
      fromUser = TG.callbackQueryFrom callback
      maybeCallbackData = TG.callbackQueryData callback
      maybeChatId = getChatIdFromCallback callback

  let telegramId = TelegramId (getUserIdInt fromUser)

  case (maybeChatId, maybeCallbackData) of
    (Just chatId, Just callbackData) ->
      handleCallbackQuery botState telegramId chatId callbackQueryId callbackData
    _ -> return ()

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extract chat ID from a callback query.
getChatIdFromCallback :: TG.CallbackQuery -> Maybe Int64
getChatIdFromCallback callback = do
  message <- TG.callbackQueryMessage callback
  let TG.ChatId chatId = TG.chatId (TG.messageChat message)
  return (fromIntegral chatId)

-- | Extract user ID as Int64 from a User.
getUserIdInt :: TG.User -> Int64
getUserIdInt user =
  let TG.UserId uid = TG.userId user
   in fromIntegral uid
