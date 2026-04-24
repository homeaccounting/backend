{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Provider
  ( -- * Provider
    BankProvider (..),
    TransactionClassification (..),

    -- * Types
    BankAccountId,
    BankAccount (..),
    BankTransaction (..),
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Core.Types (ExternalTransactionId, MCC)
import RIO (Bool, Either, Eq, IO, Int, Maybe, Rational, Show)

-- | Identifier for an external bank account (provider-specific).
type BankAccountId = Text

-- | Record-of-functions abstraction for bank API providers.
--
-- Each bank (Monobank, PrivatBank, etc.) implements this interface.
-- Ephemeral — constructed per-request from user's token, NOT stored in AppEnv.
data BankProvider = BankProvider
  { providerName :: !Text,
    fetchAccounts :: IO (Either Text [BankAccount]),
    fetchStatements :: BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction]),
    registerWebhook :: Text -> IO (Either Text ()),
    classifyTransaction :: BankTransaction -> TransactionClassification
  }

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
