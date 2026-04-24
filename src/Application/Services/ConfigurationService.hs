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
    seedDefaultConfiguration,

    -- * Well-known Dictionary IDs
    incomeCategoryDictId,
    expenseCategoryDictId,
    labelsDictId,
  )
where

import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..), getConfiguration)
import Application.ReadModels.Transaction (findReferencingTransactions)
import Application.ReadModels.User (UserData (..), getUser)
import qualified Data.Map.Strict as Map
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (ChangeAccountCurrency (..))
import Domain.Configuration.CommandHandler (ConfigurationCommand (..))
import Domain.Configuration.Commands
  ( AddDictionaryEntry (..),
    ChangeBaseCurrency (..),
    ChangeDefaultCurrency (..),
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
import Infrastructure.App
  ( AppM,
    HasEventStore (..),
    HasReadModel (..),
  )
import Infrastructure.Eventium (applyAccountCommand, applyConfigurationCommand, applyUserCommand)
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
getConfigurationForUser userId = do
  logInfo $ "Getting configuration for user: " <> displayShow userId
  result <- lookupUserConfiguration userId
  case result of
    Left err -> return $ Left err
    Right (_configId, configData) -> return $ Right configData

-- | Change the base currency for a user's configuration.
--
-- Special flow:
--   1. Clone-on-write if needed
--   2. Attempt ChangeAccountCurrency on the user's External account first
--   3. If it succeeds, apply ChangeBaseCurrency on the configuration
--   4. If it fails, return error
changeBaseCurrency :: UserId -> Currency -> AppM (Either DomainError ())
changeBaseCurrency userId newCurrency = do
  logInfo $ "Changing base currency to " <> displayShow newCurrency <> " for user " <> displayShow userId

  -- Look up user data to get External account ID
  userRM <- view userReadModelL
  maybeUser <- liftIO $ getUser userRM userId
  case maybeUser of
    Nothing -> return $ Left $ NotFound "User" (tshow userId)
    Just userData -> do
      -- Ensure we have a cloned config (clone-on-write)
      cloneResult <- ensureClonedConfiguration userId
      case cloneResult of
        Left err -> return $ Left err
        Right configId -> do
          -- Step 1: Attempt ChangeAccountCurrency on External account first
          let extAccountUuid = unAccountId userData.externalAccountId
          let accountCmd = ChangeAccountCurrencyAccountCommand ChangeAccountCurrency {newCurrency = newCurrency}
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL
          accountResult <- liftIO $ applyAccountCommand writer reader id extAccountUuid accountCmd
          case accountResult of
            Left err -> do
              logError $ "ChangeAccountCurrency rejected: " <> displayShow err
              return $ Left $ AccountError (T.pack (show err))
            Right _ -> do
              -- Step 2: Apply ChangeBaseCurrency on the configuration
              let configUuid = unConfigurationId configId
              let configCmd = ChangeBaseCurrencyConfigurationCommand ChangeBaseCurrency {baseCurrency = newCurrency}
              configResult <- liftIO $ applyConfigurationCommand writer reader id configUuid configCmd
              case configResult of
                Left err -> do
                  logError $ "ChangeBaseCurrency rejected: " <> displayShow err
                  return $ Left $ ConfigurationError (T.pack (show err))
                Right _ -> do
                  logInfo "Base currency changed successfully"
                  return $ Right ()

-- | Change the default currency for a user's configuration.
changeDefaultCurrency :: UserId -> Currency -> AppM (Either DomainError ())
changeDefaultCurrency userId newCurrency = do
  logInfo $ "Changing default currency to " <> displayShow newCurrency <> " for user " <> displayShow userId

  cloneResult <- ensureClonedConfiguration userId
  case cloneResult of
    Left err -> return $ Left err
    Right configId -> do
      let configUuid = unConfigurationId configId
      let cmd = ChangeDefaultCurrencyConfigurationCommand ChangeDefaultCurrency {defaultCurrency = newCurrency}
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
      case result of
        Left err -> do
          logError $ "ChangeDefaultCurrency rejected: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          logInfo "Default currency changed successfully"
          return $ Right ()

-- | Add a new entry to a dictionary in the user's configuration.
addDictionaryEntry :: UserId -> DictionaryId -> EntryName -> AppM (Either DomainError DictionaryEntryId)
addDictionaryEntry userId dictId entryName = do
  logInfo $ "Adding dictionary entry to " <> displayShow dictId <> " for user " <> displayShow userId

  cloneResult <- ensureClonedConfiguration userId
  case cloneResult of
    Left err -> return $ Left err
    Right configId -> do
      entryUuid <- liftIO UUID.nextRandom
      let entryId = unsafeDictionaryEntryId entryUuid
      let configUuid = unConfigurationId configId
      let cmd =
            AddDictionaryEntryConfigurationCommand
              AddDictionaryEntry
                { dictionaryId = dictId,
                  entryId = entryId,
                  name = entryName
                }
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
      case result of
        Left err -> do
          logError $ "AddDictionaryEntry rejected: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          logInfo "Dictionary entry added successfully"
          return $ Right entryId

-- | Rename an entry in a dictionary in the user's configuration.
renameDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> EntryName -> AppM (Either DomainError ())
renameDictionaryEntry userId dictId entryId newName = do
  logInfo $ "Renaming dictionary entry in " <> displayShow dictId <> " for user " <> displayShow userId

  cloneResult <- ensureClonedConfiguration userId
  case cloneResult of
    Left err -> return $ Left err
    Right configId -> do
      let configUuid = unConfigurationId configId
      let cmd =
            RenameDictionaryEntryConfigurationCommand
              RenameDictionaryEntry
                { dictionaryId = dictId,
                  entryId = entryId,
                  newName = newName
                }
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
      case result of
        Left err -> do
          logError $ "RenameDictionaryEntry rejected: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          logInfo "Dictionary entry renamed successfully"
          return $ Right ()

-- | Remove an entry from a dictionary in the user's configuration.
--
-- Refuses with 'LabelInUse' or 'CategoryInUse' when any transaction still
-- references the entry (either via its labels set or via the categorised
-- 'TransferType'). The check is performed at the service layer because it
-- depends on the transaction read model; the pure configuration command
-- handler enforces only the aggregate-local "last-entry" rule.
removeDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> AppM (Either DomainError ())
removeDictionaryEntry userId dictId entryId = do
  logInfo $ "Removing dictionary entry from " <> displayShow dictId <> " for user " <> displayShow userId

  txnRM <- view transactionReadModelL
  usageCount <- findReferencingTransactions txnRM entryId
  if usageCount > 0
    then do
      let eidText = T.pack (show (unDictionaryEntryId entryId))
          err
            | dictId == labelsDictId =
                LabelInUse {entryId = eidText, usageCount = usageCount}
            | otherwise =
                CategoryInUse {entryId = eidText, usageCount = usageCount}
      logWarn
        $ "Refusing to remove dictionary entry: "
        <> display usageCount
        <> " transaction(s) still reference it"
      return $ Left err
    else do
      cloneResult <- ensureClonedConfiguration userId
      case cloneResult of
        Left err -> return $ Left err
        Right configId -> do
          let configUuid = unConfigurationId configId
          let cmd =
                RemoveDictionaryEntryConfigurationCommand
                  RemoveDictionaryEntry
                    { dictionaryId = dictId,
                      entryId = entryId
                    }
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL
          result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
          case result of
            Left err -> do
              logError $ "RemoveDictionaryEntry rejected: " <> displayShow err
              return $ Left $ ConfigurationError (T.pack (show err))
            Right _ -> do
              logInfo "Dictionary entry removed successfully"
              return $ Right ()

-- | Set the default income category for banking imports in the user's configuration.
setBankingDefaultIncomeCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setBankingDefaultIncomeCategory userId categoryId = do
  logInfo $ "Setting banking default income category for user " <> displayShow userId

  cloneResult <- ensureClonedConfiguration userId
  case cloneResult of
    Left err -> return $ Left err
    Right configId -> do
      let configUuid = unConfigurationId configId
      let cmd = SetBankingDefaultIncomeCategoryConfigurationCommand SetBankingDefaultIncomeCategory {categoryId = categoryId}
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
      case result of
        Left err -> do
          logError $ "SetBankingDefaultIncomeCategory rejected: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          logInfo "Banking default income category set successfully"
          return $ Right ()

-- | Set the default expense category for banking imports in the user's configuration.
setBankingDefaultExpenseCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setBankingDefaultExpenseCategory userId categoryId = do
  logInfo $ "Setting banking default expense category for user " <> displayShow userId

  cloneResult <- ensureClonedConfiguration userId
  case cloneResult of
    Left err -> return $ Left err
    Right configId -> do
      let configUuid = unConfigurationId configId
      let cmd = SetBankingDefaultExpenseCategoryConfigurationCommand SetBankingDefaultExpenseCategory {categoryId = categoryId}
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
      case result of
        Left err -> do
          logError $ "SetBankingDefaultExpenseCategory rejected: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          logInfo "Banking default expense category set successfully"
          return $ Right ()

-- | Replace the MCC-to-expense-category map wholesale in the user's configuration.
setBankingMccExpenseCategoryMap :: UserId -> Map MCC CategoryId -> AppM (Either DomainError ())
setBankingMccExpenseCategoryMap userId mapping = do
  logInfo $ "Setting banking MCC expense category map for user " <> displayShow userId

  cloneResult <- ensureClonedConfiguration userId
  case cloneResult of
    Left err -> return $ Left err
    Right configId -> do
      let configUuid = unConfigurationId configId
      let cmd = SetBankingMccExpenseCategoryMapConfigurationCommand SetBankingMccExpenseCategoryMap {mapping = mapping}
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
      case result of
        Left err -> do
          logError $ "SetBankingMccExpenseCategoryMap rejected: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          logInfo "Banking MCC expense category map set successfully"
          return $ Right ()

-- | Seed the default system configuration if it does not already exist.
--
-- Creates the default configuration with USD base/default currency,
-- and populates income and expense category dictionaries with standard entries.
seedDefaultConfiguration :: AppM ()
seedDefaultConfiguration = do
  logInfo "Checking if default configuration needs seeding..."

  configRM <- view configurationReadModelL
  maybeConfig <- liftIO $ getConfiguration configRM defaultConfigurationId
  case maybeConfig of
    Just _ -> do
      logInfo "Default configuration already exists, skipping seed"
    Nothing -> do
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
lookupUserConfiguration userId = do
  userRM <- view userReadModelL
  maybeUser <- liftIO $ getUser userRM userId
  case maybeUser of
    Nothing -> return $ Left $ NotFound "User" (tshow userId)
    Just userData -> do
      configRM <- view configurationReadModelL
      maybeConfig <- liftIO $ getConfiguration configRM userData.configurationId
      case maybeConfig of
        Nothing -> return $ Left $ NotFound "Configuration" (tshow userData.configurationId)
        Just configData -> return $ Right (userData.configurationId, configData)

-- | Ensure the user has their own cloned configuration.
--
-- Clone-on-write logic:
--   - If the configuration's createdBy is @ClonedBy thisUser _@, the user already
--     owns it; return its ID directly.
--   - Otherwise (System or ClonedBy anotherUser _), clone the configuration,
--     assign the clone to the user, and return the new ID.
ensureClonedConfiguration :: UserId -> AppM (Either DomainError ConfigurationId)
ensureClonedConfiguration userId = do
  lookupResult <- lookupUserConfiguration userId
  case lookupResult of
    Left err -> return $ Left err
    Right (configId, configData) ->
      case configData.createdBy of
        ClonedBy ownerId _
          | ownerId == userId -> do
              -- User already owns this configuration
              return $ Right configId
        _ -> do
          -- Need to clone
          cloneConfiguration userId configId configData

-- | Clone a configuration for a user.
--
-- Steps:
--   1. Generate new UUID for the cloned configuration
--   2. Create the new configuration with current currencies and createdBy = ClonedBy
--   3. Copy all dictionary entries from the source
--   4. Assign the new configuration to the user
cloneConfiguration :: UserId -> ConfigurationId -> ConfigurationData -> AppM (Either DomainError ConfigurationId)
cloneConfiguration userId sourceConfigId configData = do
  logInfo $ "Cloning configuration " <> displayShow sourceConfigId <> " for user " <> displayShow userId

  -- 1. Generate new configuration ID
  newConfigUuid <- liftIO UUID.nextRandom
  case mkConfigurationId newConfigUuid of
    Left err -> do
      logError $ "Failed to create ConfigurationId: " <> display err
      return $ Left $ ConfigurationError "Internal error: failed to generate configuration ID"
    Right newConfigId -> do
      let newConfigUuidVal = unConfigurationId newConfigId

      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL

      -- 2. Create the new configuration
      let createCmd =
            CreateConfigurationConfigurationCommand
              CreateConfiguration
                { baseCurrency = configData.baseCurrency,
                  defaultCurrency = configData.defaultCurrency,
                  createdBy = ClonedBy userId sourceConfigId
                }
      createResult <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal createCmd
      case createResult of
        Left err -> do
          logError $ "Failed to create cloned configuration: " <> displayShow err
          return $ Left $ ConfigurationError (T.pack (show err))
        Right _ -> do
          -- 3. Copy all dictionary entries
          let dictEntries = Map.toList configData.dictionaries
          forM_ dictEntries $ \(dictId, dictData) -> do
            let entries = Map.toList dictData.entries
            forM_ entries $ \(eId, eName) -> do
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

          -- 3b. Copy banking configuration
          let srcBanking = configData.banking
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

          -- 4. Assign the new configuration to the user via User aggregate
          let userUuid = unUserId userId
          let assignCmd =
                AssignConfigurationUserCommand
                  AssignConfiguration
                    { configurationId = newConfigId
                    }
          assignResult <- liftIO $ applyUserCommand writer reader id userUuid assignCmd
          case assignResult of
            Left err -> do
              logError $ "Failed to assign configuration to user: " <> displayShow err
              return $ Left $ UserError (T.pack (show err))
            Right _ -> do
              logInfo $ "Configuration cloned successfully: " <> displayShow newConfigId
              return $ Right newConfigId
