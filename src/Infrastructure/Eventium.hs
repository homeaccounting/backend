{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

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
    AccountingGlobalEventStoreReader,
    AccountingEventHandler,

    -- * Event Store Creation
    accountingEventStoreReader,
    accountingEventStoreWriter,
    accountingVersionedEventStoreReader,
    accountingGlobalEventStoreReader,

    -- * Event Store Lifting
    liftVersionedWriter,
    liftVersionedReader,
    liftGlobalReader,
    liftIOEventHandler,

    -- * Command Handler Registry
    applyAccountCommand,
    applyTransactionCommand,
    applyUserCommand,

    -- * Command Dispatcher (for testing)
    commandDispatcher,

    -- * Aggregate Loading
    loadUserAggregate,

    -- * Read Model Event Handlers
    createAccountSummaryEventHandler,
    createTransactionSummaryEventHandler,
    createUserSummaryEventHandler,

    -- * Utilities
    printEventJSON,
  )
where

import Application.ProcessManagers (transferProcessManager)
import Application.ReadModels.AccountSummary
  ( AccountSummaryReadModel,
    createAccountSummaryReadModel,
    handleAccountSummaryEvents,
  )
import Application.ReadModels.TransactionSummary
  ( TransactionSummaryReadModel,
    createTransactionSummaryReadModel,
    handleTransactionSummaryEvents,
  )
import Application.ReadModels.UserSummary
  ( UserSummaryReadModel,
    createUserSummaryReadModel,
    handleUserSummaryEvents,
  )
import Control.Concurrent.STM (TVar)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Aeson (ToJSON)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.Text (Text)
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
    GlobalEventStoreReader,
    RejectionReason (..),
    StreamEvent (..),
    StreamProjection (..),
    UUID,
    VersionedEventStoreReader,
    VersionedEventStoreWriter,
    VersionedStreamEvent,
    allEvents,
    applyCommandHandler,
    codecEventStoreWriter,
    codecGlobalEventStoreReader,
    codecVersionedEventStoreReader,
    commandHandlerDispatcher,
    embed,
    emptyMetadata,
    getEvents,
    latestProjection,
    mkAggregateHandler,
    mkAggregateHandlerWith,
    processManagerEventHandler,
    publishingEventStoreWriter,
    runEventStoreReaderUsing,
    runEventStoreWriterUsing,
    synchronousPublisher,
  )
import Eventium.Store.Postgresql
  ( JSONString,
    SqlEventStoreConfig,
    jsonStringCodec,
    postgresqlEventStoreWriter,
    sqlEventStoreReader,
    sqlGlobalEventStoreReader,
  )
import Infrastructure.Database (runDbDirect)

-- -----------------------------------------------------------------------------
-- Type Aliases
-- -----------------------------------------------------------------------------

-- | Versioned event store reader for AccountingEvent.
type AccountingVersionedEventStoreReader m = VersionedEventStoreReader m AccountingEvent

-- | Versioned event store writer for AccountingEvent.
type AccountingVersionedEventStoreWriter m = VersionedEventStoreWriter m AccountingEvent

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
  AccountingVersionedEventStoreWriter (SqlPersistT m)
accountingEventStoreWriter config extraHandlers =
  let publishingWriter = publishingEventStoreWriter rawWriter (synchronousPublisher combinedHandler)
      rawWriter = codecEventStoreWriter jsonStringCodec (postgresqlEventStoreWriter config)
      globalReader = accountingGlobalEventStoreReader config
      versionedReader = accountingVersionedEventStoreReader config
      combinedHandler =
        eventLoggerHandler
          <> mconcat extraHandlers
          <> transferManagerHandler publishingWriter globalReader versionedReader
   in publishingWriter

-- -----------------------------------------------------------------------------
-- Event Handlers
-- -----------------------------------------------------------------------------

-- | Event logger handler — logs all events as pretty-printed JSON.
eventLoggerHandler :: (MonadIO m) => AccountingEventHandler m
eventLoggerHandler = EventHandler $ \versionedEvent ->
  liftIO $ printEventJSON (streamEventKey versionedEvent, streamEventEvent versionedEvent)

-- | Transfer process manager event handler.
--
-- Uses 'processManagerEventHandler' from eventium to wire the transfer
-- process manager to the global reader and command dispatcher.
transferManagerHandler ::
  (MonadIO m) =>
  AccountingVersionedEventStoreWriter m ->
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
  AccountingVersionedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  CommandDispatcher m AccountingCommand
commandDispatcher writer reader =
  commandHandlerDispatcher
    writer
    reader
    [ mkAggregateHandlerWith formatAccountError accountAccountingCommandHandler,
      mkAggregateHandler transactionAccountingCommandHandler,
      mkAggregateHandler userAccountingCommandHandler
    ]

-- | Human-readable formatting for account errors.

-- TODO: - move to Domain/Account
formatAccountError :: AccountError -> RejectionReason
formatAccountError InsufficientFunds = RejectionReason (T.pack "Insufficient funds")
formatAccountError AccountDoesNotExist = RejectionReason (T.pack "Account does not exist")
formatAccountError err = RejectionReason (T.pack (show err))

-- | Lift an IO event handler to any MonadIO monad.

-- TODO: - move to eventium-core
liftIOEventHandler :: (MonadIO m) => EventHandler IO event -> EventHandler m event
liftIOEventHandler (EventHandler h) = EventHandler $ \e -> liftIO (h e)

-- -----------------------------------------------------------------------------
-- Read Model Event Handlers
-- -----------------------------------------------------------------------------

-- | Creates an event handler for the AccountSummary read model.
createAccountSummaryEventHandler ::
  (MonadIO m) =>
  m (TVar AccountSummaryReadModel, AccountingEventHandler m)
createAccountSummaryEventHandler = do
  readModel <- createAccountSummaryReadModel
  let handler = EventHandler $ \versionedEvent -> do
        let globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
        handleAccountSummaryEvents readModel [globalEvent]
  return (readModel, handler)

-- | Creates a transaction summary read model and its event handler.
createTransactionSummaryEventHandler ::
  (MonadIO m) =>
  m (TVar TransactionSummaryReadModel, AccountingEventHandler m)
createTransactionSummaryEventHandler = do
  readModel <- createTransactionSummaryReadModel
  let handler = EventHandler $ \versionedEvent -> do
        let globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
        handleTransactionSummaryEvents readModel [globalEvent]
  return (readModel, handler)

-- | Creates a user summary read model and its event handler.
createUserSummaryEventHandler ::
  (MonadIO m) =>
  m (TVar UserSummaryReadModel, AccountingEventHandler m)
createUserSummaryEventHandler = do
  readModel <- createUserSummaryReadModel
  let handler = EventHandler $ \versionedEvent -> do
        let globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
        handleUserSummaryEvents readModel [globalEvent]
  return (readModel, handler)

-- -----------------------------------------------------------------------------
-- Command Handler Registry
-- -----------------------------------------------------------------------------

-- | Apply an Account command.
applyAccountCommand ::
  (Monad m) =>
  AccountingVersionedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  UUID ->
  AccountCommand ->
  m (Either (CommandHandlerError AccountError) [AccountingEvent])
applyAccountCommand writer reader accountId cmd =
  applyCommandHandler
    writer
    reader
    accountAccountingCommandHandler
    accountId
    (embed accountCommandEmbedding cmd)

-- | Apply a Transaction command.
applyTransactionCommand ::
  (Monad m) =>
  AccountingVersionedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  UUID ->
  TransactionCommand ->
  m (Either (CommandHandlerError TransactionError) [AccountingEvent])
applyTransactionCommand writer reader txId cmd =
  applyCommandHandler
    writer
    reader
    transactionAccountingCommandHandler
    txId
    (embed transactionCommandEmbedding cmd)

-- | Apply a User command.
applyUserCommand ::
  (Monad m) =>
  AccountingVersionedEventStoreWriter m ->
  AccountingVersionedEventStoreReader m ->
  UUID ->
  UserCommand ->
  m (Either (CommandHandlerError UserError) [AccountingEvent])
applyUserCommand writer reader userId cmd =
  applyCommandHandler
    writer
    reader
    userAccountingCommandHandler
    userId
    (embed userCommandEmbedding cmd)

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
  events <- getEvents reader (allEvents userId)
  pure $ latestProjection userAccountingProjection (streamEventEvent <$> events)

-- -----------------------------------------------------------------------------
-- Event Store Lifting Helpers
-- -----------------------------------------------------------------------------

-- | Lift a versioned event store writer from SqlPersistT IO to IO.
liftVersionedWriter ::
  ConnectionPool ->
  AccountingVersionedEventStoreWriter (SqlPersistT IO) ->
  AccountingVersionedEventStoreWriter IO
liftVersionedWriter pool = runEventStoreWriterUsing (runDbDirect pool)

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
