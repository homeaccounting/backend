{-# LANGUAGE OverloadedStrings #-}
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
--   - TransactionLabelsSet: The label set on a completed transaction was replaced
--   - TransactionCategoryChanged: The category on a completed Income/Expense transaction was changed
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
    TransactionLabelsSet (..),
    TransactionCategoryChanged (..),
  )
where

import Data.Aeson (FromJSON (..), withObject, (.!=), (.:), (.:?))
import Data.Aeson.TH (defaultOptions, deriveJSON, deriveToJSON)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Domain.Core.Types (AccountId, CategoryId, ExchangeRate, ExternalTransactionId, LabelId, Money, TransactionId, TransferType, UserId)
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
    ''TransferFailed,
    ''TransactionLabelsSet,
    ''TransactionCategoryChanged
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
    externalTransactionId :: Maybe ExternalTransactionId,
    -- | Labels attached to this transfer (may be empty).
    labels :: Set LabelId
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

-- | Event emitted when the label set of a completed transaction is replaced.
--
-- Labels are replace-set semantics — the event carries the new, complete
-- label set as it should be after applying the event. The audit trail is
-- the sequence of events, each of which is a full snapshot of the labels
-- at that point in time.
data TransactionLabelsSet = TransactionLabelsSet
  { -- | The transaction whose labels changed. Carried in the payload for
    -- symmetry with TransferFailed's reason; the stream key (the aggregate id)
    -- is authoritative.
    transactionId :: TransactionId,
    -- | The new complete label set (may be empty).
    labels :: Set LabelId
  }
  deriving (Show, Eq)

-- | Event emitted when the category on a completed Income/Expense transaction
-- is changed.
--
-- Only applicable to transactions whose transferType is Income or Expense;
-- internal transfers have no category and the command handler rejects any
-- attempt to emit this event against them.
data TransactionCategoryChanged = TransactionCategoryChanged
  { -- | The transaction whose category changed.
    transactionId :: TransactionId,
    -- | The new category id.
    newCategory :: CategoryId
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all events (fields already unprefixed).
-- TransferInitiated uses a hand-written FromJSON so that previously
-- serialised events without a "labels" field still deserialise, defaulting
-- to an empty set.
deriveToJSON defaultOptions ''TransferInitiated

instance FromJSON TransferInitiated where
  parseJSON = withObject "TransferInitiated" $ \o ->
    TransferInitiated
      <$> o .: "sourceAccountId"
      <*> o .: "targetAccountId"
      <*> o .: "sourceAmount"
      <*> o .: "targetAmount"
      <*> o .:? "exchangeRate" .!= Nothing
      <*> o .: "description"
      <*> o .: "by"
      <*> o .: "transferType"
      <*> o .:? "externalTransactionId" .!= Nothing
      <*> (fromMaybe Set.empty <$> o .:? "labels")

deriveJSON defaultOptions ''TransferCompleted
deriveJSON defaultOptions ''TransferFailed
deriveJSON defaultOptions ''TransactionLabelsSet
deriveJSON defaultOptions ''TransactionCategoryChanged
