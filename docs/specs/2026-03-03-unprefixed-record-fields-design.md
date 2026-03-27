---
status: draft
---

# Unprefixed Record Fields with Optics Migration

## Summary

Adopt unprefixed record field names across the entire codebase, replacing the current type-name-prefixed convention. Migrate from `lens` to `optics-th` with `makeFieldLabelsNoPrefix` and `#label` syntax.

## Motivation

Modern GHC extensions (`NoFieldSelectors`, `DuplicateRecordFields`, `OverloadedLabels`) eliminate the namespace collision problem that originally motivated prefixed field names. Unprefixed fields are shorter, more readable, and align with current Haskell best practices.

## Extensions & Dependencies

**New global extensions** (in `package.yaml` `default-extensions`):
- `NoFieldSelectors` — prevents record fields from generating top-level selector functions
- `DuplicateRecordFields` — allows multiple types to share field names
- `OverloadedLabels` — enables `#fieldName` syntax for optics access

**Dependency swap:**
- Remove: `lens >= 4.19 && < 5.4`
- Add: `optics >= 0.4 && < 0.5`, `optics-th >= 0.4 && < 0.5`

## Field Renaming Rules

### Domain Aggregates

```haskell
-- Before
data Account = Account { _accountBalance :: Money, _accountName :: Text }

-- After
data Account = Account { balance :: Money, name :: Text }
```

### Domain Events

```haskell
-- Before
data AccountCreated = AccountCreated { accountCreatedName :: Text, accountCreatedBy :: UserId }

-- After
data AccountCreated = AccountCreated { name :: Text, by :: UserId }
```

### Domain Value Types

```haskell
-- Before
data AccountAccess = AccountAccess { accessUserId :: UserId, accessRole :: AccountRole }

-- After
data AccountAccess = AccountAccess { userId :: UserId, role :: AccountRole }
```

### Application Read Models

```haskell
-- Before
data AccountSummaryData = AccountSummaryData { accountSummaryDataName :: Text }

-- After
data AccountSummaryData = AccountSummaryData { name :: Text }
```

### Web DTOs

```haskell
-- Before
data AccountResponse = AccountResponse { accountResponseId :: UUID, accountResponseName :: Text }

-- After
data AccountResponse = AccountResponse { id :: UUID, name :: Text }
```

### Infrastructure

```haskell
-- Before
data AppEnv = AppEnv { appLogFunc :: !LogFunc, appConfig :: !AppConfig }

-- After
data AppEnv = AppEnv { logFunc :: !LogFunc, config :: !AppConfig }
```

### Newtypes (exempt)

Unwrappers like `unMoney`, `unAccountId` stay as-is.

## JSON Serialization

Replace `unPrefixLower` with `defaultOptions` since fields are already the desired JSON key names:

```haskell
-- Before
deriveJSON (unPrefixLower "_account") ''Account

-- After
deriveJSON defaultOptions ''Account
```

Event types likewise switch to `defaultOptions`. No backwards compatibility needed — DB will be recreated.

## Optics Access Pattern

```haskell
-- Before (lens)
import Control.Lens (makeLenses, (%~), (&), (.~), (^.))
makeLenses ''Account
account ^. accountBalance
account & accountName .~ "Savings"

-- After (optics)
import Optics (makeFieldLabelsNoPrefix, (%~), (&), (.~), (^.))
makeFieldLabelsNoPrefix ''Account
account ^. #balance
account & #name .~ "Savings"
```

Key operator difference: optics uses `%` for composition instead of `.`.

TransferManager `at` usage migrates to `Optics.At`:

```haskell
-- Before
state ^. transferManagerTransfers . at transferId

-- After
state ^. #transfers % at transferId
```

`RecordWildCards` pattern matching continues to work with `NoFieldSelectors`.

## Scope

Full refactor across all layers: Domain, Application, Web, Infrastructure, and tests. 13 files import `Control.Lens`, 4 types have `makeLenses`, 3 use `deriveJSON` with `unPrefixLower`.
