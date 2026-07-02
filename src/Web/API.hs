{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API
-- Description : Combined REST API for the accounting system
--
-- This module combines all individual API modules into a single unified API
-- type and server implementation.
--
-- Architecture:
--
--   This follows the Servant pattern for composing multiple APIs:
--     1. Define individual APIs separately (AccountAPI, TransactionAPI, etc.)
--     2. Combine them using type-level (:<|>) operator
--     3. Combine their server implementations similarly
--     4. Single entry point for the entire REST API
--
-- API Structure:
--
--   The complete API provides:
--     - Account management (create, query, share, revoke access)
--     - Transaction operations (initiate transfer, query status)
--     - Authentication (register, login, OAuth, Telegram, token refresh)
--     - User profile (get, update, change password, unlink providers)
--     - Configuration (currencies, dictionaries)
--     - Telegram webhook (bot updates)
--     - Banking (webhook handling, manual resync)
module Web.API
  ( -- * Combined API
    API,
    api,

    -- * Combined Server
    server,

    -- * Re-exports of Individual APIs
    module Web.API.AccountAPI,
    module Web.API.TransactionAPI,
    module Web.API.AuthAPI,
    module Web.API.UserAPI,
    module Web.API.ConfigurationAPI,
    module Web.API.TelegramWebhookAPI,
    module Web.API.BankingAPI,
    module Web.API.ReportingAPI,
    module Web.API.PromptAPI,
  )
where

import Infrastructure.App (AppM)
import RIO
import Servant (ServerT, (:<|>) (..))
import Web.API.AccountAPI
import Web.API.AuthAPI
import Web.API.BankingAPI
import Web.API.ConfigurationAPI
import Web.API.PromptAPI (PromptAPI, promptServer)
import Web.API.ReportingAPI
import Web.API.TelegramWebhookAPI
import Web.API.TransactionAPI
import Web.API.UserAPI

-- -----------------------------------------------------------------------------
-- Combined API Type
-- -----------------------------------------------------------------------------

-- | The complete REST API for the accounting system.
--
-- This type combines all individual API modules into a single, unified API.
--
-- Type Structure:
--   API = AccountAPI
--     :<|> TransactionAPI
--     :<|> AuthAPI
--     :<|> UserAPI
--     :<|> ConfigurationAPI
--     :<|> TelegramWebhookAPI
--     :<|> BankingAPI
type API =
  AccountAPI
    :<|> TransactionAPI
    :<|> AuthAPI
    :<|> UserAPI
    :<|> ConfigurationAPI
    :<|> TelegramWebhookAPI
    :<|> BankingAPI
    :<|> ReportingAPI
    :<|> PromptAPI

-- | Proxy for the combined API.
api :: Proxy API
api = Proxy

-- -----------------------------------------------------------------------------
-- Combined Server Implementation
-- -----------------------------------------------------------------------------

-- | Combined server implementation for the entire API.
--
-- Wires together all individual API servers. Servant automatically routes
-- incoming requests to the correct handler based on method, path, body,
-- and response type.
server :: ServerT API AppM
server =
  accountServer
    :<|> transactionServer
    :<|> authServer
    :<|> userServer
    :<|> configurationServer
    :<|> telegramWebhookServer
    :<|> bankingServer
    :<|> reportingServer
    :<|> promptServer
