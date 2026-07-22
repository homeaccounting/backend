{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Core.Errors
-- Description : Error types for domain operations
--
-- This module defines the error types used throughout the domain layer.
-- All domain operations that can fail should use these error types to
-- maintain consistent error handling across the system.
module Domain.Core.Errors
  ( -- * Domain Errors
    DomainError (..),
    ValidationError (..),
    mkValidationError,
    renderDomainError,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Generics (Generic)

-- | ISO-8601 rendering for UTCTime values that appear in user-facing
-- error messages.  Matches the form clients send via Aeson, so the
-- echoed value round-trips.
iso8601 :: UTCTime -> Text
iso8601 = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

-- -----------------------------------------------------------------------------
-- Domain Error Types
-- -----------------------------------------------------------------------------

-- | Top-level domain error type.
--
-- This represents all possible errors that can occur in the domain layer.
-- Each variant corresponds to a specific category of domain error.
data DomainError
  = -- | Validation error occurred
    ValidationErr ValidationError
  | -- | Account-related error
    AccountError Text
  | -- | Transaction-related error
    TransactionError Text
  | -- | User-related error
    UserError Text
  | -- | Configuration-related error
    ConfigurationError Text
  | -- | Insufficient funds for operation
    InsufficientFunds
      { sourceAmount :: Double,
        requiredAmount :: Double
      }
  | -- | Exchange rate unavailable for currency conversion
    ExchangeRateUnavailable Text
  | -- | Entity not found
    NotFound
      { entityType :: Text,
        entityId :: Text
      }
  | -- | Banking integration error
    BankingError Text
  | -- | A feature is disabled via configuration. The payload names the
    -- feature (e.g. @"banking"@) for diagnostic logs; HTTP mapping
    -- translates this to a 404 so the endpoint is hidden entirely when
    -- the feature flag is off.
    FeatureDisabled Text
  | -- | The referenced label does not exist in the user's labels dictionary.
    LabelNotFound Text
  | -- | The referenced category does not exist in the applicable dictionary.
    CategoryNotFound Text
  | -- | Cannot delete a label — still referenced by existing transactions.
    LabelInUse
      { entryId :: Text,
        usageCount :: Int
      }
  | -- | Cannot delete a category — still referenced by existing transactions.
    CategoryInUse
      { entryId :: Text,
        usageCount :: Int
      }
  | -- | Cannot remove a dictionary entry that is a non-empty group (it still
    -- has child entries). The children must be moved or removed first. A
    -- conflict with the current tree state, surfaced as HTTP 409.
    DictionaryGroupNotEmpty
  | -- | Cannot edit metadata (labels, category, description, business date) on a
    -- transaction that is not in the Completed state.
    --
    -- The name reflects the rejection condition (status /= Completed), not the
    -- allowed state. The HTTP error code @TRANSACTION_NOT_COMPLETED@ is the
    -- snake-case form of that same condition.
    CannotEditUncompletedTransaction
  | -- | Smart-constructor / handler rejection: sum of allocation amounts
    --   does not equal the categorised total.
    AllocationsDoNotSumToTotal
  | -- | An allocation's amount is zero or negative.
    AllocationAmountNotPositive
  | -- | An allocation's currency differs from the categorised side's currency.
    AllocationCurrencyMismatch
  | -- | A transaction direction carries a category allocation it must not:
    --   an `Expense` (outbound) transaction with a non-empty income bucket
    --   would be contra-income, which is unsupported.
    ContraIncomeNotSupported
  | -- | `mkAllocations` rejected a payload with both buckets empty —
    --   a categorised transaction must carry at least one allocation.
    AllocationsEmpty
  | -- | 'SetTransactionAllocations' or 'AmendTransaction' issued with a
    --   @newTransactionType@ whose kind differs from the existing transaction's.
    --   Recategorising across the kind boundary is a delete-and-repost
    --   operation.
    CannotChangeKindOfCategorisedTransaction
  | -- | 'SetTransactionAllocations' issued against a Transfer or Adjustment,
    --   which has no allocations to set.
    CannotSetAllocationsOnUncategorisedTransaction
  | -- | 'SetTransactionAllocations' issued against a non-Completed transaction.
    TransactionMustBeCompletedForAllocationsEdit
  | -- | Edit (or backdated creation) would land in a closed period.
    --   @current@ is the user's @booksClosedThrough@; @attempted@ is the
    --   business date that triggered the rejection.
    CannotEditClosedPeriod
      { current :: UTCTime,
        attempted :: UTCTime
      }
  | -- | 'CloseBooksThrough' would rewind the cutoff (advance-only rule).
    --   @current@ is the existing cutoff; @attempted@ is the requested
    --   cutoff that did not strictly advance past it.
    CannotRewindBooksCloseDate
      { current :: UTCTime,
        attempted :: UTCTime
      }
  | -- | Transfer amendment would produce a transfer between the same two
    -- accounts (source and destination are identical after amendment).
    CannotAmendToSameAccountPair
  | -- | Transfer amendment would set the amount to zero.
    CannotAmendToZeroAmount
  | -- | 'AmendTransaction' supplied 'newAllocations = Nothing' for a kind
    --   change into Income or Expense. Caller must supply the new
    --   allocations covering the new categorised total.
    AllocationsRequiredForCategorisedKind
  | -- | 'AmendTransaction' supplied allocations but the derived new kind
    --   is Transfer. Transfer carries no allocations.
    AllocationsNotAllowedForTransferKind
  | -- | The synthesised 'newTransactionType' is 'Adjustment'. Reachable
    --   only via a service-layer programming bug (the service rejects
    --   @source == target@ before deriving the kind), so this is a
    --   defensive guard rather than a user-facing validation error.
    CannotAmendToAdjustmentKind
  | -- | The saga rejected the amendment because at least one account has
    -- insufficient funds.  @reason@ is the human-readable rejection message
    -- returned by the saga.
    InsufficientFundsForAmendment
      { reason :: Text
      }
  | -- | Cancelling a transaction that is already in the Cancelled terminal state.
    TransactionAlreadyCancelled
  | -- | A cancellation saga is already in progress on this transaction.
    -- Reachable via two near-simultaneous DELETE requests.
    CancellationAlreadyInProgress
  | -- | A bank-connection operation targeted a connection that does not exist
    -- for the user.
    BankConnectionNotFound
  | -- | A resync was requested against a connection whose @enabled@ flag is
    -- 'False'. Surfaces as 422 @CONNECTION_DISABLED@.
    BankConnectionDisabled
  | -- | A bank connection's account map references a local account that is
    -- already a target of a /different/ connection in this configuration
    -- (within-config uniqueness violation).
    BankConnectionAccountConflict
  | -- | A bank connection's account map references a local account that does
    -- not exist, or that the user does not own/edit. The payload carries the
    -- offending field name (e.g. @"accountMap"@) for the HTTP field-error.
    BankConnectionAccountInvalid Text
  | -- | 'CancelTransaction' issued while an amendment saga is in flight on the
    -- same transaction.
    CannotCancelDuringAmendment
  | -- | 'AmendTransaction' issued while a cancellation saga is in flight on the
    -- same transaction.
    CannotAmendDuringCancellation
  | -- | A refund income was linked to a target transaction that is not an
    -- Expense. Only expenses can be refunded.
    RefundTargetMustBeExpense
  | -- | A refund was linked to a Cancelled target transaction. A cancelled
    -- expense has no balance to refund.
    CannotRefundCancelledTransaction
  | -- | A relationship was requested between a transaction and itself.
    CannotRelateTransactionToItself
  | -- | A relationship was requested against a target that already declares an
    -- outbound edge of the same kind. Relations are depth-1 only (no chaining).
    CannotChainRelations
  | -- | A Refund relation's source ("from") transaction is not an income
    -- carrying a contra (expense-bucket) allocation. Only such an income can
    -- refund an expense.
    RefundSourceMustBeIncomeWithContra
  | -- | Adding this Refund would push the total refunded amount (existing
    -- refunds plus this one) above the target expense's refundable amount.
    RefundExceedsRefundableAmount
  | -- | The requested relation edge already exists (a duplicate forward edge,
    -- or — for 'Associated' — a reciprocal edge in the opposite direction).
    RelationAlreadyExists
  | -- | A removal was requested for a relation edge that does not exist in
    -- either direction (never created, or already removed). Idempotent removal
    -- surfaces the second removal as this.
    RelationNotFound
  | -- | A removal was requested for a 'Merge'/'Split' lineage edge. Lineage
    -- edges are structural provenance and are not user-removable.
    CannotRemoveLineageRelation
  deriving (Show, Eq, Generic)

instance ToJSON DomainError

instance FromJSON DomainError

-- | Validation errors for domain value objects.
--
-- These errors occur when attempting to create domain objects with invalid data.
data ValidationError = ValidationError
  { -- | Field that failed validation
    validationField :: Text,
    -- | Error message describing why validation failed
    validationMessage :: Text,
    -- | The invalid value that was provided
    validationValue :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ValidationError

instance FromJSON ValidationError

-- | Smart constructor for ValidationError.
--
-- Creates a validation error with the given field, message, and value.
--
-- Example:
-- >>> mkValidationError "amount" "must be positive" "100"
-- ValidationError {validationField = "amount", validationMessage = "must be positive", validationValue = "-100"}
mkValidationError :: Text -> Text -> Text -> ValidationError
mkValidationError field msg value =
  ValidationError
    { validationField = field,
      validationMessage = msg,
      validationValue = value
    }

-- | Render a 'DomainError' as user-facing prose.
--
-- Suitable for HTTP response bodies and per-transaction failure strings
-- returned by 'Application.Services.BankImportService.importConnection'.
-- Unlike the derived 'Show' instance (which produces Haskell constructor
-- syntax like @"BankingError \"...\""@), this formatter emits plain prose.
renderDomainError :: DomainError -> Text
renderDomainError err = case err of
  ValidationErr ve ->
    "Validation failed for "
      <> ve.validationField
      <> ": "
      <> ve.validationMessage
      <> " (value: "
      <> ve.validationValue
      <> ")"
  AccountError msg -> "Account error: " <> msg
  TransactionError msg -> "Transaction error: " <> msg
  UserError msg -> "User error: " <> msg
  ConfigurationError msg -> "Configuration error: " <> msg
  InsufficientFunds src req ->
    "Insufficient funds: have "
      <> T.pack (show src)
      <> ", need "
      <> T.pack (show req)
  ExchangeRateUnavailable msg -> "Exchange rate unavailable: " <> msg
  NotFound ty eid -> ty <> " not found: " <> eid
  BankingError msg -> "Banking error: " <> msg
  FeatureDisabled feature -> "Feature disabled: " <> feature
  LabelNotFound eid -> "Label not found: " <> eid
  CategoryNotFound eid -> "Category not found: " <> eid
  LabelInUse eid n ->
    "Cannot delete label " <> eid <> ": referenced by " <> T.pack (show n) <> " transaction(s)"
  CategoryInUse eid n ->
    "Cannot delete category " <> eid <> ": referenced by " <> T.pack (show n) <> " transaction(s)"
  DictionaryGroupNotEmpty ->
    "Cannot remove a dictionary group that still has entries; move or remove its children first"
  CannotEditUncompletedTransaction ->
    "Transaction metadata can only be changed after the transfer has completed"
  AllocationsDoNotSumToTotal ->
    "Sum of allocation amounts must equal the categorised amount"
  AllocationAmountNotPositive ->
    "Each allocation amount must be positive"
  AllocationCurrencyMismatch ->
    "All allocations must share the categorised currency"
  ContraIncomeNotSupported ->
    "An expense cannot carry income allocations (contra-income is not supported)"
  AllocationsEmpty ->
    "A categorised transaction must carry at least one allocation"
  CannotChangeKindOfCategorisedTransaction ->
    "Cannot change Income/Expense/Transfer/Adjustment via allocation edit; delete and repost instead"
  CannotSetAllocationsOnUncategorisedTransaction ->
    "Transfer and Adjustment transactions have no allocations to set"
  TransactionMustBeCompletedForAllocationsEdit ->
    "Allocations can only be edited on Completed transactions"
  CannotEditClosedPeriod cur att ->
    "Cannot edit a transaction in a closed period: books closed through "
      <> iso8601 cur
      <> ", attempted "
      <> iso8601 att
  CannotRewindBooksCloseDate cur att ->
    "Books-close date may only advance: current "
      <> iso8601 cur
      <> ", attempted "
      <> iso8601 att
  CannotAmendToSameAccountPair ->
    "Transfer cannot be amended to the same source and destination account"
  CannotAmendToZeroAmount ->
    "Transfer amount cannot be amended to zero"
  AllocationsRequiredForCategorisedKind ->
    "Allocations are required when amending into an Income or Expense kind"
  AllocationsNotAllowedForTransferKind ->
    "Allocations cannot be supplied when amending into a Transfer kind"
  CannotAmendToAdjustmentKind ->
    "Cross-kind amendment into Adjustment is not supported; use AdjustAccountBalance"
  InsufficientFundsForAmendment r ->
    "Insufficient funds for transfer amendment: " <> r
  TransactionAlreadyCancelled ->
    "Transaction is already cancelled"
  CancellationAlreadyInProgress ->
    "A cancellation is already in progress for this transaction"
  BankConnectionNotFound ->
    "Bank connection not found"
  BankConnectionDisabled ->
    "Bank connection is disabled"
  BankConnectionAccountConflict ->
    "The local account is already mapped by another bank connection"
  BankConnectionAccountInvalid field ->
    "Invalid account in " <> field <> ": the account does not exist or you cannot write to it"
  CannotCancelDuringAmendment ->
    "Transaction cannot be cancelled while an amendment is in progress"
  CannotAmendDuringCancellation ->
    "Transaction cannot be amended while a cancellation is in progress"
  RefundTargetMustBeExpense -> "Refund target must be an expense transaction"
  CannotRefundCancelledTransaction -> "Cannot refund a cancelled transaction"
  CannotRelateTransactionToItself -> "A transaction cannot be related to itself"
  CannotChainRelations -> "Relations cannot be chained (depth-1 only)"
  RefundSourceMustBeIncomeWithContra ->
    "A refund's source must be an income carrying a contra allocation"
  RefundExceedsRefundableAmount ->
    "Refund exceeds the target expense's remaining refundable amount"
  RelationAlreadyExists -> "The relation already exists"
  RelationNotFound -> "The relation does not exist"
  CannotRemoveLineageRelation ->
    "Merge/Split lineage relations cannot be removed"
