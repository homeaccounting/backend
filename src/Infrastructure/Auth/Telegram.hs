{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Infrastructure.Auth.Telegram
-- Description : Telegram authentication for web login widget and bot
--
-- This module provides Telegram authentication support for:
--   1. Telegram Login Widget (web authentication)
--   2. Telegram Bot authentication (bot users)
--
-- Telegram Login Widget Flow:
--   1. User clicks "Login with Telegram" widget on website
--   2. Telegram sends auth data to callback URL
--   3. Server verifies auth data hash using bot token
--   4. Server creates/links user account
--
-- Bot Authentication Flow:
--   1. User sends /start or /login to bot
--   2. Bot receives user's Telegram identity
--   3. Server verifies update is from Telegram
--   4. Server creates/links user account
--
-- Security:
--   - Auth data is signed with HMAC-SHA256 using bot token
--   - Data must be recent (within 24 hours by default)
--   - Bot token hash is used as signing key
module Infrastructure.Auth.Telegram
  ( -- * Configuration
    TelegramConfig (..),

    -- * Auth Data
    TelegramAuthData (..),

    -- * Verification
    verifyTelegramAuth,
    verifyTelegramAuthWithTime,

    -- * Authentication
    authenticateViaTelegram,

    -- * Errors
    TelegramAuthError (..),
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Crypto.Hash (SHA256 (..), hashWith)
import Crypto.MAC.HMAC (HMAC (..), hmac)
import Data.Aeson (FromJSON (..), ToJSON, withObject, (.!=), (.:), (.:?))
import Data.Bits (xor, (.|.))
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import Data.Int (Int64)
import Data.List (sortBy)
import qualified Data.List
import Data.Ord (comparing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime, secondsToNominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Core.Types (TelegramId (..), TelegramIdentity (..), UserId)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

-- | Configuration for Telegram authentication.
data TelegramConfig = TelegramConfig
  { -- | Telegram Bot token (from @BotFather)
    telegramBotToken :: Text,
    -- | Bot username (without @)
    telegramBotUsername :: Text,
    -- | Maximum age of auth data in seconds (default: 86400 = 24 hours)
    telegramAuthMaxAge :: NominalDiffTime,
    -- | Webhook URL for receiving bot updates (production)
    telegramWebhookUrl :: Maybe Text,
    -- | Use polling instead of webhook (development)
    telegramUsePolling :: Bool,
    -- | Polling timeout in seconds (default: 30)
    telegramPollingTimeout :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramConfig

instance FromJSON TelegramConfig where
  parseJSON = withObject "TelegramConfig" $ \v ->
    TelegramConfig
      <$> v .: "bot_token"
      <*> v .: "bot_username"
      <*> (secondsToNominalDiffTime . fromIntegral <$> (v .:? "auth_max_age_seconds" .!= (86400 :: Int)))
      <*> v .:? "webhook_url"
      <*> v .:? "use_polling" .!= True
      <*> v .:? "polling_timeout" .!= 30

-- | Default Telegram configuration.
defaultTelegramConfig :: Text -> Text -> TelegramConfig
defaultTelegramConfig botToken botUsername =
  TelegramConfig
    { telegramBotToken = botToken,
      telegramBotUsername = botUsername,
      telegramAuthMaxAge = 86400, -- 24 hours
      telegramWebhookUrl = Nothing,
      telegramUsePolling = True,
      telegramPollingTimeout = 30
    }

-- -----------------------------------------------------------------------------
-- Auth Data
-- -----------------------------------------------------------------------------

-- | Data received from Telegram Login Widget.
--
-- This data is passed to the callback URL after user authenticates.
-- The hash field is used to verify the data integrity.
data TelegramAuthData = TelegramAuthData
  { -- | Telegram user ID
    telegramAuthId :: Int64,
    -- | User's first name
    telegramAuthFirstName :: Text,
    -- | User's last name (optional)
    telegramAuthLastName :: Maybe Text,
    -- | Username without @ (optional)
    telegramAuthUsername :: Maybe Text,
    -- | URL to user's profile photo (optional)
    telegramAuthPhotoUrl :: Maybe Text,
    -- | Unix timestamp when auth was performed
    telegramAuthDate :: Int64,
    -- | HMAC-SHA256 hash of the data
    telegramAuthHash :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TelegramAuthData

instance FromJSON TelegramAuthData

-- -----------------------------------------------------------------------------
-- Errors
-- -----------------------------------------------------------------------------

-- | Errors that can occur during Telegram authentication.
data TelegramAuthError
  = -- | Hash verification failed (tampered or forged data)
    InvalidHash
  | -- | Auth data is too old
    AuthDataExpired
  | -- | Missing required field in auth data
    MissingField Text
  | -- | Invalid auth data format
    InvalidAuthData Text
  deriving (Show, Eq, Generic)

instance ToJSON TelegramAuthError

instance FromJSON TelegramAuthError

-- -----------------------------------------------------------------------------
-- Verification
-- -----------------------------------------------------------------------------

-- | Verify Telegram Login Widget auth data.
--
-- Verification steps:
--   1. Check that auth_date is recent enough
--   2. Compute expected hash using bot token
--   3. Compare with provided hash
--
-- Example:
-- >>> result <- verifyTelegramAuth config authData
-- >>> case result of
-- >>>   Right () -> createOrLinkUser authData
-- >>>   Left err -> rejectAuth err
verifyTelegramAuth ::
  (MonadIO m) =>
  TelegramConfig ->
  TelegramAuthData ->
  m (Either TelegramAuthError ())
verifyTelegramAuth config authData = do
  now <- liftIO getCurrentTime
  return $ verifyTelegramAuthWithTime config authData now

-- | Verify Telegram auth data with explicit current time (for testing).
verifyTelegramAuthWithTime ::
  TelegramConfig ->
  TelegramAuthData ->
  UTCTime ->
  Either TelegramAuthError ()
verifyTelegramAuthWithTime config authData now = do
  -- Check auth data age
  let authTime = posixSecondsToUTCTime $ fromIntegral $ telegramAuthDate authData
      maxAge = telegramAuthMaxAge config
      maxTime = addUTCTime maxAge authTime

  if now > maxTime
    then Left AuthDataExpired
    else -- Verify hash
      let expectedHash = computeTelegramHash (telegramBotToken config) authData
       in if constantTimeCompare (encodeUtf8 expectedHash) (encodeUtf8 $ telegramAuthHash authData)
            then Right ()
            else Left InvalidHash

-- | Compute expected hash for Telegram auth data.
--
-- The hash is computed as:
--   1. Create data-check-string: key=value pairs sorted alphabetically, joined by newlines
--   2. Compute secret_key = SHA256(bot_token)
--   3. hash = HMAC-SHA256(data_check_string, secret_key)
computeTelegramHash :: Text -> TelegramAuthData -> Text
computeTelegramHash botToken authData =
  let -- Build key=value pairs (excluding hash)
      pairs =
        sortBy (comparing fst) $
          filter (not . T.null . snd) $
            [ ("auth_date", T.pack $ show $ telegramAuthDate authData),
              ("first_name", telegramAuthFirstName authData),
              ("id", T.pack $ show $ telegramAuthId authData)
            ]
              ++ maybe [] (\x -> [("last_name", x)]) (telegramAuthLastName authData)
              ++ maybe [] (\x -> [("photo_url", x)]) (telegramAuthPhotoUrl authData)
              ++ maybe [] (\x -> [("username", x)]) (telegramAuthUsername authData)

      -- Create data-check-string
      dataCheckString = T.intercalate "\n" $ map (\(k, v) -> k <> "=" <> v) pairs

      -- Compute secret key = SHA256(bot_token)
      secretKey :: ByteString
      secretKey = convert $ hashWith SHA256 (encodeUtf8 botToken)

      -- Compute HMAC-SHA256
      hmacResult :: HMAC SHA256
      hmacResult = hmac secretKey (encodeUtf8 dataCheckString)

      -- Convert to hex string
      hashBytes = convert hmacResult :: ByteString
   in T.pack $ BS8.unpack $ toHex hashBytes

-- | Convert ByteString to hexadecimal Text.
toHex :: ByteString -> ByteString
toHex = BS.concatMap toHexByte
  where
    toHexByte b =
      let (hi, lo) = b `divMod` 16
       in BS.pack [hexChar hi, hexChar lo]
    hexChar n
      | n < 10 = 0x30 + n -- '0' to '9'
      | otherwise = 0x61 + (n - 10) -- 'a' to 'f'

-- -----------------------------------------------------------------------------
-- Authentication
-- -----------------------------------------------------------------------------

-- | Authenticate a user via Telegram.
--
-- This function verifies the auth data and returns the Telegram identity
-- that can be used to create or link a user account.
--
-- Returns:
--   - Right TelegramIdentity: Valid auth, use to create/link user
--   - Left TelegramAuthError: Invalid auth
--
-- Example:
-- >>> result <- authenticateViaTelegram config authData
-- >>> case result of
-- >>>   Right identity -> do
-- >>>     maybeUser <- findUserByTelegramId (telegramId identity)
-- >>>     case maybeUser of
-- >>>       Just user -> loginUser user
-- >>>       Nothing -> createNewUser identity
-- >>>   Left err -> rejectAuth err
authenticateViaTelegram ::
  (MonadIO m) =>
  TelegramConfig ->
  TelegramAuthData ->
  m (Either TelegramAuthError TelegramIdentity)
authenticateViaTelegram config authData = do
  verifyResult <- verifyTelegramAuth config authData
  case verifyResult of
    Left err -> return $ Left err
    Right () ->
      return $
        Right
          TelegramIdentity
            { telegramId = TelegramId $ telegramAuthId authData,
              telegramUsername = telegramAuthUsername authData,
              telegramFirstName = telegramAuthFirstName authData
            }

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Constant-time comparison to prevent timing attacks.
constantTimeCompare :: ByteString -> ByteString -> Bool
constantTimeCompare a b =
  BS.length a == BS.length b
    && (0 == Data.List.foldl' xorByte 0 (BS.zipWith xorBytes a b))
  where
    xorByte acc byte = acc .|. byte
    xorBytes x y = x `xor` y
