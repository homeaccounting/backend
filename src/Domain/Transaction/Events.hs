{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Transaction.Events
-- Description : Events for the Transaction aggregate
--
-- This module defines all events that can occur in the Transaction aggregate's lifecycle.
-- Events represent immutable facts about state changes that have already occurred.
--
-- Key Events:
--   - TransferInitiated: A money transfer between accounts was started
--   - TransferCompleted: A money transfer completed successfully
--   - TransferFailed: A money transfer failed (e.g., insufficient funds)
--
-- All events use Template Haskell for integration with the eventium library
-- and include JSON serialization instances.
module Domain.Transaction.Events
  ( -- * Event List
    transactionEvents,

    -- * Transaction Events
    TransferInitiated (..),
    TransferCompleted (..),
    TransferFailed (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Text (Text)
import Domain.Core.Types (AccountId, ExchangeRate, ExternalTransactionId, Money, TransferType, UserId)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Event List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all transaction event type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the TransactionEvent sum type and related serialization code.
transactionEvents :: [Name]
transactionEvents =
  [ ''TransferInitiated,
    ''TransferCompleted,
    ''TransferFailed
  ]

-- -----------------------------------------------------------------------------
-- Transaction Events
-- -----------------------------------------------------------------------------

-- | Event emitted when a money transfer is initiated.
--
-- Contains all the information needed to execute the transfer,
-- including source and target accounts, amount, and who initiated it.
--
-- Transfer Types:
--   - External -> Regular: Income (money coming from outside world)
--   - Regular -> External: Expense (money going to outside world)
--   - Regular -> Regular: Internal transfer between accounts
--
-- Example:
-- >>> TransferInitiated sourceId targetId (Money 500.0) "Rent payment" userId
data TransferInitiated = TransferInitiated
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
    by :: UserId,
    -- | Type of transfer (Income, Expense, Transfer)
    transferType :: TransferType,
    -- | Identifier for this transaction in an external system (e.g., Monobank)
    externalTransactionId :: Maybe ExternalTransactionId
  }
  deriving (Show, Eq)

-- | Event emitted when a money transfer completes successfully.
--
-- Records that the transfer has been fully processed and both
-- the debit and credit operations have succeeded.
--
-- Example:
-- >>> TransferCompleted
data TransferCompleted = TransferCompleted
  deriving (Show, Eq)

-- | Event emitted when a money transfer fails.
--
-- Contains the reason for the failure to aid in error handling
-- and compensation logic.
--
-- Example:
-- >>> TransferFailed "Insufficient funds in source account"
newtype TransferFailed = TransferFailed
  { -- | Description of why the transfer failed
    reason :: Text
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all events (fields already unprefixed)
deriveJSON defaultOptions ''TransferInitiated
deriveJSON defaultOptions ''TransferCompleted
deriveJSON defaultOptions ''TransferFailed
