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
    SetTransactionLabels (..),
    ChangeTransactionCategory (..),
    ChangeTransactionDescription (..),
    ChangeTransactionDate (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Core.Types (AccountId, CategoryId, ExchangeRate, ExternalTransactionId, LabelId, Money, TransactionId, TransferType, UserId)
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
    ''FailTransfer,
    ''SetTransactionLabels,
    ''ChangeTransactionCategory,
    ''ChangeTransactionDescription,
    ''ChangeTransactionDate
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
    sourceAccountId :: AccountId,
    -- | Account to which money will be credited
    targetAccountId :: AccountId,
    -- | Amount debited from source account
    sourceAmount :: Money,
    -- | Amount credited to target account
    targetAmount :: Money,
    -- | Exchange rate used (Nothing if same-currency)
    exchangeRate :: Maybe ExchangeRate,
    -- | Description of the transfer
    description :: Text,
    -- | User who initiated the transfer (for audit trail)
    initiatedBy :: UserId,
    -- | Business time of the transfer (user-supplied or 'now' at the API edge)
    at :: UTCTime,
    -- | Type of transfer (Income, Expense, Transfer)
    transferType :: TransferType,
    -- | Identifier for this transaction in an external system (e.g., Monobank)
    externalTransactionId :: Maybe ExternalTransactionId,
    -- | Labels to attach to the transfer (may be empty).
    labels :: Set LabelId
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

-- | Command to replace the label set on a completed transaction.
--
-- Business Rules:
--  - Transaction must be in the Completed state.
--  - The label ids must exist in the owning user's labels dictionary
--    (validated at the service layer, not in the pure handler).
--
-- Example:
-- >>> SetTransactionLabels txId (Set.fromList [lbl1, lbl2])
data SetTransactionLabels = SetTransactionLabels
  { -- | The transaction whose labels are being replaced.
    transactionId :: TransactionId,
    -- | The new complete label set (may be empty).
    labels :: Set LabelId
  }
  deriving (Show, Eq)

-- | Command to change the category on a completed Income/Expense transaction.
--
-- Business Rules:
--  - Transaction must be in the Completed state.
--  - Transaction's transferType must be Income or Expense; internal
--    transfers have no category and the command is rejected.
--  - The new category id must exist in the income or expense dictionary
--    (validated at the service layer, not in the pure handler).
--
-- Example:
-- >>> ChangeTransactionCategory txId newCategoryId
data ChangeTransactionCategory = ChangeTransactionCategory
  { -- | The transaction whose category is being changed.
    transactionId :: TransactionId,
    -- | The new category id.
    newCategory :: CategoryId
  }
  deriving (Show, Eq)

-- | Command to change the free-text description on a completed transaction.
--
-- Business Rules:
--  - Transaction must be in the Completed state (enforced by the pure handler).
--  - Books-closed enforcement happens at the service layer, not here.
--
-- Example:
-- >>> ChangeTransactionDescription txId "Corrected description"
data ChangeTransactionDescription = ChangeTransactionDescription
  { -- | The transaction whose description is being changed.
    transactionId :: TransactionId,
    -- | The new description text.
    newDescription :: Text
  }
  deriving (Show, Eq)

-- | Command to change the business date ('at') on a completed transaction.
--
-- Business Rules:
--  - Transaction must be in the Completed state (enforced by the pure handler).
--  - Books-closed enforcement happens at the service layer, not here.
--
-- Example:
-- >>> ChangeTransactionDate txId someUTCTime
data ChangeTransactionDate = ChangeTransactionDate
  { -- | The transaction whose business date is being changed.
    transactionId :: TransactionId,
    -- | The new business date / time.
    newAt :: UTCTime
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands (fields already unprefixed)
deriveJSON defaultOptions ''InitiateTransfer
deriveJSON defaultOptions ''CompleteTransfer
deriveJSON defaultOptions ''FailTransfer
deriveJSON defaultOptions ''SetTransactionLabels
deriveJSON defaultOptions ''ChangeTransactionCategory
deriveJSON defaultOptions ''ChangeTransactionDescription
deriveJSON defaultOptions ''ChangeTransactionDate
