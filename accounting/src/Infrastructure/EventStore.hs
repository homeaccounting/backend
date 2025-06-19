{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.EventStore
  ( EventStore
  , newEventStore
  , appendEvent
  , getEvents
  , getEventsByAggregateId
  , AppState(..)
  , newAppState
  ) where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)
import Domain.Events
import Domain.Account (Account)
import qualified Data.Map as Map

-- Event Store type
type EventStore = TVar [StoredEvent]

-- Application State (combining event store with read models)
data AppState = AppState
  { eventStore :: EventStore
  , accounts :: TVar [Account]
  }

-- Create new event store
newEventStore :: IO EventStore
newEventStore = newTVarIO []

-- Create new application state
newAppState :: IO AppState
newAppState = do
  es <- newEventStore
  accs <- newTVarIO []
  return $ AppState es accs

-- Append event to store
appendEvent :: (MonadIO m) => EventStore -> Text -> Text -> Event -> Int -> m StoredEvent
appendEvent store aggregateId eventType event version = liftIO $ do
  eventId <- nextRandom
  timestamp <- getCurrentTime
  let metadata = EventMetadata eventId timestamp aggregateId eventType version
      storedEvent = StoredEvent metadata event
  atomically $ do
    events <- readTVar store
    writeTVar store (storedEvent : events)
  return storedEvent

-- Get all events
getEvents :: (MonadIO m) => EventStore -> m [StoredEvent]
getEvents store = liftIO $ readTVarIO store

-- Get events by aggregate ID
getEventsByAggregateId :: (MonadIO m) => EventStore -> Text -> m [StoredEvent]
getEventsByAggregateId store aggId = liftIO $ do
  events <- readTVarIO store
  return $ filter (\se -> aggregateId (storedEventMetadata se) == aggId) events 