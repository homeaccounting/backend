{-# LANGUAGE DataKinds #-}
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
-- a thin HTTP adapter that acknowledges receipt and delegates.
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

import Infrastructure.App (AppM, HasBotState (..))
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
-- Delegates to 'Telegram.Bot.processUpdate' (same path as polling mode)
-- and always returns 200 OK to acknowledge receipt.
handleWebhookUpdate :: TG.Update -> AppM NoContent
handleWebhookUpdate update = do
  botState <- view botStateL
  processUpdate botState update
  return NoContent
