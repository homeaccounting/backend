{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Test-only helpers for signing ID tokens with throwaway keys.
module Testkit.IdTokens
  ( testRsaKey,
    testJwkSet,
    signIdToken,
    signIdTokenWithAlg,
    baseClaims,
    testIdTokenConfig,
  )
where

import Crypto.JOSE
  ( Alg (RS256),
    CompactJWS,
    Error,
    HeaderParam (..),
    JWK,
    JWKSet (..),
    JWSHeader,
    KeyMaterialGenParam (..),
    RequiredProtection (..),
    asPublicKey,
    encodeCompact,
    genJWK,
    jwkKid,
    kid,
    newJWSHeader,
    runJOSE,
    signJWS,
  )
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (IdTokenConfig (..))
import RIO
import qualified RIO.ByteString.Lazy as BL
import RIO.Partial (fromJust)

testIdTokenConfig :: IdTokenConfig
testIdTokenConfig = IdTokenConfig {googleAudiences = ["test-google-aud"], appleAudiences = ["test.apple.aud"]}

-- | A fresh RSA-2048 key with kid "k1".
testRsaKey :: IO JWK
testRsaKey = do
  k <- genJWK (RSAGenParam 256)
  pure (set jwkKid (Just "k1") k)

-- | The public half of the key, as a provider would publish it.
testJwkSet :: JWK -> JWKSet
testJwkSet k = JWKSet [fromJust (k ^. asPublicKey)]

signIdToken :: JWK -> Aeson.Object -> IO Text
signIdToken k = signIdTokenWithAlg k RS256

-- | Sign an arbitrary JSON payload as a compact JWS with the key's kid.
signIdTokenWithAlg :: JWK -> Alg -> Aeson.Object -> IO Text
signIdTokenWithAlg k a claims = do
  let hdr = newJWSHeader (RequiredProtection, a) & kid .~ fmap (HeaderParam RequiredProtection) (k ^. jwkKid)
  res <- runJOSE (signJWS (Aeson.encode claims) (Identity (hdr, k))) :: IO (Either Error (CompactJWS JWSHeader))
  either (throwString . show) (pure . decodeUtf8Lenient . BL.toStrict . encodeCompact) res

baseClaims :: OAuthProvider -> UTCTime -> Aeson.Object
baseClaims p now =
  KM.fromList
    [ ("iss", Aeson.String (if p == Apple then "https://appleid.apple.com" else "https://accounts.google.com")),
      ("aud", Aeson.String (if p == Apple then "test.apple.aud" else "test-google-aud")),
      ("sub", "sub-1"),
      ("email", "u@example.com"),
      ("email_verified", Aeson.Bool True),
      ("nonce", "n-1"),
      ("exp", Aeson.Number (fromIntegral (floor (utcTimeToPOSIXSeconds (addUTCTime 600 now)) :: Integer)))
    ]
