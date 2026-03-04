{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Auth.Password
-- Description : Password hashing using Argon2
--
-- This module provides password hashing and verification using the Argon2id
-- algorithm, which is the recommended choice for password hashing due to its
-- resistance to GPU and side-channel attacks.
--
-- Key Functions:
--   - hashPassword: Hash a plaintext password
--   - verifyPassword: Verify a password against a hash
--
-- Security Properties:
--   - Uses Argon2id (hybrid mode combining Argon2i and Argon2d)
--   - Memory-hard to resist GPU attacks
--   - Includes salt in the hash output
--   - Configurable parameters for future-proofing
--
-- Usage:
-- >>> hash <- hashPassword "mySecretPassword"
-- >>> let isValid = verifyPassword "mySecretPassword" hash
-- >>> print isValid
-- True
module Infrastructure.Auth.Password
  ( -- * Password Hashing
    hashPassword,
    verifyPassword,

    -- * Configuration
    PasswordHashConfig (..),
    defaultPasswordHashConfig,
    hashPasswordWithConfig,
  )
where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Crypto.Error (CryptoFailable (..))
import Crypto.KDF.Argon2
  ( Options (..),
    Variant (..),
    Version (..),
    hash,
  )
import Crypto.Random (getRandomBytes)
import Data.Bits (xor, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.List
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word32)
import Domain.Core.Types (PasswordHash (..))

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

-- | Configuration for password hashing.
--
-- These parameters control the security/performance trade-off of the
-- password hashing. Higher values = more secure but slower.
--
-- Recommended minimums (OWASP 2023):
--   - Memory: 19456 KiB (19 MiB)
--   - Iterations: 2
--   - Parallelism: 1
data PasswordHashConfig = PasswordHashConfig
  { -- | Memory cost in KiB (default: 65536 = 64 MiB)
    memory :: Word32,
    -- | Number of iterations (default: 3)
    iterations :: Word32,
    -- | Degree of parallelism (default: 4)
    parallelism :: Word32,
    -- | Output hash length in bytes (default: 32)
    hashLength :: Word32,
    -- | Salt length in bytes (default: 16)
    saltLength :: Int
  }
  deriving (Show, Eq)

-- | Default password hashing configuration.
--
-- Uses secure defaults suitable for most applications:
--   - 64 MiB memory
--   - 3 iterations
--   - 4 parallel lanes
--   - 32-byte output
--   - 16-byte salt
defaultPasswordHashConfig :: PasswordHashConfig
defaultPasswordHashConfig =
  PasswordHashConfig
    { memory = 65536, -- 64 MiB
      iterations = 3,
      parallelism = 4,
      hashLength = 32,
      saltLength = 16
    }

-- -----------------------------------------------------------------------------
-- Password Hashing
-- -----------------------------------------------------------------------------

-- | Hash a password using Argon2id with default configuration.
--
-- The resulting hash includes:
--   - The salt (prepended)
--   - The hash output
--
-- These are combined into a single ByteString that can be stored
-- and later used for verification.
--
-- Example:
-- >>> hash <- hashPassword "myPassword"
-- >>> print hash
-- PasswordHash "<base64-encoded-salt+hash>"
hashPassword :: (MonadIO m) => Text -> m PasswordHash
hashPassword = hashPasswordWithConfig defaultPasswordHashConfig

-- | Hash a password with custom configuration.
--
-- Use this when you need to tune the hashing parameters for
-- specific security or performance requirements.
--
-- Example:
-- >>> let config = defaultPasswordHashConfig { memory = 131072 }
-- >>> hash <- hashPasswordWithConfig config "myPassword"
hashPasswordWithConfig :: (MonadIO m) => PasswordHashConfig -> Text -> m PasswordHash
hashPasswordWithConfig config password = liftIO $ do
  salt <- getRandomBytes config.saltLength
  let passwordBytes = encodeUtf8 password
      options =
        Options
          { iterations = config.iterations,
            memory = config.memory,
            parallelism = config.parallelism,
            variant = Argon2id,
            version = Version13
          }
  case hash options passwordBytes salt (fromIntegral config.hashLength) of
    CryptoPassed hashOutput ->
      -- Combine salt + hash for storage
      let combined = salt <> hashOutput
       in return $ PasswordHash combined
    CryptoFailed err ->
      -- This should not happen with valid parameters, but handle it
      error $ "Password hashing failed: " ++ show err

-- | Verify a password against a stored hash.
--
-- Extracts the salt from the stored hash, re-hashes the input password
-- with the same salt, and compares the results using constant-time
-- comparison to prevent timing attacks.
--
-- Example:
-- >>> let isValid = verifyPassword "myPassword" storedHash
-- >>> if isValid then grantAccess else denyAccess
verifyPassword :: Text -> PasswordHash -> Bool
verifyPassword password (PasswordHash stored)
  | BS.length stored < saltLen + hashLen = False
  | otherwise =
      let salt = BS.take saltLen stored
          storedHash = BS.drop saltLen stored
          passwordBytes = encodeUtf8 password
          options =
            Options
              { iterations = defaultPasswordHashConfig.iterations,
                memory = defaultPasswordHashConfig.memory,
                parallelism = defaultPasswordHashConfig.parallelism,
                variant = Argon2id,
                version = Version13
              }
       in case hash options passwordBytes salt hashLen of
            CryptoPassed computedHash -> constantTimeCompare storedHash computedHash
            CryptoFailed _ -> False
  where
    saltLen = defaultPasswordHashConfig.saltLength
    hashLen = fromIntegral defaultPasswordHashConfig.hashLength

-- | Constant-time comparison to prevent timing attacks.
--
-- Compares two ByteStrings in constant time regardless of where
-- they differ. This is important for security-sensitive comparisons.
constantTimeCompare :: ByteString -> ByteString -> Bool
constantTimeCompare a b =
  BS.length a == BS.length b
    && (0 == Data.List.foldl' xorByte 0 (BS.zipWith xorBytes a b))
  where
    xorByte acc byte = acc .|. byte
    xorBytes x y = x `xor` y
