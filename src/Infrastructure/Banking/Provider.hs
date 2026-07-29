{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Provider
  ( -- * Provider
    TransactionClassification (..),
    TransactionInterpretation (..),
    TransferMatcher (..),

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
    defaultInterpretation,
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Domain.Banking.Types (BankProviderId, ExternalAccountId, ProviderCredential)
import Domain.Core.Types (ExternalTransactionId, MCC)
import RIO (Bool, Either, Eq, IO, Int, Maybe, Ord, Rational, Show, abs, isJust, otherwise, signum, ($), (&&), (/=), (<), (<=), (==))

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
    interpretation :: TransactionInterpretation,
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

-- | Decides whether two provider transactions are the two legs of one
-- internal transfer between the user's own accounts. Wrapped in a newtype for
-- a named 'matchesTransfer' accessor and nominal typing at call sites, rather
-- than a bare function.
newtype TransferMatcher = TransferMatcher
  { matchesTransfer :: BankTransaction -> BankTransaction -> Bool
  }

-- | Provider-contributed interpretation of raw bank transactions: the
-- direction 'classify' hint plus the internal-transfer 'transferMatcher'.
data TransactionInterpretation = TransactionInterpretation
  { classify :: BankTransaction -> TransactionClassification,
    transferMatcher :: TransferMatcher
  }

-- | Default window within which two opposite legs may be paired as a single
-- transfer: 5 minutes.
defaultTransferPairingWindow :: NominalDiffTime
defaultTransferPairingWindow = 300

-- | Generic transfer matcher: two legs pair when they share a currency, carry
-- opposite signs, have equal magnitude, and fall within @window@ of each
-- other.
defaultTransferMatcher :: NominalDiffTime -> TransferMatcher
defaultTransferMatcher window =
  TransferMatcher $ \a b ->
    a.currencyCode
      == b.currencyCode
      && signum a.amount
      /= signum b.amount
      && abs a.amount
      == abs b.amount
      && abs (diffUTCTime a.time b.time)
      <= window

-- | Default interpretation for providers that need no bespoke logic:
-- 'defaultClassify' plus 'defaultTransferMatcher' over 'defaultTransferPairingWindow'.
defaultInterpretation :: TransactionInterpretation
defaultInterpretation =
  TransactionInterpretation defaultClassify (defaultTransferMatcher defaultTransferPairingWindow)
