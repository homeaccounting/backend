{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Auth.Telegram
-- Description : Telegram bot authentication configuration
--
-- This module provides the Telegram bot configuration record used by both
-- the bot polling/webhook infrastructure and the deep-link link-code flow.
--
-- The former Telegram Login Widget surfaces (HMAC-signed payloads sent to
-- POST /api/auth/telegram and POST /api/auth/link-telegram) have been removed
-- in favour of the bot deep-link flow.
module Infrastructure.Auth.Telegram
  ( -- * Configuration
    TelegramConfig (..),

    -- * Default Config
    defaultTelegramConfig,
  )
where

import Data.Aeson (FromJSON (..), ToJSON, withObject, (.!=), (.:), (.:?))
import Data.Text (Text)
import Data.Time (NominalDiffTime, secondsToNominalDiffTime)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

-- | Configuration for Telegram authentication.
data TelegramConfig = TelegramConfig
  { -- | Telegram Bot token (from @BotFather)
    botToken :: Text,
    -- | Bot username (without @)
    botUsername :: Text,
    -- | Maximum age of auth data in seconds (default: 86400 = 24 hours)
    authMaxAge :: NominalDiffTime,
    -- | Webhook URL for receiving bot updates (production)
    webhookUrl :: Maybe Text,
    -- | Use polling instead of webhook (development)
    usePolling :: Bool,
    -- | Polling timeout in seconds (default: 30)
    pollingTimeout :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramConfig

instance FromJSON TelegramConfig where
  parseJSON = withObject "TelegramConfig" $ \v ->
    TelegramConfig
      <$> v .: "bot_token"
      <*> v .: "bot_username"
      <*> (secondsToNominalDiffTime . fromIntegral <$> (v .:? "auth_max_age_seconds" .!= (86400 :: Int)))
      <*> v .:? "webhook_url"
      <*> v .:? "use_polling" .!= True
      <*> v .:? "polling_timeout" .!= 30

-- | Default Telegram configuration.
defaultTelegramConfig :: Text -> Text -> TelegramConfig
defaultTelegramConfig botToken' botUsername' =
  TelegramConfig
    { botToken = botToken',
      botUsername = botUsername',
      authMaxAge = 86400, -- 24 hours
      webhookUrl = Nothing,
      usePolling = True,
      pollingTimeout = 30
    }
