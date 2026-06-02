---
status: completed
date: 2026-06-02
issue: homeaccounting/backend#93
spec: 2026-06-02-transaction-naming-consistency-design.md
---

# Transaction Naming Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the `Transfer*` family (types, events, commands, process managers, service helpers, DTOs) to `Transaction*` with sub-domain qualifiers (`Posting`, `Amendment`), removing the kind-vs-saga foot-gun in the codebase.

**Architecture:** Pure mechanical rename across `src/` and `test/`. No behaviour change. Compiler catches misses. Each task leaves the build green (`just build`) and the test suite green (`just test`) before commit. JSON event-payload tags break — clean snap per project's no-backcompat policy.

**Tech Stack:** Haskell GHC 9.10.3, RIO prelude, eventium (event store), Servant, Hspec + QuickCheck.

---

## Working environment

Branch: `refactor/rename-transfer-to-transaction` (already created).

Every task ends with:
1. `just build` — must succeed.
2. `just test` — must pass (full suite for final task; per-spec for fast iteration on early tasks is acceptable but the full suite must pass before the PR opens).
3. `just format` — ormolu in place.
4. `just lint` — hlint clean.
5. `git commit` with a Conventional Commits message.

Do NOT skip the build between tasks. The renames are interlocked; a missed reference manifests as a compile error and is much easier to fix one task at a time than at the end.

`grep -rn '<old-name>' src test` is the canonical way to verify a rename is complete. Use `\b<old-name>\b` style word-boundary checks where the name is a substring of another identifier.

---

## Task 1: Rename core types (`TransferType`, `TransferKind`, `rescaleTransferType`) and the `transferType` field

**Files (primary):**
- Modify: `src/Domain/Core/Types.hs` (definitions at lines ~995–1190)
- Touches ~40 source/test files that reference `TransferType`, `TransferKind`, or `rescaleTransferType`.
- Touches ~43 source/test files that reference the `transferType` field.

**Rationale:** Field and type are tightly coupled (the field's type is the renamed type). Doing them in one task keeps the diff coherent.

- [ ] **Step 1: Survey scope**

  ```bash
  grep -rn '\bTransferType\b' src test
  grep -rn '\bTransferKind\b' src test
  grep -rn '\brescaleTransferType\b' src test
  grep -rn '\btransferType\b' src test
  ```

  Note the locations. Most are imports, type signatures, field accesses, and pattern matches.

- [ ] **Step 2: Rename the data types in `src/Domain/Core/Types.hs`**

  Apply these substitutions (whole-identifier; case-sensitive):
  - `TransferType` → `TransactionType`
  - `TransferKind` → `TransactionKind` (the data type only; the *constructor* `TransferKind` keeps its name)
  - `rescaleTransferType` → `rescaleTransactionType`
  - `transferType` (when used as a field name, parameter name, or local variable for this type) → `transactionType`

  The `TransferKind` constructor of `TransactionKind` keeps its name — it's the tag for the `Transfer` constructor of `TransactionType`. Verify by reading the renamed `kindOf` function:

  ```haskell
  kindOf :: TransactionType -> TransactionKind
  kindOf (Income _) = IncomeKind
  kindOf (Expense _) = ExpenseKind
  kindOf Transfer = TransferKind
  kindOf Adjustment = AdjustmentKind
  ```

  Update module export list to reflect new names.

- [ ] **Step 3: Propagate to all importing modules**

  For each file from the grep survey, replace:
  - `TransferType` → `TransactionType`
  - `TransferKind` → `TransactionKind` (data type references only — beware import lists and signature lines that match the constructor too)
  - `rescaleTransferType` → `rescaleTransactionType`
  - `transferType` (field name and field-named identifiers) → `transactionType`

  Hot spots:
  - `src/Domain/Transaction/Events.hs` — `TransferInitiated` carries `transferType :: TransferType` (this field is renamed; the *event* is renamed in Task 2)
  - `src/Domain/Transaction/CommandHandler.hs` — pattern matches on `transferType`
  - `src/Domain/Transaction/Projection.hs` — copy of `transferType` field
  - `src/Application/Services/TransactionService.hs` — many references
  - `src/Application/ReadModels/Transaction.hs` — uses `transferType` in JSON serialisation
  - `src/Web/Types.hs` — `TransactionResponse` carries `transferType`
  - `test/Testkit/Generators.hs` — generators for the type
  - `test/Domain/Core/TypesPropertySpec.hs` — laws for the type

- [ ] **Step 4: Verify the build**

  ```bash
  just build
  ```

  Expected: build succeeds. If it fails, find the missed reference in the error message and fix it.

- [ ] **Step 5: Verify the test suite**

  ```bash
  just test
  ```

  Expected: all tests pass. JSON serialisation tests may need their golden values updated (`"transferType":` → `"transactionType":`).

- [ ] **Step 6: Format + lint**

  ```bash
  just format && just lint
  ```

- [ ] **Step 7: Commit**

  ```bash
  git add -A
  git commit -m "refactor(transaction): rename TransferType to TransactionType

  Renames the TransferType / TransferKind sum types and the transferType
  field everywhere they appear. Constructor names (Income/Expense/Transfer/
  Adjustment and *Kind variants) stay. Pure rename, no behaviour change."
  ```

---

## Task 2: Rename posting-saga events (`TransferInitiated/Completed/Failed`)

**Files:**
- Modify: `src/Domain/Transaction/Events.hs` (definitions, export list, TH name list, JSON instances)
- Touches ~38 files (less now that Task 1 has redrawn some import lists).

**Rationale:** Renaming events propagates to TH-generated wrapper constructors (`TransferInitiatedEvent` → `TransactionPostingInitiatedEvent`) and every pattern match against them.

- [ ] **Step 1: Survey scope**

  ```bash
  grep -rn '\bTransferInitiated\b\|\bTransferCompleted\b\|\bTransferFailed\b' src test
  grep -rn '\bTransferInitiatedEvent\b\|\bTransferCompletedEvent\b\|\bTransferFailedEvent\b' src test
  ```

- [ ] **Step 2: Rename in `src/Domain/Transaction/Events.hs`**

  - `TransferInitiated` → `TransactionPostingInitiated` (data type, export, TH list, JSON)
  - `TransferCompleted` → `TransactionPostingCompleted`
  - `TransferFailed` → `TransactionPostingFailed`

  The `Data.Aeson.TH.deriveJSON` block at the bottom and the hand-written `FromJSON TransferInitiated` instance both need the renamed type.

- [ ] **Step 3: Propagate to all files**

  Substitute (in this order, since `TransferInitiated` is a substring of `TransferInitiatedEvent`):
  - `TransferInitiatedEvent` → `TransactionPostingInitiatedEvent`
  - `TransferCompletedEvent` → `TransactionPostingCompletedEvent`
  - `TransferFailedEvent` → `TransactionPostingFailedEvent`
  - `TransferInitiated` → `TransactionPostingInitiated`
  - `TransferCompleted` → `TransactionPostingCompleted`
  - `TransferFailed` → `TransactionPostingFailed`

  Hot spots:
  - `src/Application/ProcessManagers/TransferManager.hs` — `handleTransferEvent`, `reactToTransferEvent` (these functions still keep their names for now; Task 5 renames them)
  - `src/Application/ProcessManagers/Snapshots.hs` — `applyTransferInitiated`
  - `src/Application/ReadModels/BankImportReadModel.hs` — `TransferInitiatedEvent` and `TransferFailedEvent` cases
  - `src/Application/ReadModels/Transaction.hs` — pattern matches
  - `src/Application/Services/TransactionHistoryService.hs` — pattern matches
  - All `test/**/*.hs` files that construct or match these events

- [ ] **Step 4: Verify**

  ```bash
  just build && just test
  ```

  Update golden JSON values in tests if any: `"tag":"TransferInitiated"` → `"tag":"TransactionPostingInitiated"`.

- [ ] **Step 5: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename Transfer{Initiated,Completed,Failed} to TransactionPosting{Initiated,Completed,Failed}

  Posting-saga events gain the 'Posting' sub-domain qualifier for
  consistency with the Amendment and Cancellation saga families. Event
  JSON tags break; no upcaster per project no-backcompat policy."
  ```

---

## Task 3: Rename amendment-saga events (`TransferAmendment{Initiated,Completed,Failed}`)

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Touches ~24 files.

- [ ] **Step 1: Survey scope**

  ```bash
  grep -rn '\bTransferAmendment\(Initiated\|Completed\|Failed\)\b' src test
  ```

- [ ] **Step 2: Rename in `src/Domain/Transaction/Events.hs`**

  - `TransferAmendmentInitiated` → `TransactionAmendmentInitiated`
  - `TransferAmendmentCompleted` → `TransactionAmendmentCompleted`
  - `TransferAmendmentFailed` → `TransactionAmendmentFailed`

  Update the TH `transactionEvents` name list and the JSON deriving block.

- [ ] **Step 3: Propagate**

  Substitute (longer first, but the longer forms also need substitution — they contain the shorter):
  - `TransferAmendmentInitiatedEvent` → `TransactionAmendmentInitiatedEvent`
  - `TransferAmendmentCompletedEvent` → `TransactionAmendmentCompletedEvent`
  - `TransferAmendmentFailedEvent` → `TransactionAmendmentFailedEvent`
  - `TransferAmendmentInitiated` → `TransactionAmendmentInitiated`
  - `TransferAmendmentCompleted` → `TransactionAmendmentCompleted`
  - `TransferAmendmentFailed` → `TransactionAmendmentFailed`

  Hot spots:
  - `src/Application/ProcessManagers/TransferAmendmentManager.hs` — all three plus their `*Event` constructors
  - `src/Domain/Transaction/CommandHandler.hs` — handler emits these events
  - `src/Application/ReadModels/Transaction.hs` — pattern matches
  - `src/Application/Services/TransactionHistoryService.hs` — pattern matches
  - `test/Integration/TransferAmendmentIntegrationSpec.hs`
  - `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` etc.

- [ ] **Step 4: Verify**

  ```bash
  just build && just test
  ```

- [ ] **Step 5: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename TransferAmendment* events to TransactionAmendment*"
  ```

---

## Task 4: Rename posting-saga commands

**Renames:**
- `InitiateTransfer` → `InitiateTransaction`
- `CompleteTransfer` → `CompleteTransactionPosting`
- `FailTransfer` → `FailTransactionPosting`

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs`
- Touches: command handler, service helpers, process manager, tests.

- [ ] **Step 1: Survey**

  ```bash
  grep -rn '\bInitiateTransfer\b\|\bCompleteTransfer\b\|\bFailTransfer\b' src test
  grep -rn '\bInitiateTransferTransactionCommand\b\|\bCompleteTransferTransactionCommand\b\|\bFailTransferTransactionCommand\b' src test
  ```

  Note: `CompleteTransfer` is a substring of `CompleteTransferAmendment`; `FailTransfer` is a substring of `FailTransferAmendment`. Order your substitutions to avoid accidentally double-renaming these. Use whole-word matching where possible, or do amendment first (Task 5) — actually we'll do posting first here, so DO NOT do bare substring replace yet.

- [ ] **Step 2: Rename in `src/Domain/Transaction/Commands.hs`**

  - `InitiateTransfer` → `InitiateTransaction` (whole word — does not collide with anything)
  - `CompleteTransfer` → `CompleteTransactionPosting` (BEFORE this, ensure no `CompleteTransferAmendment` references remain in the same edit window, or use precise multi-line context)
  - `FailTransfer` → `FailTransactionPosting` (same caveat)

  **Safer approach:** edit `Commands.hs` first (small file, easy to verify by hand), then in downstream files use Edit with surrounding context to ensure precise whole-identifier matches. The `CompleteTransfer`/`FailTransfer` data declarations are short; pattern-match callers in `CommandHandler.hs` use the pattern `CompleteTransfer` directly (no `Amendment` suffix).

- [ ] **Step 3: Propagate, watching for substring collisions**

  Order of substitutions per file:
  1. `InitiateTransferTransactionCommand` → `InitiateTransactionTransactionCommand`
  2. `InitiateTransfer` → `InitiateTransaction` (catches both bare and any remaining suffix)
  3. `CompleteTransferTransactionCommand` → `CompleteTransactionPostingTransactionCommand`
  4. `FailTransferTransactionCommand` → `FailTransactionPostingTransactionCommand`
  5. Edit `CompleteTransfer` → `CompleteTransactionPosting` ONLY in places where it's not followed by `Amendment`. The grep below catches these:
     ```bash
     grep -rn '\bCompleteTransfer\b' src test | grep -v 'CompleteTransferAmendment'
     ```
  6. Same for `FailTransfer`:
     ```bash
     grep -rn '\bFailTransfer\b' src test | grep -v 'FailTransferAmendment'
     ```

  Hot spots:
  - `src/Domain/Transaction/CommandHandler.hs` — pattern matches
  - `src/Application/Services/TransactionService.hs` — imports and uses
  - `src/Application/ProcessManagers/TransferManager.hs` — issues `CompleteTransferTransactionCommand`, `FailTransferTransactionCommand`
  - Tests in `test/Domain/Transaction/`

- [ ] **Step 4: Verify**

  ```bash
  grep -rn '\bInitiateTransfer\b\|\bCompleteTransfer\b\|\bFailTransfer\b' src test
  ```

  Expected: prints only lines that are part of `CompleteTransferAmendment` / `FailTransferAmendment` (handled in Task 5).

  ```bash
  just build && just test
  ```

- [ ] **Step 5: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename posting-saga commands to Transaction{Initiate,CompletePosting,FailPosting}"
  ```

---

## Task 5: Rename amendment-saga commands

**Renames:**
- `AmendTransfer` → `AmendTransaction`
- `CompleteTransferAmendment` → `CompleteTransactionAmendment`
- `FailTransferAmendment` → `FailTransactionAmendment`

- [ ] **Step 1: Survey**

  ```bash
  grep -rn '\bAmendTransfer\b\|\bCompleteTransferAmendment\b\|\bFailTransferAmendment\b' src test
  ```

  Note: `AmendTransfer` is a substring of `AmendTransferRequest` (Task 7). Don't replace bare `AmendTransfer` substring-wise until you verify no `AmendTransferRequest` references will be broken — or just do longer-prefix matches first.

- [ ] **Step 2: Rename in `src/Domain/Transaction/Commands.hs`**

  - `CompleteTransferAmendment` → `CompleteTransactionAmendment`
  - `FailTransferAmendment` → `FailTransactionAmendment`
  - `AmendTransfer` → `AmendTransaction` (BUT NOT `AmendTransferRequest` — careful: edit only the command type declaration, the export, and TH list)

- [ ] **Step 3: Propagate**

  Order matters to avoid collisions:
  1. `CompleteTransferAmendmentTransactionCommand` → `CompleteTransactionAmendmentTransactionCommand`
  2. `FailTransferAmendmentTransactionCommand` → `FailTransactionAmendmentTransactionCommand`
  3. `AmendTransferTransactionCommand` → `AmendTransactionTransactionCommand`
  4. `CompleteTransferAmendment` → `CompleteTransactionAmendment`
  5. `FailTransferAmendment` → `FailTransactionAmendment`
  6. `AmendTransfer` (whole identifier, NOT followed by `Request`) → `AmendTransaction`. Use:
     ```bash
     grep -rn '\bAmendTransfer\b' src test | grep -v 'AmendTransferRequest'
     ```

  Hot spots:
  - `src/Domain/Transaction/CommandHandler.hs`
  - `src/Application/Services/TransactionService.hs`
  - `src/Application/ProcessManagers/TransferAmendmentManager.hs`
  - `test/**/*Amendment*Spec.hs`

- [ ] **Step 4: Verify**

  ```bash
  grep -rn '\bAmendTransfer\b\|\bCompleteTransferAmendment\b\|\bFailTransferAmendment\b' src test
  ```

  Expected: only `AmendTransferRequest` / `AmendTransferHandler` references remain (Task 7).

  ```bash
  just build && just test
  ```

- [ ] **Step 5: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename amendment-saga commands to TransactionAmendment*"
  ```

---

## Task 6: Rename `TransferManager` → `TransactionPostingManager`

**Files:**
- Rename: `src/Application/ProcessManagers/TransferManager.hs` → `src/Application/ProcessManagers/TransactionPostingManager.hs`
- Modify: `src/Application/ProcessManagers.hs` (re-export), `app/Main.hs` (wiring), `src/Application/ProcessManagers/Snapshots.hs`, `package.yaml` if explicit module list.

**Renames inside the file:**
- Module name: `Application.ProcessManagers.TransferManager` → `Application.ProcessManagers.TransactionPostingManager`
- Record: `TransferManager` → `TransactionPostingManager`
- `TransferData` → `TransactionPostingData`
- `TransferPhase` → `TransactionPostingPhase`
- `TransferProcessManager` (type alias) → `TransactionPostingProcessManager`
- `transferManagerDefault` → `transactionPostingManagerDefault`
- `transferManagerProjection` → `transactionPostingManagerProjection`
- `handleTransferEvent` → `handleTransactionPostingEvent`
- `reactToTransferEvent` → `reactToTransactionPostingEvent`

- [ ] **Step 1: Survey scope**

  ```bash
  grep -rn '\bTransferManager\b\|\bTransferData\b\|\bTransferPhase\b\|\bTransferProcessManager\b' src test
  grep -rn '\btransferManagerDefault\b\|\btransferManagerProjection\b\|\bhandleTransferEvent\b\|\breactToTransferEvent\b' src test
  grep -rn 'Application\.ProcessManagers\.TransferManager' src test app
  ```

- [ ] **Step 2: Move and rename the file**

  ```bash
  git mv src/Application/ProcessManagers/TransferManager.hs src/Application/ProcessManagers/TransactionPostingManager.hs
  ```

  Then edit the file to update the module header, all type/function names listed above.

- [ ] **Step 3: Update imports in callers**

  Files that import the module:
  - `src/Application/ProcessManagers.hs` (re-export aggregator)
  - `app/Main.hs` (saga wiring)
  - `src/Application/ProcessManagers/Snapshots.hs` (uses `applyTransferInitiated` — also rename this to `applyTransactionPostingInitiated`)
  - Any test file that imports the process manager

  Substitute:
  - `Application.ProcessManagers.TransferManager` → `Application.ProcessManagers.TransactionPostingManager`
  - All renames listed in the task header (record name, helpers, aliases)

- [ ] **Step 4: Update `package.yaml` and re-run hpack if needed**

  ```bash
  grep -n 'TransferManager' package.yaml
  ```

  If the module is explicitly listed, replace with `TransactionPostingManager`. Run `hpack` (or `just build` which invokes hpack).

- [ ] **Step 5: Verify**

  ```bash
  just build && just test
  ```

- [ ] **Step 6: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename TransferManager module to TransactionPostingManager"
  ```

---

## Task 7: Rename `TransferAmendmentManager` → `TransactionAmendmentManager`

**Files:**
- Rename: `src/Application/ProcessManagers/TransferAmendmentManager.hs` → `src/Application/ProcessManagers/TransactionAmendmentManager.hs`
- Modify: re-export aggregator, `app/Main.hs`, tests.

**Renames inside the file:**
- Module name
- Record `TransferAmendmentManager` → `TransactionAmendmentManager`
- `TransferAmendmentData` → `TransactionAmendmentData`
- `TransferAmendmentPhase` → `TransactionAmendmentPhase`
- `TransferAmendmentProcessManager` → `TransactionAmendmentProcessManager`
- Helper functions following the same pattern (`transferAmendmentManagerDefault` etc. if they exist; check the file)

- [ ] **Step 1: Survey**

  ```bash
  grep -rn '\bTransferAmendmentManager\b\|\bTransferAmendmentData\b\|\bTransferAmendmentPhase\b\|\bTransferAmendmentProcessManager\b' src test
  grep -rn 'Application\.ProcessManagers\.TransferAmendmentManager' src test app
  ```

- [ ] **Step 2: Move and rename the file**

  ```bash
  git mv src/Application/ProcessManagers/TransferAmendmentManager.hs src/Application/ProcessManagers/TransactionAmendmentManager.hs
  ```

  Edit module header, type names, helpers.

- [ ] **Step 3: Update imports in callers**

  - Re-export aggregator
  - `app/Main.hs`
  - `test/Integration/TransferAmendmentIntegrationSpec.hs` (also: consider renaming the test file to `TransactionAmendmentIntegrationSpec.hs` — do it as `git mv` and update `hspec-discover` if used)

- [ ] **Step 4: Update `package.yaml` if needed; verify build**

  ```bash
  just build && just test
  ```

- [ ] **Step 5: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename TransferAmendmentManager module to TransactionAmendmentManager"
  ```

---

## Task 8: Rename service helpers (`initiateTransfer`, `amendTransfer`, `initiateInternalTransfer`)

**Renames in `src/Application/Services/TransactionService.hs`:**
- `initiateTransfer` (generic command runner around `InitiateTransaction`) → `initiateTransaction`
- `amendTransfer` → `amendTransaction`
- `initiateInternalTransfer` → `initiateTransfer` (drops the now-redundant `Internal` qualifier)

**Caution:** the rename order matters. If you rename `initiateInternalTransfer` → `initiateTransfer` first, you'll get a name collision with the still-existing generic `initiateTransfer`. Do the generic rename first.

- [ ] **Step 1: Survey**

  ```bash
  grep -rn '\binitiateTransfer\b\|\bamendTransfer\b\|\binitiateInternalTransfer\b' src test
  ```

- [ ] **Step 2: Edit `src/Application/Services/TransactionService.hs`**

  Order:
  1. `initiateTransfer` → `initiateTransaction` (the generic helper)
  2. `amendTransfer` → `amendTransaction`
  3. `initiateInternalTransfer` → `initiateTransfer` (now the slot is free)

  Update the module export list and the function definitions and any internal callers within the file.

- [ ] **Step 3: Propagate to callers**

  - `src/Web/API/TransactionAPI.hs` — handlers call these
  - `src/Telegram/Commands.hs` — `initiateInternalTransfer` is imported here too
  - Test files calling these helpers (search results from Step 1)

- [ ] **Step 4: Verify**

  ```bash
  grep -rn '\binitiateTransfer\b\|\bamendTransfer\b\|\binitiateInternalTransfer\b' src test
  ```

  Expected: only `initiateTransfer` remains (the renamed `initiateInternalTransfer`); the old names are gone.

  ```bash
  just build && just test
  ```

- [ ] **Step 5: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename service helpers (drop Internal qualifier from initiateTransfer)

  - initiateTransfer (generic runner) -> initiateTransaction
  - amendTransfer -> amendTransaction
  - initiateInternalTransfer -> initiateTransfer

  After the type-name rename, Transfer is unambiguously Regular->Regular,
  so the Internal qualifier on the kind helper is redundant."
  ```

---

## Task 9: Rename Web layer DTOs and handlers

**Renames:**
- `InternalTransferRequest` → `TransferRequest`
- `AmendTransferRequest` → `AmendTransactionRequest`
- `amendTransferHandler` → `amendTransactionHandler`

**Files:**
- Modify: `src/Web/Types.hs`, `src/Web/API/TransactionAPI.hs`, tests in `test/Web/API/`.

Routes stay at `POST /transactions/transfer` and `POST /transactions/{id}/amend`.

- [ ] **Step 1: Survey**

  ```bash
  grep -rn '\bInternalTransferRequest\b\|\bAmendTransferRequest\b\|\bamendTransferHandler\b' src test
  ```

- [ ] **Step 2: Edit `src/Web/Types.hs`**

  - `InternalTransferRequest` → `TransferRequest` (data type, constructor, ToJSON/FromJSON instances, export list)
  - `AmendTransferRequest` → `AmendTransactionRequest`

- [ ] **Step 3: Edit `src/Web/API/TransactionAPI.hs`**

  - `amendTransferHandler` → `amendTransactionHandler`
  - Update imports and handler routing
  - `transferHandler` keeps its name (kind-named)

- [ ] **Step 4: Update tests**

  ```bash
  grep -rn '\bInternalTransferRequest\b\|\bAmendTransferRequest\b\|\bamendTransferHandler\b' test
  ```

  Update test files. The integration test files send JSON bodies — those payloads use the field names of the renamed types, but JSON field names are derived from Haskell record fields. If the request body field shape changes (e.g., the old DTO had a `transferType` field that's now `transactionType`), update the JSON in the test fixtures.

- [ ] **Step 5: Verify**

  ```bash
  just build && just test
  ```

- [ ] **Step 6: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename Web DTOs and handlers

  - InternalTransferRequest -> TransferRequest
  - AmendTransferRequest -> AmendTransactionRequest
  - amendTransferHandler -> amendTransactionHandler

  Routes unchanged."
  ```

---

## Task 10: Rename test helpers (`seedInternalTransfer`)

- [ ] **Step 1: Survey**

  ```bash
  grep -rn '\bseedInternalTransfer\b' test
  ```

- [ ] **Step 2: Rename**

  - `seedInternalTransfer` → `seedTransfer`

  Files (from Step 1 survey):
  - `test/Testkit/` (helper module that defines the seeder)
  - `test/Web/API/TransactionAPISpec.hs`
  - `test/Web/API/TransactionLabelsAPISpec.hs`
  - `test/Web/API/TransactionAllocationsAPISpec.hs`

- [ ] **Step 3: Verify**

  ```bash
  grep -rn '\bseedInternalTransfer\b' test
  ```

  Expected: empty.

  ```bash
  just build && just test
  ```

- [ ] **Step 4: Format + lint + commit**

  ```bash
  just format && just lint
  git add -A
  git commit -m "refactor(transaction): rename seedInternalTransfer test helper to seedTransfer"
  ```

---

## Task 11: Final verification and spec status update

- [ ] **Step 1: Final grep audit**

  Confirm no lingering old names in source/test code:

  ```bash
  # Type/field names
  grep -rn '\bTransferType\b\|\bTransferKind\b\|\bteansferType\b\|\brescaleTransferType\b' src test
  # Event names (excluding generic English in comments)
  grep -rn '\bTransferInitiated\b\|\bTransferCompleted\b\|\bTransferFailed\b' src test
  grep -rn '\bTransferAmendmentInitiated\b\|\bTransferAmendmentCompleted\b\|\bTransferAmendmentFailed\b' src test
  # Commands
  grep -rn '\bInitiateTransfer\b\|\bCompleteTransfer\b\|\bFailTransfer\b\|\bAmendTransfer\b\|\bCompleteTransferAmendment\b\|\bFailTransferAmendment\b' src test
  # Managers
  grep -rn '\bTransferManager\b\|\bTransferAmendmentManager\b\|\bTransferData\b\|\bTransferPhase\b\|\bTransferAmendmentData\b\|\bTransferAmendmentPhase\b' src test
  # Helpers
  grep -rn '\binitiateTransfer\b' src test | grep -v 'initiateInternalTransfer\|initiateTransaction'
  grep -rn '\bamendTransfer\b\|\binitiateInternalTransfer\b\|\bamendTransferHandler\b\|\bseedInternalTransfer\b\|\bInternalTransferRequest\b\|\bAmendTransferRequest\b' src test
  ```

  Each grep should print nothing (or only matches inside generic comments that are unrelated to the rename targets — review by eye).

  **Allowed remaining references** to the word "Transfer":
  - The `Transfer` constructor of `TransactionType`
  - The `TransferKind` constructor of `TransactionKind`
  - `transferHandler` in `TransactionAPI.hs`
  - `TransferRequest` (the renamed DTO)
  - `seedTransfer` (the renamed helper)
  - `initiateTransfer` (the renamed kind helper)
  - Generic English in docstrings/comments that don't refer to renamed identifiers

- [ ] **Step 2: Full test suite (slow path)**

  ```bash
  just check     # format + lint
  just build     # full build
  just test      # full test suite
  ```

  All must pass.

- [ ] **Step 3: Smoke test in dev**

  ```bash
  just docker-up
  just run       # starts the backend with config/test.yaml
  ```

  Stop the server (`Ctrl+C`). Confirm it boots without error. `just docker-down` to stop Postgres.

- [ ] **Step 4: Update spec status**

  Edit `docs/specs/2026-06-02-transaction-naming-consistency-design.md` frontmatter:

  ```yaml
  status: completed
  ```

  Update `docs/plans/2026-06-02-transaction-naming-consistency.md` frontmatter:

  ```yaml
  status: completed
  ```

- [ ] **Step 5: Commit and prepare PR**

  ```bash
  git add docs/
  git commit -m "docs(transaction): mark naming-consistency spec and plan as completed"
  ```

- [ ] **Step 6: Open the PR**

  ```bash
  git push -u origin refactor/rename-transfer-to-transaction
  gh pr create --title "refactor(transaction): rename Transfer* family to Transaction*" --body "$(cat <<'EOF'
  ## Summary

  Pure rename across types, events, commands, process managers, service
  helpers, and Web DTOs. Supersedes #93.

  - `TransferType` / `TransferKind` → `TransactionType` / `TransactionKind`
  - Posting saga: `Transfer{Initiated,Completed,Failed}` → `TransactionPosting{Initiated,Completed,Failed}`; `Initiate/Complete/FailTransfer` → `InitiateTransaction`, `Complete/FailTransactionPosting`
  - Amendment saga: `TransferAmendment*` → `TransactionAmendment*`; `AmendTransfer` → `AmendTransaction`
  - Process managers: `TransferManager` → `TransactionPostingManager`; `TransferAmendmentManager` → `TransactionAmendmentManager`
  - Service helpers: `initiateTransfer` (generic) → `initiateTransaction`; `initiateInternalTransfer` → `initiateTransfer` (drops `Internal` qualifier); `amendTransfer` → `amendTransaction`
  - Web DTOs: `InternalTransferRequest` → `TransferRequest`; `AmendTransferRequest` → `AmendTransactionRequest`

  No behaviour change. Clean event-JSON-tag break per the project's
  no-backcompat policy.

  Closes #93.

  ## Test plan

  - [x] `just check` — ormolu, hlint clean
  - [x] `just build` — green
  - [x] `just test` — full suite green
  - [x] Boot smoke test (`just run`) succeeds
  EOF
  )"
  ```

---

## Notes on substring collisions

The following identifier pairs share substrings; ordering renames matters.

| Outer (longer) | Inner (shorter, substring) | Strategy |
| --- | --- | --- |
| `CompleteTransferAmendment` | `CompleteTransfer` | Rename outer first, OR use whole-word matching for inner |
| `FailTransferAmendment` | `FailTransfer` | Same |
| `AmendTransferRequest` | `AmendTransfer` | Same |
| `TransferInitiatedEvent` | `TransferInitiated` | Substring substitution OK — both rename consistently |
| `TransferAmendmentInitiated` | `TransferAmendment` | Substring substitution OK — but `TransferAmendmentManager` doesn't get the event/command rename, so be precise per-task |
| `initiateInternalTransfer` | `initiateTransfer` | These DO NOT share a substring — safe |

When in doubt, after each substitution pass, run a grep for the original and review the remaining hits to make sure they're either intentional (not part of the rename) or genuinely missed (need another pass).

---

## Rollback

The rename is atomic per task. If a task introduces issues that aren't caught until later, revert just that commit with `git revert <sha>` and re-do. There are no cross-task data dependencies (no migrations, no state).
