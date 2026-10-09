{-# LANGUAGE DataKinds #-}
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
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Auth.RefreshTokenStore
-- Description : Persistent refresh-token families and tokens (ADR 007).
--
-- Auth-session state, not a read model: nothing here is projected from
-- events, and read-model rebuilds never touch it. Rotation and revocation
-- contend on the family row, so a revocation can't miss a successor being
-- issued concurrently.
module Infrastructure.Auth.RefreshTokenStore
  ( migrateRefreshTokens,
    startFamily,
    issueSuccessor,
    findRefreshToken,
    markRotated,
    revokeFamily,
  )
where

import Database.Persist
  ( Entity (..),
    deleteWhere,
    getBy,
    insert_,
    updateWhere,
    (<=.),
    (=.),
    (==.),
  )
import Database.Persist.Sql (SqlPersistT, rawExecute, runMigration, updateWhereCount)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Core.Types (UserId)
import Infrastructure.Auth.RefreshToken
import Infrastructure.Database.Orphans ()
import RIO
import RIO.Time (NominalDiffTime, UTCTime, addUTCTime)

share
  [mkPersist sqlSettings, mkMigrate "migrateRefreshTokenTables"]
  [persistLowerCase|
RefreshTokenFamilyEntity sql=refresh_token_families
    familyId FamilyId
    userId UserId
    createdAt UTCTime
    revokedAt UTCTime Maybe
    UniqueRefreshTokenFamily familyId
    deriving Show Eq
RefreshTokenEntity sql=refresh_tokens
    tokenHash Text
    familyId FamilyId
    userId UserId
    createdAt UTCTime
    expiresAt UTCTime
    rotatedAt UTCTime Maybe
    revokedAt UTCTime Maybe
    UniqueRefreshTokenHash tokenHash
    deriving Show Eq
|]

-- | Tables plus secondary indexes. Idempotent; valid on PostgreSQL and SQLite.
migrateRefreshTokens :: (MonadIO m) => SqlPersistT m ()
migrateRefreshTokens = do
  void (runMigration migrateRefreshTokenTables)
  forM_
    [ "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON refresh_tokens (user_id)",
      "CREATE INDEX IF NOT EXISTS idx_refresh_tokens_family ON refresh_tokens (family_id)"
    ]
    (`rawExecute` [])

startFamily :: (MonadIO m) => NominalDiffTime -> UserId -> UTCTime -> SqlPersistT m RefreshToken
startFamily ttl uid now = do
  fam <- newFamilyId
  insert_ (RefreshTokenFamilyEntity fam uid now Nothing)
  insertToken ttl uid fam now

-- | Claim the family (one-row update that only matches while it is not
-- revoked), then insert the successor. A concurrent 'revokeFamily' serialises
-- on that row, so it either sees the successor or the claim fails.
issueSuccessor :: (MonadIO m) => NominalDiffTime -> UserId -> FamilyId -> UTCTime -> SqlPersistT m (Maybe RefreshToken)
issueSuccessor ttl uid fam now = do
  claimed <-
    updateWhereCount
      [RefreshTokenFamilyEntityFamilyId ==. fam, RefreshTokenFamilyEntityRevokedAt ==. Nothing]
      [RefreshTokenFamilyEntityRevokedAt =. Nothing]
  if claimed == 1 then Just <$> insertToken ttl uid fam now else pure Nothing

-- | Insert a token row, first pruning this user's expired rows.
insertToken :: (MonadIO m) => NominalDiffTime -> UserId -> FamilyId -> UTCTime -> SqlPersistT m RefreshToken
insertToken ttl uid fam now = do
  deleteWhere [RefreshTokenEntityUserId ==. uid, RefreshTokenEntityExpiresAt <=. now]
  tok <- newRefreshToken
  insert_
    RefreshTokenEntity
      { refreshTokenEntityTokenHash = unRefreshTokenHash (hashRefreshToken tok),
        refreshTokenEntityFamilyId = fam,
        refreshTokenEntityUserId = uid,
        refreshTokenEntityCreatedAt = now,
        refreshTokenEntityExpiresAt = addUTCTime ttl now,
        refreshTokenEntityRotatedAt = Nothing,
        refreshTokenEntityRevokedAt = Nothing
      }
  pure tok

findRefreshToken :: (MonadIO m) => RefreshTokenHash -> SqlPersistT m (Maybe StoredRefreshToken)
findRefreshToken h = fmap (toStored . entityVal) <$> getBy (UniqueRefreshTokenHash (unRefreshTokenHash h))
  where
    toStored e =
      StoredRefreshToken
        { userId = e.refreshTokenEntityUserId,
          familyId = e.refreshTokenEntityFamilyId,
          expiresAt = e.refreshTokenEntityExpiresAt,
          rotatedAt = e.refreshTokenEntityRotatedAt,
          revokedAt = e.refreshTokenEntityRevokedAt
        }

-- | Set rotated_at while it is still unset and the token is unrevoked.
-- True iff this call won.
markRotated :: (MonadIO m) => RefreshTokenHash -> UTCTime -> SqlPersistT m Bool
markRotated h now =
  (== 1)
    <$> updateWhereCount
      [ RefreshTokenEntityTokenHash ==. unRefreshTokenHash h,
        RefreshTokenEntityRotatedAt ==. Nothing,
        RefreshTokenEntityRevokedAt ==. Nothing
      ]
      [RefreshTokenEntityRotatedAt =. Just now]

-- | Revoke the family row and all its unrevoked tokens.
revokeFamily :: (MonadIO m) => FamilyId -> UTCTime -> SqlPersistT m ()
revokeFamily fam now = do
  updateWhere
    [RefreshTokenFamilyEntityFamilyId ==. fam, RefreshTokenFamilyEntityRevokedAt ==. Nothing]
    [RefreshTokenFamilyEntityRevokedAt =. Just now]
  updateWhere
    [RefreshTokenEntityFamilyId ==. fam, RefreshTokenEntityRevokedAt ==. Nothing]
    [RefreshTokenEntityRevokedAt =. Just now]
