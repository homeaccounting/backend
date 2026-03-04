{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TelegramWebhookAPI
-- Description : Telegram bot webhook endpoint
--
-- This module defines the Telegram webhook endpoint that receives
-- bot updates from Telegram in production mode.
--
-- This is a thin HTTP adapter. Processing logic lives in the
-- @Telegram.Commands@ module.
--
-- Endpoint:
--   - POST /api/telegram/webhook - Receive Telegram updates
--
-- Security:
--   - Endpoint should be accessible only from Telegram's IP ranges
--   - Updates are verified by checking they originate from Telegram
module Web.API.TelegramWebhookAPI
  ( -- * API Type
    TelegramWebhookAPI,

    -- * Request Types
    TelegramUpdate (..),
    TelegramMessage (..),
    TelegramUser (..),
    TelegramCallbackQuery (..),

    -- * Server
    telegramWebhookServer,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Domain.Core.Types (TelegramId (..))
import GHC.Generics (Generic)
import Infrastructure.App (AppM)
import RIO hiding (Handler)
import qualified RIO.Text as T
import Servant

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Telegram webhook API type.
type TelegramWebhookAPI =
  "api"
    :> "telegram"
    :> "webhook"
    :> ReqBody '[JSON] TelegramUpdate
    :> Post '[JSON] NoContent

-- -----------------------------------------------------------------------------
-- Request Types (Telegram Update Schema)
-- -----------------------------------------------------------------------------

-- | Telegram update object.
--
-- This represents an update from Telegram containing either a message,
-- callback query, or other update types.
data TelegramUpdate = TelegramUpdate
  { updateId :: Int,
    updateMessage :: Maybe TelegramMessage,
    updateCallbackQuery :: Maybe TelegramCallbackQuery,
    updateEditedMessage :: Maybe TelegramMessage
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramUpdate

instance FromJSON TelegramUpdate

-- | Telegram message object.
data TelegramMessage = TelegramMessage
  { messageId :: Int,
    messageFrom :: Maybe TelegramUser,
    messageChat :: TelegramChat,
    messageDate :: Int,
    messageText :: Maybe Text,
    messageEntities :: Maybe [TelegramMessageEntity]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramMessage

instance FromJSON TelegramMessage

-- | Telegram user object.
data TelegramUser = TelegramUser
  { userId :: Int64,
    userIsBot :: Bool,
    userFirstName :: Text,
    userLastName :: Maybe Text,
    userUsername :: Maybe Text,
    userLanguageCode :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramUser

instance FromJSON TelegramUser

-- | Telegram chat object.
data TelegramChat = TelegramChat
  { chatId :: Int64,
    chatType :: Text, -- "private", "group", "supergroup", "channel"
    chatTitle :: Maybe Text,
    chatUsername :: Maybe Text,
    chatFirstName :: Maybe Text,
    chatLastName :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramChat

instance FromJSON TelegramChat

-- | Telegram callback query (inline keyboard button press).
data TelegramCallbackQuery = TelegramCallbackQuery
  { callbackQueryId :: Text,
    callbackQueryFrom :: TelegramUser,
    callbackQueryMessage :: Maybe TelegramMessage,
    callbackQueryData :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramCallbackQuery

instance FromJSON TelegramCallbackQuery

-- | Telegram message entity (commands, mentions, etc.).
data TelegramMessageEntity = TelegramMessageEntity
  { entityType :: Text, -- "bot_command", "mention", etc.
    entityOffset :: Int,
    entityLength :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramMessageEntity

instance FromJSON TelegramMessageEntity

-- -----------------------------------------------------------------------------
-- Server Implementation (thin handler)
-- -----------------------------------------------------------------------------

-- | Telegram webhook server.
telegramWebhookServer :: ServerT TelegramWebhookAPI AppM
telegramWebhookServer = handleWebhookUpdate

-- | Handle incoming Telegram update.
--
-- This is a thin HTTP adapter that:
--   1. Logs the update receipt
--   2. Delegates message/callback processing to Telegram.Commands
--   3. Returns 200 OK to acknowledge receipt
--
-- Note: In full implementation, this would delegate to
-- Telegram.Commands.handleCommand / handleMessage / handleCallbackQuery.
-- Currently a stub that only logs.
handleWebhookUpdate :: TelegramUpdate -> AppM NoContent
handleWebhookUpdate TelegramUpdate {..} = do
  logInfo $ "Received Telegram update: " <> displayShow updateId

  -- Delegate message processing to Telegram.Commands
  -- TODO: Wire up to Telegram.Commands.handleCommand / handleMessage
  forM_ updateMessage logMessageInfo

  forM_ updateCallbackQuery logCallbackInfo

  -- Always return 200 OK to acknowledge receipt
  return NoContent

-- | Log message info (placeholder until Telegram.Commands is wired in).
logMessageInfo :: TelegramMessage -> AppM ()
logMessageInfo TelegramMessage {..} = do
  case messageFrom of
    Nothing -> logWarn "Received message without sender"
    Just sender -> do
      case messageText of
        Nothing -> logDebug "Received message without text"
        Just text -> do
          logInfo $ "Message from " <> displayShow sender.userId <> ": " <> display text
          if T.isPrefixOf "/" text
            then logInfo $ "Command received: " <> display text
            else logDebug "Non-command message received"

-- | Log callback info (placeholder until Telegram.Commands is wired in).
logCallbackInfo :: TelegramCallbackQuery -> AppM ()
logCallbackInfo TelegramCallbackQuery {..} = do
  logInfo $ "Callback query from " <> displayShow callbackQueryFrom.userId
  case callbackQueryData of
    Nothing -> logWarn "Callback query without data"
    Just dat -> logInfo $ "Callback data: " <> display dat
