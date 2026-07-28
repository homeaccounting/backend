{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Application.ReadModels.Account
-- Description : Persistent, indexed read model for account queries
--
-- Accounts are projected into two Postgres tables:
--
--   * @accounts@ — one row per account (name, balance, owner, type, overdraft,
--     status, version), and
--   * @account_access@ — the many-to-many access list (account, user, role),
--     indexed by user so "accounts visible to user U" is an indexed lookup
--     rather than a scan of every account.
--
-- The projection is an eventium 'ReadModel' ('accountReadModel') driven
-- synchronously in the event-append transaction. Per-row @version@ is recorded
-- from the event's real per-stream 'EventVersion' (not derived by incrementing),
-- which is idempotent; @balance@ folds debit/credit deltas (applied exactly once
-- under the synchronous driver).
module Application.ReadModels.Account
  ( -- * Query result type
    AccountData (..),
    RegularAccountData (..),

    -- * Read model
    accountReadModel,
    accountProjectionName,
    migrateAccount,
    resetAccount,
    AccountEntity (..),
    AccountAccessEntity (..),

    -- * Queries (run via 'runDb')
    getAccount,
    getOwnedAccounts,
    getAccounts,
    getAccountIds,
    getRegularAccounts,
    accountExists,

    -- * Temporal balance (event-store fold)
    balanceAsOf,
    foldBalanceAsOf,
  )
where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO)
import Data.Aeson (FromJSON, ToJSON)
import Data.Either (fromRight)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Database.Persist
  ( Entity (..),
    Filter,
    deleteWhere,
    getBy,
    insertUnique,
    replace,
    selectList,
    (<-.),
    (==.),
  )
import Database.Persist.Sql (SqlPersistT, runMigrationSilent)
import Database.Persist.TH (mkMigrate, mkPersist, persistLowerCase, share, sqlSettings)
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountCreated (..),
    AccountCreditReversed (..),
    AccountCredited (..),
    AccountDebitReversed (..),
    AccountDebited (..),
    AccountRenamed (..),
    AccountSubtypeSet (..),
    OverdraftLimitSet (..),
  )
import Domain.Core.Types
  ( AccountAccess (..),
    AccountId,
    AccountRole (..),
    AccountStatus (..),
    AccountSubtypeKind,
    AccountType (..),
    Money,
    TransactionId,
    UserId,
    accountTypeSubtypeKind,
    addMoney,
    mkAccountIdSafe,
    subtractMoney,
    unAccountId,
  )
import Domain.Models (AccountingEvent (..))
import Eventium
  ( EventHandler (..),
    EventStoreReader (..),
    EventVersion (..),
    GlobalStreamEvent,
    ReadModel (..),
    StreamEvent (..),
    VersionedStreamEvent,
    allEvents,
  )
import Eventium.ProjectionCache.Postgresql (CheckpointName (..), postgresqlCheckpointStore)
import GHC.Generics (Generic)
import Infrastructure.Database.Orphans ()

-- -----------------------------------------------------------------------------
-- Query result type
-- -----------------------------------------------------------------------------

-- | Denormalized account information returned by queries. @accessList@ is
-- assembled from the @account_access@ rows.
data AccountData = AccountData
  { name :: Text,
    balance :: Money,
    createdBy :: UserId,
    accountType :: AccountType,
    accessList :: [AccountAccess],
    overdraftLimit :: Maybe Money,
    hasTransactions :: Bool,
    status :: AccountStatus,
    version :: EventVersion
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountData

instance FromJSON AccountData

-- | A user's own regular (non-'External') account, projected to the fields
-- callers need for name/subtype resolution (the prompt resolver, Telegram).
-- Carries the payload-free 'AccountSubtypeKind' rather than the full subtype.
data RegularAccountData = RegularAccountData
  { name :: Text,
    balance :: Money,
    subtype :: AccountSubtypeKind
  }
  deriving (Show, Eq, Generic)

instance ToJSON RegularAccountData

instance FromJSON RegularAccountData

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

share
  [mkPersist sqlSettings, mkMigrate "migrateAccount"]
  [persistLowerCase|
AccountEntity sql=accounts
    accountId AccountId
    name Text
    balance Money
    createdBy UserId
    accountType AccountType
    overdraftLimit Money Maybe
    hasTransactions Bool
    status AccountStatus
    version EventVersion
    UniqueAccountId accountId
    deriving Show Eq
AccountAccessEntity sql=account_access
    accountId AccountId
    userId UserId
    role AccountRole
    -- (userId, accountId): leads with userId so "accounts visible to a user" is
    -- an indexed lookup; also uniquely identifies a user's role on an account.
    UniqueAccountAccess userId accountId
    deriving Show Eq
|]

-- | Projection/checkpoint name for this read model.
accountProjectionName :: CheckpointName
accountProjectionName = CheckpointName "account"

-- | Clear both account tables. The checkpoint is reset by 'rebuildReadModel'.
resetAccount :: (MonadIO m) => SqlPersistT m ()
resetAccount = do
  deleteWhere ([] :: [Filter AccountAccessEntity])
  deleteWhere ([] :: [Filter AccountEntity])

-- -----------------------------------------------------------------------------
-- Read model
-- -----------------------------------------------------------------------------

accountReadModel :: ReadModel (SqlPersistT IO) AccountingEvent
accountReadModel =
  ReadModel
    { initialize = void (runMigrationSilent migrateAccount),
      eventHandler = EventHandler applyAccountEvent,
      checkpointStore = postgresqlCheckpointStore accountProjectionName,
      reset = resetAccount
    }

-- | Apply a single global event to the account tables. The per-stream version
-- (@globalEvent.payload.position@) is recorded as the row @version@.
applyAccountEvent :: (MonadIO m) => GlobalStreamEvent AccountingEvent -> SqlPersistT m ()
applyAccountEvent globalEvent =
  let inner = globalEvent.payload
      ver = inner.position
   in case mkAccountIdSafe inner.key of
        Nothing -> pure ()
        Just accId -> case inner.payload of
          AccountCreatedEvent evt -> do
            void $
              insertUnique
                AccountEntity
                  { accountEntityAccountId = accId,
                    accountEntityName = evt.name,
                    accountEntityBalance = evt.initialBalance,
                    accountEntityCreatedBy = evt.by,
                    accountEntityAccountType = evt.accountType,
                    accountEntityOverdraftLimit = evt.overdraftLimit,
                    accountEntityHasTransactions = False,
                    accountEntityStatus = Opened,
                    accountEntityVersion = ver
                  }
            void $ insertUnique (AccountAccessEntity accId evt.by Owner)
          AccountAccessGrantedEvent evt -> do
            deleteWhere [AccountAccessEntityAccountId ==. accId, AccountAccessEntityUserId ==. evt.userId]
            void $ insertUnique (AccountAccessEntity accId evt.userId evt.role)
            bumpVersion accId ver
          AccountAccessRevokedEvent evt -> do
            deleteWhere [AccountAccessEntityAccountId ==. accId, AccountAccessEntityUserId ==. evt.userId]
            bumpVersion accId ver
          AccountDebitedEvent evt -> adjustBalance accId ver subtractMoney evt.amount
          AccountCreditedEvent evt -> adjustBalance accId ver addMoney evt.amount
          AccountDebitReversedEvent evt -> adjustBalance accId ver addMoney evt.amount
          AccountCreditReversedEvent evt -> adjustBalance accId ver subtractMoney evt.amount
          OverdraftLimitSetEvent evt ->
            modifyAccount accId (\e -> e {accountEntityOverdraftLimit = evt.overdraftLimit, accountEntityVersion = ver})
          AccountSubtypeSetEvent evt ->
            modifyAccount accId (\e -> e {accountEntityAccountType = Regular evt.subtype, accountEntityVersion = ver})
          AccountRenamedEvent evt ->
            modifyAccount accId (\e -> e {accountEntityName = evt.newName, accountEntityVersion = ver})
          AccountClosedEvent _ ->
            modifyAccount accId (\e -> e {accountEntityStatus = Closed, accountEntityVersion = ver})
          AccountReopenedEvent _ ->
            modifyAccount accId (\e -> e {accountEntityStatus = Opened, accountEntityVersion = ver})
          _ -> pure ()

-- | Read-modify-write the account row (no-op if absent).
modifyAccount :: (MonadIO m) => AccountId -> (AccountEntity -> AccountEntity) -> SqlPersistT m ()
modifyAccount accId f = do
  mEnt <- getBy (UniqueAccountId accId)
  case mEnt of
    Nothing -> pure ()
    Just (Entity k e) -> replace k (f e)

-- | Apply a balance delta (currency mismatch — impossible for valid streams — is
-- a no-op), set @hasTransactions@, and record the version.
adjustBalance ::
  (MonadIO m) =>
  AccountId ->
  EventVersion ->
  (Money -> Money -> Either e Money) ->
  Money ->
  SqlPersistT m ()
adjustBalance accId ver op amount =
  modifyAccount accId $ \e ->
    case op e.accountEntityBalance amount of
      Right b -> e {accountEntityBalance = b, accountEntityHasTransactions = True, accountEntityVersion = ver}
      Left _ -> e

bumpVersion :: (MonadIO m) => AccountId -> EventVersion -> SqlPersistT m ()
bumpVersion accId ver = modifyAccount accId (\e -> e {accountEntityVersion = ver})

-- -----------------------------------------------------------------------------
-- Queries
-- -----------------------------------------------------------------------------

entToData :: AccountEntity -> [AccountAccess] -> AccountData
entToData e acl =
  AccountData
    { name = e.accountEntityName,
      balance = e.accountEntityBalance,
      createdBy = e.accountEntityCreatedBy,
      accountType = e.accountEntityAccountType,
      accessList = acl,
      overdraftLimit = e.accountEntityOverdraftLimit,
      hasTransactions = e.accountEntityHasTransactions,
      status = e.accountEntityStatus,
      version = e.accountEntityVersion
    }

-- | The access list (users + roles) for an account.
loadAccessList :: (MonadIO m) => AccountId -> SqlPersistT m [AccountAccess]
loadAccessList accId = do
  rows <- selectList [AccountAccessEntityAccountId ==. accId] []
  pure [AccountAccess r.accountAccessEntityUserId r.accountAccessEntityRole | Entity _ r <- rows]

-- | Access lists for many accounts in a single indexed query, grouped by
-- account. Avoids the N+1 of calling 'loadAccessList' per account in the
-- multi-account queries below.
loadAccessLists :: (MonadIO m) => [AccountId] -> SqlPersistT m (Map AccountId [AccountAccess])
loadAccessLists accIds = do
  rows <- selectList [AccountAccessEntityAccountId <-. accIds] []
  pure $
    Map.fromListWith
      (<>)
      [ (r.accountAccessEntityAccountId, [AccountAccess r.accountAccessEntityUserId r.accountAccessEntityRole])
      | Entity _ r <- rows
      ]

-- | Account by id, with its access list, or 'Nothing'.
getAccount :: (MonadIO m) => AccountId -> SqlPersistT m (Maybe AccountData)
getAccount accId = do
  mEnt <- getBy (UniqueAccountId accId)
  case mEnt of
    Nothing -> pure Nothing
    Just (Entity _ e) -> Just . entToData e <$> loadAccessList accId

-- | The caller's own accounts (those they created), keyed by id, each with its
-- access list. Scoped to the owner via an indexed @created_by@ lookup — never a
-- full-table scan over every user's accounts. Accounts merely shared /to/ the
-- caller are excluded; use 'getAccounts' for the owner+shared scope.
getOwnedAccounts :: (MonadIO m) => UserId -> SqlPersistT m (Map AccountId AccountData)
getOwnedAccounts userId = do
  rows <- selectList [AccountEntityCreatedBy ==. userId] []
  aclByAcc <- loadAccessLists [e.accountEntityAccountId | Entity _ e <- rows]
  pure $
    Map.fromList
      [ (e.accountEntityAccountId, entToData e (Map.findWithDefault [] e.accountEntityAccountId aclByAcc))
      | Entity _ e <- rows
      ]

-- | The owner+shared access scope, in one place: the (account id, role) pairs
-- from the @account_access@ table for a user. An indexed @WHERE user_id = ?@
-- lookup covering both accounts the user created (role 'Owner') and accounts
-- shared to them (the granted role). Every accessible-scope query below is
-- built on this, so the scope predicate lives in exactly one place.
accessScopeFor :: (MonadIO m) => UserId -> SqlPersistT m [(AccountId, AccountRole)]
accessScopeFor userId = do
  rows <- selectList [AccountAccessEntityUserId ==. userId] []
  pure [(r.accountAccessEntityAccountId, r.accountAccessEntityRole) | Entity _ r <- rows]

-- | Accounts the user can access (owner + shared, any role), with the user's
-- role on each. Includes the user's own External bookkeeping account; callers
-- that want only spendable accounts use 'getRegularAccounts'.
getAccounts ::
  (MonadIO m) =>
  UserId ->
  SqlPersistT m [(AccountId, AccountData, AccountRole)]
getAccounts userId = do
  roleByAcc <- Map.fromList <$> accessScopeFor userId
  let accIds = Map.keys roleByAcc
  accountRows <- selectList [AccountEntityAccountId <-. accIds] []
  aclByAcc <- loadAccessLists accIds
  pure
    [ (e.accountEntityAccountId, entToData e (Map.findWithDefault [] e.accountEntityAccountId aclByAcc), role)
    | Entity _ e <- accountRows,
      Just role <- [Map.lookup e.accountEntityAccountId roleByAcc]
    ]

-- | The set of account ids a user can access (owner + shared). Kept as its own
-- lean id-only query — it drives transaction/report visibility filtering, so it
-- must not pay to load full account rows the way 'getAccounts' does.
getAccountIds :: (MonadIO m) => UserId -> SqlPersistT m (Set AccountId)
getAccountIds userId = Set.fromList . map fst <$> accessScopeFor userId

-- | A user's accessible (owner + shared) regular accounts as
-- (id, 'RegularAccountData'). A projection of 'getAccounts' that drops the
-- role, keeps only 'Regular' accounts (the External bookkeeping account has no
-- subtype and so falls out), and carries just name\/balance\/subtype.
getRegularAccounts :: (MonadIO m) => UserId -> SqlPersistT m [(AccountId, RegularAccountData)]
getRegularAccounts userId = do
  accounts <- getAccounts userId
  pure
    [ ( aid,
        RegularAccountData
          { name = ad.name,
            balance = ad.balance,
            subtype = kind
          }
      )
    | (aid, ad, _role) <- accounts,
      Just kind <- [accountTypeSubtypeKind ad.accountType]
    ]

-- | Whether an account exists.
accountExists :: (MonadIO m) => AccountId -> SqlPersistT m Bool
accountExists accId = isJust <$> getBy (UniqueAccountId accId)

-- -----------------------------------------------------------------------------
-- Temporal balance query (event-store fold; unchanged)
-- -----------------------------------------------------------------------------

-- | Balance as of business date @D@ by re-folding the aggregate's event stream
-- (an on-demand event-store fold, not a maintained projection). See the prior
-- documentation; behaviour is unchanged.
balanceAsOf ::
  (Monad m) =>
  EventStoreReader UUID EventVersion m (VersionedStreamEvent AccountingEvent) ->
  (TransactionId -> Maybe UTCTime) ->
  AccountId ->
  UTCTime ->
  m (Maybe Money)
balanceAsOf (EventStoreReader readStream) lookupAt accountId asOf = do
  events <- readStream (allEvents (unAccountId accountId))
  pure (foldBalanceAsOf asOf lookupAt ((.payload) <$> events))

-- | Pure fold of 'AccountingEvent' payloads into a balance as of @D@. Returns
-- 'Nothing' when no 'AccountCreated' is present.
foldBalanceAsOf ::
  UTCTime ->
  (TransactionId -> Maybe UTCTime) ->
  [AccountingEvent] ->
  Maybe Money
foldBalanceAsOf asOf lookupAt events =
  case dropWhile (not . isAccountCreated) events of
    [] -> Nothing
    (AccountCreatedEvent c : rest) ->
      Just (foldl' (applyAsOf asOf lookupAt) c.initialBalance rest)
    _ -> Nothing
  where
    isAccountCreated (AccountCreatedEvent _) = True
    isAccountCreated _ = False

    applyAsOf :: UTCTime -> (TransactionId -> Maybe UTCTime) -> Money -> AccountingEvent -> Money
    applyAsOf cutoff lookup_ bal (AccountDebitedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          fromRight bal (subtractMoney bal e.amount)
    applyAsOf cutoff lookup_ bal (AccountCreditedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          fromRight bal (addMoney bal e.amount)
    applyAsOf cutoff lookup_ bal (AccountDebitReversedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          fromRight bal (addMoney bal e.amount)
    applyAsOf cutoff lookup_ bal (AccountCreditReversedEvent e)
      | Just effectiveAt <- lookup_ e.transactionId,
        effectiveAt <= cutoff =
          fromRight bal (subtractMoney bal e.amount)
    applyAsOf _ _ bal _ = bal
