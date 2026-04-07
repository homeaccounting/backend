# Rename AccountCategory/AccountType → AccountKind/AccountSubtype

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename `AccountCategory` → `AccountKind` and `AccountType` → `AccountSubtype` throughout the codebase, rename record fields to `kind`/`subtype`, and simplify JSON serialization (breaking change).

**Architecture:** Mechanical rename across all four layers (Domain → Application → Web → Tests). The rename is bottom-up: start with core types, then fix everything that depends on them. JSON serialization is simplified by removing backwards-compat aliases and custom `fieldLabelModifier` hacks.

**Tech Stack:** Haskell, Aeson (JSON), Template Haskell (eventium), Servant

**Spec:** `docs/specs/2026-04-07-rename-account-kind-subtype-design.md`

---

## File Map

| Action | File | What changes |
|--------|------|-------------|
| Modify | `src/Domain/Core/Types.hs` | Rename types, update JSON instances |
| No change | `src/Domain/Models.hs` | TH-generated constructors (`AccountTypeSetEvent` → `AccountSubtypeSetEvent`, etc.) update automatically when source types are renamed |
| Modify | `src/Domain/Account/Events.hs` | Rename imports, fields, types, remove `fieldLabelModifier` |
| Modify | `src/Domain/Account/Commands.hs` | Rename imports, fields, types, remove `fieldLabelModifier` |
| Modify | `src/Domain/Account/CommandHandler.hs` | Rename imports, pattern matches, field accesses |
| Modify | `src/Domain/Account/Projection.hs` | Rename imports, fields, lens accesses |
| Modify | `src/Application/Services/AccountService.hs` | Rename imports, field accesses |
| Modify | `src/Application/Services/TransactionService.hs` | Rename imports, field accesses |
| Modify | `src/Application/Services/AuthorizationService.hs` | Rename imports, fields |
| Modify | `src/Application/Services/AuthService.hs` | Rename imports, field assignments |
| Modify | `src/Application/ReadModels/Account.hs` | Rename imports, fields, event handling |
| Modify | `src/Web/Types.hs` | Rename imports, DTOs, conversion functions |
| Modify | `src/Web/API/AccountAPI.hs` | Rename imports, handler references |
| Modify | `src/Telegram/Commands.hs` | Rename imports, field assignments |
| Modify | `test/Domain/Account/CommandHandlerPropertySpec.hs` | Rename field accesses |
| Modify | `test/Domain/Account/CommandHandlerSpec.hs` | Rename field accesses |
| Modify | `test/Integration/TransferWorkflowSpec.hs` | Rename imports, field accesses |
| Modify | `test/Application/Services/AccountServiceSpec.hs` | Rename field accesses |
| Modify | `test/Application/Services/AuthorizationServiceSpec.hs` | Rename type references |
| Modify | `test/Application/Services/TransactionServiceSpec.hs` | Rename imports, field accesses |

---

### Task 1: Rename core types and simplify JSON (Domain.Core.Types)

**Files:**
- Modify: `src/Domain/Core/Types.hs`

This is the foundation — everything else depends on these types.

- [ ] **Step 1: Rename `AccountType` → `AccountSubtype`**

  Rename the type, all constructors stay the same. Rename all default constructors (`defaultCash :: AccountSubtype`, etc.). Update export list: `AccountType` → `AccountSubtype`.

- [ ] **Step 2: Rename `AccountCategory` → `AccountKind`**

  Rename the type. Constructor `Regular AccountType` → `Regular AccountSubtype`. Update export list.

- [ ] **Step 3: Simplify `AccountKind` JSON instances**

  Replace the custom `ToJSON`/`FromJSON` instances. Remove all backwards-compat aliases (`"ExternalAccount"`, `"RegularAccount"`, `"Internal"`).

  New `ToJSON`:
  ```haskell
  instance ToJSON AccountKind where
    toJSON External = toJSON ("External" :: Text)
    toJSON (Regular st) = object ["tag" .= ("Regular" :: Text), "subtype" .= st]
  ```

  New `FromJSON`:
  ```haskell
  instance FromJSON AccountKind where
    parseJSON (Aeson.String "External") = pure External
    parseJSON v = flip (withObject "AccountKind") v $ \o -> do
      tag <- o .: "tag"
      case (tag :: Text) of
        "Regular" -> Regular <$> o .: "subtype"
        _ -> fail $ "Unknown AccountKind tag: " <> show tag
  ```

- [ ] **Step 4: Verify it compiles (expect downstream failures)**

  Run: `just build 2>&1 | head -50`

  Expected: Compilation errors in downstream modules referencing old names. This is expected — we fix them in subsequent tasks.

- [ ] **Step 5: Commit**

  ```bash
  git add src/Domain/Core/Types.hs
  git commit -m "refactor: rename AccountCategory/AccountType to AccountKind/AccountSubtype in core types"
  ```

---

### Task 2: Rename in Events and Commands (Domain.Account)

**Files:**
- Modify: `src/Domain/Account/Events.hs`
- Modify: `src/Domain/Account/Commands.hs`

- [ ] **Step 1: Update Events.hs**

  1. Rename export `AccountTypeSet` → `AccountSubtypeSet`
  2. Update import: `AccountCategory` → `AccountKind`, `AccountType` → `AccountSubtype`
  3. Rename `AccountCreated.accountCategory` → `AccountCreated.kind` (field)
  4. Rename type `AccountTypeSet` → `AccountSubtypeSet`, field `accountType` → `subtype`
  5. Update TH event list: `''AccountTypeSet` → `''AccountSubtypeSet`
  6. Remove the custom `fieldLabelModifier` on `AccountCreated` — use plain `deriveJSON defaultOptions ''AccountCreated` (field is now `kind`, JSON key is `kind`)
  7. Update `deriveJSON` for `AccountSubtypeSet`
  8. Remove unused `{-# LANGUAGE LambdaCase #-}` extension and `fieldLabelModifier` from the `Data.Aeson.TH` import (CI `-Werror` will fail on unused imports)

- [ ] **Step 2: Update Commands.hs**

  1. Rename export `SetAccountType` → `SetAccountSubtype`
  2. Update import: `AccountCategory` → `AccountKind`, `AccountType` → `AccountSubtype`
  3. Rename `CreateAccount.accountCategory` → `CreateAccount.kind` (field)
  4. Rename type `SetAccountType` → `SetAccountSubtype`, field `accountType` → `subtype`
  5. Update TH command list: `''SetAccountType` → `''SetAccountSubtype`
  6. Remove custom `fieldLabelModifier` on `CreateAccount` — use plain `deriveJSON defaultOptions ''CreateAccount`
  7. Update `deriveJSON` for `SetAccountSubtype`
  8. Remove unused `{-# LANGUAGE LambdaCase #-}` extension and `fieldLabelModifier` from the `Data.Aeson.TH` import

- [ ] **Step 3: Verify it compiles (expect downstream failures)**

  Run: `just build 2>&1 | head -80`

- [ ] **Step 4: Commit**

  ```bash
  git add src/Domain/Account/Events.hs src/Domain/Account/Commands.hs
  git commit -m "refactor: rename AccountTypeSet/SetAccountType to AccountSubtypeSet/SetAccountSubtype"
  ```

---

### Task 3: Rename in CommandHandler and Projection (Domain.Account)

**Files:**
- Modify: `src/Domain/Account/CommandHandler.hs`
- Modify: `src/Domain/Account/Projection.hs`

- [ ] **Step 1: Update CommandHandler.hs**

  1. Update imports: `AccountCategory (..)` → `AccountKind (..)`, `AccountType (..)` → `AccountSubtype (..)`
  2. Update import of commands: `SetAccountType` → `SetAccountSubtype`
  3. All `accountCategory` field accesses → `kind`
  4. All `accountType` references → `subtype`
  5. Pattern match on command: `SetAccountTypeAccountCommand SetAccountType {..}` → `SetAccountSubtypeAccountCommand SetAccountSubtype {..}`
  6. Event constructor: `AccountTypeSetAccountEvent` → `AccountSubtypeSetAccountEvent`, `AccountTypeSet` → `AccountSubtypeSet`

- [ ] **Step 2: Update Projection.hs**

  1. Update imports: `AccountCategory (..)` → `AccountKind (..)`, `AccountType` → `AccountSubtype`, `AccountTypeSet` → `AccountSubtypeSet`
  2. Rename field `accountCategory :: AccountCategory` → `kind :: AccountKind` in Account aggregate state
  3. Update default: `accountCategory = Regular defaultCash` → `kind = Regular defaultCash`
  4. Update lens accesses: `#accountCategory` → `#kind`
  5. Update event pattern: `AccountTypeSetAccountEvent AccountTypeSet {..}` → `AccountSubtypeSetAccountEvent AccountSubtypeSet {..}`
  6. Update record update: `#accountCategory .~ Regular accountType` → `#kind .~ Regular subtype`

- [ ] **Step 3: Verify it compiles (expect downstream failures)**

  Run: `just build 2>&1 | head -80`

- [ ] **Step 4: Commit**

  ```bash
  git add src/Domain/Account/CommandHandler.hs src/Domain/Account/Projection.hs
  git commit -m "refactor: rename accountCategory/accountType fields in command handler and projection"
  ```

---

### Task 4: Rename in Application layer

**Files:**
- Modify: `src/Application/Services/AccountService.hs`
- Modify: `src/Application/Services/TransactionService.hs`
- Modify: `src/Application/Services/AuthorizationService.hs`
- Modify: `src/Application/Services/AuthService.hs`
- Modify: `src/Application/ReadModels/Account.hs`

- [ ] **Step 1: Update AccountService.hs**

  1. Update imports: `SetAccountType` → `SetAccountSubtype`, `AccountCategory (..)` → `AccountKind (..)`, `AccountType` → `AccountSubtype`
  2. Rename `setAccountType` function → `setAccountSubtype`
  3. Update field accesses: `.accountCategory` → `.kind`
  4. Update command construction: `SetAccountTypeAccountCommand SetAccountType { accountType = ... }` → `SetAccountSubtypeAccountCommand SetAccountSubtype { subtype = ... }`

- [ ] **Step 2: Update TransactionService.hs**

  1. Update import: `AccountCategory (..)` → `AccountKind (..)`
  2. Update field accesses: `.accountCategory` → `.kind`

- [ ] **Step 3: Update AuthorizationService.hs**

  1. Update import: `AccountCategory (..)` → `AccountKind (..)`
  2. Update field: `accountCategory :: AccountCategory` → `kind :: AccountKind`

- [ ] **Step 4: Update AuthService.hs**

  1. Update import: `AccountCategory (..)` → `AccountKind (..)`
  2. Update field assignments: `accountCategory = External` → `kind = External`

- [ ] **Step 5: Update ReadModels/Account.hs**

  1. Update imports: `AccountTypeSet` → `AccountSubtypeSet`, `AccountCategory (..)` → `AccountKind (..)`, `AccountType` → `AccountSubtype` (if imported)
  2. Rename field: `accountCategory :: AccountCategory` → `kind :: AccountKind` in `AccountData`
  3. Update event handler: `AccountTypeSetEvent` → `AccountSubtypeSetEvent`
  4. Update field assignments: `accountCategory = ...` → `kind = ...`
  5. Update field accesses: `acc.accountCategory` → `acc.kind`

- [ ] **Step 6: Verify it compiles (expect downstream failures)**

  Run: `just build 2>&1 | head -80`

- [ ] **Step 7: Commit**

  ```bash
  git add src/Application/
  git commit -m "refactor: rename accountCategory/accountType to kind/subtype in application layer"
  ```

---

### Task 5: Rename in Web layer and Telegram

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/AccountAPI.hs`
- Modify: `src/Telegram/Commands.hs`

- [ ] **Step 1: Update Web/Types.hs**

  **Note:** DTO field renames (items 3-5) change the HTTP API JSON contract — this is intentional (breaking change per spec). Functions using `RecordWildCards` to destructure these DTOs will break and must be updated to use the new field names.

  1. Update imports: `AccountCategory (..)` → `AccountKind (..)`, `AccountType (..)` → `AccountSubtype (..)`
  2. Rename DTO: `AccountTypeRequest` → `AccountSubtypeRequest`, `SetAccountTypeRequest` → `SetAccountSubtypeRequest`
  3. Rename field in `SetAccountSubtypeRequest`: `accountType` → `subtype`
  4. Rename field in `CreateAccountRequest`: `accountType` → `subtype` (the `Maybe AccountSubtypeRequest` field)
  5. Rename response field: `accountType :: Maybe Value` → `subtype :: Maybe Value`
  6. Rename conversion functions: `toAccountType` → `toAccountSubtype`, `fromAccountType` → `fromAccountSubtype`
  7. Update all internal references to use new names
  8. In `toCreateAccountCommand`: update `RecordWildCards` destructure — `accountType` binding becomes `subtype`, and field assignment `accountCategory = Regular parsedType` → `kind = Regular parsedType`
  9. In `fromAccountData`: update `RecordWildCards` destructure — `accountCategory` binding becomes `kind`, pattern match accordingly

- [ ] **Step 2: Update Web/API/AccountAPI.hs**

  1. Update imports: `SetAccountTypeRequest` → `SetAccountSubtypeRequest`, `toAccountType` → `toAccountSubtype`
  2. Rename handler: `setAccountTypeHandler` → `setAccountSubtypeHandler`
  3. Update endpoint type signature and implementation
  4. Update error message: `"accountType"` → `"subtype"` in validation error

- [ ] **Step 3: Update Telegram/Commands.hs**

  1. Update import: `AccountCategory (..)` → `AccountKind (..)`
  2. Update field assignments: `accountCategory = Regular defaultCash` → `kind = Regular defaultCash`

- [ ] **Step 4: Verify full build compiles**

  Run: `just build`

  Expected: Clean compilation (all source files updated).

- [ ] **Step 5: Commit**

  ```bash
  git add src/Web/ src/Telegram/
  git commit -m "refactor: rename accountType/accountCategory to subtype/kind in web and telegram layers"
  ```

---

### Task 6: Rename in tests

**Files:**
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs`
- Modify: `test/Domain/Account/CommandHandlerSpec.hs`
- Modify: `test/Integration/TransferWorkflowSpec.hs`
- Modify: `test/Application/Services/AccountServiceSpec.hs`
- Modify: `test/Application/Services/AuthorizationServiceSpec.hs`
- Modify: `test/Application/Services/TransactionServiceSpec.hs`

- [ ] **Step 1: Update CommandHandlerPropertySpec.hs**

  1. Rename parameter/field: `AccountCategory` → `AccountKind` in type signatures
  2. Update `Arbitrary AccountCategory` → `Arbitrary AccountKind`
  3. Update field assignments: `accountCategory = ...` → `kind = ...`

- [ ] **Step 2: Update CommandHandlerSpec.hs**

  1. Update all field assignments: `accountCategory = Regular defaultCash` → `kind = Regular defaultCash`
  2. Update all field accesses: `.accountCategory` → `.kind`, `#accountCategory` → `#kind`

- [ ] **Step 3: Update TransferWorkflowSpec.hs**

  1. Update import: `AccountCategory (..)` → `AccountKind (..)`
  2. Update all field assignments: `accountCategory = ...` → `kind = ...`

- [ ] **Step 4: Update AccountServiceSpec.hs**

  1. Update all field assignments and accesses: `accountCategory` → `kind`

- [ ] **Step 5: Update AuthorizationServiceSpec.hs**

  1. Update type signature: `AccountCategory` → `AccountKind`

- [ ] **Step 6: Update TransactionServiceSpec.hs**

  1. Update import: `AccountCategory (..)` → `AccountKind (..)`
  2. Update field assignments: `accountCategory = ...` → `kind = ...`

- [ ] **Step 7: Run full test suite**

  Run: `just test`

  Expected: All tests pass.

- [ ] **Step 8: Commit**

  ```bash
  git add test/
  git commit -m "refactor: rename accountCategory/accountType to kind/subtype in tests"
  ```

---

### Task 7: Update documentation and run final checks

**Files:**
- Modify: `docs/specs/2026-04-07-account-types-design.md`

- [ ] **Step 1: Update account-types-design.md**

  Replace all references: `AccountCategory` → `AccountKind`, `AccountType` → `AccountSubtype`, `accountCategory` → `kind`, `accountType` → `subtype`. Update the spec status to reflect the rename.

- [ ] **Step 2: Run format and lint**

  Run: `just check`

  Expected: Clean output.

- [ ] **Step 3: Run full test suite one more time**

  Run: `just test`

  Expected: All tests pass.

- [ ] **Step 4: Commit**

  ```bash
  git add docs/
  git commit -m "docs: update account-types spec to reflect AccountKind/AccountSubtype rename"
  ```
