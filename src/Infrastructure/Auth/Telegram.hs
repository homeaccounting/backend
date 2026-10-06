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

    -- * Webhook Secret
    webhookSecret,
    verifyWebhookSecret,
  )
where

import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.Aeson (FromJSON (..), ToJSON, withObject, (.!=), (.:), (.:?))
import qualified Data.ByteArray as BA
import qualified Data.ByteArray.Encoding as BAE
import Data.ByteString (ByteString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
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

-- -----------------------------------------------------------------------------
-- Webhook Secret
-- -----------------------------------------------------------------------------

-- | The @secret_token@ registered with Telegram's @setWebhook@, which Telegram
-- echoes in the @X-Telegram-Bot-Api-Secret-Token@ header of every update.
--
-- Derived from the bot token rather than configured separately, so a
-- self-hosted instance is protected without a new setting, and the secret
-- rotates whenever the bot token does. HMAC keeps the bot token itself out of
-- the header. Hex output satisfies Telegram's @[A-Za-z0-9_-]{1,256}@ format.
-- 'Nothing' when the bot is disabled (empty token): a secret derived from an
-- empty key would be public.
webhookSecret :: Text -> Maybe Text
webhookSecret token
  | T.null token = Nothing
  | otherwise =
      let mac = hmac (encodeUtf8 token) ("homeaccounting:telegram-webhook" :: ByteString) :: HMAC SHA256
       in Just (decodeUtf8 (BAE.convertToBase BAE.Base16 mac))

-- | Constant-time check of the webhook header against 'webhookSecret'.
-- Always 'False' when the bot is disabled or the header is missing.
verifyWebhookSecret :: Text -> Maybe Text -> Bool
verifyWebhookSecret token received =
  case (webhookSecret token, received) of
    (Just expected, Just actual) -> BA.constEq (encodeUtf8 expected) (encodeUtf8 actual)
    _ -> False
