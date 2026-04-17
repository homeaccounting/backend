-- |
-- Module      : Infrastructure.Eventium.GlobalEvent
-- Description : Helpers for working with GlobalStreamEvent in read models
--
-- A leaf module (no dependencies on read models) so it can be imported from
-- every @Application.ReadModels.*@ without forming a cycle with the parent
-- 'Infrastructure.Eventium' module (which wires the read models together).
module Infrastructure.Eventium.GlobalEvent
  ( unpackGlobalEvent,
  )
where

import Eventium (GlobalStreamEvent, StreamEvent (..), UUID)

-- | Destructure a 'GlobalStreamEvent' into its @(streamUuid, payload)@ pair.
--
-- 'GlobalStreamEvent' is @StreamEvent () SequenceNumber (VersionedStreamEvent event)@,
-- so extracting the aggregate's stream UUID and the actual event payload
-- requires peeling two 'StreamEvent' layers. Every read-model event handler
-- in this codebase repeats the same three-line destructuring; this helper
-- names the operation and collapses it to a pair.
--
-- TODO: upstream to @eventium-core@ (see
-- @../../eventium/eventium-core/src/Eventium/Store/Types.hs@) — it is a
-- generic operation over 'GlobalStreamEvent' with no accounting-specific
-- content.
unpackGlobalEvent :: GlobalStreamEvent event -> (UUID, event)
unpackGlobalEvent globalEvent =
  let versionedEvent = globalEvent.payload
   in (versionedEvent.key, versionedEvent.payload)
