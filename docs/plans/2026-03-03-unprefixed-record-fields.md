# Unprefixed Record Fields with Optics Migration — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Remove type-name prefixes from all record fields and migrate from `lens` to `optics-th` with `#label` syntax.

**Architecture:** Enable `NoFieldSelectors`, `DuplicateRecordFields`, `OverloadedLabels`, and `OverloadedRecordDot` globally. Replace `makeLenses` with `makeFieldLabelsNoPrefix` from optics-th for aggregate state types. Use `OverloadedRecordDot` (`.field`) for simple reads on events/DTOs. Use `#label` optics for functional updates on aggregates.

**Tech Stack:** optics 0.4+, optics-th 0.4+, GHC 9.6.7

**Design doc:** `docs/plans/2026-03-03-unprefixed-record-fields-design.md`

---

### Task 1: Update package.yaml — dependencies and extensions

**Files:**
- Modify: `package.yaml`

**Step 1: Swap lens for optics in dependencies**

Replace the lens dependency block:

```yaml
  # Lens
  - lens >= 4.19 && < 5.4
```

With:

```yaml
  # Optics
  - optics >= 0.4 && < 0.5
  - optics-th >= 0.4 && < 0.5
```

**Step 2: Add default-extensions to library section**

In the `library:` section, after `source-dirs: src`, add:

```yaml
  default-extensions:
    - NoFieldSelectors
    - DuplicateRecordFields
    - OverloadedLabels
    - OverloadedRecordDot
```

**Step 3: Add default-extensions to executable section**

In the `executables: accounting:` section, add:

```yaml
    default-extensions:
      - NoFieldSelectors
      - DuplicateRecordFields
      - OverloadedLabels
      - OverloadedRecordDot
```

**Step 4: Add default-extensions to test section**

In the `tests: accounting-test:` section, add:

```yaml
    default-extensions:
      - NoFieldSelectors
      - DuplicateRecordFields
      - OverloadedLabels
      - OverloadedRecordDot
```

**Step 5: Run hpack to regenerate cabal file**

Run: `hpack`
Expected: `accounting.cabal` regenerated with new deps and extensions.

**Step 6: Commit**

```bash
git add package.yaml accounting.cabal
git commit -m "chore: swap lens for optics, add NoFieldSelectors extensions"
```

---

### Task 2: Infrastructure/App.hs — unprefix AppEnv and fix HasX lenses

**Files:**
- Modify: `src/Infrastructure/App.hs`

With `NoFieldSelectors`, field selector functions like `appDbPool` no longer exist as top-level functions. The HasX lens implementations use these as getters and must switch to `OverloadedRecordDot`.

**Step 1: Rename AppEnv fields**

Strip `app` prefix from all fields:

| Before | After |
|--------|-------|
| `appLogFunc` | `logFunc` |
| `appConfig` | `config` |
| `appDatabaseConfig` | `databaseConfig` |
| `appDbPool` | `dbPool` |
| `appEventStoreWriter` | `eventStoreWriter` |
| `appEventStoreReader` | `eventStoreReader` |
| `appGlobalEventStoreReader` | `globalEventStoreReader` |
| `appAccountSummaryReadModel` | `accountSummaryReadModel` |
| `appTransactionSummaryReadModel` | `transactionSummaryReadModel` |
| `appUserSummaryReadModel` | `userSummaryReadModel` |
| `appJWTConfig` | `jwtConfig` |
| `appOAuthConfig` | `oauthConfig` |
| `appTelegramConfig` | `telegramConfig` |
| `appBotState` | `botState` |
| `appTelegramClientEnv` | `telegramClientEnv` |

**Step 2: Update initializeAppEnv record construction**

Update all field names in the `AppEnv { ... }` construction (lines ~214-230) to use new names. Field names only, parameter names stay the same.

**Step 3: Update HasX lens implementations**

Replace field selector function with `OverloadedRecordDot` getter. For each instance:

Before:
```haskell
dbPoolL = lens appDbPool (\x y -> x {appDbPool = y})
```

After:
```haskell
dbPoolL = lens (.dbPool) (\x y -> x {dbPool = y})
```

Apply to all HasX instances:
- `HasDbPool`: `appDbPool` -> `.dbPool`
- `HasEventStore`: `appEventStoreWriter` -> `.eventStoreWriter`, etc.
- `HasReadModel`: `appAccountSummaryReadModel` -> `.accountSummaryReadModel`, etc.
- `HasAuthConfig`: `appJWTConfig` -> `.jwtConfig`, etc.
- `HasBotState`: `appBotState` -> `.botState`
- `HasTelegramClientEnv`: `appTelegramClientEnv` -> `.telegramClientEnv`
- `HasAppConfig`: `appConfig` -> `.config`
- `HasDatabaseConfig`: `appDatabaseConfig` -> `.databaseConfig`
- `HasLogFunc`: `appLogFunc` -> `.logFunc`

**Step 4: Update runDb and any other functions using field selectors**

Search for direct field selector usage in this file (e.g., `appDbPool env`) and replace with `env.dbPool`.

**Step 5: Commit**

```bash
git add src/Infrastructure/App.hs
git commit -m "refactor: unprefix AppEnv fields, update HasX lenses"
```

---

### Task 3: Domain/Core/Types.hs — unprefix value types

**Files:**
- Modify: `src/Domain/Core/Types.hs`

**Step 1: Rename AccountAccess fields**

Before:
```haskell
data AccountAccess = AccountAccess
  { accessUserId :: UserId,
    accessRole :: AccountRole
  }
```

After:
```haskell
data AccountAccess = AccountAccess
  { userId :: UserId,
    role :: AccountRole
  }
```

**Step 2: Rename OAuthIdentity fields**

Before:
```haskell
data OAuthIdentity = OAuthIdentity
  { oauthProvider :: OAuthProvider,
    oauthSubject :: Text
  }
```

After:
```haskell
data OAuthIdentity = OAuthIdentity
  { provider :: OAuthProvider,
    subject :: Text
  }
```

**Step 3: Rename TelegramIdentity fields**

Before:
```haskell
data TelegramIdentity = TelegramIdentity
  { telegramId :: TelegramId,
    telegramUsername :: Maybe Text,
    telegramFirstName :: Text
  }
```

After:
```haskell
data TelegramIdentity = TelegramIdentity
  { id :: TelegramId,
    username :: Maybe Text,
    firstName :: Text
  }
```

**Step 4: Fix all usages of old field names in this file**

Search for `accessUserId`, `accessRole`, `oauthProvider`, `oauthSubject`, `telegramId`, `telegramUsername`, `telegramFirstName` in record construction/pattern matching within this file and update.

**Step 5: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "refactor: unprefix AccountAccess, OAuthIdentity, TelegramIdentity fields"
```

---

### Task 4: Account bounded context — Events, Commands, Projection, CommandHandler

**Files:**
- Modify: `src/Domain/Account/Events.hs`
- Modify: `src/Domain/Account/Commands.hs`
- Modify: `src/Domain/Account/Projection.hs`
- Modify: `src/Domain/Account/CommandHandler.hs`

#### Step 1: Unprefix Account Events

Rename fields in all 5 event types. Strip the event type name prefix:

**AccountCreated:**
| Before | After |
|--------|-------|
| `accountCreatedName` | `name` |
| `accountCreatedInitialBalance` | `initialBalance` |
| `accountCreatedBy` | `by` |
| `accountCreatedType` | `accountType` |

**AccountAccessGranted:**
| Before | After |
|--------|-------|
| `accountAccessGrantedUserId` | `userId` |
| `accountAccessGrantedRole` | `role` |
| `accountAccessGrantedBy` | `by` |

**AccountAccessRevoked:**
| Before | After |
|--------|-------|
| `accountAccessRevokedUserId` | `userId` |
| `accountAccessRevokedBy` | `by` |

**AccountDebited:**
| Before | After |
|--------|-------|
| `accountDebitedAmount` | `amount` |
| `accountDebitedTransactionId` | `transactionId` |
| `accountDebitedReason` | `reason` |

**AccountCredited:**
| Before | After |
|--------|-------|
| `accountCreditedAmount` | `amount` |
| `accountCreditedTransactionId` | `transactionId` |
| `accountCreditedReason` | `reason` |

Replace `deriveJSONUnPrefixLower ''AccountCreated` etc. with `deriveJSON defaultOptions ''AccountCreated` for all 5 events. Import `Data.Aeson.TH (deriveJSON, defaultOptions)` and remove the `Eventium.Json.TH (deriveJSONUnPrefixLower)` import.

#### Step 2: Unprefix Account Commands

Rename fields in all 5 command types. Strip command type name prefix:

**CreateAccount:**
| Before | After |
|--------|-------|
| `createAccountName` | `name` |
| `createAccountInitialBalance` | `initialBalance` |
| `createAccountCreatedBy` | `createdBy` |
| `createAccountType` | `accountType` |

**ShareAccount:**
| Before | After |
|--------|-------|
| `shareAccountUserId` | `userId` |
| `shareAccountRole` | `role` |
| `shareAccountGrantedBy` | `grantedBy` |

**RevokeAccountAccess:**
| Before | After |
|--------|-------|
| `revokeAccountAccessUserId` | `userId` |
| `revokeAccountAccessRevokedBy` | `revokedBy` |

**DebitAccount:**
| Before | After |
|--------|-------|
| `debitAccountAmount` | `amount` |
| `debitAccountTransactionId` | `transactionId` |
| `debitAccountReason` | `reason` |

**CreditAccount:**
| Before | After |
|--------|-------|
| `creditAccountAmount` | `amount` |
| `creditAccountTransactionId` | `transactionId` |
| `creditAccountReason` | `reason` |

Replace `deriveJSONUnPrefixLower` with `deriveJSON defaultOptions` for all 5 commands. Update imports.

#### Step 3: Unprefix Account Projection and switch to optics

Rename fields in Account record — strip `_account` prefix:

| Before | After |
|--------|-------|
| `_accountBalance` | `balance` |
| `_accountName` | `name` |
| `_accountCreatedBy` | `createdBy` |
| `_accountType` | `accountType` |
| `_accountAccessList` | `accessList` |

Replace imports:
```haskell
-- Before
import Control.Lens (makeLenses, (%~), (&), (.~), (^.))

-- After
import Optics (makeFieldLabelsNoPrefix, (%~), (&), (.~), (^.))
```

Replace TH splice:
```haskell
-- Before
makeLenses ''Account

-- After
makeFieldLabelsNoPrefix ''Account
```

Replace JSON derivation:
```haskell
-- Before
deriveJSON (unPrefixLower "_account") ''Account

-- After
deriveJSON defaultOptions ''Account
```

Remove `Eventium.Json (unPrefixLower)` import.

Update all lens access in event handlers to use `#label` syntax:
```haskell
-- Before
account & accountName .~ Events.accountCreatedName created
account ^. accountBalance

-- After
account & #name .~ created.name
account ^. #balance
```

Replace direct field selector access (`Events.accountCreatedName created`) with `OverloadedRecordDot` (`created.name`).

Replace `_accountAccessList account` with `account.accessList` or `account ^. #accessList`.

Replace `accessUserId a` (from Core/Types.hs) with `a.userId`.

#### Step 4: Update Account CommandHandler

Replace import:
```haskell
-- Before
import Control.Lens ((^.))

-- After
import Optics ((^.))
```

Update lens access:
```haskell
-- Before
account ^. accountName
account ^. accountType
account ^. accountBalance

-- After
account ^. #name
account ^. #accountType
account ^. #balance
```

Update `RecordWildCards` bindings — field names bound by `{..}` change:
```haskell
-- Before (binds createAccountName, createAccountInitialBalance, etc.)
handleAccountCommand account (CreateAccountAccountCommand CreateAccount {..})
  | T.null createAccountName = Left AccountNameEmpty

-- After (binds name, initialBalance, etc.)
handleAccountCommand account (CreateAccountAccountCommand CreateAccount {..})
  | T.null name = Left AccountNameEmpty
```

Update event construction to use new field names:
```haskell
-- Before
AccountCreated
  { accountCreatedName = createAccountName,
    accountCreatedInitialBalance = createAccountInitialBalance,
    accountCreatedBy = createAccountCreatedBy,
    accountCreatedType = createAccountType
  }

-- After
AccountCreated
  { name = name,
    initialBalance = initialBalance,
    by = createdBy,
    accountType = accountType
  }
```

Update helper functions `isOwner` and `hasAccess` — these likely use `accessUserId` from `AccountAccess`, which is now `userId`. Use dot syntax: `a.userId` or pattern match.

#### Step 5: Build Account bounded context

Run: `cabal build`
Expected: Compilation errors from downstream modules (User, Transaction, Application, Web, tests) that reference old field names. Account-internal compilation should succeed.

#### Step 6: Commit

```bash
git add src/Domain/Account/Events.hs src/Domain/Account/Commands.hs src/Domain/Account/Projection.hs src/Domain/Account/CommandHandler.hs
git commit -m "refactor: unprefix Account bounded context fields, switch to optics"
```

---

### Task 5: User bounded context — Events, Commands, Projection, CommandHandler

**Files:**
- Modify: `src/Domain/User/Events.hs`
- Modify: `src/Domain/User/Commands.hs`
- Modify: `src/Domain/User/Projection.hs`
- Modify: `src/Domain/User/CommandHandler.hs`

Apply the same pattern as Task 4:

#### Step 1: Unprefix User Events

Strip event type prefix from all user event fields. Replace `deriveJSONUnPrefixLower` with `deriveJSON defaultOptions`. There are 7 event types.

Key renames:
- `userRegisteredEmail` -> `email`
- `userRegisteredPasswordHash` -> `passwordHash`
- `userRegisteredExternalAccountId` -> `externalAccountId`
- `userRegisteredViaTelegramEmail` -> `email` (etc.)
- `oAuthAccountLinkedProvider` -> `provider` (etc.)
- `telegramAccountLinkedTelegramId` -> `telegramId` (etc.)
- `passwordChangedNewPasswordHash` -> `newPasswordHash`

#### Step 2: Unprefix User Commands

Strip command type prefix from all user command fields. Replace `deriveJSONUnPrefixLower` with `deriveJSON defaultOptions`. There are 7 command types.

#### Step 3: Unprefix User Projection and switch to optics

Rename fields:
| Before | After |
|--------|-------|
| `_userEmail` | `email` |
| `_userPasswordHash` | `passwordHash` |
| `_userOAuthIdentities` | `oauthIdentities` |
| `_userTelegramIdentity` | `telegramIdentity` |
| `_userExternalAccountId` | `externalAccountId` |
| `_userIsRegistered` | `isRegistered` |

Replace `Control.Lens` import with `Optics`. Replace `makeLenses ''User` with `makeFieldLabelsNoPrefix ''User`. Replace `deriveJSON (unPrefixLower "_user") ''User` with `deriveJSON defaultOptions ''User`. Update all lens access to `#label` syntax. Update all event field access to `OverloadedRecordDot`.

#### Step 4: Update User CommandHandler

Replace `Control.Lens ((^.))` with `Optics ((^.))`. Update lens access and RecordWildCards bindings.

#### Step 5: Commit

```bash
git add src/Domain/User/Events.hs src/Domain/User/Commands.hs src/Domain/User/Projection.hs src/Domain/User/CommandHandler.hs
git commit -m "refactor: unprefix User bounded context fields, switch to optics"
```

---

### Task 6: Transaction bounded context — Events, Commands, Projection, CommandHandler

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/Projection.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`

Apply the same pattern as Tasks 4-5:

#### Step 1: Unprefix Transaction Events

Key renames for TransferInitiated:
- `transferInitiatedFromAccountId` -> `fromAccountId`
- `transferInitiatedToAccountId` -> `toAccountId`
- `transferInitiatedAmount` -> `amount`
- `transferInitiatedReason` -> `reason`
- `transferInitiatedBy` -> `by`

TransferCompleted has no record fields. TransferFailed: `transferFailedReason` -> `reason`.

Replace `deriveJSONUnPrefixLower` with `deriveJSON defaultOptions`.

#### Step 2: Unprefix Transaction Commands

Strip command type prefix. Replace JSON derivation.

#### Step 3: Unprefix Transaction Projection and switch to optics

| Before | After |
|--------|-------|
| `_transactionFromAccountId` | `fromAccountId` |
| `_transactionToAccountId` | `toAccountId` |
| `_transactionAmount` | `amount` |
| `_transactionReason` | `reason` |
| `_transactionStatus` | `status` |
| `_transactionInitiatedBy` | `initiatedBy` |

Replace `Control.Lens` with `Optics`. Replace `makeLenses` with `makeFieldLabelsNoPrefix`. Replace `deriveJSON (unPrefixLower "_transaction")` with `deriveJSON defaultOptions`. Update all lens access to `#label` syntax.

#### Step 4: Update Transaction CommandHandler

Same pattern — replace lens import, update `(^.)` to use `#label`.

#### Step 5: Commit

```bash
git add src/Domain/Transaction/Events.hs src/Domain/Transaction/Commands.hs src/Domain/Transaction/Projection.hs src/Domain/Transaction/CommandHandler.hs
git commit -m "refactor: unprefix Transaction bounded context fields, switch to optics"
```

---

### Task 7: Domain/Models.hs

**Files:**
- Modify: `src/Domain/Models.hs`

This file uses Template Haskell to generate sum types. Check if any record fields need updating. The sum type constructors (e.g., `AccountCreatedAccountEvent`) are generated by TH and don't change. The `deriveJSON` with `dropSuffix` operates on constructor names, not fields.

**Step 1: Verify no field changes needed**

Read the file and confirm whether any record fields or field-dependent code needs updating.

**Step 2: Commit (if changes needed)**

```bash
git add src/Domain/Models.hs
git commit -m "refactor: update Domain.Models for unprefixed fields"
```

---

### Task 8: Application layer — ReadModels and ProcessManagers

**Files:**
- Modify: `src/Application/ReadModels/AccountSummary.hs`
- Modify: `src/Application/ReadModels/TransactionSummary.hs`
- Modify: `src/Application/ProcessManagers/TransferManager.hs`
- Modify: any other files in `src/Application/`

#### Step 1: Unprefix AccountSummary read model

**AccountSummaryData:**
| Before | After |
|--------|-------|
| `accountSummaryDataName` | `name` |
| `accountSummaryDataBalance` | `balance` |
| `accountSummaryDataCreatedBy` | `createdBy` |
| `accountSummaryDataType` | `accountType` |
| `accountSummaryDataAccessList` | `accessList` |
| `accountSummaryDataVersion` | `version` |

**AccountSummaryWithRole:**
| Before | After |
|--------|-------|
| `accountSummaryWithRoleData` | `summaryData` |
| `accountSummaryWithRoleUserRole` | `userRole` |

**AccountSummaryReadModel:**
| Before | After |
|--------|-------|
| `accountSummaryLatestSequence` | `latestSequence` |
| `accountSummaryData` | `summaryData` |

Update all record construction, pattern matching, and `RecordWildCards` bindings. Event field access (e.g., `accountCreatedName evt`) becomes `evt.name` using `OverloadedRecordDot`.

#### Step 2: Unprefix TransactionSummary read model

Apply same pattern to TransactionSummaryData and TransactionSummaryReadModel. Strip `transactionSummaryData` prefix from fields.

#### Step 3: Unprefix TransferManager and switch to optics

**TransferManager:**
| Before | After |
|--------|-------|
| `_transferManagerTransfers` | `transfers` |

**TransferData:**
| Before | After |
|--------|-------|
| `transferDataSourceAccount` | `sourceAccount` |
| `transferDataTargetAccount` | `targetAccount` |
| `transferDataAmount` | `amount` |
| `transferDataReason` | `reason` |
| `transferDataPhase` | `phase` |

Replace imports:
```haskell
-- Before
import Control.Lens (at, makeLenses, (%~), (&), (?~), (^.))

-- After
import Optics (at, makeFieldLabelsNoPrefix, (%~), (&), (?~), (^.))
```

Replace `makeLenses ''TransferManager` with `makeFieldLabelsNoPrefix ''TransferManager`.

Update lens composition (critical difference):
```haskell
-- Before (lens uses . for composition)
manager ^. transferManagerTransfers . at txId

-- After (optics uses % for composition)
manager ^. #transfers % at txId
```

Update all `transferManagerTransfers` lens references to `#transfers`.

#### Step 4: Update any Service files

Check `src/Application/Services/` for references to old field names (especially in record construction/pattern matching). Update accordingly.

#### Step 5: Commit

```bash
git add src/Application/
git commit -m "refactor: unprefix Application layer fields, switch TransferManager to optics"
```

---

### Task 9: Web layer — Types and Handlers

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/Handlers/AccountHandler.hs`
- Modify: `src/Web/Handlers/TransactionHandler.hs`
- Modify: any other Web handler files

#### Step 1: Unprefix Web DTOs

**CreateAccountRequest:**
| Before | After |
|--------|-------|
| `createAccountRequestName` | `name` |
| `createAccountRequestInitialBalance` | `initialBalance` |

**AccountResponse:**
| Before | After |
|--------|-------|
| `accountResponseId` | `id` |
| `accountResponseName` | `name` |
| `accountResponseBalance` | `balance` |
| `accountResponseVersion` | `version` |

**AccountListResponse:**
| Before | After |
|--------|-------|
| `accountListResponseAccounts` | `accounts` |
| `accountListResponseTotalCount` | `totalCount` |

**TransferRequest:**
| Before | After |
|--------|-------|
| `transferRequestFromAccountId` | `fromAccountId` |
| `transferRequestToAccountId` | `toAccountId` |
| `transferRequestAmount` | `amount` |
| `transferRequestReason` | `reason` |

**TransactionResponse:**
| Before | After |
|--------|-------|
| `transactionResponseId` | `id` |
| `transactionResponseFromAccountId` | `fromAccountId` |
| `transactionResponseToAccountId` | `toAccountId` |
| `transactionResponseAmount` | `amount` |
| `transactionResponseReason` | `reason` |
| `transactionResponseStatus` | `status` |
| `transactionResponseFailureReason` | `failureReason` |

**TransactionStatusResponse:**
| Before | After |
|--------|-------|
| `transactionStatusResponseId` | `id` |
| `transactionStatusResponseStatus` | `status` |

**ErrorResponse:**
| Before | After |
|--------|-------|
| `errorResponseMessage` | `message` |
| `errorResponseCode` | `code` |
| `errorResponseDetails` | `details` |

**ValidationErrorResponse:**
| Before | After |
|--------|-------|
| `validationErrorResponseMessage` | `message` |
| `validationErrorResponseFieldErrors` | `fieldErrors` |

#### Step 2: Update manual ToJSON/FromJSON instances

The JSON keys stay the same (these are the API contract). Only the Haskell field names referenced via `RecordWildCards` change:

```haskell
-- Before
instance ToJSON AccountResponse where
  toJSON AccountResponse {..} =
    object
      [ "accountId" .= accountResponseId,
        "accountName" .= accountResponseName
      ]

-- After
instance ToJSON AccountResponse where
  toJSON AccountResponse {..} =
    object
      [ "accountId" .= id,
        "accountName" .= name
      ]
```

Apply to all manual ToJSON/FromJSON instances.

#### Step 3: Update conversion functions

Update `fromAccountSummary`, `fromTransactionSummary`, `fromTransaction`, `toCreateAccountCommand`, `toInitiateTransferCommand`:

```haskell
-- Before
fromTransaction txId tx =
  TransactionResponse
    { transactionResponseId = unTransactionId txId,
      transactionResponseFromAccountId = unAccountId (_transactionFromAccountId tx),
      ...
    }

-- After
fromTransaction txId tx =
  TransactionResponse
    { id = unTransactionId txId,
      fromAccountId = unAccountId tx.fromAccountId,
      ...
    }
```

#### Step 4: Update Web Handlers

Search all handler files for old field names in record construction/destruction and update.

#### Step 5: Commit

```bash
git add src/Web/
git commit -m "refactor: unprefix Web layer DTOs, preserve JSON API contract"
```

---

### Task 10: Infrastructure — Config and remaining files

**Files:**
- Modify: `src/Infrastructure/Config.hs`
- Modify: `src/Infrastructure/Database.hs` (if any field references)
- Modify: `src/Infrastructure/Auth/*.hs` (if any field references)
- Modify: `src/Telegram/*.hs` (if any field references)
- Modify: `app/Main.hs`

#### Step 1: Unprefix Config types

Check `src/Infrastructure/Config.hs` for prefixed record fields and rename them. Update all usages.

#### Step 2: Update Main.hs

Update AppEnv construction to use new field names (already renamed in Task 2). Check for any other field references.

#### Step 3: Update Telegram modules

`src/Telegram/Commands.hs` and `src/Telegram/Bot.hs` likely reference AppEnv fields via `view`. These should work unchanged since they use the HasX lens names (e.g., `view userSummaryReadModelL`), not direct field selectors.

Check for any direct field access on domain types and update to use dot syntax.

#### Step 4: Grep for remaining old field names

Run a project-wide search for any remaining old prefixed field names:
```bash
grep -rn 'appLogFunc\|appConfig\|appDbPool\|_account\|_user\|_transaction\|accountCreated\|accountDebited' src/ app/
```

Fix any remaining references.

#### Step 5: Commit

```bash
git add src/Infrastructure/ src/Telegram/ app/
git commit -m "refactor: unprefix Infrastructure and Telegram field references"
```

---

### Task 11: Test files

**Files:**
- Modify: `test/Domain/Account/CommandHandlerSpec.hs`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs`
- Modify: `test/Domain/Transaction/CommandHandlerSpec.hs`
- Modify: `test/Domain/Transaction/CommandHandlerPropertySpec.hs`
- Modify: `test/Domain/User/CommandHandlerSpec.hs`
- Modify: `test/Application/ProcessManagers/TransferManagerSpec.hs`
- Modify: `test/Application/ProcessManagers/TransferManagerPropertySpec.hs`
- Modify: `test/TestSupport/Generators.hs`
- Modify: `test/TestSupport/Helpers.hs`
- Modify: any other test files

#### Step 1: Update lens imports in test files

Replace `import Control.Lens ((^.))` with `import Optics ((^.))` in:
- `test/Domain/Account/CommandHandlerPropertySpec.hs`
- `test/Domain/Account/CommandHandlerSpec.hs`
- `test/Domain/Transaction/CommandHandlerPropertySpec.hs`
- `test/Domain/Transaction/CommandHandlerSpec.hs`
- `test/Domain/User/CommandHandlerSpec.hs`

Replace `import qualified Control.Lens as Lens` with `import qualified Optics as Optics` (or unqualified) in:
- `test/Application/ProcessManagers/TransferManagerPropertySpec.hs`
- `test/Application/ProcessManagers/TransferManagerSpec.hs`

Update `Lens.view accountBalance` to `Optics.view #balance` (or use `(^.)` directly).

#### Step 2: Update record construction in tests

All test files that construct events, commands, or domain types with old prefixed field names need updating. Use the same rename tables from Tasks 3-9.

#### Step 3: Update lens access in tests

Replace named lens access with `#label` syntax:
```haskell
-- Before
result ^. accountBalance

-- After
result ^. #balance
```

#### Step 4: Update TestSupport files

Check `Generators.hs` and `Helpers.hs` for record construction with old field names and update.

#### Step 5: Commit

```bash
git add test/
git commit -m "refactor: update tests for unprefixed fields and optics"
```

---

### Task 12: Build, test, and verify

**Step 1: Full build**

Run: `just build`
Expected: Clean compilation with no errors.

**Step 2: Run formatter**

Run: `just format`
Expected: All files formatted. If ormolu reformats anything, stage the changes.

**Step 3: Run linter**

Run: `just lint`
Expected: No new warnings from hlint. Address any warnings.

**Step 4: Run full test suite**

Run: `just test`
Expected: All existing tests pass.

**Step 5: Grep for any remaining prefixed fields**

Search for common old patterns to ensure nothing was missed:
```bash
grep -rn '_account\|_user\|_transaction\|accountCreated[A-Z]\|accountResponse[A-Z]\|transferRequest[A-Z]\|appLogFunc\|appConfig\|appDbPool' src/ app/ test/
```

**Step 6: Final commit**

```bash
git add -A
git commit -m "refactor: complete unprefixed record fields migration to optics"
```
