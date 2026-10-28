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
-- hammer the provider.
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
import Network.HTTP.Client (Manager, httpLbs, parseRequest, responseBody, responseHeaders, responseStatus)
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
    lastAttempt :: !UTCTime
  }

refetchInterval, defaultLifetime :: NominalDiffTime
refetchInterval = 60
defaultLifetime = 3600

newCachingKeySource :: IO UTCTime -> Fetcher -> IO KeySource
newCachingKeySource clock fetch = do
  var <- newTVarIO (Map.empty :: Map OAuthProvider Entry)
  pure $ KeySource $ \provider forced -> do
    now <- clock
    entry <- Map.lookup provider <$> readTVarIO var
    let held = entry >>= (.cached)
        fresh = maybe False (\(_, expiry) -> now < expiry) held
        -- Failed attempts count too, so an unreachable provider is not hammered.
        throttled = maybe False (\e -> diffUTCTime now e.lastAttempt < refetchInterval) entry
        wanted = isNothing held || not fresh || forced
        fallback err = maybe (Left err) (Right . fst) held
    if throttled || not wanted
      then pure (fallback "no keys cached")
      else do
        res <- fetch provider
        case res of
          Right (keySet, maxAge) -> do
            let expiry = addUTCTime (fromMaybe defaultLifetime maxAge) now
            atomically $ modifyTVar' var (Map.insert provider (Entry (Just (keySet, expiry)) now))
            pure (Right keySet)
          Left err -> do
            atomically $ modifyTVar' var (Map.insert provider (Entry held now))
            pure (fallback err)

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
    resp <- httpLbs req mgr
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
