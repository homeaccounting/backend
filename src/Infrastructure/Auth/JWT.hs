{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Infrastructure.Auth.JWT
-- Description : JWT token management for authentication
--
-- This module provides JWT (JSON Web Token) generation and verification
-- for user authentication. Tokens contain user identity claims and are
-- used for stateless authentication in the API.
--
-- Key Functions:
--   - generateToken: Create a new JWT for a user
--   - verifyToken: Verify and decode a JWT
--   - refreshToken: Generate a new token from an existing valid one
--
-- Token Structure:
--   - Header: Algorithm (HS256) and token type
--   - Payload: User ID, email, expiration time
--   - Signature: HMAC-SHA256 of header + payload
--
-- Security Properties:
--   - Uses HS256 (HMAC-SHA256) for signing
--   - Includes expiration time (configurable)
--   - Tokens are stateless (no server-side storage required)
--
-- Usage:
-- >>> token <- generateToken jwtConfig userId "user@example.com"
-- >>> claims <- verifyToken jwtConfig token
-- >>> case claims of
-- >>>   Just c -> print (jwtUserId c)
-- >>>   Nothing -> print "Invalid token"
module Infrastructure.Auth.JWT
  ( -- * JWT Claims
    JWTClaims (..),

    -- * Configuration
    JWTConfig (..),
    defaultJWTConfig,

    -- * Token Operations
    generateToken,
    verifyToken,
    refreshToken,

    -- * Error Types
    JWTError (..),
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.MAC.HMAC (HMAC (..), hmac)
import Data.Aeson (FromJSON (..), ToJSON (..), decode, encode, object, withObject, (.:), (.=))
import qualified Data.Aeson as Aeson
import Data.Bits (xor, (.|.))
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64URL
import qualified Data.ByteString.Lazy as LBS
import qualified Data.List
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime, secondsToNominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Types (UserId (..), mkUserIdSafe, unUserId)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- JWT Claims
-- -----------------------------------------------------------------------------

-- | Claims contained in a JWT token.
--
-- These are the custom claims used by the accounting application
-- in addition to the standard JWT claims (exp, iat, sub).
data JWTClaims = JWTClaims
  { -- | User ID (from the 'sub' claim)
    jwtUserId :: UserId,
    -- | User's email address
    jwtEmail :: Text,
    -- | Token expiration time
    jwtExpiry :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON JWTClaims

instance FromJSON JWTClaims

-- | Internal representation of JWT payload for encoding/decoding.
data JWTPayload = JWTPayload
  { payloadSub :: Text, -- User ID as UUID string
    payloadEmail :: Text,
    payloadExp :: Integer, -- Unix timestamp
    payloadIat :: Integer, -- Unix timestamp
    payloadIss :: Text,
    payloadAud :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON JWTPayload where
  toJSON JWTPayload {..} =
    object
      [ "sub" .= payloadSub,
        "email" .= payloadEmail,
        "exp" .= payloadExp,
        "iat" .= payloadIat,
        "iss" .= payloadIss,
        "aud" .= payloadAud
      ]

instance FromJSON JWTPayload where
  parseJSON = Aeson.withObject "JWTPayload" $ \v ->
    JWTPayload
      <$> v .: "sub"
      <*> v .: "email"
      <*> v .: "exp"
      <*> v .: "iat"
      <*> v .: "iss"
      <*> v .: "aud"

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

-- | Configuration for JWT token generation and verification.
--
-- Fields use simple types ('Text', 'Int') for easy YAML deserialisation.
-- The 'jwtSecret' is converted to 'ByteString' at usage sites via
-- 'encodeUtf8'.
data JWTConfig = JWTConfig
  { -- | Secret key for signing tokens (should be at least 256 bits)
    jwtSecret :: Text,
    -- | Token validity duration in seconds (default: 3600 = 1 hour)
    jwtExpirySeconds :: Int,
    -- | Token issuer (typically the application URL)
    jwtIssuer :: Text,
    -- | Token audience (typically the application name)
    jwtAudience :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON JWTConfig

instance FromJSON JWTConfig where
  parseJSON = withObject "JWTConfig" $ \v ->
    JWTConfig
      <$> v .: "jwt_secret"
      <*> v .: "jwt_expiry_seconds"
      <*> v .: "jwt_issuer"
      <*> v .: "jwt_audience"

-- | Default JWT configuration.
--
-- Note: The secret should be overridden with a secure random value!
defaultJWTConfig :: JWTConfig
defaultJWTConfig =
  JWTConfig
    { jwtSecret = "CHANGE_THIS_TO_A_SECURE_SECRET_KEY_AT_LEAST_32_BYTES",
      jwtExpirySeconds = 3600, -- 1 hour
      jwtIssuer = "accounting-api",
      jwtAudience = "accounting-app"
    }

-- -----------------------------------------------------------------------------
-- Error Types
-- -----------------------------------------------------------------------------

-- | Errors that can occur during JWT operations.
data JWTError
  = -- | Token signature is invalid
    InvalidSignature
  | -- | Token has expired
    TokenExpired
  | -- | Token format is malformed
    MalformedToken Text
  | -- | Token claims are invalid
    InvalidClaims Text
  | -- | Token generation failed
    TokenGenerationFailed Text
  deriving (Show, Eq, Generic)

instance ToJSON JWTError

instance FromJSON JWTError

-- -----------------------------------------------------------------------------
-- Token Operations
-- -----------------------------------------------------------------------------

-- | Generate a new JWT token for a user.
--
-- Creates a signed JWT containing:
--   - sub: User ID (UUID)
--   - email: User's email address
--   - exp: Expiration time
--   - iat: Issued at time
--   - iss: Issuer
--   - aud: Audience
--
-- Example:
-- >>> token <- generateToken config userId "user@example.com"
-- >>> case token of
-- >>>   Right t -> sendTokenToClient t
-- >>>   Left err -> handleError err
generateToken ::
  (MonadIO m) =>
  JWTConfig ->
  UserId ->
  Text ->
  m (Either JWTError Text)
generateToken config userId email = liftIO $ do
  now <- getCurrentTime
  let expiry = addUTCTime (secondsToNominalDiffTime $ fromIntegral $ jwtExpirySeconds config) now
      payload =
        JWTPayload
          { payloadSub = T.pack $ UUID.toString $ unUserId userId,
            payloadEmail = email,
            payloadExp = round $ utcTimeToPOSIXSeconds expiry,
            payloadIat = round $ utcTimeToPOSIXSeconds now,
            payloadIss = jwtIssuer config,
            payloadAud = jwtAudience config
          }
  return $ Right $ encodeJWT (encodeUtf8 $ jwtSecret config) payload

-- | Verify a JWT token and extract its claims.
--
-- Performs the following checks:
--   - Signature validation
--   - Expiration time
--   - Issuer match
--   - Audience match
--
-- Returns Nothing if the token is invalid or expired.
--
-- Example:
-- >>> claims <- verifyToken config token
-- >>> case claims of
-- >>>   Just c -> proceedWithUser (jwtUserId c)
-- >>>   Nothing -> return401Unauthorized
verifyToken ::
  (MonadIO m) =>
  JWTConfig ->
  Text ->
  m (Maybe JWTClaims)
verifyToken config token = liftIO $ do
  now <- getCurrentTime
  case decodeJWT (encodeUtf8 $ jwtSecret config) token of
    Nothing -> return Nothing
    Just payload -> do
      -- Check expiration
      let expiryTime = posixSecondsToUTCTime $ fromInteger $ payloadExp payload
      if now > expiryTime
        then return Nothing
        else -- Check issuer
          if payloadIss payload /= jwtIssuer config
            then return Nothing
            else -- Check audience
              if payloadAud payload /= jwtAudience config
                then return Nothing
                else -- Extract claims
                  case UUID.fromText (payloadSub payload) >>= mkUserIdSafe of
                    Nothing -> return Nothing
                    Just userId ->
                      return $
                        Just
                          JWTClaims
                            { jwtUserId = userId,
                              jwtEmail = payloadEmail payload,
                              jwtExpiry = expiryTime
                            }

-- | Refresh an existing valid token.
--
-- Verifies the old token and generates a new one with a fresh expiration time.
-- This allows users to stay logged in without re-authenticating.
--
-- Example:
-- >>> newToken <- refreshToken config oldToken
-- >>> case newToken of
-- >>>   Right t -> sendNewToken t
-- >>>   Left err -> requireReLogin
refreshToken ::
  (MonadIO m) =>
  JWTConfig ->
  Text ->
  m (Either JWTError Text)
refreshToken config token = do
  maybeClaims <- verifyToken config token
  case maybeClaims of
    Nothing -> return $ Left TokenExpired
    Just claims -> generateToken config (jwtUserId claims) (jwtEmail claims)

-- -----------------------------------------------------------------------------
-- Internal JWT Encoding/Decoding
-- -----------------------------------------------------------------------------

-- | JWT header for HS256 algorithm.
jwtHeader :: ByteString
jwtHeader = LBS.toStrict $ encode $ object ["alg" .= ("HS256" :: Text), "typ" .= ("JWT" :: Text)]

-- | Encode a JWT payload into a signed token.
encodeJWT :: ByteString -> JWTPayload -> Text
encodeJWT secret payload =
  let headerB64 = base64UrlEncode jwtHeader
      payloadB64 = base64UrlEncode $ LBS.toStrict $ encode payload
      signingInput = headerB64 <> "." <> payloadB64
      signature = computeHMAC secret (encodeUtf8 signingInput)
      signatureB64 = base64UrlEncode signature
   in signingInput <> "." <> signatureB64

-- | Decode and verify a JWT token.
decodeJWT :: ByteString -> Text -> Maybe JWTPayload
decodeJWT secret token =
  case T.splitOn "." token of
    [headerB64, payloadB64, signatureB64] ->
      let signingInput = headerB64 <> "." <> payloadB64
          expectedSignature = computeHMAC secret (encodeUtf8 signingInput)
       in case base64UrlDecode (encodeUtf8 signatureB64) of
            Nothing -> Nothing
            Just actualSignature ->
              if constantTimeCompare expectedSignature actualSignature
                then case base64UrlDecode (encodeUtf8 payloadB64) of
                  Nothing -> Nothing
                  Just payloadBytes -> decode (LBS.fromStrict payloadBytes)
                else Nothing
    _ -> Nothing

-- | Compute HMAC-SHA256 signature.
computeHMAC :: ByteString -> ByteString -> ByteString
computeHMAC secret message =
  let hmacResult :: HMAC SHA256
      hmacResult = hmac secret message
   in convert hmacResult

-- | Base64 URL-safe encoding without padding.
base64UrlEncode :: ByteString -> Text
base64UrlEncode = decodeUtf8 . BS.filter (/= 0x3D) . B64URL.encode

-- | Base64 URL-safe decoding with padding handling.
base64UrlDecode :: ByteString -> Maybe ByteString
base64UrlDecode bs =
  let paddedLength = 4 - (BS.length bs `mod` 4)
      padded = if paddedLength < 4 then bs <> BS.replicate paddedLength 0x3D else bs
   in case B64URL.decode padded of
        Left _ -> Nothing
        Right decoded -> Just decoded

-- | Constant-time comparison to prevent timing attacks.
constantTimeCompare :: ByteString -> ByteString -> Bool
constantTimeCompare a b =
  BS.length a == BS.length b
    && (0 == foldl' xorByte 0 (BS.zipWith xorBytes a b))
  where
    xorByte acc byte = acc .|. byte
    xorBytes x y = x `xor` y
    foldl' = Data.List.foldl'
