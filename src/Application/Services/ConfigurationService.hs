{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ConfigurationService
-- Description : Configuration use case orchestration with clone-on-write
--
-- This module implements the application-level orchestration for configuration
-- operations, handling:
--
--   - Clone-on-write semantics for shared default configurations
--   - Dictionary management (add, rename, remove entries)
--   - Currency preference changes (base and default)
--   - Default configuration seeding on first startup
--
-- Clone-on-write logic: when a user modifies a configuration they don't own
-- (System or ClonedBy another user), a personal clone is created first, then
-- the mutation is applied to the clone.
--
-- Services accept and return domain/application types only. Web-layer
-- DTO conversion is the responsibility of the API handlers.
module Application.Services.ConfigurationService
  ( -- * Service Functions
    getConfigurationForUser,
    changeBaseCurrency,
    changeDefaultCurrency,
    addDictionaryEntry,
    renameDictionaryEntry,
    removeDictionaryEntry,
    setBankingDefaultIncomeCategory,
    setBankingDefaultExpenseCategory,
    setBankingMccExpenseCategoryMap,
    closeBooksThrough,
    seedDefaultConfiguration,

    -- * Well-known Dictionary IDs
    incomeCategoryDictId,
    expenseCategoryDictId,
    labelsDictId,
  )
where

import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..), getConfiguration)
import Application.ReadModels.Transaction (findReferencingTransactions)
import Application.ReadModels.User (UserData (..))
import Application.Services.Internal
  ( getUserData,
    guardE,
    liftEitherWith,
    liftMaybeM,
    runAccountCmd,
    runConfigurationCmd,
    runUserCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (ChangeAccountCurrency (..))
import Domain.Configuration.CommandHandler (ConfigurationCommand (..))
import qualified Domain.Configuration.CommandHandler as ConfigCh
import Domain.Configuration.Commands
  ( AddDictionaryEntry (..),
    ChangeBaseCurrency (..),
    ChangeDefaultCurrency (..),
    CloseBooksThrough (..),
    CreateConfiguration (..),
    RemoveDictionaryEntry (..),
    RenameDictionaryEntry (..),
    SetBankingDefaultExpenseCategory (..),
    SetBankingDefaultIncomeCategory (..),
    SetBankingMccExpenseCategoryMap (..),
  )
import Domain.Configuration.Defaults
  ( DefaultEntry (..),
    ExpenseDefaults (other),
    IncomeDefaults (other),
    defaultExpenseCategories,
    defaultIncomeCategories,
    defaultMccExpenseCategoryMap,
    expense,
    expenseCategoryDictId,
    income,
    incomeCategoryDictId,
  )
import Domain.Configuration.Projection (BankingConfiguration (defaultExpenseCategory, defaultIncomeCategory, mccExpenseCategoryMap))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( CategoryId,
    ConfigurationId,
    CreatedBy (..),
    Currency (..),
    DictionaryEntryId,
    DictionaryId (..),
    EntryName,
    MCC,
    UserId,
    defaultConfigurationId,
    mkConfigurationId,
    unAccountId,
    unConfigurationId,
    unDictionaryEntryId,
    unUserId,
    unsafeDictionaryEntryId,
    unsafeEntryName,
  )
import Domain.User.CommandHandler (UserCommand (..))
import Domain.User.Commands (AssignConfiguration (..))
import Eventium (CommandHandlerError (..))
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasReadModel (..),
  )
import Infrastructure.Eventium (applyConfigurationCommand)
import RIO
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Well-known Dictionary IDs
-- -----------------------------------------------------------------------------

-- | Dictionary ID for transaction labels (optional, multi-valued per txn).
labelsDictId :: DictionaryId
labelsDictId = DictionaryId "labels"

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Get the configuration data for a user.
--
-- Looks up the user's assigned configuration ID and retrieves the configuration
-- data from the read model.
getConfigurationForUser :: UserId -> AppM (Either DomainError ConfigurationData)
getConfigurationForUser userId = runExceptT $ do
  lift $ logInfo $ "Getting configuration for user: " <> displayShow userId
  (_configId, configData) <- ExceptT (lookupUserConfiguration userId)
  pure configData

-- | Change the base currency for a user's configuration.
--
-- Special flow:
--   1. Clone-on-write if needed
--   2. Attempt ChangeAccountCurrency on the user's External account first
--   3. If it succeeds, apply ChangeBaseCurrency on the configuration
--   4. If it fails, return error
changeBaseCurrency :: UserId -> Currency -> AppM (Either DomainError ())
changeBaseCurrency userId newCurrency = runExceptT $ do
  lift $ logInfo $ "Changing base currency to " <> displayShow newCurrency <> " for user " <> displayShow userId
  userData <- getUserData userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runAccountCmd
    id
    (unAccountId userData.externalAccountId)
    (ChangeAccountCurrencyAccountCommand ChangeAccountCurrency {newCurrency = newCurrency})
  runConfigurationCmd
    defaultTranslateConfigurationError
    id
    (unConfigurationId configId)
    (ChangeBaseCurrencyConfigurationCommand ChangeBaseCurrency {baseCurrency = newCurrency})
  lift $ logInfo "Base currency changed successfully"

-- | Change the default currency for a user's configuration.
changeDefaultCurrency :: UserId -> Currency -> AppM (Either DomainError ())
changeDefaultCurrency userId newCurrency = runExceptT $ do
  lift $ logInfo $ "Changing default currency to " <> displayShow newCurrency <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    defaultTranslateConfigurationError
    id
    (unConfigurationId configId)
    (ChangeDefaultCurrencyConfigurationCommand ChangeDefaultCurrency {defaultCurrency = newCurrency})
  lift $ logInfo "Default currency changed successfully"

-- | Add a new entry to a dictionary in the user's configuration.
addDictionaryEntry :: UserId -> DictionaryId -> EntryName -> AppM (Either DomainError DictionaryEntryId)
addDictionaryEntry userId dictId entryName = runExceptT $ do
  lift $ logInfo $ "Adding dictionary entry to " <> displayShow dictId <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  entryUuid <- liftIO UUID.nextRandom
  let entryId = unsafeDictionaryEntryId entryUuid
      cmd =
        AddDictionaryEntryConfigurationCommand
          AddDictionaryEntry
            { dictionaryId = dictId,
              entryId = entryId,
              name = entryName
            }
  runConfigurationCmd defaultTranslateConfigurationError id (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry added successfully"
  pure entryId

-- | Rename an entry in a dictionary in the user's configuration.
renameDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> EntryName -> AppM (Either DomainError ())
renameDictionaryEntry userId dictId entryId newName = runExceptT $ do
  lift $ logInfo $ "Renaming dictionary entry in " <> displayShow dictId <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RenameDictionaryEntryConfigurationCommand
          RenameDictionaryEntry
            { dictionaryId = dictId,
              entryId = entryId,
              newName = newName
            }
  runConfigurationCmd defaultTranslateConfigurationError id (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry renamed successfully"

-- | Remove an entry from a dictionary in the user's configuration.
--
-- Refuses with 'LabelInUse' or 'CategoryInUse' when any transaction still
-- references the entry (either via its labels set or via the categorised
-- 'TransactionType'). The check is performed at the service layer because it
-- depends on the transaction read model; the pure configuration command
-- handler enforces only the aggregate-local "last-entry" rule.
removeDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> AppM (Either DomainError ())
removeDictionaryEntry userId dictId entryId = runExceptT $ do
  lift $ logInfo $ "Removing dictionary entry from " <> displayShow dictId <> " for user " <> displayShow userId
  txnRM <- lift (view transactionReadModelL)
  usageCount <- lift (findReferencingTransactions txnRM entryId)
  let inUse =
        if dictId == labelsDictId
          then LabelInUse {entryId = T.pack (show (unDictionaryEntryId entryId)), usageCount = usageCount}
          else CategoryInUse {entryId = T.pack (show (unDictionaryEntryId entryId)), usageCount = usageCount}
  guardE (usageCount == 0) inUse
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RemoveDictionaryEntryConfigurationCommand
          RemoveDictionaryEntry
            { dictionaryId = dictId,
              entryId = entryId
            }
  runConfigurationCmd defaultTranslateConfigurationError id (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry removed successfully"

-- | Set the default income category for banking imports in the user's configuration.
setBankingDefaultIncomeCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setBankingDefaultIncomeCategory userId categoryId = runExceptT $ do
  lift $ logInfo $ "Setting banking default income category for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    defaultTranslateConfigurationError
    id
    (unConfigurationId configId)
    (SetBankingDefaultIncomeCategoryConfigurationCommand SetBankingDefaultIncomeCategory {categoryId = categoryId})
  lift $ logInfo "Banking default income category set successfully"

-- | Set the default expense category for banking imports in the user's configuration.
setBankingDefaultExpenseCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setBankingDefaultExpenseCategory userId categoryId = runExceptT $ do
  lift $ logInfo $ "Setting banking default expense category for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    defaultTranslateConfigurationError
    id
    (unConfigurationId configId)
    (SetBankingDefaultExpenseCategoryConfigurationCommand SetBankingDefaultExpenseCategory {categoryId = categoryId})
  lift $ logInfo "Banking default expense category set successfully"

-- | Replace the MCC-to-expense-category map wholesale in the user's configuration.
setBankingMccExpenseCategoryMap :: UserId -> Map MCC CategoryId -> AppM (Either DomainError ())
setBankingMccExpenseCategoryMap userId mapping = runExceptT $ do
  lift $ logInfo $ "Setting banking MCC expense category map for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    defaultTranslateConfigurationError
    id
    (unConfigurationId configId)
    (SetBankingMccExpenseCategoryMapConfigurationCommand SetBankingMccExpenseCategoryMap {mapping = mapping})
  lift $ logInfo "Banking MCC expense category map set successfully"

-- | Advance the user's books-close cutoff. Both layers (service edge + aggregate)
-- enforce the strict-advance rule:
--
--   * the service-edge check is a latency-saving short-circuit that returns
--     a clean error before the configuration is cloned and the command dispatched;
--   * the aggregate-level check is authoritative under concurrent edits.
--
-- Returns the latest 'ConfigurationData' on success.
closeBooksThrough :: UserId -> UTCTime -> AppM (Either DomainError ConfigurationData)
closeBooksThrough userId newCutoff = runExceptT $ do
  lift $ logInfo $ "Closing books through " <> displayShow newCutoff <> " for user " <> displayShow userId
  -- Service-edge advance-only short-circuit. The aggregate-level check is the
  -- authoritative defence under concurrent edits; this branch just avoids a
  -- clone-on-write + dispatch when the read model already shows the request
  -- would be rejected.
  cfgBefore <- ExceptT (getConfigurationForUser userId)
  case cfgBefore.booksClosedThrough of
    Just current
      | newCutoff <= current ->
          throwE
            CannotRewindBooksCloseDate
              { current = current,
                attempted = newCutoff
              }
    _ -> pure ()
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        CloseBooksThroughConfigurationCommand
          CloseBooksThrough {closedThrough = newCutoff}
  runConfigurationCmd translateConfigurationError id (unConfigurationId configId) cmd
  lift $ logInfo "Books closed through cutoff advanced successfully"
  ExceptT (getConfigurationForUser userId)

-- | Translate an aggregate-local 'ConfigCh.ConfigurationError' (wrapped in
-- 'CommandHandlerError') into the public 'DomainError' surface.
--
-- Only 'ConfigCh.CannotRewindBooksCloseDate' has a dedicated mapping; every
-- other failure mode falls through to the generic 'ConfigurationError'
-- carrier so existing behaviour is preserved.
translateConfigurationError ::
  CommandHandlerError ConfigCh.ConfigurationError ->
  DomainError
translateConfigurationError (CommandRejected ConfigCh.CannotRewindBooksCloseDate {current = cur, attempted = att}) =
  CannotRewindBooksCloseDate {current = cur, attempted = att}
translateConfigurationError other =
  ConfigurationError (T.pack (show other))

-- | Default translator used by call sites that have no structured-error
-- payloads to preserve. Stringifies the rejection into the generic
-- 'ConfigurationError' carrier.
defaultTranslateConfigurationError ::
  CommandHandlerError ConfigCh.ConfigurationError ->
  DomainError
defaultTranslateConfigurationError err = ConfigurationError (T.pack (show err))

-- | Seed the default system configuration if it does not already exist.
--
-- Creates the default configuration with USD base/default currency,
-- and populates income and expense category dictionaries with standard entries.
--
-- Per-entry failures are logged and skipped (non-short-circuiting): seeding is
-- best-effort and a single misbehaving entry must not block the rest.
seedDefaultConfiguration :: AppM ()
seedDefaultConfiguration = do
  logInfo "Checking if default configuration needs seeding..."
  configRM <- view configurationReadModelL
  maybeConfig <- liftIO $ getConfiguration configRM defaultConfigurationId
  case maybeConfig of
    Just _ -> logInfo "Default configuration already exists, skipping seed"
    Nothing -> seedFresh

-- | Internal worker for 'seedDefaultConfiguration'. Per-entry loops here
-- intentionally do not short-circuit on failure — see the module comment.
seedFresh :: AppM ()
seedFresh = do
  logInfo "Seeding default configuration..."
  let configUuid = unConfigurationId defaultConfigurationId

  -- Create the default configuration
  let createCmd =
        CreateConfigurationConfigurationCommand
          CreateConfiguration
            { baseCurrency = USD,
              defaultCurrency = USD,
              createdBy = System
            }

  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  createResult <- liftIO $ applyConfigurationCommand writer reader id configUuid createCmd
  case createResult of
    Left err -> do
      logError $ "Failed to create default configuration: " <> displayShow err
    Right _ -> do
      logInfo "Default configuration created, adding dictionary entries..."

      -- Add income category entries
      forM_ defaultIncomeCategories $ \entry -> do
        let cmd =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryId = incomeCategoryDictId,
                    entryId = entry.entryId,
                    name = unsafeEntryName entry.entryName
                  }
        result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
        case result of
          Left err -> logWarn $ "Failed to add income category '" <> display entry.entryName <> "': " <> displayShow err
          Right _ -> return ()

      -- Add expense category entries
      forM_ defaultExpenseCategories $ \entry -> do
        let cmd =
              AddDictionaryEntryConfigurationCommand
                AddDictionaryEntry
                  { dictionaryId = expenseCategoryDictId,
                    entryId = entry.entryId,
                    name = unsafeEntryName entry.entryName
                  }
        result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
        case result of
          Left err -> logWarn $ "Failed to add expense category '" <> display entry.entryName <> "': " <> displayShow err
          Right _ -> return ()

      -- Set banking defaults
      let incomeCategoryCmd =
            SetBankingDefaultIncomeCategoryConfigurationCommand
              SetBankingDefaultIncomeCategory {categoryId = income.other.entryId}
      incomeResult <- liftIO $ applyConfigurationCommand writer reader id configUuid incomeCategoryCmd
      case incomeResult of
        Left err -> logWarn $ "Failed to set banking default income category: " <> displayShow err
        Right _ -> return ()

      let expenseCategoryCmd =
            SetBankingDefaultExpenseCategoryConfigurationCommand
              SetBankingDefaultExpenseCategory {categoryId = expense.other.entryId}
      expenseResult <- liftIO $ applyConfigurationCommand writer reader id configUuid expenseCategoryCmd
      case expenseResult of
        Left err -> logWarn $ "Failed to set banking default expense category: " <> displayShow err
        Right _ -> return ()

      let mccMapCmd =
            SetBankingMccExpenseCategoryMapConfigurationCommand
              SetBankingMccExpenseCategoryMap {mapping = defaultMccExpenseCategoryMap}
      mccResult <- liftIO $ applyConfigurationCommand writer reader id configUuid mccMapCmd
      case mccResult of
        Left err -> logWarn $ "Failed to set banking MCC expense category map: " <> displayShow err
        Right _ -> return ()

      logInfo "Default configuration seeded successfully"

-- -----------------------------------------------------------------------------
-- Clone-on-Write Helpers
-- -----------------------------------------------------------------------------

-- | Look up a user's configuration ID and data from the read models.
lookupUserConfiguration :: UserId -> AppM (Either DomainError (ConfigurationId, ConfigurationData))
lookupUserConfiguration userId = runExceptT $ do
  userData <- getUserData userId
  configRM <- lift (view configurationReadModelL)
  configData <-
    liftMaybeM
      (NotFound "Configuration" (tshow userData.configurationId))
      (liftIO $ getConfiguration configRM userData.configurationId)
  pure (userData.configurationId, configData)

-- | Ensure the user has their own cloned configuration.
--
-- Clone-on-write logic:
--   - If the configuration's createdBy is @ClonedBy thisUser _@, the user already
--     owns it; return its ID directly.
--   - Otherwise (System or ClonedBy anotherUser _), clone the configuration,
--     assign the clone to the user, and return the new ID.
ensureClonedConfiguration :: UserId -> AppM (Either DomainError ConfigurationId)
ensureClonedConfiguration userId = runExceptT $ do
  (configId, configData) <- ExceptT (lookupUserConfiguration userId)
  case configData.createdBy of
    ClonedBy ownerId _
      | ownerId == userId -> pure configId
    _ -> ExceptT (cloneConfiguration userId configId configData)

-- | Clone a configuration for a user.
--
-- Steps:
--   1. Generate new UUID for the cloned configuration
--   2. Create the new configuration with current currencies and createdBy = ClonedBy
--   3. Copy all dictionary entries from the source (best-effort; per-entry
--      failures are logged but do not abort the clone).
--   4. Copy banking defaults (best-effort; per-field failures are logged).
--   5. Assign the new configuration to the user.
cloneConfiguration :: UserId -> ConfigurationId -> ConfigurationData -> AppM (Either DomainError ConfigurationId)
cloneConfiguration userId sourceConfigId configData = runExceptT $ do
  lift $ logInfo $ "Cloning configuration " <> displayShow sourceConfigId <> " for user " <> displayShow userId
  newConfigUuid <- liftIO UUID.nextRandom
  newConfigId <-
    liftEitherWith
      (\err -> ConfigurationError ("Internal error: failed to generate configuration ID: " <> tshow err))
      (mkConfigurationId newConfigUuid)
  let newConfigUuidVal = unConfigurationId newConfigId
  runConfigurationCmd
    defaultTranslateConfigurationError
    id
    newConfigUuidVal
    ( CreateConfigurationConfigurationCommand
        CreateConfiguration
          { baseCurrency = configData.baseCurrency,
            defaultCurrency = configData.defaultCurrency,
            createdBy = ClonedBy userId sourceConfigId
          }
    )
  -- Best-effort: per-entry failures inside the next two helpers are logged
  -- but do not abort the clone. The aggregate-level CreateConfiguration above
  -- and AssignConfiguration below remain short-circuiting.
  --
  -- Note: booksClosedThrough is intentionally not propagated. It is a per-user
  -- bookkeeping decision; clones start from an open ledger.
  lift (copyDictionaries newConfigUuidVal configData.dictionaries)
  lift (copyBanking newConfigUuidVal configData.banking)
  runUserCmd
    id
    (unUserId userId)
    ( AssignConfigurationUserCommand
        AssignConfiguration {configurationId = newConfigId}
    )
  lift $ logInfo $ "Configuration cloned successfully: " <> displayShow newConfigId
  pure newConfigId

-- | Copy every dictionary entry from a source configuration's dictionaries
-- map into the freshly created clone. Per-entry failures are logged and
-- skipped — clone-on-write must succeed even when one entry fails to copy.
copyDictionaries :: UUID -> Map DictionaryId DictionaryData -> AppM ()
copyDictionaries newConfigUuidVal dictionaries = do
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  forM_ (Map.toList dictionaries) $ \(dictId, dictData) ->
    forM_ (Map.toList dictData.entries) $ \(eId, eName) -> do
      let cmd =
            AddDictionaryEntryConfigurationCommand
              AddDictionaryEntry
                { dictionaryId = dictId,
                  entryId = eId,
                  name = eName
                }
      addResult <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
      case addResult of
        Left err -> logWarn $ "Failed to clone dictionary entry: " <> displayShow err
        Right _ -> return ()

-- | Copy banking defaults (default income/expense category and MCC map) from
-- the source configuration to the clone. Per-field failures are logged and
-- skipped.
copyBanking :: UUID -> BankingConfiguration -> AppM ()
copyBanking newConfigUuidVal srcBanking = do
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  forM_ srcBanking.defaultIncomeCategory $ \eid -> do
    let cmd =
          SetBankingDefaultIncomeCategoryConfigurationCommand
            SetBankingDefaultIncomeCategory {categoryId = eid}
    copyResult <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone banking.defaultIncomeCategory: " <> displayShow err
      Right _ -> return ()

  forM_ srcBanking.defaultExpenseCategory $ \eid -> do
    let cmd =
          SetBankingDefaultExpenseCategoryConfigurationCommand
            SetBankingDefaultExpenseCategory {categoryId = eid}
    copyResult <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone banking.defaultExpenseCategory: " <> displayShow err
      Right _ -> return ()

  unless (Map.null srcBanking.mccExpenseCategoryMap) $ do
    let cmd =
          SetBankingMccExpenseCategoryMapConfigurationCommand
            SetBankingMccExpenseCategoryMap {mapping = srcBanking.mccExpenseCategoryMap}
    copyResult <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone banking.mccExpenseCategoryMap: " <> displayShow err
      Right _ -> return ()
