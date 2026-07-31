{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Infrastructure.Eventium
-- Description : Eventium integration and wiring
--
-- This module provides the infrastructure layer for integrating with the eventium
-- event sourcing library. It sets up event store readers/writers, command handlers,
-- process managers, and codec/embedding-based serialization.
--
-- Key Components:
--   - Event Store: Read/write interface to event storage
--   - Codecs: JSON codec for events (jsonStringCodec)
--   - Command Handlers: Registry of aggregate command handlers
--   - Process Managers: Transfer saga wiring via EventPublisher/EventHandler
--   - Type Aliases: Convenient type definitions
--
-- Architecture:
--
-- The infrastructure layer connects domain logic to persistence:
--
-- ```
-- Domain Layer (Pure)
--   |
-- Infrastructure Layer (This module)
--   | JSON Codec
-- Event Store (PostgreSQL)
-- ```
module Infrastructure.Eventium
  ( -- * Event Store Types
    AccountingEventStoreReader,
    AccountingEventStoreWriter,
    AccountingVersionedEventStoreReader,
    AccountingVersionedEventStoreWriter,
    AccountingTaggedEventStoreWriter,
    AccountingGlobalEventStoreReader,
    AccountingEventHandler,

    -- * Event Store Creation
    accountingEventStoreReader,
    accountingEventStoreWriter,
    accountingEventStoreWriterWithRaw,
    accountingVersionedEventStoreReader,
    accountingGlobalEventStoreReader,

    -- * Event Store Lifting
    liftTaggedWriter,
    liftVersionedReader,
    liftGlobalReader,

    -- * Command Handler Registry
    applyAccountCommand,
    applyTransactionCommand,
    applyUserCommand,
    applyConfigurationCommand,

    -- * Command Dispatcher (for testing)
    commandDispatcher,

    -- * Aggregate Loading
    loadUserAggregate,

    -- * Process Manager Wiring
    AccountingProcessManagerFactory,
    wireProcessManager,
    wireProcessManagers,

    -- * Utilities
    embedWith,
    printEventJSON,
  )
where

import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (ToJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as BSL
import qualified Data.Text as T
import Database.Persist.Sql
  ( ConnectionPool,
    PersistEntity,
    PersistEntityBackend,
    SafeToInsert,
    SqlBackend,
    SqlPersistT,
  )
import Domain.Models
import Eventium
  ( CommandDispatcher,
    CommandHandlerError (..),
    EventHandler (..),
    EventStoreReader (..),
    EventStoreWriter,
    EventVersion,
    GlobalEventStoreReader,
    MetadataEnricher,
    ProcessManager,
    QueryRange,
    ReadModel,
    RejectionReason (..),
    StreamEvent (..),
    TaggedEvent,
    TypeEmbedding (..),
    UUID,
    VersionedEventStoreReader,
    VersionedEventStoreWriter,
    VersionedStreamEvent,
    allEvents,
    applyCommandHandler,
    codecGlobalEventStoreReader,
    codecVersionedEventStoreReader,
    commandHandlerDispatcher,
    globalToVersionedHandler,
    latestProjection,
    metadataEnrichingEventStoreWriterWithEnricher,
    mkAggregateHandler,
    mkAggregateHandlerWith,
    processManagerEventHandler,
    publishingGlobalTaggedCodecEventStoreWriter,
    readModelPublisher,
    runEventStoreReaderUsing,
    runEventStoreWriterUsing,
    synchronousGlobalPublisher,
  )
import Eventium.Store.Postgresql
  ( JSONString,
    SqlEventStoreConfig,
    postgresqlTaggedEventStoreWriter,
    sqlEventStoreReader,
    sqlGlobalEventStoreReader,
  )
import Infrastructure.Database (runDbDirect)
import Infrastructure.Eventium.Schema (accountingEventCodec)

-- | Extract the embedding function from a 'TypeEmbedding'.
embedWith :: TypeEmbedding a b -> a -> b
embedWith (TypeEmbedding e _) = e

-- | Extract the query function from an 'EventStoreReader'.
readEvents :: EventStoreReader key position m event -> (QueryRange key position -> m [event])
readEvents (EventStoreReader f) = f

-- -----------------------------------------------------------------------------
-- Type Aliases
-- -----------------------------------------------------------------------------

-- | Versioned event store reader for AccountingEvent.
type AccountingVersionedEventStoreReader m = VersionedEventStoreReader m AccountingEvent

-- | Versioned event store writer for AccountingEvent.
type AccountingVersionedEventStoreWriter m = VersionedEventStoreWriter m AccountingEvent

-- | Tagged event store writer (pre-codec, for per-call MetadataEnricher support).
type AccountingTaggedEventStoreWriter m = EventStoreWriter UUID EventVersion m (TaggedEvent JSONString)

-- | Global event store reader for AccountingEvent.
type AccountingGlobalEventStoreReader m = GlobalEventStoreReader m AccountingEvent

-- | Legacy type alias for event store reader.
type AccountingEventStoreReader m = AccountingVersionedEventStoreReader m

-- | Legacy type alias for event store writer.
type AccountingEventStoreWriter m = AccountingVersionedEventStoreWriter m

-- | Event handler for versioned stream events.
type AccountingEventHandler m = EventHandler m (VersionedStreamEvent AccountingEvent)

-- | Factory for wiring a process manager into the event bus.
--
-- Receives the (lazily-bound) publishing writer, global reader, and versioned
-- reader — all of which are computed inside 'accountingEventStoreWriter' — and
-- returns an 'AccountingEventHandler' that forwards commands back through the
-- writer, closing the saga loop.
type AccountingProcessManagerFactory m =
  AccountingTaggedEventStoreWriter m ->
  AccountingGlobalEventStoreReader m ->
  AccountingVersionedEventStoreReader m ->
  AccountingEventHandler m

-- -----------------------------------------------------------------------------
-- Event Store Creation
-- -----------------------------------------------------------------------------

-- | Create a versioned event store reader with JSON codec.
accountingVersionedEventStoreReader ::
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend) =>
  SqlEventStoreConfig entity JSONString ->
  AccountingVersionedEventStoreReader (SqlPersistT m)
accountingVersionedEventStoreReader config =
  codecVersionedEventStoreReader accountingEventCodec $
    sqlEventStoreReader config

-- | Create a global event store reader with JSON codec.
accountingGlobalEventStoreReader ::
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend) =>
  SqlEventStoreConfig entity JSONString ->
  AccountingGlobalEventStoreReader (SqlPersistT m)
accountingGlobalEventStoreReader config =
  codecGlobalEventStoreReader accountingEventCodec $
    sqlGlobalEventStoreReader config

-- | Legacy alias for versioned reader.
accountingEventStoreReader ::
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend) =>
  SqlEventStoreConfig entity JSONString ->
  AccountingEventStoreReader (SqlPersistT m)
accountingEventStoreReader = accountingVersionedEventStoreReader

-- -----------------------------------------------------------------------------
-- Event Store Writer (with EventPublisher and lazy binding)
-- -----------------------------------------------------------------------------

-- | Create an event store writer with event publishing integration.
--
-- The writer:
--   - Writes events to PostgreSQL via eventium-postgresql
--   - Encodes AccountingEvent to JSON via jsonStringCodec
--   - Publishes events synchronously to registered handlers
--   - Wires the supplied process manager factory via lazy binding
--
-- The lazy binding pattern resolves the circular dependency:
-- @publishingWriter@ is used by the process manager (via @commandDispatcher@),
-- but @publishingWriter@ is defined in terms of @combinedHandler@ which includes
-- the process manager. Haskell's laziness resolves this.
accountingEventStoreWriter ::
  forall m entity.
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend, SafeToInsert entity) =>
  SqlEventStoreConfig entity JSONString ->
  AccountingProcessManagerFactory (SqlPersistT m) ->
  [ReadModel (SqlPersistT m) AccountingEvent] ->
  AccountingTaggedEventStoreWriter (SqlPersistT m)
accountingEventStoreWriter config =
  accountingEventStoreWriterWithRaw (postgresqlTaggedEventStoreWriter config) config

-- | Like 'accountingEventStoreWriter' but with the raw (pre-publishing) tagged
-- writer supplied explicitly, decoupling the wiring from the SQL backend.
-- Production passes @postgresqlTaggedEventStoreWriter config@; tests pass the
-- SQLite raw writer, so both exercise the identical wiring.
--
-- Two classes of consumer run synchronously in the write transaction:
--
--   * @persistentReadModels@ — eventium 'ReadModel's, each driven by
--     'readModelPublisher' so it applies and advances its own 'CheckpointStore'
--     using the real global 'SequenceNumber' the write assigns.
--   * the logger and process managers, lifted onto the global stream via
--     'globalToVersionedHandler'.
accountingEventStoreWriterWithRaw ::
  forall m entity.
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend) =>
  AccountingTaggedEventStoreWriter (SqlPersistT m) ->
  SqlEventStoreConfig entity JSONString ->
  AccountingProcessManagerFactory (SqlPersistT m) ->
  [ReadModel (SqlPersistT m) AccountingEvent] ->
  AccountingTaggedEventStoreWriter (SqlPersistT m)
accountingEventStoreWriterWithRaw rawWriter config pmFactory persistentReadModels =
  let globalReader = accountingGlobalEventStoreReader config
      versionedReader = accountingVersionedEventStoreReader config
      -- Versioned consumers: logger and process managers.
      -- The process manager receives publishingWriter so events produced by
      -- dispatched commands re-enter the bus (lazy binding resolves the cycle).
      versionedHandler =
        eventLoggerHandler
          <> pmFactory publishingWriter globalReader versionedReader
      -- Publish GlobalStreamEvents (real positions): persistent read models via
      -- their own checkpoint-advancing publisher; versioned consumers lifted in.
      globalPublisher =
        mconcat (map readModelPublisher persistentReadModels)
          <> synchronousGlobalPublisher (globalToVersionedHandler versionedHandler)
      publishingWriter =
        publishingGlobalTaggedCodecEventStoreWriter accountingEventCodec rawWriter globalPublisher
   in publishingWriter

-- -----------------------------------------------------------------------------
-- Event Handlers
-- -----------------------------------------------------------------------------

-- | Event logger handler — logs all events as pretty-printed JSON.
eventLoggerHandler :: (MonadIO m) => AccountingEventHandler m
eventLoggerHandler = EventHandler $ \versionedEvent ->
  liftIO $ printEventJSON (versionedEvent.key, versionedEvent.payload)

-- | Wire a process manager into the event bus.
--
-- Satisfies 'AccountingProcessManagerFactory': receives the lazily-bound
-- publishing writer, global reader, and versioned reader, then delegates to
-- 'processManagerEventHandler' and 'commandDispatcher'.
wireProcessManager ::
  (MonadIO m) =>
  ProcessManager state AccountingEvent AccountingCommand ->
  AccountingProcessManagerFactory m
wireProcessManager pm writer globalReader versionedReader =
  processManagerEventHandler pm globalReader (commandDispatcher writer versionedReader)

-- | Combine multiple process-manager factories into a single one.
--
-- Each factory contributes an 'AccountingEventHandler' on the same event
-- bus; the combined factory delivers every event to every process
-- manager. Uses the 'EventHandler' Monoid instance under the hood.
--
-- Usage:
--
-- @
-- accountingEventStoreWriter
--   config
--   ( wireProcessManagers
--       [ wireProcessManager transferProcessManager,
--         wireProcessManager transferAmendmentProcessManager
--       ]
--   )
--   handlers
-- @
wireProcessManagers ::
  (MonadIO m) =>
  [AccountingProcessManagerFactory m] ->
  AccountingProcessManagerFactory m
wireProcessManagers factories writer globalReader versionedReader =
  mconcat [factory writer globalReader versionedReader | factory <- factories]

-- | Build a 'CommandDispatcher' that routes commands to the correct
-- aggregate handler and reports success/failure via 'CommandDispatchResult'.
--
-- Pure routing only — no saga compensation logic. Compensation is declared
-- by the process manager via 'IssueCommandWithCompensation'.
--
-- Adding a new aggregate: append an 'mkAggregateHandler' entry to the list.
commandDispatcher ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  CommandDispatcher m AccountingCommand
commandDispatcher writer reader =
  commandHandlerDispatcher
    accountingEventCodec
    writer
    reader
    [ mkAggregateHandlerWith formatAccountError accountAccountingCommandHandler,
      mkAggregateHandler transactionAccountingCommandHandler,
      mkAggregateHandler userAccountingCommandHandler,
      mkAggregateHandler configurationAccountingCommandHandler
    ]

-- | Human-readable formatting for account errors.

-- TODO: - move to Domain/Account
formatAccountError :: AccountError -> RejectionReason
formatAccountError InsufficientFunds = RejectionReason (T.pack "Insufficient funds")
formatAccountError AccountDoesNotExist = RejectionReason (T.pack "Account does not exist")
formatAccountError AccountCurrencyLocked = RejectionReason (T.pack "Account currency is locked")
formatAccountError err = RejectionReason (T.pack (show err))

-- -----------------------------------------------------------------------------
-- Command Handler Registry
-- -----------------------------------------------------------------------------

-- | Apply an Account command.
applyAccountCommand ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  MetadataEnricher ->
  UUID ->
  AccountCommand ->
  m (Either (CommandHandlerError AccountError) [AccountingEvent])
applyAccountCommand writer reader enricher accountId cmd =
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher accountingEventCodec writer
   in applyCommandHandler
        enrichedWriter
        reader
        accountAccountingCommandHandler
        accountId
        (embedWith accountCommandEmbedding cmd)

-- | Apply a Transaction command.
applyTransactionCommand ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  MetadataEnricher ->
  UUID ->
  TransactionCommand ->
  m (Either (CommandHandlerError TransactionError) [AccountingEvent])
applyTransactionCommand writer reader enricher txId cmd =
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher accountingEventCodec writer
   in applyCommandHandler
        enrichedWriter
        reader
        transactionAccountingCommandHandler
        txId
        (embedWith transactionCommandEmbedding cmd)

-- | Apply a User command.
applyUserCommand ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  MetadataEnricher ->
  UUID ->
  UserCommand ->
  m (Either (CommandHandlerError UserError) [AccountingEvent])
applyUserCommand writer reader enricher userId cmd =
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher accountingEventCodec writer
   in applyCommandHandler
        enrichedWriter
        reader
        userAccountingCommandHandler
        userId
        (embedWith userCommandEmbedding cmd)

-- | Apply a Configuration command.
applyConfigurationCommand ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  MetadataEnricher ->
  UUID ->
  ConfigurationCommand ->
  m (Either (CommandHandlerError ConfigurationError) [AccountingEvent])
applyConfigurationCommand writer reader enricher configId cmd =
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher accountingEventCodec writer
   in applyCommandHandler
        enrichedWriter
        reader
        configurationAccountingCommandHandler
        configId
        (embedWith configurationCommandEmbedding cmd)

-- -----------------------------------------------------------------------------
-- Aggregate Loading
-- -----------------------------------------------------------------------------
--

-- | Load the current User aggregate state from the event store.

-- TODO: move to eventium-core
loadUserAggregate ::
  (Monad m) =>
  AccountingVersionedEventStoreReader m ->
  UUID ->
  m User
loadUserAggregate reader userId = do
  events <- readEvents reader (allEvents userId)
  pure $ latestProjection userAccountingProjection ((.payload) <$> events)

-- -----------------------------------------------------------------------------
-- Event Store Lifting Helpers
-- -----------------------------------------------------------------------------

-- | Lift a tagged event store writer from SqlPersistT IO to IO.
liftTaggedWriter ::
  ConnectionPool ->
  AccountingTaggedEventStoreWriter (SqlPersistT IO) ->
  AccountingTaggedEventStoreWriter IO
liftTaggedWriter pool = runEventStoreWriterUsing (runDbDirect pool)

-- | Lift a versioned event store reader from SqlPersistT IO to IO.
liftVersionedReader ::
  ConnectionPool ->
  AccountingVersionedEventStoreReader (SqlPersistT IO) ->
  AccountingVersionedEventStoreReader IO
liftVersionedReader pool = runEventStoreReaderUsing (runDbDirect pool)

-- | Lift a global event store reader from SqlPersistT IO to IO.
liftGlobalReader ::
  ConnectionPool ->
  AccountingGlobalEventStoreReader (SqlPersistT IO) ->
  AccountingGlobalEventStoreReader IO
liftGlobalReader pool = runEventStoreReaderUsing (runDbDirect pool)

-- -----------------------------------------------------------------------------
-- Utilities
-- -----------------------------------------------------------------------------

-- | Print an event as pretty-printed JSON.
printEventJSON :: (MonadIO m, ToJSON a) => a -> m ()
printEventJSON x = liftIO $ BSL.putStrLn $ encodePretty x
