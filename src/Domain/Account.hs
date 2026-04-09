-- |
-- Module      : Domain.Account
-- Description : Public API for the Account aggregate
--
-- This module re-exports all Account aggregate components, providing a single
-- import point for working with accounts.
--
-- Usage:
-- >>> import Domain.Account
--
-- This gives you access to:
--   - Events: AccountCreated, AccountAccessGranted, AccountAccessRevoked, AccountDebited, AccountCredited
--   - Commands: CreateAccount, ShareAccount, RevokeAccountAccess
--   - Projection: Account, accountProjection, AccountEvent
--   - Command Handler: accountCommandHandler, AccountCommand
--   - Errors: AccountError, InsufficientFunds, AccountNotFound, AccessDenied, etc.
--
-- The Account aggregate represents a financial account with balance, name,
-- owner, type (Regular or External), and access list (RBAC).
--
-- It follows event sourcing and CQRS patterns:
--   - Commands express user intent
--   - Command handler validates commands against current state
--   - Events represent facts about state changes
--   - Projection rebuilds state from events
--
-- Example Usage:
--
-- Creating an account:
-- >>> let cmd = CreateAccount "Savings" (Money 1000.0) userId RegularAccount
-- >>> let events = handleAccountCommand accountDefault cmd
-- >>> events
-- [AccountCreatedAccountEvent (AccountCreated "Savings" (Money 1000.0) userId RegularAccount)]
--
-- Processing events:
-- >>> let account = latestProjection accountProjection events
-- >>> account ^. accountBalance
-- Money 1000.0
--
-- Business Rules:
--   - Regular accounts cannot have negative balances
--   - External accounts can go negative (for income/expense tracking)
--   - Account names cannot be empty
--   - Only Owner can share or revoke access
--   - External accounts cannot be shared
--   - All state changes are event-sourced
module Domain.Account
  ( -- * Command Handler
    module Domain.Account.CommandHandler,

    -- * Commands
    module Domain.Account.Commands,

    -- * Events (without field accessors that conflict with lenses)
    AccountCreated (AccountCreated),
    AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountDebited (..),
    AccountCredited (..),
    OverdraftLimitSet (..),
    AccountSubtypeSet (..),
    AccountCurrencyChanged (..),
    accountEvents,

    -- * Projection
    module Domain.Account.Projection,
  )
where

import Domain.Account.CommandHandler
import Domain.Account.Commands
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountCreated (AccountCreated),
    AccountCredited (..),
    AccountCurrencyChanged (..),
    AccountDebited (..),
    AccountSubtypeSet (..),
    OverdraftLimitSet (..),
    accountEvents,
  )
import Domain.Account.Projection
