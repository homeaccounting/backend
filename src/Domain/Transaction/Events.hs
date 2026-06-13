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
--   - TransactionPostingInitiated: A money transfer between accounts was started
--   - TransactionPostingCompleted: A money transfer completed successfully
--   - TransactionPostingFailed: A money transfer failed (e.g., insufficient funds)
--   - TransactionLabelsSet: The label set on a completed transaction was replaced
--   - TransactionAllocationsChanged: The allocation list on a completed Income/Expense transaction was replaced
--   - TransactionDescriptionChanged: The free-text description on a completed transaction was edited
--   - TransactionDateChanged: The business date on a completed transaction was edited
--
-- All events use Template Haskell for integration with the eventium library
-- and include JSON serialization instances.
module Domain.Transaction.Events
  ( -- * Event List
    transactionEvents,

    -- * Transaction Events
    TransactionPostingInitiated (..),
    TransactionPostingCompleted (..),
    TransactionPostingFailed (..),
    TransactionLabelsSet (..),
    TransactionAllocationsChanged (..),
    TransactionDescriptionChanged (..),
    TransactionDateChanged (..),
    TransactionAmendmentInitiated (..),
    TransactionAmendmentCompleted (..),
    TransactionAmendmentFailed (..),
    TransactionCancellationInitiated (..),
    TransactionCancellationCompleted (..),
  )
where

import Data.Aeson (FromJSON (..), withObject, (.!=), (.:), (.:?))
import Data.Aeson.TH (defaultOptions, deriveJSON, deriveToJSON)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Core.Types (AccountId, Allocations, ExchangeRate, ExternalTransactionId, LabelId, Money, TransactionId, TransactionType, UserId)
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
  [ ''TransactionPostingInitiated,
    ''TransactionPostingCompleted,
    ''TransactionPostingFailed,
    ''TransactionLabelsSet,
    ''TransactionAllocationsChanged,
    ''TransactionDescriptionChanged,
    ''TransactionDateChanged,
    ''TransactionAmendmentInitiated,
    ''TransactionAmendmentCompleted,
    ''TransactionAmendmentFailed,
    ''TransactionCancellationInitiated,
    ''TransactionCancellationCompleted
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
-- >>> TransactionPostingInitiated sourceId targetId (Money 500.0) "Rent payment" userId
data TransactionPostingInitiated = TransactionPostingInitiated
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
    -- | Business time of the transfer (user-supplied or 'now' at initiation)
    at :: UTCTime,
    -- | Type of transfer (Income, Expense, Transfer)
    transactionType :: TransactionType,
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
-- >>> TransactionPostingCompleted
data TransactionPostingCompleted = TransactionPostingCompleted
  deriving (Show, Eq)

-- | Event emitted when a money transfer fails.
--
-- Contains the reason for the failure to aid in error handling
-- and compensation logic.
--
-- Example:
-- >>> TransactionPostingFailed "Insufficient funds in source account"
newtype TransactionPostingFailed = TransactionPostingFailed
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
    -- symmetry with TransactionPostingFailed's reason; the stream key (the aggregate id)
    -- is authoritative.
    transactionId :: TransactionId,
    -- | The new complete label set (may be empty).
    labels :: Set LabelId
  }
  deriving (Show, Eq)

-- | Event emitted when the allocation list on a completed Income/Expense
-- transaction is replaced.
--
-- Only applicable to transactions whose transactionType is Income or Expense;
-- internal transfers have no allocations and the command handler rejects any
-- attempt to emit this event against them. The event payload carries only
-- the new allocations — the surrounding kind (Income / Expense) cannot
-- change on this event, so the projection rebuilds the full 'TransactionType'
-- from existing state via 'replaceAllocations'.
data TransactionAllocationsChanged = TransactionAllocationsChanged
  { -- | The transaction whose allocations changed.
    transactionId :: TransactionId,
    -- | The new allocation list (non-empty). The kind (Income / Expense)
    -- is preserved from the existing transaction; only the breakdown
    -- changes here.
    newAllocations :: Allocations
  }
  deriving (Show, Eq)

-- | Event emitted when the free-text description of a completed transaction
-- is changed.
--
-- The event carries the full new description; the audit trail is the sequence
-- of these events, each a complete snapshot of the description at that point
-- in time.
data TransactionDescriptionChanged = TransactionDescriptionChanged
  { -- | The transaction whose description changed.
    transactionId :: TransactionId,
    -- | The new description text.
    newDescription :: Text
  }
  deriving (Show, Eq)

-- | Event emitted when the business date ('at') of a completed transaction
-- is changed.
--
-- The event carries the full new timestamp; the audit trail is the sequence
-- of these events, each a complete snapshot of the date at that point in time.
data TransactionDateChanged = TransactionDateChanged
  { -- | The transaction whose date changed.
    transactionId :: TransactionId,
    -- | The new business date / time.
    newAt :: UTCTime
  }
  deriving (Show, Eq)

-- | Saga-trigger event: the user has submitted an 'AmendTransaction'
-- command and the domain handler accepted it. The process manager
-- reacts by computing the minimum leg diff between the snapshotted
-- old state and the new payload, then issuing the corresponding leg
-- commands.
--
-- Carries the synthesised 'newTransactionType' (kind ⊕ allocations)
-- so the saga can echo it onto 'CompleteTransactionAmendment' at
-- finalize without re-deriving from state.
data TransactionAmendmentInitiated = TransactionAmendmentInitiated
  { -- | The transaction being amended.
    transactionId :: TransactionId,
    -- | New source account for the transfer.
    newSourceAccountId :: AccountId,
    -- | New target account for the transfer.
    newTargetAccountId :: AccountId,
    -- | New amount to debit from source account.
    newSourceAmount :: Money,
    -- | New amount to credit to target account.
    newTargetAmount :: Money,
    -- | New exchange rate (Nothing if same-currency).
    newExchangeRate :: Maybe ExchangeRate,
    -- | Synthesised full new 'TransactionType' (kind ⊕ allocations).
    newTransactionType :: TransactionType,
    -- | User who amended the transfer.
    by :: UserId
  }
  deriving (Show, Eq)

-- | Saga-completion event: all leg events have landed. The TX
-- aggregate's canonical posting facts and 'transactionType' move to
-- the new values; the projection bumps 'amendmentCount'. Replayed
-- from saga state so the event is self-contained for read-model
-- rebuilds.
--
-- 'newTransactionType' is the full kind ⊕ allocations value the
-- service layer synthesised and threaded through the saga. The
-- projection replaces the existing 'transactionType' with this value
-- verbatim — no rescale, no kind-merge.
data TransactionAmendmentCompleted = TransactionAmendmentCompleted
  { -- | The transaction being amended.
    transactionId :: TransactionId,
    -- | New source account for the transfer.
    newSourceAccountId :: AccountId,
    -- | New target account for the transfer.
    newTargetAccountId :: AccountId,
    -- | New amount to debit from source account.
    newSourceAmount :: Money,
    -- | New amount to credit to target account.
    newTargetAmount :: Money,
    -- | New exchange rate (Nothing if same-currency).
    newExchangeRate :: Maybe ExchangeRate,
    -- | Full new 'TransactionType' synthesised by the service layer.
    newTransactionType :: TransactionType,
    -- | User who amended the transfer.
    by :: UserId
  }
  deriving (Show, Eq)

-- | Saga-failure event: the only fallible saga step (the new-source debit)
-- was rejected. No leg events were written; the original transfer is intact.
newtype TransactionAmendmentFailed = TransactionAmendmentFailed
  { -- | Description of why the amendment failed.
    reason :: Text
  }
  deriving (Show, Eq)

-- | Saga-trigger event: the user has submitted a 'CancelTransaction'
-- command and the domain handler accepted it. The
-- 'Application.ProcessManagers.TransactionCancellationManager' process
-- manager reacts to this event by issuing the two reversal commands on
-- the source and target accounts.
--
-- Carries the identity of the user who requested the cancellation for
-- the audit trail; no posting facts on the payload — those are
-- snapshotted in the saga state from the prior 'TransactionPostingInitiated' /
-- 'TransactionAmendmentCompleted' events.
data TransactionCancellationInitiated = TransactionCancellationInitiated
  { -- | The transaction being cancelled.
    transactionId :: TransactionId,
    -- | User who requested the cancellation.
    by :: UserId
  }
  deriving (Show, Eq)

-- | Saga-completion event: all reversal leg events have landed. The TX
-- aggregate's status transitions to 'Cancelled' and the transient
-- @cancellationInProgress@ flag is cleared. Replayed from saga state so
-- the event is self-contained for read-model rebuilds.
data TransactionCancellationCompleted = TransactionCancellationCompleted
  { -- | The transaction that was cancelled.
    transactionId :: TransactionId,
    -- | User who requested the cancellation (preserved for audit trail).
    by :: UserId
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all events (fields already unprefixed).
-- TransactionPostingInitiated uses a hand-written FromJSON so that previously
-- serialised events without a "labels" field still deserialise, defaulting
-- to an empty set.
deriveToJSON defaultOptions ''TransactionPostingInitiated

instance FromJSON TransactionPostingInitiated where
  parseJSON = withObject "TransactionPostingInitiated" $ \o ->
    TransactionPostingInitiated
      <$> o .: "sourceAccountId"
      <*> o .: "targetAccountId"
      <*> o .: "sourceAmount"
      <*> o .: "targetAmount"
      <*> o .:? "exchangeRate" .!= Nothing
      <*> o .: "description"
      <*> o .: "by"
      <*> o .: "at"
      <*> o .: "transactionType"
      <*> o .:? "externalTransactionId" .!= Nothing
      <*> (fromMaybe Set.empty <$> o .:? "labels")

deriveJSON defaultOptions ''TransactionPostingCompleted
deriveJSON defaultOptions ''TransactionPostingFailed
deriveJSON defaultOptions ''TransactionLabelsSet
deriveJSON defaultOptions ''TransactionAllocationsChanged
deriveJSON defaultOptions ''TransactionDescriptionChanged
deriveJSON defaultOptions ''TransactionDateChanged
deriveJSON defaultOptions ''TransactionAmendmentInitiated
deriveJSON defaultOptions ''TransactionAmendmentCompleted
deriveJSON defaultOptions ''TransactionAmendmentFailed
deriveJSON defaultOptions ''TransactionCancellationInitiated
deriveJSON defaultOptions ''TransactionCancellationCompleted
