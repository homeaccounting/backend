{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Domain.Transaction.Errors
-- Description : Error types specific to the Transaction aggregate
--
-- This module defines error types that can occur during transaction operations.
-- These errors represent business rule violations or invalid states that
-- prevent commands from being executed.
--
-- Error Types:
--   - SourceAccountNotFound: Source account does not exist
--   - TargetAccountNotFound: Target account does not exist
--   - TransferFailed: Transfer could not be completed
--   - InvalidTransferAmount: Transfer amount is invalid (zero or negative)
--   - SameSourceAndTarget: Source and target accounts are identical
--   - TransactionNotFound: Transaction does not exist
--   - TransactionAlreadyCompleted: Attempt to modify completed transaction
--   - TransactionAlreadyFailed: Attempt to modify failed transaction
--
-- These errors are used at the API layer to provide meaningful feedback
-- to clients. The command handler itself uses events (like TransferFailed)
-- to represent business rule violations within the event stream.
--
-- Usage Context:
--   - API Layer: Convert events to errors for HTTP responses
--   - Query Side: Report errors when transactions cannot be found
--   - Validation: Pre-validation before sending commands
--   - Process Manager: Handle saga failures
module Domain.Transaction.Errors
  ( -- * Transaction Error Types
    TransactionError (..),

    -- * Error Constructors
    mkSourceAccountNotFound,
    mkTargetAccountNotFound,
    mkTransferFailed,
    mkInvalidTransferAmount,
    mkSameSourceAndTarget,
    mkTransactionNotFound,
    mkTransactionAlreadyCompleted,
    mkTransactionAlreadyFailed,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, TransactionId)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Transaction Error Types
-- -----------------------------------------------------------------------------

-- | Errors specific to transaction operations.
--
-- These errors represent violations of business rules or invalid states
-- in transaction operations. They are typically used at the API layer to
-- provide meaningful error responses to clients.
--
-- Note: Within the event sourcing domain, business rule violations are
-- represented as events (e.g., TransferFailed). These error types
-- are for the query side and API responses.
data TransactionError
  = -- | Source account not found
    SourceAccountNotFound
      { -- | The transaction ID that references the missing account
        sourceAccountNotFoundTransactionId :: TransactionId,
        -- | The account ID that was not found
        sourceAccountNotFoundAccountId :: AccountId
      }
  | -- | Target account not found
    TargetAccountNotFound
      { -- | The transaction ID that references the missing account
        targetAccountNotFoundTransactionId :: TransactionId,
        -- | The account ID that was not found
        targetAccountNotFoundAccountId :: AccountId
      }
  | -- | Transfer failed with a reason
    TransferFailed
      { -- | The transaction ID that failed
        transferFailedTransactionId :: TransactionId,
        -- | The reason for the failure
        transferFailedReason :: Text
      }
  | -- | Invalid transfer amount (zero or negative)
    InvalidTransferAmount
      { -- | The transaction ID with invalid amount
        invalidTransferAmountTransactionId :: TransactionId,
        -- | The invalid amount that was provided
        invalidTransferAmountValue :: Money,
        -- | Description of why the amount is invalid
        invalidTransferAmountReason :: Text
      }
  | -- | Source and target accounts are the same
    SameSourceAndTarget
      { -- | The transaction ID with same source and target
        sameSourceAndTargetTransactionId :: TransactionId,
        -- | The account ID used for both source and target
        sameSourceAndTargetAccountId :: AccountId
      }
  | -- | Transaction not found by ID
    TransactionNotFound
      { -- | The transaction ID that was not found
        transactionNotFoundId :: TransactionId
      }
  | -- | Transaction already completed
    TransactionAlreadyCompleted
      { -- | The transaction ID that is already completed
        transactionAlreadyCompletedId :: TransactionId
      }
  | -- | Transaction already failed
    TransactionAlreadyFailed
      { -- | The transaction ID that already failed
        transactionAlreadyFailedId :: TransactionId,
        -- | The original failure reason
        transactionAlreadyFailedReason :: Text
      }
  deriving (Show, Eq, Generic)

-- JSON instances for API serialization
instance ToJSON TransactionError

instance FromJSON TransactionError

-- -----------------------------------------------------------------------------
-- Error Constructors
-- -----------------------------------------------------------------------------

-- | Create a SourceAccountNotFound error.
--
-- This error indicates that the source account for a transfer does not exist
-- in the system.
--
-- Example:
-- >>> mkSourceAccountNotFound transactionId sourceAccountId
-- SourceAccountNotFound { sourceAccountNotFoundTransactionId = transactionId
--                       , sourceAccountNotFoundAccountId = sourceAccountId
--                       }
--
-- Usage:
-- This error should be created when:
--  - An InitiateTransfer command references a non-existent source account
--  - The process manager cannot find the source account
--  - API validation discovers the source account doesn't exist
mkSourceAccountNotFound ::
  -- | Transaction ID
  TransactionId ->
  -- | Source account ID that was not found
  AccountId ->
  TransactionError
mkSourceAccountNotFound transactionId accountId =
  SourceAccountNotFound
    { sourceAccountNotFoundTransactionId = transactionId,
      sourceAccountNotFoundAccountId = accountId
    }

-- | Create a TargetAccountNotFound error.
--
-- This error indicates that the target account for a transfer does not exist
-- in the system.
--
-- Example:
-- >>> mkTargetAccountNotFound transactionId targetAccountId
-- TargetAccountNotFound { targetAccountNotFoundTransactionId = transactionId
--                       , targetAccountNotFoundAccountId = targetAccountId
--                       }
--
-- Usage:
-- This error should be created when:
--  - An InitiateTransfer command references a non-existent target account
--  - The process manager cannot find the target account
--  - API validation discovers the target account doesn't exist
mkTargetAccountNotFound ::
  -- | Transaction ID
  TransactionId ->
  -- | Target account ID that was not found
  AccountId ->
  TransactionError
mkTargetAccountNotFound transactionId accountId =
  TargetAccountNotFound
    { targetAccountNotFoundTransactionId = transactionId,
      targetAccountNotFoundAccountId = accountId
    }

-- | Create a TransferFailed error.
--
-- This error indicates that a transfer could not be completed for some reason
-- (e.g., insufficient funds, validation failure, system error).
--
-- Example:
-- >>> mkTransferFailed transactionId "Insufficient funds in source account"
-- TransferFailed { transferFailedTransactionId = transactionId
--                , transferFailedReason = "Insufficient funds in source account"
--                }
--
-- Usage:
-- This error should be created when:
--  - A debit operation fails due to insufficient funds
--  - A credit operation fails due to validation errors
--  - The process manager encounters an error during saga execution
--  - Any step in the transfer process fails
mkTransferFailed ::
  -- | Transaction ID that failed
  TransactionId ->
  -- | Reason for the failure
  Text ->
  TransactionError
mkTransferFailed transactionId reason =
  TransferFailed
    { transferFailedTransactionId = transactionId,
      transferFailedReason = reason
    }

-- | Create an InvalidTransferAmount error.
--
-- This error indicates that the transfer amount is invalid (zero, negative,
-- or otherwise not acceptable).
--
-- Example:
-- >>> mkInvalidTransferAmount transactionId (Money 0) "Transfer amount must be positive"
-- InvalidTransferAmount { invalidTransferAmountTransactionId = transactionId
--                       , invalidTransferAmountValue = Money 0
--                       , invalidTransferAmountReason = "Transfer amount must be positive"
--                       }
--
-- Usage:
-- This error should be created when:
--  - An InitiateTransfer command has zero amount
--  - An InitiateTransfer command has negative amount (shouldn't happen with Money type)
--  - API validation detects invalid amount
--  - Amount exceeds system limits (if any)
mkInvalidTransferAmount ::
  -- | Transaction ID
  TransactionId ->
  -- | The invalid amount value
  Money ->
  -- | Reason why the amount is invalid
  Text ->
  TransactionError
mkInvalidTransferAmount transactionId amount reason =
  InvalidTransferAmount
    { invalidTransferAmountTransactionId = transactionId,
      invalidTransferAmountValue = amount,
      invalidTransferAmountReason = reason
    }

-- | Create a SameSourceAndTarget error.
--
-- This error indicates that the source and target accounts are the same,
-- which is not allowed for transfers.
--
-- Example:
-- >>> mkSameSourceAndTarget transactionId accountId
-- SameSourceAndTarget { sameSourceAndTargetTransactionId = transactionId
--                     , sameSourceAndTargetAccountId = accountId
--                     }
--
-- Usage:
-- This error should be created when:
--  - An InitiateTransfer command has the same account for source and target
--  - API validation detects identical source and target
--  - Pre-validation before sending command
mkSameSourceAndTarget ::
  -- | Transaction ID
  TransactionId ->
  -- | Account ID used for both source and target
  AccountId ->
  TransactionError
mkSameSourceAndTarget transactionId accountId =
  SameSourceAndTarget
    { sameSourceAndTargetTransactionId = transactionId,
      sameSourceAndTargetAccountId = accountId
    }

-- | Create a TransactionNotFound error.
--
-- This error indicates that a transaction with the given ID does not exist
-- in the system.
--
-- Example:
-- >>> mkTransactionNotFound transactionId
-- TransactionNotFound { transactionNotFoundId = transactionId }
--
-- Usage:
-- This error should be created when:
--  - A query for a transaction returns no results
--  - A command targets a non-existent transaction
--  - An API request specifies an invalid transaction ID
mkTransactionNotFound ::
  -- | Transaction ID that was not found
  TransactionId ->
  TransactionError
mkTransactionNotFound transactionId =
  TransactionNotFound
    { transactionNotFoundId = transactionId
    }

-- | Create a TransactionAlreadyCompleted error.
--
-- This error indicates that an attempt was made to modify a transaction
-- that has already been completed.
--
-- Example:
-- >>> mkTransactionAlreadyCompleted transactionId
-- TransactionAlreadyCompleted { transactionAlreadyCompletedId = transactionId }
--
-- Usage:
-- This error should be created when:
--  - A CompleteTransfer command targets an already completed transaction
--  - An API request attempts to modify a completed transaction
--  - The process manager tries to complete a completed transaction
mkTransactionAlreadyCompleted ::
  -- | Transaction ID that is already completed
  TransactionId ->
  TransactionError
mkTransactionAlreadyCompleted transactionId =
  TransactionAlreadyCompleted
    { transactionAlreadyCompletedId = transactionId
    }

-- | Create a TransactionAlreadyFailed error.
--
-- This error indicates that an attempt was made to modify a transaction
-- that has already failed.
--
-- Example:
-- >>> mkTransactionAlreadyFailed transactionId "Insufficient funds"
-- TransactionAlreadyFailed { transactionAlreadyFailedId = transactionId
--                          , transactionAlreadyFailedReason = "Insufficient funds"
--                          }
--
-- Usage:
-- This error should be created when:
--  - A CompleteTransfer command targets an already failed transaction
--  - A FailTransfer command targets an already failed transaction
--  - An API request attempts to modify a failed transaction
--  - The process manager tries to modify a failed transaction
mkTransactionAlreadyFailed ::
  -- | Transaction ID that already failed
  TransactionId ->
  -- | The original failure reason
  Text ->
  TransactionError
mkTransactionAlreadyFailed transactionId reason =
  TransactionAlreadyFailed
    { transactionAlreadyFailedId = transactionId,
      transactionAlreadyFailedReason = reason
    }
