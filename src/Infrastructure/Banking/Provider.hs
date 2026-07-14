{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Provider
  ( -- * Provider
    TransactionClassification (..),

    -- * Types
    BankAccount (..),
    BankTransaction (..),

    -- * Descriptor + capabilities
    BankProviderDescriptor (..),
    PullCapability (..),
    FileImportCapability (..),
    StatementFormat (..),
    ParseError (..),
    RowError (..),
    StatementParser,
    providerSupportsPull,
    providerSupportsFile,
    defaultClassify,
  )
where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Banking.Types (BankProviderId, ExternalAccountId, ProviderCredential)
import Domain.Core.Types (ExternalTransactionId, MCC)
import RIO (Bool, Either, Eq, IO, Int, Maybe, Ord, Rational, Show, isJust, otherwise, (<))

-- | Provider-contributed classification hint — direction only.
-- BankImportService owns the final category decision.
data TransactionClassification
  = ClassifiedExpense
  | ClassifiedIncome
  deriving (Show, Eq)

-- | A bank account as reported by the provider.
data BankAccount = BankAccount
  { externalAccountId :: !ExternalAccountId,
    accountNumber :: !Text,
    currencyCode :: !Int,
    cardMasks :: ![Text],
    balance :: !Int64
  }
  deriving (Show, Eq)

-- | A bank transaction as reported by the provider.
data BankTransaction = BankTransaction
  { externalId :: !ExternalTransactionId,
    externalAccountId :: !ExternalAccountId,
    time :: !UTCTime,
    -- | Account-currency amount in major units (e.g. 12.34 not 1234). Signed.
    amount :: !Rational,
    -- | ISO 4217 numeric code of the account currency.
    currencyCode :: !Int,
    description :: !Text,
    hold :: !Bool,
    mcc :: !(Maybe MCC),
    -- | Major-unit amount in the transaction's original currency, iff the
    -- transaction was in a currency different from the account. Monobank
    -- does not report the original currency code; Phase 1 uses the ratio
    -- @|originalAmount| / |amount|@ to derive an exchange rate.
    originalAmount :: !(Maybe Rational),
    notes :: !(Maybe Text),
    categoryHint :: !(Maybe Text)
  }
  deriving (Show, Eq)

-- | Metadata + optional capabilities for a bank provider, keyed by its
-- stable 'BankProviderId'. This is the single provider abstraction: the
-- registry holds one per compiled-in, enabled provider.
--
-- 'pull' is present for providers that support live API access (credential
-- in, capability out); 'fileImport' is present for providers that support
-- statement-file import. Both, one, or neither may be populated.
data BankProviderDescriptor = BankProviderDescriptor
  { providerId :: !BankProviderId,
    displayName :: !Text,
    classify :: BankTransaction -> TransactionClassification,
    pull :: !(Maybe (ProviderCredential -> PullCapability)),
    fileImport :: !(Maybe FileImportCapability)
  }

-- | Whether a provider descriptor supports the live pull/API transport.
providerSupportsPull :: BankProviderDescriptor -> Bool
providerSupportsPull d = isJust d.pull

-- | Whether a provider descriptor supports the statement-file-import
-- transport.
providerSupportsFile :: BankProviderDescriptor -> Bool
providerSupportsFile d = isJust d.fileImport

-- | Live bank-API capability, constructed from a decrypted user credential.
-- Carries the per-request request closures; the provider name and classifier
-- live on the owning 'BankProviderDescriptor'.
data PullCapability = PullCapability
  { fetchAccounts :: IO (Either Text [BankAccount]),
    fetchStatements :: ExternalAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction]),
    registerWebhook :: Text -> IO (Either Text ())
  }

-- | Statement-file import capability: parse an uploaded statement into
-- '[BankTransaction]'. Consumed by @POST .../connections/:id/import/file@ via
-- 'Application.Services.ConfigurationService.getConnectionFileImport'. Keyed by
-- the formats a provider supports; a consumer computes 'Map.keys' when it
-- needs the supported-format list.
newtype FileImportCapability = FileImportCapability
  {parsers :: Map StatementFormat StatementParser}

-- | File formats a provider's 'FileImportCapability' can parse.
data StatementFormat = StatementCsv | StatementXlsx
  deriving (Show, Eq, Ord)

-- | Failure parsing a statement file.
newtype ParseError = ParseError Text
  deriving (Show, Eq)

-- | A single statement row that failed to parse. Structural/whole-file
--   failures use 'ParseError' instead.
data RowError = RowError {rowNumber :: !Int, message :: !Text}
  deriving (Show, Eq)

-- | Parse a statement of one already-selected format into per-row results:
--   'Left ParseError' for a whole-file/structural failure; otherwise one entry
--   per row, each 'Left RowError' (that row failed) or 'Right BankTransaction'.
type StatementParser = ByteString -> Either ParseError [Either RowError BankTransaction]

-- | Shared direction rule: money out (negative) is an expense, otherwise
-- income. The default 'classify' implementation for providers that don't
-- need bespoke logic (e.g. MCC-based overrides).
defaultClassify :: BankTransaction -> TransactionClassification
defaultClassify tx
  | tx.amount < 0 = ClassifiedExpense
  | otherwise = ClassifiedIncome
