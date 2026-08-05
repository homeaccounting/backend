{-# LANGUAGE OverloadedStrings #-}
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
import Domain.Models (AccountingEvent)
import Eventium.Codec (Codec)
import Eventium.SchemaEvolution.Types (SchemaRegistry, emptyRegistry)
import Eventium.Store.Postgresql (JSONString, upcastingJsonStringCodec)
import Eventium.Store.Types (EventTypeName)
import RIO

-- | Read the event-type name from a stored payload: the top-level @tag@ field
-- of an 'AccountingEvent'\'s JSON encoding.
accountingEventTypeOf :: Value -> Maybe EventTypeName
accountingEventTypeOf (Object o) = case KeyMap.lookup "tag" o of
  Just (String t) -> Just t
  _ -> Nothing
accountingEventTypeOf _ = Nothing

-- | The registry of single-hop upcasters keyed by 'AccountingEvent' tag.
--
-- Currently empty. Every stored-shape change made so far was cleared by a
-- one-time pre-launch DB recreate (the documented alpha exception in
-- @CLAUDE.md@ "Backward compatibility"), so no live migrations exist. The two
-- historical upcasters that used to live here (the @TransactionAmendmentInitiated@
-- @allowOverdraft@ default and the @TransactionPostingInitiated@
-- @externalTransactionId@ scalar→list widening) were removed with that recreate.
--
-- The seam is retained deliberately: a post-launch shape change registers its
-- @v(N)→v(N+1)@ upcaster here (keyed by @eventTypeName \@T@) with no other wiring
-- changes, restoring the standing upcast-on-read policy.
accountingSchemaRegistry :: SchemaRegistry Value
accountingSchemaRegistry = emptyRegistry

-- | The event codec for the accounting store: schema-evolving drop-in for
-- @jsonStringCodec@. Reads normalize older stored events to the current shape;
-- writes are wrapped in the current-version envelope.
accountingEventCodec :: Codec AccountingEvent JSONString
accountingEventCodec = upcastingJsonStringCodec accountingEventTypeOf accountingSchemaRegistry
