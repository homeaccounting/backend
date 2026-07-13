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

    -- * Banking Value Types
    ExternalAccountId,
    PlainToken,
    BankConnectionName,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), ToJSONKey (..))
import Data.Aeson.Types (toJSONKeyText)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), mkValidationError)
import GHC.Generics (Generic)

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

-- | Identifier for an account at the external bank provider, rendered as text.
type ExternalAccountId = Text

-- | A decrypted provider API token (plaintext). Distinguished from the stored
-- ciphertext so call sites that handle the raw secret read clearly.
type PlainToken = Text

-- | A bank connection's user-facing display name.
type BankConnectionName = Text
