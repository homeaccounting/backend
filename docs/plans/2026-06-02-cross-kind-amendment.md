---
status: completed
date: 2026-06-02
spec: ../specs/2026-06-01-cross-kind-amendment-design.md
issue: homeaccounting/backend#94
---

# Cross-Kind Transaction Amendment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lift the kind-preservation invariant on `AmendTransaction` so a Completed transaction can be amended across the `Income ↔ Expense ↔ Transfer` boundary in a single saga, while preserving `externalTransactionId`, labels, business date, and the amendment history. The Monobank own-card import row (today Income) can then be reclassified into a Transfer without losing dedup.

**Architecture:** Kind remains structurally derived from the two endpoints' `AccountType` values — a new `deriveTransactionKind :: AccountType -> AccountType -> TransactionKind` helper centralises that derivation. The user-facing `AmendTransaction` command grows one optional field `newAllocations :: Maybe Allocations` *and* one service-internal field `newTransactionType :: TransactionType` (computed by the service layer; the web handler initialises it to a placeholder which the service immediately overwrites before dispatch — see "Command-shape rationale" below). The service layer synthesises a full `newTransactionType` (kind ⊕ allocations) from `(derivedKind, cmd.newAllocations, existingTransactionType)` and threads it through the saga (`AmendTransaction` → `TransactionAmendmentInitiated` → `CompleteTransactionAmendment` → `TransactionAmendmentCompleted`). The two amendment events shift from carrying lean posting-facts (with the post-hoc `newAllocations :: Maybe Allocations` snapshot on `Completed`) to carrying the full `newTransactionType` verbatim — projections become a single field write. The saga state (`TransactionAmendmentData`) gains the same field. The leg-diff algorithm (`diffAmendmentLegs`) is account-type-agnostic by design and needs no structural change.

**Command-shape rationale:** The user-facing `AmendTransaction` value type gains *both* `newAllocations :: Maybe Allocations` (what the caller supplied) and `newTransactionType :: TransactionType` (what the service computed). The latter is documented in Haddock as "service-internal: the user-facing web handler initialises this to `Transfer`; the service layer always overwrites it via `synthesiseAmendmentTransactionType` before calling `runTransactionCmd`." The handler trusts this field as the canonical post-amendment shape. The alternative — splitting into a public command + a saga-internal command — would require a new sum-type variant and matching event-store routing for one field; the placeholder is the smaller change. Commands are not persisted by Eventium (only events are), so the placeholder never reaches durable storage; it lives only in memory between web handler and service.

**Tech Stack:** GHC 9.10.3, Cabal 3.10+, Hpack, RIO prelude, Servant, Eventium, PostgreSQL 15. All commands via `just` (run inside `nix develop`).

**Reference spec:** [`docs/specs/2026-06-01-cross-kind-amendment-design.md`](../specs/2026-06-01-cross-kind-amendment-design.md). Every task references the spec section that defines the contract — read before coding.

**Reference implementations:**

- The transfer-amendment-saga plan ([`docs/plans/2026-05-23-transfer-amendment-saga.md`](2026-05-23-transfer-amendment-saga.md), merged in PR #83) — how `TransactionAmendment{Initiated,Completed,Failed}` events carry payloads through the saga; how `amendTransaction` orchestrates dispatch + outcome read.
- The transaction-allocations plan ([`docs/plans/2026-05-30-transaction-allocations.md`](2026-05-30-transaction-allocations.md), merged in PR #90) — how `Allocations` are validated by smart constructors, how `replaceAllocations` / `rescaleAllocations` are wired into projections, and how the `TransactionAmendmentCompleted` event today carries a handler-computed `newAllocations :: Maybe Allocations` snapshot (which this plan replaces).
- The transaction naming refactor ([`docs/plans/2026-06-02-transaction-naming-consistency.md`](2026-06-02-transaction-naming-consistency.md), merged in PR #95) — establishes the current naming (`TransactionType`, `TransactionKind`, `AmendTransaction`, `TransactionAmendment*`, `TransactionAmendmentManager`). This plan adds no further renames.

---

## File Inventory

**New files:**

- `test/Domain/Core/DeriveTransactionKindSpec.hs` — unit tests for the new helper.
- `test/Application/Services/CrossKindAmendmentSpec.hs` — service-layer cross-kind acceptance / rejection tests.
- `test/Integration/CrossKindAmendmentIntegrationSpec.hs` — end-to-end Monobank-style flow.

**Modified files (Domain):**

- `src/Domain/Core/Types.hs` — add `deriveTransactionKind`, export it. Keep `replaceAllocations` and `rescaleAllocations` (still used elsewhere).
- `src/Domain/Core/Errors.hs` — add `AllocationsNotAllowedForTransferKind`, `AllocationsRequiredForCategorisedKind`, `CannotAmendToAdjustmentKind`. Delete `CannotAmendAcrossAccountType` and its `renderDomainError` arm.
- `src/Domain/Transaction/Commands.hs` — `AmendTransaction` gains `newAllocations :: Maybe Allocations` (user-facing) and `newTransactionType :: TransactionType` (service-internal). `CompleteTransactionAmendment` gains `newTransactionType :: TransactionType`. Update Haddocks.
- `src/Domain/Transaction/Events.hs` — `TransactionAmendmentInitiated` and `TransactionAmendmentCompleted` each gain `newTransactionType :: TransactionType`. `TransactionAmendmentCompleted` loses `newAllocations :: Maybe Allocations`. Update Haddocks. The hand-written `FromJSON` instance for `TransactionPostingInitiated` is unaffected.
- `src/Domain/Transaction/CommandHandler.hs` — add aggregate-local error `CannotAmendToAdjustmentKind`. `AmendTransaction` arm: validate the supplied `newTransactionType` against the new posting amounts (`Adjustment` rejection; for `Income` / `Expense`, reuse `checkAllocationsAgainst`); emit `newTransactionType` verbatim. `CompleteTransactionAmendment` arm: drop the handler-side rescale; emit `newTransactionType` verbatim onto the event. Trim unused imports (`rescaleAllocations`, `sumAllocationsUnchecked`, `allocationsOf`, `kindOf`, `TransactionKind (..)`).
- `src/Domain/Transaction/Projection.hs` — `TransactionAmendmentCompleted` arm rewrites `transactionType` from `evt.newTransactionType` instead of `replaceAllocations evt.newAllocations …`. The `TransactionAllocationsChangedTransactionEvent` arm continues to use `replaceAllocations` — keep the import.

**Modified files (Application):**

- `src/Application/Services/TransactionService.hs` — delete `validateAccountTypePreserved`; rewrite `amendTransaction`:
  - `ensureEditorOnNewAccounts` returns the fetched `AccountData` pair (refactor signature; one caller site).
  - Derive new kind via `deriveTransactionKind`.
  - Synthesise `newTransactionType` per the spec §"Service layer" truth table via a new helper `synthesiseAmendmentTransactionType`; validate allocation categories via `validateAllocationsAgainstDictionary`; rescale for within-kind amount-only edits via `rescaleAllocations`.
  - Extend `isIdentityAmend` to compare `newTransactionType` (deep, including allocations).
  - Overwrite `cmd.newTransactionType` with the synthesised value before dispatch.
  - Add `translateTransactionError` arm mapping `TxCh.CannotAmendToAdjustmentKind` → `DomainError.CannotAmendToAdjustmentKind`. Remove translation for `CannotAmendAcrossAccountType` if present.
- `src/Application/ProcessManagers/TransactionAmendmentManager.hs` — `TransactionAmendmentData` gains `newTransactionType :: TransactionType`. Reaction to `TransactionAmendmentInitiatedEvent` reads `evt.newTransactionType` into the snapshot. `completeEffect` echoes `newTransactionType` onto the `CompleteTransactionAmendment` command. No change to `diffAmendmentLegs`.
- `src/Application/ReadModels/Transaction.hs` — `TransactionAmendmentCompletedEvent` arm replaces `transactionType` from `evt.newTransactionType` (today: `replaceAllocations evt.newAllocations transaction.transactionType`). Keep the `replaceAllocations` import — `TransactionAllocationsChangedEvent` still uses it.

**Modified files (Web):**

- `src/Web/Types.hs` — `AmendTransactionRequest` gains `newAllocations :: Maybe Allocations` (reuse existing `Allocations` JSON instances). Update Haddocks: `transactionType` is now amendable across `Income ↔ Expense ↔ Transfer`; cross-boundary recategorisation no longer requires delete-and-repost.
- `src/Web/API/TransactionAPI.hs` — `amendTransactionHandler` plumbs `req.newAllocations` into the `AmendTransaction` value; initialises `newTransactionType = Transfer` (placeholder — the service overwrites). No extra DTO-layer validation needed (`Allocation`'s smart constructor and the `NonEmpty` requirement enforce positivity and non-emptiness).
- `src/Web/ErrorMapping.hs` — add mappings for `AllocationsRequiredForCategorisedKind`, `AllocationsNotAllowedForTransferKind`, `CannotAmendToAdjustmentKind` (all → `400 ValidationErr`). Remove `CannotAmendAcrossAccountType` mapping.

**Modified files (Tests — sweep):**

- `test/Application/Services/TransactionAmendmentSpec.hs` — delete the `CannotAmendAcrossAccountType` test at line ≈242 (behaviour is gone). Add a cross-kind happy path or rely on `CrossKindAmendmentSpec.hs` for coverage.
- `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` — add cases: Adjustment rejection (`CannotAmendToAdjustmentKind`), allocation sum/currency rejections via the existing `AllocationsDoNotSumToTotal` / `AllocationCurrencyMismatch` paths under `AmendTransaction`.
- `test/Domain/Transaction/AmendmentPropertySpec.hs` — property: handler-accepted `AmendTransaction` round-trips `newTransactionType` through the projection unchanged (deep equality).
- `test/Application/ProcessManagers/TransactionAmendmentManagerSpec.hs` — extend a saga test to exercise an `Income → Transfer` leg-diff (source endpoint swap `External → Regular`); confirm leg set matches expectation.
- `test/Application/ProcessManagers/TransactionAmendmentManagerPropertySpec.hs` — property: `diffAmendmentLegs` is account-type-agnostic (same leg shapes for matched `External` vs `Regular` endpoints).
- `test/Integration/TransactionAmendmentIntegrationSpec.hs` — keep within-kind cases working; add a cross-kind smoke covering one `Income → Transfer` end-to-end (the deeper E2E lives in the new integration spec).

**Modified files (Build):**

- `package.yaml` — bump `version: 0.4.0` → `0.5.0` (breaking domain change — event payload shape).
- Regenerate `backend.cabal` via `just build` (which runs `hpack`).

---

## Task Ordering

Tightly coupled changes land in a single atomic commit (Task 3); decoupled foundations and integration come before and after. Each task is one PR-sized commit unless explicitly split.

```
1. deriveTransactionKind helper + unit test
2. Error variants (DomainError + TransactionError + ErrorMapping)
3. Atomic shape + handler + saga + service synthesis  ← bulk of the work
4. Web DTO field + handler
5. Service-layer property + integration tests
6. Domain property tests
7. Ancillary caller sweep (bank-import / telegram / history)
8. Verification + version bump + PR
```

Standing rules (apply to every commit):

- Run `just check` (ormolu + hlint) before committing.
- Run `just build` after every code change.
- Run `just test` after every test addition / code change. For inner-loop iteration, `cabal test all --test-option='--match' --test-option="/Pattern/"` is faster.
- Commits use Conventional Commits (`feat`, `fix`, `refactor`, `test`, `docs`, `chore`).
- No `error`, `undefined`, no partial functions. No `--no-verify`, `--amend` of published commits, or destructive git.

---

## Task 1: `deriveTransactionKind` helper + unit test

**Spec:** §"Kind derivation".

**Files:**

- Modify: `src/Domain/Core/Types.hs` (add helper + export, near `kindOf` at line ≈1024).
- Create: `test/Domain/Core/DeriveTransactionKindSpec.hs`.

The helper is total over `(AccountType, AccountType)`. The `External ↔ External` case is structurally unreachable (one `External` account per user) but kept exhaustive to satisfy the no-partial-functions rule.

- [ ] **Step 1: Write the failing unit test**

Inspect `AccountSubtype` constructors first:

```bash
grep -nE "^\s*\|" src/Domain/Core/Types.hs | grep -iE "Subtype|Cash" | head -10
```

Then create `test/Domain/Core/DeriveTransactionKindSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Core.DeriveTransactionKindSpec (spec) where

import Domain.Core.Types
  ( AccountSubtype (..),
    AccountType (..),
    TransactionKind (..),
    deriveTransactionKind,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = describe "deriveTransactionKind" $ do
  let cash = Regular Cash  -- adjust to whichever Regular subtype constructor exists
  it "Regular → External = ExpenseKind" $
    deriveTransactionKind cash External `shouldBe` ExpenseKind
  it "External → Regular = IncomeKind" $
    deriveTransactionKind External cash `shouldBe` IncomeKind
  it "Regular → Regular = TransferKind" $
    deriveTransactionKind cash cash `shouldBe` TransferKind
  it "External → External = TransferKind (dead branch, total)" $
    deriveTransactionKind External External `shouldBe` TransferKind
```

> If `Regular Cash` doesn't compile, substitute whichever exported subtype constructor / `defaultCash` value the project provides. The four cases must be exhaustive over `(AccountType, AccountType)`.

- [ ] **Step 2: Run test to verify it fails**

```bash
cabal test all --test-option='--match' --test-option="/deriveTransactionKind/"
```

Expected: FAIL with `Variable not in scope: deriveTransactionKind`.

- [ ] **Step 3: Add the helper**

In `src/Domain/Core/Types.hs`, immediately after `kindOf` (line ≈1024–1028), add:

```haskell
-- | Derive a 'TransactionKind' from a (source, target) 'AccountType' pair.
--
-- Total. The 'External ↔ External' case is structurally unreachable for
-- valid inputs (a user owns exactly one 'External' account, and the
-- service layer rejects @source == target@ before calling this helper),
-- but the case is kept exhaustive to keep the function total per project
-- rules; the chosen result ('TransferKind') is irrelevant because the
-- branch is dead.
--
-- 'AdjustmentKind' is never derivable here because the service layer
-- rejects @source == target@ before reaching this helper (an Adjustment
-- is a single-account write, not a two-leg amendment).
deriveTransactionKind :: AccountType -> AccountType -> TransactionKind
deriveTransactionKind (Regular _) External    = ExpenseKind
deriveTransactionKind External    (Regular _) = IncomeKind
deriveTransactionKind (Regular _) (Regular _) = TransferKind
deriveTransactionKind External    External    = TransferKind
```

Add `deriveTransactionKind` to the module export list (find the section that exports `kindOf`).

- [ ] **Step 4: Run test to verify it passes**

```bash
cabal test all --test-option='--match' --test-option="/deriveTransactionKind/"
```

Expected: PASS (4 examples).

- [ ] **Step 5: Format, lint, build**

```bash
just check
just build
```

Expected: clean.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Core/Types.hs test/Domain/Core/DeriveTransactionKindSpec.hs
git commit -m "$(cat <<'EOF'
feat(transaction): add deriveTransactionKind helper

Total mapping from (AccountType, AccountType) to TransactionKind, used
by the cross-kind amendment path to compute the new kind from the new
endpoints' account types. External ↔ External is a dead branch — kept
exhaustive for totality.
EOF
)"
```

---

## Task 2: Error variants

**Spec:** §"Errors".

**Files:**

- Modify: `src/Domain/Core/Errors.hs`.
- Modify: `src/Domain/Transaction/CommandHandler.hs` (`TransactionError` sum).
- Modify: `src/Application/Services/TransactionService.hs` (`translateTransactionError`).
- Modify: `src/Web/ErrorMapping.hs`.
- Modify: `test/Application/Services/TransactionAmendmentSpec.hs` (remove the dead assertion at line ≈242).

`CannotAmendAcrossAccountType` is removed because the underlying restriction (`validateAccountTypePreserved`) is removed in Task 3. Three new constructors are added: `AllocationsRequiredForCategorisedKind`, `AllocationsNotAllowedForTransferKind`, `CannotAmendToAdjustmentKind`. The Adjustment-rejection error appears in both the aggregate-local `TransactionError` (since the pure handler enforces it) and `DomainError` (since the service layer surfaces it to HTTP).

- [ ] **Step 1: Add the failing test for the new HTTP mapping**

Add to `test/Web/ErrorMappingSpec.hs` (if it exists — otherwise to the nearest analogous spec; if no test exists, skip and rely on the build):

```haskell
describe "cross-kind amendment errors" $ do
  it "maps AllocationsRequiredForCategorisedKind to 400" $
    statusCode (mapDomainError AllocationsRequiredForCategorisedKind) `shouldBe` 400
  it "maps AllocationsNotAllowedForTransferKind to 400" $
    statusCode (mapDomainError AllocationsNotAllowedForTransferKind) `shouldBe` 400
  it "maps CannotAmendToAdjustmentKind to 400" $
    statusCode (mapDomainError CannotAmendToAdjustmentKind) `shouldBe` 400
```

> If no `ErrorMappingSpec` exists, omit this step — the new arms will be exercised end-to-end in Task 5's service tests and Task 6's integration tests.

- [ ] **Step 2: Extend `DomainError`**

In `src/Domain/Core/Errors.hs`, add three new constructors after `CannotAmendAcrossAccountType` (line ≈133) and delete `CannotAmendAcrossAccountType`:

```haskell
  | -- | 'AmendTransaction' supplied 'newAllocations = Nothing' for a kind
    --   change into Income or Expense. Caller must supply the new
    --   allocations covering the new categorised total.
    AllocationsRequiredForCategorisedKind
  | -- | 'AmendTransaction' supplied allocations but the derived new kind
    --   is Transfer. Transfer carries no allocations.
    AllocationsNotAllowedForTransferKind
  | -- | The synthesised 'newTransactionType' is 'Adjustment'. Reachable
    --   only via a service-layer programming bug (the service rejects
    --   @source == target@ before deriving the kind), so this is a
    --   defensive guard rather than a user-facing validation error.
    CannotAmendToAdjustmentKind
```

Add corresponding `renderDomainError` arms (line ≈252):

```haskell
  AllocationsRequiredForCategorisedKind ->
    "Allocations are required when amending into an Income or Expense kind"
  AllocationsNotAllowedForTransferKind ->
    "Allocations cannot be supplied when amending into a Transfer kind"
  CannotAmendToAdjustmentKind ->
    "Cross-kind amendment into Adjustment is not supported; use AdjustAccountBalance"
```

Delete `CannotAmendAcrossAccountType` (constructor at line ≈133 and `renderDomainError` arm at line ≈252).

- [ ] **Step 3: Extend `TransactionError`**

In `src/Domain/Transaction/CommandHandler.hs` (around line 79–122), add:

```haskell
  | -- | 'AmendTransaction' supplied a 'newTransactionType' whose kind is
    --   'Adjustment'. Cross-kind amendment into Adjustment is unsupported.
    CannotAmendToAdjustmentKind
```

- [ ] **Step 4: Add `translateTransactionError` arm**

In `src/Application/Services/TransactionService.hs` (line ≈920+ where the other `TxCh` translations live), add:

```haskell
translateTransactionError (CommandRejected TxCh.CannotAmendToAdjustmentKind) =
  CannotAmendToAdjustmentKind
```

> Both names are unqualified `DomainError` constructors at this site; the existing pattern uses `TxCh.` for aggregate-local errors and unqualified for `DomainError` (see line 935 for the precedent: `TxCh.AmendTransferToSameAccountPair → CannotAmendToSameAccountPair`).

- [ ] **Step 5: Update `Web/ErrorMapping.hs`**

In `src/Web/ErrorMapping.hs`, copy the structure of `mapDomainError AllocationsDoNotSumToTotal` (line ≈233) for the three new arms:

```haskell
mapDomainError AllocationsRequiredForCategorisedKind =
  err400
    { errBody =
        encode
          ApiError
            { message = "Allocations are required when amending into an Income or Expense kind",
              code = "AMENDMENT_ALLOCATIONS_REQUIRED"
            }
    }
mapDomainError AllocationsNotAllowedForTransferKind =
  err400
    { errBody =
        encode
          ApiError
            { message = "Allocations cannot be supplied when amending into a Transfer kind",
              code = "AMENDMENT_ALLOCATIONS_NOT_ALLOWED"
            }
    }
mapDomainError CannotAmendToAdjustmentKind =
  err400
    { errBody =
        encode
          ApiError
            { message = "Cross-kind amendment into Adjustment is not supported",
              code = "AMENDMENT_KIND_ADJUSTMENT"
            }
    }
```

Delete the `mapDomainError CannotAmendAcrossAccountType` arm at line ≈343.

> Verify the `ApiError` field names (`message`, `code`) and the `encode` import match the surrounding arms in the same file — copy verbatim from `AllocationsDoNotSumToTotal` to avoid drift.

- [ ] **Step 6: Delete the dead test assertion**

`test/Application/Services/TransactionAmendmentSpec.hs` around line 242 asserts:

```haskell
result `shouldBe` Left CannotAmendAcrossAccountType
```

Delete the entire `it` block that contains it. The cross-kind path is now the happy path; positive coverage lives in `CrossKindAmendmentSpec.hs` (created in Task 5).

- [ ] **Step 7: Build, test**

```bash
just check
just build
just test
```

Expected: green. The compiler will flag any other site that pattern-matches `CannotAmendAcrossAccountType` — there should be none after Step 6 (verify with `grep -rn 'CannotAmendAcrossAccountType' src/ test/`).

- [ ] **Step 8: Commit**

```bash
git add src/Domain/Core/Errors.hs src/Domain/Transaction/CommandHandler.hs \
        src/Application/Services/TransactionService.hs \
        src/Web/ErrorMapping.hs \
        test/Application/Services/TransactionAmendmentSpec.hs
git commit -m "$(cat <<'EOF'
feat(errors): cross-kind amendment error variants

Add AllocationsRequiredForCategorisedKind,
AllocationsNotAllowedForTransferKind, CannotAmendToAdjustmentKind to
DomainError. Add CannotAmendToAdjustmentKind to aggregate-local
TransactionError and translate it into DomainError. Delete
CannotAmendAcrossAccountType — the cross-AccountType restriction is
lifted by this feature (full removal of validateAccountTypePreserved
follows in the next commit).
EOF
)"
```

---

## Task 3: Atomic shape change — commands, events, handler, projection, read-model, saga, service

**Spec:** §"Command surface", §"Event shape", §"Pure handler", §"Projection", §"Saga", §"Service layer".

**Files:**

- Modify: `src/Domain/Transaction/Commands.hs`.
- Modify: `src/Domain/Transaction/Events.hs`.
- Modify: `src/Domain/Transaction/CommandHandler.hs`.
- Modify: `src/Domain/Transaction/Projection.hs`.
- Modify: `src/Application/ReadModels/Transaction.hs`.
- Modify: `src/Application/ProcessManagers/TransactionAmendmentManager.hs`.
- Modify: `src/Application/Services/TransactionService.hs`.
- Modify: tests as the compiler / test runner indicate.

**Why atomic:** these changes are tightly coupled. Splitting them creates intermediate commits where event payloads carry placeholder `Transfer` values regardless of caller input — every Income/Expense amendment would silently mis-project until the service-layer synthesis lands. To avoid committing knowingly-wrong code, this entire group lands in one commit. The task is structured as eleven sub-steps that flow top-down; each sub-step is small (≤ 5 minutes) and the test suite is run at the end.

The service synthesis is the keystone: without it, the placeholder leaks downstream. With it, every other change becomes a single-line field write.

### Step 1: `AmendTransaction` command record

In `src/Domain/Transaction/Commands.hs` (lines 246–290), replace the `AmendTransaction` declaration and its Haddock:

```haskell
-- | User-facing command to amend an existing completed transaction.
--
-- Triggers the amendment saga. The service layer computes the diff
-- against current canonical state and short-circuits if the payload
-- is identical (no events emitted, saga not started).
--
-- Cross-kind amendment is supported: the new kind (Income / Expense /
-- Transfer) is structurally derived from the (newSource, newTarget)
-- 'AccountType' pair at the service layer via 'deriveTransactionKind'.
-- 'Adjustment' is out of scope (single-account; use
-- 'AdjustAccountBalance' or delete-and-repost).
--
-- @newAllocations@ semantics:
--
--   * 'Nothing', kind unchanged (Income\/Expense): service rescales
--     existing allocations against the new categorised amount.
--   * 'Nothing', kind changing into Income\/Expense: rejected with
--     'AllocationsRequiredForCategorisedKind'.
--   * 'Nothing', kind = Transfer: pure 'Transfer'.
--   * 'Just allocs', kind = Income\/Expense: 'Income allocs' or
--     'Expense allocs'. Each 'categoryId' is validated against the
--     matching dictionary.
--   * 'Just _', kind = Transfer: rejected with
--     'AllocationsNotAllowedForTransferKind'.
--
-- @newTransactionType@ is the **service-internal** field carrying the
-- synthesised full 'TransactionType' (kind ⊕ allocations). The web
-- handler initialises it to 'Transfer' as a placeholder; the service
-- layer always overwrites it via 'synthesiseAmendmentTransactionType'
-- before calling 'runTransactionCmd'. The handler trusts this field
-- as the canonical post-amendment shape. Commands are not persisted
-- by Eventium (only events are), so the placeholder never reaches
-- durable storage.
--
-- Business Rules (handler-enforced):
--   - Transaction must be in the 'Completed' state.
--   - @newSourceAccountId@ /= @newTargetAccountId@.
--   - @newSourceAmount@ and @newTargetAmount@ are both non-zero.
--   - 'newTransactionType' must not be 'Adjustment'
--     ('CannotAmendToAdjustmentKind').
--   - For Income, sum of allocations equals @newTargetAmount@ and
--     all allocation currencies match @newTargetAmount@'s currency.
--   - For Expense, same against @newSourceAmount@.
data AmendTransaction = AmendTransaction
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    -- | Optional new allocation list. See module-level documentation
    -- on the truth table.
    newAllocations :: Maybe Allocations,
    -- | Service-internal: full new 'TransactionType' (kind ⊕
    -- allocations). Web handler initialises to 'Transfer'; the
    -- service layer always overwrites before dispatch.
    newTransactionType :: TransactionType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)
```

### Step 2: `CompleteTransactionAmendment` command record

In `src/Domain/Transaction/Commands.hs` (lines 292–316), add `newTransactionType :: TransactionType` after `newExchangeRate` and before `amendedBy`. Update the Haddock to one sentence: "carries the full new 'TransactionType' so the resulting `TransactionAmendmentCompleted` event is self-contained for projection / read-model rebuilds."

### Step 3: `TransactionAmendmentInitiated` event

In `src/Domain/Transaction/Events.hs` (lines 204–229), replace the Haddock and add `newTransactionType :: TransactionType` after `newExchangeRate`, before `amendedBy`:

```haskell
-- | Saga-trigger event: the user has submitted an 'AmendTransaction'
-- command and the domain handler accepted it. The process manager
-- reacts by computing the minimum leg diff between the snapshotted
-- old state and the new payload, then issuing the corresponding leg
-- commands.
--
-- Carries the synthesised 'newTransactionType' (kind ⊕ allocations)
-- so the saga can echo it onto 'CompleteTransactionAmendment' at
-- finalize without re-deriving from state.
data TransactionAmendmentInitiated = TransactionAmendmentInitiated
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransactionType :: TransactionType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)
```

### Step 4: `TransactionAmendmentCompleted` event

In `src/Domain/Transaction/Events.hs` (lines 232–273), replace the Haddock, remove `newAllocations :: Maybe Allocations`, and add `newTransactionType :: TransactionType`:

```haskell
-- | Saga-completion event: all leg events have landed. The TX
-- aggregate's canonical posting facts and 'transactionType' move to
-- the new values; the projection bumps 'amendmentCount'. Replayed
-- from saga state so the event is self-contained for read-model
-- rebuilds.
--
-- 'newTransactionType' is the full kind ⊕ allocations value the
-- service layer synthesised and threaded through the saga. The
-- projection replaces the existing 'transactionType' with this value
-- verbatim — no rescale, no kind-merge.
data TransactionAmendmentCompleted = TransactionAmendmentCompleted
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransactionType :: TransactionType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)
```

`TransactionAmendmentFailed` is unchanged.

### Step 5: `AmendTransaction` handler arm

In `src/Domain/Transaction/CommandHandler.hs` (lines 293–315), replace the `AmendTransaction` arm with:

```haskell
-- Handle AmendTransaction command
--
-- The service layer has already synthesised the full @newTransactionType@
-- (kind ⊕ allocations). The handler only validates structural
-- invariants and the allocation shape against the supplied amounts.
handleTransactionCommand transaction (AmendTransactionTransactionCommand AmendTransaction {..}) =
  case transaction ^. #status of
    Completed
      | transaction ^. #cancellationInProgress ->
          Left CannotAmendDuringCancellation
      | unAccountId newSourceAccountId == unAccountId newTargetAccountId ->
          Left AmendTransferToSameAccountPair
      | unMoney newSourceAmount == 0 || unMoney newTargetAmount == 0 ->
          Left AmendTransferToZeroAmount
      | otherwise -> do
          -- Validate the service-synthesised newTransactionType against
          -- the new posting amounts. checkAllocationsAgainst is the
          -- same helper used by InitiateTransaction (sum, currency,
          -- positivity). 'do' here is the Either monad: a Left short-
          -- circuits and is returned; Right () proceeds.
          case newTransactionType of
            Income allocs -> checkAllocationsAgainst newTargetAmount allocs
            Expense allocs -> checkAllocationsAgainst newSourceAmount allocs
            Transfer -> Right ()
            Adjustment -> Left CannotAmendToAdjustmentKind
          Right
            [ TransactionAmendmentInitiatedTransactionEvent
                TransactionAmendmentInitiated
                  { transactionId = transactionId,
                    newSourceAccountId = newSourceAccountId,
                    newTargetAccountId = newTargetAccountId,
                    newSourceAmount = newSourceAmount,
                    newTargetAmount = newTargetAmount,
                    newExchangeRate = newExchangeRate,
                    newTransactionType = newTransactionType,
                    amendedBy = amendedBy
                  }
            ]
    _ -> Left CannotEditUncompletedTransaction
```

> The `do` block runs in `Either TransactionError`. The `case … of` statement returns `Either TransactionError ()`; the trailing `Right [event]` is the success continuation. If the validation `case` returns `Left e`, the entire do-block short-circuits to `Left e`.

### Step 6: `CompleteTransactionAmendment` handler arm

In `src/Domain/Transaction/CommandHandler.hs` (lines 328–362), replace the arm with the lean version:

```haskell
-- Handle CompleteTransactionAmendment command
--
-- Saga-internal. The service layer has already synthesised
-- @newTransactionType@; the saga echoed it onto this command via
-- 'TransactionAmendmentData'. The handler emits the event verbatim.
handleTransactionCommand transaction (CompleteTransactionAmendmentTransactionCommand CompleteTransactionAmendment {..}) =
  if not (transaction ^. #amendmentInProgress)
    then Left NoAmendmentInProgress
    else
      Right
        [ TransactionAmendmentCompletedTransactionEvent
            TransactionAmendmentCompleted
              { transactionId = transactionId,
                newSourceAccountId = newSourceAccountId,
                newTargetAccountId = newTargetAccountId,
                newSourceAmount = newSourceAmount,
                newTargetAmount = newTargetAmount,
                newExchangeRate = newExchangeRate,
                newTransactionType = newTransactionType,
                amendedBy = amendedBy
              }
        ]
```

Remove imports made unused (`rescaleAllocations`, `sumAllocationsUnchecked`, `allocationsOf`, `kindOf`, `TransactionKind (..)`) from the import group at lines 44–62. The build will flag any that are still needed elsewhere in the file (`checkAllocationsAgainst` is defined locally and uses `validateAllocations` from `Domain.Core.Types` — keep that one).

### Step 7: Projection — `TransactionAmendmentCompleted` arm

In `src/Domain/Transaction/Projection.hs` (lines 352–384), replace the arm with a single field write:

```haskell
handleTransactionEvent transaction (TransactionAmendmentCompletedTransactionEvent evt) =
  transaction
    & #sourceAccountId .~ evt.newSourceAccountId
    & #targetAccountId .~ evt.newTargetAccountId
    & #sourceAmount .~ evt.newSourceAmount
    & #targetAmount .~ evt.newTargetAmount
    & #exchangeRate .~ evt.newExchangeRate
    & #transactionType .~ evt.newTransactionType
    & #amendmentCount %~ (+ 1)
    & #amendmentInProgress .~ False
```

Keep the `replaceAllocations` import on line 56 — `TransactionAllocationsChangedTransactionEvent` arm at line 333 still uses it.

### Step 8: Read model — `TransactionAmendmentCompletedEvent` arm

In `src/Application/ReadModels/Transaction.hs` (lines 368–397), replace the arm:

```haskell
TransactionAmendmentCompletedEvent evt ->
  case mkTransactionIdSafe streamUuid of
    Nothing -> transactions
    Just transactionId ->
      Map.adjust
        ( \transaction ->
            (transaction :: TransactionData)
              { sourceAccountId = evt.newSourceAccountId,
                targetAccountId = evt.newTargetAccountId,
                sourceAmount = evt.newSourceAmount,
                targetAmount = evt.newTargetAmount,
                exchangeRate = evt.newExchangeRate,
                transactionType = evt.newTransactionType,
                amendmentCount = transaction.amendmentCount + 1
              }
        )
        transactionId
        transactions
```

Keep the `replaceAllocations` import on line 73 — the `TransactionAllocationsChangedEvent` arm at line 338 still uses it.

### Step 9: Saga state and command flow

In `src/Application/ProcessManagers/TransactionAmendmentManager.hs`:

1. `TransactionAmendmentData` (line 135–149): add `newTransactionType :: TransactionType` after `newExchangeRate`, before `amendedBy`. Update the Haddock to mention it carries the synthesised kind ⊕ allocations.
2. `handleTransactionAmendmentEvent` reaction to `TransactionAmendmentInitiatedEvent` (line ≈260): the existing `TransactionAmendmentData` literal at line 268 gains `newTransactionType = evt.newTransactionType`.
3. `completeEffect` (line 369+): the `CompleteTransactionAmendment` literal gains `newTransactionType = amend.newTransactionType`.

`diffAmendmentLegs` is unchanged.

> **Replay note:** `TransactionAmendmentManager` is a pure projection rebuilt from the event stream at startup; there is no on-disk saga state. The new field has no migration story. The renamed event field (`newAllocations` → `newTransactionType`) means streams written by the previous code cannot be replayed verbatim — see Task 8 verification step on dev-DB rebuild.

### Step 10: Service layer — `synthesiseAmendmentTransactionType`, `ensureEditorOnNewAccounts` return shape, `amendTransaction` rewrite, `isIdentityAmend` extension, `validateAccountTypePreserved` deletion

In `src/Application/Services/TransactionService.hs`:

**10a.** Refactor `ensureEditorOnNewAccounts` (line 755–781) to return the resolved `AccountData` pair:

```haskell
ensureEditorOnNewAccounts ::
  UserId ->
  AccountId ->
  AccountId ->
  AppM (Either DomainError (AccountData, AccountData))
ensureEditorOnNewAccounts userId newSrc newTgt = runExceptT $ do
  accountRM <- lift (view accountReadModelL)
  src <-
    liftMaybeM
      (NotFound "Account" (tshow newSrc))
      (liftIO (AccountRM.getAccount accountRM newSrc))
  tgt <-
    liftMaybeM
      (NotFound "Account" (tshow newTgt))
      (liftIO (AccountRM.getAccount accountRM newTgt))
  let toAuthData acc =
        AccountAuthData
          { createdBy = acc.createdBy,
            accountType = acc.accountType,
            accessList = acc.accessList
          }
  guardE
    (canModifyAccount userId (toAuthData src))
    (AccountError "User does not have edit access to the new source account")
  guardE
    (canModifyAccount userId (toAuthData tgt))
    (AccountError "User does not have edit access to the new target account")
  pure (src, tgt)
```

**10b.** Delete `validateAccountTypePreserved` entirely (lines 791–817).

**10c.** Add the synthesis helper (place it near `isIdentityAmend`):

```haskell
-- | Synthesise the full new 'TransactionType' for an 'AmendTransaction'
-- from the derived kind, the existing transaction's type, and the
-- caller-supplied 'newAllocations'.
--
-- Per the spec §"Service layer" truth table:
--
--   * 'Just allocs' + Income / Expense kind: validate categories and
--     build 'Income allocs' / 'Expense allocs'.
--   * 'Just _' + Transfer kind: reject 'AllocationsNotAllowedForTransferKind'.
--   * 'Nothing' + Income / Expense kind, same kind as existing: rescale
--     existing allocations against the new categorised amount.
--   * 'Nothing' + Income / Expense kind, kind changed: reject
--     'AllocationsRequiredForCategorisedKind'.
--   * 'Nothing' + Transfer kind: 'Transfer'.
--   * Anything + AdjustmentKind: defensive reject
--     'CannotAmendToAdjustmentKind' (unreachable via deriveTransactionKind).
synthesiseAmendmentTransactionType ::
  UserId ->
  TransactionKind ->
  TransactionType ->
  AmendTransaction ->
  AppM (Either DomainError TransactionType)
synthesiseAmendmentTransactionType userId derivedKind existingTT cmd = runExceptT $ do
  case (cmd.newAllocations, derivedKind) of
    (Just allocs, IncomeKind) -> do
      ExceptT (validateAllocationsAgainstDictionary userId IncomeKind allocs)
      pure (Income allocs)
    (Just allocs, ExpenseKind) -> do
      ExceptT (validateAllocationsAgainstDictionary userId ExpenseKind allocs)
      pure (Expense allocs)
    (Just _, TransferKind) -> throwE AllocationsNotAllowedForTransferKind
    (Just _, AdjustmentKind) -> throwE CannotAmendToAdjustmentKind
    (Nothing, IncomeKind)
      | kindOf existingTT == IncomeKind,
        Just oldAllocs <- allocationsOf existingTT ->
          let oldTotal = sumAllocationsUnchecked oldAllocs
              rescaled =
                if oldTotal /= cmd.newTargetAmount
                  then rescaleAllocations oldTotal cmd.newTargetAmount oldAllocs
                  else oldAllocs
           in pure (Income rescaled)
      | otherwise -> throwE AllocationsRequiredForCategorisedKind
    (Nothing, ExpenseKind)
      | kindOf existingTT == ExpenseKind,
        Just oldAllocs <- allocationsOf existingTT ->
          let oldTotal = sumAllocationsUnchecked oldAllocs
              rescaled =
                if oldTotal /= cmd.newSourceAmount
                  then rescaleAllocations oldTotal cmd.newSourceAmount oldAllocs
                  else oldAllocs
           in pure (Expense rescaled)
      | otherwise -> throwE AllocationsRequiredForCategorisedKind
    (Nothing, TransferKind) -> pure Transfer
    (Nothing, AdjustmentKind) -> throwE CannotAmendToAdjustmentKind
```

Add imports as needed from `Domain.Core.Types` (`deriveTransactionKind`, `sumAllocationsUnchecked`, `rescaleAllocations`, `allocationsOf`, `kindOf`, `TransactionKind (..)`, `TransactionType (..)` — most are already imported; check the existing import block at lines 71–97 and add what's missing). From `Domain.Core.Errors`, add `AllocationsRequiredForCategorisedKind`, `AllocationsNotAllowedForTransferKind`, `CannotAmendToAdjustmentKind` (these come for free via the unqualified `DomainError (..)` import already in place).

**10d.** Rewrite `amendTransaction` (lines 559–599):

```haskell
amendTransaction ::
  UserId ->
  TransactionId ->
  AmendTransaction ->
  AppM (Either DomainError TransactionData)
amendTransaction userId transactionId amendCmd = runExceptT $ do
  lift
    $ logInfo
    $ "Amending transaction "
    <> displayShow transactionId
    <> " for user "
    <> displayShow userId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  (newSrcAcc, newTgtAcc) <-
    ExceptT
      ( ensureEditorOnNewAccounts
          userId
          amendCmd.newSourceAccountId
          amendCmd.newTargetAccountId
      )
  let derivedKind =
        deriveTransactionKind newSrcAcc.accountType newTgtAcc.accountType
      existingTT = transaction.transactionType
  newTT <-
    ExceptT
      ( synthesiseAmendmentTransactionType
          userId
          derivedKind
          existingTT
          amendCmd
      )
  let dispatched = amendCmd {newTransactionType = newTT}
  if isIdentityAmend transaction dispatched
    then pure transaction
    else
      ExceptT
        ( dispatchAndAwaitAmendment
            transactionId
            (AmendTransactionTransactionCommand dispatched)
        )
```

**10e.** Extend `isIdentityAmend` (line 741) to compare `newTransactionType`:

```haskell
-- | True when the amendment payload exactly matches the current
-- canonical state. Compared fields: accounts, amounts, exchange rate,
-- and transactionType (deep equality, including allocations).
isIdentityAmend :: TransactionData -> AmendTransaction -> Bool
isIdentityAmend td cmd =
  td.sourceAccountId == cmd.newSourceAccountId
    && td.targetAccountId == cmd.newTargetAccountId
    && td.sourceAmount == cmd.newSourceAmount
    && td.targetAmount == cmd.newTargetAmount
    && td.exchangeRate == cmd.newExchangeRate
    && td.transactionType == cmd.newTransactionType
```

> **`Eq` on `TransactionType`:** the type derives `Eq` via `Allocation` (= `(CategoryId, Money)`). `CategoryId` is a `newtype` over `DictionaryEntryId` (a UUID) and is content-only; `Money` is content-only `(Decimal, Currency)`. Therefore `TransactionType`'s `Eq` is purely content-based — no synthetic ids, no timestamps. The deep-equality comparison is safe.

**10f.** Audit identity-amend tests before committing — see Step 11 below.

### Step 11: Fix call sites, fix tests, format, build, run all tests

The compiler will flag every record-literal construction of `AmendTransaction`, `CompleteTransactionAmendment`, `TransactionAmendmentInitiated`, `TransactionAmendmentCompleted`, and `TransactionAmendmentData`. Fix each by adding `newTransactionType = …` (use the appropriate kind for tests that exercise a specific scenario; use `Transfer` as a neutral default for tests that don't care).

Construction sites to update (use `grep -rn` to enumerate; expected list):

- `src/Web/API/TransactionAPI.hs:362` — the `AmendTransaction` literal in `amendTransactionHandler`. Add `newAllocations = Nothing, newTransactionType = Transfer`. The service overwrites both as appropriate (`newTransactionType` after synthesis; `newAllocations` stays as the user passed it). Import `TransactionType (..)`. Web DTO field is wired in Task 4; for now, this commit's web handler still uses `Nothing` for allocations.
- `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` — every `AmendTransaction` and `CompleteTransactionAmendment` literal.
- `test/Domain/Transaction/AmendmentPropertySpec.hs` — same.
- `test/Application/Services/TransactionAmendmentSpec.hs` — same.
- `test/Application/ProcessManagers/TransactionAmendmentManagerSpec.hs` — `TransactionAmendmentInitiated` and `TransactionAmendmentData` literals.
- `test/Application/ProcessManagers/TransactionAmendmentManagerPropertySpec.hs` — same.
- `test/Integration/TransactionAmendmentIntegrationSpec.hs` — likely uses higher-level `amendTransaction` service call rather than constructing the command directly; verify and fix as needed.
- `src/Application/Services/TransactionHistoryService.hs` — if it pattern-matches `TransactionAmendmentCompletedEvent` and reads `evt.newAllocations`, the field is gone; switch to reading `evt.newTransactionType` (and any subsequent rendering of allocations passes through `allocationsOf evt.newTransactionType`).

**Identity-amend test audit** (Step 10f follow-through):

Search for existing identity-amend tests that exercise the `isIdentityAmend = True` short-circuit:

```bash
grep -rn 'isIdentityAmend\|identity-?amend\|"no-op"' test/Application/Services/TransactionAmendmentSpec.hs test/Integration/TransactionAmendmentIntegrationSpec.hs
```

For each hit, verify the test fixture re-uses the *exact same* `TransactionType` value (same allocations, same currency, same amounts) on the amend command. If the test today constructs a fresh `Income allocs` with re-built `Allocation` values, those values are content-equal to the original (no synthetic ids), so the new comparison passes. If any test fails after the change, the failure is correct and the fixture needs updating to thread the existing `TransactionType` through.

**Build and test loop:**

```bash
just check
just build
just test
```

Iterate on compiler errors until clean. Iterate on test failures: for each failure, decide whether the assertion is wrong (most existing tests assert posting facts only — those still pass) or the fixture needs the new field threaded through. Tests that previously verified handler-side rescaling of allocations (under `TransactionAmendmentCompleted`) now need to compare `evt.newTransactionType` instead of `evt.newAllocations` — adjust the assertion accordingly.

### Step 12: Commit (single, large atomic commit)

```bash
git add src/Domain/Transaction/Commands.hs \
        src/Domain/Transaction/Events.hs \
        src/Domain/Transaction/CommandHandler.hs \
        src/Domain/Transaction/Projection.hs \
        src/Application/ReadModels/Transaction.hs \
        src/Application/ProcessManagers/TransactionAmendmentManager.hs \
        src/Application/Services/TransactionService.hs \
        src/Application/Services/TransactionHistoryService.hs \
        src/Web/API/TransactionAPI.hs \
        test/
git commit -m "$(cat <<'EOF'
feat(transaction): cross-kind amendment shape change + service synthesis

Lifts the kind-preservation invariant on AmendTransaction.

Domain:
- AmendTransaction gains optional user-facing 'newAllocations' and
  service-internal 'newTransactionType'.
- CompleteTransactionAmendment gains 'newTransactionType'.
- TransactionAmendmentInitiated gains 'newTransactionType'.
- TransactionAmendmentCompleted replaces 'newAllocations :: Maybe
  Allocations' with 'newTransactionType :: TransactionType'.
- Handler validates 'newTransactionType' against new posting amounts;
  rejects 'Adjustment' with CannotAmendToAdjustmentKind. Emits
  'newTransactionType' verbatim. CompleteTransactionAmendment arm
  drops its rescale; the service has already done it.
- Projection and read-model write 'transactionType' verbatim from
  the event.

Saga:
- TransactionAmendmentData snapshot gains 'newTransactionType' (read
  from the Initiated event); echoed onto the saga's completion
  command. diffAmendmentLegs unchanged (account-type-agnostic).

Service:
- Delete validateAccountTypePreserved.
- ensureEditorOnNewAccounts returns the resolved AccountData pair.
- New helper synthesiseAmendmentTransactionType implements the
  spec's truth table.
- Derive the new kind via deriveTransactionKind; synthesise full
  newTransactionType; overwrite cmd.newTransactionType before
  dispatch.
- isIdentityAmend now compares transactionType deeply.

Breaking event shape change (TransactionAmendmentCompleted payload
field renamed); no upcaster per project policy. Closes the bulk of #94.
EOF
)"
```

---

## Task 4: Web DTO field

**Spec:** §"Web API".

**Files:**

- Modify: `src/Web/Types.hs`.
- Modify: `src/Web/API/TransactionAPI.hs`.
- Test: `test/Web/API/TransactionAPISpec.hs` (or the nearest amend HTTP test).

- [ ] **Step 1: Write the failing HTTP test**

Add to `test/Web/API/TransactionAPISpec.hs` (locate the existing `amendTransactionHandler` HTTP test for the precedent):

```haskell
it "PUT /amendment with newAllocations and Income → Transfer kind change" $ do
  -- Seed an Income transaction.
  -- Build AmendTransactionRequest with
  --   sourceAccountId = <Regular A>, targetAccountId = <Regular B>,
  --   sourceAmount = 100, sourceCurrency = "UAH",
  --   targetAmount = 100, targetCurrency = "UAH",
  --   exchangeRate = Nothing,
  --   newAllocations = Nothing.
  -- Send PUT /api/transactions/<id>/amendment.
  -- Expect 200; response.transactionType == "Transfer".
  ...
```

> Use the existing amend HTTP test's fixture style verbatim; the new fixture differs only in `newAllocations` and the assertion on the response's `transactionType`.

- [ ] **Step 2: Extend `AmendTransactionRequest`**

In `src/Web/Types.hs` (lines 467–476), update Haddock and add the field:

```haskell
-- | Body for @PUT \/api\/transactions\/:id\/amendment@ — replaces the
-- posting facts on a Completed transaction. The client supplies the
-- complete desired end-state; the saga computes the diff.
--
-- Cross-kind amendment is supported: the new kind (Income / Expense /
-- Transfer) is structurally derived from the (source, target) account
-- types at the service layer. Adjustment is out of scope (single
-- account; use @AdjustAccountBalance@).
--
-- @newAllocations@ is required when the new kind is Income or Expense
-- AND that kind differs from the current kind. Omit ('null') for
-- within-kind amount edits and for Transfer-kind amendments.
data AmendTransactionRequest = AmendTransactionRequest
  { sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount :: Double,
    sourceCurrency :: Text,
    targetAmount :: Double,
    targetCurrency :: Text,
    exchangeRate :: Maybe Double,
    newAllocations :: Maybe Allocations
  }
  deriving (Show, Eq, Generic)
```

The existing `ToJSON` / `FromJSON` Generic-derived instances handle the new optional field automatically; absent JSON field → `Nothing` is the default `Generic` behaviour for `Maybe` fields.

- [ ] **Step 3: Plumb through the handler**

In `src/Web/API/TransactionAPI.hs` (lines 347–375), update the `cmd` literal to read `newAllocations = req.newAllocations`:

```haskell
let cmd =
      AmendTransaction
        { transactionId = transactionId,
          newSourceAccountId = newSource,
          newTargetAccountId = newTarget,
          newSourceAmount = srcMoney,
          newTargetAmount = tgtMoney,
          newExchangeRate = maybeRate,
          newAllocations = req.newAllocations,
          newTransactionType = Transfer, -- service overwrites
          amendedBy = user.userId
        }
```

Task 3 already added the `Transfer` placeholder and the `newAllocations = Nothing` default; this step only replaces `Nothing` with `req.newAllocations`. `TransactionType (..)` is already imported via Task 3.

- [ ] **Step 4: Run the new test**

```bash
cabal test all --test-option='--match' --test-option="/PUT \/amendment with newAllocations/"
```

Expected: PASS.

- [ ] **Step 5: Full sweep**

```bash
just check
just build
just test
```

Expected: green.

- [ ] **Step 6: Commit**

```bash
git add src/Web/Types.hs src/Web/API/TransactionAPI.hs test/Web/API/
git commit -m "$(cat <<'EOF'
feat(web): cross-kind amendment via AmendTransactionRequest

Add optional newAllocations field on AmendTransactionRequest; handler
plumbs it through to AmendTransaction. The service layer overwrites
the placeholder newTransactionType before dispatch.
EOF
)"
```

---

## Task 5: Service-layer cross-kind tests

**Spec:** §"Test plan" — Unit tests / Service tests.

**Files:**

- Create: `test/Application/Services/CrossKindAmendmentSpec.hs`.

Seven concrete cases (no `pendingWith` stubs). Use the same in-memory event-store + read-model scaffolding the existing `TransactionAmendmentSpec.hs` uses. Each case follows the Arrange-Act-Assert structure:

| # | Scenario                                                    | `newAllocations` | Expected outcome                                                       |
| - | ----------------------------------------------------------- | ---------------- | ---------------------------------------------------------------------- |
| 1 | Within-kind amount-only Income edit (Income → Income, Δ$)    | `Nothing`        | Accepts; final `transactionType == Income rescaled`                    |
| 2 | Cross-kind Income → Transfer (External src → Regular src)    | `Nothing`        | Accepts; final `transactionType == Transfer`; allocations dropped      |
| 3 | Cross-kind Transfer → Income (Regular src → External src) with new allocations summing to `newTargetAmount` | `Just allocs`    | Accepts; final `transactionType == Income allocs`                      |
| 4 | Cross-kind Transfer → Income with `newAllocations = Nothing` | `Nothing`        | Rejects with `AllocationsRequiredForCategorisedKind`                   |
| 5 | Transfer-derived kind with allocations supplied              | `Just allocs`    | Rejects with `AllocationsNotAllowedForTransferKind`                    |
| 6 | Income kind with allocation `categoryId` not in user's dict  | `Just bad`       | Rejects with `CategoryNotFound`                                        |
| 7 | Identity-amend (payload deep-equal to current state)         | matching shape   | No events emitted; returns existing `TransactionData` unchanged        |

- [ ] **Step 1: Scaffold the new spec file**

Open `test/Application/Services/TransactionAmendmentSpec.hs` and read its top section (imports, fixture builders) to understand the scaffolding. Create `test/Application/Services/CrossKindAmendmentSpec.hs` mirroring the imports and helpers.

- [ ] **Step 2: Implement Case 1 — within-kind rescale**

```haskell
it "(1) within-kind amount-only Income rescale" $ do
  (env, userId, accExt, accReg) <- buildAppEnv  -- existing helper
  -- Post an Income for 100 UAH with single allocation [catFood, 100 UAH].
  let initialAllocs = NE.singleton (Allocation catFood (mkMoneyUAH 100))
  txId <- runApp env $ postIncome userId accReg (mkMoneyUAH 100) initialAllocs
  -- Amend: bump amount to 150, no new allocations.
  let amendReq = baseAmend txId accExt accReg (mkMoneyUAH 150) (mkMoneyUAH 150) Nothing
  Right td <- runApp env $ TransactionService.amendTransaction userId txId amendReq
  td.transactionType `shouldSatisfy` isIncomeOf 150
```

Define `isIncomeOf` locally:

```haskell
isIncomeOf :: Rational -> TransactionType -> Bool
isIncomeOf n (Income allocs) =
  unMoney (sumAllocationsUnchecked allocs) == n
isIncomeOf _ _ = False
```

Iterate similarly for Cases 2–7. Each case is ≤ 20 lines.

- [ ] **Step 3: Build, run new tests, commit**

```bash
cabal test all --test-option='--match' --test-option="/amendTransaction — cross-kind synthesis/"
just check
just test
git add test/Application/Services/CrossKindAmendmentSpec.hs
git commit -m "test(transaction): service-layer cross-kind amendment cases

Seven concrete cases covering the spec truth table: within-kind
rescale, Income → Transfer drop, Transfer → Income with new
allocations, missing allocations on categorised kind change,
Transfer-kind allocation rejection, unknown categoryId, identity-
amend short-circuit."
```

---

## Task 6: Integration tests — Monobank dedup E2E

**Spec:** §"Test plan" — Integration tests.

**Files:**

- Create: `test/Integration/CrossKindAmendmentIntegrationSpec.hs`.
- Modify: `test/Integration/TransactionAmendmentIntegrationSpec.hs` (add one cross-kind smoke alongside existing within-kind tests).

- [ ] **Step 1: Read the existing integration setup**

`test/Integration/TransactionAmendmentIntegrationSpec.hs` is the canonical reference for the in-memory app scaffold (seeded user, accounts, projections). Copy its setup into the new file.

- [ ] **Step 2: Implement the four E2E cases**

```haskell
spec :: Spec
spec = around withSeededApp $ describe "Cross-kind amendment (E2E)" $ do
  it "Income → Transfer: balances and externalTransactionId preserved" $ \app -> do
    -- Seed: user + accExt + accA (Regular) + accB (Regular).
    -- Post Income(accExt → accA, 100 UAH) with externalTransactionId = Just "mono-123".
    -- Amend: AmendTransaction(accA, accB, 100, 100, Nothing, newAllocations=Nothing).
    -- Assert: accA balance = 0 (Income credited, Transfer debited).
    -- Assert: accB balance = 100.
    -- Assert: TransactionData.transactionType == Transfer.
    -- Assert: TransactionData.externalTransactionId == Just "mono-123".
    -- Assert: amendmentCount == 1.
    ...

  it "Monobank dedup: amended Income is still imported-as-seen by resync" $ \app -> do
    -- Seed an external bank source with one card-to-card row (mono-456).
    -- Trigger resync → an Income is created with externalTransactionId.
    -- Amend that transaction into a Transfer.
    -- Re-trigger resync.
    -- Assert: total transaction count unchanged (the second resync
    -- saw the externalTransactionId as already-imported via
    -- BankImportReadModel.isImported and skipped it).
    ...

  it "Income → Expense (endpoint swap) with supplied allocations" $ \app -> do
    -- Seed Income(accExt → accReg, 100 UAH, [catFood, 100]).
    -- Amend: (accReg, accExt, 100, 100, Nothing,
    --   newAllocations = Just [Allocation catSalary 100]).
    -- Assert: transactionType == Expense [Allocation catSalary 100].
    -- Assert: accReg balance reflects the Income credit + Expense debit
    --         (canceling to 0 if no other movement).
    ...

  it "amendmentCount == 1 after cross-kind amendment; original event present" $ \app -> do
    -- Post Income, amend cross-kind, query history.
    -- Assert: history shows the original TransactionPostingInitiated
    -- followed by TransactionAmendmentInitiated and
    -- TransactionAmendmentCompleted.
    -- Assert: TransactionData.amendmentCount == 1.
    ...
```

Use the existing test helpers (`runApp`, `postIncome`, `buildAmendRequest`, etc.) verbatim where they exist; introduce new helpers in `test/Testkit/` only if needed.

- [ ] **Step 3: Add one cross-kind smoke to `TransactionAmendmentIntegrationSpec.hs`**

A single `it "amends Income → Transfer end-to-end" $ \app -> do …` block — duplicate of E2E case 1 but stripped to just the success-path assertion. Keeps the existing within-kind file relevant for the new feature without bloating it.

- [ ] **Step 4: Build, test, commit**

```bash
just docker-up
just check
just build
just test
git add test/Integration/CrossKindAmendmentIntegrationSpec.hs \
        test/Integration/TransactionAmendmentIntegrationSpec.hs
git commit -m "$(cat <<'EOF'
test(transaction): cross-kind amendment end-to-end

Four E2E flows: Income → Transfer with externalTransactionId
preservation, Monobank dedup across amendment, Income → Expense
with supplied allocations, amendment-history audit trail.
EOF
)"
```

---

## Task 7: Domain property tests

**Spec:** §"Test plan" — Property tests.

**Files:**

- Modify: `test/Domain/Transaction/AmendmentPropertySpec.hs`.

Four properties from the spec (`deriveTransactionKind` totality is already in Task 1's unit tests, so skipping it as a property):

1. **Cross-kind round-trip**: any handler-accepted `AmendTransaction` projects to a transaction whose `transactionType` equals `cmd.newTransactionType`.
2. **Allocations-amount agreement**: every handler-accepted `AmendTransaction` has its allocation sum equal to the relevant leg.
3. **Currency consistency**: every allocation in `cmd.newTransactionType` shares the relevant leg's currency.
4. **Identity-amend idempotence**: a fully-deep-equal payload returns the existing read model unchanged, no events emitted.

- [ ] **Step 1: Reuse existing generators**

`test/Testkit/Generators.hs` already has `Arbitrary TransactionType` and `Arbitrary Allocation` instances from PR #90. Use them. If a generator for "a valid `(seedTransaction, AmendTransaction)` pair with kind cross-set" is needed, add it to `test/Testkit/Generators.hs` as `genCrossKindAmendInputs`.

- [ ] **Step 2: Add the four properties**

Property #1 verifies the round-trip through the emitted *event*, not through the projection — because the handler's `AmendTransaction` arm emits only `TransactionAmendmentInitiated`, which does not write `transactionType` (only `TransactionAmendmentCompleted`, emitted by the saga later, does). The end-to-end round-trip through projection lives in the integration tests (Task 6); here we verify the pure handler faithfully threads `newTransactionType` onto the event.

Property #4 lives at the service layer (the pure handler does not short-circuit identity-amend; `TransactionService.isIdentityAmend` does), and the cleanest form is a pure predicate property on `isIdentityAmend` itself.

```haskell
describe "AmendTransaction — cross-kind properties" $ do
  prop "(1) handler emits Initiated event with newTransactionType verbatim" $
    forAll genCrossKindAmendInputs $ \(seed, cmd) ->
      case handleTransactionCommand seed (AmendTransactionTransactionCommand cmd) of
        Right [TransactionAmendmentInitiatedTransactionEvent evt] ->
          evt.newTransactionType === cmd.newTransactionType
        Right _ ->
          counterexample "handler emitted unexpected event shape" False
        Left e ->
          counterexample ("handler rejected valid input: " <> show e) False

  prop "(2) allocation sum equals relevant leg amount" $
    forAll genCrossKindAmendInputs $ \(_seed, cmd) ->
      case cmd.newTransactionType of
        Income allocs -> sumAllocationsUnchecked allocs === cmd.newTargetAmount
        Expense allocs -> sumAllocationsUnchecked allocs === cmd.newSourceAmount
        _ -> property True

  prop "(3) allocation currency matches relevant leg" $
    forAll genCrossKindAmendInputs $ \(_seed, cmd) ->
      case cmd.newTransactionType of
        Income allocs ->
          all (\a -> a.amount.currency == cmd.newTargetAmount.currency) (NE.toList allocs)
        Expense allocs ->
          all (\a -> a.amount.currency == cmd.newSourceAmount.currency) (NE.toList allocs)
        _ -> True
```

In `test/Application/Services/CrossKindAmendmentSpec.hs`, add:

```haskell
prop "(4) identity-amend predicate holds for self-amend" $
  forAll genIdentityAmendInputs $ \(seedTd, cmd) ->
    isIdentityAmend seedTd cmd === True
```

`genIdentityAmendInputs` builds a `(seedTd, cmd)` pair where every field of `cmd` is set from `seedTd` — specifically `cmd.newTransactionType = seedTd.transactionType` (not a re-derived value). Pure property; no IO.

`genCrossKindAmendInputs` produces a `(seedTransaction, amendCmd)` pair that the handler accepts (Completed status, distinct accounts, non-zero amounts, valid `newTransactionType`). The generator's contract: `cmd.newTransactionType` is consistent with `cmd.newSourceAmount` / `cmd.newTargetAmount` (sum, currency, positivity) so the handler never returns `Left`. Add it to `test/Testkit/Generators.hs`.

- [ ] **Step 3: Build, run, commit**

```bash
cabal test all --test-option='--match' --test-option="/cross-kind properties/"
just check
just test
git add test/Domain/Transaction/AmendmentPropertySpec.hs \
        test/Application/Services/CrossKindAmendmentSpec.hs \
        test/Testkit/Generators.hs
git commit -m "test(transaction): cross-kind amendment property suite

Round-trip preservation, allocation sum/currency agreement,
identity-amend idempotence. Generators piggyback on the existing
TransactionType Arbitrary instance."
```

---

## Task 8: Ancillary caller sweep + saga / read-model tests

**Files:**

- Inspect / modify: `src/Application/Services/BankImportService.hs`, `src/Application/Services/TransactionHistoryService.hs`, `src/Telegram/Commands.hs`, anywhere `AmendTransaction` or `TransactionAmendmentCompleted` is constructed or pattern-matched.
- Modify: `test/Application/ProcessManagers/TransactionAmendmentManagerSpec.hs`, `test/Application/ProcessManagers/TransactionAmendmentManagerPropertySpec.hs`.

- [ ] **Step 1: Enumerate every `AmendTransaction` / `TransactionAmendmentCompleted` site**

```bash
grep -rn "AmendTransaction\|TransactionAmendmentCompleted\|TransactionAmendmentCompletedEvent\|TransactionAmendmentCompletedTransactionEvent" src/ \
  | grep -v "Domain/Transaction\|Application/Services/TransactionService\|Application/ReadModels/Transaction\|Application/ProcessManagers/TransactionAmendmentManager\|Web/API/TransactionAPI"
```

Each remaining hit is a call site to triage. Expected hits:

- `src/Application/Services/TransactionHistoryService.hs` — reads `evt.newAllocations` on `TransactionAmendmentCompletedEvent`. Switch to reading `evt.newTransactionType` and threading through whatever rendering helper produces the history row's allocation summary.
- `src/Application/Services/BankImportService.hs` — does it construct `AmendTransaction`? If yes, add `newAllocations = Nothing, newTransactionType = Transfer`.
- `src/Telegram/Commands.hs` — same check.

For each site, make the minimum change to compile + preserve behaviour. No behavioural change is expected in these callers; they continue passing `Nothing` / placeholder.

> **Note re: `TransactionHistoryService.hs`:** Task 3 Step 11 already updates this file's `TransactionAmendmentCompletedEvent` pattern match (because the event field rename forces it). This step is a verification pass — confirm the Task 3 change correctly renders the new `evt.newTransactionType`-driven history row, not a re-edit.

- [ ] **Step 2: Verify dispatch goes through `TransactionService.amendTransaction`**

The placeholder `newTransactionType = Transfer` is safe only because the service overwrites it before `runTransactionCmd`. Verify no caller bypasses the service:

```bash
grep -rn "AmendTransactionTransactionCommand" src/ | grep -v "Application/Services/TransactionService\|Domain/Transaction"
```

Expected: no hits. If a hit exists, the caller must either be routed through `amendTransaction` or accept responsibility for synthesising `newTransactionType` itself.

- [ ] **Step 3: Saga unit + property tests**

In `test/Application/ProcessManagers/TransactionAmendmentManagerSpec.hs`, add:

```haskell
it "Income → Transfer source endpoint swap produces source-only legs" $ do
  let initial =
        TransferPostings
          { sourceAccountId = accExt,  -- External
            targetAccountId = accA,    -- Regular A
            sourceAmount = mkMoneyUAH 100,
            targetAmount = mkMoneyUAH 100,
            at = at0
          }
      amend =
        TransactionAmendmentInitiated
          { transactionId = txId,
            newSourceAccountId = accB,   -- Regular B (was accExt)
            newTargetAccountId = accA,   -- unchanged
            newSourceAmount = mkMoneyUAH 100,
            newTargetAmount = mkMoneyUAH 100,
            newExchangeRate = Nothing,
            newTransactionType = Transfer,
            amendedBy = userId
          }
      (mDebit, rest) = diffAmendmentLegs initial amend
  mDebit `shouldBe` Just (DebitNewSource (accB, mkMoneyUAH 100, txId))
  rest `shouldBe` [ReverseOldSource accExt (mkMoneyUAH 100) txId at0]
```

In `test/Application/ProcessManagers/TransactionAmendmentManagerPropertySpec.hs`, add:

```haskell
prop "diffAmendmentLegs is account-type-agnostic" $
  forAll genMatchedEndpointPairs $ \(extEndpoints, regEndpoints) ->
    -- Build two TransactionAmendmentInitiated values with identical
    -- accounts/amounts but one with External legs and one with Regular.
    -- Assert diffAmendmentLegs returns the same shape for both.
    let (extDebit, extRest) = diffAmendmentLegs ...
        (regDebit, regRest) = diffAmendmentLegs ...
     in extDebit === regDebit .&&. extRest === regRest
```

> If the property is awkward (the diff algorithm doesn't pattern-match on `AccountType` at all, so this is trivially true), the simpler form is to inspect the function body and assert as a code-comment instead. Skip the property if the value of writing it is < value of reading the source. Document the decision in the PR.

- [ ] **Step 3: Build, test, commit**

```bash
just check
just build
just test
git add -A
git commit -m "$(cat <<'EOF'
chore(transaction): wire cross-kind amendment through ancillary callers

History service, bank-import service, and telegram bot now construct
AmendTransaction with the new fields. No behavioural change in these
callers (placeholder newTransactionType is overwritten by the
service). Saga unit + property test for Income → Transfer leg-diff.
EOF
)"
```

---

## Task 9: Verification + version bump + PR

**Files:**

- Modify: `package.yaml`.
- Regenerate: `backend.cabal` via `just build`.
- Modify: spec + plan frontmatter to `status: completed`.

### Cross-cutting checks (do these before bumping the version)

- [ ] **Check 1: No remaining references to deleted symbols**

```bash
grep -rn "validateAccountTypePreserved" src/ test/                                # expected: 0 hits
grep -rn "CannotAmendAcrossAccountType" src/ test/                                # expected: 0 hits
grep -rn "newAllocations :: Maybe Allocations" src/Domain/Transaction/Events.hs   # expected: 0 hits
grep -rn "evt.newAllocations" src/Domain/Transaction/Projection.hs \
                              src/Application/ReadModels/Transaction.hs           # expected: 0 hits in amendment arms
```

- [ ] **Check 2: All `AmendTransactionTransactionCommand` dispatches go through the service**

```bash
grep -rn "AmendTransactionTransactionCommand" src/ \
  | grep -v "Application/Services/TransactionService\|Domain/Transaction"
```

Expected: no hits.

- [ ] **Check 3: CI-style build is clean**

```bash
cabal build -fci
```

Expected: clean with `-Werror`.

- [ ] **Check 4: Dev DB reset note**

Eventium stores payloads as JSONB. Streams written by the pre-change code carry `TransactionAmendmentCompleted` with `newAllocations :: Maybe Allocations` and will fail to deserialise into the new shape. Per project policy (auto-memory `project_no_backcompat_phase`), no upcaster is provided. For local-dev only:

```bash
just docker-down
# remove the eventium PG volume so the DB starts empty on next docker-up
docker volume ls | grep eventium  # find the volume name
docker volume rm <name>
```

CI rebuilds the DB clean; no action required there.

### Version bump

- [ ] **Step 1: Bump version**

In `package.yaml`, change `version: 0.4.0` to `version: 0.5.0` (breaking event payload).

- [ ] **Step 2: Regenerate cabal file**

```bash
just build  # hpack regenerates backend.cabal
```

- [ ] **Step 3: Update spec + plan frontmatter**

Change `status: draft` → `status: completed` in both:

- `docs/specs/2026-06-01-cross-kind-amendment-design.md`
- `docs/plans/2026-06-02-cross-kind-amendment.md`

### Final verification

- [ ] **Step 4: Full verification suite**

```bash
just check
just build
just test
just docker-down
```

Expected: green on every step.

- [ ] **Step 5: Commit + push**

```bash
git add package.yaml backend.cabal \
        docs/specs/2026-06-01-cross-kind-amendment-design.md \
        docs/plans/2026-06-02-cross-kind-amendment.md
git commit -m "$(cat <<'EOF'
chore: bump to 0.5.0 — cross-kind amendment

Closes #94. TransactionAmendmentCompleted event payload changed
(newAllocations → newTransactionType); breaking — no upcaster per
project policy.
EOF
)"

git push -u origin feat/cross-kind-amendment
```

### Open the PR

- [ ] **Step 6: Create PR**

```bash
gh pr create --title "feat(transaction): cross-kind amendment" --body "$(cat <<'EOF'
## Summary
- Lifts the kind-preservation invariant on `AmendTransaction`. Income ↔ Expense ↔ Transfer amendments are now first-class; `externalTransactionId`, labels, business date, and amendment history are preserved across the kind change. Adjustment remains out of scope (single-account write — `AdjustAccountBalance` is the way in).
- Service layer derives the new kind from the new endpoints' `AccountType` pair via `deriveTransactionKind` and synthesises a full `newTransactionType` (kind ⊕ allocations) before dispatching. Amendment events shift to carrying the full `newTransactionType` verbatim; projections become a single field write.
- Breaking event shape change (no upcaster per project policy). Version bumped to 0.5.0.

## Test plan
- [x] `just check`
- [x] `just build` and `cabal build -fci`
- [x] `just test`
- [x] Integration: Monobank own-card dedup across cross-kind amendment
- [x] Property: round-trip preserves `newTransactionType`; allocation sum/currency invariants
- [x] Manual: amend Income → Transfer via `PUT /api/transactions/:id/amendment`

Closes #94.
EOF
)"
```

---

## Open issues / follow-ups (not in scope)

- **Bank-import auto-detection of own-account transfers.** Would prevent the misclassification at import time rather than make it amendable. Separate concern; benefits from this work landing first so the reclassification path exists.
- **UX: distinct "Reclassify" button vs. extending the existing amend form.** Front-end concern; the backend serves both shapes via the same endpoint.
- **`AmendTransaction.newTransactionType` placeholder smell.** The user-facing command carries a service-internal field initialised to `Transfer` and overwritten by the service. The alternatives (split into public + saga-internal command types) require a new sum-type variant and extra Eventium routing. If the placeholder becomes a maintenance pain (e.g., command logging surfaces the placeholder), split it out.
