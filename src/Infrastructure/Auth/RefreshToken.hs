{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Auth.RefreshToken
-- Description : Opaque rotating refresh tokens: format, hashing and the
--               refresh decision (ADR 007).
--
-- Tokens are 32 random bytes, base64url without padding. Only their SHA-256
-- hex hash is ever stored. 'decideRefresh' is the whole rotation policy:
-- expired beats reuse, reuse revokes the family.
module Infrastructure.Auth.RefreshToken
  ( RefreshToken,
    mkRefreshToken,
    unRefreshToken,
    RefreshTokenHash,
    mkRefreshTokenHash,
    unRefreshTokenHash,
    FamilyId,
    mkFamilyId,
    unFamilyId,
    newRefreshToken,
    hashRefreshToken,
    newFamilyId,
    StoredRefreshToken (..),
    RefreshRejection (..),
    RefreshDecision (..),
    decideRefresh,
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64URL
import Data.Time (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Types (UserId)
import RIO
import qualified RIO.Text as T

-- | The plaintext token handed to the client. Deliberately no 'Show': it is a
-- bearer credential and must never reach a log.
newtype RefreshToken = RefreshToken Text
  deriving (Eq)

mkRefreshToken :: Text -> RefreshToken
mkRefreshToken = RefreshToken

unRefreshToken :: RefreshToken -> Text
unRefreshToken (RefreshToken t) = t

-- | SHA-256 of the token, hex-encoded: the only form persisted.
newtype RefreshTokenHash = RefreshTokenHash Text
  deriving (Eq, Show)

mkRefreshTokenHash :: Text -> RefreshTokenHash
mkRefreshTokenHash = RefreshTokenHash

unRefreshTokenHash :: RefreshTokenHash -> Text
unRefreshTokenHash (RefreshTokenHash t) = t

-- | One sign-in (one device). Every rotation stays in its family.
newtype FamilyId = FamilyId UUID
  deriving (Eq, Ord, Show)

mkFamilyId :: UUID -> FamilyId
mkFamilyId = FamilyId

unFamilyId :: FamilyId -> UUID
unFamilyId (FamilyId u) = u

newRefreshToken :: (MonadIO m) => m RefreshToken
newRefreshToken = do
  raw <- liftIO (getRandomBytes 32 :: IO ByteString)
  pure (RefreshToken (decodeUtf8Lenient (B64URL.encodeUnpadded raw)))

hashRefreshToken :: RefreshToken -> RefreshTokenHash
hashRefreshToken (RefreshToken t) =
  RefreshTokenHash (T.pack (show (hash (encodeUtf8 t) :: Digest SHA256)))

newFamilyId :: (MonadIO m) => m FamilyId
newFamilyId = FamilyId <$> liftIO UUID.nextRandom

-- | What the store knows about a presented token.
data StoredRefreshToken = StoredRefreshToken
  { userId :: UserId,
    familyId :: FamilyId,
    expiresAt :: UTCTime,
    rotatedAt :: Maybe UTCTime,
    revokedAt :: Maybe UTCTime
  }
  deriving (Eq, Show)

data RefreshRejection = RefreshUnknown | RefreshExpired
  deriving (Eq, Show)

data RefreshDecision
  = -- | Live: issue a successor in the same family.
    Rotate UserId FamilyId
  | -- | Reuse of a rotated or revoked token: revoke the whole family.
    RevokeFamily FamilyId
  | Reject RefreshRejection
  deriving (Eq, Show)

-- | The rotation policy. An expired token is rejected without revoking:
-- expired rows are pruned on write, so reuse detection for expired tokens is
-- best-effort by design. @expiresAt <= now@ counts as expired.
decideRefresh :: UTCTime -> Maybe StoredRefreshToken -> RefreshDecision
decideRefresh _ Nothing = Reject RefreshUnknown
decideRefresh now (Just s)
  | s.expiresAt <= now = Reject RefreshExpired
  | isJust s.rotatedAt || isJust s.revokedAt = RevokeFamily s.familyId
  | otherwise = Rotate s.userId s.familyId
