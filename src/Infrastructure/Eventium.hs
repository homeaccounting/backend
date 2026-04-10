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
    accountingVersionedEventStoreReader,
    accountingGlobalEventStoreReader,

    -- * Event Store Lifting
    liftTaggedWriter,
    liftVersionedReader,
    liftGlobalReader,
    liftIOEventHandler,

    -- * Command Handler Registry
    applyAccountCommand,
    applyTransactionCommand,
    applyUserCommand,
    applyConfigurationCommand,

    -- * Command Dispatcher (for testing)
    commandDispatcher,

    -- * Aggregate Loading
    loadUserAggregate,

    -- * Read Models
    ReadModels (..),
    createReadModelHandlers,

    -- * Read Model Replay
    replayReadModels,

    -- * Utilities
    printEventJSON,
  )
where

import Application.ProcessManagers (transferProcessManager)
import Application.ReadModels.Account
  ( AccountReadModel,
    createAccountReadModel,
    handleAccountEvents,
  )
import Application.ReadModels.Configuration
  ( ConfigurationReadModel,
    createConfigurationReadModel,
    handleConfigurationEvents,
  )
import Application.ReadModels.Transaction
  ( TransactionReadModel,
    createTransactionReadModel,
    handleTransactionEvents,
  )
import Application.ReadModels.User
  ( UserReadModel,
    createUserReadModel,
    handleUserEvents,
  )
import Control.Concurrent.STM (TVar)
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
    QueryRange,
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
    emptyMetadata,
    latestProjection,
    metadataEnrichingEventStoreWriterWithEnricher,
    mkAggregateHandler,
    mkAggregateHandlerWith,
    processManagerEventHandler,
    publishingTaggedCodecEventStoreWriter,
    runEventStoreReaderUsing,
    runEventStoreWriterUsing,
    synchronousPublisher,
  )
import Eventium.Store.Postgresql
  ( JSONString,
    SqlEventStoreConfig,
    jsonStringCodec,
    postgresqlTaggedEventStoreWriter,
    sqlEventStoreReader,
    sqlGlobalEventStoreReader,
  )
import Infrastructure.Database (runDbDirect)

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

-- -----------------------------------------------------------------------------
-- Event Store Creation
-- -----------------------------------------------------------------------------

-- | Create a versioned event store reader with JSON codec.
accountingVersionedEventStoreReader ::
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend) =>
  SqlEventStoreConfig entity JSONString ->
  AccountingVersionedEventStoreReader (SqlPersistT m)
accountingVersionedEventStoreReader config =
  codecVersionedEventStoreReader jsonStringCodec $
    sqlEventStoreReader config

-- | Create a global event store reader with JSON codec.
accountingGlobalEventStoreReader ::
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend) =>
  SqlEventStoreConfig entity JSONString ->
  AccountingGlobalEventStoreReader (SqlPersistT m)
accountingGlobalEventStoreReader config =
  codecGlobalEventStoreReader jsonStringCodec $
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
--   - Includes the transfer process manager via lazy binding
--
-- The lazy binding pattern resolves the circular dependency:
-- @publishingWriter@ is used by @transferManagerHandler@ (via @commandDispatcher@),
-- but @publishingWriter@ is defined in terms of @combinedHandler@ which includes
-- @transferManagerHandler@. Haskell's laziness resolves this.
accountingEventStoreWriter ::
  forall m entity.
  (MonadIO m, PersistEntity entity, PersistEntityBackend entity ~ SqlBackend, SafeToInsert entity) =>
  SqlEventStoreConfig entity JSONString ->
  [AccountingEventHandler (SqlPersistT m)] ->
  AccountingTaggedEventStoreWriter (SqlPersistT m)
accountingEventStoreWriter config extraHandlers =
  let rawWriter = postgresqlTaggedEventStoreWriter config
      globalReader = accountingGlobalEventStoreReader config
      versionedReader = accountingVersionedEventStoreReader config
      combinedHandler =
        eventLoggerHandler
          <> mconcat extraHandlers
          -- Process manager receives publishingWriter so that events produced by
          -- dispatched commands (e.g. AccountDebited from DebitAccount) re-enter
          -- the event bus and trigger the next saga step. The circular reference
          -- is resolved by Haskell's laziness.
          <> transferManagerHandler publishingWriter globalReader versionedReader
      -- Wrap the raw tagged writer with event bus publishing.
      -- Writes TaggedEvent JSONString to DB, decodes via jsonStringCodec for handlers.
      publishingWriter =
        publishingTaggedCodecEventStoreWriter jsonStringCodec rawWriter (synchronousPublisher combinedHandler)
   in publishingWriter

-- -----------------------------------------------------------------------------
-- Event Handlers
-- -----------------------------------------------------------------------------

-- | Event logger handler — logs all events as pretty-printed JSON.
eventLoggerHandler :: (MonadIO m) => AccountingEventHandler m
eventLoggerHandler = EventHandler $ \versionedEvent ->
  liftIO $ printEventJSON (versionedEvent.key, versionedEvent.payload)

-- | Transfer process manager event handler.
--
-- Uses 'processManagerEventHandler' from eventium to wire the transfer
-- process manager to the global reader and command dispatcher.
transferManagerHandler ::
  (MonadIO m) =>
  AccountingTaggedEventStoreWriter m ->
  AccountingGlobalEventStoreReader m ->
  AccountingVersionedEventStoreReader m ->
  AccountingEventHandler m
transferManagerHandler writer globalReader versionedReader =
  processManagerEventHandler transferProcessManager globalReader (commandDispatcher writer versionedReader)

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
    jsonStringCodec
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

-- | Lift an IO event handler to any MonadIO monad.

-- TODO: - move to eventium-core
liftIOEventHandler :: (MonadIO m) => EventHandler IO event -> EventHandler m event
liftIOEventHandler (EventHandler h) = EventHandler $ \e -> liftIO (h e)

-- -----------------------------------------------------------------------------
-- Read Models
-- -----------------------------------------------------------------------------

-- | Combined read model state for all bounded contexts.
data ReadModels = ReadModels
  { account :: TVar AccountReadModel,
    transaction :: TVar TransactionReadModel,
    user :: TVar UserReadModel,
    configuration :: TVar ConfigurationReadModel
  }

-- | Create all read models and their event bus handlers.
createReadModelHandlers ::
  (MonadIO m) =>
  m (ReadModels, [AccountingEventHandler m])
createReadModelHandlers = do
  accountRM <- createAccountReadModel
  transactionRM <- createTransactionReadModel
  userRM <- createUserReadModel
  configRM <- createConfigurationReadModel
  let mkHandler handle rm = EventHandler $ \versionedEvent -> do
        let globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
        handle rm [globalEvent]
      handlers =
        [ mkHandler handleAccountEvents accountRM,
          mkHandler handleTransactionEvents transactionRM,
          mkHandler handleUserEvents userRM,
          mkHandler handleConfigurationEvents configRM
        ]
      readModels = ReadModels accountRM transactionRM userRM configRM
  return (readModels, handlers)

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
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher jsonStringCodec writer
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
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher jsonStringCodec writer
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
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher jsonStringCodec writer
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
  let enrichedWriter = metadataEnrichingEventStoreWriterWithEnricher enricher jsonStringCodec writer
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

-- | Replay all historical events from the event store into read models.
--
-- This must be called on startup to populate in-memory read models
-- from persisted events. Without this, read models start empty and
-- cannot find previously created users/accounts.
replayReadModels ::
  (MonadIO m) =>
  AccountingGlobalEventStoreReader m ->
  ReadModels ->
  m Int
-- Must run before server/bot starts to avoid concurrent writes to TVars.
replayReadModels globalReader' readModels = do
  events <- readEvents globalReader' (allEvents ())
  handleAccountEvents readModels.account events
  handleTransactionEvents readModels.transaction events
  handleUserEvents readModels.user events
  handleConfigurationEvents readModels.configuration events
  pure (length events)

-- | Print an event as pretty-printed JSON.
printEventJSON :: (MonadIO m, ToJSON a) => a -> m ()
printEventJSON x = liftIO $ BSL.putStrLn $ encodePretty x
