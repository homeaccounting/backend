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

    -- * Banking Value Types
    ExternalAccountId,
    PlainToken,
    BankConnectionName,
    BankProvider (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.Text (Text)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
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

-- | Identifier for an account at the external bank provider, rendered as text.
type ExternalAccountId = Text

-- | A decrypted provider API token (plaintext). Distinguished from the stored
-- ciphertext so call sites that handle the raw secret read clearly.
type PlainToken = Text

-- | A bank connection's user-facing display name.
type BankConnectionName = Text

-- | A supported external bank provider. Currently only Monobank is supported.
data BankProvider = Monobank
  deriving (Show, Eq, Ord, Generic)

instance ToJSON BankProvider

instance FromJSON BankProvider
