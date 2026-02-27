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
--     - Telegram webhook (bot updates)
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
    module Web.API.TelegramWebhookAPI,
  )
where

import Infrastructure.App (AppM)
import RIO
import Servant (Proxy (..), ServerT, (:<|>) (..))
import Web.API.AccountAPI
import Web.API.AuthAPI
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
--     :<|> TelegramWebhookAPI
type API =
  AccountAPI
    :<|> TransactionAPI
    :<|> AuthAPI
    :<|> UserAPI
    :<|> TelegramWebhookAPI

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
    :<|> telegramWebhookServer
