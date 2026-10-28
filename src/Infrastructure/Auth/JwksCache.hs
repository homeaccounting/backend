{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Auth.JwksCache
-- Description : Google/Apple signing keys for ID-token verification
--
-- Keys are fetched lazily and cached per provider for the response's
-- Cache-Control max-age (else an hour). An unknown kid forces a refetch at most
-- once a minute, so key rotation is picked up without letting forged kids
-- hammer the provider. At most one fetch per provider runs at a time:
-- concurrent callers wait for it (or keep using a cached set), so a slow
-- provider cannot pile up requests on this public endpoint.
module Infrastructure.Auth.JwksCache
  ( KeySource (..),
    getKeys,
    Fetcher,
    newCachingKeySource,
    httpFetcher,
    fixedKeySource,
    jwksUrl,
  )
where

import Crypto.JOSE (JWKSet)
import qualified Data.Aeson as Aeson
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Domain.Core.Types (OAuthProvider (..))
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody, responseHeaders, responseStatus, responseTimeout, responseTimeoutMicro)
import Network.HTTP.Types (statusIsSuccessful)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T

-- | The 'Bool' means "the caller saw an unknown kid; refetch if allowed".
-- 'Left' means there are no keys at all; its text is for logs.
newtype KeySource = KeySource (OAuthProvider -> Bool -> IO (Either Text JWKSet))

-- A plain function: the repo uses NoFieldSelectors, so a record field would not be callable.
getKeys :: KeySource -> OAuthProvider -> Bool -> IO (Either Text JWKSet)
getKeys (KeySource f) = f

-- | Key keySet plus the response's @max-age@.
type Fetcher = OAuthProvider -> IO (Either Text (JWKSet, Maybe NominalDiffTime))

data Entry = Entry
  { cached :: !(Maybe (JWKSet, UTCTime)), -- keySet and its expiry
    lastAttempt :: !UTCTime,
    inFlight :: !Bool
  }

data Step = Serve (Either Text JWKSet) | Fetch (Maybe (JWKSet, UTCTime))

refetchInterval, defaultLifetime :: NominalDiffTime
refetchInterval = 60
defaultLifetime = 3600

newCachingKeySource :: IO UTCTime -> Fetcher -> IO KeySource
newCachingKeySource clock fetch = do
  var <- newTVarIO (Map.empty :: Map OAuthProvider Entry)
  let store provider e = modifyTVar' var (Map.insert provider e)
      -- Decide, and claim the fetch, in one transaction so that no two
      -- callers fetch the same provider at once.
      step provider forced now = do
        entry <- Map.lookup provider <$> readTVar var
        let held = entry >>= (.cached)
            fresh = maybe False (\(_, expiry) -> now < expiry) held
            busy = maybe False (.inFlight) entry
            -- Failed attempts count too, so an unreachable provider is not hammered.
            throttled = maybe False (\e -> diffUTCTime now e.lastAttempt < refetchInterval) entry
            wanted = isNothing held || not fresh || forced
            serve = Serve (fallback "no keys cached" held)
        if
          | not wanted -> pure serve
          -- A stale set is still usable; an unknown kid or no set waits for
          -- the fetch in flight, then decides again.
          | busy -> if isJust held && not forced then pure serve else retrySTM
          | throttled -> pure serve
          | otherwise -> store provider (Entry held now True) $> Fetch held
  pure $ KeySource $ \provider forced -> do
    now <- clock
    mask $ \restore ->
      atomically (step provider forced now) >>= \case
        Serve r -> pure r
        Fetch held -> do
          res <- restore (fetch provider) `onException` atomically (store provider (Entry held now False))
          case res of
            Right (keySet, maxAge) -> do
              let expiry = addUTCTime (fromMaybe defaultLifetime maxAge) now
              atomically $ store provider (Entry (Just (keySet, expiry)) now False)
              pure (Right keySet)
            Left err -> do
              atomically $ store provider (Entry held now False)
              pure (fallback err held)
  where
    fallback err = maybe (Left err) (Right . fst)

fixedKeySource :: JWKSet -> KeySource
fixedKeySource keySet = KeySource (\_ _ -> pure (Right keySet))

jwksUrl :: OAuthProvider -> Maybe String
jwksUrl Google = Just "https://www.googleapis.com/oauth2/v3/certs"
jwksUrl Apple = Just "https://appleid.apple.com/auth/keys"
jwksUrl _ = Nothing

httpFetcher :: Manager -> Fetcher
httpFetcher mgr provider = case jwksUrl provider of
  Nothing -> pure (Left "provider has no JWKS")
  Just url -> handleAny (pure . Left . tshow) $ do
    req <- parseRequest url
    -- Far below the shared manager's timeout: sign-in requests wait on this.
    resp <- httpLbs req {responseTimeout = responseTimeoutMicro 5000000} mgr
    pure
      $ if not (statusIsSuccessful (responseStatus resp))
        then Left ("JWKS HTTP " <> tshow (responseStatus resp))
        else case Aeson.eitherDecode (responseBody resp) of
          Left e -> Left (T.pack e)
          Right keySet -> Right (keySet, maxAgeOf (responseHeaders resp))
  where
    maxAgeOf hs = do
      v <- lookup "Cache-Control" hs
      t <- either (const Nothing) Just (decodeUtf8' v)
      d <- listToMaybe [rest | part <- T.split (== ',') t, Just rest <- [T.stripPrefix "max-age=" (T.strip part)]]
      fromIntegral <$> (readMaybe (T.unpack d) :: Maybe Int)
