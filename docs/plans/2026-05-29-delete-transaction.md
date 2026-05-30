---
status: draft
date: 2026-05-29
spec: ../specs/2026-05-29-delete-transaction-design.md
issue: homeaccounting/backend#85
---

# Delete (Cancel) Transaction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-facing cancellation of completed transactions via reversing-entry saga (`DELETE /api/transactions/:id`), mirroring the transfer-amendment saga pattern.

**Architecture:** New `TransactionCancellationManager` process manager orchestrates two guaranteed-success reversal legs (`ReverseAccountDebit`, `ReverseAccountCredit`) and finalises with a `TransactionCancellationCompleted` event. Cross-saga concurrency (cancel vs amend, double-cancel) is gated in the pure command handler via transient flags on the aggregate projection. Cancelled transactions are hidden from the default list view but visible via `?includeCancelled=true`.

**Tech Stack:** GHC 9.10.3, Cabal, Eventium (event store + process managers), Servant, RIO. All commands via `just` (run inside `nix develop`).

**Reference spec:** [`docs/specs/2026-05-29-delete-transaction-design.md`](../specs/2026-05-29-delete-transaction-design.md). Every task references the spec section that defines the contract — read it before coding.

**Reference implementation:** Every component has a direct sibling in the transfer-amendment-saga work (PR #83). When in doubt, mirror that file's structure exactly.

---

## File Inventory

**New files:**
- `src/Application/ProcessManagers/Snapshots.hs` — shared `TransferPostings` type
- `src/Application/ProcessManagers/TransactionCancellationManager.hs` — new saga
- `test/Domain/Transaction/CancellationCommandHandlerSpec.hs`
- `test/Domain/Transaction/CancellationPropertySpec.hs`
- `test/Application/ProcessManagers/TransactionCancellationManagerSpec.hs`
- `test/Application/ProcessManagers/TransactionCancellationManagerPropertySpec.hs`
- `test/Application/Services/TransactionServiceCancellationIntegrationSpec.hs`

**Modified files:**
- `src/Domain/Core/Errors.hs` — four new typed variants
- `src/Domain/Transaction/Commands.hs` — `CancelTransaction`, `CompleteTransactionCancellation`
- `src/Domain/Transaction/Events.hs` — `TransactionCancellationInitiated`, `TransactionCancellationCompleted`
- `src/Domain/Transaction/CommandHandler.hs` — five new `TransactionError` variants; new handler arms; modified `AmendTransfer` arm
- `src/Domain/Transaction/Projection.hs` — `Cancelled` status, `cancellationInProgress` flag, new event handlers
- `src/Application/ProcessManagers/TransferAmendmentManager.hs` — re-export `TransferPostings` from `Snapshots`
- `src/Application/ReadModels/Transaction.hs` — `qIncludeCancelled` field, new event arms, `findReferencingTransactions` filter
- `src/Application/Services/TransactionService.hs` — `cancelTransaction`, `dispatchAndAwaitCancellation`, `lastCancellationOutcome`, four new translation arms
- `src/Application/Services/TransactionHistoryService.hs` — two new history entries
- `src/Web/API/TransactionAPI.hs` — `DELETE` route + handler, `includeCancelled` query param threaded into the list handler
- `src/Web/ErrorMapping.hs` — four new `409 Conflict` mappings
- `src/Web/Types.hs` — `TransactionStatus` JSON pickup (likely automatic via Aeson Generic; verify only)
- `app/Main.hs` — register `transactionCancellationProcessManager`
- `package.yaml` — MINOR version bump 0.2.7 → 0.3.0 (Task 17); hspec-discover finds new tests automatically — no per-module edits

---

## Task Ordering

Tasks are ordered for short, reviewable commits. Roughly bottom-up: domain types → pure handler → projection → read-model → process manager → service → web. Cross-cutting test additions sit at the end of their layer.

Run `just check` (ormolu + hlint) before every commit. Run `just build` after every code change. Run `just test` after every test addition.

---

## Task 1: Add typed `DomainError` variants

**Spec:** §3.1 translation table. Adds four payload-free typed variants used at the HTTP boundary.

**Files:**
- Modify: `src/Domain/Core/Errors.hs`

- [ ] **Step 1: Add the four new constructors to `DomainError`**

Add (next to existing `CannotAmend*` variants near line 111):

```haskell
  | -- | Cancelling a transaction that is already in the Cancelled terminal state.
    TransactionAlreadyCancelled
  | -- | A cancellation saga is already in progress on this transaction.
    --   Reachable via two near-simultaneous DELETE requests; surfaced as 409.
    CancellationAlreadyInProgress
  | -- | CancelTransaction issued while an amendment saga is in flight on the
    --   same transaction.
    CannotCancelDuringAmendment
  | -- | AmendTransfer issued while a cancellation saga is in flight on the
    --   same transaction.
    CannotAmendDuringCancellation
```

- [ ] **Step 2: Add message renderers**

Extend the `errorMessage` (or equivalent) function (around line 195-216) with arms:

```haskell
  TransactionAlreadyCancelled ->
    "Transaction is already cancelled"
  CancellationAlreadyInProgress ->
    "A cancellation is already in progress for this transaction"
  CannotCancelDuringAmendment ->
    "Cannot cancel: an amendment is in progress for this transaction"
  CannotAmendDuringCancellation ->
    "Cannot amend: a cancellation is in progress for this transaction"
```

- [ ] **Step 3: Verify build**

```
just build
```
Expected: clean build, no warnings.

- [ ] **Step 4: Commit**

```
git add src/Domain/Core/Errors.hs
git commit -m "feat(domain): add DomainError variants for transaction cancellation"
```

---

## Task 2: Extend pure `TransactionStatus` and projection state

**Spec:** §1, §3.3.

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs`

- [ ] **Step 1: Add `Cancelled` to `TransactionStatus`**

Add the constructor at the end of the enum (around line 86):

```haskell
data TransactionStatus
  = Pending
  | Completed
  | Failed Text
  | Cancelled  -- new
  deriving (Show, Eq, Generic)
```

Aeson's `Generic` deriving picks up the new constructor automatically; existing on-disk `Pending` / `Completed` / `Failed` payloads still deserialise.

- [ ] **Step 2: Add `cancellationInProgress` field to `Transaction`**

Add the field next to `amendmentInProgress` (around line 158):

```haskell
    -- | Transient flag: True between TransactionCancellationInitiated and
    -- TransactionCancellationCompleted. Gates CompleteTransactionCancellation
    -- and (in §3.1) cross-saga conflicts with AmendTransfer.
    cancellationInProgress :: Bool
```

- [ ] **Step 3: Extend `transactionDefault`**

Add `cancellationInProgress = False` to the record at line 181-205.

- [ ] **Step 4: Update `fromTransactionStatus`**

`src/Web/Types.hs` has a hand-written encoder at lines 1023-1026; the new constructor needs a matching arm:

```haskell
fromTransactionStatus Cancelled = "Cancelled"
```

- [ ] **Step 5: Update `Transaction { … }` record literals**

Build will fail until every full `Transaction` record literal includes `cancellationInProgress`. The concrete call sites are:

- `src/Domain/Transaction/Projection.hs:182` — `transactionDefault` (covered in Step 3)
- `test/Domain/Transaction/AmendmentPropertySpec.hs`
- `test/Domain/Transaction/LabelsProjectionSpec.hs:47-54`
- `test/Domain/Transaction/DescriptionAndDateSpec.hs:86-92`
- `test/Domain/Transaction/LabelsAndCategorySpec.hs`

For each: add `, cancellationInProgress = False` (or `True` where the test cares about it). Verify by `grep -rn "Transaction\s*{" src/ test/` — that's exhaustive.

- [ ] **Step 6: Verify build**

```
just build
```
Expected: clean build, no incomplete-pattern warnings.

- [ ] **Step 7: Run existing tests**

```
just test
```
Expected: existing suite still passes (no behaviour change; new field defaults to False everywhere).

- [ ] **Step 8: Commit**

```
git add src/Domain/Transaction/Projection.hs src/Web/Types.hs test/Domain/Transaction/
git commit -m "feat(domain): add Cancelled status and cancellationInProgress flag"
```

---

## Task 3: Add cancellation events

**Spec:** §3.2.

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`

- [ ] **Step 1: Declare the two event records**

Add after the `TransferAmendmentFailed` block (around line 250):

```haskell
data TransactionCancellationInitiated = TransactionCancellationInitiated
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }
  deriving (Show, Eq)

data TransactionCancellationCompleted = TransactionCancellationCompleted
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }
  deriving (Show, Eq)
```

- [ ] **Step 2: Register in the TH event list**

Add to `transactionEvents` (around line 60):

```haskell
    ''TransactionCancellationInitiated,
    ''TransactionCancellationCompleted
```

- [ ] **Step 3: Derive JSON instances**

Add to the bottom of the file with the other `deriveJSON` calls:

```haskell
deriveJSON defaultOptions ''TransactionCancellationInitiated
deriveJSON defaultOptions ''TransactionCancellationCompleted
```

- [ ] **Step 4: Update exports**

Add `TransactionCancellationInitiated (..)` and `TransactionCancellationCompleted (..)` to the module export list (around line 30).

- [ ] **Step 5: Extend the projection event handlers**

In `src/Domain/Transaction/Projection.hs`, add two arms to `handleTransactionEvent` (around line 348):

```haskell
handleTransactionEvent transaction (TransactionCancellationInitiatedTransactionEvent _) =
  transaction & #cancellationInProgress .~ True
handleTransactionEvent transaction (TransactionCancellationCompletedTransactionEvent _) =
  transaction
    & #status                 .~ Cancelled
    & #cancellationInProgress .~ False
```

- [ ] **Step 6: Verify build**

```
just build
```
Expected: build succeeds. The TH splice regenerates `TransactionEvent` with the two new constructors. Any exhaustive pattern match elsewhere on `TransactionEvent` may need new arms (read models, history service, saga managers — covered in later tasks).

- [ ] **Step 7: Commit**

```
git add src/Domain/Transaction/Events.hs src/Domain/Transaction/Projection.hs
git commit -m "feat(domain): add TransactionCancellationInitiated/Completed events"
```

---

## Task 4: Add cancellation commands + handler arms (single atomic step)

**Spec:** §3.1.

**Why these merge:** Adding commands to `transactionCommands` widens the TH-generated `TransactionCommand` sum type, which makes the existing `handleTransactionCommand` non-exhaustive. Splitting commands and handler into two commits would leave a non-exhaustive-pattern warning in between (CI uses `-Werror` per CLAUDE.md, but even outside CI this is a runtime hazard). Land them together.

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Create: `test/Domain/Transaction/CancellationCommandHandlerSpec.hs`

- [ ] **Step 1: Declare the two command records**

In `src/Domain/Transaction/Commands.hs`, add after `FailTransferAmendment` (around line 305):

```haskell
data CancelTransaction = CancelTransaction
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }
  deriving (Show, Eq)

data CompleteTransactionCancellation = CompleteTransactionCancellation
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }
  deriving (Show, Eq)
```

- [ ] **Step 2: Register in the TH command list + derive JSON + export**

Add to `transactionCommands` (line 57):

```haskell
    ''CancelTransaction,
    ''CompleteTransactionCancellation
```

Add to the bottom of the file:

```haskell
deriveJSON defaultOptions ''CancelTransaction
deriveJSON defaultOptions ''CompleteTransactionCancellation
```

Add `CancelTransaction (..)`, `CompleteTransactionCancellation (..)` to the module export list.

- [ ] **Step 3: Write the failing test file**

`test/Domain/Transaction/CancellationCommandHandlerSpec.hs`. Cover **every row of the §3.1 table plus the AmendTransfer regression**. Pattern after `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` for spec layout. For fixtures use `transactionDefault` from `Domain.Transaction.Projection` and set fields via lenses, e.g.:

```haskell
let tx = transactionDefault
      & #status .~ Completed
      & #cancellationInProgress .~ True
```

Required cases:

| Initial state | Command | Expected |
| --- | --- | --- |
| `status = Completed`, both flags False | `CancelTransaction` | `Right [TransactionCancellationInitiated …]` |
| `status = Pending` | `CancelTransaction` | `Left CannotEditUncompletedTransaction` |
| `status = Failed _` | `CancelTransaction` | `Left CannotEditUncompletedTransaction` |
| `status = Cancelled` | `CancelTransaction` | `Left TransactionAlreadyCancelled` |
| `status = Completed`, `amendmentInProgress = True` | `CancelTransaction` | `Left CannotCancelDuringAmendment` |
| `status = Completed`, `cancellationInProgress = True` | `CancelTransaction` | `Left CancellationAlreadyInProgress` |
| `cancellationInProgress = True` | `CompleteTransactionCancellation` | `Right [TransactionCancellationCompleted …]` |
| `cancellationInProgress = False` | `CompleteTransactionCancellation` | `Left NoCancellationInProgress` |
| `cancellationInProgress = True`, valid amend payload | `AmendTransfer` | `Left CannotAmendDuringCancellation` |
| `cancellationInProgress = False`, **same-account-pair** amend payload | `AmendTransfer` | `Left AmendTransferToSameAccountPair` (regression — verifies the new guard interleaves correctly) |
| `cancellationInProgress = False`, **zero-amount** amend payload | `AmendTransfer` | `Left AmendTransferToZeroAmount` (regression) |
| `status = Cancelled` | `ChangeTransactionDescription` | `Left CannotEditUncompletedTransaction` (existing catch-all hit) |
| `status = Cancelled` | `SetTransactionLabels` | `Left CannotEditUncompletedTransaction` |

- [ ] **Step 4: Run the tests; verify they fail to compile**

```
cabal test all --test-option='--match' --test-option='/Domain.Transaction.CancellationCommandHandler/'
```
Expected: compile error — `TransactionError` constructors `TransactionAlreadyCancelled`, `CancellationAlreadyInProgress`, `CannotCancelDuringAmendment`, `NoCancellationInProgress`, `CannotAmendDuringCancellation` don't exist; new commands don't have handler arms.

- [ ] **Step 5: Add the new `TransactionError` constructors**

In `src/Domain/Transaction/CommandHandler.hs` around line 60-78:

```haskell
  | TransactionAlreadyCancelled
  | CancellationAlreadyInProgress
  | CannotCancelDuringAmendment
  | NoCancellationInProgress
  | CannotAmendDuringCancellation
```

- [ ] **Step 6: Add the `CancelTransaction` and `CompleteTransactionCancellation` handler arms**

Add after the existing `FailTransferAmendment` arm (around line 282):

```haskell
handleTransactionCommand transaction (CancelTransactionTransactionCommand CancelTransaction {..}) =
  case transaction ^. #status of
    Completed
      | transaction ^. #amendmentInProgress    -> Left CannotCancelDuringAmendment
      | transaction ^. #cancellationInProgress -> Left CancellationAlreadyInProgress
      | otherwise ->
          Right
            [ TransactionCancellationInitiatedTransactionEvent
                TransactionCancellationInitiated
                  { transactionId = transactionId
                  , cancelledBy   = cancelledBy
                  }
            ]
    Cancelled -> Left TransactionAlreadyCancelled
    _         -> Left CannotEditUncompletedTransaction
handleTransactionCommand transaction (CompleteTransactionCancellationTransactionCommand CompleteTransactionCancellation {..}) =
  if not (transaction ^. #cancellationInProgress)
    then Left NoCancellationInProgress
    else
      Right
        [ TransactionCancellationCompletedTransactionEvent
            TransactionCancellationCompleted
              { transactionId = transactionId
              , cancelledBy   = cancelledBy
              }
        ]
```

- [ ] **Step 7: Rewrite the existing `AmendTransfer` arm to add the `cancellationInProgress` guard**

Replace the existing arm at lines 233-254 wholesale. The original uses nested `if … then … else if`; refactor to a guard chain so the new condition fits cleanly. **Full replacement:**

```haskell
handleTransactionCommand transaction (AmendTransferTransactionCommand AmendTransfer {..}) =
  case transaction ^. #status of
    Completed
      | transaction ^. #cancellationInProgress ->
          Left CannotAmendDuringCancellation
      | unAccountId newSourceAccountId == unAccountId newTargetAccountId ->
          Left AmendTransferToSameAccountPair
      | unMoney newSourceAmount == 0 || unMoney newTargetAmount == 0 ->
          Left AmendTransferToZeroAmount
      | otherwise ->
          Right
            [ TransferAmendmentInitiatedTransactionEvent
                TransferAmendmentInitiated
                  { transactionId      = transactionId
                  , newSourceAccountId = newSourceAccountId
                  , newTargetAccountId = newTargetAccountId
                  , newSourceAmount    = newSourceAmount
                  , newTargetAmount    = newTargetAmount
                  , newExchangeRate    = newExchangeRate
                  , amendedBy          = amendedBy
                  }
            ]
    _ -> Left CannotEditUncompletedTransaction
```

Behaviour for `cancellationInProgress = False` is unchanged.

- [ ] **Step 8: Run the new cancellation tests; verify all pass**

```
cabal test all --test-option='--match' --test-option='/Domain.Transaction.CancellationCommandHandler/'
```
Expected: PASS.

- [ ] **Step 9: Run the existing amendment-handler tests; verify no regression**

```
cabal test all --test-option='--match' --test-option='/Domain.Transaction.AmendmentCommandHandler/'
```
Expected: PASS — the guard-chain refactor on `AmendTransfer` preserves all existing behaviour.

- [ ] **Step 10: `just check` and commit**

```
just check
git add src/Domain/Transaction/Commands.hs src/Domain/Transaction/CommandHandler.hs test/Domain/Transaction/CancellationCommandHandlerSpec.hs
git commit -m "feat(domain): cancel commands + handler arms with cross-saga gating"
```

---

## Task 5: Property tests for cancellation handler

**Spec:** §Testing — "Property (domain)" row.

**Files:**
- Create: `test/Domain/Transaction/CancellationPropertySpec.hs`

- [ ] **Step 1: Pattern after `AmendmentPropertySpec.hs`**

Required properties:

1. **Handler determinism:** `handleTransactionCommand s c == handleTransactionCommand s c` for arbitrary `Transaction` and `CancelTransaction` / `CompleteTransactionCancellation`.
2. **Status monotonicity:** for any `Transaction` with `status = Cancelled` and any `TransactionEvent`, `handleTransactionEvent t e ^. #status == Cancelled` — Cancelled is terminal at the projection level.
3. **`cancellationInProgress` is bracketed:** for any stream containing exactly one `TransactionCancellationInitiated` followed by exactly one `TransactionCancellationCompleted`, the flag is True between them and False after.

Use existing `Testkit.Generators` for `Transaction`, `Money`, etc.

- [ ] **Step 2: Run and verify**

```
cabal test all --test-option='--match' --test-option='/Domain.Transaction.CancellationProperty/'
```
Expected: PASS.

- [ ] **Step 3: Commit**

```
git add test/Domain/Transaction/CancellationPropertySpec.hs
git commit -m "test(domain): property tests for cancellation handler"
```

---

## Task 6: Extract `TransferPostings` to shared module

**Spec:** §4.2 paragraph 4. The only non-additive change to existing code.

**Files:**
- Create: `src/Application/ProcessManagers/Snapshots.hs`
- Modify: `src/Application/ProcessManagers/TransferAmendmentManager.hs`

- [ ] **Step 1: Create the new module**

`src/Application/ProcessManagers/Snapshots.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Shared snapshot types used by transfer-amendment and
-- transaction-cancellation process managers. Both managers fold
-- TransferInitiated and TransferAmendmentCompleted events identically
-- into their own currentPostings maps.
module Application.ProcessManagers.Snapshots
  ( TransferPostings (..),
  )
where

import Data.Time (UTCTime)
import Domain.Core.Types (AccountId, Money)
import Optics (makeFieldLabelsNoPrefix)

-- | Snapshot of the canonical posting facts at the most recently
-- committed state of a transaction. Field documentation matches the
-- original definition in TransferAmendmentManager (which now
-- re-exports this type).
data TransferPostings = TransferPostings
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount    :: Money,
    targetAmount    :: Money,
    at              :: UTCTime
  }
  deriving (Show, Eq)

makeFieldLabelsNoPrefix ''TransferPostings
```

- [ ] **Step 2: Delete the original `TransferPostings` definition**

In `src/Application/ProcessManagers/TransferAmendmentManager.hs` (lines 116-123), delete the data declaration only. There is **no** `makeFieldLabelsNoPrefix ''TransferPostings` in the existing file — the manager uses record-dot syntax (`p.at`, `evt.sourceAccountId`), not optics labels, on this type. The `Snapshots.hs` you wrote in Step 1 *does* add `makeFieldLabelsNoPrefix ''TransferPostings`; both consumers (amendment + cancellation) will use that going forward.

- [ ] **Step 3: Add the import + re-export**

In the same file, add:

```haskell
import Application.ProcessManagers.Snapshots (TransferPostings (..))
```

…and add `TransferPostings (..)` to the module export list (currently around line 31-46) so all existing consumers continue to import it from the same module path.

- [ ] **Step 4: Run hpack and verify build**

```
just build
```
Expected: clean build. Hpack regenerates `backend.cabal` to include the new module. `package.yaml` is unchanged (Hpack discovers modules via `source-dirs: src`, no per-module listing).

- [ ] **Step 5: Run the existing amendment tests**

```
cabal test all --test-option='--match' --test-option='/TransferAmendmentManager/'
```
Expected: PASS — pure type relocation, no behaviour change.

- [ ] **Step 6: Commit**

```
git add src/Application/ProcessManagers/Snapshots.hs src/Application/ProcessManagers/TransferAmendmentManager.hs backend.cabal
git commit -m "refactor(process-managers): extract TransferPostings to shared module"
```

---

## Task 7: `TransactionCancellationManager` process manager (TDD)

**Spec:** §4.2, §4.3, §4.4. Reference: `src/Application/ProcessManagers/TransferAmendmentManager.hs` for structure, naming, and Eventium wiring.

**Files:**
- Create: `src/Application/ProcessManagers/TransactionCancellationManager.hs`
- Create: `test/Application/ProcessManagers/TransactionCancellationManagerSpec.hs`

- [ ] **Step 1: Write the failing unit test file**

Pattern after `test/Application/ProcessManagers/TransferAmendmentManagerSpec.hs`. Required cases per spec §Testing "Unit (saga)" row:

1. `TransferInitiatedEvent` populates `currentPostings` with the original posting facts.
2. `TransferAmendmentCompletedEvent` updates `currentPostings` to the amended facts; subsequent cancellation uses amended amounts.
3. `TransactionCancellationInitiatedEvent` creates a `cancellations` entry and the react function emits exactly two commands: `ReverseAccountDebit` on the source account, `ReverseAccountCredit` on the target account, with the snapshot's amounts and `at`.
4. `AccountDebitReversedEvent` for the saga's `transactionId` toggles `sourceReversed = True`; second event (`AccountCreditReversed`) toggles `targetReversed = True` and the react function emits `CompleteTransactionCancellation`.
5. Reversal arrival order doesn't matter (test both `Debit` then `Credit` and `Credit` then `Debit`).
6. `TransactionCancellationCompletedEvent` deletes both `cancellations` and `currentPostings` entries.
7. Replay of `AccountDebitReversedEvent` after `TransactionCancellationCompletedEvent` lands is a no-op (no command emitted).

- [ ] **Step 2: Run; verify failure**

```
cabal test all --test-option='--match' --test-option='/TransactionCancellationManager/'
```
Expected: module doesn't exist; compile error.

- [ ] **Step 3: Implement the module**

`src/Application/ProcessManagers/TransactionCancellationManager.hs`. Mirror the amendment manager file's structure. Spec §4.2-4.4 contains the concrete code; key types:

```haskell
data TransactionCancellationManager = TransactionCancellationManager
  { cancellations   :: Map TransactionId TransactionCancellationData
  , currentPostings :: Map TransactionId TransferPostings
  }

data TransactionCancellationData = TransactionCancellationData
  { transactionId  :: TransactionId
  , cancelledBy    :: UserId
  , sourceReversed :: Bool
  , targetReversed :: Bool
  }

makeFieldLabelsNoPrefix ''TransactionCancellationManager
makeFieldLabelsNoPrefix ''TransactionCancellationData
```

Both `makeFieldLabelsNoPrefix` splices are required so the spec §4.3-4.4 code using `m & #cancellations % at txId %~ …` and `c.sourceReversed` typechecks.

Mandatory functions:

- `handleTransactionCancellationEvent :: TransactionCancellationManager -> VersionedStreamEvent AccountingEvent -> TransactionCancellationManager` — all six arms per spec §4.3.
- `reactToTransactionCancellationEvent :: TransactionCancellationManager -> VersionedStreamEvent AccountingEvent -> [ProcessManagerEffect AccountingCommand]` — arms for `TransactionCancellationInitiatedEvent`, `AccountDebitReversedEvent`, `AccountCreditReversedEvent` per spec §4.4.
- `completeIfReady` helper.
- `transactionCancellationManagerProjection :: Projection TransactionCancellationManager (VersionedStreamEvent AccountingEvent)`.
- `transactionCancellationProcessManager :: TransactionCancellationProcessManager`.

Imports: `Application.ProcessManagers.Snapshots (TransferPostings (..))`, `Domain.Models`, plus the same Eventium imports as the amendment manager.

- [ ] **Step 4: Run; verify all pass**

```
cabal test all --test-option='--match' --test-option='/TransactionCancellationManager/'
```
Expected: PASS for every case from Step 1.

- [ ] **Step 5: `just check`, commit**

```
just check
git add src/Application/ProcessManagers/TransactionCancellationManager.hs test/Application/ProcessManagers/TransactionCancellationManagerSpec.hs package.yaml backend.cabal
git commit -m "feat(process-managers): TransactionCancellationManager saga"
```

---

## Task 8: Property tests for `TransactionCancellationManager`

**Spec:** §Testing — "Property (saga)" row.

**Files:**
- Create: `test/Application/ProcessManagers/TransactionCancellationManagerPropertySpec.hs`

- [ ] **Step 1: Pattern after `TransferAmendmentManagerPropertySpec.hs`**

Required properties:

1. **Exactly two reversal commands per cancellation.** For any valid `TransferPostings`, the saga emits exactly one `ReverseAccountDebit` and one `ReverseAccountCredit` with the snapshotted amounts and `at`.
2. **Permutation invariance.** For all permutations of the four-event sequence (`TransactionCancellationInitiated`, `AccountDebitReversed`, `AccountCreditReversed`, `TransactionCancellationCompleted`) where order is consistent with causal dependency (Initiated first, both reversals before Completed), the saga produces the same final state and the same multiset of commands.
3. **Per-transaction independence.** Two cancellations on different `transactionId`s never affect each other's `cancellations` or `currentPostings` entries.

- [ ] **Step 2: Run; verify PASS**

```
cabal test all --test-option='--match' --test-option='/TransactionCancellationManagerProperty/'
```

- [ ] **Step 3: Commit**

```
git add test/Application/ProcessManagers/TransactionCancellationManagerPropertySpec.hs
git commit -m "test(process-managers): property tests for cancellation saga"
```

---

## Task 9: Read model — events, status filter, `findReferencingTransactions`

**Spec:** §5.

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`

- [ ] **Step 1: Add `qIncludeCancelled` to `TransactionQuery`**

Add field at line 152-157:

```haskell
data TransactionQuery = TransactionQuery
  { qAccountId        :: Maybe AccountId
  , qFrom             :: Maybe UTCTime
  , qTo               :: Maybe UTCTime
  , qIncludeCancelled :: Bool
  }
  deriving (Show, Eq)
```

- [ ] **Step 2: Update `mkTransactionQuery` to take a fourth arg**

```haskell
mkTransactionQuery ::
  Maybe AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Bool ->
  Either Text TransactionQuery
mkTransactionQuery acct mFrom mTo includeCancelled =
  case (mFrom, mTo) of
    (Just f, Just t) | f > t -> Left "from must be <= to"
    _ -> Right TransactionQuery
      { qAccountId        = acct
      , qFrom             = mFrom
      , qTo               = mTo
      , qIncludeCancelled = includeCancelled
      }
```

- [ ] **Step 3: Update `emptyTransactionQuery`**

```haskell
emptyTransactionQuery = TransactionQuery
  { qAccountId        = Nothing
  , qFrom             = Nothing
  , qTo               = Nothing
  , qIncludeCancelled = False
  }
```

- [ ] **Step 4: Add the `isVisibleByStatus` predicate to `listTransactions`**

In `listTransactions` (around line 447-478), add the predicate to the filter chain:

```haskell
isVisibleByStatus td = case td.status of
  Cancelled -> query.qIncludeCancelled
  _         -> True
```

…and include it in the filter list alongside `isVisible`, `matchesAccount`, `matchesFrom`, `matchesTo`.

- [ ] **Step 5: Add event handlers for cancellation events**

In `processEvent` (around line 358-378), add two arms:

```haskell
TransactionCancellationInitiatedEvent _evt -> transactions
  -- saga-internal marker; no canonical change
TransactionCancellationCompletedEvent _evt ->
  case mkTransactionIdSafe streamUuid of
    Nothing -> transactions
    Just transactionId ->
      Map.adjust
        (\transaction -> (transaction :: TransactionData) {status = Cancelled})
        transactionId
        transactions
```

Update imports at the top of the file: add `TransactionCancellationInitiatedEvent`, `TransactionCancellationCompletedEvent` to the `AccountingEvent` import; add `TransactionCancellationCompleted (..)` to the Domain.Transaction.Events import (if you reference the field) — though if the projection ignores both events' payloads except for status, only the constructor is needed.

Also add `Cancelled` to the `Domain.Transaction.Projection.TransactionStatus` import (line 95).

- [ ] **Step 6: Tighten `findReferencingTransactions`**

In the helper (line 510-520), add the status filter:

```haskell
referencesEntry td =
  td.status /= Cancelled
    && ( Set.member entryId td.labels
           || case td.transferType of
                Income cid -> cid == entryId
                Expense cid -> cid == entryId
                Transfer -> False
                Adjustment -> False
       )
```

- [ ] **Step 7: Verify build**

```
just build
```
Expected: build fails at every call site of `mkTransactionQuery`. The concrete call sites that need updating are:

- `src/Web/API/TransactionAPI.hs:388`
- `src/Telegram/Commands.hs:400`
- `test/Application/ReadModels/TransactionListSpec.hs` — 6 call sites (lines 151, 160, 170, 179, 190, 244, 250)
- `test/Application/ReadModels/TransactionQuerySpec.hs` — 6 call sites
- `test/Application/ReadModels/TransactionListPropertySpec.hs:121`

For each non-Web call site, pass `False` as the fourth argument to preserve current behaviour. The Web caller is updated in Task 12 to thread the parsed query param.

- [ ] **Step 8: Run existing tests**

```
just test
```
Expected: PASS, possibly after fixing test-helper call sites for the new arg.

- [ ] **Step 9: Commit**

```
just check
git add src/Application/ReadModels/Transaction.hs <other touched files>
git commit -m "feat(read-model): cancellation events + includeCancelled filter"
```

---

## Task 10: `TransactionService.cancelTransaction`

**Spec:** §6.

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`

- [ ] **Step 1: Add translation arms for the four new pure-handler errors**

In `translateTransactionError` (around line 799-813), add:

```haskell
translateTransactionError (CommandRejected TxCh.TransactionAlreadyCancelled) =
  TransactionAlreadyCancelled
translateTransactionError (CommandRejected TxCh.CancellationAlreadyInProgress) =
  CancellationAlreadyInProgress
translateTransactionError (CommandRejected TxCh.CannotCancelDuringAmendment) =
  CannotCancelDuringAmendment
translateTransactionError (CommandRejected TxCh.NoCancellationInProgress) =
  TransactionError "No cancellation in progress"
translateTransactionError (CommandRejected TxCh.CannotAmendDuringCancellation) =
  CannotAmendDuringCancellation
```

- [ ] **Step 2: Add `CancellationOutcome` ADT and `lastCancellationOutcome`**

Pattern after `AmendmentOutcome` / `lastAmendmentOutcome` (line 776-793):

```haskell
data CancellationOutcome
  = CancellationSucceeded
  | CancellationUnknown
  deriving (Show, Eq)

lastCancellationOutcome :: [TransactionEvent] -> CancellationOutcome
lastCancellationOutcome = foldl' step CancellationUnknown
  where
    step _ (TransactionCancellationCompletedEvent _) = CancellationSucceeded
    step acc _                                       = acc
```

- [ ] **Step 3: Add `dispatchAndAwaitCancellation`**

Pattern after `dispatchAndAwaitAmendment` (line 753-770):

```haskell
dispatchAndAwaitCancellation ::
  TransactionId ->
  TransactionCommand ->
  AppM (Either DomainError TransactionData)
dispatchAndAwaitCancellation txId cmd = runExceptT $ do
  runTransactionCmd translateTransactionError id (unTransactionId txId) cmd
  events <- ExceptT (readTransactionStream txId)
  case lastCancellationOutcome events of
    CancellationSucceeded -> ExceptT (readTransaction txId)
    CancellationUnknown   -> throwError (TransactionError "Cancellation saga did not produce a terminal event")
```

(Adjust to match the existing helper's exact dispatch shape — likely needs the same `runTransactionCmd` plumbing as amendment.)

- [ ] **Step 4: Add `cancelTransaction`**

Pattern after `amendTransfer` (line 523-557):

```haskell
cancelTransaction ::
  UserId ->
  TransactionId ->
  AppM (Either DomainError TransactionData)
cancelTransaction userId transactionId = runExceptT $ do
  lift
    $ logInfo
    $ "Cancelling transaction "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  ExceptT
    ( dispatchAndAwaitCancellation
        transactionId
        ( CancelTransactionTransactionCommand
            CancelTransaction { transactionId = transactionId, cancelledBy = userId }
        )
    )
```

- [ ] **Step 5: Export `cancelTransaction`**

Add to the module export list (around line 37).

- [ ] **Step 6: Verify build**

```
just build
```
Expected: clean build.

- [ ] **Step 7: `just check` + run existing tests**

```
just check
just test
```
Expected: existing suite PASS. Service-level integration test for the new function comes in Task 13.

- [ ] **Step 8: Commit**

```
git add src/Application/Services/TransactionService.hs
git commit -m "feat(service): TransactionService.cancelTransaction"
```

---

## Task 11: History service entries

**Spec:** §6 last paragraph.

**Files:**
- Modify: `src/Application/Services/TransactionHistoryService.hs`

- [ ] **Step 1: Add the two history entries**

Around line 107-109:

```haskell
  | HistoryCancellationInitiated TransactionCancellationInitiated
  | HistoryCancellationCompleted TransactionCancellationCompleted
```

- [ ] **Step 2: Add step-function arms**

Around line 166-168:

```haskell
TransactionCancellationInitiatedEvent e -> Just (HistoryCancellationInitiated e)
TransactionCancellationCompletedEvent e -> Just (HistoryCancellationCompleted e)
```

- [ ] **Step 3: Update imports**

Add `TransactionCancellationInitiated`, `TransactionCancellationCompleted` to the `Domain.Transaction.Events` import and the corresponding `*Event` constructors to the `Domain.Models` import.

- [ ] **Step 4: Update exports**

Add the new constructors to `TransactionHistoryEntry (..)` in the module export list (the entry sum type, not the `TransactionHistory` wrapper). Inspect `TransactionHistoryService.hs:90-107` to confirm the constructor names match the existing pattern.

- [ ] **Step 5: Build + test**

```
just build && just test
```

- [ ] **Step 6: Commit**

```
git add src/Application/Services/TransactionHistoryService.hs
git commit -m "feat(history): cancellation entries in transaction history"
```

---

## Task 12: HTTP error mapping + web layer

**Spec:** §7.

**Files:**
- Modify: `src/Web/ErrorMapping.hs`
- Modify: `src/Web/API/TransactionAPI.hs`

- [ ] **Step 1: Add the four 409 mappings**

In `Web.ErrorMapping.mapDomainError`, add arms returning `err409`:

```haskell
mapDomainError TransactionAlreadyCancelled =
  err409 { errBody = encodeError "Transaction is already cancelled" }
mapDomainError CancellationAlreadyInProgress =
  err409 { errBody = encodeError "A cancellation is already in progress" }
mapDomainError CannotCancelDuringAmendment =
  err409 { errBody = encodeError "Cannot cancel: amendment in progress" }
mapDomainError CannotAmendDuringCancellation =
  err409 { errBody = encodeError "Cannot amend: cancellation in progress" }
```

…where `encodeError msg = encode (ErrorResponse { error = msg })` — pattern after the existing `TransactionError` mapping.

- [ ] **Step 2: Add the Servant route**

In `Web.API.TransactionAPI` `TransactionAPI` type, add:

```haskell
  :<|> AuthProtect "jwt"
     :> Capture "id" UUID
     :> DeleteNoContent
```

- [ ] **Step 3: Thread `includeCancelled` through the list endpoint**

Find the existing list route in the API type, add `:> QueryParam "includeCancelled" Bool`. Update the list handler signature to take the additional `Maybe Bool` and pass `fromMaybe False` into `mkTransactionQuery`.

- [ ] **Step 4: Add `cancelTransactionHandler`**

Pattern after `changeDateHandler` / `setLabelsHandler`:

```haskell
cancelTransactionHandler ::
  AuthenticatedUser -> UUID -> AppM NoContent
cancelTransactionHandler user rawId = do
  transactionId <- validateField "id" (mkTransactionId rawId)
  result <- TransactionService.cancelTransaction user.userId transactionId
  case result of
    Right _  -> pure NoContent
    Left err -> throwDomainError err
```

- [ ] **Step 5: Wire into `transactionServer`**

Add `:<|> cancelTransactionHandler` to the server stack (around line 204).

- [ ] **Step 6: Export the new handler**

Add `cancelTransactionHandler` to the module export list (around line 52).

- [ ] **Step 7: Build + check + existing tests**

```
just check && just build && just test
```

- [ ] **Step 8: Commit**

```
git add src/Web/ErrorMapping.hs src/Web/API/TransactionAPI.hs
git commit -m "feat(web): DELETE /api/transactions/:id + includeCancelled query param"
```

---

## Task 13: Register the saga in `Main.hs`

**Spec:** §4 last paragraph.

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Import the new process manager**

```haskell
import Application.ProcessManagers.TransactionCancellationManager
  ( transactionCancellationProcessManager,
  )
```

- [ ] **Step 2: Add it to the process-manager registration**

Find the call site that registers `transferAmendmentProcessManager` and add a symmetric call for `transactionCancellationProcessManager`.

- [ ] **Step 3: Build**

```
just build
```

- [ ] **Step 4: Smoke-run the server**

```
just db-up
just run &
sleep 5
# Confirm the server is bound and not crashing. Auth-protected endpoints
# need a JWT, so just verifying the process is alive on its port is enough.
lsof -iTCP -sTCP:LISTEN -P -n | grep backend
kill %1
just db-down
```
Expected: the backend process is listening on its configured port and exits cleanly on SIGTERM.

- [ ] **Step 5: Commit**

```
git add app/Main.hs
git commit -m "chore(main): register TransactionCancellationProcessManager"
```

---

## Task 14: Integration test

**Spec:** §Testing — "Integration" row.

**Files:**
- Create: `test/Application/Services/TransactionServiceCancellationIntegrationSpec.hs`

- [ ] **Step 1: Pattern after the amendment integration test**

Look for an existing integration test that exercises the full transfer→amendment→completed loop with the in-memory event store; mirror its setup. Required scenarios per spec:

1. **Happy path:** create accounts → initiate + complete transfer → cancel. Verify source & target balances return to pre-transfer; account streams contain `AccountDebited`, `AccountCredited`, `AccountDebitReversed`, `AccountCreditReversed` in order; TX stream ends with `TransactionCancellationCompleted`; projection status is `Cancelled`.
2. **Read model — default list excludes cancelled.** After cancellation, `listTransactions visible emptyTransactionQuery` returns no row for the cancelled tx; with `mkTransactionQuery _ _ _ True`, the cancelled tx appears.
3. **Direct lookup still works.** `getTransaction` returns `Just td { status = Cancelled }`.
4. **Amend-then-cancel reverses amended amounts.** Initiate → complete → amend (different amounts) → cancel. Final account balances match pre-transfer.
5. **Books-close rejection** when TX date is at/before cutoff: returns `Left CannotEditClosedPeriod`.
6. **Authorization rejection** for non-Editor caller: returns `Left Forbidden …`.
7. **Double-cancel** returns `Left TransactionAlreadyCancelled`.
8. **Cancel-during-amend** returns `Left CannotCancelDuringAmendment`.
9. **Amend-during-cancel** returns `Left CannotAmendDuringCancellation`.

- [ ] **Step 2: Run; verify all pass**

```
cabal test all --test-option='--match' --test-option='/TransactionServiceCancellationIntegration/'
```

- [ ] **Step 3: Commit**

```
git add test/Application/Services/TransactionServiceCancellationIntegrationSpec.hs
git commit -m "test(service): integration coverage for cancelTransaction"
```

---

## Task 15: HTTP API tests

**Spec:** §Testing — "HTTP" row.

**Files:**
- Modify: `test/Web/API/TransactionAPISpec.hs`

- [ ] **Step 1: Add a `describe "DELETE /api/transactions/:id"` block**

Cases:

| Setup | Expected status |
| --- | --- |
| Happy path | 204 |
| No JWT | 401 |
| Caller lacks Editor+ | 403 |
| TX date ≤ books-close cutoff | 403 |
| Unknown transaction id | 404 |
| Already-cancelled | 409 |
| Amend-in-progress on the same tx | 409 |
| Malformed UUID in path | 422 |

- [ ] **Step 2: Add a `describe "GET /api/transactions"` block (or extend existing) for `includeCancelled`**

| Query | Expected |
| --- | --- |
| (no param) | cancelled tx absent |
| `?includeCancelled=true` | cancelled tx present with `status = "Cancelled"` |
| `?includeCancelled=false` | cancelled tx absent |

- [ ] **Step 3: Run; verify PASS**

```
cabal test all --test-option='--match' --test-option='/Web.API.TransactionAPI/'
```

- [ ] **Step 4: Commit**

```
git add test/Web/API/TransactionAPISpec.hs
git commit -m "test(api): HTTP coverage for DELETE + includeCancelled"
```

---

## Task 16: Regression — dictionary-deletion ignores cancelled transactions

**Spec:** §Testing — "Read-model (regression)" row.

**Files:**
- Modify: existing label/category deletion test file (likely `test/Application/Services/TransactionServiceLabelsSpec.hs` or similar — find via `grep -r "findReferencingTransactions" test/`).

- [ ] **Step 1: Add a regression case**

> Deleting a label/category that is referenced **only by a cancelled transaction** succeeds.

Setup: create a transaction that uses the label/category, complete it, cancel it, then attempt to delete the dictionary entry. Verify success.

- [ ] **Step 2: Run; verify PASS**

- [ ] **Step 3: Commit**

```
git add test/Application/Services/<file>.hs
git commit -m "test(read-model): dictionary deletion ignores cancelled transactions"
```

---

## Task 17: Bump backend version

**Spec:** none; project convention (see `docs/plans/2026-04-09-backend-versioning.md` and `src/Infrastructure/Version.hs`). The version is rendered at startup and on `GET /api/info`; user-visible feature additions warrant a MINOR bump per semver.

Current `version: 0.2.7` in `package.yaml`. Cancellation is a user-visible additive feature with no breaking API changes → bump to **0.3.0**.

**Files:**
- Modify: `package.yaml`

- [ ] **Step 1: Bump the version**

In `package.yaml` line 2:

```yaml
version: 0.3.0
```

- [ ] **Step 2: Verify the regenerated cabal picks it up**

```
just build
```
Expected: hpack regenerates `backend.cabal` with `version: 0.3.0`. The smoke test in Task 18 will confirm the new version surfaces via `GET /api/info`.

- [ ] **Step 3: Commit**

```
git add package.yaml backend.cabal
git commit -m "chore(version): bump backend to 0.3.0 (transaction cancellation)"
```

---

## Task 18: Final verification

- [ ] **Step 1: Full build + check**

```
just check && just build
```
Expected: clean.

- [ ] **Step 2: Full test suite**

```
just test
```
Expected: all green.

- [ ] **Step 3: Smoke test against a live server**

```
just db-up
just run &
sleep 5
curl http://localhost:<port>/api/info   # expect version "v0.3.0 (<sha>)"
# Optional: with a JWT in hand,
#   1. POST /api/transactions/transfer       → returns {id}
#   2. DELETE /api/transactions/{id}         → 204
#   3. GET /api/transactions                 → cancelled tx absent
#   4. GET /api/transactions?includeCancelled=true → cancelled tx present
#   5. GET /api/accounts/{src} & {tgt}       → balances back at pre-transfer values
# The integration suite (Task 14) already covers this end-to-end; this is a
# sanity check that the wired-up server actually accepts the new route and
# reports the new version.
kill %1
just db-down
```

- [ ] **Step 4: Update spec status**

In `docs/specs/2026-05-29-delete-transaction-design.md`, change frontmatter:

```yaml
status: completed
```

- [ ] **Step 5: Final commit (or PR)**

```
git add docs/specs/2026-05-29-delete-transaction-design.md
git commit -m "docs(transaction): mark delete-transaction spec as completed"
```

---

## Out-of-scope (deferred)

- Account-deletion mid-saga handling (spec Open Questions §1) — not addressed; accounts aren't deletable today.
- `POST /api/transactions/:id/cancellation` alternative endpoint shape — `DELETE` chosen, see spec Open Questions §2.
- LiquidHaskell refinements on the new types (`TransactionCancellationData` etc.) — follow the precedent set by `TransferAmendmentData`, which has no LH refinements; the amendment manager spec considered it out of scope.
