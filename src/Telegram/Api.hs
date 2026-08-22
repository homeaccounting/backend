{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.Api
-- Description : Thin wrapper around telegram-bot-api for AppM integration
--
-- This module provides a thin wrapper around the telegram-bot-api library,
-- adapting it for use with the AppM monad and RIO patterns.
--
-- Key functions:
--   - createTelegramClientEnv: Initialize the Telegram API client
--   - sendTextMessage: Send a simple text message
--   - sendMessageWithKeyboard: Send a message with inline keyboard
--   - answerCallback: Answer a callback query
--   - fetchUpdates: Fetch new updates (for polling mode)
module Telegram.Api
  ( -- * Client Environment
    createTelegramClientEnv,

    -- * Sending Messages
    sendTextMessage,
    sendMessageWithKeyboard,

    -- * Callback Queries
    answerCallback,

    -- * Updates
    fetchUpdates,

    -- * Bot Configuration
    registerCommands,
    registerChatCommands,
    registerWebhook,
  )
where

import Domain.Localization.Language (Language (..), languageCode)
import Network.HTTP.Client (managerResponseTimeout, newManager, responseTimeoutMicro)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import RIO
import qualified RIO.Text as T
import Servant.Client (ClientEnv, ClientError, mkClientEnv, runClientM)
import qualified Telegram.Bot.API as TG
import Telegram.Bot.API.MakingRequests ()
import qualified Telegram.Bot.API.Webhook as TGW
import Telegram.Types (botCommands)

-- -----------------------------------------------------------------------------
-- Client Environment
-- -----------------------------------------------------------------------------

-- | Create a Telegram client environment from a bot token.
--
-- This initializes the Servant ClientEnv for making requests to the Telegram
-- Bot API. The token should be in the format returned by BotFather.
--
-- We create a custom HTTP manager with a longer response timeout (70 seconds)
-- because the default 30-second timeout from http-client conflicts with
-- Telegram's long polling (which holds connections for up to 30+ seconds).
-- Without this, the manager kills the connection before Telegram responds.
--
-- Example:
-- >>> clientEnv <- createTelegramClientEnv "1234567890:ABCdefGHIjklMNOpqrsTUVwxyz"
-- >>> -- Now use clientEnv for API calls
createTelegramClientEnv :: Text -> IO ClientEnv
createTelegramClientEnv tokenText = do
  let token = TG.Token tokenText
      baseUrl = TG.botBaseUrl token
      -- Long polling timeout (30s) + generous buffer (40s) = 70s
      managerSettings =
        tlsManagerSettings
          { managerResponseTimeout =
              responseTimeoutMicro (70 * 1000000)
          }
  manager <- newManager managerSettings
  return $ mkClientEnv manager baseUrl

-- -----------------------------------------------------------------------------
-- Sending Messages
-- -----------------------------------------------------------------------------

-- | Send a simple text message to a chat.
--
-- This is the most basic message sending function. It sends plain text
-- without any formatting or keyboards.
--
-- Example:
-- >>> result <- sendTextMessage clientEnv (TG.SomeChatId $ TG.ChatId 123456) "Hello, World!"
-- >>> case result of
-- >>>   Right msg -> logInfo "Message sent"
-- >>>   Left err -> logError $ "Failed: " <> displayShow err
sendTextMessage ::
  (MonadIO m) =>
  ClientEnv ->
  TG.SomeChatId ->
  Text ->
  m (Either ClientError TG.Message)
sendTextMessage clientEnv chatId text = liftIO $ do
  let request =
        TG.SendMessageRequest
          { TG.sendMessageBusinessConnectionId = Nothing,
            TG.sendMessageChatId = chatId,
            TG.sendMessageMessageThreadId = Nothing,
            TG.sendMessageText = text,
            TG.sendMessageParseMode = Nothing,
            TG.sendMessageEntities = Nothing,
            TG.sendMessageLinkPreviewOptions = Nothing,
            TG.sendMessageDisableNotification = Nothing,
            TG.sendMessageProtectContent = Nothing,
            TG.sendMessageMessageEffectId = Nothing,
            TG.sendMessageReplyParameters = Nothing,
            TG.sendMessageReplyToMessageId = Nothing,
            TG.sendMessageReplyMarkup = Nothing
          }
  response <- runClientM (TG.sendMessage request) clientEnv
  return $ fmap TG.responseResult response

-- | Send a message with an inline keyboard.
--
-- This sends a text message with interactive buttons. The keyboard is
-- displayed below the message, and button clicks trigger callback queries.
--
-- Example:
-- >>> let keyboard = TG.InlineKeyboardMarkup [[button1, button2]]
-- >>> result <- sendMessageWithKeyboard clientEnv chatId "Choose an option:" keyboard
sendMessageWithKeyboard ::
  (MonadIO m) =>
  ClientEnv ->
  TG.SomeChatId ->
  Text ->
  TG.InlineKeyboardMarkup ->
  m (Either ClientError TG.Message)
sendMessageWithKeyboard clientEnv chatId text keyboard = liftIO $ do
  let request =
        TG.SendMessageRequest
          { TG.sendMessageBusinessConnectionId = Nothing,
            TG.sendMessageChatId = chatId,
            TG.sendMessageMessageThreadId = Nothing,
            TG.sendMessageText = text,
            TG.sendMessageParseMode = Nothing,
            TG.sendMessageEntities = Nothing,
            TG.sendMessageLinkPreviewOptions = Nothing,
            TG.sendMessageDisableNotification = Nothing,
            TG.sendMessageProtectContent = Nothing,
            TG.sendMessageMessageEffectId = Nothing,
            TG.sendMessageReplyParameters = Nothing,
            TG.sendMessageReplyToMessageId = Nothing,
            TG.sendMessageReplyMarkup = Just (TG.SomeInlineKeyboardMarkup keyboard)
          }
  response <- runClientM (TG.sendMessage request) clientEnv
  return $ fmap TG.responseResult response

-- -----------------------------------------------------------------------------
-- Callback Queries
-- -----------------------------------------------------------------------------

-- | Answer a callback query from an inline keyboard button.
--
-- This must be called after a user clicks an inline keyboard button.
-- Failing to answer callback queries will cause the button to show a
-- loading indicator indefinitely.
--
-- The optional text parameter shows a notification to the user.
--
-- Example:
-- >>> result <- answerCallback clientEnv callbackQueryId (Just "Action completed!")
-- >>> case result of
-- >>>   Right () -> logInfo "Callback answered"
-- >>>   Left err -> logError $ "Failed: " <> displayShow err
answerCallback ::
  (MonadIO m) =>
  ClientEnv ->
  TG.CallbackQueryId ->
  Maybe Text ->
  m (Either ClientError ())
answerCallback clientEnv callbackQueryId maybeText = liftIO $ do
  let request =
        TG.AnswerCallbackQueryRequest
          { TG.answerCallbackQueryCallbackQueryId = callbackQueryId,
            TG.answerCallbackQueryText = maybeText,
            TG.answerCallbackQueryShowAlert = Nothing,
            TG.answerCallbackQueryUrl = Nothing,
            TG.answerCallbackQueryCacheTime = Nothing
          }
  response <- runClientM (TG.answerCallbackQuery request) clientEnv
  return $ void response

-- -----------------------------------------------------------------------------
-- Updates
-- -----------------------------------------------------------------------------

-- | Fetch new updates from the Telegram Bot API.
--
-- This is used in polling mode to receive new messages, callback queries,
-- and other updates. The offset parameter should be set to (last_update_id + 1)
-- to acknowledge processed updates.
--
-- The timeout parameter specifies how long (in seconds) the request should
-- wait for new updates before returning. Use 0 for short polling, 30+ for
-- long polling.
--
-- Example (long polling):
-- >>> result <- fetchUpdates clientEnv (Just 123) 30
-- >>> case result of
-- >>>   Right updates -> mapM_ processUpdate updates
-- >>>   Left err -> logError $ "Failed: " <> displayShow err
fetchUpdates ::
  (MonadIO m) =>
  ClientEnv ->
  Maybe Int ->
  Int ->
  m (Either ClientError [TG.Update])
fetchUpdates clientEnv maybeOffset timeoutSeconds = liftIO $ do
  let request =
        TG.GetUpdatesRequest
          { TG.getUpdatesOffset = TG.UpdateId <$> maybeOffset,
            TG.getUpdatesLimit = Nothing,
            TG.getUpdatesTimeout = Just (TG.Seconds timeoutSeconds),
            TG.getUpdatesAllowedUpdates = Nothing
          }
  response <- runClientM (TG.getUpdates request) clientEnv
  return $ fmap TG.responseResult response

-- -----------------------------------------------------------------------------
-- Bot Configuration
-- -----------------------------------------------------------------------------

-- | Register bot commands with Telegram so they appear in the menu, for a
-- single locale.
--
-- This calls the @setMyCommands@ API. English is registered as the language
-- code-less default (@setMyCommandsLanguageCode = Nothing@), which Telegram
-- serves to any client whose locale has no dedicated registration; every other
-- 'Language' is registered under its two-letter code so Telegram clients set to
-- that locale see localized descriptions. Call once per supported locale at
-- startup (see 'Telegram.Bot.setupBotCommands').
registerCommands ::
  (MonadIO m) =>
  ClientEnv ->
  Language ->
  m (Either ClientError Bool)
registerCommands clientEnv lang = liftIO $ do
  let commands = map (uncurry TG.BotCommand) (botCommands lang)
      langCode = case lang of
        En -> Nothing
        _ -> Just (languageCode lang)
      request =
        TG.SetMyCommandsRequest
          { TG.setMyCommandsCommands = commands,
            TG.setMyCommandsScope = Nothing,
            TG.setMyCommandsLanguageCode = langCode
          }
  response <- runClientM (TG.setMyCommands request) clientEnv
  return $ fmap TG.responseResult response

-- | Register bot commands for one specific chat, in @lang@.
--
-- Unlike 'registerCommands' (which scopes by the client's @language_code@), this
-- uses a @BotCommandScopeChat@ override, which Telegram serves to that chat
-- regardless of the user's Telegram-client language. This is how the command
-- menu follows the user's /app/ language preference rather than their Telegram
-- app locale. Higher precedence than the default/language-code registration, so
-- it wins for the target chat.
registerChatCommands ::
  (MonadIO m) =>
  ClientEnv ->
  Language ->
  Int64 ->
  m (Either ClientError Bool)
registerChatCommands clientEnv lang chatId = liftIO $ do
  let commands = map (uncurry TG.BotCommand) (botCommands lang)
      scope = TG.BotCommandScopeChat (TG.SomeChatId (TG.ChatId (fromIntegral chatId)))
      request =
        TG.SetMyCommandsRequest
          { TG.setMyCommandsCommands = commands,
            TG.setMyCommandsScope = Just scope,
            TG.setMyCommandsLanguageCode = Nothing
          }
  response <- runClientM (TG.setMyCommands request) clientEnv
  return $ fmap TG.responseResult response

-- | Register the webhook URL with Telegram.
--
-- This calls the @setWebhook@ API so Telegram knows where to send updates.
-- Must be called once at startup when running in webhook mode.
registerWebhook ::
  (MonadIO m) =>
  ClientEnv ->
  Text ->
  m (Either ClientError ())
registerWebhook clientEnv webhookUrl = liftIO $ do
  let request = TGW.defSetWebhook (T.unpack webhookUrl)
  TGW.setUpWebhook request clientEnv
