{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}

-- |
-- Module      : Application.Services.AuthorizationService
-- Description : Authorization service for RBAC access control
--
-- This module implements the authorization service that checks user permissions
-- for account access and transfer operations based on Role-Based Access Control (RBAC).
--
-- Key Components:
--   - AccountAccessResult: Result of checking account access
--   - TransferAuthResult: Result of checking transfer authorization
--   - canAccessAccount: Check if user can access an account
--   - canModifyAccount: Check if user can modify an account (Editor+)
--   - canManageAccount: Check if user can manage an account (Owner only)
--   - canTransfer: Check if user can perform a transfer between accounts
--   - getUserAccessibleAccounts: Get all accounts a user can access
--
-- Design Rationale:
--   - Separates authorization logic from domain logic
--   - Uses read models for efficient permission checks
--   - Returns 404 for unauthorized access to hide account existence
--   - Supports the transfer-only model with proper role checks
--
-- Authorization Rules:
--   - User can access account if they appear in the account's access list
--   - Viewer can only view, Editor can view and transfer, Owner has full control
--   - Transfer requires Editor+ role on BOTH source and target accounts
--   - User always has implicit Editor access to their own External account
module Application.Services.AuthorizationService
  ( -- * Result Types
    AccountAccessResult (..),
    TransferAuthResult (..),
    TransferDenialReason (..),

    -- * Account Auth Data (for testing)
    AccountAuthData (..),

    -- * Authorization Functions
    canAccessAccount,
    canModifyAccount,
    canManageAccount,
    canTransfer,
    getUserAccessibleAccounts,
    checkAccountAccess,
  )
where

import Control.Concurrent.STM (TVar, readTVarIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types
  ( AccountAccess (..),
    AccountId,
    AccountRole (..),
    AccountType (..),
    UserId,
  )
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Result Types
-- -----------------------------------------------------------------------------

-- | Result of checking account access.
data AccountAccessResult
  = -- | Access granted with the user's role
    AccessGranted AccountRole
  | -- | Access denied (user has no access to this account)
    AccessDenied
  deriving (Show, Eq, Generic)

instance ToJSON AccountAccessResult

instance FromJSON AccountAccessResult

-- | Result of checking transfer authorization.
data TransferAuthResult
  = -- | Transfer is authorized
    TransferAuthorized
  | -- | Transfer is denied with a reason
    TransferDenied TransferDenialReason
  deriving (Show, Eq, Generic)

instance ToJSON TransferAuthResult

instance FromJSON TransferAuthResult

-- | Reason why a transfer was denied.
data TransferDenialReason
  = -- | User has no access to the source account
    NoAccessToSource
  | -- | User has no access to the target account
    NoAccessToTarget
  | -- | User has insufficient role on source (e.g., Viewer can't transfer)
    InsufficientRoleOnSource AccountRole
  | -- | User has insufficient role on target (e.g., Viewer can't receive)
    InsufficientRoleOnTarget AccountRole
  | -- | Source and target are the same account
    SameSourceAndTarget
  | -- | Source account does not exist
    SourceAccountNotFound
  | -- | Target account does not exist
    TargetAccountNotFound
  deriving (Show, Eq, Generic)

instance ToJSON TransferDenialReason

instance FromJSON TransferDenialReason

-- -----------------------------------------------------------------------------
-- Account Access Data Structure
--
-- This represents the data structure used for authorization checks.
-- In a full implementation, this would come from the read model.
-- -----------------------------------------------------------------------------

-- | Account data needed for authorization checks.
data AccountAuthData = AccountAuthData
  { accountAuthDataCreatedBy :: UserId,
    accountAuthDataType :: AccountType,
    accountAuthDataAccessList :: [AccountAccess]
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Authorization Functions
-- -----------------------------------------------------------------------------

-- | Check if a user can access an account.
--
-- Returns the user's role if they have access, or AccessDenied if not.
--
-- Access is granted if:
--   - User appears in the account's access list (any role)
--   - User is the creator of the account (implicit Owner)
--
-- Example:
-- >>> result <- canAccessAccount userId accountAuthData
-- >>> case result of
-- >>>   AccessGranted role -> doSomethingWith role
-- >>>   AccessDenied -> return404
canAccessAccount ::
  UserId ->
  AccountAuthData ->
  AccountAccessResult
canAccessAccount userId accountData =
  case getUserRoleFromAccessList userId (accountAuthDataAccessList accountData) of
    Just role -> AccessGranted role
    Nothing ->
      -- Check if user is creator (should already be in access list, but as fallback)
      if accountAuthDataCreatedBy accountData == userId
        then AccessGranted Owner
        else AccessDenied

-- | Check if a user can modify an account (requires Editor or Owner role).
--
-- Modification includes:
--   - Being the source or target of a transfer
--   - Any write operation on the account
--
-- Example:
-- >>> canModify <- canModifyAccount userId accountAuthData
-- >>> if canModify then proceedWithTransfer else denyTransfer
canModifyAccount ::
  UserId ->
  AccountAuthData ->
  Bool
canModifyAccount userId accountData =
  case canAccessAccount userId accountData of
    AccessGranted Owner -> True
    AccessGranted Editor -> True
    AccessGranted Viewer -> False
    AccessDenied -> False

-- | Check if a user can manage an account (requires Owner role).
--
-- Management includes:
--   - Sharing the account with other users
--   - Revoking access from users
--   - Deleting the account
--
-- Example:
-- >>> canManage <- canManageAccount userId accountAuthData
-- >>> if canManage then shareAccount else denySharing
canManageAccount ::
  UserId ->
  AccountAuthData ->
  Bool
canManageAccount userId accountData =
  case canAccessAccount userId accountData of
    AccessGranted Owner -> True
    AccessGranted _ -> False
    AccessDenied -> False

-- | Check if a user can perform a transfer between two accounts.
--
-- Transfer authorization requires:
--   - Editor+ role on the source account
--   - Editor+ role on the target account
--   - Source and target must be different accounts
--
-- Special Cases:
--   - External accounts: User always has implicit Editor access to their own External account
--   - Self-transfers: Rejected (same account as source and target)
--
-- Example:
-- >>> result <- canTransfer userId sourceAccountData targetAccountData sourceId targetId
-- >>> case result of
-- >>>   TransferAuthorized -> executeTransfer
-- >>>   TransferDenied reason -> rejectWithReason reason
canTransfer ::
  UserId ->
  AccountAuthData ->
  AccountAuthData ->
  AccountId ->
  AccountId ->
  TransferAuthResult
canTransfer userId sourceData targetData sourceId targetId
  -- Same account - reject
  | sourceId == targetId = TransferDenied SameSourceAndTarget
  -- Check source access
  | not (canModifyAccount userId sourceData) =
      case canAccessAccount userId sourceData of
        AccessGranted role -> TransferDenied (InsufficientRoleOnSource role)
        AccessDenied -> TransferDenied NoAccessToSource
  -- Check target access
  | not (canModifyAccount userId targetData) =
      case canAccessAccount userId targetData of
        AccessGranted role -> TransferDenied (InsufficientRoleOnTarget role)
        AccessDenied -> TransferDenied NoAccessToTarget
  -- All checks passed
  | otherwise = TransferAuthorized

-- | Get all accounts a user can access with their roles.
--
-- This function would typically query the read model to find all accounts
-- where the user appears in the access list.
--
-- Note: This is a placeholder signature. The actual implementation
-- would need to iterate over all accounts in the read model.
--
-- Example:
-- >>> accounts <- getUserAccessibleAccounts userId accountReadModel
-- >>> mapM_ (\(accId, role) -> print (accId, role)) accounts
getUserAccessibleAccounts ::
  (MonadIO m) =>
  UserId ->
  TVar AccountAccessReadModel ->
  m [(AccountId, AccountRole)]
getUserAccessibleAccounts userId readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  let allAccounts = Map.toList (accountAccessData model)
      accessibleAccounts =
        [ (accountId, role)
          | (accountId, authData) <- allAccounts,
            Just role <- [getUserRoleFromAccessList userId (accountAuthDataAccessList authData)]
        ]
  return accessibleAccounts

-- | Check account access and return the auth data if accessible.
--
-- This is a convenience function that combines lookup and access check.
-- Returns Nothing if account doesn't exist OR user doesn't have access
-- (to hide account existence from unauthorized users).
checkAccountAccess ::
  (MonadIO m) =>
  UserId ->
  AccountId ->
  TVar AccountAccessReadModel ->
  m (Maybe (AccountRole, AccountAuthData))
checkAccountAccess userId accountId readModelTVar = do
  model <- liftIO $ readTVarIO readModelTVar
  case Map.lookup accountId (accountAccessData model) of
    Nothing -> return Nothing -- Account doesn't exist
    Just authData ->
      case canAccessAccount userId authData of
        AccessGranted role -> return $ Just (role, authData)
        AccessDenied -> return Nothing -- Hide existence

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Get a user's role from an access list.
getUserRoleFromAccessList :: UserId -> [AccountAccess] -> Maybe AccountRole
getUserRoleFromAccessList userId accessList =
  accessRole <$> findAccess
  where
    findAccess = foldr matchUser Nothing accessList
    matchUser acc result =
      if accessUserId acc == userId
        then Just acc
        else result

-- -----------------------------------------------------------------------------
-- Read Model Types (Placeholder)
--
-- In a full implementation, this would be imported from the actual read model
-- module. For now, we define the types here.
-- -----------------------------------------------------------------------------

-- | Read model for authorization data.
--
-- This stores the authorization-relevant data for all accounts,
-- updated by listening to the event stream.
data AccountAccessReadModel = AccountAccessReadModel
  { accountAccessData :: Map.Map AccountId AccountAuthData
  }
  deriving (Show, Eq)
