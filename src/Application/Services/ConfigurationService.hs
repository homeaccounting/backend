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
    moveDictionaryEntry,
    setDefaultIncomeCategory,
    setDefaultExpenseCategory,
    setDefaultAccount,
    setDefaultSubtypeAccounts,
    setBankProviderExpenseCategoryMap,
    addBankConnection,
    renameBankConnection,
    changeBankConnectionCredential,
    setBankConnectionEnabled,
    setBankConnectionAccountMap,
    removeBankConnection,
    getDecryptedConnectionCredential,
    getConnectionProvider,
    getConnectionFileImport,
    closeBooksThrough,
    seedDefaultConfiguration,

    -- * Well-known Dictionary Kinds
    incomeCategoryDictKind,
    expenseCategoryDictKind,
    labelsDictKind,
    contactsDictKind,
  )
where

import Application.ReadModels.Account (AccountData (..), getAccounts)
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..), dictionaryEntriesParentFirst, getConfiguration)
import Application.ReadModels.Transaction (findReferencingTransactions)
import Application.ReadModels.User (UserData (..))
import Application.Services.AuthorizationService (AccountAuthData (..), canModifyAccount)
import Application.Services.Internal
  ( getUserData,
    getUserExternalAccountId,
    guardE,
    liftEitherWith,
    liftMaybeM,
    runAccountCmd,
    runConfigurationCmd,
    runUserCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (eitherDecode)
import Data.Aeson.Text (encodeToLazyText)
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy as TL
import Data.Time (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (ChangeAccountCurrency (..))
import Domain.Banking.Types
  ( BankConnectionId,
    BankConnectionName,
    BankProviderCredential (..),
    ExternalAccountId,
    unBankProviderId,
    unsafeBankConnectionId,
  )
import qualified Domain.Banking.Types as Domain
import Domain.Configuration.CommandHandler (ConfigurationCommand (..))
import qualified Domain.Configuration.CommandHandler as ConfigCh
import Domain.Configuration.Commands
  ( AddBankConnection (..),
    AddDictionaryEntry (..),
    ChangeBankConnectionCredential (..),
    ChangeBaseCurrency (..),
    ChangeDefaultCurrency (..),
    CloseBooksThrough (..),
    CreateConfiguration (..),
    MoveDictionaryEntry (..),
    RemoveBankConnection (..),
    RemoveDictionaryEntry (..),
    RenameBankConnection (..),
    RenameDictionaryEntry (..),
    SetBankConnectionAccountMap (..),
    SetBankConnectionEnabled (..),
    SetBankProviderExpenseCategoryMap (..),
    SetDefaultAccount (..),
    SetDefaultExpenseCategory (..),
    SetDefaultIncomeCategory (..),
    SetDefaultSubtypeAccounts (..),
  )
import Domain.Configuration.Defaults
  ( DefaultEntry (..),
    ExpenseDefaults (other),
    IncomeDefaults (other),
    defaultExpenseCategories,
    defaultIncomeCategories,
    expense,
    expenseCategoryDictKind,
    income,
    incomeCategoryDictKind,
  )
import Domain.Configuration.Dictionary (DictionaryKind (..), EntryRole)
import Domain.Configuration.Projection
  ( BankConnection (..),
    BankingConfiguration (bankProviderExpenseCategoryMap, connections),
    ConfigurationDefaults (..),
  )
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountId,
    AccountRole (..),
    AccountSubtypeKind,
    BankProviderCategory,
    CategoryId,
    ConfigurationId,
    CreatedBy (..),
    Currency (..),
    DictionaryEntryId,
    EntryName,
    UserId,
    defaultConfigurationId,
    isRegular,
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
    HasBankProviderRegistry (..),
    HasBankingKeyRing (..),
    HasEventStore (..),
    HasRequestContext (..),
    runDb,
  )
import Infrastructure.Banking.CategoryDefaults (defaultBankProviderExpenseCategoryMap)
import Infrastructure.Banking.Provider
  ( BankProviderDescriptor (..),
    FileImportCapability,
    PullCapability,
    TransactionInterpretation,
    providerSupportsPull,
  )
import Infrastructure.Banking.Registry (lookupProvider)
import Infrastructure.Crypto.SecretBox (decryptSecret, encryptSecret)
import Infrastructure.Eventium (applyConfigurationCommand)
import Infrastructure.Observability.Context (enricherFromContext)
import RIO
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Well-known Dictionary Kinds
-- -----------------------------------------------------------------------------

-- | Dictionary kind for transaction labels (optional, multi-valued per txn).
labelsDictKind :: DictionaryKind
labelsDictKind = LabelKind

-- | Dictionary kind for transaction contacts (counterparties).
contactsDictKind :: DictionaryKind
contactsDictKind = ContactKind

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
  externalAccId <- getUserExternalAccountId userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runAccountCmd
    (unAccountId externalAccId)
    (ChangeAccountCurrencyAccountCommand ChangeAccountCurrency {newCurrency = newCurrency})
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (ChangeBaseCurrencyConfigurationCommand ChangeBaseCurrency {baseCurrency = newCurrency})
  lift $ logInfo "Base currency changed successfully"

-- | Change the default currency for a user's configuration.
changeDefaultCurrency :: UserId -> Currency -> AppM (Either DomainError ())
changeDefaultCurrency userId newCurrency = runExceptT $ do
  lift $ logInfo $ "Changing default currency to " <> displayShow newCurrency <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (ChangeDefaultCurrencyConfigurationCommand ChangeDefaultCurrency {defaultCurrency = newCurrency})
  lift $ logInfo "Default currency changed successfully"

-- | Add a new entry to a dictionary in the user's configuration.
addDictionaryEntry :: UserId -> DictionaryKind -> EntryName -> EntryRole -> Maybe DictionaryEntryId -> AppM (Either DomainError DictionaryEntryId)
addDictionaryEntry userId dictKind entryName role parentId = runExceptT $ do
  lift $ logInfo $ "Adding dictionary entry to " <> displayShow dictKind <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  entryUuid <- liftIO UUID.nextRandom
  let entryId = unsafeDictionaryEntryId entryUuid
      cmd =
        AddDictionaryEntryConfigurationCommand
          AddDictionaryEntry
            { dictionaryKind = dictKind,
              entryId = entryId,
              name = entryName,
              role = role,
              parentId = parentId
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry added successfully"
  pure entryId

-- | Rename an entry in a dictionary in the user's configuration.
renameDictionaryEntry :: UserId -> DictionaryKind -> DictionaryEntryId -> EntryName -> AppM (Either DomainError ())
renameDictionaryEntry userId dictKind entryId newName = runExceptT $ do
  lift $ logInfo $ "Renaming dictionary entry in " <> displayShow dictKind <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RenameDictionaryEntryConfigurationCommand
          RenameDictionaryEntry
            { dictionaryKind = dictKind,
              entryId = entryId,
              newName = newName
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry renamed successfully"

-- | Remove an entry from a dictionary in the user's configuration.
--
-- Refuses with 'LabelInUse', 'CategoryInUse', or 'ContactInUse' when any
-- transaction still references the entry (via its labels set, its
-- categorised 'TransactionType', or its contact). The check is performed at
-- the service layer because it depends on the transaction read model; the
-- pure configuration command handler enforces only the aggregate-local
-- "last-entry" rule.
removeDictionaryEntry :: UserId -> DictionaryKind -> DictionaryEntryId -> AppM (Either DomainError ())
removeDictionaryEntry userId dictKind entryId = runExceptT $ do
  lift $ logInfo $ "Removing dictionary entry from " <> displayShow dictKind <> " for user " <> displayShow userId
  usageCount <- lift (runDb (findReferencingTransactions entryId))
  let eidText = T.pack (show (unDictionaryEntryId entryId))
      -- Exhaustive over 'DictionaryKind' (not an if/else on 'labelsDictKind')
      -- so a future kind fails to compile here rather than silently falling
      -- through to 'CategoryInUse'.
      inUse = case dictKind of
        LabelKind -> LabelInUse {entryId = eidText, usageCount = usageCount}
        ContactKind -> ContactInUse {entryId = eidText, usageCount = usageCount}
        IncomeKind -> CategoryInUse {entryId = eidText, usageCount = usageCount}
        ExpenseKind -> CategoryInUse {entryId = eidText, usageCount = usageCount}
  guardE (usageCount == 0) inUse
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RemoveDictionaryEntryConfigurationCommand
          RemoveDictionaryEntry
            { dictionaryKind = dictKind,
              entryId = entryId
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry removed successfully"

-- | Move a dictionary entry to a new parent group (or to the root when
-- @newParentId@ is 'Nothing').
--
-- The pure command handler enforces the full tree invariants (the target
-- parent exists, the move is cycle-free, the subtree stays within the depth
-- limit, and the moved name is unique among its new siblings); this service
-- function only clones-on-write and dispatches the command.
moveDictionaryEntry :: UserId -> DictionaryKind -> DictionaryEntryId -> Maybe DictionaryEntryId -> AppM (Either DomainError ())
moveDictionaryEntry userId dictKind entryId newParentId = runExceptT $ do
  lift $ logInfo $ "Moving dictionary entry in " <> displayShow dictKind <> " for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        MoveDictionaryEntryConfigurationCommand
          MoveDictionaryEntry
            { dictionaryKind = dictKind,
              entryId = entryId,
              newParentId = newParentId
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Dictionary entry moved successfully"

-- | Set the global default income category in the user's configuration.
setDefaultIncomeCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setDefaultIncomeCategory userId categoryId = runExceptT $ do
  lift $ logInfo $ "Setting default income category for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (SetDefaultIncomeCategoryConfigurationCommand SetDefaultIncomeCategory {categoryId = categoryId})
  lift $ logInfo "Default income category set successfully"

-- | Set the global default expense category in the user's configuration.
setDefaultExpenseCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setDefaultExpenseCategory userId categoryId = runExceptT $ do
  lift $ logInfo $ "Setting default expense category for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (SetDefaultExpenseCategoryConfigurationCommand SetDefaultExpenseCategory {categoryId = categoryId})
  lift $ logInfo "Default expense category set successfully"

-- | Reject unless every 'AccountId' is a __Regular__ account the user can write
-- to. Cross-aggregate validation lives here, not in the pure command handler
-- (which has no account view). The write-access decision is delegated to
-- 'canModifyAccount' (the same auth check the transaction write-path uses); the
-- extra "must be Regular" rule (default accounts must never point at the
-- system-managed External account) is composed on top. On any invalid target
-- the whole request is rejected with a @ValidationErr@.
validateOwnedRegularAccounts :: UserId -> Text -> [AccountId] -> ExceptT DomainError AppM ()
validateOwnedRegularAccounts userId field targets = do
  accessible <- lift (runDb (getAccounts userId))
  let writable =
        Set.fromList
          [ accId
          | (accId, accData, _role) <- accessible,
            isRegular accData.accountType,
            canModifyAccount userId (toAuthData accData)
          ]
  unless (all (`Set.member` writable) targets)
    $ throwE (ValidationErr (mkValidationError field "account is not an owned regular account" ""))
  where
    toAuthData d =
      AccountAuthData
        { createdBy = d.createdBy,
          accountType = d.accountType,
          accessList = d.accessList
        }

-- | Set the global default account in the user's configuration. The target must
-- be a Regular account the user owns/edits.
setDefaultAccount :: UserId -> AccountId -> AppM (Either DomainError ())
setDefaultAccount userId accountId = runExceptT $ do
  lift $ logInfo $ "Setting default account for user " <> displayShow userId
  validateOwnedRegularAccounts userId "account" [accountId]
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (SetDefaultAccountConfigurationCommand SetDefaultAccount {accountId = accountId})
  lift $ logInfo "Default account set successfully"

-- | Replace the per-subtype default-account map wholesale. Every target account
-- must be a Regular account the user owns/edits.
setDefaultSubtypeAccounts :: UserId -> Map AccountSubtypeKind AccountId -> AppM (Either DomainError ())
setDefaultSubtypeAccounts userId mapping = runExceptT $ do
  lift $ logInfo $ "Setting default subtype accounts for user " <> displayShow userId
  validateOwnedRegularAccounts userId "subtypeAccounts" (Map.elems mapping)
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (SetDefaultSubtypeAccountsConfigurationCommand SetDefaultSubtypeAccounts {subtypeAccounts = mapping})
  lift $ logInfo "Default subtype accounts set successfully"

-- | Replace the provider-category-to-expense-category map wholesale in the
-- user's configuration.
setBankProviderExpenseCategoryMap :: UserId -> Map BankProviderCategory CategoryId -> AppM (Either DomainError ())
setBankProviderExpenseCategoryMap userId mapping = runExceptT $ do
  lift $ logInfo $ "Setting banking provider-category map for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (SetBankProviderExpenseCategoryMapConfigurationCommand SetBankProviderExpenseCategoryMap {mapping = mapping})
  lift $ logInfo "Banking provider-category map set successfully"

-- -----------------------------------------------------------------------------
-- Bank Connections
-- -----------------------------------------------------------------------------

-- | Compute the non-secret hint from a decrypted credential: for a
-- 'StaticSecret', the last (up to) four characters of the plaintext secret,
-- used so the user can recognise a stored credential.
secretHintOf :: BankProviderCredential -> Text
secretHintOf (StaticSecret t) = T.takeEnd 4 t

-- | Encode a 'BankProviderCredential' to the JSON 'Text' that gets encrypted at
-- rest (via 'encryptSecret'). The persisted 'EncryptedSecret' therefore
-- carries the credential's tagged JSON, not the credential's shape directly —
-- see "Domain.Banking.Types" for why this keeps the event schema unchanged.
encodeCredential :: BankProviderCredential -> Text
-- 'encodeToLazyText' yields JSON as 'Text' directly — total, no partial UTF-8
-- decode (unlike 'Data.Text.Encoding.decodeUtf8').
encodeCredential = TL.toStrict . encodeToLazyText

-- | Decode a decrypted credential JSON 'Text' back into a 'BankProviderCredential'.
-- Total: a decode failure is reported as 'Left', never a partial function.
decodeCredential :: Text -> Either Text BankProviderCredential
decodeCredential plaintext =
  case eitherDecode (BSL.fromStrict (TE.encodeUtf8 plaintext)) of
    Left err -> Left (T.pack err)
    Right cred -> Right cred

-- | Add a new bank connection to the user's configuration.
--
-- Encrypts the credential's JSON encoding in the service layer (only
-- ciphertext enters the event log), generates a fresh 'BankConnectionId',
-- computes a token hint, and emits 'AddBankConnection'. The connection starts
-- with an empty account map.
--
-- The credential is OPTIONAL: 'Nothing' is stored verbatim (no encryption
-- attempted) for a connection to a provider with no pull/API transport (e.g. a
-- file-only provider). Whether a token is actually required for the chosen
-- provider is decided by the caller (the web handler, which has access to the
-- provider registry) — this function stores whatever it is given.
addBankConnection ::
  UserId ->
  Domain.BankProviderId ->
  -- | Display name
  BankConnectionName ->
  -- | Provider credential, if any (its JSON encoding is encrypted before it
  -- leaves this function; 'Nothing' for a connection with no credential)
  Maybe BankProviderCredential ->
  -- | Whether the connection is enabled for syncing
  Bool ->
  AppM (Either DomainError BankConnectionId)
addBankConnection userId provider name mCred enabled = runExceptT $ do
  lift $ logInfo $ "Adding bank connection for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  connUuid <- liftIO UUID.nextRandom
  let connId = unsafeBankConnectionId connUuid
  (mEnc, mHint) <- case mCred of
    Nothing -> pure (Nothing, Nothing)
    Just cred -> do
      ring <- lift (view bankingKeyRingL)
      enc <- liftIO (encryptSecret ring (encodeCredential cred))
      pure (Just enc, Just (secretHintOf cred))
  let cmd =
        AddBankConnectionConfigurationCommand
          AddBankConnection
            { connectionId = connId,
              provider = provider,
              name = name,
              encryptedSecret = mEnc,
              secretHint = mHint,
              enabled = enabled
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Bank connection added successfully"
  pure connId

-- | Rename an existing bank connection.
renameBankConnection :: UserId -> BankConnectionId -> BankConnectionName -> AppM (Either DomainError ())
renameBankConnection userId connId newName = runExceptT $ do
  lift $ logInfo $ "Renaming bank connection for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RenameBankConnectionConfigurationCommand
          RenameBankConnection
            { connectionId = connId,
              name = newName
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Bank connection renamed successfully"

-- | Replace an existing bank connection's credential. The new credential's
-- JSON encoding is re-encrypted in the service layer and a fresh hint is
-- computed.
--
-- Rejected with 'BankingError' when the connection's provider has no pull/API
-- transport: a file-only connection has no credential to change.
changeBankConnectionCredential :: UserId -> BankConnectionId -> BankProviderCredential -> AppM (Either DomainError ())
changeBankConnectionCredential userId connId cred = runExceptT $ do
  lift $ logInfo $ "Changing bank connection credential for user " <> displayShow userId
  configData <- ExceptT (getConfigurationForUser userId)
  conn <-
    maybe
      (throwE BankConnectionNotFound)
      pure
      (Map.lookup connId configData.banking.connections)
  reg <- lift (view bankProviderRegistryL)
  case lookupProvider conn.provider reg of
    Just desc | providerSupportsPull desc -> pure ()
    _ -> throwE (BankingError ("Bank connection's provider has no pull transport, so it has no credential to change: " <> unBankProviderId conn.provider))
  configId <- ExceptT (ensureClonedConfiguration userId)
  ring <- lift (view bankingKeyRingL)
  enc <- liftIO (encryptSecret ring (encodeCredential cred))
  let cmd =
        ChangeBankConnectionCredentialConfigurationCommand
          ChangeBankConnectionCredential
            { connectionId = connId,
              encryptedSecret = enc,
              secretHint = secretHintOf cred
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Bank connection credential changed successfully"

-- | Enable or disable an existing bank connection.
setBankConnectionEnabled :: UserId -> BankConnectionId -> Bool -> AppM (Either DomainError ())
setBankConnectionEnabled userId connId enabled = runExceptT $ do
  lift $ logInfo $ "Setting bank connection enabled flag for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        SetBankConnectionEnabledConfigurationCommand
          SetBankConnectionEnabled
            { connectionId = connId,
              enabled = enabled
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Bank connection enabled flag set successfully"

-- | Remove an existing bank connection.
removeBankConnection :: UserId -> BankConnectionId -> AppM (Either DomainError ())
removeBankConnection userId connId = runExceptT $ do
  lift $ logInfo $ "Removing bank connection for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        RemoveBankConnectionConfigurationCommand
          RemoveBankConnection
            { connectionId = connId
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Bank connection removed successfully"

-- | Replace a bank connection's external-account map wholesale.
--
-- Cross-aggregate validation lives here (not in the pure handler): every target
-- 'AccountId' must exist and be accessible to the user with an 'Owner' or
-- 'Editor' role, so bank imports never write to an account the user cannot
-- write to (or one that is read-only shared). On any failure the whole map is
-- rejected with 'BankConnectionAccountInvalid "accountMap"'.
--
-- Within-config uniqueness (an account already mapped by a different
-- connection) is enforced by the command handler and surfaces as
-- 'BankConnectionAccountConflict'.
setBankConnectionAccountMap ::
  UserId ->
  BankConnectionId ->
  Map ExternalAccountId AccountId ->
  AppM (Either DomainError ())
setBankConnectionAccountMap userId connId accountMap = runExceptT $ do
  lift $ logInfo $ "Setting bank connection account map for user " <> displayShow userId
  -- Cross-aggregate validation against the account read model BEFORE issuing the
  -- command. The user must own/edit every target account.
  accessible <- lift (runDb (getAccounts userId))
  let writable =
        [ accId
        | (accId, _accData, role) <- accessible,
          role == Owner || role == Editor
        ]
      writableSet = Set.fromList writable
      targets = Map.elems accountMap
  unless (all (`Set.member` writableSet) targets)
    $ throwE (BankConnectionAccountInvalid "accountMap")
  configId <- ExceptT (ensureClonedConfiguration userId)
  let cmd =
        SetBankConnectionAccountMapConfigurationCommand
          SetBankConnectionAccountMap
            { connectionId = connId,
              accountMap = accountMap
            }
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Bank connection account map set successfully"

-- | Load a user's configuration, find the named connection, and decrypt its
-- stored credential. Used by the external-accounts and resync endpoints
-- (Tasks 8/9).
--
-- Returns 'BankConnectionNotFound' when the connection is absent, a
-- 'BankingError' when the connection has no stored credential (a file-only
-- connection), a 'BankingError' when decryption fails (a
-- misconfigured/rotated key ring), and a 'BankingError' when the decrypted
-- plaintext fails to decode as a 'BankProviderCredential' (should not happen
-- under no-backcompat, but handled totally — no partial functions).
getDecryptedConnectionCredential :: UserId -> BankConnectionId -> AppM (Either DomainError BankProviderCredential)
getDecryptedConnectionCredential userId connId = runExceptT $ do
  configData <- ExceptT (getConfigurationForUser userId)
  conn <-
    maybe
      (throwE BankConnectionNotFound)
      pure
      (Map.lookup connId configData.banking.connections)
  enc <-
    maybe
      (throwE (BankingError "Bank connection has no stored credential"))
      pure
      conn.encryptedSecret
  ring <- lift (view bankingKeyRingL)
  plaintext <- case decryptSecret ring enc of
    Left err -> throwE (BankingError ("Failed to decrypt connection credential: " <> tshow err))
    Right pt -> pure pt
  case decodeCredential plaintext of
    Left err -> throwE (BankingError ("Failed to decode connection credential: " <> err))
    Right cred -> pure cred

-- | Resolve a user's stored bank connection into a ready-to-use pull pair:
-- the provider's 'TransactionInterpretation' (classify direction + transfer
-- matcher) and a 'PullCapability' built from the decrypted token.
--
-- Loads the connection by id ('BankConnectionNotFound' when absent), decrypts
-- its stored token, looks the connection's provider descriptor up in the
-- injected 'bankProviderRegistryL' (a 'BankingError' when the provider is not
-- available in this deployment or has no live pull transport), and applies the
-- descriptor's pull constructor to the token. Callers — in particular the
-- banking HTTP handlers — never touch app config or a concrete provider
-- implementation.
getConnectionProvider ::
  UserId ->
  BankConnectionId ->
  AppM (Either DomainError (TransactionInterpretation, PullCapability))
getConnectionProvider userId connId = runExceptT $ do
  configData <- ExceptT (getConfigurationForUser userId)
  conn <-
    maybe
      (throwE BankConnectionNotFound)
      pure
      (Map.lookup connId configData.banking.connections)
  reg <- lift (view bankProviderRegistryL)
  desc <-
    maybe
      (throwE (BankingError ("Bank provider not available: " <> unBankProviderId conn.provider)))
      pure
      (lookupProvider conn.provider reg)
  -- Check the pull transport before decrypting the token so a file-only
  -- (token-less) connection reports the actionable "no pull transport" cause
  -- rather than "no stored token".
  mkPull <-
    maybe
      (throwE (BankingError ("Bank provider has no pull transport: " <> unBankProviderId conn.provider)))
      pure
      desc.pull
  cred <- ExceptT (getDecryptedConnectionCredential userId connId)
  pure (desc.interpretation, mkPull cred)

-- | Resolve a user's stored bank connection into a ready-to-use file-import
-- pair: the provider's 'TransactionInterpretation' (classify direction +
-- transfer matcher) and its 'FileImportCapability' (the format-keyed statement
-- parsers).
--
-- Loads the connection by id ('BankConnectionNotFound' when absent), looks
-- the connection's provider descriptor up in the injected
-- 'bankProviderRegistryL' (a 'BankingError' when the provider is not
-- available in this deployment or has no file-import transport). Unlike
-- 'getConnectionProvider', no token is required or decrypted here: a
-- file-import provider needs no credential, so a token-less (file-only)
-- connection resolves fine.
getConnectionFileImport ::
  UserId ->
  BankConnectionId ->
  AppM (Either DomainError (TransactionInterpretation, FileImportCapability))
getConnectionFileImport userId connId = runExceptT $ do
  configData <- ExceptT (getConfigurationForUser userId)
  conn <-
    maybe
      (throwE BankConnectionNotFound)
      pure
      (Map.lookup connId configData.banking.connections)
  reg <- lift (view bankProviderRegistryL)
  desc <-
    maybe
      (throwE (BankingError ("Bank provider not available: " <> unBankProviderId conn.provider)))
      pure
      (lookupProvider conn.provider reg)
  cap <-
    maybe
      (throwE (BankingError ("Bank provider has no file-import transport: " <> unBankProviderId conn.provider)))
      pure
      desc.fileImport
  pure (desc.interpretation, cap)

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
  runConfigurationCmd translateConfigurationError (unConfigurationId configId) cmd
  lift $ logInfo "Books closed through cutoff advanced successfully"
  ExceptT (getConfigurationForUser userId)

-- | Translate an aggregate-local 'ConfigCh.ConfigurationError' (wrapped in
-- 'CommandHandlerError') into the public 'DomainError' surface.
--
-- Only 'ConfigCh.CannotRewindBooksCloseDate' has a dedicated mapping; every
-- other failure mode falls through to the generic 'ConfigurationError'
-- carrier so existing behaviour is preserved.
--
-- Dictionary-tree rejections are mapped to meaningful public errors so the HTTP
-- layer returns sensible codes:
--
--   * 'ConfigCh.ParentEntryNotFound', 'ConfigCh.ParentNotAGroup',
--     'ConfigCh.MoveWouldCreateCycle', and 'ConfigCh.MaxDepthExceeded' are
--     bad-request rejections (the client asked for an impossible tree shape) and
--     surface as a 400-class 'ConfigurationError'.
--   * 'ConfigCh.GroupNotEmpty' is a conflict with the current tree state (the
--     group still has children) and surfaces as the 409-class
--     'DictionaryGroupNotEmpty'.
--
-- Any other rejection falls through to the generic 'ConfigurationError' carrier.
translateConfigurationError ::
  CommandHandlerError ConfigCh.ConfigurationError ->
  DomainError
translateConfigurationError (CommandRejected ConfigCh.CannotRewindBooksCloseDate {current = cur, attempted = att}) =
  CannotRewindBooksCloseDate {current = cur, attempted = att}
translateConfigurationError (CommandRejected ConfigCh.BankConnectionNotFound) =
  BankConnectionNotFound
translateConfigurationError (CommandRejected ConfigCh.BankConnectionAccountConflict) =
  BankConnectionAccountConflict
translateConfigurationError (CommandRejected ConfigCh.ParentEntryNotFound) =
  ConfigurationError "The specified parent entry does not exist"
translateConfigurationError (CommandRejected ConfigCh.ParentNotAGroup) =
  ConfigurationError "The specified parent is not a group; only groups can contain entries"
translateConfigurationError (CommandRejected ConfigCh.MoveWouldCreateCycle) =
  ConfigurationError "Moving this entry under the target would create a cycle in the dictionary tree"
translateConfigurationError (CommandRejected ConfigCh.MaxDepthExceeded) =
  ConfigurationError
    ("Dictionary nesting would exceed the maximum depth of " <> tshow ConfigCh.maxDictionaryDepth)
translateConfigurationError (CommandRejected ConfigCh.GroupNotEmpty) =
  DictionaryGroupNotEmpty
translateConfigurationError other =
  ConfigurationError (T.pack (show other))

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
  maybeConfig <- runDb (getConfiguration defaultConfigurationId)
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
                  { dictionaryKind = incomeCategoryDictKind,
                    entryId = entry.entryId,
                    name = unsafeEntryName entry.entryName,
                    role = entry.role,
                    parentId = entry.parentId
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
                  { dictionaryKind = expenseCategoryDictKind,
                    entryId = entry.entryId,
                    name = unsafeEntryName entry.entryName,
                    role = entry.role,
                    parentId = entry.parentId
                  }
        result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
        case result of
          Left err -> logWarn $ "Failed to add expense category '" <> display entry.entryName <> "': " <> displayShow err
          Right _ -> return ()

      -- Set global defaults
      let incomeCategoryCmd =
            SetDefaultIncomeCategoryConfigurationCommand
              SetDefaultIncomeCategory {categoryId = income.other.entryId}
      incomeResult <- liftIO $ applyConfigurationCommand writer reader id configUuid incomeCategoryCmd
      case incomeResult of
        Left err -> logWarn $ "Failed to set default income category: " <> displayShow err
        Right _ -> return ()

      let expenseCategoryCmd =
            SetDefaultExpenseCategoryConfigurationCommand
              SetDefaultExpenseCategory {categoryId = expense.other.entryId}
      expenseResult <- liftIO $ applyConfigurationCommand writer reader id configUuid expenseCategoryCmd
      case expenseResult of
        Left err -> logWarn $ "Failed to set default expense category: " <> displayShow err
        Right _ -> return ()

      let bankProviderExpenseCategoryMapCmd =
            SetBankProviderExpenseCategoryMapConfigurationCommand
              SetBankProviderExpenseCategoryMap {mapping = defaultBankProviderExpenseCategoryMap}
      bankProviderCategoryResult <- liftIO $ applyConfigurationCommand writer reader id configUuid bankProviderExpenseCategoryMapCmd
      case bankProviderCategoryResult of
        Left err -> logWarn $ "Failed to set banking provider-category map: " <> displayShow err
        Right _ -> return ()

      logInfo "Default configuration seeded successfully"

-- -----------------------------------------------------------------------------
-- Clone-on-Write Helpers
-- -----------------------------------------------------------------------------

-- | Look up a user's configuration ID and data from the read models.
lookupUserConfiguration :: UserId -> AppM (Either DomainError (ConfigurationId, ConfigurationData))
lookupUserConfiguration userId = runExceptT $ do
  userData <- getUserData userId
  configData <-
    liftMaybeM
      (NotFound "Configuration" (tshow userData.configurationId))
      (runDb (getConfiguration userData.configurationId))
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
    translateConfigurationError
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
  lift (copyDefaults newConfigUuidVal configData)
  lift (copyBanking newConfigUuidVal configData.banking)
  runUserCmd
    (unUserId userId)
    ( AssignConfigurationUserCommand
        AssignConfiguration {configurationId = newConfigId}
    )
  lift $ logInfo $ "Configuration cloned successfully: " <> displayShow newConfigId
  pure newConfigId

-- | Copy every dictionary entry from a source configuration's dictionaries
-- map into the freshly created clone. Per-entry failures are logged and
-- skipped — clone-on-write must succeed even when one entry fails to copy.
copyDictionaries :: UUID -> Map DictionaryKind DictionaryData -> AppM ()
copyDictionaries newConfigUuidVal dictionaries = do
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  enricher <- enricherFromContext <$> view requestContextL
  forM_ (Map.toList dictionaries) $ \(dictKind, dictData) ->
    forM_ (dictionaryEntriesParentFirst dictData) $ \(eId, entryName, entryRole, mParent) -> do
      let cmd =
            AddDictionaryEntryConfigurationCommand
              AddDictionaryEntry
                { dictionaryKind = dictKind,
                  entryId = eId,
                  name = entryName,
                  role = entryRole,
                  parentId = mParent
                }
      addResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal cmd
      case addResult of
        Left err -> logWarn $ "Failed to clone dictionary entry: " <> displayShow err
        Right _ -> return ()

-- | Copy the global defaults (income/expense categories, global default account,
-- and per-subtype default accounts) from the source configuration to the clone.
-- Per-field failures are logged and skipped.
copyDefaults :: UUID -> ConfigurationData -> AppM ()
copyDefaults newConfigUuidVal srcConfig = do
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  enricher <- enricherFromContext <$> view requestContextL
  let ConfigurationDefaults
        { incomeCategory = mIncome,
          expenseCategory = mExpense,
          account = mAccount,
          subtypeAccounts = subAccts
        } = srcConfig.defaults
  forM_ mIncome $ \eid -> do
    let cmd =
          SetDefaultIncomeCategoryConfigurationCommand
            SetDefaultIncomeCategory {categoryId = eid}
    copyResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone defaultIncomeCategory: " <> displayShow err
      Right _ -> return ()

  forM_ mExpense $ \eid -> do
    let cmd =
          SetDefaultExpenseCategoryConfigurationCommand
            SetDefaultExpenseCategory {categoryId = eid}
    copyResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone defaultExpenseCategory: " <> displayShow err
      Right _ -> return ()

  forM_ mAccount $ \aid -> do
    let cmd =
          SetDefaultAccountConfigurationCommand
            SetDefaultAccount {accountId = aid}
    copyResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone defaultAccount: " <> displayShow err
      Right _ -> return ()

  unless (Map.null subAccts) $ do
    let cmd =
          SetDefaultSubtypeAccountsConfigurationCommand
            SetDefaultSubtypeAccounts {subtypeAccounts = subAccts}
    copyResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone defaultSubtypeAccounts: " <> displayShow err
      Right _ -> return ()

-- | Copy banking config (MCC map and bank connections) from the source
-- configuration to the clone. Per-field failures are logged and skipped.
copyBanking :: UUID -> BankingConfiguration -> AppM ()
copyBanking newConfigUuidVal srcBanking = do
  writer <- view eventStoreWriterL
  reader <- view eventStoreReaderL
  enricher <- enricherFromContext <$> view requestContextL
  unless (Map.null srcBanking.bankProviderExpenseCategoryMap) $ do
    let cmd =
          SetBankProviderExpenseCategoryMapConfigurationCommand
            SetBankProviderExpenseCategoryMap {mapping = srcBanking.bankProviderExpenseCategoryMap}
    copyResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal cmd
    case copyResult of
      Left err -> logWarn $ "Failed to clone banking.bankProviderExpenseCategoryMap: " <> displayShow err
      Right _ -> return ()

  -- Clone bank connections. Each connection is re-emitted with its already
  -- encrypted secret, hint, provider, name, and enabled flag preserved; its
  -- account map (if any) is set afterwards. Per-connection failures are logged
  -- and skipped — clone-on-write must not abort on a single connection.
  forM_ (Map.toList srcBanking.connections) $ \(connId, conn) -> do
    let addCmd =
          AddBankConnectionConfigurationCommand
            AddBankConnection
              { connectionId = connId,
                provider = conn.provider,
                name = conn.name,
                encryptedSecret = conn.encryptedSecret,
                secretHint = conn.secretHint,
                enabled = conn.enabled
              }
    addResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal addCmd
    case addResult of
      Left err -> logWarn $ "Failed to clone bank connection: " <> displayShow err
      Right _ ->
        unless (Map.null conn.accountMap) $ do
          let mapCmd =
                SetBankConnectionAccountMapConfigurationCommand
                  SetBankConnectionAccountMap
                    { connectionId = connId,
                      accountMap = conn.accountMap
                    }
          mapResult <- liftIO $ applyConfigurationCommand writer reader enricher newConfigUuidVal mapCmd
          case mapResult of
            Left err -> logWarn $ "Failed to clone bank connection account map: " <> displayShow err
            Right _ -> return ()
