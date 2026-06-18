# Global Default Categories — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `defaultIncomeCategory` / `defaultExpenseCategory` out of the banking sub-record and make them top-level global configuration, exposed via a new `PUT /api/users/me/configuration/defaults` endpoint.

**Architecture:** Event-sourced Configuration aggregate. Fields relocate from `BankingConfiguration` to the top-level `Configuration` record; the `Banking*` events/commands are renamed to global names. **No prod DB → intentional breaking change, no event/wire backward-compat.** Bank import keeps reading the (now top-level) fields, so import behaviour is unchanged.

**Tech Stack:** Haskell (GHC 9.10), Servant, RIO, event-sourced (eventium), Hspec + hspec-wai.

**Spec:** `../../monorepo/docs/specs/2026-06-18-global-default-categories-design.md`

**Environment:** Build/test inside `nix develop`; needs gitignored `cabal.project.local` and a running Postgres (`docker compose up`). Single spec: `cabal test backend-test --test-show-details=direct --test-options='--match "<describe text>"'`. A piped `| tail` masks cabal's exit code — read the output.

---

## Rename reference (apply consistently across the codebase)

| Old | New |
| --- | --- |
| `BankingDefaultIncomeCategorySet` (event) | `DefaultIncomeCategorySet` |
| `BankingDefaultExpenseCategorySet` (event) | `DefaultExpenseCategorySet` |
| `BankingDefaultIncomeCategorySetConfigurationEvent` (sum ctor) | `DefaultIncomeCategorySetConfigurationEvent` |
| `BankingDefaultExpenseCategorySetConfigurationEvent` (sum ctor) | `DefaultExpenseCategorySetConfigurationEvent` |
| `BankingDefaultIncomeCategorySetEvent` (read-model wrapper) | `DefaultIncomeCategorySetEvent` |
| `BankingDefaultExpenseCategorySetEvent` (read-model wrapper) | `DefaultExpenseCategorySetEvent` |
| `SetBankingDefaultIncomeCategory` (command) | `SetDefaultIncomeCategory` |
| `SetBankingDefaultExpenseCategory` (command) | `SetDefaultExpenseCategory` |
| `SetBankingDefaultIncomeCategoryConfigurationCommand` (sum ctor) | `SetDefaultIncomeCategoryConfigurationCommand` |
| `SetBankingDefaultExpenseCategoryConfigurationCommand` (sum ctor) | `SetDefaultExpenseCategoryConfigurationCommand` |
| `setBankingDefaultIncomeCategory` (service fn) | `setDefaultIncomeCategory` |
| `setBankingDefaultExpenseCategory` (service fn) | `setDefaultExpenseCategory` |
| `isBankingDefault` (guard) | `isGlobalDefault` |
| `EntryIsBankingDefault` (error) | `EntryIsGlobalDefault` |

The MCC map (`BankingMccExpenseCategoryMap*`, `SetBankingMccExpenseCategoryMap`) stays banking-scoped — **do not rename it**.

---

## Task 1: Relocate fields + rename events in the domain projection

**Files:**
- Modify: `src/Domain/Configuration/Events.hs` (`:31-32`, `:83-84`, `:156-165`, `:254-255`)
- Modify: `src/Domain/Configuration/Projection.hs` (`:19-20`, `:89-126`, `:143-178`, `:276-278`)
- Test: `test/Domain/Configuration/ProjectionSpec.hs` (`:364-380`)

- [ ] **Step 1: Adjust the failing test.** In `ProjectionSpec.hs`, update the default-category specs to (a) use the renamed events `DefaultIncomeCategorySet` / `DefaultExpenseCategorySet`, and (b) assert the value lands on the **top-level** field, e.g. `config.defaultIncomeCategory `shouldBe` Just cid` (not `config.banking.defaultIncomeCategory`).

- [ ] **Step 2: Run, expect compile failure** (renamed ctors/fields don't exist yet).
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "Configuration projection"'`
  Expected: compile error / FAIL.

- [ ] **Step 3: Events.hs** — rename `BankingDefaultIncomeCategorySet`→`DefaultIncomeCategorySet`, `BankingDefaultExpenseCategorySet`→`DefaultExpenseCategorySet` (data decls, the export list `:31-32`, the event-sum TH list `:83-84`, and the `deriveJSON` lines `:254-255`). Update the comment from "banking default" to "default".

- [ ] **Step 4: Projection.hs**
  - Remove `defaultIncomeCategory` / `defaultExpenseCategory` from `BankingConfiguration` (`:91-93`), from its export tuple (`:19`), and from `emptyBankingConfiguration` (`:124-125`).
  - Add `defaultIncomeCategory :: !(Maybe CategoryId)` and `defaultExpenseCategory :: !(Maybe CategoryId)` to the top-level `Configuration` record (`:143`), and `= Nothing` for both in `configurationDefault` (`:165`).
  - Update the two `handleConfigurationEvent` arms (`:276-278`) to the renamed sum ctors writing `config {defaultIncomeCategory = Just evt.categoryId}` (top-level, not `config.banking`).

- [ ] **Step 5: Run, expect PASS.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "Configuration projection"'`
  Expected: PASS.

- [ ] **Step 6: Commit.**
  ```bash
  git add src/Domain/Configuration/Events.hs src/Domain/Configuration/Projection.hs test/Domain/Configuration/ProjectionSpec.hs
  git commit -m "refactor(configuration): relocate default categories to top-level projection (#41)"
  ```

---

## Task 2: Rename commands, handler emit, and deletion guard

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs` (`:24-25`, `:76-77`, `:165-175`, `:290-291`)
- Modify: `src/Domain/Configuration/CommandHandler.hs` (`:66` error, `:142-145` guard, `:249` call-site, plus the two `Set*` command handler arms that emit the events)
- Test: `test/Domain/Configuration/CommandHandlerSpec.hs` (`:708-753`)

- [ ] **Step 1: Adjust the failing test.** In `CommandHandlerSpec.hs`, rename `SetBankingDefault*Category` → `SetDefault*Category` and the emitted-event assertions to `DefaultIncomeCategorySetConfigurationEvent` etc. Update the deletion-guard spec to expect `EntryIsGlobalDefault` and to seed the default via the top-level field.

- [ ] **Step 2: Run, expect compile failure.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "Configuration command"'`
  Expected: FAIL.

- [ ] **Step 3: Commands.hs** — rename the two command data decls (`:165-175`), exports (`:24-25`), the command-sum TH list (`:76-77`), and `deriveJSON` (`:290-291`). Leave the MCC command untouched.

- [ ] **Step 4: CommandHandler.hs**
  - Rename error constructor `EntryIsBankingDefault`→`EntryIsGlobalDefault` (`:66`).
  - Rename `isBankingDefault`→`isGlobalDefault` and point it at top-level fields:
    ```haskell
    isGlobalDefault :: CategoryId -> Configuration -> Bool
    isGlobalDefault eid config =
      config.defaultIncomeCategory == Just eid
        || config.defaultExpenseCategory == Just eid
    ```
  - Update the `RemoveDictionaryEntry` guard (`:249`) to `isGlobalDefault entryId config = Left EntryIsGlobalDefault`.
  - Rename the two `Set*Category` command-handler arms to the new command/event ctors (emit `DefaultIncomeCategorySetConfigurationEvent` etc.).

- [ ] **Step 5: Run, expect PASS.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "Configuration command"'`
  Expected: PASS.

- [ ] **Step 6: Commit.**
  ```bash
  git add src/Domain/Configuration/Commands.hs src/Domain/Configuration/CommandHandler.hs test/Domain/Configuration/CommandHandlerSpec.hs
  git commit -m "refactor(configuration): rename Set/Default category commands to global (#41)"
  ```

---

## Task 3: Read model — add fields to `ConfigurationData` + fold

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs` (record `:99-117`, created-event init `:216-223`, import `:60`, destructuring `:72`, fold arms `:307`, `:320`)
- Test: read-model spec if present (`test/Application/ReadModels/ConfigurationSpec.hs`), else covered by integration.

> The read model has its **own** record `ConfigurationData` (`:99`), separate from the domain `Configuration` (Projection.hs). It must gain the same two fields. The `…SetEvent` match ctors at `:307`/`:320` are TH-generated from the domain event names (`Domain/Models.hs` `constructSumType`), so renaming the domain events in Task 1 cascades automatically — only the match arms here need hand-editing, there is no separate wrapper definition to rename.

- [ ] **Step 1: If a read-model spec exists**, update it to the top-level field; run and expect FAIL. If none exists, skip to Step 2 (the API test in Task 5 exercises this path).

- [ ] **Step 2:**
  - Add `defaultIncomeCategory :: Maybe CategoryId` and `defaultExpenseCategory :: Maybe CategoryId` to the `ConfigurationData` record (`:99-117`).
  - Initialise both to `Nothing` in the `ConfigurationCreatedEvent` arm (`:216-223`).
  - Update the import at `:60` to the renamed event name; fix the `BankingConfiguration` destructuring (`:72`) so it no longer binds the moved fields.
  - Update the two fold arms (`:307`, `:320`) to the renamed ctors writing the **top-level** field, e.g. `config {defaultIncomeCategory = Just evt.categoryId, version = config.version + 1}` (preserve the existing `version` bump if present).

- [ ] **Step 3: Compile the package.**
  Run: `cabal build backend`
  Expected: builds clean.

- [ ] **Step 4: Commit.**
  ```bash
  git add src/Application/ReadModels/Configuration.hs
  git commit -m "refactor(configuration): read model folds default categories at top level (#41)"
  ```

---

## Task 4: Service layer (wrappers, seeding, clone)

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs` (imports `:31-32`, `:98-99`, `:116`; wrappers `:274-296`; seeding `:623-637`; clone `:745-769`)
- Modify: `src/Application/Services/BankImportService.hs` (`:209-210`)
- Test: `test/Application/Services/ConfigurationServiceSpec.hs` (seeding + clone specs)

- [ ] **Step 1: Adjust the failing test.** In the service spec, update the seeding assertion to read the seeded defaults from the **top-level** config field, and the clone spec likewise. Rename any `setBankingDefault*` references to `setDefault*`.

- [ ] **Step 2: Run, expect FAIL.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "ConfigurationService"'`
  Expected: FAIL.

- [ ] **Step 3: ConfigurationService.hs**
  - Rename wrappers `setBankingDefaultIncomeCategory`→`setDefaultIncomeCategory` / `...Expense...` (`:274-296`), emitting `SetDefaultIncomeCategoryConfigurationCommand SetDefaultIncomeCategory {..}`. Update the export list (`:31-32`) and the imported command ctors (`:98-99`).
  - Seeding (`:623-637`): rename the two seed commands to `SetDefault*CategoryConfigurationCommand`.
  - Clone (`:745-769`): `copyBanking` currently reads `srcBanking.defaultIncomeCategory`. Since the fields moved off `BankingConfiguration`, change the clone to read them from the top-level source `Configuration`. Simplest: rename/extend to `copyDefaults :: UUID -> Configuration -> AppM ()` reading `srcConfig.defaultIncomeCategory` / `srcConfig.defaultExpenseCategory` and emitting the renamed commands; update its call site to pass the source `Configuration` (it previously passed `config.banking`). Keep MCC-map cloning where it is (still on banking).
  - Fix the `BankingConfiguration (...)` destructuring at `:116` so it no longer binds the moved fields.

- [ ] **Step 4: BankImportService.hs** (`:209-210`): change the fallback lookups from `banking.defaultIncomeCategory` / `banking.defaultExpenseCategory` to the top-level `config.defaultIncomeCategory` / `config.defaultExpenseCategory`. **No behavioural change** — same value, new location.

- [ ] **Step 5: Run, expect PASS.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "ConfigurationService"'` and `--match "BankImport"`.
  Expected: PASS.

- [ ] **Step 6: Commit.**
  ```bash
  git add src/Application/Services/ConfigurationService.hs src/Application/Services/BankImportService.hs test/Application/Services/ConfigurationServiceSpec.hs
  git commit -m "refactor(configuration): repoint service wrappers/seeding/clone + import to global defaults (#41)"
  ```

---

## Task 5: API — top-level response fields + new `/defaults` endpoint

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs` (DTO `:251-258`, `toBankingDTO` `:305-309`, `ConfigurationResponse` `:313-330`, `toConfigurationResponse` `:746-753`, `UpdateBankingRequest` `:400-404`, route table `:103-244`, `configurationServer` `:478-493`, `updateBankingHandler` `:532-565`)
- Test: `test/Web/API/ConfigurationBankingAPISpec.hs` (the real HTTP spec — **note: there is no `ConfigurationAPISpec.hs`**)

- [ ] **Step 1: Update the failing API spec** in `ConfigurationBankingAPISpec.hs`:
  - **Relocate** the default-category cases that currently PUT to `/banking` and assert `dto.defaultIncomeCategory` (`:96-187`) into a new describe `"PUT /api/users/me/configuration/defaults"`: PUT `{defaultIncomeCategory: <uuid>}` to `/defaults` → 200, response is the full `ConfigurationResponse` with top-level `defaultIncomeCategory` set; same for expense; the clone-on-write case (`:142-146`) asserts the seeded top-level defaults.
  - Add an invalid-UUID case → 4xx field error `defaultIncomeCategory`.
  - Update the `GET /configuration` case (`:281-303`) to assert the **top-level** `cfg.defaultIncomeCategory` (not `cfg.banking.defaultIncomeCategory`), driven via a PUT to `/defaults`.
  - The `mccExpenseCategoryMap` describe (`:198+`) stays on `/banking`, unchanged.
  - **Do not** add any "null clears" assertion (set-only — see Task 5 note).

- [ ] **Step 2: Run, expect FAIL.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "configuration/defaults"'`
  Expected: FAIL (route 404 / field missing). Also run `--match "GET /api/users/me/configuration"` to catch the relocated assertion.

- [ ] **Step 3: DTO + response changes**
  - Remove `defaultIncomeCategory` / `defaultExpenseCategory` from `BankingConfigurationDTO` (`:252-253`) and from `toBankingDTO` (`:306-307`).
  - Add `defaultIncomeCategory :: Maybe UUID` and `defaultExpenseCategory :: Maybe UUID` to `ConfigurationResponse` (`:313`), populated in `toConfigurationResponse` (`:746`) from `configData.defaultIncomeCategory` (map through `unDictionaryEntryId`).
  - Replace `UpdateBankingRequest` (`:400-404`) so it keeps only `mccExpenseCategoryMap :: Maybe (Map Text UUID)`. Add a new request type:
    ```haskell
    -- | Partial-update body for PUT /api/users/me/configuration/defaults.
    -- Set-only: a present UUID sets the field; absent OR null means "no change"
    -- (matching the existing banking-defaults semantics — there is no clear path).
    data UpdateDefaultsRequest = UpdateDefaultsRequest
      { defaultIncomeCategory :: Maybe UUID,
        defaultExpenseCategory :: Maybe UUID
      }
      deriving (Show, Eq, Generic)
    instance ToJSON UpdateDefaultsRequest
    instance FromJSON UpdateDefaultsRequest
    ```
    > **Clear-to-none is intentionally NOT supported** (preserving existing behaviour). The current `updateBankingHandler` is set-only — it `forM_`s over `Maybe` and only ever emits a `Set` command; the domain has no `Unset`/clear event. `Maybe UUID` (absent or null → `Nothing` → no-op) matches that exactly. The web "— none —" affordance has always been a server-side no-op; fixing it (an `UnsetDefault*` command/event/projection arm) is out of scope for #41 — capture as a follow-up if desired. **Do not assert that null clears** in any test.

- [ ] **Step 4: Route + handler + server wiring**
  - Add a route entry after the `banking` PUT (`:138`):
    ```haskell
    :<|> AuthProtect "jwt"
      :> "api" :> "users" :> "me" :> "configuration" :> "defaults"
      :> ReqBody '[JSON] UpdateDefaultsRequest
      :> Put '[JSON] ConfigurationResponse
    ```
  - Add `updateDefaultsHandler` (model on `updateBankingHandler` `:532-565`): for each present field, `validateFieldCtx` then call `ConfigService.setDefaultIncomeCategory` / `setDefaultExpenseCategory`; finally return `toConfigurationResponse … configData` for the refreshed config.
  - Strip the two default branches out of `updateBankingHandler` (it now handles only the MCC map) and change its return to the (still) `BankingConfigurationDTO`.
  - Add `updateDefaultsHandler` to `configurationServer` (`:478-493`) **immediately after `updateBankingHandler`** (`:483`) — i.e. `… :<|> updateBankingHandler :<|> updateDefaultsHandler :<|> closeBooksThroughHandler …`. Servant matches handlers positionally to the route type, so it MUST occupy the slot of the route inserted at `:138`; appending it at the end misaligns every subsequent handler.
  - Update the module-header route doc comment (`:21`).

- [ ] **Step 5: Run, expect PASS.**
  Run: `cabal test backend-test --test-show-details=direct --test-options='--match "ConfigurationAPI"'`
  Expected: PASS.

- [ ] **Step 6: Full suite + commit.**
  Run: `cabal test backend-test --test-show-details=direct`
  Expected: all green.
  ```bash
  git add src/Web/API/ConfigurationAPI.hs test/Web/API/ConfigurationAPISpec.hs
  git commit -m "feat(configuration): expose global default categories + PUT /configuration/defaults (#41)"
  ```

---

## Task 6: Final verification

- [ ] `cabal build backend && cabal test backend-test --test-show-details=direct` — full green.
- [ ] `grep -rn "BankingDefault\|setBankingDefault\|isBankingDefault\|EntryIsBankingDefault" src/` returns **nothing** (rename complete; MCC-map identifiers are fine).
- [ ] `hlint src/` clean (per house practice).
- [ ] Confirm `GET /configuration` JSON has top-level `defaultIncomeCategory`/`defaultExpenseCategory` and `banking` no longer carries them — this is the contract the web plan codes against.
- [ ] Open backend PR; note the breaking wire change and that it pairs with the web PR.
