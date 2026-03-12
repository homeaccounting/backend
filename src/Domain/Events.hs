{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Domain.Events
  ( Event (..),
    EventMetadata (..),
    StoredEvent (..),
    AccountId (..),
    AccountName (..),
    Balance (..),
    Money (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID, fromText, toText)
import GHC.Generics (Generic)
import Servant (FromHttpApiData (..), ToHttpApiData (..))

-- Define types here to avoid circular imports
newtype AccountId = AccountId UUID
  deriving (Eq, Ord, Show, Generic)

newtype AccountName = AccountName Text
  deriving (Eq, Show, Generic)

newtype Balance = Balance Integer
  deriving (Eq, Ord, Show, Generic)

newtype Money = Money Integer
  deriving (Eq, Ord, Show, Generic)

-- Domain Events
data Event
  = AccountCreated AccountId AccountName Balance
  | MoneyTransferred AccountId AccountId Money
  deriving (Eq, Show, Generic)

-- Event metadata for event store
data EventMetadata = EventMetadata
  { eventId :: UUID,
    timestamp :: UTCTime,
    aggregateId :: Text,
    eventType :: Text,
    version :: Int
  }
  deriving (Eq, Show, Generic)

-- Stored event combines event with metadata
data StoredEvent = StoredEvent
  { storedEventMetadata :: EventMetadata,
    storedEventData :: Event
  }
  deriving (Eq, Show, Generic)

-- JSON instances
instance ToJSON AccountId

instance FromJSON AccountId

instance ToJSON AccountName

instance FromJSON AccountName

instance ToJSON Balance

instance FromJSON Balance

instance ToJSON Money

instance FromJSON Money

instance ToJSON Event

instance FromJSON Event

instance ToJSON EventMetadata

instance FromJSON EventMetadata

instance ToJSON StoredEvent

instance FromJSON StoredEvent

-- Servant instances for URL parsing
instance FromHttpApiData AccountId where
  parseUrlPiece t = case fromText t of
    Just uuid -> Right (AccountId uuid)
    Nothing -> Left "Invalid UUID format"

instance ToHttpApiData AccountId where
  toUrlPiece (AccountId uuid) = toText uuid
