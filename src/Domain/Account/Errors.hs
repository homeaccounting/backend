{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Domain.Account.Errors
-- Description : Error types specific to the Account aggregate
--
-- This module defines error types that can occur during account operations.
-- These errors represent business rule violations or invalid states that
-- prevent commands from being executed.
--
-- Error Types:
--   - InsufficientFunds: Transfer amount exceeds available balance
--   - AccountNotFound: Account does not exist in the system
--   - AccountAlreadyExists: Attempt to create account that already exists
--   - InvalidAccountName: Account name is empty or invalid
--   - AccessDenied: User does not have access to the account
--   - NotOwner: User is not the owner and cannot perform owner-only operations
--   - ExternalAccountNotShareable: Cannot share External accounts
--
-- These errors are used at the API layer to provide meaningful feedback
-- to clients.
--
-- Usage Context:
--   - API Layer: Convert validation failures to errors for HTTP responses
--   - Query Side: Report errors when accounts cannot be found
--   - Authorization: Access control violations
module Domain.Account.Errors
  ( -- * Account Error Types
    AccountError (..),

    -- * Error Constructors
    mkInsufficientFunds,
    mkAccountNotFound,
    mkAccountAlreadyExists,
    mkInvalidAccountName,
    mkAccessDenied,
    mkNotOwner,
    mkExternalAccountNotShareable,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, UserId)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Account Error Types
-- -----------------------------------------------------------------------------

-- | Errors specific to account operations.
--
-- These errors represent violations of business rules or invalid states
-- in account operations. They are typically used at the API layer to
-- provide meaningful error responses to clients.
data AccountError
  = -- | Insufficient funds for a transfer operation
    InsufficientFunds
      { -- | The account that has insufficient funds
        insufficientFundsAccountId :: AccountId,
        -- | The current available balance
        insufficientFundsBalance :: Money,
        -- | The amount that was requested to transfer
        insufficientFundsRequested :: Money
      }
  | -- | Account not found by ID (also used for access denied to hide existence)
    AccountNotFound
      { -- | The account ID that was not found
        accountNotFoundId :: AccountId
      }
  | -- | Account already exists
    AccountAlreadyExists
      { -- | The account ID that already exists
        accountAlreadyExistsId :: AccountId,
        -- | The name of the existing account
        accountAlreadyExistsName :: Text
      }
  | -- | Invalid account name
    InvalidAccountName
      { -- | The invalid name that was provided
        invalidAccountNameValue :: Text,
        -- | Description of why the name is invalid
        invalidAccountNameReason :: Text
      }
  | -- | User does not have access to the account
    AccessDenied
      { -- | The account being accessed
        accessDeniedAccountId :: AccountId,
        -- | The user who was denied
        accessDeniedUserId :: UserId,
        -- | Description of the operation attempted
        accessDeniedOperation :: Text
      }
  | -- | User is not the owner (for owner-only operations)
    NotOwner
      { -- | The account
        notOwnerAccountId :: AccountId,
        -- | The user who is not the owner
        notOwnerUserId :: UserId,
        -- | Description of the operation attempted
        notOwnerOperation :: Text
      }
  | -- | External accounts cannot be shared
    ExternalAccountNotShareable
      { -- | The External account that cannot be shared
        externalAccountNotShareableId :: AccountId
      }
  deriving (Show, Eq, Generic)

-- JSON instances for API serialization
instance ToJSON AccountError

instance FromJSON AccountError

-- -----------------------------------------------------------------------------
-- Error Constructors
-- -----------------------------------------------------------------------------

-- | Create an InsufficientFunds error.
--
-- This error indicates that a transfer cannot be performed because
-- the source account does not have enough funds.
--
-- Example:
-- >>> mkInsufficientFunds accountId (Money 100) (Money 200)
-- InsufficientFunds { insufficientFundsAccountId = accountId
--                  , insufficientFundsBalance = Money 100
--                  , insufficientFundsRequested = Money 200
--                  }
mkInsufficientFunds ::
  -- | Account ID with insufficient funds
  AccountId ->
  -- | Current balance
  Money ->
  -- | Requested amount
  Money ->
  AccountError
mkInsufficientFunds accountId balance requested =
  InsufficientFunds
    { insufficientFundsAccountId = accountId,
      insufficientFundsBalance = balance,
      insufficientFundsRequested = requested
    }

-- | Create an AccountNotFound error.
--
-- This error indicates that an account with the given ID does not exist
-- in the system. Also used for access denied to hide account existence.
--
-- Example:
-- >>> mkAccountNotFound accountId
-- AccountNotFound { accountNotFoundId = accountId }
mkAccountNotFound ::
  -- | Account ID that was not found
  AccountId ->
  AccountError
mkAccountNotFound accountId =
  AccountNotFound
    { accountNotFoundId = accountId
    }

-- | Create an AccountAlreadyExists error.
--
-- This error indicates that an attempt was made to create an account
-- that already exists.
--
-- Example:
-- >>> mkAccountAlreadyExists accountId "Checking"
-- AccountAlreadyExists { accountAlreadyExistsId = accountId
--                     , accountAlreadyExistsName = "Checking"
--                     }
mkAccountAlreadyExists ::
  -- | Account ID that already exists
  AccountId ->
  -- | Name of the existing account
  Text ->
  AccountError
mkAccountAlreadyExists accountId name =
  AccountAlreadyExists
    { accountAlreadyExistsId = accountId,
      accountAlreadyExistsName = name
    }

-- | Create an InvalidAccountName error.
--
-- This error indicates that an account name is invalid (empty, too long,
-- contains invalid characters, etc.).
--
-- Example:
-- >>> mkInvalidAccountName "" "Account name cannot be empty"
-- InvalidAccountName { invalidAccountNameValue = ""
--                   , invalidAccountNameReason = "Account name cannot be empty"
--                   }
mkInvalidAccountName ::
  -- | The invalid name value
  Text ->
  -- | Reason why the name is invalid
  Text ->
  AccountError
mkInvalidAccountName value reason =
  InvalidAccountName
    { invalidAccountNameValue = value,
      invalidAccountNameReason = reason
    }

-- | Create an AccessDenied error.
--
-- This error indicates that a user does not have access to an account.
-- Note: In API responses, this should usually be converted to AccountNotFound
-- to hide account existence from unauthorized users.
--
-- Example:
-- >>> mkAccessDenied accountId userId "view"
-- AccessDenied { accessDeniedAccountId = accountId
--             , accessDeniedUserId = userId
--             , accessDeniedOperation = "view"
--             }
mkAccessDenied ::
  -- | Account being accessed
  AccountId ->
  -- | User who was denied
  UserId ->
  -- | Operation attempted
  Text ->
  AccountError
mkAccessDenied accountId userId operation =
  AccessDenied
    { accessDeniedAccountId = accountId,
      accessDeniedUserId = userId,
      accessDeniedOperation = operation
    }

-- | Create a NotOwner error.
--
-- This error indicates that a user attempted an owner-only operation
-- but is not the owner of the account.
--
-- Example:
-- >>> mkNotOwner accountId userId "share"
-- NotOwner { notOwnerAccountId = accountId
--         , notOwnerUserId = userId
--         , notOwnerOperation = "share"
--         }
mkNotOwner ::
  -- | Account
  AccountId ->
  -- | User who is not the owner
  UserId ->
  -- | Operation attempted
  Text ->
  AccountError
mkNotOwner accountId userId operation =
  NotOwner
    { notOwnerAccountId = accountId,
      notOwnerUserId = userId,
      notOwnerOperation = operation
    }

-- | Create an ExternalAccountNotShareable error.
--
-- This error indicates that an attempt was made to share an External
-- account, which is not allowed.
--
-- Example:
-- >>> mkExternalAccountNotShareable accountId
-- ExternalAccountNotShareable { externalAccountNotShareableId = accountId }
mkExternalAccountNotShareable ::
  -- | External account ID
  AccountId ->
  AccountError
mkExternalAccountNotShareable accountId =
  ExternalAccountNotShareable
    { externalAccountNotShareableId = accountId
    }
