{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Observability.Context
-- Description : Per-request observability context and metadata enrichment
--
-- This module defines a pure 'RequestContext' (a correlation id plus the
-- optional acting user) and a 'MetadataEnricher' derived from it that stamps
-- outgoing 'EventMetadata' with correlation/user information for tracing.
--
-- This module is intentionally isolated: it imports only eventium, Domain
-- types, and base/RIO/vault. It defines the 'HasRequestContext' capability
-- class but does NOT provide an 'AppEnv' instance — that wiring is added by a
-- later task once the request-scoped context is threaded through the app.
module Infrastructure.Observability.Context
  ( RequestContext (..),
    emptyRequestContext,
    nilRequestContext,
    HasRequestContext (..),
    readRequestContext,
    setCorrelationId,
    renderUserId,
    enricherFromContext,
    propagateContext,
  )
where

import qualified Data.Map.Strict as Map
import qualified Data.Vault.Lazy as Vault
import Domain.Core.Types (UserId, unUserId)
import Eventium (EventMetadata (..), MetadataEnricher, insertCustomMetadata)
import Eventium.UUID (UUID, nil, uuidToText)
import RIO

-- | Per-request observability context: the correlation id used to tie
-- together all events/log lines emitted while handling a request, and the
-- acting user (if authenticated).
data RequestContext = RequestContext
  { correlationId :: !UUID,
    userId :: !(Maybe UserId)
  }

-- | A 'RequestContext' with no acting user.
emptyRequestContext :: UUID -> RequestContext
emptyRequestContext cid = RequestContext {correlationId = cid, userId = Nothing}

-- | The default context used when none has been established (e.g. reading
-- from an empty 'Vault.Vault').
nilRequestContext :: RequestContext
nilRequestContext = emptyRequestContext nil

-- | Capability for environments that carry a 'RequestContext'. The 'AppEnv'
-- instance is added by a later task.
class HasRequestContext env where
  requestContextL :: Lens' env RequestContext

-- | Read the 'RequestContext' stored under a 'Vault.Key', defaulting to
-- 'nilRequestContext' when absent.
readRequestContext :: Vault.Key RequestContext -> Vault.Vault -> RequestContext
readRequestContext key = fromMaybe nilRequestContext . Vault.lookup key

-- | Stamp the correlation id onto 'EventMetadata'.
--
-- Uses positional construction rather than record-update syntax: 'EventMetadata'
-- and 'RequestContext' both have a @correlationId@ field, and a named-field
-- update is ambiguous under 'DuplicateRecordFields' whenever more than one
-- in-scope record shares the field name (GHC's type-directed fallback for
-- record updates is deprecated and rejected under -Werror).
setCorrelationId :: UUID -> EventMetadata -> EventMetadata
setCorrelationId cid (EventMetadata et _ causationId createdAt custom) =
  EventMetadata et (Just cid) causationId createdAt custom

-- | Render a 'UserId' for use as event metadata custom-field value.
renderUserId :: UserId -> Text
renderUserId = uuidToText . unUserId

-- | Derive a 'MetadataEnricher' from a 'RequestContext': stamps the
-- correlation id, and, when a user is present, records it under the
-- @"userId"@ custom metadata key.
enricherFromContext :: RequestContext -> MetadataEnricher
enricherFromContext ctx =
  setCorrelationId ctx.correlationId
    . maybe id (insertCustomMetadata "userId" . renderUserId) ctx.userId

-- | Build a 'MetadataEnricher' that copies the correlation context
-- (correlation id + the @"userId"@ custom field) from a triggering event's
-- metadata onto events a saga emits in response — so synchronous saga
-- events inherit the originating request's attribution.
--
-- Uses positional pattern-matching (rather than a named-field update) for
-- the same reason as 'setCorrelationId': 'EventMetadata' and
-- 'RequestContext' both have a @correlationId@ field, and a named-field
-- update is ambiguous under 'DuplicateRecordFields'.
propagateContext :: EventMetadata -> MetadataEnricher
propagateContext trigMeta (EventMetadata et _ causationId createdAt custom) =
  let md1 = EventMetadata et trigMeta.correlationId causationId createdAt custom
   in maybe md1 (\u -> insertCustomMetadata "userId" u md1) (Map.lookup "userId" trigMeta.custom)
