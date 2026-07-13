{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Provider
  ( -- * Provider
    TransactionClassification (..),

    -- * Types
    BankAccountId,
    BankAccount (..),
    BankTransaction (..),

    -- * Descriptor + capabilities
    BankProviderDescriptor (..),
    PullCapability (..),
    FileImportCapability (..),
    StatementFormat (..),
    ParseError (..),
    defaultClassify,
  )
where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Banking.Types (BankProviderId, PlainToken)
import Domain.Core.Types (ExternalTransactionId, MCC)
import RIO (Bool, Either, Eq, IO, Int, Maybe, Rational, Show, otherwise, (<))

-- | Identifier for an external bank account (provider-specific).
type BankAccountId = Text

-- | Provider-contributed classification hint — direction only.
-- BankImportService owns the final category decision.
data TransactionClassification
  = ClassifiedExpense
  | ClassifiedIncome
  deriving (Show, Eq)

-- | A bank account as reported by the provider.
data BankAccount = BankAccount
  { externalId :: !BankAccountId,
    accountNumber :: !Text,
    currencyCode :: !Int,
    cardMasks :: ![Text],
    balance :: !Int64
  }
  deriving (Show, Eq)

-- | A bank transaction as reported by the provider.
data BankTransaction = BankTransaction
  { externalId :: !ExternalTransactionId,
    accountId :: !BankAccountId,
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
-- 'pull' is present for providers that support live API access (token in,
-- capability out); 'fileImport' is present for providers that support
-- statement-file import. Both, one, or neither may be populated.
data BankProviderDescriptor = BankProviderDescriptor
  { providerId :: !BankProviderId,
    displayName :: !Text,
    classify :: BankTransaction -> TransactionClassification,
    pull :: !(Maybe (PlainToken -> PullCapability)),
    fileImport :: !(Maybe FileImportCapability)
  }

-- | Live bank-API capability, constructed from a decrypted user token.
-- Carries the per-request request closures; the provider name and classifier
-- live on the owning 'BankProviderDescriptor'.
data PullCapability = PullCapability
  { fetchAccounts :: IO (Either Text [BankAccount]),
    fetchStatements :: BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction]),
    registerWebhook :: Text -> IO (Either Text ())
  }

-- | Statement-file import capability. Defined now, UNUSED until a later
-- spec wires an import endpoint against it — it documents the seam.
data FileImportCapability = FileImportCapability
  { supportedFormats :: !(NonEmpty StatementFormat),
    parseStatement :: StatementFormat -> ByteString -> Either ParseError [BankTransaction]
  }

-- | File formats a provider's 'FileImportCapability' can parse.
data StatementFormat = StatementCsv | StatementXlsx
  deriving (Show, Eq)

-- | Failure parsing a statement file.
newtype ParseError = ParseError Text
  deriving (Show, Eq)

-- | Shared direction rule: money out (negative) is an expense, otherwise
-- income. The default 'classify' implementation for providers that don't
-- need bespoke logic (e.g. MCC-based overrides).
defaultClassify :: BankTransaction -> TransactionClassification
defaultClassify tx
  | tx.amount < 0 = ClassifiedExpense
  | otherwise = ClassifiedIncome
