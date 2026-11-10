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
--     entry per event type whose shape has changed across a release:
--     'ConfigurationCreated' (language/country) and the four events embedding a
--     TransactionType (plain @Transfer@ gained an optional fee allocation).
--     Earlier stored-shape changes were cleared by a one-time pre-launch DB
--     recreate (see @CLAUDE.md@ "Backward compatibility"). Register further
--     @v(N)→v(N+1)@ upcasters here with no wiring changes.
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
import Data.Aeson.Key (Key)
import qualified Data.Aeson.KeyMap as KeyMap
import Domain.Configuration.Events (ConfigurationCreated)
import Domain.Models (AccountingEvent)
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted,
    TransactionAmendmentInitiated,
    TransactionMergeInitiated,
    TransactionPostingInitiated,
  )
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

-- | v1→v2 upcaster for events embedding a TransactionType under the given
-- field (@"transactionType"@ or @"newTransactionType"@): @Transfer@ gained an
-- optional fee 'Allocations' payload, so a legacy plain @{"tag":"Transfer"}@
-- becomes @{"tag":"Transfer","contents":null}@ ('Transfer' 'Nothing').
--
-- @addFieldIfAbsent@ is idempotent, and Income/Expense already carry
-- @contents@ so they pass through untouched.
transferFeesV1toV2 :: Key -> Value -> Value
transferFeesV1toV2 field =
  atKey "contents" (atKey field (addFieldIfAbsent "contents" Null))

-- | The registry of single-hop upcasters keyed by 'AccountingEvent' tag.
--
-- Holds the 'ConfigurationCreated' @v1→v2@ chain and the transfer-fee
-- @v1→v2@ chain for each event type embedding a TransactionType. Register
-- further @v(N)→v(N+1)@ upcasters here (keyed by @eventTypeName \@T@) with no
-- other wiring changes.
accountingSchemaRegistry :: SchemaRegistry Value
accountingSchemaRegistry =
  registerUpcasters (eventTypeName @ConfigurationCreated) [configurationCreatedV1toV2]
    . registerUpcasters (eventTypeName @TransactionPostingInitiated) [transferFeesV1toV2 "transactionType"]
    . registerUpcasters (eventTypeName @TransactionAmendmentInitiated) [transferFeesV1toV2 "newTransactionType"]
    . registerUpcasters (eventTypeName @TransactionAmendmentCompleted) [transferFeesV1toV2 "newTransactionType"]
    . registerUpcasters (eventTypeName @TransactionMergeInitiated) [transferFeesV1toV2 "newTransactionType"]
    $ emptyRegistry

-- | The event codec for the accounting store: schema-evolving drop-in for
-- @jsonStringCodec@. Reads normalize older stored events to the current shape;
-- writes are wrapped in the current-version envelope.
accountingEventCodec :: Codec AccountingEvent JSONString
accountingEventCodec = upcastingJsonStringCodec accountingEventTypeOf accountingSchemaRegistry
