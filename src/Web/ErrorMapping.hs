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
import Domain.Core.Errors
  ( DomainError (..),
    ValidationError (..),
  )
import RIO
import Servant.Server (ServerError, err400, err404, err422, errBody)
import Web.Types (ErrorResponse (..), ValidationErrorResponse (..))

-- -----------------------------------------------------------------------------
-- Core Error Mapping
-- -----------------------------------------------------------------------------

-- | Map a DomainError to an HTTP ServerError with structured JSON body.
--
-- Pattern matches on DomainError constructors for type-safe mapping:
--   - ValidationErr     -> 400 with field-level error details
--   - AccountError      -> 400 with error message
--   - TransactionError  -> 400 with error message
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
