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
--   - InitiateTransaction: Request to start a money transfer between accounts
--   - CompleteTransactionPosting: Internal command to mark transfer as completed
--   - FailTransactionPosting: Internal command to mark transfer as failed
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
    InitiateTransaction (..),
    CompleteTransactionPosting (..),
    FailTransactionPosting (..),
    SetTransactionLabels (..),
    SetTransactionContact (..),
    SetTransactionAllocations (..),
    ChangeTransactionDescription (..),
    ChangeTransactionDate (..),
    AmendTransaction (..),
    CompleteTransactionAmendment (..),
    FailTransactionAmendment (..),
    CancelTransaction (..),
    CompleteTransactionCancellation (..),
    AddTransactionRelation (..),
    RemoveTransactionRelation (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Set (Set)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Core.Types (AccountId, Allocations, ContactId, ExchangeRate, ImportInfo, LabelId, Money, RelationKind, RelationSpec, TransactionId, TransactionType, UserId)
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
  [ ''InitiateTransaction,
    ''CompleteTransactionPosting,
    ''FailTransactionPosting,
    ''SetTransactionLabels,
    ''SetTransactionContact,
    ''SetTransactionAllocations,
    ''ChangeTransactionDescription,
    ''ChangeTransactionDate,
    ''AmendTransaction,
    ''CompleteTransactionAmendment,
    ''FailTransactionAmendment,
    ''CancelTransaction,
    ''CompleteTransactionCancellation,
    ''AddTransactionRelation,
    ''RemoveTransactionRelation
  ]

-- -----------------------------------------------------------------------------
-- Transaction Commands
-- -----------------------------------------------------------------------------

-- | Command to initiate a money transfer between accounts.
--
-- Represents the intent to transfer money from one account to another.
-- This is the primary user-facing command that starts the transfer saga.
--
-- If accepted, produces a TransactionPostingInitiated event, which triggers the
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
-- >>> InitiateTransaction sourceId targetId (Money 500.0) "Rent payment" userId
data InitiateTransaction = InitiateTransaction
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
    transactionType :: TransactionType,
    -- | Import provenance when this transaction originates from a bank import
    -- (external id + optional MCC). 'Nothing' for manual entries.
    importInfo :: Maybe ImportInfo,
    -- | Labels to attach to the transfer (may be empty).
    labels :: Set LabelId,
    -- | Optional contact associated with this transfer (e.g., a payee/payer).
    contactId :: Maybe ContactId,
    -- | Optional at-creation typed relationship to a pre-existing transaction
    -- (e.g., a 'Refund' edge to the refunded expense). When 'Just', the handler
    -- emits a 'TransactionRelationAdded' event alongside the posting event; the
    -- owning ("from") endpoint is the freshly-created transaction.
    relation :: Maybe RelationSpec
  }
  deriving (Show, Eq)

-- | Command to mark a transfer as completed.
--
-- This is typically an internal command used by the process manager
-- after both the debit and credit operations have succeeded.
--
-- If accepted, produces a TransactionPostingCompleted event.
--
-- Business Rules:
--  - Can only be issued for transfers in progress
--  - Transfer must not already be completed or failed
--
-- Example:
-- >>> CompleteTransactionPosting
data CompleteTransactionPosting = CompleteTransactionPosting
  deriving (Show, Eq)

-- | Command to mark a transfer as failed.
--
-- This is typically an internal command used by the process manager
-- when the transfer cannot be completed (e.g., insufficient funds,
-- account not found, or other validation failures).
--
-- If accepted, produces a TransactionPostingFailed event.
--
-- Business Rules:
--  - Can only be issued for transfers in progress
--  - Transfer must not already be completed or failed
--  - Reason should clearly describe why the transfer failed
--
-- Example:
-- >>> FailTransactionPosting "Insufficient funds in source account"
newtype FailTransactionPosting = FailTransactionPosting
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

-- | Command to set (or clear) the contact associated with a completed transaction.
--
-- Business Rules:
--  - Transaction must be in the Completed state.
--  - The contact id must exist in the owning user's contacts dictionary
--    (validated at the service layer, not in the pure handler).
--
-- Example:
-- >>> SetTransactionContact txId (Just contact1)
data SetTransactionContact = SetTransactionContact
  { -- | The transaction whose contact is being replaced.
    transactionId :: TransactionId,
    -- | The new contact ('Nothing' clears the contact).
    contactId :: Maybe ContactId
  }
  deriving (Show, Eq)

-- | Command to set the allocation list on a completed Income/Expense transaction.
--
-- Replaces the old single-category 'ChangeTransactionCategory': a fresh
-- allocation list is supplied atomically. Single-category edits are the
-- degenerate length-1 case. The transaction's kind is structurally
-- preserved by this command's shape — it carries only allocations, not
-- a full 'TransactionType', so there is no incoming kind to conflict with
-- the existing one.
--
-- Business Rules (enforced by the pure handler):
--  * Transaction must be in the Completed state
--    ('CannotEditUncompletedTransaction').
--  * Existing 'transactionType' must be Income or Expense
--    ('CannotSetAllocationsOnUncategorisedTransaction').
--  * Sum of @newAllocations@ must equal the existing categorised amount
--    ('AllocationsDoNotSumToTotal').
--  * Currency consistency: each allocation's currency equals the
--    existing categorised currency ('AllocationCurrencyMismatch').
--  * Each amount > 0 ('AllocationAmountNotPositive').
--  * Service layer validates each 'CategoryId' exists in the user's
--    dictionary for the matching kind.
--
-- Example:
-- >>> SetTransactionAllocations txId (allocA :| [allocB])
data SetTransactionAllocations = SetTransactionAllocations
  { -- | The transaction whose allocations are being replaced.
    transactionId :: TransactionId,
    -- | The new allocation list. Sum must equal the existing categorised
    -- total; each currency must match the existing categorised currency;
    -- each amount must be > 0.
    newAllocations :: Allocations
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

-- | User-facing command to amend an existing completed transaction.
--
-- Triggers the amendment saga. The service layer computes the diff
-- against current canonical state and short-circuits if the payload
-- is identical (no events emitted, saga not started).
--
-- Cross-kind amendment is supported: the new kind (Income / Expense /
-- Transfer) is structurally derived from the (newSource, newTarget)
-- 'AccountType' pair at the service layer via 'deriveTransactionKind'.
-- 'Adjustment' is out of scope (single-account; use
-- 'AdjustAccountBalance' or delete-and-repost).
--
-- @newAllocations@ semantics:
--
--   * 'Nothing', kind = Income\/Expense (whether unchanged or newly
--     derived): caller must supply allocations; rejected with
--     'AllocationsRequiredForCategorisedKind'.
--   * 'Nothing', kind = Transfer: pure 'Transfer'.
--   * 'Just allocs', kind = Income\/Expense: 'Income allocs' or
--     'Expense allocs'. Each 'categoryId' is validated against the
--     matching dictionary.
--   * 'Just _', kind = Transfer: rejected with
--     'AllocationsNotAllowedForTransferKind'.
--
-- @newTransactionType@ is the **service-internal** field carrying the
-- synthesised full 'TransactionType' (kind ⊕ allocations). The web
-- handler initialises it to 'Transfer' as a placeholder; the service
-- layer always overwrites it via 'synthesiseAmendmentTransactionType'
-- before calling 'runTransactionCmd'. The handler trusts this field
-- as the canonical post-amendment shape. Commands are not persisted
-- by Eventium (only events are), so the placeholder never reaches
-- durable storage.
--
-- Business Rules (handler-enforced):
--   - Transaction must be in the 'Completed' state.
--   - @newSourceAccountId@ /= @newTargetAccountId@.
--   - @newSourceAmount@ and @newTargetAmount@ are both non-zero.
--   - 'newTransactionType' must not be 'Adjustment'
--     ('CannotAmendToAdjustmentKind').
--   - For Income, sum of allocations equals @newTargetAmount@ and
--     all allocation currencies match @newTargetAmount@'s currency.
--   - For Expense, same against @newSourceAmount@.
data AmendTransaction = AmendTransaction
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    -- | Optional new allocation list. See module-level documentation
    -- on the truth table.
    newAllocations :: Maybe Allocations,
    -- | Service-internal: full new 'TransactionType' (kind ⊕
    -- allocations). Web handler initialises to 'Transfer'; the
    -- service layer always overwrites before dispatch.
    newTransactionType :: TransactionType,
    -- | New contact for the transaction ('Nothing' to clear). Full
    -- replacement, mirroring 'newTransactionType' — not a delta.
    contactId :: Maybe ContactId,
    by :: UserId
  }
  deriving (Show, Eq)

-- | Saga-internal command to mark a transfer amendment as completed.
--
-- Issued by the @TransactionAmendmentManager@ process manager once all leg
-- events have landed. Accepted iff a @TransactionAmendmentInitiated@ is in
-- progress on the aggregate (tracked via @amendmentInProgress@). Carries the
-- full new 'TransactionType' so the resulting 'TransactionAmendmentCompleted'
-- event is self-contained for projection / read-model rebuilds.
data CompleteTransactionAmendment = CompleteTransactionAmendment
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
    -- | New contact for the transaction ('Nothing' to clear). Echoed
    -- from 'TransactionAmendmentInitiated' by the saga.
    contactId :: Maybe ContactId,
    -- | User who amended the transfer.
    by :: UserId
  }
  deriving (Show, Eq)

-- | Saga-internal command to mark a transfer amendment as failed.
--
-- Issued by the @TransactionAmendmentManager@ when the new-source debit is
-- rejected. Accepted iff a @TransactionAmendmentInitiated@ is in progress.
-- The original transfer is left intact.
--
-- Example:
-- >>> FailTransactionAmendment "Insufficient funds in new source account"
newtype FailTransactionAmendment = FailTransactionAmendment
  { -- | Description of why the amendment failed.
    reason :: Text
  }
  deriving (Show, Eq)

-- | User-facing command to cancel a completed transaction.
--
-- Triggers the @TransactionCancellationManager@ saga, which issues reversal
-- commands on both affected accounts and then emits
-- 'CompleteTransactionCancellation' on the transaction stream.
--
-- Business Rules (enforced by the pure handler):
--  - Transaction must be in the 'Completed' state.
--  - No amendment saga may be in progress (@amendmentInProgress = False@).
--  - No cancellation saga may already be in progress (@cancellationInProgress = False@).
--
-- Example:
-- >>> CancelTransaction txId userId
data CancelTransaction = CancelTransaction
  { -- | The transaction being cancelled.
    transactionId :: TransactionId,
    -- | User who initiated the cancellation (for audit trail).
    by :: UserId
  }
  deriving (Show, Eq)

-- | Saga-internal command to mark a transaction cancellation as completed.
--
-- Issued by the @TransactionCancellationManager@ once both reversal events
-- have landed. Accepted iff @cancellationInProgress = True@ on the aggregate.
-- The @by@ field is an audit echo — the saga carries it from the
-- initiating 'CancelTransaction' so the resulting event is self-contained
-- for read-model replay.
--
-- Example:
-- >>> CompleteTransactionCancellation txId userId
data CompleteTransactionCancellation = CompleteTransactionCancellation
  { -- | The transaction being cancelled.
    transactionId :: TransactionId,
    -- | User who initiated the cancellation (echoed from the saga state).
    by :: UserId
  }
  deriving (Show, Eq)

-- | Post-hoc command to record a typed relationship on an already-existing
-- (Completed) transaction. Used by the merge/split domain operations to write
-- 'Merge'/'Split' lineage; not exposed as a public "create arbitrary edge"
-- endpoint. At-creation edges (Refund) are recorded via 'InitiateTransaction.relation'
-- instead. 'transactionId' is the owning ("from") aggregate the command routes to.
data AddTransactionRelation = AddTransactionRelation
  { transactionId :: TransactionId,
    relatedTransactionId :: TransactionId,
    relationKind :: RelationKind
  }
  deriving (Show, Eq)

-- | Post-hoc command to remove a previously-recorded typed relationship from an
-- already-existing (Completed) transaction. The mirror of 'AddTransactionRelation';
-- 'transactionId' is the owning ("from") aggregate the command routes to.
-- Direction resolution + kind restriction (lineage edges are not removable) is
-- enforced at the service layer, not in the pure handler.
data RemoveTransactionRelation = RemoveTransactionRelation
  { transactionId :: TransactionId,
    relatedTransactionId :: TransactionId,
    relationKind :: RelationKind
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands (fields already unprefixed)
deriveJSON defaultOptions ''InitiateTransaction
deriveJSON defaultOptions ''CompleteTransactionPosting
deriveJSON defaultOptions ''FailTransactionPosting
deriveJSON defaultOptions ''SetTransactionLabels
deriveJSON defaultOptions ''SetTransactionContact
deriveJSON defaultOptions ''SetTransactionAllocations
deriveJSON defaultOptions ''ChangeTransactionDescription
deriveJSON defaultOptions ''ChangeTransactionDate
deriveJSON defaultOptions ''AmendTransaction
deriveJSON defaultOptions ''CompleteTransactionAmendment
deriveJSON defaultOptions ''FailTransactionAmendment
deriveJSON defaultOptions ''CancelTransaction
deriveJSON defaultOptions ''CompleteTransactionCancellation
deriveJSON defaultOptions ''AddTransactionRelation
deriveJSON defaultOptions ''RemoveTransactionRelation
