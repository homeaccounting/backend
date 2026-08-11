{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.SyncAPI
-- Description : REST API endpoint exposing the per-user "data changed" counter
--
-- Part of the "data changed" signal (tracker#45). The web client polls
-- @GET \/api\/sync\/version@ to learn whether its local state is stale; the
-- returned number itself is opaque, only its monotonic increase matters.
--
-- API Endpoints:
--
--   GET /api/sync/version - The authenticated caller's data-version counter.
module Web.API.SyncAPI
  ( -- * API Type
    SyncAPI,
    syncAPI,

    -- * Server
    syncServer,

    -- * Individual Handlers (exported for testing)
    versionHandler,
  )
where

import Application.ReadModels.DataVersion (getDataVersion)
import Infrastructure.App (AppM, runDb)
import RIO
import Servant
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types (SyncVersionResponse (..))

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Sync API type-level definition.
--
-- Authentication:
--  - Requires a valid JWT token (AuthProtect "jwt").
--  - The counter is scoped to the authenticated user.
type SyncAPI =
  -- GET /api/sync/version - The caller's data-version counter.
  AuthProtect "jwt"
    :> "api"
    :> "sync"
    :> "version"
    :> Get '[JSON] SyncVersionResponse

-- | Proxy for the SyncAPI.
syncAPI :: Proxy SyncAPI
syncAPI = Proxy

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Sync API server implementation.
syncServer :: ServerT SyncAPI AppM
syncServer = versionHandler

-- -----------------------------------------------------------------------------
-- Handlers (thin HTTP adapters)
-- -----------------------------------------------------------------------------

-- | Handler for GET /api/sync/version.
versionHandler :: AuthenticatedUser -> AppM SyncVersionResponse
versionHandler user = do
  v <- runDb (getDataVersion user.userId)
  pure SyncVersionResponse {version = v}
