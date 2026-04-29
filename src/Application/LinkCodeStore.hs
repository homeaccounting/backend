{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.LinkCodeStore
-- Description : In-memory store for short-lived, single-use Telegram link codes.
--
-- Tokens are 32-byte cryptographically-random values base64url-encoded to
-- ~43 ASCII characters. The store is a single 'TVar' over a 'HashMap'; all
-- mutations are STM transactions so concurrent redeems can never both
-- succeed.
--
-- Issuing replaces any prior active code for the same user (one active code
-- per user). Redeeming atomically reads, expiry-checks, and deletes.
module Application.LinkCodeStore
  ( LinkCodeStore,
    LinkCodeToken,
    mkLinkCodeToken,
    unLinkCodeToken,
    newLinkCodeStore,
    issue,
    redeem,
    purgeExpired,
    issueAt,
    redeemAt,
    purgeExpiredAt,
  )
where

import Crypto.Random (getRandomBytes)
import qualified Data.ByteString.Base64.URL as B64URL
import qualified Data.HashMap.Strict as HM
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Domain.Core.Types (UserId)
import RIO

newtype LinkCodeToken = LinkCodeToken Text
  deriving (Eq, Show, Generic)

-- | Wrap a raw text value into a 'LinkCodeToken'.
--
-- Intended for use in tests that reconstruct a token extracted from a
-- deep-link URL. Production code should never need to construct tokens
-- manually — they are always produced by 'issue' / 'issueAt'.
mkLinkCodeToken :: Text -> LinkCodeToken
mkLinkCodeToken = LinkCodeToken

-- | Extract the text value from a 'LinkCodeToken'.
unLinkCodeToken :: LinkCodeToken -> Text
unLinkCodeToken (LinkCodeToken t) = t

instance Hashable LinkCodeToken

newtype LinkCodeStore = LinkCodeStore
  { storeVar :: TVar (HM.HashMap LinkCodeToken Entry)
  }

data Entry = Entry
  { entryUserId :: !UserId,
    entryExpiresAt :: !UTCTime
  }
  deriving (Show)

newLinkCodeStore :: IO LinkCodeStore
newLinkCodeStore = LinkCodeStore <$> newTVarIO HM.empty

issue :: LinkCodeStore -> UserId -> NominalDiffTime -> IO (LinkCodeToken, UTCTime)
issue store uid ttl = do
  now <- getCurrentTime
  issueAt store uid ttl now

redeem :: LinkCodeStore -> LinkCodeToken -> IO (Maybe UserId)
redeem store tok = do
  now <- getCurrentTime
  redeemAt store tok now

purgeExpired :: LinkCodeStore -> IO ()
purgeExpired store = do
  now <- getCurrentTime
  purgeExpiredAt store now

issueAt :: LinkCodeStore -> UserId -> NominalDiffTime -> UTCTime -> IO (LinkCodeToken, UTCTime)
issueAt store uid ttl now = do
  purgeExpiredAt store now
  raw <- getRandomBytes 32
  let token = LinkCodeToken (decodeUtf8Lenient (B64URL.encode raw))
      expiresAt = addUTCTime ttl now
  atomically $ modifyTVar' store.storeVar $ \m ->
    let cleared = HM.filter (\e -> e.entryUserId /= uid) m
     in HM.insert token (Entry uid expiresAt) cleared
  pure (token, expiresAt)

redeemAt :: LinkCodeStore -> LinkCodeToken -> UTCTime -> IO (Maybe UserId)
redeemAt store tok now = atomically $ do
  m <- readTVar store.storeVar
  case HM.lookup tok m of
    Nothing -> pure Nothing
    Just e
      | e.entryExpiresAt <= now -> do
          writeTVar store.storeVar (HM.delete tok m)
          pure Nothing
      | otherwise -> do
          writeTVar store.storeVar (HM.delete tok m)
          pure (Just e.entryUserId)

purgeExpiredAt :: LinkCodeStore -> UTCTime -> IO ()
purgeExpiredAt store now =
  atomically
    $ modifyTVar' store.storeVar
    $ HM.filter (\e -> e.entryExpiresAt > now)
