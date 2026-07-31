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
--     entry per event type whose shape has changed across a release.
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

import Data.Aeson (Value (..), toJSON)
import qualified Data.Aeson.KeyMap as KeyMap
import Domain.Models (AccountingEvent)
import Domain.Transaction.Events (TransactionAmendmentInitiated, TransactionPostingInitiated)
import Eventium.Codec (Codec)
import Eventium.SchemaEvolution.Json (JsonUpcaster, addFieldIfAbsent, atKey)
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

-- | The registry of single-hop upcasters keyed by 'AccountingEvent' tag.
--
-- Keys are derived from the event type via 'eventTypeName' rather than written
-- as string literals. By this app's JSON conventions the tag equals the wrapped
-- event type's name (@constructSumType@ appends @Event@; @deriveJSON@ strips it),
-- so @eventTypeName \@T@ is the tag — and renaming or removing the type is a
-- compile error here, not a silently-dead upcaster. (The name-equals-tag
-- correspondence itself is pinned by the round-trip tests, which decode a real
-- encoding through this registry.)
--
-- Current entries:
--
--   * 'TransactionAmendmentInitiated' v1→v2: default the added @allowOverdraft@
--     field to @False@. Correct because the only writer of @True@ is the merge
--     saga, whose amendments postdate the field and are always written at v2;
--     any v1 (pre-field) event therefore predates merge, where @False@ is the
--     exact original behaviour.
--   * 'TransactionPostingInitiated' v1→v2: normalise the single
--     @importInfo.externalTransactionId@ string to the @externalTransactionIds@
--     one-or-more list. The field was widened from a scalar to a 'NonEmpty' when
--     detected internal transfers gained a second leg's id; older import events
--     (and only those — manual entries have no @importInfo@) carry the scalar.
accountingSchemaRegistry :: SchemaRegistry Value
accountingSchemaRegistry =
  registerUpcasters (eventTypeName @TransactionAmendmentInitiated) [amendmentInitiatedV1toV2]
    . registerUpcasters (eventTypeName @TransactionPostingInitiated) [postingInitiatedV1toV2]
    $ emptyRegistry

-- | v1→v2 for @TransactionAmendmentInitiated@: default the added
-- @allowOverdraft@ field to @False@ if absent. The field lives under the tagged
-- constructor's @contents@ object, so we focus there with 'atKey'.
amendmentInitiatedV1toV2 :: JsonUpcaster
amendmentInitiatedV1toV2 = atKey "contents" (addFieldIfAbsent "allowOverdraft" (Bool False))

-- | v1→v2 for @TransactionPostingInitiated@: rewrite the pre-widening scalar
-- @importInfo.externalTransactionId@ (a JSON string) to @externalTransactionIds@
-- (a one-element JSON array), the current 'NonEmpty' shape. A plain
-- 'Eventium.SchemaEvolution.Json.renameField' would move the scalar as-is and
-- still fail to decode as a list, so the value is wrapped here.
--
-- Safe across every legacy shape, all of which read as v1 (no envelope yet):
-- a no-op when @importInfo@ is @null@ (manual entry) or absent, and when it is
-- already the @externalTransactionIds@ array — so a v1-tagged event that already
-- carries the current shape passes through untouched.
postingInitiatedV1toV2 :: JsonUpcaster
postingInitiatedV1toV2 = atKey "contents" (atKey "importInfo" externalIdToList)
  where
    externalIdToList (Object o) = case KeyMap.lookup "externalTransactionId" o of
      Just eid ->
        Object
          ( KeyMap.insert "externalTransactionIds" (toJSON [eid]) $
              KeyMap.delete "externalTransactionId" o
          )
      Nothing -> Object o
    externalIdToList v = v

-- | The event codec for the accounting store: schema-evolving drop-in for
-- @jsonStringCodec@. Reads normalize older stored events to the current shape;
-- writes are wrapped in the current-version envelope.
accountingEventCodec :: Codec AccountingEvent JSONString
accountingEventCodec = upcastingJsonStringCodec accountingEventTypeOf accountingSchemaRegistry
