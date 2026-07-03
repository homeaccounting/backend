# Default Accounts & `configuration.defaults` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group all Configuration defaults into a `defaults` sub-structure (`incomeCategory`, `expenseCategory`, `account`, `subtypeAccounts`), add global + per-subtype default accounts, and make the NL prompt resolver use them via a deterministic precedence ladder.

**Architecture:** CQRS + Event Sourcing. Additive events on the Configuration aggregate; the projected state, read model, and API DTO nest defaults under `defaults`. Per-subtype accounts are a bounded `Map AccountSubtypeKind AccountId` stored as one JSON column (house `jsonToPersist`/`SqlString` pattern), not a child table. Account-ownership validation lives in the service layer (the pure handler has no Account-aggregate knowledge), mirroring `setBankConnectionAccountMap`.

**Tech Stack:** GHC 9.10, RIO prelude, Servant, Eventium, persistent/esqueleto (Postgres), Hspec + QuickCheck, LiquidHaskell.

**Spec:** `docs/specs/2026-07-02-default-accounts-design.md`

**Conventions (read before starting):**
- `nix develop` first. Build: `just build`. Test: `just test`. Format+lint: `just check`. Definitive `-Werror`: `just rebuild`.
- Run a focused spec: `cabal test all --test-option='--match' --test-option="/PATTERN/"`.
- Never export data constructors / field selectors — smart constructors + accessors only. `NoImplicitPrelude` (RIO), `StrictData`, `OverloadedRecordDot`, `NoFieldSelectors`, `DuplicateRecordFields`.
- Format after every code change (`just format`) and keep `-fci` green.
- Commit after each task (Conventional Commits, scope `config`/`prompt`/`read-models`).

---

## File Structure

**Domain (`src/Domain/`)**
- `Core/Types.hs` — add `AccountSubtypeKind`, `accountSubtypeKind`, `DefaultSubtypeAccounts` newtype.
- `Configuration/Projection.hs` — `ConfigurationDefaults` sub-record; nest into `Configuration`; new event handlers.
- `Configuration/Events.hs` — `DefaultAccountSet`, `DefaultSubtypeAccountsSet`.
- `Configuration/Commands.hs` — `SetDefaultAccount`, `SetDefaultSubtypeAccounts`.
- `Configuration/CommandHandler.hs` — new command arms; `isGlobalDefault` reads nested defaults.

**Infrastructure (`src/Infrastructure/`)**
- `Database/Orphans.hs` — `PersistField`/`PersistFieldSql` for `AccountSubtypeKind` and `DefaultSubtypeAccounts`.

**Application (`src/Application/`)**
- `ReadModels/Configuration.hs` — nest `defaults` in `ConfigurationData`; two new columns; new event arms; load/seed.
- `ReadModels/Account.hs` — `getUserRegularAccounts` also returns `AccountSubtypeKind`.
- `Services/ConfigurationService.hs` — `setDefaultAccount`, `setDefaultSubtypeAccounts` (+ validation); extend `copyDefaults`.
- `Services/Prompt/Transaction/Resolve.hs` — precedence ladder + keyword map.
- `Services/Prompt/Transaction/Handler.hs` — build the extended `ResolveContext`.

**Web (`src/Web/`)**
- `API/ConfigurationAPI.hs` — `ConfigurationDefaultsDTO`, nest in `ConfigurationResponse`, extend `UpdateDefaultsRequest` + handler.

**Tests (`test/`)** — see per-task Test entries.

---

## Task 1: `AccountSubtypeKind` discriminator + projection

**Files:**
- Modify: `src/Domain/Core/Types.hs` (near `AccountSubtype`, ~line 863; add to module export list)
- Test: `test/Domain/Core/AccountSubtypeKindSpec.hs` (create) + a property in an existing `*PropertySpec.hs` if one fits; otherwise a `*Spec.hs`.

- [ ] **Step 1: Write the failing test**

`test/Domain/Core/AccountSubtypeKindSpec.hs`:
```haskell
module Domain.Core.AccountSubtypeKindSpec (spec) where

import Domain.Core.Types
import Data.Aeson (decode, encode)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "AccountSubtypeKind" $ do
  it "projects each AccountSubtype constructor to its kind" $ do
    accountSubtypeKind defaultCash `shouldBe` CashKind
    accountSubtypeKind defaultBankAccount `shouldBe` BankAccountKind
    accountSubtypeKind defaultEWallet `shouldBe` EWalletKind
    accountSubtypeKind defaultAsset `shouldBe` AssetKind
    accountSubtypeKind defaultLoan `shouldBe` LoanKind

  it "round-trips through JSON" $
    forM_ [minBound .. maxBound] $ \k ->
      decode (encode (k :: AccountSubtypeKind)) `shouldBe` Just k
```

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/AccountSubtypeKind/"`
Expected: FAIL — `AccountSubtypeKind`/`accountSubtypeKind` not in scope.

- [ ] **Step 3: Implement in `Domain/Core/Types.hs`**

Add after `AccountSubtype` (~line 869). Follow the file's existing JSON style (it uses `aeson` with `Generic` and manual `ToJSONKey` where needed):
```haskell
-- | Payload-free discriminator over 'AccountSubtype' constructors, for use as a
-- map key and wire tag (mirrors the query-side 'StatusKind' pattern).
data AccountSubtypeKind
  = CashKind
  | BankAccountKind
  | EWalletKind
  | AssetKind
  | LoanKind
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

instance ToJSON AccountSubtypeKind

instance FromJSON AccountSubtypeKind

instance ToJSONKey AccountSubtypeKind

instance FromJSONKey AccountSubtypeKind

-- | Payload-free projection of an 'AccountSubtype'.
accountSubtypeKind :: AccountSubtype -> AccountSubtypeKind
accountSubtypeKind (Cash _) = CashKind
accountSubtypeKind (BankAccount _) = BankAccountKind
accountSubtypeKind (EWallet _) = EWalletKind
accountSubtypeKind (Asset _) = AssetKind
accountSubtypeKind (Loan _) = LoanKind
```
Add `AccountSubtypeKind (..)`, `accountSubtypeKind` to the module export list (the `Core.Types` export block). Confirm `ToJSONKey`/`FromJSONKey` are imported from `Data.Aeson` in this module (add to the import list if absent).

- [ ] **Step 4: Run to verify it passes**

Run: `cabal test all --test-option='--match' --test-option="/AccountSubtypeKind/"`
Expected: PASS. Then `just format`.

- [ ] **Step 5: Commit**
```bash
git add src/Domain/Core/Types.hs test/Domain/Core/AccountSubtypeKindSpec.hs
git commit -m "feat(config): add AccountSubtypeKind discriminator and projection"
```

---

## Task 2: `ConfigurationDefaults` sub-record (domain projection nest)

Pure structural change: replace the flat `defaultIncomeCategory` / `defaultExpenseCategory` on `Configuration` with `defaults :: ConfigurationDefaults`. Behavior of existing events is preserved.

**Files:**
- Modify: `src/Domain/Configuration/Projection.hs` (record ~line 137, `configurationDefault` ~line 164, handlers ~line 226-282; exports ~line 15-33)
- Modify: `src/Domain/Configuration/CommandHandler.hs` (`isGlobalDefault` ~line 142)
- Test: `test/Domain/Configuration/ProjectionSpec.hs` (update existing assertions)

- [ ] **Step 1: Update the failing test first**

In `ProjectionSpec.hs`, change assertions that read `config.defaultIncomeCategory` / `config.defaultExpenseCategory` to `config.defaults.incomeCategory` / `config.defaults.expenseCategory`. Add an assertion that a fresh projection has `defaults.account == Nothing` and `defaults.subtypeAccounts == mempty`.

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/Configuration.Projection/"`
Expected: FAIL — record field `defaults` not present.

- [ ] **Step 3: Implement the sub-record**

In `Projection.hs`:
1. Add the record + empty value + exports (`ConfigurationDefaults (..)`, `emptyConfigurationDefaults`):
```haskell
-- | All per-configuration defaults, grouped (mirrors the 'BankingConfiguration'
-- sub-record). @account@ is the global fallback account; @subtypeAccounts@ is the
-- default account per account subtype.
data ConfigurationDefaults = ConfigurationDefaults
  { incomeCategory :: !(Maybe CategoryId),
    expenseCategory :: !(Maybe CategoryId),
    account :: !(Maybe AccountId),
    subtypeAccounts :: !(Map AccountSubtypeKind AccountId)
  }
  deriving (Show, Eq)

emptyConfigurationDefaults :: ConfigurationDefaults
emptyConfigurationDefaults =
  ConfigurationDefaults
    { incomeCategory = Nothing,
      expenseCategory = Nothing,
      account = Nothing,
      subtypeAccounts = Map.empty
    }
```
2. In `Configuration`, replace the two flat fields with `defaults :: ConfigurationDefaults`.
3. In `configurationDefault`, replace them with `defaults = emptyConfigurationDefaults`.
4. Update the two existing handlers:
```haskell
handleConfigurationEvent config (DefaultIncomeCategorySetConfigurationEvent evt) =
  config {defaults = config.defaults {incomeCategory = Just evt.categoryId}}
handleConfigurationEvent config (DefaultExpenseCategorySetConfigurationEvent evt) =
  config {defaults = config.defaults {expenseCategory = Just evt.categoryId}}
```
5. The `BaseCurrencyChanged` / `DefaultCurrencyChanged` handlers use `RecordWildCards` to rebuild `Configuration {..}` — replace the two removed field bindings with `defaults = defaults` (keep the wildcard-bound `defaults`).
6. Import `AccountSubtypeKind` from `Domain.Core.Types`.

In `CommandHandler.hs`, update `isGlobalDefault`:
```haskell
isGlobalDefault eid config =
  config.defaults.incomeCategory == Just eid
    || config.defaults.expenseCategory == Just eid
```

- [ ] **Step 4: Run to verify it passes**

Run: `cabal test all --test-option='--match' --test-option="/Configuration/"`
Expected: PASS (Projection + CommandHandler specs). `just format`.

- [ ] **Step 5: Commit**
```bash
git add src/Domain/Configuration/Projection.hs src/Domain/Configuration/CommandHandler.hs test/Domain/Configuration/ProjectionSpec.hs
git commit -m "refactor(config)!: nest defaults under ConfigurationDefaults sub-record"
```

---

## Task 3: New events `DefaultAccountSet` / `DefaultSubtypeAccountsSet`

**Files:**
- Modify: `src/Domain/Configuration/Events.hs` (event list ~line 76, event types ~line 155-165, `deriveJSON` ~line 254)
- Modify: `src/Domain/Configuration/Projection.hs` (new handler arms)
- Test: `test/Domain/Configuration/ProjectionSpec.hs`

- [ ] **Step 1: Write failing tests**

Add to `ProjectionSpec.hs`: folding `DefaultAccountSet {accountId = a}` yields `defaults.account == Just a`; folding `DefaultSubtypeAccountsSet {subtypeAccounts = m}` yields `defaults.subtypeAccounts == m`; a second `DefaultSubtypeAccountsSet` **replaces** (does not merge) the map. Use mock `AccountId` from `Testkit/Helpers.hs` (add a helper if none exists).

- [ ] **Step 2: Run — FAIL** (`DefaultAccountSet` not in scope).

- [ ] **Step 3: Implement**

`Events.hs`:
- Add to `configurationEvents`: `''DefaultAccountSet`, `''DefaultSubtypeAccountsSet`.
- Add types (import `AccountId`, `AccountSubtypeKind`, `Map`):
```haskell
-- | Event: the global default account was set.
newtype DefaultAccountSet = DefaultAccountSet {accountId :: AccountId}
  deriving (Show, Eq)

-- | Event: the per-subtype default-account map was replaced wholesale.
newtype DefaultSubtypeAccountsSet = DefaultSubtypeAccountsSet
  {subtypeAccounts :: Map AccountSubtypeKind AccountId}
  deriving (Show, Eq)
```
- Add to exports and `deriveJSON defaultOptions ''DefaultAccountSet` / `''DefaultSubtypeAccountsSet`.

`Projection.hs` — import the two events; add handlers:
```haskell
handleConfigurationEvent config (DefaultAccountSetConfigurationEvent evt) =
  config {defaults = config.defaults {account = Just evt.accountId}}
handleConfigurationEvent config (DefaultSubtypeAccountsSetConfigurationEvent evt) =
  config {defaults = config.defaults {subtypeAccounts = evt.subtypeAccounts}}
```

- [ ] **Step 4: Run — PASS.** `just format`.

- [ ] **Step 5: Commit**
```bash
git add src/Domain/Configuration/Events.hs src/Domain/Configuration/Projection.hs test/Domain/Configuration/ProjectionSpec.hs
git commit -m "feat(config): add DefaultAccountSet and DefaultSubtypeAccountsSet events"
```

---

## Task 4: New commands `SetDefaultAccount` / `SetDefaultSubtypeAccounts`

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs` (command list ~line 68, types ~line 164-180, `deriveJSON` ~line 290)
- Modify: `src/Domain/Configuration/CommandHandler.hs` (new arms)
- Test: `test/Domain/Configuration/CommandHandlerSpec.hs`

- [ ] **Step 1: Write failing tests**

`SetDefaultAccount {accountId = a}` on a created config → `[DefaultAccountSet {accountId = a}]` (no account validation in the pure handler). `SetDefaultSubtypeAccounts {subtypeAccounts = m}` → `[DefaultSubtypeAccountsSet {subtypeAccounts = m}]`. (Match the arrange/act/assert style already in the file.)

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**

`Commands.hs`:
- Add `''SetDefaultAccount`, `''SetDefaultSubtypeAccounts` to `configurationCommands`.
- Add types (import `AccountId`, `AccountSubtypeKind`, `Map`):
```haskell
-- | Command: set the global default account. Account-existence/ownership is
-- validated in the service layer, not here (the aggregate has no account view).
newtype SetDefaultAccount = SetDefaultAccount {accountId :: AccountId}
  deriving (Show, Eq)

-- | Command: replace the per-subtype default-account map wholesale.
newtype SetDefaultSubtypeAccounts = SetDefaultSubtypeAccounts
  {subtypeAccounts :: Map AccountSubtypeKind AccountId}
  deriving (Show, Eq)
```
- Add to exports and `deriveJSON`.

`CommandHandler.hs` — add arms (emit unconditionally; import the commands via the existing `Domain.Configuration.Commands` blanket import and events via `Domain.Configuration.Events`):
```haskell
handleConfigurationCommand _ (SetDefaultAccountConfigurationCommand SetDefaultAccount {..}) =
  Right [DefaultAccountSetConfigurationEvent DefaultAccountSet {accountId = accountId}]
handleConfigurationCommand _ (SetDefaultSubtypeAccountsConfigurationCommand SetDefaultSubtypeAccounts {..}) =
  Right [DefaultSubtypeAccountsSetConfigurationEvent DefaultSubtypeAccountsSet {subtypeAccounts = subtypeAccounts}]
```

- [ ] **Step 4: Run — PASS.** `just format`.

- [ ] **Step 5: Commit**
```bash
git add src/Domain/Configuration/Commands.hs src/Domain/Configuration/CommandHandler.hs test/Domain/Configuration/CommandHandlerSpec.hs
git commit -m "feat(config): add SetDefaultAccount and SetDefaultSubtypeAccounts commands"
```

---

## Task 5: Persistence instances for the subtype-account map

**Files:**
- Modify: `src/Domain/Core/Types.hs` (add `DefaultSubtypeAccounts` newtype + accessor + JSON)
- Modify: `src/Infrastructure/Database/Orphans.hs` (`PersistField`/`PersistFieldSql`)
- Test: `test/Infrastructure/Database/OrphansSpec.hs` (create or extend if present)

- [ ] **Step 1: Write failing test**

Round-trip: `fromPersistValue (toPersistValue x) == Right x` for a `DefaultSubtypeAccounts` holding a couple of entries and for the empty map.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**

In `Core/Types.hs` add (export `DefaultSubtypeAccounts (..)`, `unDefaultSubtypeAccounts`):
```haskell
-- | Newtype wrapper so the per-subtype default-account map can carry a
-- 'PersistField' instance (stored as one JSON column) without an orphan on 'Map'.
newtype DefaultSubtypeAccounts = DefaultSubtypeAccounts
  {unDefaultSubtypeAccounts :: Map AccountSubtypeKind AccountId}
  deriving (Show, Eq, Generic)

instance ToJSON DefaultSubtypeAccounts

instance FromJSON DefaultSubtypeAccounts
```

In `Orphans.hs` (mirror the `AccountType` instance at ~line 165):
```haskell
instance PersistField AccountSubtypeKind where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql AccountSubtypeKind where
  sqlType _ = SqlString

instance PersistField DefaultSubtypeAccounts where
  toPersistValue = jsonToPersist
  fromPersistValue = jsonFromPersist

instance PersistFieldSql DefaultSubtypeAccounts where
  sqlType _ = SqlString
```
(Import `AccountSubtypeKind`, `DefaultSubtypeAccounts` from `Domain.Core.Types`.)

- [ ] **Step 4: Run — PASS.** `just format`.

- [ ] **Step 5: Commit**
```bash
git add src/Domain/Core/Types.hs src/Infrastructure/Database/Orphans.hs test/Infrastructure/Database/OrphansSpec.hs
git commit -m "feat(config): persist AccountSubtypeKind and default subtype-account map as JSON columns"
```

---

## Task 6: Read model — nest defaults, add columns, handle new events

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs` (query type ~line 132, schema ~line 168, `applyConfigurationEvent` ~line 243, `getConfiguration` ~line 378, imports)
- Modify all `ConfigurationData` field consumers to nested access (mechanical): `src/Web/API/ConfigurationAPI.hs`, `src/Application/Services/Prompt/Transaction/Handler.hs`, `src/Application/Services/ConfigurationService.hs` (`copyDefaults`), `src/Application/Services/BankImportService.hs` (uses `defaultIncomeCategory`/`defaultExpenseCategory`).
- Test: `test/Application/Services/ConfigurationServiceIntegrationSpec.hs` (round-trip), plus fix references in specs listed under "ripple" below.

- [ ] **Step 1: Update/author failing test**

In an integration spec, after applying `SetDefaultAccount` and `SetDefaultSubtypeAccounts` to a config, assert `getConfiguration` returns `defaults.account == Just a` and `defaults.subtypeAccounts == m`. Update existing reads of `configData.defaultIncomeCategory` → `configData.defaults.incomeCategory`.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**

1. `ConfigurationData`: replace the two flat fields with `defaults :: ConfigurationDefaults` (import from `Domain.Configuration.Projection`). Keep `banking`, `booksClosedThrough`, etc. as-is.
2. Schema `ConfigurationEntity`: keep `defaultIncomeCategory`/`defaultExpenseCategory`; add
   ```
   defaultAccount AccountId Maybe
   defaultSubtypeAccounts DefaultSubtypeAccounts
   ```
   (import `DefaultSubtypeAccounts`). The non-nullable map column defaults to the empty map on insert.
3. `ConfigurationCreated` insert: add `configurationEntityDefaultAccount = Nothing`, `configurationEntityDefaultSubtypeAccounts = DefaultSubtypeAccounts Map.empty`.
4. New arms in `applyConfigurationEvent`:
   ```haskell
   DefaultAccountSetEvent evt ->
     modifyConfig configId (\e -> e {configurationEntityDefaultAccount = Just evt.accountId, configurationEntityVersion = ver})
   DefaultSubtypeAccountsSetEvent evt ->
     modifyConfig configId (\e -> e {configurationEntityDefaultSubtypeAccounts = DefaultSubtypeAccounts evt.subtypeAccounts, configurationEntityVersion = ver})
   ```
   Import both events.
5. `getConfiguration`: build `defaults = ConfigurationDefaults { incomeCategory = e.configurationEntityDefaultIncomeCategory, expenseCategory = e.configurationEntityDefaultExpenseCategory, account = e.configurationEntityDefaultAccount, subtypeAccounts = unDefaultSubtypeAccounts e.configurationEntityDefaultSubtypeAccounts }`.

6. **Ripple — mechanical nested-access renames** (no behavior change), so the build stays green:
   - `ConfigurationService.copyDefaults`: `srcConfig.defaultIncomeCategory` → `srcConfig.defaults.incomeCategory` (and expense).
   - `BankImportService`: same rename at its `configData.defaultIncomeCategory` / `defaultExpenseCategory` reads.
   - `Prompt/Transaction/Handler.hs buildContexts`: `cfg.defaultIncomeCategory` → `cfg.defaults.incomeCategory` (expanded properly in Task 9; a minimal rename here keeps it compiling).
   - `Web/API/ConfigurationAPI.hs toConfigurationResponse`: `configData.defaultIncomeCategory` → `configData.defaults.incomeCategory` (DTO reshape is Task 8; keep the flat response fields for now, just fix the source of the value).

- [ ] **Step 4: Run — PASS.** Requires Postgres: `just docker-up` then `just test`. Confirm `-fci`: `just rebuild`.

- [ ] **Step 5: Commit**
```bash
git add src/Application/ReadModels/Configuration.hs src/Application/Services/ConfigurationService.hs src/Application/Services/BankImportService.hs src/Application/Services/Prompt/Transaction/Handler.hs src/Web/API/ConfigurationAPI.hs test/
git commit -m "feat(read-models): nest configuration defaults and persist default accounts"
```

**Ripple checklist** (fix any remaining `defaultIncomeCategory`/`defaultExpenseCategory` field-access compile errors in these specs; grep first): `test/Application/Services/BankImportServiceSpec.hs`, `test/Application/Services/ConfigurationServiceSpec.hs`, `test/Integration/BankImportWorkflowSpec.hs`, `test/Web/API/ConfigurationBankingAPISpec.hs`, `test/Domain/Configuration/LabelsDictionarySpec.hs`, `test/Application/Services/Prompt/Transaction/ResolveSpec.hs`, `test/Integration/TransactionPromptIntegrationSpec.hs`. Run `grep -rn "\.defaultIncomeCategory\|\.defaultExpenseCategory" test src` and reconcile.

---

## Task 7: Service — `setDefaultAccount` / `setDefaultSubtypeAccounts` + clone

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs` (exports ~line 24, functions after `setDefaultExpenseCategory` ~line 294, `copyDefaults` ~line 746)
- Test: `test/Application/Services/ConfigurationServiceIntegrationSpec.hs`

- [ ] **Step 1: Write failing tests**

- Setting a default account the user owns (Owner/Editor, Regular) succeeds and is reflected by `getConfigurationForUser`.
- Setting a default account the user does **not** own → `Left (ValidationErr ...)` on field `"account"`; no event emitted.
- `setDefaultSubtypeAccounts` with a non-owned target in the map → rejected; with all owned → succeeds.
- Cloning a config carries `defaults.account` and `defaults.subtypeAccounts` into the clone.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**

Add validation helper + two service functions. This follows `setBankConnectionAccountMap`'s `getAccessibleAccounts` writable-role check, **plus** an added `isRegular` filter that the spec requires (note: `setBankConnectionAccountMap` itself only checks `Owner`/`Editor`, not `isRegular` — the `isRegular` guard is new here). `getAccessibleAccounts` returns `[(AccountId, AccountData, AccountRole)]`; a Regular writable account is `isRegular accData.accountType && role ∈ {Owner,Editor}`:
```haskell
-- | Reject unless every AccountId is a Regular account the user can write to.
validateOwnedRegularAccounts :: UserId -> [AccountId] -> ExceptT DomainError AppM ()
validateOwnedRegularAccounts userId targets = do
  accessible <- lift (runDb (getAccessibleAccounts userId))
  let writable =
        Set.fromList
          [ accId
          | (accId, accData, role) <- accessible,
            isRegular accData.accountType,
            role == Owner || role == Editor
          ]
  unless (all (`Set.member` writable) targets)
    $ throwE (ValidationErr (mkValidationError "account" "account is not owned/regular" ""))

setDefaultAccount :: UserId -> AccountId -> AppM (Either DomainError ())
setDefaultAccount userId accountId = runExceptT $ do
  validateOwnedRegularAccounts userId [accountId]
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd defaultTranslateConfigurationError id (unConfigurationId configId)
    (SetDefaultAccountConfigurationCommand SetDefaultAccount {accountId = accountId})

setDefaultSubtypeAccounts :: UserId -> Map AccountSubtypeKind AccountId -> AppM (Either DomainError ())
setDefaultSubtypeAccounts userId m = runExceptT $ do
  validateOwnedRegularAccounts userId (Map.elems m)
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd defaultTranslateConfigurationError id (unConfigurationId configId)
    (SetDefaultSubtypeAccountsConfigurationCommand SetDefaultSubtypeAccounts {subtypeAccounts = m})
```
Imports: `SetDefaultAccount (..)`, `SetDefaultSubtypeAccounts (..)` from `Domain.Configuration.Commands`; `isRegular`, `AccountSubtypeKind`, `mkValidationError`; `AccountData (..)` from the account read model (already imports `getAccessibleAccounts`). Export both functions.

Extend `copyDefaults` to also emit `SetDefaultAccount` (when `srcConfig.defaults.account` is `Just`) and `SetDefaultSubtypeAccounts` (when the map is non-empty), best-effort/logged like the category copies.

- [ ] **Step 4: Run — PASS** (`just docker-up` first). `just format`; `just rebuild`.

- [ ] **Step 5: Commit**
```bash
git add src/Application/Services/ConfigurationService.hs test/Application/Services/ConfigurationServiceIntegrationSpec.hs
git commit -m "feat(config): service ops for default account + subtype accounts with ownership validation"
```

---

## Task 8: Web — nested `defaults` DTO + extended update endpoint

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs` (`ConfigurationResponse` ~line 320, `UpdateDefaultsRequest` ~line 424, `updateDefaultsHandler` ~line 579, `toConfigurationResponse` ~line 781)
- Test: `test/Web/API/ConfigurationBankingAPISpec.hs` (or a config API spec)

- [ ] **Step 1: Write failing tests**

`ConfigurationResponse` serialises a nested `defaults` object with `incomeCategory`/`expenseCategory`/`account`/`subtypeAccounts`. `PUT /api/users/me/configuration/defaults` with `{account, subtypeAccounts}` applies them; GET reflects them. Non-owned account → 400.

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**

1. New DTO + nest:
```haskell
data ConfigurationDefaultsDTO = ConfigurationDefaultsDTO
  { incomeCategory :: Maybe UUID,
    expenseCategory :: Maybe UUID,
    account :: Maybe UUID,
    subtypeAccounts :: Map AccountSubtypeKind UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON ConfigurationDefaultsDTO
instance FromJSON ConfigurationDefaultsDTO
```
Replace the two top-level `defaultIncomeCategory`/`defaultExpenseCategory` fields on `ConfigurationResponse` with `defaults :: ConfigurationDefaultsDTO`. In `toConfigurationResponse`, build it from `configData.defaults` (`unDictionaryEntryId <$> ...` for categories; `unAccountId <$> ...` for account; `Map.map unAccountId configData.defaults.subtypeAccounts`).
2. Extend `UpdateDefaultsRequest`:
```haskell
data UpdateDefaultsRequest = UpdateDefaultsRequest
  { incomeCategory :: Maybe UUID,
    expenseCategory :: Maybe UUID,
    account :: Maybe UUID,
    subtypeAccounts :: Maybe (Map AccountSubtypeKind UUID)
  }
```
(Rename the two existing fields to the nested names.)
3. `updateDefaultsHandler`: keep the two category `forM_` blocks (renamed field access); add:
   - `forM_ req.account $ \uuid -> do { aid <- validateFieldCtx "account" (tshow uuid) (mkAccountId uuid); ConfigService.setDefaultAccount uid aid ... }`
   - `forM_ req.subtypeAccounts $ \rawMap -> do { m <- traverse (\u -> validateFieldCtx "subtypeAccounts" (tshow u) (mkAccountId u)) rawMap; ConfigService.setDefaultSubtypeAccounts uid m ... }`
   Imports: `mkAccountId`, `unAccountId`, `AccountSubtypeKind`, the two new service functions.

- [ ] **Step 4: Run — PASS** (`just docker-up`). `just format`; `just rebuild`.

- [ ] **Step 5: Commit**
```bash
git add src/Web/API/ConfigurationAPI.hs test/Web/API/ConfigurationBankingAPISpec.hs
git commit -m "feat(config): nest defaults in configuration API response and update endpoint"
```

---

## Task 9: Resolver — precedence ladder + subtype keywords

**Files:**
- Modify: `src/Application/ReadModels/Account.hs` (`getUserRegularAccounts` ~line 352; export unchanged)
- Modify: `src/Application/Services/Prompt/Transaction/Resolve.hs` (`ResolveContext` ~line 58, `resolveAccount` ~line 131)
- Modify: `src/Application/Services/Prompt/Transaction/Handler.hs` (`gatherContext`/`buildContexts` ~line 72-112)
- Test: `test/Application/Services/Prompt/Transaction/ResolveSpec.hs`; `test/Integration/TransactionPromptIntegrationSpec.hs`

- [ ] **Step 1: Write failing tests (resolver precedence table)**

In `ResolveSpec.hs` cover, holding accounts/defaults fixed:
1. exact **name** match wins even when a subtype default exists;
2. no name but keyword `"cash"` → the `CashKind` default account;
3. keyword `"card"` → the `BankAccountKind` default (alias);
4. no keyword but exactly one account of the referenced subtype → that account;
5. omitted account (`Nothing`) → the global `account` default;
6. none of the above → `NoMatch`/`Ambiguous` (400);
7. transfer with omitted target still fails (global default does not fill a transfer target).

- [ ] **Step 2: Run — FAIL.**

- [ ] **Step 3: Implement**

`Account.hs` — extend the return type to include the subtype kind:
```haskell
getUserRegularAccounts :: (MonadIO m) => UserId -> SqlPersistT m [(AccountId, Text, Money, AccountSubtypeKind)]
getUserRegularAccounts userId = do
  rows <- selectList [AccountEntityCreatedBy ==. userId] []
  pure
    [ (e.accountEntityAccountId, e.accountEntityName, e.accountEntityBalance, kindOf e.accountEntityAccountType)
    | Entity _ e <- rows,
      isRegular e.accountEntityAccountType
    ]
  where
    kindOf (Regular st) = accountSubtypeKind st
    kindOf External = CashKind  -- unreachable: filtered by isRegular
```
Import `AccountSubtypeKind`, `accountSubtypeKind`, `Regular`, `External`, `accountSubtypeKind`.

`Resolve.hs`:
- `ResolveContext.accounts :: [(AccountId, Text, Currency, AccountSubtypeKind)]`; add `defaultAccount :: Maybe AccountId` and `subtypeAccounts :: Map AccountSubtypeKind AccountId`; keep `incomeCategories`/`expenseCategories`/labels; replace the two flat default-category fields with `defaultIncomeCategory`/`defaultExpenseCategory` (unchanged names, still needed by category resolution).
- Update `matchByName` accessor to the 4-tuple (`\(_, n, _, _) -> n`), and the tuple-returning success path — `resolveAccount` should still yield `(AccountId, Text, Currency)` to the callers, so drop the 4th element after matching.
- New precedence in `resolveAccount`:
```haskell
resolveAccount ctx fld mName = case mName of
  Just name
    | Matched acc <- matchByName (\(_,n,_,_) -> n) name ctx.accounts -> Right (drop4 acc)
  _ ->
    case mName >>= keywordSubtype of
      Just k
        | Just aid <- Map.lookup k ctx.subtypeAccounts -> byId aid fld
        | [only] <- accountsOfKind k -> Right (drop4 only)
      _ -> fallbackGlobal
  where
    accountsOfKind k = [a | a@(_,_,_,k') <- ctx.accounts, k' == k]
    fallbackGlobal = case ctx.defaultAccount of
      Just aid -> byId aid fld
      Nothing -> Left (ResolveError fld (noMatchMsg mName))
    byId aid f = case [a | a@(aid',_,_,_) <- ctx.accounts, aid' == aid] of
      (a:_) -> Right (drop4 a)
      []    -> Left (ResolveError f "configured default account no longer exists")
    drop4 (aid,nm,cur,_) = (aid,nm,cur)
```
(Refine to also handle the ambiguous-name case exactly as before — keep the current `Ambiguous`/`NoMatch` branches for the name-present path.)
- `keywordSubtype :: Text -> Maybe AccountSubtypeKind` (lowercased, stripped; contains-match):
```haskell
keywordSubtype t
  | any (`T.isInfixOf` s) ["e-wallet","ewallet","wallet"] = Just EWalletKind
  | any (`T.isInfixOf` s) ["bank","card"]                 = Just BankAccountKind
  | "cash" `T.isInfixOf` s                                = Just CashKind
  | otherwise = Nothing
  where s = T.toLower (T.strip t)
```
- **Transfer**: `resolveTransfer` keeps requiring an explicit `targetAccount` (do not route the destination through `fallbackGlobal`). Leave its current guard intact.

`Handler.hs buildContexts`: thread the 4-tuple accounts through; populate `defaultAccount`/`subtypeAccounts` from `cfg.defaults`; category defaults from `cfg.defaults.incomeCategory`/`expenseCategory`.

- [ ] **Step 4: Run — PASS.**

Run: `cabal test all --test-option='--match' --test-option="/Resolve/"` then the prompt integration spec (`just docker-up`). `just format`; `just rebuild`.

- [ ] **Step 5: Commit**
```bash
git add src/Application/ReadModels/Account.hs src/Application/Services/Prompt/Transaction/Resolve.hs src/Application/Services/Prompt/Transaction/Handler.hs test/
git commit -m "feat(prompt): resolve accounts via subtype keywords and default accounts (#26)"
```

---

## Task 10: Full-suite verification + docs

- [ ] **Step 1:** `just docker-up && just rebuild && just test` — entire suite green under `-fci`.
- [ ] **Step 2:** `just check` (format + lint) clean, no hlint suppressions.
- [ ] **Step 3:** `grep -rn "defaultIncomeCategory\|defaultExpenseCategory" src` — confirm only the read-model *entity column* names remain flat (intended); no stale projection/DTO field access.
- [ ] **Step 4:** Update `docs/architecture.md` if it documents the Configuration record/API shape; flip the spec's frontmatter `status: draft` → `completed`.
- [ ] **Step 5: Commit**
```bash
git add -A
git commit -m "docs(config): mark default-accounts design completed"
```

---

## Notes / gotchas

- **`-fci` warm-cache masking:** always `just rebuild` for the definitive `-Werror` check before committing a task that touched many modules (Tasks 6/9 especially).
- **Eventium sum-type constructors:** the TH splice appends the type name — event constructor is `DefaultAccountSetConfigurationEvent`, command is `SetDefaultAccountConfigurationCommand`. Match the existing generated names exactly.
- **`AccountId` JSON:** the API uses raw `UUID` on the wire (`unAccountId`/`mkAccountId`), consistent with the existing bank-account-map endpoints — reuse those, don't invent an `AccountId` JSON shape.
- **No new domain error variant** is needed; account-ownership failures reuse `ValidationErr`/`mkValidationError` (field `"account"`/`"subtypeAccounts"`).
- **Eventium genericity:** nothing here is generic enough to push into eventium — this is domain-specific Configuration wiring. No library change.
