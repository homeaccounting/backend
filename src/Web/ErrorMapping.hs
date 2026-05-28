{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Web.ErrorMapping
-- Description : Type-safe mapping from DomainError to HTTP ServerError
--
-- This module provides centralized, type-safe error mapping from domain errors
-- to HTTP error responses. All API handlers should use these functions instead
-- of constructing HTTP errors directly.
--
-- Mapping Rules:
--   - ValidationErr     -> 400 Bad Request
--   - AccountError      -> 400 Bad Request
--   - TransactionError  -> 400 Bad Request
--   - ConfigurationError -> 400 Bad Request
--   - InsufficientFunds -> 422 Unprocessable Entity
--   - NotFound          -> 404 Not Found
--
-- Usage:
-- >>> case serviceResult of
-- >>>   Left domainErr -> throwIO $ mapDomainError domainErr
-- >>>   Right value    -> return $ toResponse value
module Web.ErrorMapping
  ( -- * Error Mapping
    mapDomainError,
    throwDomainError,

    -- * Convenience Helpers
    throwValidation,
    throwNotFound,
  )
where

import Data.Aeson (encode)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Domain.Core.Errors
  ( DomainError (..),
    ValidationError (..),
  )
import RIO
import Servant.Server (ServerError, err400, err404, err409, err422, errBody)
import Web.Types (ErrorResponse (..), ValidationErrorResponse (..))

-- | Render a UTCTime as ISO-8601 so client-side parsers (and round-trip
-- with the request body, which uses Aeson's ISO-8601 form) work.
iso8601 :: UTCTime -> Text
iso8601 = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

-- -----------------------------------------------------------------------------
-- Core Error Mapping
-- -----------------------------------------------------------------------------

-- | Map a DomainError to an HTTP ServerError with structured JSON body.
--
-- Pattern matches on DomainError constructors for type-safe mapping:
--   - ValidationErr     -> 400 with field-level error details
--   - AccountError      -> 400 with error message
--   - TransactionError  -> 400 with error message
--   - ConfigurationError -> 400 with error message
--   - InsufficientFunds -> 422 with source/required amounts
--   - NotFound          -> 404 with entity type and ID
mapDomainError :: DomainError -> ServerError
mapDomainError (ValidationErr ve) =
  err400
    { errBody =
        encode $
          ValidationErrorResponse
            { message = "Validation failed",
              fieldErrors =
                Map.singleton
                  ve.validationField
                  ve.validationMessage
            }
    }
mapDomainError (AccountError msg) =
  err400
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "ACCOUNT_ERROR",
              details = Nothing
            }
    }
mapDomainError (TransactionError msg) =
  err400
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "TRANSACTION_ERROR",
              details = Nothing
            }
    }
mapDomainError (UserError msg) =
  err400
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "USER_ERROR",
              details = Nothing
            }
    }
mapDomainError (ConfigurationError msg) =
  err400
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "CONFIGURATION_ERROR",
              details = Nothing
            }
    }
mapDomainError (InsufficientFunds srcAmount reqAmount) =
  err422
    { errBody =
        encode $
          ErrorResponse
            { message = "Insufficient funds",
              code = "INSUFFICIENT_FUNDS",
              details =
                Just $
                  Map.fromList
                    [ ("sourceAmount", tshow srcAmount),
                      ("requiredAmount", tshow reqAmount)
                    ]
            }
    }
mapDomainError (ExchangeRateUnavailable msg) =
  err422
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "EXCHANGE_RATE_UNAVAILABLE",
              details = Nothing
            }
    }
mapDomainError (NotFound etype eid) =
  err404
    { errBody =
        encode $
          ErrorResponse
            { message = etype <> " not found",
              code = "NOT_FOUND",
              details = Just $ Map.singleton "entityId" eid
            }
    }
mapDomainError (BankingError msg) =
  err400
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "BANKING_ERROR",
              details = Nothing
            }
    }
mapDomainError (FeatureDisabled feature) =
  err404
    { errBody =
        encode $
          ErrorResponse
            { message = "Feature not available",
              code = "FEATURE_DISABLED",
              details = Just $ Map.singleton "feature" feature
            }
    }
mapDomainError (LabelNotFound eid) =
  err404
    { errBody =
        encode $
          ErrorResponse
            { message = "Label not found",
              code = "LABEL_NOT_FOUND",
              details = Just $ Map.singleton "entryId" eid
            }
    }
mapDomainError (CategoryNotFound eid) =
  err404
    { errBody =
        encode $
          ErrorResponse
            { message = "Category not found",
              code = "CATEGORY_NOT_FOUND",
              details = Just $ Map.singleton "entryId" eid
            }
    }
mapDomainError (LabelInUse eid n) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Label is referenced by existing transactions",
              code = "LABEL_IN_USE",
              details =
                Just $
                  Map.fromList
                    [ ("entryId", eid),
                      ("usageCount", tshow n)
                    ]
            }
    }
mapDomainError (CategoryInUse eid n) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Category is referenced by existing transactions",
              code = "CATEGORY_IN_USE",
              details =
                Just $
                  Map.fromList
                    [ ("entryId", eid),
                      ("usageCount", tshow n)
                    ]
            }
    }
mapDomainError CannotEditUncompletedTransaction =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Transaction metadata can only be changed after the transfer has completed",
              code = "TRANSACTION_NOT_COMPLETED",
              details = Nothing
            }
    }
mapDomainError CannotChangeCategoryOnUncategorizedTransaction =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Category cannot be set on a Transfer or Adjustment",
              code = "CATEGORY_NOT_APPLICABLE",
              details = Nothing
            }
    }
mapDomainError (CannotEditClosedPeriod cur att) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Cannot edit a transaction in a closed period",
              code = "CANNOT_EDIT_CLOSED_PERIOD",
              details =
                Just $
                  Map.fromList
                    [ ("current", iso8601 cur),
                      ("attempted", iso8601 att)
                    ]
            }
    }
mapDomainError (CannotRewindBooksCloseDate cur att) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Books-close date may only advance",
              code = "CANNOT_REWIND_BOOKS_CLOSE",
              details =
                Just $
                  Map.fromList
                    [ ("current", iso8601 cur),
                      ("attempted", iso8601 att)
                    ]
            }
    }
mapDomainError CannotAmendToSameAccountPair =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Transfer cannot be amended to the same source and destination account",
              code = "CANNOT_AMEND_TO_SAME_ACCOUNT_PAIR",
              details = Nothing
            }
    }
mapDomainError CannotAmendToZeroAmount =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Transfer amount cannot be amended to zero",
              code = "CANNOT_AMEND_TO_ZERO_AMOUNT",
              details = Nothing
            }
    }
mapDomainError CannotAmendAcrossAccountType =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Transfer amendment cannot change an account's type (Regular vs External)",
              code = "CANNOT_AMEND_ACROSS_ACCOUNT_TYPE",
              details = Nothing
            }
    }
mapDomainError (InsufficientFundsForAmendment r) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Insufficient funds for transfer amendment",
              code = "INSUFFICIENT_FUNDS_FOR_AMENDMENT",
              details = Just $ Map.singleton "reason" r
            }
    }

-- -----------------------------------------------------------------------------
-- Convenience Functions
-- -----------------------------------------------------------------------------

-- | Throw a DomainError as an HTTP ServerError.
--
-- Combines mapDomainError with throwIO for use in AppM handlers.
--
-- Example:
-- >>> case result of
-- >>>   Left err -> throwDomainError err
-- >>>   Right val -> return val
throwDomainError :: (MonadIO m) => DomainError -> m a
throwDomainError = throwIO . mapDomainError

-- | Throw a validation error with field name and message.
--
-- Convenience function for common validation failures.
--
-- Example:
-- >>> when (T.null name) $ throwValidation "name" "must not be empty"
throwValidation :: (MonadIO m) => Text -> Text -> m a
throwValidation field msg =
  throwIO $
    err400
      { errBody =
          encode $
            ValidationErrorResponse
              { message = "Validation failed",
                fieldErrors = Map.singleton field msg
              }
      }

-- | Throw a not-found error with entity type and ID.
--
-- Convenience function for common not-found responses.
--
-- Example:
-- >>> throwNotFound "Account" (T.pack $ show accountUuid)
throwNotFound :: (MonadIO m) => Text -> Text -> m a
throwNotFound etype eid =
  throwIO $
    err404
      { errBody =
          encode $
            ErrorResponse
              { message = etype <> " not found",
                code = "NOT_FOUND",
                details = Just $ Map.singleton "entityId" eid
              }
      }

-- Note: Uses 'tshow' from RIO for Text conversion of Show-able values.
