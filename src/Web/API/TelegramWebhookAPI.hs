{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TelegramWebhookAPI
-- Description : Telegram bot webhook endpoint
--
-- This module defines the Telegram webhook endpoint that receives
-- bot updates from Telegram in production mode.
--
-- Processing logic lives in the @Telegram.Bot@ module; this is
-- a thin HTTP adapter that authenticates the caller, acknowledges receipt
-- and delegates.
--
-- The URL is public, so every request must carry the secret registered with
-- @setWebhook@ in its @X-Telegram-Bot-Api-Secret-Token@ header; anything else
-- is rejected before it reaches the bot (see
-- 'Infrastructure.Auth.Telegram.webhookSecret').
--
-- Endpoint:
--   - POST /api/telegram/webhook - Receive Telegram updates
module Web.API.TelegramWebhookAPI
  ( -- * API Type
    TelegramWebhookAPI,

    -- * Server
    telegramWebhookServer,
  )
where

import Infrastructure.App (AppM, HasAppConfig (..), HasBotState (..))
import Infrastructure.Auth.Telegram (TelegramConfig (..), verifyWebhookSecret)
import Infrastructure.Config (AppConfig (..))
import RIO
import Servant
import Telegram.Bot (processUpdate)
import qualified Telegram.Bot.API as TG

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Telegram webhook API type.
--
-- Accepts the library's 'TG.Update' directly — it already has 'FromJSON'.
type TelegramWebhookAPI =
  "api"
    :> "telegram"
    :> "webhook"
    :> Header "X-Telegram-Bot-Api-Secret-Token" Text
    :> ReqBody '[JSON] TG.Update
    :> Post '[JSON] NoContent

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Telegram webhook server.
telegramWebhookServer :: ServerT TelegramWebhookAPI AppM
telegramWebhookServer = handleWebhookUpdate

-- | Handle incoming Telegram update.
--
-- Rejects requests without the registered secret with 401. Otherwise
-- delegates to 'Telegram.Bot.processUpdate' (same path as polling mode)
-- and always returns 200 OK to acknowledge receipt.
handleWebhookUpdate :: Maybe Text -> TG.Update -> AppM NoContent
handleWebhookUpdate secretHeader update = do
  config <- view appConfigL
  unless (verifyWebhookSecret config.telegram.botToken secretHeader) $
    throwIO err401 {errBody = "Invalid or missing Telegram webhook secret"}
  botState <- view botStateL
  processUpdate botState update
  return NoContent
