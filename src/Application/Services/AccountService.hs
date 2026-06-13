{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AccountService
-- Description : Account use case orchestration
--
-- This module implements the application-level orchestration for account
-- operations, handling:
--
--   - ID generation and validation
--   - Event store interactions
--   - Read model queries
--   - Command construction and execution
--
-- Services accept and return domain/application types only. Web-layer
-- DTO conversion is the responsibility of the API handlers.
--
-- All functions return @Either DomainError a@ to make errors explicit in
-- the type, following the project's idiomatic error handling approach.
--
-- Usage:
--   Services are called by thin API handlers in @Web.API.AccountAPI@.
module Application.Services.AccountService
  ( -- * Service Functions
    createAccount,
    getAccount,
    listAccountsForUser,
    shareAccount,
    revokeAccountAccess,
    setOverdraftLimit,
    renameAccount,
    setAccountSubtype,
    adjustAccountBalance,
    closeAccount,
    reopenAccount,
  )
where

import Application.ReadModels.Account (AccountData (..), balanceAsOf)
import qualified Application.ReadModels.Account as ReadModel
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TransactionRM
import Application.Services.AuthorizationService (AccountAuthData (..), canModifyAccount)
import Application.Services.Internal
  ( getUserExternalAccountId,
    guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
    runAccountCmd,
  )
import qualified Application.Services.TransactionService as TransactionService
import Control.Monad.Trans.Except (ExceptT (..), runExceptT)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands
  ( CloseAccount (..),
    CreateAccount,
    RenameAccount (..),
    ReopenAccount (..),
    RevokeAccountAccess (..),
    SetAccountSubtype (..),
    SetOverdraftLimit (..),
    ShareAccount (..),
  )
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountId,
    AccountRole (..),
    AccountSubtype,
    AccountType (..),
    Money (..),
    TransactionId,
    TransactionType (..),
    UserId,
    mkAccountId,
    mkUserId,
    moneyIsPositive,
    moneyIsZero,
    negateMoney,
    subtractMoney,
  )
import Domain.Transaction.Commands (InitiateTransaction (..))
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasReadModel (..),
  )
import RIO
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Create a new account.
--
-- Accepts a validated domain command. The caller (Web handler) is responsible
-- for converting the HTTP request DTO into a 'CreateAccount' command.
--
-- Orchestrates:
--   1. Generate new account ID (UUID)
--   2. Execute CreateAccount command via event store
--   3. Query read model for the created account
--
-- Returns the AccountId and AccountData on success.
createAccount ::
  CreateAccount ->
  AppM (Either DomainError (AccountId, AccountData))
createAccount createCmd = runExceptT $ do
  lift $ logInfo "Creating new account..."
  accountUuid <- liftIO UUID.nextRandom
  accountId <-
    liftEitherWith
      (\err -> AccountError ("Internal error: failed to generate account ID: " <> tshow err))
      (mkAccountId accountUuid)
  lift $ logInfo $ "Generated account ID: " <> displayShow accountUuid
  runAccountCmd id accountUuid (CreateAccountAccountCommand createCmd)
  readModel <- lift (view accountReadModelL)
  account <-
    liftMaybeM
      (AccountError "Account created but not found in read model")
      (liftIO $ ReadModel.getAccount readModel accountId)
  lift $ logInfo "Account successfully created"
  pure (accountId, account)

-- | Get an account by UUID.
--
-- Orchestrates:
--   1. Convert UUID to AccountId
--   2. Query read model
--
-- Returns the AccountId and AccountData on success.
getAccount ::
  UUID ->
  AppM (Either DomainError (AccountId, AccountData))
getAccount accountUuid = runExceptT $ do
  lift $ logInfo $ "Getting account: " <> displayShow accountUuid
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  readModel <- lift (view accountReadModelL)
  account <-
    liftMaybeM
      (NotFound "Account" (tshow accountUuid))
      (liftIO $ ReadModel.getAccount readModel accountId)
  lift $ logInfo "Account found"
  pure (accountId, account)

-- | List accounts accessible to a given user.
--
-- Queries the read model for accounts where the user has access (owner, editor, or viewer).
-- Returns a list of (AccountId, AccountData) pairs, excluding the user's External
-- account: External accounts are an internal bookkeeping device for income/expense
-- and are not surfaced through the public API.
listAccountsForUser :: UserId -> AppM [(AccountId, AccountData)]
listAccountsForUser userId = do
  logInfo $ "Listing accounts for user " <> displayShow userId

  readModel <- view accountReadModelL
  accountsList <- liftIO $ ReadModel.getAccessibleAccounts readModel userId

  let result =
        [ (aid, account)
        | (aid, account, _role) <- accountsList,
          account.accountType /= External
        ]

  logInfo $ "Found " <> displayShow (length result) <> " account(s)"
  return result

-- | Share an account with another user.
--
-- Orchestrates:
--   1. Validate account exists and user is Owner
--   2. Validate target user ID and role
--   3. Check account is not External (cannot share External accounts)
--   4. Issue ShareAccount command
shareAccount ::
  UserId ->
  UUID ->
  UUID ->
  Text ->
  AppM (Either DomainError ())
shareAccount requestingUserId accountUuid targetUserUuid roleText = runExceptT $ do
  lift $ logInfo $ "Sharing account: " <> displayShow accountUuid
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  readModel <- lift (view accountReadModelL)
  account <-
    liftMaybeM
      (NotFound "Account" (tshow accountUuid))
      (liftIO $ ReadModel.getAccount readModel accountId)
  guardE
    (account.createdBy == requestingUserId)
    (AccountError "Only account owner can share access")
  guardE
    (account.accountType /= External)
    (AccountError "External accounts cannot be shared")
  targetUserId <-
    liftEitherWith
      (\_ -> ValidationErr (mkValidationError "userId" "Invalid user ID" (tshow targetUserUuid)))
      (mkUserId targetUserUuid)
  role <-
    liftMaybe
      ( ValidationErr
          (mkValidationError "role" "Invalid role. Must be 'owner', 'editor', or 'viewer'" roleText)
      )
      (parseRole roleText)
  let shareCmd =
        ShareAccountAccountCommand
          ShareAccount
            { userId = targetUserId,
              role = role,
              grantedBy = requestingUserId
            }
  runAccountCmd id accountUuid shareCmd
  lift $ logInfo "Account shared successfully"

-- | Revoke a user's access to an account.
--
-- Orchestrates:
--   1. Validate account exists and user is Owner
--   2. Validate target user ID
--   3. Cannot revoke owner's own access
--   4. Issue RevokeAccountAccess command
revokeAccountAccess ::
  UserId ->
  UUID ->
  UUID ->
  AppM (Either DomainError ())
revokeAccountAccess requestingUserId accountUuid targetUserUuid = runExceptT $ do
  lift $ logInfo $ "Revoking account access: " <> displayShow accountUuid
  accountId <-
    liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  readModel <- lift (view accountReadModelL)
  account <-
    liftMaybeM
      (NotFound "Account" (tshow accountUuid))
      (liftIO $ ReadModel.getAccount readModel accountId)
  guardE
    (account.createdBy == requestingUserId)
    (AccountError "Only account owner can revoke access")
  targetUserId <-
    liftEitherWith
      (\_ -> ValidationErr (mkValidationError "userId" "Invalid user ID" (tshow targetUserUuid)))
      (mkUserId targetUserUuid)
  guardE (targetUserId /= account.createdBy) (AccountError "Cannot revoke owner's access")
  let revokeCmd =
        RevokeAccountAccessAccountCommand
          RevokeAccountAccess
            { userId = targetUserId,
              revokedBy = requestingUserId
            }
  runAccountCmd id accountUuid revokeCmd
  lift $ logInfo "Account access revoked successfully"

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Parse role from text.
parseRole :: Text -> Maybe AccountRole
parseRole t = case T.toLower t of
  "owner" -> Just Owner
  "editor" -> Just Editor
  "viewer" -> Just Viewer
  _ -> Nothing

-- | Set the overdraft limit on an account.
setOverdraftLimit ::
  UserId ->
  UUID ->
  Maybe Money ->
  AppM (Either DomainError ())
setOverdraftLimit requestingUserId accountUuid newLimit = runExceptT $ do
  lift $ logInfo $ "Setting overdraft limit: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd =
        SetOverdraftLimitAccountCommand
          SetOverdraftLimit {overdraftLimit = newLimit, setBy = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Overdraft limit set successfully"

-- | Rename an account.
renameAccount ::
  UserId ->
  UUID ->
  Text ->
  AppM (Either DomainError ())
renameAccount requestingUserId accountUuid newName = runExceptT $ do
  lift $ logInfo $ "Renaming account: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd =
        RenameAccountAccountCommand
          RenameAccount {newName = newName, renamedBy = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account renamed successfully"

-- | Set the account type on an account.
setAccountSubtype ::
  UserId ->
  UUID ->
  AccountSubtype ->
  AppM (Either DomainError ())
setAccountSubtype requestingUserId accountUuid newType = runExceptT $ do
  lift $ logInfo $ "Setting account type: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd =
        SetAccountSubtypeAccountCommand
          SetAccountSubtype {subtype = newType, setBy = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account type set successfully"

-- | Close (deactivate) an account. Owner-only; enforced by the domain handler.
closeAccount ::
  UserId ->
  UUID ->
  AppM (Either DomainError ())
closeAccount requestingUserId accountUuid = runExceptT $ do
  lift $ logInfo $ "Closing account: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd = CloseAccountAccountCommand CloseAccount {by = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account closed successfully"

-- | Reopen a previously-closed account. Owner-only; enforced by the domain handler.
reopenAccount ::
  UserId ->
  UUID ->
  AppM (Either DomainError ())
reopenAccount requestingUserId accountUuid = runExceptT $ do
  lift $ logInfo $ "Reopening account: " <> displayShow accountUuid
  _ <- liftEitherWith (\_ -> NotFound "Account" (tshow accountUuid)) (mkAccountId accountUuid)
  let cmd = ReopenAccountAccountCommand ReopenAccount {by = requestingUserId}
  runAccountCmd id accountUuid cmd
  lift $ logInfo "Account reopened successfully"

-- -----------------------------------------------------------------------------
-- Balance adjustment
-- -----------------------------------------------------------------------------

-- | Reconcile a Regular account's balance to a target value as of a given
-- business date.
--
-- Routes through the existing transfer saga using the user's singleton
-- External account as the contra side. The computed delta determines the
-- direction:
--
--  * @delta > 0@ — credit the Regular account: source = External, target = Regular.
--  * @delta < 0@ — debit the Regular account: source = Regular, target = External.
--
-- Cross-currency cases (External denominated in a different currency from
-- the target account) are resolved by 'TransactionService.resolveAndInitiate'
-- using the same ECB rate path Income\/Expense already use.
--
-- Validation (synchronous, pre-saga):
--
--  * Editor+ role on the account (otherwise 'AccountError').
--  * Account exists and is not External.
--  * @targetBalance@ is denominated in the account's currency.
--  * @at@ is in the past or present.
--  * Resulting delta is non-zero.
--
-- Post-saga failures (e.g. overdraft on a debit leg) surface through the
-- existing 'TransactionPostingManager' path: the returned 'TransactionData' carries
-- a 'Failed' status with the saga's reason.
adjustAccountBalance ::
  UserId ->
  AccountId ->
  -- | Target balance, must be in the account's currency.
  Money ->
  -- | Business date @D@ (the moment the target balance was correct).
  UTCTime ->
  -- | Human-readable reason; stored as the transaction's description.
  Text ->
  AppM (Either DomainError (TransactionId, TransactionRM.TransactionData))
adjustAccountBalance userId accountId targetBalance asOf reason = runExceptT $ do
  lift
    $ logInfo
    $ "Adjusting balance for account "
    <> displayShow accountId
    <> " to target "
    <> displayShow targetBalance.amount
    <> " "
    <> displayShow targetBalance.currency
    <> " as of "
    <> displayShow asOf
  now <- liftIO getCurrentTime
  guardE
    (asOf <= now)
    ( ValidationErr
        (mkValidationError "date" "Adjustment date must be in the past or present" (tshow asOf))
    )

  -- 1. Load account; reject if missing or External.
  accountRM <- lift (view accountReadModelL)
  account <-
    liftMaybeM
      (NotFound "Account" (tshow accountId))
      (ReadModel.getAccount accountRM accountId)
  guardE
    (account.accountType /= External)
    ( ValidationErr
        (mkValidationError "accountType" "Cannot adjust an External account" (tshow accountId))
    )

  -- 2. Authorize Editor+ on the account.
  guardE
    ( canModifyAccount
        userId
        AccountAuthData
          { createdBy = account.createdBy,
            accountType = account.accountType,
            accessList = account.accessList
          }
    )
    (AccountError "User does not have edit access to this account")

  -- 3. Currency match.
  guardE
    (targetBalance.currency == account.balance.currency)
    ( ValidationErr
        ( mkValidationError
            "currency"
            "Currency does not match account currency"
            (tshow targetBalance.currency)
        )
    )

  -- 4. Look up the caller's External account.
  externalAccId <- getUserExternalAccountId userId
  externalAccount <-
    liftMaybeM
      (NotFound "Account" (tshow externalAccId))
      (ReadModel.getAccount accountRM externalAccId)

  -- 5. Compute delta against the historical balance at D.
  --
  -- The balance-as-of fold joins each leg event back to its Transaction
  -- aggregate to honour user edits of the TX's business date. We snapshot
  -- the transaction read model once and feed a pure lookup into the fold.
  reader <- lift (view eventStoreReaderL)
  txnRM <- lift (view transactionReadModelL)
  txnMap <- liftIO (TransactionRM.getAllTransactions txnRM)
  let lookupTxAt txId = (.date) <$> Map.lookup txId txnMap
  currentAtD <-
    liftMaybeM
      (NotFound "Account" (tshow accountId))
      (liftIO (balanceAsOf reader lookupTxAt accountId asOf))
  delta <-
    liftEitherWith
      ( \msg ->
          ValidationErr
            (mkValidationError "currency" msg (tshow targetBalance.currency))
      )
      (subtractMoney targetBalance currentAtD)

  -- 6. Reject no-op adjustments.
  guardE
    (not (moneyIsZero delta))
    ( ValidationErr
        ( mkValidationError
            "targetBalance"
            "Target balance equals current balance at this date"
            (tshow targetBalance.amount)
        )
    )

  -- 7. Direction + amount. The user-supplied magnitude is always in the
  -- account-being-adjusted's currency (= account.balance currency):
  --   * Positive delta — direction is External -> Regular. The Regular
  --     account is the target leg, so the user amount is on the target
  --     side: @userAmountIsSource = False@.
  --   * Negative delta — direction is Regular -> External. The Regular
  --     account is the source leg: @userAmountIsSource = True@.
  let positive = moneyIsPositive delta
      (sourceAccId, targetAccId, magnitude)
        | positive = (externalAccId, accountId, delta)
        | otherwise = (accountId, externalAccId, negateMoney delta)
      srcCurrency = (if positive then externalAccount else account).balance.currency
      tgtCurrency = (if positive then account else externalAccount).balance.currency
      userAmountIsSource = not positive

  -- 8. Cross-currency resolution + saga kick-off.
  ExceptT
    ( TransactionService.resolveAndInitiate
        (Just asOf)
        now
        magnitude
        srcCurrency
        tgtCurrency
        userAmountIsSource
        Nothing
        $ \date srcAmt tgtAmt rate ->
          Right
            InitiateTransaction
              { sourceAccountId = sourceAccId,
                targetAccountId = targetAccId,
                sourceAmount = srcAmt,
                targetAmount = tgtAmt,
                exchangeRate = rate,
                description = reason,
                initiatedBy = userId,
                at = date,
                transactionType = Adjustment,
                externalTransactionId = Nothing,
                labels = mempty
              }
    )
