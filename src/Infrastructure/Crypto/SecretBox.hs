{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Infrastructure.Crypto.SecretBox
-- Description : Authenticated encryption of small secrets using AES-256-GCM
--
-- This module provides a small "secret box" abstraction for encrypting
-- sensitive tokens (e.g. bank connection access tokens) at rest. It uses
-- AES-256-GCM (AEAD) from cryptonite, which provides both confidentiality
-- and integrity (tampering is detected on decryption).
--
-- Keys are managed through a 'KeyRing', which maps an integer key version to
-- a 32-byte key and designates one version as the "current" key used for
-- encryption. Storing the key version alongside the ciphertext allows for
-- key rotation: old ciphertexts remain decryptable as long as their key
-- version stays in the ring.
--
-- The serialised form 'EncryptedSecret' is JSON-friendly (all binary fields
-- are base64-encoded) so it can be embedded directly in events.
--
-- Security properties:
--   - AES-256-GCM authenticated encryption
--   - Fresh random 12-byte nonce per encryption
--   - 16-byte authentication tag
--   - No associated data (AAD) is used
module Infrastructure.Crypto.SecretBox
  ( EncryptedSecret (..),
    KeyRing,
    mkKeyRing,
    CryptoError (..),
    encryptSecret,
    decryptSecret,
  )
where

import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types
  ( AEAD,
    AEADMode (AEAD_GCM),
    AuthTag (..),
    aeadInit,
    aeadSimpleDecrypt,
    aeadSimpleEncrypt,
    cipherInit,
  )
import Crypto.Error (CryptoFailable (..))
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON, ToJSON)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64 as B64
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Generics (Generic)

-- | An encrypted secret in a JSON/event-friendly form. All binary fields are
-- base64-encoded.
data EncryptedSecret = EncryptedSecret
  { -- | Version of the key used to encrypt this secret (for rotation).
    keyVersion :: !Int,
    -- | base64-encoded 12-byte GCM nonce.
    nonce :: !Text,
    -- | base64-encoded ciphertext.
    ciphertext :: !Text,
    -- | base64-encoded 16-byte GCM authentication tag.
    authTag :: !Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON EncryptedSecret

instance FromJSON EncryptedSecret

-- | A set of versioned 32-byte keys with a designated current version used for
-- encryption.
data KeyRing = KeyRing
  { current :: !Int,
    keys :: !(Map.Map Int ByteString)
  }

-- | Build a 'KeyRing' from a current key version and a list of
-- @(version, key)@ pairs. Keys should be 32 bytes; an incorrect length is
-- detected at encryption/decryption time as 'BadKeyLength'.
mkKeyRing :: Int -> [(Int, ByteString)] -> KeyRing
mkKeyRing cur ks = KeyRing cur (Map.fromList ks)

-- | Errors that can occur during encryption or decryption.
data CryptoError
  = -- | No key for the requested version is present in the ring.
    KeyNotFound Int
  | -- | The key is not 32 bytes long (AES-256 requires a 256-bit key).
    BadKeyLength
  | -- | Authenticated decryption failed (wrong key, tampered ciphertext/tag).
    DecryptFailed
  | -- | A base64 field could not be decoded.
    BadEncoding Text
  deriving (Show, Eq)

-- | Number of bytes in a GCM nonce.
nonceLength :: Int
nonceLength = 12

-- | Number of bytes in the GCM authentication tag.
tagLength :: Int
tagLength = 16

-- | Initialise an AES-256-GCM AEAD context from a raw key and nonce, wrapping
-- the two cryptonite 'CryptoFailable' steps (cipher init + AEAD init).
initGcm :: ByteString -> ByteString -> Either CryptoError (AEAD AES256)
initGcm key iv
  | BS.length key /= 32 = Left BadKeyLength
  | otherwise =
      case cipherInit key :: CryptoFailable AES256 of
        CryptoFailed _ -> Left BadKeyLength
        CryptoPassed cipher ->
          case aeadInit AEAD_GCM cipher iv of
            CryptoFailed _ -> Left DecryptFailed
            CryptoPassed aead -> Right aead

-- | Encrypt a plaintext secret using the current key of the ring.
--
-- A fresh random 12-byte nonce is generated for every call, so encrypting the
-- same plaintext twice yields different ciphertexts.
encryptSecret :: KeyRing -> Text -> IO EncryptedSecret
encryptSecret ring plaintext = do
  iv <- getRandomBytes nonceLength
  let ptBytes = TE.encodeUtf8 plaintext
      ver = ring.current
  case Map.lookup ver ring.keys of
    Nothing -> ioError $ userError $ "SecretBox: " <> show (KeyNotFound ver)
    Just key ->
      case initGcm key iv of
        Left err -> ioError $ userError $ "SecretBox: " <> show err
        Right aead ->
          let (AuthTag tag, ct) = aeadSimpleEncrypt aead BS.empty ptBytes tagLength
           in pure
                EncryptedSecret
                  { keyVersion = ver,
                    nonce = b64Encode iv,
                    ciphertext = b64Encode ct,
                    authTag = b64Encode (convert tag)
                  }

-- | Decrypt an 'EncryptedSecret' using the key matching its 'keyVersion'.
--
-- Returns 'Left' if the key version is unknown, a base64 field is malformed,
-- or authentication fails (wrong key or tampered data).
decryptSecret :: KeyRing -> EncryptedSecret -> Either CryptoError Text
decryptSecret ring enc = do
  key <- maybe (Left (KeyNotFound enc.keyVersion)) Right (Map.lookup enc.keyVersion ring.keys)
  iv <- b64Decode "nonce" enc.nonce
  ct <- b64Decode "ciphertext" enc.ciphertext
  tagBytes <- b64Decode "authTag" enc.authTag
  aead <- initGcm key iv
  case aeadSimpleDecrypt aead BS.empty ct (AuthTag (convert tagBytes)) of
    Nothing -> Left DecryptFailed
    Just pt -> case TE.decodeUtf8' pt of
      Left _ -> Left (BadEncoding "plaintext is not valid UTF-8")
      Right t -> Right t

-- | Encode bytes to a base64 'Text'.
b64Encode :: ByteString -> Text
b64Encode = TE.decodeUtf8 . B64.encode

-- | Decode a base64 'Text' field to bytes, tagging failures with the field
-- name.
b64Decode :: Text -> Text -> Either CryptoError ByteString
b64Decode field t =
  case B64.decode (TE.encodeUtf8 t) of
    Right bs -> Right bs
    Left err -> Left (BadEncoding (field <> ": " <> T.pack err))
