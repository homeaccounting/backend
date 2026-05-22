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
  | -- | Cannot edit metadata (labels, category, description, business date) on a
    -- transaction that is not in the Completed state.
    --
    -- The name reflects the rejection condition (status /= Completed), not the
    -- allowed state. The HTTP error code @TRANSACTION_NOT_COMPLETED@ is the
    -- snake-case form of that same condition.
    CannotEditUncompletedTransaction
  | -- | Cannot change the category on a transaction with no category (Transfer or Adjustment).
    CannotChangeCategoryOnUncategorizedTransaction
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
-- returned by 'Application.Services.BankImportService.resync'. Unlike the
-- derived 'Show' instance (which produces Haskell constructor syntax like
-- @"BankingError \"...\""@), this formatter emits plain prose.
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
  CannotEditUncompletedTransaction ->
    "Transaction metadata can only be changed after the transfer has completed"
  CannotChangeCategoryOnUncategorizedTransaction ->
    "Category cannot be set on a Transfer or Adjustment"
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
