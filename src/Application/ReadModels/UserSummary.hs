{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- |
-- Module      : Application.ReadModels.UserSummary
-- Description : Read model for optimized user queries
--
-- This module implements a read model that provides efficient queries for user
-- information without requiring event replay. The read model listens to the event
-- stream and maintains a denormalized view optimized for common query patterns.
--
-- Key Components:
--   - UserSummaryData: Denormalized user information
--   - UserSummaryReadModel: Map of user IDs to summary data, plus lookup indices
--   - Event handlers: Update the read model when events occur
--   - Query functions: Efficient lookups by user ID, email, or Telegram ID
--
-- Design Rationale:
--   - Separates read and write models (CQRS pattern)
--   - Maintains multiple indices for efficient lookups
--   - Tracks sequence numbers for reliable event processing
--   - Supports authentication workflows (login by email or Telegram)
--
-- The read model can be:
--   - Rebuilt from the event stream if corrupted
--   - Extended with additional denormalized fields
--   - Backed by in-memory or persistent storage
module Application.ReadModels.UserSummary
  ( -- * Read Model Types
    UserSummaryData (..),
    UserSummaryReadModel (..),

    -- * Read Model Creation
    createUserSummaryReadModel,
    emptyUserSummaryReadModel,

    -- * Event Handler
    handleUserSummaryEvents,

    -- * Query Functions
    getUserSummary,
    getUserByEmail,
    getUserByTelegramId,
    getUserByOAuthIdentity,
    userExists,
    emailExists,
    telegramIdLinked,

    -- * Helper Functions
    userSummaryToMap,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types
  ( AccountId,
    OAuthIdentity (..),
    OAuthProvider,
    TelegramId (..),
    TelegramIdentity (..),
    UserId,
    mkUserIdSafe,
  )
import Domain.Models (AccountingEvent (..))
import Domain.User.Events
  ( OAuthAccountLinked (..),
    OAuthAccountUnlinked (..),
    PasswordChanged (..),
    TelegramAccountLinked (..),
    TelegramAccountUnlinked (..),
    UserRegistered (..),
    UserRegisteredViaTelegram (..),
  )
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import GHC.Generics (Generic)
import Safe (maximumDef)

-- -----------------------------------------------------------------------------
-- Read Model Data Types
-- -----------------------------------------------------------------------------

-- | Denormalized user information for efficient querying.
--
-- This structure contains all the information needed for common user queries
-- without requiring event replay. It's optimized for read operations.
data UserSummaryData = UserSummaryData
  { -- | User's email address (primary identifier for web login)
    email :: Maybe Text,
    -- | Whether user has a password set
    hasPassword :: Bool,
    -- | List of linked OAuth identities
    oauthIdentities :: [OAuthIdentity],
    -- | Linked Telegram identity (if any)
    telegramIdentity :: Maybe TelegramIdentity,
    -- | Reference to auto-created External account
    externalAccountId :: AccountId,
    -- | Version number from event stream for optimistic concurrency
    version :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON UserSummaryData

instance FromJSON UserSummaryData

-- | The read model state with multiple indices for efficient lookups.
--
-- Maintains:
--   - Primary index: User ID -> UserSummaryData
--   - Email index: Email -> User ID
--   - Telegram index: Telegram ID -> User ID
--   - OAuth index: (Provider, Subject) -> User ID
data UserSummaryReadModel = UserSummaryReadModel
  { -- | Latest processed sequence number
    latestSequence :: SequenceNumber,
    -- | Primary data map: User ID -> Summary
    summaryData :: Map UserId UserSummaryData,
    -- | Email index: Email -> User ID
    emailIndex :: Map Text UserId, -- TODO: type Email = Text

    -- | Telegram index: Telegram ID -> User ID
    telegramIndex :: Map TelegramId UserId,
    -- | OAuth index: (Provider, Subject) -> User ID
    oauthIndex :: Map (OAuthProvider, Text) UserId -- TODO: type OAuthSubject = Text
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Read Model Creation
-- -----------------------------------------------------------------------------

-- | Creates a new empty user summary read model.
--
-- This initializes the read model with:
--   - Sequence number -1 (before any events)
--   - Empty maps for all indices
--
-- Example:
-- >>> readModel <- createUserSummaryReadModel
-- >>> summary <- getUserSummary readModel someUserId
createUserSummaryReadModel :: (MonadIO m) => m (TVar UserSummaryReadModel)
createUserSummaryReadModel =
  liftIO $ newTVarIO emptyUserSummaryReadModel

-- | Empty user summary read model for initialization.
emptyUserSummaryReadModel :: UserSummaryReadModel
emptyUserSummaryReadModel =
  UserSummaryReadModel
    { latestSequence = -1,
      summaryData = Map.empty,
      emailIndex = Map.empty,
      telegramIndex = Map.empty,
      oauthIndex = Map.empty
    }

-- -----------------------------------------------------------------------------
-- Event Handler
-- -----------------------------------------------------------------------------

-- | Updates the read model with new events from the global event stream.
--
-- This function:
--   1. Processes each event and updates the user summary accordingly
--   2. Maintains all lookup indices
--   3. Tracks the highest sequence number seen
--   4. Updates the TVar atomically
--
-- Events handled:
--   - UserRegistered: Adds new user with email/password
--   - UserRegisteredViaTelegram: Adds new user with Telegram identity
--   - OAuthAccountLinked: Adds OAuth identity to user
--   - TelegramAccountLinked: Adds Telegram identity to user
--   - OAuthAccountUnlinked: Removes OAuth identity from user
--   - TelegramAccountUnlinked: Removes Telegram identity from user
--   - PasswordChanged: Updates password flag
--
-- The function is idempotent - replaying the same events produces the same result.
handleUserSummaryEvents ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleUserSummaryEvents readModelTVar events = do
  currentModel <- liftIO $ readTVarIO readModelTVar

  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedModel = foldl processUserEvent currentModel events

  liftIO . atomically . writeTVar readModelTVar $
    updatedModel {latestSequence = newSeq}

-- | Processes a single event and updates the user summary read model.
processUserEvent ::
  UserSummaryReadModel ->
  GlobalStreamEvent AccountingEvent ->
  UserSummaryReadModel
processUserEvent model globalEvent =
  let versionedEvent = globalEvent.payload
      streamUuid = versionedEvent.key
      payload = versionedEvent.payload
   in case payload of
        UserRegisteredEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let summary =
                    UserSummaryData
                      { email = Just evt.email,
                        hasPassword = True,
                        oauthIdentities = [],
                        telegramIdentity = Nothing,
                        externalAccountId = evt.externalAccountId,
                        version = 1
                      }
               in model
                    { summaryData = Map.insert userId summary model.summaryData,
                      emailIndex = Map.insert evt.email userId model.emailIndex
                    }
        UserRegisteredViaTelegramEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let ident = evt.identity
                  summary =
                    UserSummaryData
                      { email = Nothing,
                        hasPassword = False,
                        oauthIdentities = [],
                        telegramIdentity = Just ident,
                        externalAccountId = evt.externalAccountId,
                        version = 1
                      }
               in model
                    { summaryData = Map.insert userId summary model.summaryData,
                      telegramIndex = Map.insert ident.id userId model.telegramIndex
                    }
        OAuthAccountLinkedEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let ident = evt.identity
                  oauthKey = (ident.provider, ident.subject)
               in model
                    { summaryData =
                        Map.adjust
                          ( \s ->
                              s
                                { oauthIdentities = ident : s.oauthIdentities,
                                  version = s.version + 1
                                }
                          )
                          userId
                          model.summaryData,
                      oauthIndex = Map.insert oauthKey userId model.oauthIndex
                    }
        TelegramAccountLinkedEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let ident = evt.identity
               in model
                    { summaryData =
                        Map.adjust
                          ( \s ->
                              s
                                { telegramIdentity = Just ident,
                                  version = s.version + 1
                                }
                          )
                          userId
                          model.summaryData,
                      telegramIndex = Map.insert ident.id userId model.telegramIndex
                    }
        OAuthAccountUnlinkedEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let ident = evt.identity
                  oauthKey = (ident.provider, ident.subject)
               in model
                    { summaryData =
                        Map.adjust
                          ( \s ->
                              s
                                { oauthIdentities =
                                    filter
                                      ( \i ->
                                          i.provider /= ident.provider
                                            || i.subject /= ident.subject
                                      )
                                      s.oauthIdentities,
                                  version = s.version + 1
                                }
                          )
                          userId
                          model.summaryData,
                      oauthIndex = Map.delete oauthKey model.oauthIndex
                    }
        TelegramAccountUnlinkedEvent _ ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              case Map.lookup userId model.summaryData of
                Nothing -> model
                Just existing ->
                  case existing.telegramIdentity of
                    Nothing -> model
                    Just ident ->
                      model
                        { summaryData =
                            Map.adjust
                              ( \s ->
                                  s
                                    { telegramIdentity = Nothing,
                                      version = s.version + 1
                                    }
                              )
                              userId
                              model.summaryData,
                          telegramIndex = Map.delete ident.id model.telegramIndex
                        }
        PasswordChangedEvent _ ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              model
                { summaryData =
                    Map.adjust
                      ( \s ->
                          s
                            { hasPassword = True,
                              version = s.version + 1
                            }
                      )
                      userId
                      model.summaryData
                }
        _ -> model -- Ignore non-user events

-- -----------------------------------------------------------------------------
-- Query Functions
-- -----------------------------------------------------------------------------

-- | Retrieves the user summary for a specific user ID.
--
-- Returns 'Nothing' if the user doesn't exist in the read model.
--
-- Example:
-- >>> maybeSummary <- getUserSummary readModel userId
-- >>> case maybeSummary of
-- >>>   Just summary -> print (summary.email)
-- >>>   Nothing -> putStrLn "User not found"
getUserSummary ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  UserId ->
  m (Maybe UserSummaryData)
getUserSummary readModelTVar userId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup userId model.summaryData

-- | Retrieves a user by email address.
--
-- Returns 'Nothing' if no user is registered with this email.
--
-- Example:
-- >>> maybeUser <- getUserByEmail readModel "user@example.com"
-- >>> case maybeUser of
-- >>>   Just (userId, summary) -> authenticateUser userId summary
-- >>>   Nothing -> rejectLogin
getUserByEmail ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  Text ->
  m (Maybe (UserId, UserSummaryData))
getUserByEmail readModelTVar emailAddr = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup emailAddr model.emailIndex of
    Nothing -> return Nothing
    Just userId -> case Map.lookup userId model.summaryData of
      Nothing -> return Nothing
      Just summary -> return $ Just (userId, summary)

-- | Retrieves a user by Telegram ID.
--
-- Returns 'Nothing' if no user is linked to this Telegram account.
--
-- Example:
-- >>> maybeUser <- getUserByTelegramId readModel telegramId
-- >>> case maybeUser of
-- >>>   Just (userId, summary) -> loginUser userId
-- >>>   Nothing -> createNewUser
getUserByTelegramId ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  TelegramId ->
  m (Maybe (UserId, UserSummaryData))
getUserByTelegramId readModelTVar tgId = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup tgId model.telegramIndex of
    Nothing -> return Nothing
    Just userId -> case Map.lookup userId model.summaryData of
      Nothing -> return Nothing
      Just summary -> return $ Just (userId, summary)

-- | Retrieves a user by OAuth identity.
--
-- Returns 'Nothing' if no user is linked to this OAuth account.
--
-- Example:
-- >>> maybeUser <- getUserByOAuthIdentity readModel Google "123456789"
-- >>> case maybeUser of
-- >>>   Just (userId, summary) -> loginUser userId
-- >>>   Nothing -> promptToLinkOrCreate
getUserByOAuthIdentity ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  OAuthProvider ->
  Text ->
  m (Maybe (UserId, UserSummaryData))
getUserByOAuthIdentity readModelTVar provider subjectVal = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup (provider, subjectVal) model.oauthIndex of
    Nothing -> return Nothing
    Just userId -> case Map.lookup userId model.summaryData of
      Nothing -> return Nothing
      Just summary -> return $ Just (userId, summary)

-- | Checks if a user exists in the read model.
userExists ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  UserId ->
  m Bool
userExists readModelTVar userId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member userId model.summaryData

-- | Checks if an email is already registered.
emailExists ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  Text ->
  m Bool
emailExists readModelTVar emailAddr = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member emailAddr model.emailIndex

-- | Checks if a Telegram ID is already linked to a user.
telegramIdLinked ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  TelegramId ->
  m Bool
telegramIdLinked readModelTVar tgId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member tgId model.telegramIndex

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Extracts the map of user summaries from the read model.
--
-- This is useful for testing and debugging.
userSummaryToMap ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  m (Map UserId UserSummaryData)
userSummaryToMap readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  return model.summaryData
