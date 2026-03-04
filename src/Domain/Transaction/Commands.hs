{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Transaction.Commands
-- Description : Commands for the Transaction aggregate
--
-- This module defines all commands that can be issued to the Transaction aggregate.
-- Commands represent intentions to perform actions that may succeed or fail based
-- on the current aggregate state and business rules.
--
-- Key Commands:
--   - InitiateTransfer: Request to start a money transfer between accounts
--   - CompleteTransfer: Internal command to mark transfer as completed
--   - FailTransfer: Internal command to mark transfer as failed
--
-- Commands are validated by the command handler, which either:
--   - Accepts the command and produces events representing state changes
--   - Rejects the command (e.g., invalid accounts or amount)
--
-- All commands use Template Haskell for integration with the eventium library
-- and include JSON serialization instances for API integration.
module Domain.Transaction.Commands
  ( -- * Command List
    transactionCommands,

    -- * Transaction Commands
    InitiateTransfer (..),
    CompleteTransfer (..),
    FailTransfer (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, UserId)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Command List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all transaction command type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the TransactionCommand sum type and related serialization code.
transactionCommands :: [Name]
transactionCommands =
  [ ''InitiateTransfer,
    ''CompleteTransfer,
    ''FailTransfer
  ]

-- -----------------------------------------------------------------------------
-- Transaction Commands
-- -----------------------------------------------------------------------------

-- | Command to initiate a money transfer between accounts.
--
-- Represents the intent to transfer money from one account to another.
-- This is the primary user-facing command that starts the transfer saga.
--
-- If accepted, produces a TransferInitiated event, which triggers the
-- process manager to orchestrate the balance updates on both accounts.
--
-- Business Rules:
--   - Source and target accounts must be different
--   - Amount must be positive (enforced by Money type)
--   - User must have Editor+ role on both accounts (validated by authorization service)
--   - Source account must have sufficient funds unless it's an External account
--   - Both accounts must exist (validated during execution)
--
-- Transfer Types:
--   - External -> Regular: Income (money coming in)
--   - Regular -> External: Expense (money going out)
--   - Regular -> Regular: Internal transfer
--
-- Example:
-- >>> InitiateTransfer sourceId targetId (Money 500.0) "Rent payment" userId
data InitiateTransfer = InitiateTransfer
  { -- | Account from which money will be debited
    fromAccountId :: AccountId,
    -- | Account to which money will be credited
    toAccountId :: AccountId,
    -- | Amount of money to transfer
    amount :: Money,
    -- | Reason or description for the transfer
    reason :: Text,
    -- | User who initiated the transfer (for audit trail)
    initiatedBy :: UserId
  }
  deriving (Show, Eq)

-- | Command to mark a transfer as completed.
--
-- This is typically an internal command used by the process manager
-- after both the debit and credit operations have succeeded.
--
-- If accepted, produces a TransferCompleted event.
--
-- Business Rules:
--  - Can only be issued for transfers in progress
--  - Transfer must not already be completed or failed
--
-- Example:
-- >>> CompleteTransfer
data CompleteTransfer = CompleteTransfer
  deriving (Show, Eq)

-- | Command to mark a transfer as failed.
--
-- This is typically an internal command used by the process manager
-- when the transfer cannot be completed (e.g., insufficient funds,
-- account not found, or other validation failures).
--
-- If accepted, produces a TransferFailed event.
--
-- Business Rules:
--  - Can only be issued for transfers in progress
--  - Transfer must not already be completed or failed
--  - Reason should clearly describe why the transfer failed
--
-- Example:
-- >>> FailTransfer "Insufficient funds in source account"
newtype FailTransfer = FailTransfer
  { -- | Description of why the transfer failed
    reason :: Text
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands (fields already unprefixed)
deriveJSON defaultOptions ''InitiateTransfer
deriveJSON defaultOptions ''CompleteTransfer
deriveJSON defaultOptions ''FailTransfer
