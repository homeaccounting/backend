---
status: completed
---

# User Configurations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Introduce a Configuration bounded context with dynamic dictionaries, shared configs with clone-on-write, replacing hardcoded categories and currencies.

**Architecture:** New Configuration aggregate (events, commands, projection) following existing patterns. Dictionary abstraction keyed by opaque `DictionaryId`. `TransferCategory` changes from enum wrappers to `DictionaryEntryId` references. Account currency locking. Clone-on-write orchestration in application service. Default config seeded on startup.

**Tech Stack:** Haskell, Servant, Eventium (event sourcing), QuickCheck, Hspec, Aeson, RIO

**Spec:** `docs/specs/2026-04-08-user-configurations-design.md`

**Build strategy:** The old `IncomeCategory`/`ExpenseCategory` enums are kept alongside the new types until Task 14, when all consumers are migrated. This keeps the build green throughout. Task 14 removes the old enums and fixes all references in one pass.

---

### Task 1: Add Configuration domain types to `Domain.Core.Types`

**Files:**
- Modify: `src/Domain/Core/Types.hs`

Add new types alongside existing domain types. **Do NOT remove old enums yet** — they stay until Task 14.

- [x] **Step 1: Add ConfigurationId, DictionaryEntryId, DictionaryId, EntryName types**

Add after the existing `UserId` section (around line 480). Follow the same newtype pattern as `AccountId`/`UserId`:

```haskell
-- | Unique identifier for a configuration aggregate.
newtype ConfigurationId = ConfigurationId {unConfigurationId :: UUID}
  deriving (Show, Eq, Ord, Generic)

instance ToJSON ConfigurationId

instance FromJSON ConfigurationId

mkConfigurationId :: UUID -> Either Text ConfigurationId
mkConfigurationId uuid
  | uuid == UUID.nil = Left "ConfigurationId cannot be nil UUID"
  | otherwise = Right (ConfigurationId uuid)

mkConfigurationIdSafe :: UUID -> Maybe ConfigurationId
mkConfigurationIdSafe uuid
  | uuid == UUID.nil = Nothing
  | otherwise = Just (ConfigurationId uuid)

unsafeConfigurationId :: UUID -> ConfigurationId
unsafeConfigurationId = ConfigurationId

-- | Well-known ID for the system default configuration.
defaultConfigurationId :: ConfigurationId
defaultConfigurationId = ConfigurationId (fromJust (UUID.fromString "00000000-0000-0000-0000-000000000001"))

-- | Unique identifier for a dictionary entry.
newtype DictionaryEntryId = DictionaryEntryId {unDictionaryEntryId :: UUID}
  deriving (Show, Eq, Ord, Generic)

instance ToJSON DictionaryEntryId

instance FromJSON DictionaryEntryId

mkDictionaryEntryId :: UUID -> Either Text DictionaryEntryId
mkDictionaryEntryId uuid
  | uuid == UUID.nil = Left "DictionaryEntryId cannot be nil UUID"
  | otherwise = Right (DictionaryEntryId uuid)

unsafeDictionaryEntryId :: UUID -> DictionaryEntryId
unsafeDictionaryEntryId = DictionaryEntryId

-- | Opaque dictionary key — no domain semantics in Configuration context.
newtype DictionaryId = DictionaryId {unDictionaryId :: Text}
  deriving (Show, Eq, Ord, Generic)

instance ToJSON DictionaryId

instance FromJSON DictionaryId

-- | Display name for a dictionary entry (non-empty, trimmed, max 50 chars).
newtype EntryName = EntryName {unEntryName :: Text}
  deriving (Show, Eq, Ord, Generic)

instance ToJSON EntryName

instance FromJSON EntryName

mkEntryName :: Text -> Either Text EntryName
mkEntryName raw
  | T.null trimmed = Left "EntryName cannot be empty"
  | T.length trimmed > 50 = Left "EntryName cannot exceed 50 characters"
  | otherwise = Right (EntryName trimmed)
  where
    trimmed = T.strip raw

unsafeEntryName :: Text -> EntryName
unsafeEntryName = EntryName

-- | Who created a configuration.
data CreatedBy
  = System
  | ClonedBy UserId ConfigurationId
  deriving (Show, Eq, Generic)

instance ToJSON CreatedBy

instance FromJSON CreatedBy

-- | A single dictionary entry.
data DictionaryEntry = DictionaryEntry
  { entryId :: DictionaryEntryId,
    name :: EntryName
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryEntry

instance FromJSON DictionaryEntry

-- | A collection of entries.
data Dictionary = Dictionary
  { entries :: [DictionaryEntry]
  }
  deriving (Show, Eq, Generic)

instance ToJSON Dictionary

instance FromJSON Dictionary
```

- [x] **Step 2: Update module exports**

Add all new types and their constructors/accessors to the module export list.

- [x] **Step 3: Build to verify new types compile**

Run: `just build`
Expected: compiles successfully (old enums still intact).

- [x] **Step 4: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "feat: add Configuration domain types (ConfigurationId, DictionaryId, EntryName, Dictionary)"
```

---

### Task 2: Configuration aggregate — Events, Commands, CommandHandler, Projection

**Files:**
- Create: `src/Domain/Configuration/Events.hs`
- Create: `src/Domain/Configuration/Commands.hs`
- Create: `src/Domain/Configuration/CommandHandler.hs`
- Create: `src/Domain/Configuration/Projection.hs`
- Create: `src/Domain/Configuration.hs`

Follow the exact same patterns as `Domain/Account/` — TH event/command lists, `constructSumType`, command handler returning `Either ConfigurationError [ConfigurationEvent]`.

- [x] **Step 1: Create `src/Domain/Configuration/Events.hs`**

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Domain.Configuration.Events
  ( configurationEvents,
    ConfigurationCreated (..),
    BaseCurrencyChanged (..),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRenamed (..),
    DictionaryEntryRemoved (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Map.Strict (Map)
import Domain.Core.Types
  ( CreatedBy,
    Currency,
    Dictionary,
    DictionaryEntryId,
    DictionaryId,
    EntryName,
  )
import Language.Haskell.TH (Name)

configurationEvents :: [Name]
configurationEvents =
  [ ''ConfigurationCreated,
    ''BaseCurrencyChanged,
    ''DefaultCurrencyChanged,
    ''DictionaryEntryAdded,
    ''DictionaryEntryRenamed,
    ''DictionaryEntryRemoved
  ]

data ConfigurationCreated = ConfigurationCreated
  { baseCurrency :: Currency,
    defaultCurrency :: Currency,
    dictionaries :: Map DictionaryId Dictionary,
    createdBy :: CreatedBy
  }
  deriving (Show, Eq)

data BaseCurrencyChanged = BaseCurrencyChanged
  { newCurrency :: Currency
  }
  deriving (Show, Eq)

data DefaultCurrencyChanged = DefaultCurrencyChanged
  { newCurrency :: Currency
  }
  deriving (Show, Eq)

data DictionaryEntryAdded = DictionaryEntryAdded
  { dictionaryId :: DictionaryId,
    entryId :: DictionaryEntryId,
    name :: EntryName
  }
  deriving (Show, Eq)

data DictionaryEntryRenamed = DictionaryEntryRenamed
  { dictionaryId :: DictionaryId,
    entryId :: DictionaryEntryId,
    newName :: EntryName
  }
  deriving (Show, Eq)

data DictionaryEntryRemoved = DictionaryEntryRemoved
  { dictionaryId :: DictionaryId,
    entryId :: DictionaryEntryId
  }
  deriving (Show, Eq)

deriveJSON defaultOptions ''ConfigurationCreated
deriveJSON defaultOptions ''BaseCurrencyChanged
deriveJSON defaultOptions ''DefaultCurrencyChanged
deriveJSON defaultOptions ''DictionaryEntryAdded
deriveJSON defaultOptions ''DictionaryEntryRenamed
deriveJSON defaultOptions ''DictionaryEntryRemoved
```

- [x] **Step 2: Create `src/Domain/Configuration/Commands.hs`**

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Domain.Configuration.Commands
  ( configurationCommands,
    CreateConfiguration (..),
    ChangeBaseCurrency (..),
    ChangeDefaultCurrency (..),
    AddDictionaryEntry (..),
    RenameDictionaryEntry (..),
    RemoveDictionaryEntry (..),
  )
where

import Data.Map.Strict (Map)
import Domain.Core.Types
  ( CreatedBy,
    Currency,
    Dictionary,
    DictionaryEntryId,
    DictionaryId,
    EntryName,
  )
import Language.Haskell.TH (Name)

configurationCommands :: [Name]
configurationCommands =
  [ ''CreateConfiguration,
    ''ChangeBaseCurrency,
    ''ChangeDefaultCurrency,
    ''AddDictionaryEntry,
    ''RenameDictionaryEntry,
    ''RemoveDictionaryEntry
  ]

data CreateConfiguration = CreateConfiguration
  { baseCurrency :: Currency,
    defaultCurrency :: Currency,
    dictionaries :: Map DictionaryId Dictionary,
    createdBy :: CreatedBy
  }
  deriving (Show, Eq)

data ChangeBaseCurrency = ChangeBaseCurrency
  { newCurrency :: Currency
  }
  deriving (Show, Eq)

data ChangeDefaultCurrency = ChangeDefaultCurrency
  { newCurrency :: Currency
  }
  deriving (Show, Eq)

data AddDictionaryEntry = AddDictionaryEntry
  { dictionaryId :: DictionaryId,
    entryId :: DictionaryEntryId,
    name :: EntryName
  }
  deriving (Show, Eq)

data RenameDictionaryEntry = RenameDictionaryEntry
  { dictionaryId :: DictionaryId,
    entryId :: DictionaryEntryId,
    newName :: EntryName
  }
  deriving (Show, Eq)

data RemoveDictionaryEntry = RemoveDictionaryEntry
  { dictionaryId :: DictionaryId,
    entryId :: DictionaryEntryId
  }
  deriving (Show, Eq)
```

- [x] **Step 3: Create `src/Domain/Configuration/Projection.hs`**

Follow `Domain/Account/Projection.hs` pattern. Note: use `.field` syntax (not field selector functions) since `NoFieldSelectors` is enabled. Do NOT add `deriveJSON` with `dropSuffix` on `ConfigurationEvent` — only the unified `AccountingEvent` in `Domain.Models` gets that treatment.

```haskell
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Domain.Configuration.Projection
  ( Configuration (..),
    ConfigurationEvent (..),
    configurationProjection,
    configurationDefault,
    handleConfigurationEvent,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Domain.Configuration.Events
import Domain.Core.Types
  ( CreatedBy (..),
    Currency (..),
    Dictionary (..),
    DictionaryEntry (..),
    DictionaryEntryId,
    DictionaryId,
    EntryName,
  )
import Eventium (Projection (..))
import Eventium.TH.SumType (SumTypeTagOptions (AppendTypeNameToTags), constructSumType, defaultSumTypeOptions, withTagOptions)
import Optics (makeFieldLabelsNoPrefix)
import Data.Aeson.TH (defaultOptions, deriveJSON)

-- Generate ConfigurationEvent sum type
constructSumType
  "ConfigurationEvent"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  configurationEvents

deriving instance Show ConfigurationEvent

deriving instance Eq ConfigurationEvent

-- | Configuration aggregate state.
data Configuration = Configuration
  { baseCurrency :: Currency,
    defaultCurrency :: Currency,
    dictionaries :: Map DictionaryId Dictionary,
    createdBy :: CreatedBy,
    isCreated :: Bool
  }
  deriving (Show, Eq)

makeFieldLabelsNoPrefix ''Configuration

deriveJSON defaultOptions ''Configuration

-- | Default (uninitialized) configuration state.
configurationDefault :: Configuration
configurationDefault =
  Configuration
    { baseCurrency = USD,
      defaultCurrency = USD,
      dictionaries = Map.empty,
      createdBy = System,
      isCreated = False
    }

-- | Apply a single event to the configuration state.
handleConfigurationEvent :: Configuration -> ConfigurationEvent -> Configuration
handleConfigurationEvent config (ConfigurationCreatedConfigurationEvent e) =
  config
    { baseCurrency = e.baseCurrency,
      defaultCurrency = e.defaultCurrency,
      dictionaries = e.dictionaries,
      createdBy = e.createdBy,
      isCreated = True
    }
handleConfigurationEvent config (BaseCurrencyChangedConfigurationEvent e) =
  config {baseCurrency = e.newCurrency}
handleConfigurationEvent config (DefaultCurrencyChangedConfigurationEvent e) =
  config {defaultCurrency = e.newCurrency}
handleConfigurationEvent config (DictionaryEntryAddedConfigurationEvent e) =
  let entry = DictionaryEntry {entryId = e.entryId, name = e.name}
      addEntry dict = dict {entries = dict.entries ++ [entry]}
      updatedDicts = Map.alter
        (\case
          Nothing -> Just (Dictionary [entry])
          Just dict -> Just (addEntry dict))
        e.dictionaryId
        config.dictionaries
   in config {dictionaries = updatedDicts}
handleConfigurationEvent config (DictionaryEntryRenamedConfigurationEvent e) =
  let renameEntry de
        | de.entryId == e.entryId = de {name = e.newName}
        | otherwise = de
      updateDict dict = dict {entries = map renameEntry dict.entries}
   in config {dictionaries = Map.adjust updateDict e.dictionaryId config.dictionaries}
handleConfigurationEvent config (DictionaryEntryRemovedConfigurationEvent e) =
  let removeEntry dict = dict {entries = filter (\de -> de.entryId /= e.entryId) dict.entries}
   in config {dictionaries = Map.adjust removeEntry e.dictionaryId config.dictionaries}

-- | Configuration projection.
configurationProjection :: Projection Configuration ConfigurationEvent
configurationProjection = Projection configurationDefault handleConfigurationEvent
```

- [x] **Step 4: Create `src/Domain/Configuration/CommandHandler.hs`**

```haskell
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

module Domain.Configuration.CommandHandler
  ( ConfigurationError (..),
    ConfigurationCommand (..),
    configurationCommandHandler,
    handleConfigurationCommand,
  )
where

import qualified Data.Map.Strict as Map
import Domain.Configuration.Commands
import Domain.Configuration.Events
import Domain.Configuration.Projection (Configuration (..), ConfigurationEvent (..))
import Domain.Core.Types
  ( Dictionary (..),
    DictionaryEntryId,
    DictionaryId,
    EntryName,
  )
import Eventium (CommandHandler (..))
import Eventium.TH.SumType (SumTypeTagOptions (AppendTypeNameToTags), constructSumType, defaultSumTypeOptions, withTagOptions)

-- | Errors that can occur when handling configuration commands.
-- These are pure domain rejection reasons without contextual data.
-- The service layer maps these to richer error types.
data ConfigurationError
  = ConfigurationAlreadyExists
  | ConfigurationNotCreated
  | DictionaryNotFound
  | EntryNotFound
  | DuplicateEntryName
  | CannotRemoveLastEntry
  deriving (Show, Eq)

-- Generate ConfigurationCommand sum type
constructSumType
  "ConfigurationCommand"
  (withTagOptions AppendTypeNameToTags defaultSumTypeOptions)
  configurationCommands

deriving instance Show ConfigurationCommand

deriving instance Eq ConfigurationCommand

handleConfigurationCommand :: Configuration -> ConfigurationCommand -> Either ConfigurationError [ConfigurationEvent]
handleConfigurationCommand config (CreateConfigurationConfigurationCommand cmd)
  | config.isCreated = Left ConfigurationAlreadyExists
  | otherwise =
      Right
        [ ConfigurationCreatedConfigurationEvent
            ConfigurationCreated
              { baseCurrency = cmd.baseCurrency,
                defaultCurrency = cmd.defaultCurrency,
                dictionaries = cmd.dictionaries,
                createdBy = cmd.createdBy
              }
        ]
handleConfigurationCommand config (ChangeBaseCurrencyConfigurationCommand cmd)
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      Right [BaseCurrencyChangedConfigurationEvent (BaseCurrencyChanged cmd.newCurrency)]
handleConfigurationCommand config (ChangeDefaultCurrencyConfigurationCommand cmd)
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      Right [DefaultCurrencyChangedConfigurationEvent (DefaultCurrencyChanged cmd.newCurrency)]
handleConfigurationCommand config (AddDictionaryEntryConfigurationCommand cmd)
  | not config.isCreated = Left ConfigurationNotCreated
  | hasDuplicateName cmd.dictionaryId cmd.name config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryAddedConfigurationEvent
            DictionaryEntryAdded
              { dictionaryId = cmd.dictionaryId,
                entryId = cmd.entryId,
                name = cmd.name
              }
        ]
handleConfigurationCommand config (RenameDictionaryEntryConfigurationCommand cmd)
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists cmd.dictionaryId config) = Left DictionaryNotFound
  | not (entryExists cmd.dictionaryId cmd.entryId config) = Left EntryNotFound
  | hasDuplicateName cmd.dictionaryId cmd.newName config = Left DuplicateEntryName
  | otherwise =
      Right
        [ DictionaryEntryRenamedConfigurationEvent
            DictionaryEntryRenamed
              { dictionaryId = cmd.dictionaryId,
                entryId = cmd.entryId,
                newName = cmd.newName
              }
        ]
handleConfigurationCommand config (RemoveDictionaryEntryConfigurationCommand cmd)
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists cmd.dictionaryId config) = Left DictionaryNotFound
  | not (entryExists cmd.dictionaryId cmd.entryId config) = Left EntryNotFound
  | isLastEntry cmd.dictionaryId config = Left CannotRemoveLastEntry
  | otherwise =
      Right
        [ DictionaryEntryRemovedConfigurationEvent
            DictionaryEntryRemoved
              { dictionaryId = cmd.dictionaryId,
                entryId = cmd.entryId
              }
        ]

-- Helpers

dictionaryExists :: DictionaryId -> Configuration -> Bool
dictionaryExists dictId config = Map.member dictId config.dictionaries

entryExists :: DictionaryId -> DictionaryEntryId -> Configuration -> Bool
entryExists dictId eId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.entryId == eId) dict.entries

hasDuplicateName :: DictionaryId -> EntryName -> Configuration -> Bool
hasDuplicateName dictId eName config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> False
    Just dict -> any (\e -> e.name == eName) dict.entries

isLastEntry :: DictionaryId -> Configuration -> Bool
isLastEntry dictId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> True
    Just dict -> length dict.entries <= 1

configurationCommandHandler :: CommandHandler Configuration ConfigurationEvent ConfigurationCommand ConfigurationError
configurationCommandHandler = CommandHandler handleConfigurationCommand
```

- [x] **Step 5: Create `src/Domain/Configuration.hs` (re-export module)**

Follow `Domain/Account.hs` pattern:

```haskell
module Domain.Configuration
  ( module Domain.Configuration.CommandHandler,
    module Domain.Configuration.Commands,
    ConfigurationCreated (..),
    BaseCurrencyChanged (..),
    DefaultCurrencyChanged (..),
    DictionaryEntryAdded (..),
    DictionaryEntryRenamed (..),
    DictionaryEntryRemoved (..),
    configurationEvents,
    module Domain.Configuration.Projection,
  )
where

import Domain.Configuration.CommandHandler
import Domain.Configuration.Commands
import Domain.Configuration.Events
import Domain.Configuration.Projection
```

- [x] **Step 6: Add modules to `package.yaml`**

Add all new modules under `exposed-modules` or ensure `src/` autodiscovery picks them up.

- [x] **Step 7: Build**

Run: `just build`
Expected: compiles successfully.

- [x] **Step 8: Commit**

```bash
git add src/Domain/Configuration/
git commit -m "feat: add Configuration aggregate — events, commands, projection, command handler"
```

---

### Task 3: Configuration service-level errors

**Files:**
- Create: `src/Domain/Configuration/Errors.hs`
- Modify: `src/Domain/Core/Errors.hs`
- Modify: `src/Web/ErrorMapping.hs`

Follow the two-tier error pattern: simple `ConfigurationError` in CommandHandler (already done), rich `ConfigurationError` in Errors.hs for the service layer, and `ConfigurationError Text` variant in `DomainError`.

- [x] **Step 1: Create `src/Domain/Configuration/Errors.hs`**

Follow `src/Domain/Account/Errors.hs` pattern — record-based error variants with smart constructors:

```haskell
module Domain.Configuration.Errors
  ( ConfigurationError (..),
    mkConfigurationNotFound,
    mkDictionaryNotFound,
    mkEntryNotFound,
    mkDuplicateEntryName,
    mkCannotRemoveLastEntry,
    mkConfigurationAccessDenied,
  )
where
```

Define variants matching the spec:
- `ConfigurationNotFound { configurationNotFoundId :: ConfigurationId }`
- `DictionaryNotFound { dictionaryNotFoundConfigId :: ConfigurationId, dictionaryNotFoundDictId :: DictionaryId }`
- `EntryNotFound { entryNotFoundDictId :: DictionaryId, entryNotFoundEntryId :: DictionaryEntryId }`
- `DuplicateEntryName { duplicateEntryDictId :: DictionaryId, duplicateEntryName :: EntryName }`
- `CannotRemoveLastEntry { cannotRemoveLastDictId :: DictionaryId }`
Each with a smart constructor that returns the structured error. Note: `ConfigurationAccessDenied` is not needed — all API endpoints are scoped to the authenticated user, so unauthorized access is impossible by design.

- [x] **Step 2: Add `ConfigurationError Text` to `DomainError` in `src/Domain/Core/Errors.hs`**

```haskell
data DomainError
  = ValidationErr ValidationError
  | AccountError Text
  | TransactionError Text
  | UserError Text
  | ConfigurationError Text     -- NEW
  | InsufficientFunds { ... }
  | ExchangeRateUnavailable Text
  | NotFound { ... }
```

- [x] **Step 3: Add `ConfigurationError` mapping in `src/Web/ErrorMapping.hs`**

Add pattern match for `ConfigurationError msg -> err400 { errBody = ... }` following the existing `AccountError` / `TransactionError` pattern.

- [x] **Step 4: Note on re-exports**

Do NOT add `Domain.Configuration.Errors` to the `Domain/Configuration.hs` re-export module — it would collide with `ConfigurationError` from `CommandHandler`. Follow the existing pattern: `Domain.Account` does not re-export `Domain.Account.Errors`. Services import `Domain.Configuration.Errors` directly where needed.

- [x] **Step 5: Build**

Run: `just build`

- [x] **Step 6: Commit**

```bash
git add src/Domain/Configuration/Errors.hs src/Domain/Core/Errors.hs src/Web/ErrorMapping.hs src/Domain/Configuration.hs
git commit -m "feat: add Configuration service-level errors and DomainError integration"
```

---

### Task 4: Configuration aggregate tests

**Files:**
- Create: `test/Domain/Configuration/CommandHandlerSpec.hs`
- Create: `test/Domain/Configuration/ProjectionSpec.hs`
- Modify: `test/Testkit/Generators.hs`
- Modify: `test/Testkit/Helpers.hs`

- [x] **Step 1: Add Configuration generators to `test/Testkit/Generators.hs`**

```haskell
genConfigurationId :: Gen ConfigurationId
genConfigurationId = unsafeConfigurationId <$> genUUID `suchThat` (/= UUID.nil)

genDictionaryEntryId :: Gen DictionaryEntryId
genDictionaryEntryId = unsafeDictionaryEntryId <$> genUUID `suchThat` (/= UUID.nil)

genDictionaryId :: Gen DictionaryId
genDictionaryId = DictionaryId <$> elements ["income-category", "expense-category", "label", "tag"]

genEntryName :: Gen EntryName
genEntryName = unsafeEntryName <$> elements
  ["Salary", "Food", "Transport", "Rent", "Gift", "Other", "Utilities", "Entertainment"]

genDictionaryEntry :: Gen DictionaryEntry
genDictionaryEntry = DictionaryEntry <$> genDictionaryEntryId <*> genEntryName

genDictionary :: Gen Dictionary
genDictionary = Dictionary <$> listOf1 genDictionaryEntry

genCreatedBy :: Gen CreatedBy
genCreatedBy = oneof [pure System, ClonedBy <$> genUserId <*> genConfigurationId]
```

- [x] **Step 2: Add mock helpers to `test/Testkit/Helpers.hs`**

```haskell
mockConfigurationId :: UUID -> ConfigurationId
mockConfigurationId = unsafeConfigurationId

mockDictionaryEntryId :: UUID -> DictionaryEntryId
mockDictionaryEntryId = unsafeDictionaryEntryId

mockEntryName :: Text -> EntryName
mockEntryName = unsafeEntryName
```

- [x] **Step 3: Create `test/Domain/Configuration/CommandHandlerSpec.hs`**

Test all command handler invariants:
- CreateConfiguration succeeds on fresh aggregate, fails on created (ConfigurationAlreadyExists)
- ChangeBaseCurrency / ChangeDefaultCurrency succeed on created, fail on uncreated
- AddDictionaryEntry succeeds, auto-creates dictionary if absent, rejects duplicate name
- RenameDictionaryEntry succeeds, rejects missing dictionary/entry, rejects duplicate name
- RemoveDictionaryEntry succeeds, rejects last entry (CannotRemoveLastEntry), rejects missing
- All commands fail on uncreated aggregate (ConfigurationNotCreated)

- [x] **Step 4: Create `test/Domain/Configuration/ProjectionSpec.hs`**

Test that projection correctly folds events into state.

- [x] **Step 5: Run tests**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Configuration/"`
Expected: all tests pass.

- [x] **Step 6: Commit**

```bash
git add test/Domain/Configuration/ test/Testkit/Generators.hs test/Testkit/Helpers.hs
git commit -m "test: add Configuration command handler and projection tests"
```

---

### Task 5: Configuration Read Model

**Files:**
- Create: `src/Application/ReadModels/Configuration.hs`

Follow the exact pattern of `Application/ReadModels/Account.hs` and `Application/ReadModels/User.hs`.

- [x] **Step 1: Create the read model**

```haskell
module Application.ReadModels.Configuration
  ( ConfigurationReadModel (..),
    ConfigurationData (..),
    DictionaryData (..),
    createConfigurationReadModel,
    handleConfigurationEvents,
    getConfiguration,
  )
where
```

Define:
- `ConfigurationData` with `baseCurrency`, `defaultCurrency`, `dictionaries :: Map DictionaryId DictionaryData`, `createdBy`, `version`
- `DictionaryData` with `entries :: Map DictionaryEntryId EntryName`
- `ConfigurationReadModel` with `latestSequence`, `summaryData :: Map ConfigurationId ConfigurationData`
- `createConfigurationReadModel` — creates `TVar` with empty read model
- `handleConfigurationEvents` — processes global stream events, pattern matches on `AccountingEvent` for configuration events
- `getConfiguration :: (MonadIO m) => TVar ConfigurationReadModel -> ConfigurationId -> m (Maybe ConfigurationData)`

**Important:** This module imports `Domain.Models (AccountingEvent(..))` to pattern match on the unified event type.

- [x] **Step 2: Build**

Run: `just build`

- [x] **Step 3: Commit**

```bash
git add src/Application/ReadModels/Configuration.hs
git commit -m "feat: add ConfigurationReadModel"
```

---

### Task 6: Integrate Configuration into Domain.Models and Eventium

**Files:**
- Modify: `src/Domain/Models.hs`
- Modify: `src/Infrastructure/Eventium.hs`

Now that the read model exists (Task 5), we can wire everything together.

- [x] **Step 1: Add Configuration to `Domain.Models`**

Add import:
```haskell
import Domain.Configuration as X
```

Add `configurationEvents` to `constructSumType "AccountingEvent"`:
```haskell
(accountEvents ++ transactionEvents ++ userEvents ++ configurationEvents)
```

Add `configurationCommands` to `constructSumType "AccountingCommand"`:
```haskell
(accountCommands ++ transactionCommands ++ userCommands ++ configurationCommands)
```

Add embeddings, embedded projection, and embedded command handler:
```haskell
mkSumTypeEmbedding "configurationEventEmbedding" ''ConfigurationEvent ''AccountingEvent
mkSumTypeEmbedding "configurationCommandEmbedding" ''ConfigurationCommand ''AccountingCommand

configurationAccountingProjection :: Projection Configuration AccountingEvent
configurationAccountingProjection = embeddedProjection configurationEventEmbedding configurationProjection

configurationAccountingCommandHandler :: CommandHandler Configuration AccountingEvent AccountingCommand ConfigurationError
configurationAccountingCommandHandler =
  embeddedCommandHandler
    configurationEventEmbedding
    configurationCommandEmbedding
    configurationCommandHandler
```

Export all new symbols.

- [x] **Step 2: Wire into `src/Infrastructure/Eventium.hs`**

Add to imports:
```haskell
import Application.ReadModels.Configuration
  ( ConfigurationReadModel,
    createConfigurationReadModel,
    handleConfigurationEvents,
  )
```

Add `configuration :: TVar ConfigurationReadModel` field to `ReadModels` record.

Add `configurationAccountingCommandHandler` to `commandDispatcher`:
```haskell
[ mkAggregateHandlerWith formatAccountError accountAccountingCommandHandler,
  mkAggregateHandler transactionAccountingCommandHandler,
  mkAggregateHandler userAccountingCommandHandler,
  mkAggregateHandler configurationAccountingCommandHandler
]
```

Update `createReadModelHandlers` to create and wire configuration read model handler.

Update `replayReadModels` to include configuration events.

Add `applyConfigurationCommand` following the pattern of `applyAccountCommand`.

- [x] **Step 3: Build**

Run: `just build`

- [x] **Step 4: Commit**

```bash
git add src/Domain/Models.hs src/Infrastructure/Eventium.hs
git commit -m "feat: integrate Configuration into unified event/command types and event store"
```

---

### Task 7: Account currency change command

**Files:**
- Modify: `src/Domain/Account/Events.hs`
- Modify: `src/Domain/Account/Commands.hs`
- Modify: `src/Domain/Account/CommandHandler.hs`
- Modify: `src/Domain/Account/Projection.hs`
- Modify: `src/Domain/Account/Errors.hs`
- Modify: `src/Domain/Account.hs`
- Modify: `src/Infrastructure/Eventium.hs` (update `formatAccountError`)

- [x] **Step 1: Add `AccountCurrencyChanged` event to `Events.hs`**

Add to `accountEvents` list and define:
```haskell
data AccountCurrencyChanged = AccountCurrencyChanged
  { newCurrency :: Currency
  }
  deriving (Show, Eq)
```
Add `deriveJSON defaultOptions ''AccountCurrencyChanged`.

- [x] **Step 2: Add `ChangeAccountCurrency` command to `Commands.hs`**

Add to `accountCommands` list and define:
```haskell
data ChangeAccountCurrency = ChangeAccountCurrency
  { newCurrency :: Currency
  }
  deriving (Show, Eq)
```

- [x] **Step 3: Add `hasTransactions` to Account projection in `Projection.hs`**

Add `hasTransactions :: Bool` field to `Account`. Default to `False` in `accountDefault`.
Set to `True` in `handleAccountEvent` for `AccountDebited` and `AccountCredited`.
Handle `AccountCurrencyChanged` — update the balance currency.

- [x] **Step 4: Handle `ChangeAccountCurrency` in `CommandHandler.hs`**

Add `AccountCurrencyLocked` to the simple `AccountError` enum.

```haskell
handleAccountCommand account (ChangeAccountCurrencyAccountCommand cmd)
  | account.name == "" = Left AccountDoesNotExist
  | account.hasTransactions = Left AccountCurrencyLocked
  | otherwise = Right [AccountCurrencyChangedAccountEvent (AccountCurrencyChanged cmd.newCurrency)]
```

- [x] **Step 5: Add `AccountCurrencyLocked` service-level error to `Errors.hs`**

```haskell
| AccountCurrencyLocked
    { accountCurrencyLockedId :: AccountId
    }
```
Add smart constructor `mkAccountCurrencyLocked`.

- [x] **Step 6: Update `formatAccountError` in `src/Infrastructure/Eventium.hs`**

Add:
```haskell
formatAccountError AccountCurrencyLocked = RejectionReason (T.pack "Account currency is locked")
```

- [x] **Step 7: Update `Domain/Account.hs` re-export**

Add `AccountCurrencyChanged (..)` to exports.

- [x] **Step 8: Build and test**

Run: `just build`
Run: `cabal test all --test-option='--match' --test-option="/Domain.Account/"`

- [x] **Step 9: Commit**

```bash
git add src/Domain/Account/ src/Infrastructure/Eventium.hs
git commit -m "feat: add ChangeAccountCurrency with currency lock on accounts with transactions"
```

---

### Task 8: User aggregate — AssignConfiguration

**Files:**
- Modify: `src/Domain/User/Events.hs`
- Modify: `src/Domain/User/Commands.hs`
- Modify: `src/Domain/User/CommandHandler.hs`
- Modify: `src/Domain/User/Projection.hs`

- [x] **Step 1: Add `UserConfigurationAssigned` event**

Add to `userEvents` list:
```haskell
data UserConfigurationAssigned = UserConfigurationAssigned
  { configurationId :: ConfigurationId
  }
  deriving (Show, Eq)
```

- [x] **Step 2: Add `AssignConfiguration` command**

Add to `userCommands` list:
```haskell
data AssignConfiguration = AssignConfiguration
  { configurationId :: ConfigurationId
  }
  deriving (Show, Eq)
```

- [x] **Step 3: Handle in CommandHandler**

```haskell
handleUserCommand user (AssignConfigurationUserCommand cmd)
  | not user.isRegistered = Left UserNotRegistered
  | otherwise = Right [UserConfigurationAssignedUserEvent (UserConfigurationAssigned cmd.configurationId)]
```

- [x] **Step 4: Update User projection**

Add `configurationId :: ConfigurationId` to `User` state. Default to `defaultConfigurationId`.
Handle `UserConfigurationAssigned` in `handleUserEvent`.

- [x] **Step 5: Build and test**

Run: `just build`
Run: `cabal test all --test-option='--match' --test-option="/Domain.User/"`

- [x] **Step 6: Commit**

```bash
git add src/Domain/User/
git commit -m "feat: add AssignConfiguration command to User aggregate"
```

---

### Task 9: Update User Read Model and AppEnv

**Files:**
- Modify: `src/Application/ReadModels/User.hs`
- Modify: `src/Infrastructure/App.hs`
- Modify: `test/Testkit/InMemoryEventStore.hs`

- [x] **Step 1: Add `configurationId` to `UserData` in `User.hs`**

Default to `defaultConfigurationId` in registration event handling. Handle `UserConfigurationAssigned` events to update the field.

- [x] **Step 2: Add `configurationReadModel` to `AppEnv` in `App.hs`**

Add field and `HasConfigurationReadModel` typeclass with lens.

- [x] **Step 3: Update `test/Testkit/InMemoryEventStore.hs`**

Update `createTestAppEnv` and `createTestAppEnvWithProcessManager` to create and pass the `configurationReadModel`.

- [x] **Step 4: Build and test**

Run: `just build`
Run: `just test`

- [x] **Step 5: Commit**

```bash
git add src/Application/ReadModels/User.hs src/Infrastructure/App.hs test/Testkit/InMemoryEventStore.hs
git commit -m "feat: add configurationId to UserData, configurationReadModel to AppEnv"
```

---

### Task 10: Configuration Service with clone-on-write

**Files:**
- Create: `src/Application/Services/ConfigurationService.hs`

- [x] **Step 1: Create the service**

Functions:
- `getConfigurationForUser :: UserId -> AppM (Either DomainError ConfigurationData)`
- `changeBaseCurrency :: UserId -> Currency -> AppM (Either DomainError ())` — clone-on-write + ChangeAccountCurrency on External account
- `changeDefaultCurrency :: UserId -> Currency -> AppM (Either DomainError ())`
- `addDictionaryEntry :: UserId -> DictionaryId -> EntryName -> AppM (Either DomainError DictionaryEntryId)`
- `renameDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> EntryName -> AppM (Either DomainError ())`
- `removeDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> AppM (Either DomainError ())`
- `seedDefaultConfiguration :: AppM ()`

Clone-on-write logic: check `createdBy` from the read model. If `System` or `ClonedBy otherUser _`, clone then apply. If `ClonedBy thisUser _`, apply directly.

Error mapping: map `ConfigurationError` (from command handler) to `DomainError (ConfigurationError msg)` using a helper function, similar to how `AccountService` maps `AccountError`.

Define well-known `DictionaryId` constants:
```haskell
incomeCategoryDictId :: DictionaryId
incomeCategoryDictId = DictionaryId "income-category"

expenseCategoryDictId :: DictionaryId
expenseCategoryDictId = DictionaryId "expense-category"
```

Define default categories with deterministic UUIDs using `Data.UUID.V5`.

- [x] **Step 2: Build**

Run: `just build`

- [x] **Step 3: Commit**

```bash
git add src/Application/Services/ConfigurationService.hs
git commit -m "feat: add ConfigurationService with clone-on-write and default config seeding"
```

---

### Task 11: Update AuthService registration flow

**Files:**
- Modify: `src/Application/Services/AuthService.hs`

- [x] **Step 1: Update `register`, `createUserViaOAuth`, `createUserViaTelegram`**

In each registration function, after creating the user:

1. Issue `AssignConfigurationUserCommand (AssignConfiguration defaultConfigurationId)` on the user aggregate
2. Read `baseCurrency` from the default configuration read model
3. Use `baseCurrency` instead of hardcoded `USD 0` for the External account

- [x] **Step 2: Build and test**

Run: `just build`
Run: `cabal test all --test-option='--match' --test-option="/AuthService/"`

- [x] **Step 3: Commit**

```bash
git add src/Application/Services/AuthService.hs
git commit -m "feat: registration assigns default config and uses baseCurrency for External account"
```

---

### Task 12: Update TransactionService — validate categories against config

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`

- [x] **Step 1: Add category validation**

Before initiating a transfer, validate the `DictionaryEntryId` in `TransferCategory` against the user's configuration. Use `incomeCategoryDictId`/`expenseCategoryDictId` from ConfigurationService.

- [x] **Step 2: Build and test**

Run: `just build`

- [x] **Step 3: Commit**

```bash
git add src/Application/Services/TransactionService.hs
git commit -m "feat: validate transfer categories against user configuration dictionaries"
```

---

### Task 13: Wire startup seeding and Configuration API

**Files:**
- Modify: `app/Main.hs`
- Create: `src/Web/API/ConfigurationAPI.hs`
- Modify: `src/Web/API.hs` (or wherever the top-level API type is composed)

- [x] **Step 1: Wire startup seeding in `Main.hs`**

After `replayReadModels` and before starting the server, call `seedDefaultConfiguration`. Update `initializeAppEnv` to pass `configurationReadModel` from `ReadModels`.

- [x] **Step 2: Create Configuration API endpoints**

Define Servant API type and handlers. All endpoints are scoped to the authenticated user — no configuration ID in the URL. The service resolves the config ID internally from the user read model.

```
GET    /api/users/me/configuration
PUT    /api/users/me/configuration/base-currency
PUT    /api/users/me/configuration/default-currency
GET    /api/users/me/configuration/dictionaries/:dictId
POST   /api/users/me/configuration/dictionaries/:dictId/entries
PUT    /api/users/me/configuration/dictionaries/:dictId/entries/:entryId
DELETE /api/users/me/configuration/dictionaries/:dictId/entries/:entryId
```

Define request/response DTOs and handlers delegating to `ConfigurationService`.

- [x] **Step 3: Wire into top-level API**

- [x] **Step 4: Build**

Run: `just build`

- [x] **Step 5: Commit**

```bash
git add app/Main.hs src/Web/API/ConfigurationAPI.hs src/Web/API.hs
git commit -m "feat: add Configuration API endpoints and wire startup seeding"
```

---

### Task 14: Remove old category enums and fix all references

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Modify: `src/Web/Types.hs`
- Modify: `src/Telegram/Keyboards.hs`
- Modify: `src/Telegram/Commands.hs`
- Modify: `src/Web/API/AccountAPI.hs`
- Modify: `src/Domain/Transaction/Events.hs`
- Modify: `test/Testkit/Generators.hs`

This is the big switchover — remove old enums and fix every consumer.

- [x] **Step 1: Remove `IncomeCategory`, `ExpenseCategory` from `Domain/Core/Types.hs`**

Remove the old enum types and the old `TransferCategory`. Replace with the new `DictionaryEntryId`-based `TransferCategory`:

```haskell
data TransferCategory
  = IncomeCat DictionaryEntryId
  | ExpenseCat DictionaryEntryId
  | InternalCat
  deriving (Show, Eq, Generic)
```

Update `validateTransferCategory` to only check structural consistency.

- [x] **Step 2: Update `Domain/Transaction/Events.hs`**

`TransferInitiated.category` field type changes from old `TransferCategory` to new one. Since both are named `TransferCategory`, only the import of `DictionaryEntryId` needs adding.

- [x] **Step 3: Update `Web/Types.hs`**

Remove `parseIncomeCategory` and `parseExpenseCategory`. Update `transferCategoryToText` and any DTOs referencing old category types.

- [x] **Step 4: Update `Web/API/AccountAPI.hs`**

Replace hardcoded `"USD"` fallback with lookup from user's config `defaultCurrency`.

- [x] **Step 5: Update `Telegram/Keyboards.hs`**

Replace hardcoded keyboards with dynamic keyboards built from user's configuration read model.

- [x] **Step 6: Update `Telegram/Commands.hs`**

Remove hardcoded category text-to-enum parsing. Replace with `DictionaryEntryId` resolution from callback data.

- [x] **Step 7: Update `test/Testkit/Generators.hs`**

Remove `genIncomeCategory`, `genExpenseCategory`. Update `genTransferCategory`:
```haskell
genTransferCategory :: Gen TransferCategory
genTransferCategory =
  oneof
    [ IncomeCat <$> genDictionaryEntryId,
      ExpenseCat <$> genDictionaryEntryId,
      pure InternalCat
    ]
```

- [x] **Step 8: Clean build**

Run: `just rebuild`
Expected: zero compilation errors.

- [x] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: replace IncomeCategory/ExpenseCategory enums with DictionaryEntryId-based TransferCategory"
```

---

### Task 15: Fix all tests

**Files:**
- Modify: various test files referencing old category types

- [x] **Step 1: Fix test compilation**

Update any tests that use `Salary`, `Food`, etc. to use `DictionaryEntryId` references. Use mock helpers from Testkit.

- [x] **Step 2: Run full test suite**

Run: `just test`
Expected: all tests pass.

- [x] **Step 3: Format and lint**

Run: `just check`

- [x] **Step 4: Commit**

```bash
git add -A
git commit -m "fix: update all tests for dynamic categories"
```

---

### Task 16: Configuration Service integration tests

**Files:**
- Create: `test/Application/Services/ConfigurationServiceIntegrationSpec.hs`

- [x] **Step 1: Write integration tests**

Using in-memory event store from Testkit:
- Default configuration seeding is idempotent
- Clone-on-write: user modifying shared config triggers clone
- Clone-on-write: user modifying owned config applies directly
- `changeBaseCurrency` succeeds before transactions, fails after
- Dictionary CRUD (add, rename, remove)
- Remove last entry rejected
- Registration assigns default config

- [x] **Step 2: Run tests**

Run: `cabal test all --test-option='--match' --test-option="/ConfigurationService/"`

- [x] **Step 3: Commit**

```bash
git add test/Application/Services/ConfigurationServiceIntegrationSpec.hs
git commit -m "test: add ConfigurationService integration tests"
```

---

### Task 17: Final verification

- [x] **Step 1: Clean build**

Run: `just rebuild`

- [x] **Step 2: Full test suite**

Run: `just test`

- [x] **Step 3: Format and lint**

Run: `just check`

- [x] **Step 4: Manual smoke test**

Run: `just docker-up && just run`
Verify: application starts, default config seeded, registration works.
