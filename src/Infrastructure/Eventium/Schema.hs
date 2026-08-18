{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Eventium.Schema
-- Description : Event schema evolution registry for the accounting event store.
--
-- The app-specific half of schema evolution (the generic machinery lives in
-- "Eventium.SchemaEvolution"). This module supplies:
--
--   * 'accountingEventTypeOf' — reads the event-type name from a stored payload
--     using this app's tagging convention (the Aeson @tag@ field produced by
--     'Domain.Models.AccountingEvent'\'s derived JSON).
--   * 'accountingSchemaRegistry' — the registered single-hop upcasters, one
--     entry per event type whose shape has changed across a release. Currently
--     empty: every historical stored-shape change was cleared by a one-time
--     pre-launch DB recreate (see @CLAUDE.md@ "Backward compatibility"), so there
--     are no live migrations. The seam is kept so a post-launch shape change can
--     register its @v(N)→v(N+1)@ upcaster here with no wiring changes.
--   * 'accountingEventCodec' — the drop-in codec used at the event store
--     reader/writer call sites, replacing the plain @jsonStringCodec@.
--
-- == Envelope note
--
-- 'Domain.Models.AccountingEvent' encodes as @{ "tag": ..., "contents": {..} }@
-- (a tagged single-field constructor), so an event's own fields live under
-- @contents@. Upcasters therefore transform the @contents@ object.
module Infrastructure.Eventium.Schema
  ( accountingEventTypeOf,
    accountingSchemaRegistry,
    accountingEventCodec,
  )
where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KeyMap
import Domain.Configuration.Events (ConfigurationCreated)
import Domain.Models (AccountingEvent)
import Eventium.Codec (Codec)
import Eventium.SchemaEvolution.Json (addFieldIfAbsent, atKey)
import Eventium.SchemaEvolution.Types (SchemaRegistry, emptyRegistry, registerUpcasters)
import Eventium.Store.Postgresql (JSONString, upcastingJsonStringCodec)
import Eventium.Store.Types (EventTypeName, eventTypeName)
import RIO

-- | Read the event-type name from a stored payload: the top-level @tag@ field
-- of an 'AccountingEvent'\'s JSON encoding.
accountingEventTypeOf :: Value -> Maybe EventTypeName
accountingEventTypeOf (Object o) = case KeyMap.lookup "tag" o of
  Just (String t) -> Just t
  _ -> Nothing
accountingEventTypeOf _ = Nothing

-- | v1→v2 upcaster for 'ConfigurationCreated': the event gained a @language@
-- field (default @"en"@) and a @country@ field (default @null@) when the
-- personalization signal foundation landed. Legacy rows lack both; inject them.
--
-- Transforms under @contents@ (the app's @{tag, contents}@ envelope).
-- @addFieldIfAbsent@ is idempotent and never clobbers an existing value, so a
-- re-encoded v2 event passes through unchanged. @country@ injection is strictly
-- optional (an absent @Maybe@ decodes as 'Nothing'), but is written explicitly
-- for a self-describing v2 shape.
configurationCreatedV1toV2 :: Value -> Value
configurationCreatedV1toV2 =
  atKey "contents" (addFieldIfAbsent "language" (String "en") . addFieldIfAbsent "country" Null)

-- | The registry of single-hop upcasters keyed by 'AccountingEvent' tag.
--
-- Holds the 'ConfigurationCreated' @v1→v2@ chain — the first live entry, which
-- re-activates the upcast-on-read seam that a one-time pre-launch DB recreate had
-- left empty (see @CLAUDE.md@ "Backward compatibility"). Register further
-- @v(N)→v(N+1)@ upcasters here (keyed by @eventTypeName \@T@) with no other
-- wiring changes.
accountingSchemaRegistry :: SchemaRegistry Value
accountingSchemaRegistry =
  registerUpcasters (eventTypeName @ConfigurationCreated) [configurationCreatedV1toV2] emptyRegistry

-- | The event codec for the accounting store: schema-evolving drop-in for
-- @jsonStringCodec@. Reads normalize older stored events to the current shape;
-- writes are wrapped in the current-version envelope.
accountingEventCodec :: Codec AccountingEvent JSONString
accountingEventCodec = upcastingJsonStringCodec accountingEventTypeOf accountingSchemaRegistry
