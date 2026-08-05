{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Banking.Types
-- Description : Shared value types for the banking subdomain
--
-- This module defines the value types used across the banking-integration
-- subdomain (bank connections, external providers, provider tokens). Banking
-- is a distinct subdomain from core accounting, so these types live here
-- rather than in "Domain.Core.Types". All types include smart constructors
-- with validation where domain invariants must be maintained.
module Domain.Banking.Types
  ( -- * Bank Connection Identifier
    BankConnectionId,
    mkBankConnectionId,
    unsafeBankConnectionId,
    unBankConnectionId,

    -- * Bank Provider Identifier
    BankProviderId,
    mkBankProviderId,
    unsafeBankProviderId,
    unBankProviderId,

    -- * External Account Identifier
    ExternalAccountId,
    mkExternalAccountId,
    unsafeExternalAccountId,
    unExternalAccountId,

    -- * Banking Value Types
    BankProviderCredential (..),
    BankConnectionName,
  )
where

import Data.Aeson (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..), object, withObject, withText, (.:), (.=))
import Data.Aeson.Types (FromJSONKeyFunction (..), toJSONKeyText)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import GHC.Generics (Generic)
import RIO (Display (..))

-- -----------------------------------------------------------------------------
-- Bank Connection Identifier
-- -----------------------------------------------------------------------------

-- | Unique identifier for a bank connection.
newtype BankConnectionId = BankConnectionId
  { unBankConnectionId :: UUID
  }
  deriving (Show, Eq, Ord, Generic)

-- | Extract the UUID from a BankConnectionId.
unBankConnectionId :: BankConnectionId -> UUID
unBankConnectionId (BankConnectionId uuid) = uuid

instance ToJSON BankConnectionId where
  toJSON = toJSON . unBankConnectionId

instance FromJSON BankConnectionId where
  parseJSON v = BankConnectionId <$> parseJSON v

mkBankConnectionId :: UUID -> Either Text BankConnectionId
mkBankConnectionId uuid
  | uuid == UUID.nil = Left "BankConnectionId cannot be nil UUID"
  | otherwise = Right (BankConnectionId uuid)

unsafeBankConnectionId :: UUID -> BankConnectionId
unsafeBankConnectionId = BankConnectionId

-- -----------------------------------------------------------------------------
-- Bank Provider Identifier
-- -----------------------------------------------------------------------------

-- | Opaque, stable identifier for a bank provider (canonical slug).
-- Serialized as a bare string so it never churns the event/command schema.
newtype BankProviderId = BankProviderId Text
  deriving (Show, Eq, Ord, Generic)

unBankProviderId :: BankProviderId -> Text
unBankProviderId (BankProviderId t) = t

-- | Bypass validation. For wiring/tests only.
unsafeBankProviderId :: Text -> BankProviderId
unsafeBankProviderId = BankProviderId

-- | Validate a candidate id against the ids the running app knows about
-- (supplied from the registry at the boundary). Keeps the domain free of any
-- provider enumeration.
mkBankProviderId :: Set BankProviderId -> Text -> Either DomainError BankProviderId
mkBankProviderId known t
  | Set.member (BankProviderId t) known = Right (BankProviderId t)
  | otherwise =
      Left (ValidationErr (mkValidationError "provider" "Unknown or unavailable bank provider" t))

instance ToJSON BankProviderId where
  toJSON = toJSON . unBankProviderId

instance FromJSON BankProviderId where
  parseJSON v = BankProviderId <$> parseJSON v

-- | JSON object-key encoding for 'BankProviderId', built from the bare slug so
-- a @Map BankProviderId a@ serializes with string keys (used by the generic
-- 'ToJSON' for 'Infrastructure.Config.BankingConfig').
instance ToJSONKey BankProviderId where
  toJSONKey = toJSONKeyText unBankProviderId

-- -----------------------------------------------------------------------------
-- External Account Identifier
-- -----------------------------------------------------------------------------

-- | Identifier for a bank account in an external provider (e.g. a Monobank
--   account id, or a PrivatBank card mask). Must be non-empty.
newtype ExternalAccountId = ExternalAccountId Text
  deriving (Show, Eq, Ord, Generic)

unExternalAccountId :: ExternalAccountId -> Text
unExternalAccountId (ExternalAccountId t) = t

mkExternalAccountId :: Text -> Either Text ExternalAccountId
mkExternalAccountId t
  | T.null t = Left "ExternalAccountId must not be empty"
  | otherwise = Right (ExternalAccountId t)

unsafeExternalAccountId :: Text -> ExternalAccountId
unsafeExternalAccountId = ExternalAccountId

instance Display ExternalAccountId where
  display (ExternalAccountId t) = display t

instance ToJSON ExternalAccountId where
  toJSON = toJSON . unExternalAccountId

instance FromJSON ExternalAccountId where
  parseJSON = withText "ExternalAccountId" $ \t ->
    case mkExternalAccountId t of
      Right eid -> pure eid
      Left err -> fail (T.unpack err)

-- | JSON object-key encoding for 'ExternalAccountId', so a
-- @Map ExternalAccountId a@ serializes with string keys (used by the generic
-- 'ToJSON'/'FromJSON' derived for the Configuration events/commands/projection).
instance ToJSONKey ExternalAccountId where
  toJSONKey = toJSONKeyText unExternalAccountId

instance FromJSONKey ExternalAccountId where
  fromJSONKey = FromJSONKeyTextParser (either (fail . T.unpack) pure . mkExternalAccountId)

-- | A decrypted, provider-agnostic credential for a bank connection.
--
-- Encrypted as JSON and stored inside the existing opaque
-- 'Infrastructure.Crypto.SecretBox.EncryptedSecret' at rest, so this type's
-- shape lives entirely inside the encrypted blob: the persisted
-- command\/event\/projection schema (which only ever carries the ciphertext)
-- is unaffected by future changes here.
--
-- JSON is explicitly tagged (@{"kind":"static","secret":"…"}@) rather than
-- derived, so adding a future variant is purely additive to the plaintext
-- format and never disturbs 'StaticSecret'\'s own encoding.
data BankProviderCredential
  = -- | A single opaque static secret (e.g. a Monobank personal API token),
    -- used verbatim as the provider's bearer credential.
    StaticSecret Text
  -- Future, additive (no event-schema change): an @OAuth2@ variant carrying
  -- access/refresh tokens, expiry, and scopes would slot in here as another
  -- constructor of this same sum, e.g.:
  --   OAuth2 { accessToken :: Text, refreshToken :: Text, expiresAt ::
  --   UTCTime, scopes :: [Text] }
  deriving (Show, Eq, Generic)

instance ToJSON BankProviderCredential where
  toJSON (StaticSecret secret) =
    object ["kind" .= ("static" :: Text), "secret" .= secret]

instance FromJSON BankProviderCredential where
  parseJSON = withObject "BankProviderCredential" $ \o -> do
    kind <- o .: "kind"
    case (kind :: Text) of
      "static" -> StaticSecret <$> o .: "secret"
      other -> fail ("Unknown BankProviderCredential kind: " <> T.unpack other)

-- | A bank connection's user-facing display name.
type BankConnectionName = Text
