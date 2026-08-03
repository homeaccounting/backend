{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.Middleware.Context
-- Description : Per-request correlation id + best-effort user WAI middleware
--
-- Establishes the per-request 'RequestContext' (a correlation id, plus the
-- acting user when the request carries a valid bearer token) and stashes it
-- on the request's WAI 'Vault.Vault' under the app's shared
-- 'Infrastructure.App.contextVaultKey'. 'Web.Server' reads it back out of the
-- Servant-level @Vault@ combinator per request and re-hoists the server with
-- a context-bound 'AppEnv'.
--
-- The correlation id is taken from an inbound @X-Correlation-Id@ header when
-- present and a syntactically valid UUID, or freshly minted otherwise. It is
-- always echoed back on the response so callers can correlate their own logs
-- even when they didn't supply one.
--
-- The user lookup is best-effort and non-enforcing: 'getCurrentUser' never
-- throws on a missing/invalid/expired token, it just yields 'Nothing'.
-- Authorization (401s) is still enforced separately, downstream, by the
-- Servant 'Servant.Server.Experimental.Auth.AuthHandler' on endpoints that
-- require it — this middleware only best-effort-attributes the context for
-- observability (logs, event metadata) and never rejects a request itself.
module Web.Middleware.Context
  ( contextMiddleware,
  )
where

import qualified Data.Text.Encoding as TE
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDV4
import qualified Data.Vault.Lazy as Vault
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Observability.Context (RequestContext (..))
import Network.Wai
  ( Middleware,
    Request,
    mapResponseHeaders,
    requestHeaders,
    vault,
  )
import RIO
import Web.Middleware.Auth (AuthenticatedUser (..), getCurrentUser)

-- | The header used both to accept a caller-supplied correlation id and to
-- echo the (possibly freshly minted) one back on the response.
correlationIdHeaderName :: (IsString s) => s
correlationIdHeaderName = "X-Correlation-Id"

-- | WAI middleware establishing the per-request 'RequestContext'.
--
-- For every request:
--
--  1. Reuse the inbound @X-Correlation-Id@ header if it parses as a UUID,
--     otherwise mint a fresh one.
--  2. Best-effort resolve the acting user from the @Authorization@ header
--     (never throws, never blocks the request).
--  3. Stash the resulting 'RequestContext' on the request's 'Vault.Vault'
--     under 'AppEnv.contextVaultKey'.
--  4. Echo the correlation id back on the response via
--     @X-Correlation-Id@.
--
-- Total and non-throwing: an unparsable correlation-id header or a
-- missing/invalid bearer token never fails the request, they just fall back
-- to a fresh id / 'Nothing' user respectively.
contextMiddleware :: AppEnv -> Middleware
contextMiddleware env app req respond = do
  cid <- maybe UUIDV4.nextRandom pure (lookup correlationIdHeaderName (requestHeaders req) >>= UUID.fromASCIIBytes)
  -- Defensive: 'getCurrentUser' is non-throwing by contract, but this lookup
  -- runs OUTSIDE the error-handling middleware, so any escaping exception would
  -- become an uncorrelated 500. Enforce the best-effort contract structurally —
  -- an adversarial 'Authorization' can only ever downgrade to an unattributed
  -- request, never fail it.
  muser <- catchAny (runAppM env (getCurrentUser env.jwtConfig (bearerHeader req))) (\_ -> pure Nothing)
  let ctx = RequestContext {correlationId = cid, userId = fmap (.userId) muser}
      req' = req {vault = Vault.insert env.contextVaultKey ctx (vault req)}
  app req' (respond . mapResponseHeaders ((correlationIdHeaderName, UUID.toASCIIBytes cid) :))

-- | Extract the raw @Authorization@ header value as 'Text', if present and
-- valid UTF-8. Total: invalid UTF-8 yields 'Nothing' rather than throwing —
-- 'getCurrentUser' treats that the same as a missing header (best-effort,
-- non-enforcing).
bearerHeader :: Request -> Maybe Text
bearerHeader req =
  either (const Nothing) Just . TE.decodeUtf8' =<< lookup "Authorization" (requestHeaders req)
