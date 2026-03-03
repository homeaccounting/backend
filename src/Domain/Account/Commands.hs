{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Account.Commands
-- Description : Commands for the Account aggregate
--
-- This module defines all commands that can be issued to the Account aggregate.
-- Commands represent intentions to perform actions that may succeed or fail based
-- on the current aggregate state and business rules.
--
-- Key Commands:
--   - CreateAccount: Request to create a new account with initial configuration
--   - ShareAccount: Grant access to another user
--   - RevokeAccountAccess: Remove access from a user
--   - DebitAccount: Debit account as part of a transfer (internal, saga only)
--   - CreditAccount: Credit account as part of a transfer (internal, saga only)
--
-- User-facing money movement is transfer-only (double-entry). DebitAccount and
-- CreditAccount are internal commands issued exclusively by the TransferManager
-- process manager to coordinate the two sides of a transfer. They are not
-- exposed via any API endpoint.
--
-- Commands are validated by the command handler, which either:
--   - Accepts the command and produces events representing state changes
--   - Rejects the command (e.g., unauthorized access, insufficient funds)
--
-- All commands use Template Haskell for integration with the eventium library
-- and include JSON serialization instances for API integration.
module Domain.Account.Commands
  ( -- * Command List
    accountCommands,

    -- * Account Commands
    CreateAccount (..),
    ShareAccount (..),
    RevokeAccountAccess (..),
    DebitAccount (..),
    CreditAccount (..),
  )
where

import Data.Text (Text)
import Domain.Core.Types (AccountRole, AccountType, Money, TransactionId, UserId)
import Eventium.Json.TH (deriveJSONUnPrefixLower)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Command List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all account command type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the AccountCommand sum type and related serialization code.
accountCommands :: [Name]
accountCommands =
  [ ''CreateAccount,
    ''ShareAccount,
    ''RevokeAccountAccess,
    ''DebitAccount,
    ''CreditAccount
  ]

-- -----------------------------------------------------------------------------
-- Account Commands
-- -----------------------------------------------------------------------------

-- | Command to create a new account.
--
-- Represents the intent to create a new account with a given name and
-- initial balance. The account ID is determined by the aggregate ID
-- when the command is processed.
--
-- If accepted, produces an AccountCreated event.
--
-- Business Rules:
--   - Initial balance must be non-negative (enforced by Money type)
--   - Account name should not be empty (validated by command handler)
--   - Creator automatically becomes Owner of the account
--   - External accounts are auto-created during user registration
--
-- Example:
-- >>> CreateAccount "Savings Account" (Money 1000.0) userId RegularAccount
data CreateAccount = CreateAccount
  { -- | Human-readable name for the account (e.g., "Checking", "Savings")
    createAccountName :: Text,
    -- | Initial balance when creating the account (must be non-negative)
    createAccountInitialBalance :: Money,
    -- | User who is creating the account (becomes Owner)
    createAccountCreatedBy :: UserId,
    -- | Type of account (Regular or External)
    createAccountType :: AccountType
  }
  deriving (Show, Eq)

-- | Command to share an account with another user.
--
-- Represents the intent to grant another user access to this account
-- with a specific role.
--
-- If accepted, produces an AccountAccessGranted event.
--
-- Business Rules:
--   - Only Owner can grant access
--   - External accounts cannot be shared
--   - User can only have one role per account (new role replaces old)
--   - Cannot grant access to yourself (already Owner)
--
-- Example:
-- >>> ShareAccount targetUserId Editor grantingUserId
data ShareAccount = ShareAccount
  { -- | User to grant access to
    shareAccountUserId :: UserId,
    -- | Role to grant (Owner, Editor, or Viewer)
    shareAccountRole :: AccountRole,
    -- | User who is granting access (must be Owner)
    shareAccountGrantedBy :: UserId
  }
  deriving (Show, Eq)

-- | Command to revoke access from a user.
--
-- Represents the intent to remove a user's access to this account.
--
-- If accepted, produces an AccountAccessRevoked event.
--
-- Business Rules:
--   - Only Owner can revoke access
--   - Owner cannot be removed from access list
--   - Cannot revoke access from user who doesn't have access
--
-- Example:
-- >>> RevokeAccountAccess targetUserId revokingUserId
data RevokeAccountAccess = RevokeAccountAccess
  { -- | User to revoke access from
    revokeAccountAccessUserId :: UserId,
    -- | User who is revoking access (must be Owner)
    revokeAccountAccessRevokedBy :: UserId
  }
  deriving (Show, Eq)

-- | Command to debit an account as part of a transfer (internal, saga only).
--
-- Issued exclusively by the TransferManager process manager after a
-- TransferInitiated event. Not exposed via any API endpoint.
--
-- If the account has sufficient funds (or is External), produces AccountDebited.
-- If the account is Regular and has insufficient funds, produces AccountDebitRejected.
--
-- Business Rules:
--   - Regular accounts: balance must be >= amount, otherwise rejected
--   - External accounts: always succeed (negative balance allowed)
--   - Account must exist (name not empty)
--
-- Example:
-- >>> DebitAccount (Money 200) txId "Transfer to Savings"
data DebitAccount = DebitAccount
  { -- | Amount to debit (always positive)
    debitAccountAmount :: Money,
    -- | Transaction ID for saga correlation
    debitAccountTransactionId :: TransactionId,
    -- | Reason for the debit
    debitAccountReason :: Text
  }
  deriving (Show, Eq)

-- | Command to credit an account as part of a transfer (internal, saga only).
--
-- Issued exclusively by the TransferManager process manager after a successful
-- debit of the source account. Not exposed via any API endpoint.
--
-- Credits always succeed (adding money never fails). Produces AccountCredited.
--
-- Business Rules:
--   - Account must exist (name not empty)
--   - Always succeeds (no balance validation needed for credits)
--
-- Example:
-- >>> CreditAccount (Money 200) txId "Transfer from Checking"
data CreditAccount = CreditAccount
  { -- | Amount to credit (always positive)
    creditAccountAmount :: Money,
    -- | Transaction ID for saga correlation
    creditAccountTransactionId :: TransactionId,
    -- | Reason for the credit
    creditAccountReason :: Text
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands using the unprefixed lowercase pattern
deriveJSONUnPrefixLower ''CreateAccount
deriveJSONUnPrefixLower ''ShareAccount
deriveJSONUnPrefixLower ''RevokeAccountAccess
deriveJSONUnPrefixLower ''DebitAccount
deriveJSONUnPrefixLower ''CreditAccount
