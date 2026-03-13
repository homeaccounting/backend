{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Account.Events
-- Description : Events for the Account aggregate
--
-- This module defines all events that can occur in the Account aggregate's lifecycle.
-- Events represent immutable facts about state changes that have already occurred.
--
-- Key Events:
--   - AccountCreated: A new account was created with owner and type
--   - AccountAccessGranted: Access was granted to a user
--   - AccountAccessRevoked: Access was revoked from a user
--   - AccountDebited: Account was debited (balance decreased) as part of a transfer
--   - AccountCredited: Account was credited (balance increased) as part of a transfer
--
-- Balance-changing events (AccountDebited, AccountCredited) are internal events
-- produced by DebitAccount/CreditAccount commands issued by the TransferManager
-- process manager. They are not triggered directly by user actions.
-- Each carries a TransactionId for saga correlation.
--
-- Note: Insufficient funds on Regular accounts is handled via command handler
-- error ('Left InsufficientFunds') rather than a rejection event.
--
-- All events use Template Haskell for integration with the eventium library
-- and include JSON serialization instances.
module Domain.Account.Events
  ( -- * Event List
    accountEvents,

    -- * Account Events
    AccountCreated (..),
    AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountDebited (..),
    AccountCredited (..),
    OverdraftLimitSet (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Text (Text)
import Domain.Core.Types (AccountRole, AccountType, Money, TransactionId, UserId)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Event List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all account event type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the AccountEvent sum type and related serialization code.
accountEvents :: [Name]
accountEvents =
  [ ''AccountCreated,
    ''AccountAccessGranted,
    ''AccountAccessRevoked,
    ''AccountDebited,
    ''AccountCredited,
    ''OverdraftLimitSet
  ]

-- -----------------------------------------------------------------------------
-- Account Events
-- -----------------------------------------------------------------------------

-- | Event emitted when a new account is created.
--
-- Contains the initial account configuration including the name,
-- starting balance, owner, and account type.
--
-- Example:
-- >>> AccountCreated "Checking" (Money 1000.0) userId RegularAccount
data AccountCreated = AccountCreated
  { -- | Human-readable name for the account (e.g., "Checking", "Savings")
    name :: Text,
    -- | Initial balance when the account is created
    initialBalance :: Money,
    -- | User who created the account (becomes Owner)
    by :: UserId,
    -- | Type of account (Regular or External)
    accountType :: AccountType,
    -- | Overdraft limit for the account
    overdraftLimit :: Maybe Money
  }
  deriving (Show, Eq)

-- | Event emitted when access is granted to a user.
--
-- Records who was granted access, what role they received, and who
-- granted the access.
--
-- Example:
-- >>> AccountAccessGranted targetUserId Editor grantingUserId
data AccountAccessGranted = AccountAccessGranted
  { -- | User who was granted access
    userId :: UserId,
    -- | Role that was granted
    role :: AccountRole,
    -- | User who granted the access (Owner)
    by :: UserId
  }
  deriving (Show, Eq)

-- | Event emitted when access is revoked from a user.
--
-- Records who lost access and who revoked it.
--
-- Example:
-- >>> AccountAccessRevoked targetUserId revokingUserId
data AccountAccessRevoked = AccountAccessRevoked
  { -- | User who lost access
    userId :: UserId,
    -- | User who revoked the access (Owner)
    by :: UserId
  }
  deriving (Show, Eq)

-- | Event emitted when an account is successfully debited as part of a transfer.
--
-- Produced by the DebitAccount command handler when the source account has
-- sufficient funds (or is an External account, which allows negative balance).
-- The TransferManager saga listens for this event to proceed with crediting
-- the target account.
--
-- Example:
-- >>> AccountDebited (Money 200) txId "Transfer to Savings"
data AccountDebited = AccountDebited
  { -- | Amount debited from the account (always positive)
    amount :: Money,
    -- | Transaction ID for saga correlation
    transactionId :: TransactionId,
    -- | Reason or description for the debit
    reason :: Text
  }
  deriving (Show, Eq)

-- | Event emitted when an account is successfully credited as part of a transfer.
--
-- Produced by the CreditAccount command handler. Credits always succeed.
-- The TransferManager saga listens for this event to finalize transfer tracking.
--
-- Example:
-- >>> AccountCredited (Money 200) txId "Transfer from Checking"
data AccountCredited = AccountCredited
  { -- | Amount credited to the account (always positive)
    amount :: Money,
    -- | Transaction ID for saga correlation
    transactionId :: TransactionId,
    -- | Reason or description for the credit
    reason :: Text
  }
  deriving (Show, Eq)

-- | Event emitted when the overdraft limit is set or removed.
--
-- Records the new overdraft limit and who set it.
--
-- Example:
-- >>> OverdraftLimitSet (Just (Money 500)) ownerId
data OverdraftLimitSet = OverdraftLimitSet
  { overdraftLimit :: Maybe Money,
    by :: UserId
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all events using default options (fields already unprefixed)
deriveJSON defaultOptions ''AccountCreated
deriveJSON defaultOptions ''AccountAccessGranted
deriveJSON defaultOptions ''AccountAccessRevoked
deriveJSON defaultOptions ''AccountDebited
deriveJSON defaultOptions ''AccountCredited
deriveJSON defaultOptions ''OverdraftLimitSet
