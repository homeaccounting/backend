{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

-- |
-- Module      : Application.ReadModels.User
-- Description : Persistent, indexed read model for user queries
--
-- Users are projected into three Postgres tables:
--
--   * @users@ — one row per user (email, password flag, external account,
--     configuration, version),
--   * @user_oauth@ — the linked OAuth identities (provider, subject), and
--   * @user_telegram@ — the optional linked Telegram identity.
--
-- The email, Telegram-id, and (provider, subject) lookups are backed by unique
-- indexes, replacing the in-memory index maps. The projection is an eventium
-- 'ReadModel' ('userReadModel') driven synchronously in the event-append
-- transaction; per-row @version@ is recorded from the event's real per-stream
-- 'EventVersion' (not derived by incrementing).
module Application.ReadModels.User
  ( -- * Query result type
    UserData (..),

    -- * Read model
    userReadModel,
    userProjectionName,
    migrateUser,
    resetUser,
    applyUserEvent,
    UserEntity (..),
    UserOAuthEntity (..),
    UserTelegramEntity (..),

    -- * Queries (run via 'runDb')
    getUser,
    getUserByEmail,
    getUserByTelegramId,
    getUserByOAuthIdentity,
    userExists,
    emailExists,
    telegramIdLinked,
  )
where

import Control.Monad (forM_, void)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Maybe (isJust)
import Data.Text (Text)
import Database.Persist
  ( Entity (..),
    Filter,
    deleteWhere,
    getBy,
    insertUnique,
    replace,
    selectFirst,
    selectList,
    (==.),
  )
import Database.Persist.Sql (SqlPersistT, rawExecute, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Core.Types
  ( AccountId,
    ConfigurationId,
    OAuthIdentity (..),
    OAuthProvider,
    TelegramId,
    TelegramIdentity (..),
    UserId,
    defaultConfigurationId,
    mkUserIdSafe,
  )
import Domain.Models (AccountingEvent (..))
import Domain.User.Events
  ( OAuthAccountLinked (..),
    OAuthAccountUnlinked (..),
    TelegramAccountLinked (..),
    UserConfigurationAssigned (..),
    UserRegistered (..),
    UserRegisteredViaTelegram (..),
  )
import Eventium
  ( EventHandler (..),
    EventVersion (..),
    GlobalStreamEvent,
    ReadModel (..),
    StreamEvent (..),
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import GHC.Generics (Generic)
import Infrastructure.Database.Orphans ()

-- -----------------------------------------------------------------------------
-- Query result type
-- -----------------------------------------------------------------------------

-- | Denormalized user information returned by queries. @oauthIdentities@ and
-- @telegramIdentity@ are assembled from the @user_oauth@ / @user_telegram@ rows.
data UserData = UserData
  { email :: Maybe Text,
    hasPassword :: Bool,
    oauthIdentities :: [OAuthIdentity],
    telegramIdentity :: Maybe TelegramIdentity,
    externalAccountId :: AccountId,
    configurationId :: ConfigurationId,
    version :: EventVersion
  }
  deriving (Show, Eq, Generic)

instance ToJSON UserData

instance FromJSON UserData

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateUser"]
  [persistLowerCase|
UserEntity sql=users
    userId UserId
    email Text Maybe
    hasPassword Bool
    externalAccountId AccountId
    configurationId ConfigurationId
    version EventVersion
    UniqueUserId userId
    UniqueUserEmail email !force
    deriving Show Eq
UserOAuthEntity sql=user_oauth
    userId UserId
    provider OAuthProvider
    subject Text
    -- (provider, subject): the global OAuth-identity key and the
    -- 'getUserByOAuthIdentity' lookup.
    UniqueUserOAuth provider subject
    deriving Show Eq
UserTelegramEntity sql=user_telegram
    userId UserId
    telegramId TelegramId
    username Text Maybe
    firstName Text
    -- At most one Telegram identity per user; telegram id is globally unique.
    UniqueUserTelegramUser userId
    UniqueUserTelegramId telegramId
    deriving Show Eq
|]

-- | Projection/checkpoint name for this read model.
userProjectionName :: CheckpointName
userProjectionName = CheckpointName "user"

-- | Secondary index backing the "a user's OAuth identities" load in 'getUser'.
-- The unique constraints already index @users.email@, @user_oauth(provider,
-- subject)@, and @user_telegram.user_id@ / @.telegram_id@. Idempotent
-- @CREATE INDEX IF NOT EXISTS@ (valid on both PostgreSQL and SQLite).
createUserIndexes :: (MonadIO m) => SqlPersistT m ()
createUserIndexes =
  forM_ stmts $ \s -> rawExecute s []
  where
    stmts =
      ["CREATE INDEX IF NOT EXISTS idx_user_oauth_user ON user_oauth (user_id)"]

-- | Clear all three user tables. The checkpoint is reset by 'rebuildReadModel'.
resetUser :: (MonadIO m) => SqlPersistT m ()
resetUser = do
  deleteWhere ([] :: [Filter UserOAuthEntity])
  deleteWhere ([] :: [Filter UserTelegramEntity])
  deleteWhere ([] :: [Filter UserEntity])

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

userReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
userReadModel =
  ReadModel
    { initialize = do
        void (runMigrationSilent migrateUser)
        createUserIndexes,
      eventHandler = EventHandler applyUserEvent,
      checkpointStore = postgresqlCheckpointStore userProjectionName,
      reset = resetUser
    }

-- | Apply a single global event to the user tables. The per-stream version
-- (@globalEvent.payload.position@) is recorded as the row @version@.
applyUserEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyUserEvent globalEvent =
  let inner = globalEvent.payload
      ver = inner.position
   in case mkUserIdSafe inner.key of
        Nothing -> pure ()
        Just uid -> case inner.payload of
          UserRegisteredEvent evt ->
            void $
              insertUnique
                UserEntity
                  { userEntityUserId = uid,
                    userEntityEmail = Just evt.email,
                    userEntityHasPassword = True,
                    userEntityExternalAccountId = evt.externalAccountId,
                    userEntityConfigurationId = defaultConfigurationId,
                    userEntityVersion = ver
                  }
          UserRegisteredViaTelegramEvent evt -> do
            void $
              insertUnique
                UserEntity
                  { userEntityUserId = uid,
                    userEntityEmail = Nothing,
                    userEntityHasPassword = False,
                    userEntityExternalAccountId = evt.externalAccountId,
                    userEntityConfigurationId = defaultConfigurationId,
                    userEntityVersion = ver
                  }
            insertTelegram uid evt.identity
          OAuthAccountLinkedEvent evt -> do
            void $ insertUnique (UserOAuthEntity uid evt.identity.provider evt.identity.subject)
            bumpVersion uid ver
          TelegramAccountLinkedEvent evt -> do
            deleteWhere [UserTelegramEntityUserId ==. uid]
            insertTelegram uid evt.identity
            bumpVersion uid ver
          OAuthAccountUnlinkedEvent evt -> do
            deleteWhere
              [ UserOAuthEntityProvider ==. evt.identity.provider,
                UserOAuthEntitySubject ==. evt.identity.subject
              ]
            bumpVersion uid ver
          TelegramAccountUnlinkedEvent _ -> do
            deleteWhere [UserTelegramEntityUserId ==. uid]
            bumpVersion uid ver
          PasswordChangedEvent _ ->
            modifyUser uid (\e -> e {userEntityHasPassword = True, userEntityVersion = ver})
          UserConfigurationAssignedEvent evt ->
            modifyUser uid (\e -> e {userEntityConfigurationId = evt.configurationId, userEntityVersion = ver})
          _ -> pure ()

-- | Insert (idempotently) the user's Telegram row from a 'TelegramIdentity'.
insertTelegram :: (MonadIO m) => UserId -> TelegramIdentity -> SqlPersistT m ()
insertTelegram uid ident =
  void $
    insertUnique
      UserTelegramEntity
        { userTelegramEntityUserId = uid,
          userTelegramEntityTelegramId = ident.id,
          userTelegramEntityUsername = ident.username,
          userTelegramEntityFirstName = ident.firstName
        }

-- | Read-modify-write the user row (no-op if absent).
modifyUser :: (MonadIO m) => UserId -> (UserEntity -> UserEntity) -> SqlPersistT m ()
modifyUser uid f = do
  mEnt <- getBy (UniqueUserId uid)
  case mEnt of
    Nothing -> pure ()
    Just (Entity k e) -> replace k (f e)

bumpVersion :: (MonadIO m) => UserId -> EventVersion -> SqlPersistT m ()
bumpVersion uid ver = modifyUser uid (\e -> e {userEntityVersion = ver})

-- -----------------------------------------------------------------------------
-- Queries
-- -----------------------------------------------------------------------------

entToData :: UserEntity -> [OAuthIdentity] -> Maybe TelegramIdentity -> UserData
entToData e oauths mTg =
  UserData
    { email = e.userEntityEmail,
      hasPassword = e.userEntityHasPassword,
      oauthIdentities = oauths,
      telegramIdentity = mTg,
      externalAccountId = e.userEntityExternalAccountId,
      configurationId = e.userEntityConfigurationId,
      version = e.userEntityVersion
    }

tgFromEntity :: UserTelegramEntity -> TelegramIdentity
tgFromEntity t =
  TelegramIdentity t.userTelegramEntityTelegramId t.userTelegramEntityUsername t.userTelegramEntityFirstName

-- | Load a user's full 'UserData' (its OAuth identities + Telegram identity).
loadUserData :: (MonadIO m) => UserId -> UserEntity -> SqlPersistT m UserData
loadUserData uid e = do
  oauthRows <- selectList [UserOAuthEntityUserId ==. uid] []
  mTg <- getBy (UniqueUserTelegramUser uid)
  let oauths = [OAuthIdentity r.userOAuthEntityProvider r.userOAuthEntitySubject | Entity _ r <- oauthRows]
  pure $ entToData e oauths (tgFromEntity . entityVal <$> mTg)

-- | Resolve a user id to @(id, data)@, or 'Nothing' if the row is absent.
resolveUser :: (MonadIO m) => UserId -> SqlPersistT m (Maybe (UserId, UserData))
resolveUser uid = do
  mEnt <- getBy (UniqueUserId uid)
  case mEnt of
    Nothing -> pure Nothing
    Just (Entity _ e) -> Just . (,) uid <$> loadUserData uid e

-- | User by id, with identities, or 'Nothing'.
getUser :: (MonadIO m) => UserId -> SqlPersistT m (Maybe UserData)
getUser uid = do
  mEnt <- getBy (UniqueUserId uid)
  traverse (loadUserData uid . entityVal) mEnt

-- | User by email (unique indexed lookup). Callers pass a concrete email; the
-- @NULL@ emails of Telegram-only users never match.
getUserByEmail :: (MonadIO m) => Text -> SqlPersistT m (Maybe (UserId, UserData))
getUserByEmail emailAddr = do
  mEnt <- selectFirst [UserEntityEmail ==. Just emailAddr] []
  case mEnt of
    Nothing -> pure Nothing
    Just (Entity _ e) -> Just . (,) e.userEntityUserId <$> loadUserData e.userEntityUserId e

-- | User by Telegram id (unique indexed lookup).
getUserByTelegramId :: (MonadIO m) => TelegramId -> SqlPersistT m (Maybe (UserId, UserData))
getUserByTelegramId tgId = do
  mTg <- getBy (UniqueUserTelegramId tgId)
  case mTg of
    Nothing -> pure Nothing
    Just (Entity _ t) -> resolveUser t.userTelegramEntityUserId

-- | User by OAuth identity (unique @(provider, subject)@ indexed lookup).
getUserByOAuthIdentity :: (MonadIO m) => OAuthProvider -> Text -> SqlPersistT m (Maybe (UserId, UserData))
getUserByOAuthIdentity provider subjectVal = do
  mO <- getBy (UniqueUserOAuth provider subjectVal)
  case mO of
    Nothing -> pure Nothing
    Just (Entity _ o) -> resolveUser o.userOAuthEntityUserId

-- | Whether a user exists.
userExists :: (MonadIO m) => UserId -> SqlPersistT m Bool
userExists uid = isJust <$> getBy (UniqueUserId uid)

-- | Whether an email is already registered.
emailExists :: (MonadIO m) => Text -> SqlPersistT m Bool
emailExists emailAddr = isJust <$> selectFirst [UserEntityEmail ==. Just emailAddr] []

-- | Whether a Telegram id is already linked to a user.
telegramIdLinked :: (MonadIO m) => TelegramId -> SqlPersistT m Bool
telegramIdLinked tgId = isJust <$> getBy (UniqueUserTelegramId tgId)
