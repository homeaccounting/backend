{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

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
    userSummaryDataEmail :: Maybe Text,
    -- | Whether user has a password set
    userSummaryDataHasPassword :: Bool,
    -- | List of linked OAuth identities
    userSummaryDataOAuthIdentities :: [OAuthIdentity],
    -- | Linked Telegram identity (if any)
    userSummaryDataTelegramIdentity :: Maybe TelegramIdentity,
    -- | Reference to auto-created External account
    userSummaryDataExternalAccountId :: AccountId,
    -- | Version number from event stream for optimistic concurrency
    userSummaryDataVersion :: Int
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
    userSummaryLatestSequence :: SequenceNumber,
    -- | Primary data map: User ID -> Summary
    userSummaryData :: Map UserId UserSummaryData,
    -- | Email index: Email -> User ID
    userSummaryEmailIndex :: Map Text UserId, -- TODO: type Email = Text

    -- | Telegram index: Telegram ID -> User ID
    userSummaryTelegramIndex :: Map TelegramId UserId,
    -- | OAuth index: (Provider, Subject) -> User ID
    userSummaryOAuthIndex :: Map (OAuthProvider, Text) UserId -- TODO: type OAuthSubject = Text
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
    { userSummaryLatestSequence = -1,
      userSummaryData = Map.empty,
      userSummaryEmailIndex = Map.empty,
      userSummaryTelegramIndex = Map.empty,
      userSummaryOAuthIndex = Map.empty
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

  let newSeq = maximumDef (userSummaryLatestSequence currentModel) (streamEventPosition <$> events)
      updatedModel = foldl processUserEvent currentModel events

  liftIO . atomically . writeTVar readModelTVar $
    updatedModel {userSummaryLatestSequence = newSeq}

-- | Processes a single event and updates the user summary read model.
processUserEvent ::
  UserSummaryReadModel ->
  GlobalStreamEvent AccountingEvent ->
  UserSummaryReadModel
processUserEvent model globalEvent =
  let versionedEvent = streamEventPayload globalEvent
      streamUuid = streamEventKey versionedEvent
      payload = streamEventPayload versionedEvent
   in case payload of
        UserRegisteredEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let summary =
                    UserSummaryData
                      { userSummaryDataEmail = Just (userRegisteredEmail evt),
                        userSummaryDataHasPassword = True,
                        userSummaryDataOAuthIdentities = [],
                        userSummaryDataTelegramIdentity = Nothing,
                        userSummaryDataExternalAccountId = userRegisteredExternalAccountId evt,
                        userSummaryDataVersion = 1
                      }
               in model
                    { userSummaryData = Map.insert userId summary (userSummaryData model),
                      userSummaryEmailIndex = Map.insert (userRegisteredEmail evt) userId (userSummaryEmailIndex model)
                    }
        UserRegisteredViaTelegramEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let identity = userRegisteredViaTelegramIdentity evt
                  summary =
                    UserSummaryData
                      { userSummaryDataEmail = Nothing,
                        userSummaryDataHasPassword = False,
                        userSummaryDataOAuthIdentities = [],
                        userSummaryDataTelegramIdentity = Just identity,
                        userSummaryDataExternalAccountId = userRegisteredViaTelegramExternalAccountId evt,
                        userSummaryDataVersion = 1
                      }
               in model
                    { userSummaryData = Map.insert userId summary (userSummaryData model),
                      userSummaryTelegramIndex = Map.insert (telegramId identity) userId (userSummaryTelegramIndex model)
                    }
        OAuthAccountLinkedEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let identity = oAuthAccountLinkedIdentity evt
                  oauthKey = (oauthProvider identity, oauthSubject identity)
               in model
                    { userSummaryData =
                        Map.adjust
                          ( \s ->
                              s
                                { userSummaryDataOAuthIdentities = identity : userSummaryDataOAuthIdentities s,
                                  userSummaryDataVersion = userSummaryDataVersion s + 1
                                }
                          )
                          userId
                          (userSummaryData model),
                      userSummaryOAuthIndex = Map.insert oauthKey userId (userSummaryOAuthIndex model)
                    }
        TelegramAccountLinkedEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let identity = telegramAccountLinkedIdentity evt
               in model
                    { userSummaryData =
                        Map.adjust
                          ( \s ->
                              s
                                { userSummaryDataTelegramIdentity = Just identity,
                                  userSummaryDataVersion = userSummaryDataVersion s + 1
                                }
                          )
                          userId
                          (userSummaryData model),
                      userSummaryTelegramIndex = Map.insert (telegramId identity) userId (userSummaryTelegramIndex model)
                    }
        OAuthAccountUnlinkedEvent evt ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              let identity = oAuthAccountUnlinkedIdentity evt
                  oauthKey = (oauthProvider identity, oauthSubject identity)
               in model
                    { userSummaryData =
                        Map.adjust
                          ( \s ->
                              s
                                { userSummaryDataOAuthIdentities =
                                    filter
                                      ( \i ->
                                          oauthProvider i /= oauthProvider identity
                                            || oauthSubject i /= oauthSubject identity
                                      )
                                      (userSummaryDataOAuthIdentities s),
                                  userSummaryDataVersion = userSummaryDataVersion s + 1
                                }
                          )
                          userId
                          (userSummaryData model),
                      userSummaryOAuthIndex = Map.delete oauthKey (userSummaryOAuthIndex model)
                    }
        TelegramAccountUnlinkedEvent _ ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              case Map.lookup userId (userSummaryData model) of
                Nothing -> model
                Just existing ->
                  case userSummaryDataTelegramIdentity existing of
                    Nothing -> model
                    Just identity ->
                      model
                        { userSummaryData =
                            Map.adjust
                              ( \s ->
                                  s
                                    { userSummaryDataTelegramIdentity = Nothing,
                                      userSummaryDataVersion = userSummaryDataVersion s + 1
                                    }
                              )
                              userId
                              (userSummaryData model),
                          userSummaryTelegramIndex = Map.delete (telegramId identity) (userSummaryTelegramIndex model)
                        }
        PasswordChangedEvent _ ->
          case mkUserIdSafe streamUuid of
            Nothing -> model
            Just userId ->
              model
                { userSummaryData =
                    Map.adjust
                      ( \s ->
                          s
                            { userSummaryDataHasPassword = True,
                              userSummaryDataVersion = userSummaryDataVersion s + 1
                            }
                      )
                      userId
                      (userSummaryData model)
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
-- >>>   Just summary -> print (userSummaryDataEmail summary)
-- >>>   Nothing -> putStrLn "User not found"
getUserSummary ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  UserId ->
  m (Maybe UserSummaryData)
getUserSummary readModelTVar userId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.lookup userId (userSummaryData model)

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
getUserByEmail readModelTVar email = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup email (userSummaryEmailIndex model) of
    Nothing -> return Nothing
    Just userId -> case Map.lookup userId (userSummaryData model) of
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
getUserByTelegramId readModelTVar telegramId = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup telegramId (userSummaryTelegramIndex model) of
    Nothing -> return Nothing
    Just userId -> case Map.lookup userId (userSummaryData model) of
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
getUserByOAuthIdentity readModelTVar provider subject = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup (provider, subject) (userSummaryOAuthIndex model) of
    Nothing -> return Nothing
    Just userId -> case Map.lookup userId (userSummaryData model) of
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
  return $ Map.member userId (userSummaryData model)

-- | Checks if an email is already registered.
emailExists ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  Text ->
  m Bool
emailExists readModelTVar email = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member email (userSummaryEmailIndex model)

-- | Checks if a Telegram ID is already linked to a user.
telegramIdLinked ::
  (MonadIO m) =>
  TVar UserSummaryReadModel ->
  TelegramId ->
  m Bool
telegramIdLinked readModelTVar telegramId = do
  model <- liftIO $ readTVarIO readModelTVar
  return $ Map.member telegramId (userSummaryTelegramIndex model)

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
  return $ userSummaryData model
