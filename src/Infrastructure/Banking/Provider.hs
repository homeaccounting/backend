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

    -- * FX conversion pairing
    FxLeg (..),
    FxSignal,
    fxTransferMatcher,
    defaultFxPairingWindow,
  )
where

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import Domain.Banking.Import (ExternalTransactionId)
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact)
import Domain.Banking.Types (BankProviderCredential, BankProviderId, ExternalAccountId)
import Domain.Core.Types (CategoryId)
import Domain.Transaction.Matching.Transfer (TransferDirection (..), TransferLeg (..), isTransferMatch)
import RIO (Bool (..), Either, Eq, IO, Int, Maybe (..), Monoid (..), Ord, Rational, Semigroup (..), Show, abs, isJust, otherwise, ($), (&&), (/=), (<), (<=), (==), (||))

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
    -- | Provider-supplied category signal, if any: an MCC ('ByMcc', e.g.
    -- Monobank) or a text label ('ByLabel', e.g. PrivatBank). 'Nothing' when
    -- the provider supplies no category.
    category :: !(Maybe BankProviderCategory),
    -- | Provider-supplied counterparty signal, if any: a name-agnostic token
    -- identifying who the transaction was with (e.g. the counterparty
    -- descriptor/merchant text). 'Nothing' when the provider supplies none.
    contact :: !(Maybe BankProviderContact),
    -- | Major-unit amount in the transaction's original currency, iff the
    -- transaction was in a currency different from the account. Monobank
    -- does not report the original currency code; Phase 1 uses the ratio
    -- @|originalAmount| / |amount|@ to derive an exchange rate.
    originalAmount :: !(Maybe Rational),
    notes :: !(Maybe Text)
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
    pull :: !(Maybe (BankProviderCredential -> PullCapability)),
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

-- | Strategies compose by logical OR: the combined matcher pairs two legs when
-- /either/ component matcher would. This lets the generic, provider-specific
-- (e.g. PrivatBank card), and FX strategies coexist on one interpretation.
instance Semigroup TransferMatcher where
  TransferMatcher f <> TransferMatcher g = TransferMatcher (\a b -> f a b || g a b)

-- | 'mempty' is the matcher that never pairs — the identity of the OR.
instance Monoid TransferMatcher where
  mempty = TransferMatcher (\_ _ -> False)

-- | Provider-contributed interpretation of raw bank transactions: the
-- direction 'classify' hint, the internal-transfer 'transferMatcher', and the
-- provider's default label→category map ('labelExpenseCategories'). Groups the
-- label-category capability alongside classify/transfer matching so a
-- live-registry consumer can read it off the descriptor.
data TransactionInterpretation = TransactionInterpretation
  { classify :: BankTransaction -> TransactionClassification,
    transferMatcher :: TransferMatcher,
    -- | Mirrors the provider module's pure @labelExpenseCategories@ binding — the
    -- single source of truth for that provider's default text-label→expense-
    -- category mapping (empty for providers with no label defaults). NOTE:
    -- configuration seeding does NOT read this field; seeding must be pure, but
    -- the provider registry is effectful, so
    -- 'Infrastructure.Banking.CategoryDefaults' unions the standalone pure
    -- @labelExpenseCategories@ bindings directly. This field carries the same data for
    -- a live-registry (effectful) consumer.
    labelExpenseCategories :: Map Text CategoryId
  }

-- | Default window within which two opposite legs may be paired as a single
-- transfer: 5 minutes.
defaultTransferPairingWindow :: NominalDiffTime
defaultTransferPairingWindow = 300

-- | Project a bank transaction onto a normalised transfer leg. Sign gives
-- direction; the ISO numeric currency code is the match token.
bankTransactionLeg :: BankTransaction -> TransferLeg Int
bankTransactionLeg tx =
  TransferLeg
    { direction = if tx.amount < 0 then DebitLeg else CreditLeg,
      magnitude = abs tx.amount,
      currency = tx.currencyCode,
      time = tx.time
    }

-- | Generic transfer matcher: two legs pair when they share a currency, carry
-- opposite signs, have equal magnitude, and fall within @window@ of each
-- other.
defaultTransferMatcher :: NominalDiffTime -> TransferMatcher
defaultTransferMatcher window =
  TransferMatcher $ \a b ->
    isTransferMatch window (bankTransactionLeg a) (bankTransactionLeg b)

-- | Default interpretation for providers that need no bespoke logic:
-- 'defaultClassify' plus 'defaultTransferMatcher' over 'defaultTransferPairingWindow'.
defaultInterpretation :: TransactionInterpretation
defaultInterpretation =
  TransactionInterpretation
    { classify = defaultClassify,
      transferMatcher = defaultTransferMatcher defaultTransferPairingWindow,
      labelExpenseCategories = Map.empty
    }

-- | One leg of a currency conversion, carrying the conversion amount both legs
-- of one conversion state — the value the matcher pairs on. A conversion posts
-- two legs (a debit in one currency, a credit in another) whose statements
-- restate the /identical/ amount, so this exact 'Rational' is the pairing key
-- used by 'fxTransferMatcher'.
newtype FxLeg = FxLeg {fxAmount :: Rational}
  deriving (Eq, Show)

-- | Provider hook that recognises a currency-conversion leg and extracts its
-- conversion amount. 'Nothing' when the transaction is not a conversion leg.
type FxSignal = BankTransaction -> Maybe FxLeg

-- | Generous window: conversion legs may post minutes/hours apart the same day;
-- the EXACT shared conversion amount is the real discriminator, so a wide window
-- adds negligible false-positive risk.
defaultFxPairingWindow :: NominalDiffTime
defaultFxPairingWindow = 86400 -- 1 day

-- | Generic FX transfer matcher: two legs pair as one cross-currency conversion
-- when both carry an 'FxSignal' conversion amount, are in different currencies,
-- carry opposite signs, fall within @window@ of each other, and restate the
-- exact same conversion amount.
fxTransferMatcher :: FxSignal -> NominalDiffTime -> TransferMatcher
fxTransferMatcher signal window = TransferMatcher $ \a b ->
  case (signal a, signal b) of
    (Just la, Just lb) ->
      a.currencyCode
        /= b.currencyCode
        && (a.amount < 0)
        /= (b.amount < 0)
        && abs (diffUTCTime a.time b.time)
        <= window
        && la.fxAmount
        == lb.fxAmount
    _ -> False
