---
status: draft
date: 2026-05-23
spec: docs/specs/2026-05-20-transfer-amendment-saga-design.md
issue: homeaccounting/backend#81
---

# Transfer Amendment Saga Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users correct a completed transfer's amount, source/target accounts, exchange rate, and transfer type via a single `PUT /api/transactions/:id/amendment` endpoint. Corrections are expressed as reversing entries on the original legs plus fresh postings on the new accounts, orchestrated by a new `TransferAmendmentManager` process manager. A `TransferAmendmentCompleted` event then updates the canonical posting facts on the TX aggregate.

**Architecture:**

- Account aggregate gains two new guaranteed-success events (`AccountDebitReversed`, `AccountCreditReversed`) and matching internal commands (`ReverseAccountDebit`, `ReverseAccountCredit`). Reversal events bypass overdraft checks — an undo of a recorded fact cannot be refused.
- Transaction aggregate gains three new events (`TransferAmendmentInitiated`, `TransferAmendmentCompleted`, `TransferAmendmentFailed`) and three new commands (`AmendTransfer`, `CompleteTransferAmendment`, `FailTransferAmendment`). Only `TransferAmendmentCompleted` mutates canonical state; the other two are saga-internal markers. The projection grows a `Word` `amendmentCount` field.
- A new sibling to `TransferManager` lives at `Application.ProcessManagers.TransferAmendmentManager`. It reacts to `TransferAmendmentInitiated`, computes the minimum diff between snapshotted old state and the amendment payload, issues the leg commands in order, and emits `CompleteTransferAmendment` (or `FailTransferAmendment` if the new-source debit is rejected).
- Service layer (`amendTransfer`) enforces auth on all four affected accounts (old source, old target, new source, new target), gates by `booksClosedThrough`, validates any embedded category, **computes the diff against current canonical state and short-circuits the identity-amend (no-op) case before dispatching any command** (this keeps spec §4.3's "no events, `amendmentCount` unchanged" semantics intact), then dispatches `AmendTransfer` and synchronously waits for the saga to emit `TransferAmendmentCompleted` / `TransferAmendmentFailed`.
- Read models pick up the new events: `balanceAsOf` and `handleAccountEvents` fold reversals symmetrically (no overdraft check); `TransactionData` increments `amendmentCount` and replaces the canonical posting fields on `TransferAmendmentCompleted`. A new `getTransactionHistory` reads the TX event stream directly for the audit endpoint.
- Web layer adds `PUT /api/transactions/:id/amendment` (synchronous) and `GET /api/transactions/:id/history` (audit). `TransactionResponse` grows an `amendmentCount` field.

**Tech Stack:** Haskell 9.10.3, RIO prelude, Servant, Eventium (event sourcing), PostgreSQL, Hspec + QuickCheck + hspec-discover, `just` task runner, ormolu + hlint via `just check`.

**Branch:** `feat/transfer-amendment-saga` (already created; the spec commit lives here).

**Design reference:** `docs/specs/2026-05-20-transfer-amendment-saga-design.md`. Read the whole spec before starting; the plan is a delivery schedule, the spec is authoritative for semantics. If plan and spec disagree, flag it — do not silently diverge.

**Reference implementations:**

- `src/Application/ProcessManagers/TransferManager.hs` is the *exact* precedent for the new process manager: same projection-shape, same `reactTo*` shape, same use of `IssueCommand` / `IssueCommandWithCompensation`. Read it before starting Task 7.
- `docs/plans/2026-05-20-editable-transaction-metadata.md` shows the most recent layered-edit-on-completed-transaction flow (events + commands + handler + projection + read model + service + API + integration). Read it before starting Tasks 4–12; this plan follows the same shape with more pieces.

---

## File Map

Files created:

- `src/Application/ProcessManagers/TransferAmendmentManager.hs` — sibling of `TransferManager`. Tracks per-amendment state, computes the minimal leg-event diff, issues leg commands in order, emits `CompleteTransferAmendment` on completion or `FailTransferAmendment` on the new-source debit rejection.
- `src/Application/Services/TransactionHistoryService.hs` — read-side service that reads the TX aggregate's event stream directly (via `EventStoreReader`) and renders an ordered `TransactionHistory`.
- `test/Domain/Account/ReversalCommandHandlerSpec.hs` — unit tests for `ReverseAccountDebit` / `ReverseAccountCredit`: accepted unconditionally on existing accounts; balance fold inverts; allowed on negative balances.
- `test/Domain/Account/ReversalProjectionPropertySpec.hs` — pair-cancellation property: `fold [AccountDebited, AccountDebitReversed] acc == acc` and symmetric for credit.
- `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs` — unit tests for `AmendTransfer` / `CompleteTransferAmendment` / `FailTransferAmendment`: status guards, same-account, zero-amount, transferType-vs-account-shape, replace-value projection semantics.
- `test/Domain/Transaction/AmendmentPropertySpec.hs` — for any sequence of `TransferAmendmentCompleted` events, the projection equals the last event's payload and `amendmentCount` equals the number of `TransferAmendmentCompleted` events folded.
- `test/Application/ProcessManagers/TransferAmendmentManagerSpec.hs` — pure saga tests for each case in spec §4.2 (amount-only via net delta, source-only swap, target-only swap, full 4-leg, no-op).
- `test/Application/ProcessManagers/TransferAmendmentManagerPropertySpec.hs` — diff property: for any old/new payload, the emitted commands' net effect equals (new debit on new source) + (new credit on new target) − (old debit on old source) − (old credit on old target).
- `test/Application/Services/TransactionAmendmentSpec.hs` — orchestration tests for `amendTransfer`: auth on four accounts, books-close gate, category validity on transfer-type change, end-to-end happy path, failure path.
- `test/Application/Services/TransactionHistoryServiceSpec.hs` — audit-history rendering from a synthetic event stream.
- `test/Application/ReadModels/AmendmentBalanceSpec.hs` — `balanceAsOf` folds reversal events symmetrically; a fully-reversed transaction does not affect the period balance.
- `test/Integration/TransferAmendmentIntegrationSpec.hs` — end-to-end across the amendment shapes per spec §7 (the integration list).

Files modified:

- `src/Domain/Core/Errors.hs` — add `CannotAmendToSameAccountPair`, `CannotAmendToZeroAmount`, `CannotAmendTransferTypeAcrossExternalBoundary`, `InsufficientFundsForAmendment`. The existing `CannotEditUncompletedTransaction` (defined at `src/Domain/Core/Errors.hs:92`), `CannotEditClosedPeriod`, and `CategoryNotFound` are *reused* — the amendment endpoint maps to the same constructors used by the metadata-edit endpoints.
- `src/Web/ErrorMapping.hs` — add 409 mappings for the four new errors.
- `src/Domain/Account/Events.hs` — add `AccountDebitReversed`, `AccountCreditReversed`; register in `accountEvents`; derive JSON; carry `at :: UTCTime` (current TX-aggregate business date at amend-start).
- `src/Domain/Account/Commands.hs` — add `ReverseAccountDebit`, `ReverseAccountCredit`; register in `accountCommands`; derive JSON.
- `src/Domain/Account/CommandHandler.hs` — accept both reversal commands unconditionally on an existing account. No overdraft check. Currency-mismatch check kept (defensive against malformed saga input).
- `src/Domain/Account/Projection.hs` — fold the two reversal events: `AccountDebitReversed` adds `amount` back; `AccountCreditReversed` subtracts `amount`. No overdraft check. Set `hasTransactions = True`.
- `src/Domain/Transaction/Events.hs` — add `TransferAmendmentInitiated`, `TransferAmendmentCompleted`, `TransferAmendmentFailed`; register in `transactionEvents`; derive JSON.
- `src/Domain/Transaction/Commands.hs` — add `AmendTransfer`, `CompleteTransferAmendment`, `FailTransferAmendment`; register in `transactionCommands`; derive JSON.
- `src/Domain/Transaction/CommandHandler.hs` — handle `AmendTransfer` in `Completed` only (otherwise `CannotEditUncompletedTransaction`). Pure-handler rejections: `CannotAmendToSameAccountPair`, `CannotAmendToZeroAmount`, `CannotAmendTransferTypeAcrossExternalBoundary`. `CompleteTransferAmendment` is accepted iff the TX has a pending `TransferAmendmentInitiated` (status remains `Completed`). `FailTransferAmendment` is the saga-failure marker, also accepted iff pending.
- `src/Domain/Transaction/Projection.hs` — add `amendmentCount :: Word` to `Transaction`; initialise `0` in `transactionDefault`. Add a transient `amendmentInProgress :: Bool` flag (used by the command handler to gate `CompleteTransferAmendment` / `FailTransferAmendment` — see Task 5). Fold:
  - `TransferAmendmentInitiated` → flip `amendmentInProgress` on; no canonical change.
  - `TransferAmendmentCompleted` → replace `sourceAccountId`, `targetAccountId`, `sourceAmount`, `targetAmount`, `exchangeRate`, `transferType`; bump `amendmentCount` by 1; clear `amendmentInProgress`. Status stays `Completed`.
  - `TransferAmendmentFailed` → clear `amendmentInProgress`; no canonical change (informational).

**Identity-amend handling (spec §4.3).** The service layer short-circuits before dispatching `AmendTransfer` if the new payload exactly matches current canonical state — no `TransferAmendmentInitiated` is emitted, no events land, `amendmentCount` is unchanged. Therefore the pure command handler never has to special-case the identity payload; the saga never has to emit a "completion of nothing"; and the projection's invariants stay clean.
- `src/Application/ProcessManagers.hs` — re-export the new `TransferAmendmentManager`.
- `src/Application/ReadModels/Account.hs` — fold `AccountDebitReversed` (`balance + amount`) and `AccountCreditReversed` (`balance - amount`) in `handleAccountEvents`; update `foldBalanceAsOf` symmetrically (using the `lookupAt` parameter for the reversal's effective business date).
- `src/Application/ReadModels/Transaction.hs` — add `amendmentCount :: Word` to `TransactionData`; default `0`. Fold:
  - `TransferAmendmentInitiated` → no-op.
  - `TransferAmendmentCompleted` → replace canonical posting fields and bump `amendmentCount`.
  - `TransferAmendmentFailed` → no-op.
- `src/Application/Services/TransactionService.hs` — add `amendTransfer`. Orchestration in order: ensure-editor-access on old source AND old target AND new source AND new target; books-close gate on current TX `at` (single check — the reversing + forward legs all carry the same `at`); validate any embedded category id in `newTransferType`; dispatch `AmendTransfer`; synchronously await `TransferAmendmentCompleted` or `TransferAmendmentFailed` via the same wait-for-saga pattern used by `initiateTransfer`; surface `InsufficientFundsForAmendment` on the failure path. Export it.
- `src/Web/Types.hs` — add `AmendTransactionRequest` (matches §6.1 body); add `TransactionHistoryResponse` and a sum-tag DTO for each kind of audit entry; add `amendmentCount :: Word` to `TransactionResponse`; thread it through `fromTransactionData`.
- `src/Web/API/TransactionAPI.hs` — wire `PUT /api/transactions/:id/amendment` and `GET /api/transactions/:id/history`. Re-use `validateField`, `parseLabelIds`, `parseCategoryId`, `mkAccountId`, `mkTransactionId` from existing handlers.
- `app/Main.hs` — wire `transferAmendmentProcessManager` next to the existing `transferProcessManager` via `wireProcessManager`.

Every source edit lands in a commit that ships with its associated tests — the build stays green at every task boundary.

### Deferred from this plan

**Spec §5.1 — `LedgerEntry` net-collapsed account-history view.** The spec describes a `LedgerEntry` DTO that groups per-account leg events by `transactionId`, computes a net delta (regular + reversed), drops zero-delta entries, and joins TX-aggregate metadata. There is no current account-history HTTP endpoint that surfaces such a view (verify: `grep -n "history\|ledger" src/Web/API/AccountAPI.hs` — no matches). Adding the DTO + endpoint without a consumer would be speculative.

Within this plan, Task 8 covers only the changes needed to keep `balanceAsOf` and the current-balance fold correct under reversal events. The net-collapsed `LedgerEntry` view and its endpoint are explicitly **deferred to a follow-up spec / plan**. Flag this deferral in the PR description so spec §5.1 can be retitled or split.

---

## Task 1 — Extend `DomainError` and HTTP mapping

Foundation: subsequent tasks reference these constructors.

**Files:**
- Modify: `src/Domain/Core/Errors.hs`
- Modify: `src/Web/ErrorMapping.hs`

- [ ] **Step 1.1: Add the four new `DomainError` constructors.**

In `src/Domain/Core/Errors.hs`, after `CannotRewindBooksCloseDate { ... }`:

```haskell
  | -- | Amendment payload referenced the same account on both legs.
    CannotAmendToSameAccountPair
  | -- | Amendment payload carried a zero source or target amount.
    CannotAmendToZeroAmount
  | -- | Amendment's @newTransferType@ disagrees with the account types
    -- (External -> Regular = Income, Regular -> External = Expense,
    -- Regular -> Regular = Transfer; External -> External is forbidden).
    CannotAmendTransferTypeAcrossExternalBoundary
  | -- | The saga's new-source debit was rejected (insufficient funds /
    -- currency mismatch). The original transfer is intact; @reason@
    -- carries the underlying rejection message.
    InsufficientFundsForAmendment Text
```

Extend `renderDomainError` with matching prose cases (mirror `LabelInUse`'s shape for the parameterised case). Keep the `Eq`/`Generic` derivations.

- [ ] **Step 1.2: Wire HTTP mappings.**

In `src/Web/ErrorMapping.hs`, add four cases mirroring the existing record-bearing 409 cases. All four map to `err409`. Use these JSON codes:

| Constructor                                       | code                                                    |
| ------------------------------------------------- | ------------------------------------------------------- |
| `CannotAmendToSameAccountPair`                    | `CANNOT_AMEND_TO_SAME_ACCOUNT_PAIR`                     |
| `CannotAmendToZeroAmount`                         | `CANNOT_AMEND_TO_ZERO_AMOUNT`                           |
| `CannotAmendTransferTypeAcrossExternalBoundary`   | `CANNOT_AMEND_TRANSFER_TYPE_ACROSS_EXTERNAL_BOUNDARY`   |
| `InsufficientFundsForAmendment reason`            | `INSUFFICIENT_FUNDS_FOR_AMENDMENT` (details `reason`)   |

The first three have `details = Nothing`. `InsufficientFundsForAmendment` carries the saga rejection reason in `details` as `Map.singleton "reason" reason`.

- [ ] **Step 1.3: `just build`.**

Run: `just build`
Expected: PASS.

- [ ] **Step 1.4: Commit.**

```bash
git add src/Domain/Core/Errors.hs src/Web/ErrorMapping.hs
git commit -m "feat(errors): add DomainError constructors for transfer amendment

- CannotAmendToSameAccountPair
- CannotAmendToZeroAmount
- CannotAmendTransferTypeAcrossExternalBoundary
- InsufficientFundsForAmendment (carries saga rejection reason)

All four map to HTTP 409 in Web.ErrorMapping.

Refs #81"
```

---

## Task 2 — Account reversal events + projection

Pure-domain piece for the account side.

**Files:**
- Modify: `src/Domain/Account/Events.hs`
- Modify: `src/Domain/Account/Projection.hs`
- Test: `test/Domain/Account/ReversalProjectionPropertySpec.hs`

- [ ] **Step 2.1: Write the failing property test.**

Create `test/Domain/Account/ReversalProjectionPropertySpec.hs`:

```haskell
module Domain.Account.ReversalProjectionPropertySpec (spec) where

import Domain.Account.Events
  ( AccountCredited (..),
    AccountCreditReversed (..),
    AccountDebited (..),
    AccountDebitReversed (..),
  )
import Domain.Account.Projection (Account, AccountEvent (..), accountProjection)
import Eventium (latestProjection)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
-- ... existing generators from Testkit.Generators

spec :: Spec
spec = describe "Account reversal projection" $ do
  prop "debit + debit-reversal cancels" $ \createdEvt amt txId t ->
    let events =
          [ AccountCreatedAccountEvent createdEvt,
            AccountDebitedAccountEvent (AccountDebited amt txId),
            AccountDebitReversedAccountEvent (AccountDebitReversed amt txId t)
          ]
        finalAcct = latestProjection accountProjection events
        baseline = latestProjection accountProjection [AccountCreatedAccountEvent createdEvt]
     in (finalAcct & ignoreHasTx) == (baseline & ignoreHasTx)

  prop "credit + credit-reversal cancels" $ \createdEvt amt txId t ->
    ...
```

(The `ignoreHasTx` helper masks the `hasTransactions :: Bool` field — a debit + reversal pair does leave `hasTransactions = True`, which is correct but not part of the *balance* cancellation property.)

Match the existing `test/Domain/Account/CommandHandlerPropertySpec.hs` for the QuickCheck generators and the helper imports.

- [ ] **Step 2.2: Run, see compile failure.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Account.ReversalProjection/"`
Expected: COMPILE FAIL — `AccountDebitReversed` / `AccountCreditReversed` not defined.

- [ ] **Step 2.3: Add the events.**

In `src/Domain/Account/Events.hs`, alongside `AccountDebited` / `AccountCredited`:

```haskell
-- | Event emitted when a prior debit on this account is reversed as
-- part of a transfer amendment. The balance fold adds @amount@ back to
-- the account, with no overdraft check — a reversal undoes a recorded
-- fact and cannot be refused (see spec
-- @2026-05-20-transfer-amendment-saga-design.md@ §2.1).
data AccountDebitReversed = AccountDebitReversed
  { -- | Amount being reversed (always positive; same currency as the
    -- account's balance). Equals the original 'AccountDebited.amount'
    -- of the leg this reverses.
    amount :: Money,
    -- | Transaction id for saga correlation; identifies the
    -- 'AccountDebited' being reversed.
    transactionId :: TransactionId,
    -- | Business date of the amendment (the TX aggregate's current 'at'
    -- at amend-start). Used by 'balanceAsOf' fallback only — the
    -- authoritative business date lives on the TX aggregate.
    at :: UTCTime
  }
  deriving (Show, Eq)

-- | Event emitted when a prior credit on this account is reversed as
-- part of a transfer amendment. The balance fold subtracts @amount@
-- from the account, with no overdraft check — a Regular account may go
-- negative if the credit had already been partially spent. That
-- negative state is the truthful representation of unbacked spending
-- (spec §2.1, §"Domain consistency").
data AccountCreditReversed = AccountCreditReversed
  { amount :: Money,
    transactionId :: TransactionId,
    at :: UTCTime
  }
  deriving (Show, Eq)
```

Add `''AccountDebitReversed`, `''AccountCreditReversed` to `accountEvents`; `deriveJSON defaultOptions` for both. Re-export both from the module export list.

- [ ] **Step 2.4: Fold the events in the account projection.**

In `src/Domain/Account/Projection.hs`, after the `AccountCreditedAccountEvent` arm:

```haskell
handleAccountEvent account (AccountDebitReversedAccountEvent AccountDebitReversed {..}) =
  -- Undo a prior debit: add the amount back. No overdraft check — a
  -- reversal records the undoing of a fact, not a new posting.
  case addMoney (account ^. #balance) amount of
    Right newBalance -> account & #balance .~ newBalance & #hasTransactions .~ True
    Left _ -> account -- currency mismatch cannot occur for valid streams
handleAccountEvent account (AccountCreditReversedAccountEvent AccountCreditReversed {..}) =
  -- Undo a prior credit: subtract the amount. No overdraft check — the
  -- account may go negative if the credit had already been (partially)
  -- spent on another transfer.
  case subtractMoney (account ^. #balance) amount of
    Right newBalance -> account & #balance .~ newBalance & #hasTransactions .~ True
    Left _ -> account
```

- [ ] **Step 2.5: Add the events to the import list in `Domain.Account.Projection`** alongside the existing `AccountDebited (..)` etc.

- [ ] **Step 2.6: Run the property test, see it pass.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Account.ReversalProjection/"`
Expected: PASS.

- [ ] **Step 2.7: Run the full Account bucket — no regressions.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Account/"`
Expected: PASS.

- [ ] **Step 2.8: `just check`.**

- [ ] **Step 2.9: Commit.**

```bash
git add src/Domain/Account/Events.hs src/Domain/Account/Projection.hs test/Domain/Account/ReversalProjectionPropertySpec.hs
git commit -m "feat(accounts): reversing-entry events (debit / credit)

Adds AccountDebitReversed and AccountCreditReversed, the
guaranteed-success events emitted by the TransferAmendmentManager
saga to undo prior leg postings. The projection folds them
symmetrically: debit-reversal adds back, credit-reversal subtracts.
Neither consults the overdraft limit — a reversal cannot be refused.

Refs #81"
```

---

## Task 3 — Account reversal commands

The saga-only commands that produce the reversal events.

**Files:**
- Modify: `src/Domain/Account/Commands.hs`
- Modify: `src/Domain/Account/CommandHandler.hs`
- Test: `test/Domain/Account/ReversalCommandHandlerSpec.hs`

- [ ] **Step 3.1: Write the failing handler tests.**

Create `test/Domain/Account/ReversalCommandHandlerSpec.hs`. Cover:

- `ReverseAccountDebit` on an existing account with positive balance → emits `AccountDebitReversed`.
- `ReverseAccountDebit` on an account at zero balance → still accepted (reversal can take balance positive but does not consult overdraft either way).
- `ReverseAccountCredit` on an account whose balance is *less than* the reversal amount (i.e., would go negative) → still accepted; emits `AccountCreditReversed`.
- `ReverseAccountDebit` / `ReverseAccountCredit` against a default (uninitialised) account → `AccountDoesNotExist`.
- Currency-mismatch between the command's `amount` and the account's balance → `CurrencyMismatch`.

Use the existing fixture helpers in `test/Domain/Account/CommandHandlerSpec.hs` for an existing account; copy the shape of the `DebitAccount` tests.

- [ ] **Step 3.2: Run, see compile failure.**

Expected: COMPILE FAIL — `ReverseAccountDebit` / `ReverseAccountCredit` not defined.

- [ ] **Step 3.3: Add the commands.**

In `src/Domain/Account/Commands.hs`:

```haskell
-- | Saga-only command: reverse a prior debit on this account.
--
-- Issued exclusively by the TransferAmendmentManager process manager.
-- Not exposed via any HTTP endpoint. Always accepted on an existing
-- account (no overdraft check, no positive-balance requirement).
data ReverseAccountDebit = ReverseAccountDebit
  { amount :: Money,
    transactionId :: TransactionId,
    at :: UTCTime
  }
  deriving (Show, Eq)

-- | Saga-only command: reverse a prior credit on this account.
--
-- Same semantics as 'ReverseAccountDebit' but for the credit leg. May
-- take the account's balance negative; that negative state is the
-- truthful representation of money the user spent that was never
-- legitimately credited.
data ReverseAccountCredit = ReverseAccountCredit
  { amount :: Money,
    transactionId :: TransactionId,
    at :: UTCTime
  }
  deriving (Show, Eq)
```

Add `''ReverseAccountDebit`, `''ReverseAccountCredit` to `accountCommands`. `deriveJSON defaultOptions` for both. Add a `Data.Time (UTCTime)` import.

Re-export both from the module export list.

- [ ] **Step 3.4: Add handler arms.**

In `src/Domain/Account/CommandHandler.hs`:

```haskell
handleAccountCommand account (ReverseAccountDebitAccountCommand ReverseAccountDebit {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | moneyCurrency amount /= moneyCurrency (account ^. #balance) = Left CurrencyMismatch
  | otherwise =
      Right
        [ AccountDebitReversedAccountEvent
            AccountDebitReversed
              { amount = amount,
                transactionId = transactionId,
                at = at
              }
        ]
handleAccountCommand account (ReverseAccountCreditAccountCommand ReverseAccountCredit {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | moneyCurrency amount /= moneyCurrency (account ^. #balance) = Left CurrencyMismatch
  | otherwise =
      Right
        [ AccountCreditReversedAccountEvent
            AccountCreditReversed
              { amount = amount,
                transactionId = transactionId,
                at = at
              }
        ]
```

Pattern after the `CreditAccount` arm (no balance pre-conditions; only the existence and currency-match checks). Add `AccountDebitReversed (..)` / `AccountCreditReversed (..)` to the event imports and `ReverseAccountDebit (..)` / `ReverseAccountCredit (..)` to the command imports.

- [ ] **Step 3.5: Run handler tests, see pass.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Account.ReversalCommandHandler/"`
Expected: PASS.

- [ ] **Step 3.6: Run full Account bucket.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Account/"`
Expected: PASS — including the property test from Task 2.

- [ ] **Step 3.7: `just check`.**

- [ ] **Step 3.8: Commit.**

```bash
git add src/Domain/Account/Commands.hs src/Domain/Account/CommandHandler.hs test/Domain/Account/ReversalCommandHandlerSpec.hs
git commit -m "feat(accounts): reversal commands (debit / credit)

Adds ReverseAccountDebit and ReverseAccountCredit, the saga-only
commands that produce reversal events. Accepted unconditionally on an
existing account modulo currency match. No overdraft check on either
command — see spec §2.1.

Refs #81"
```

---

## Task 4 — Transaction amendment events

Pure-domain piece for the transaction side.

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`

- [ ] **Step 4.1: Add the three events.**

In `src/Domain/Transaction/Events.hs`, after `TransactionDateChanged`:

```haskell
-- | Saga-trigger event: the user has submitted an 'AmendTransfer'
-- command and the domain handler accepted it. The process manager
-- reacts to this event by computing the minimum diff between the
-- snapshotted old state and the new payload, then issuing the
-- corresponding leg commands. Carries the full new payload.
data TransferAmendmentInitiated = TransferAmendmentInitiated
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransferType :: TransferType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)

-- | Saga-completion event: all leg events have landed. The TX
-- aggregate's canonical posting facts move to the new values; the
-- projection bumps @amendmentCount@. Replayed from saga state so the
-- event is self-contained for read-model rebuilds.
data TransferAmendmentCompleted = TransferAmendmentCompleted
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransferType :: TransferType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)

-- | Saga-failure event: the only fallible saga step (the new-source
-- debit) was rejected. No leg events were written; the original
-- transfer is intact.
newtype TransferAmendmentFailed = TransferAmendmentFailed
  { reason :: Text
  }
  deriving (Show, Eq)
```

Add the three names to `transactionEvents`; `deriveJSON defaultOptions` for all three. Re-export all three.

- [ ] **Step 4.2: `just build`.**

Run: `just build`
Expected: PASS.

- [ ] **Step 4.3: Commit.**

```bash
git add src/Domain/Transaction/Events.hs
git commit -m "feat(transactions): amendment-saga event types

Adds TransferAmendmentInitiated, TransferAmendmentCompleted, and
TransferAmendmentFailed. Only TransferAmendmentCompleted mutates the
TX aggregate's canonical posting facts; the other two are
saga-internal markers.

Refs #81"
```

---

## Task 5 — Transaction amendment commands + command handler

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Test: `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs`

- [ ] **Step 5.1: Write the failing handler tests.**

Create `test/Domain/Transaction/AmendmentCommandHandlerSpec.hs`. Cover (using helpers from `test/Testkit/Helpers.hs` for building a Completed transaction):

- `AmendTransfer` in `Completed` with valid payload → emits a single `TransferAmendmentInitiatedTransactionEvent` carrying the full new payload.
- `AmendTransfer` in `Pending` → `Left CannotEditUncompletedTransaction`.
- `AmendTransfer` in `Failed _` → `Left CannotEditUncompletedTransaction`.
- `AmendTransfer` with `newSourceAccountId == newTargetAccountId` → `Left CannotAmendToSameAccountPair`.
- `AmendTransfer` with `newSourceAmount == zero` → `Left CannotAmendToZeroAmount`.
- `AmendTransfer` with `newTargetAmount == zero` → `Left CannotAmendToZeroAmount`.
- `CompleteTransferAmendment` in `Completed` with no pending amendment → `Left NoAmendmentInProgress` (new aggregate-local error; see §5.3 below).
- `CompleteTransferAmendment` in `Completed` after a pending `AmendTransfer` → emits `TransferAmendmentCompletedTransactionEvent`.
- `FailTransferAmendment` symmetric.

The TransferType-vs-account-shape validation (§3.5 in the spec) is checked at the *service* layer (which has the account read model), not in the pure handler. The pure handler's role is the lifecycle / structural checks only.

- [ ] **Step 5.2: Run, see compile failure.**

Expected: COMPILE FAIL.

- [ ] **Step 5.3: Add the commands.**

In `src/Domain/Transaction/Commands.hs`:

```haskell
-- | User-initiated amendment of a completed transfer's posting facts.
-- The new payload is a full replacement of the prior posting facts;
-- the saga computes the minimum diff and issues only the necessary
-- leg events.
data AmendTransfer = AmendTransfer
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransferType :: TransferType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)

-- | Saga-internal: issued by 'TransferAmendmentManager' once all leg
-- events have landed. Promotes the new payload to canonical state.
data CompleteTransferAmendment = CompleteTransferAmendment
  { transactionId :: TransactionId,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransferType :: TransferType,
    amendedBy :: UserId
  }
  deriving (Show, Eq)

-- | Saga-internal: issued by 'TransferAmendmentManager' when the
-- new-source debit is rejected. Records the failure; no canonical
-- state change.
newtype FailTransferAmendment = FailTransferAmendment
  { reason :: Text
  }
  deriving (Show, Eq)
```

Add all three names to `transactionCommands`. `deriveJSON defaultOptions` for all three. Re-export them.

- [ ] **Step 5.4: Extend the aggregate-local `TransactionError` type.**

In `src/Domain/Transaction/CommandHandler.hs`, add:

```haskell
  | -- | 'CompleteTransferAmendment' / 'FailTransferAmendment' issued
    -- without a prior 'TransferAmendmentInitiated' on the stream.
    NoAmendmentInProgress
```

- [ ] **Step 5.5: Track "amendment in progress" on the projection.**

The handler needs to know whether an amendment is mid-flight before accepting `CompleteTransferAmendment` / `FailTransferAmendment`. Add a transient field to `Transaction`:

```haskell
-- | True when a 'TransferAmendmentInitiated' has been folded but the
-- matching 'TransferAmendmentCompleted' / 'TransferAmendmentFailed'
-- has not yet been folded. Used by the command handler to gate
-- 'CompleteTransferAmendment' / 'FailTransferAmendment'.
amendmentInProgress :: Bool
```

In `transactionDefault`, initialise to `False`.

In Task 6 we extend the projection's fold to flip this on `TransferAmendmentInitiated` and back on `TransferAmendmentCompleted` / `TransferAmendmentFailed`. The projection write happens in Task 6; reference the new field here only as a status guard.

- [ ] **Step 5.6: Add handler arms.**

In `src/Domain/Transaction/CommandHandler.hs`:

```haskell
handleTransactionCommand transaction (AmendTransferTransactionCommand AmendTransfer {..}) =
  case transaction ^. #status of
    Completed
      | unAccountId newSourceAccountId == unAccountId newTargetAccountId ->
          Left CannotAmendToSameAccountPair
      | unMoney newSourceAmount == 0 || unMoney newTargetAmount == 0 ->
          Left CannotAmendToZeroAmount
      | otherwise ->
          Right
            [ TransferAmendmentInitiatedTransactionEvent
                TransferAmendmentInitiated
                  { transactionId = transactionId,
                    newSourceAccountId = newSourceAccountId,
                    newTargetAccountId = newTargetAccountId,
                    newSourceAmount = newSourceAmount,
                    newTargetAmount = newTargetAmount,
                    newExchangeRate = newExchangeRate,
                    newTransferType = newTransferType,
                    amendedBy = amendedBy
                  }
            ]
    _ -> Left CannotEditUncompletedTransaction
handleTransactionCommand transaction (CompleteTransferAmendmentTransactionCommand CompleteTransferAmendment {..})
  | not (transaction ^. #amendmentInProgress) = Left NoAmendmentInProgress
  | otherwise =
      Right
        [ TransferAmendmentCompletedTransactionEvent
            TransferAmendmentCompleted
              { transactionId = transactionId,
                newSourceAccountId = newSourceAccountId,
                newTargetAccountId = newTargetAccountId,
                newSourceAmount = newSourceAmount,
                newTargetAmount = newTargetAmount,
                newExchangeRate = newExchangeRate,
                newTransferType = newTransferType,
                amendedBy = amendedBy
              }
        ]
handleTransactionCommand transaction (FailTransferAmendmentTransactionCommand FailTransferAmendment {..})
  | not (transaction ^. #amendmentInProgress) = Left NoAmendmentInProgress
  | otherwise =
      Right
        [ TransferAmendmentFailedTransactionEvent
            TransferAmendmentFailed { reason = reason }
        ]
```

Note: the `CannotAmendTransferTypeAcrossExternalBoundary` rejection is *not* in the pure handler — see §3.5 of the spec. It needs to read account types; that lives at the service layer (Task 11).

- [ ] **Step 5.7: Translate `NoAmendmentInProgress` at the service edge.**

Extend `translateTransactionError` in `src/Application/Services/TransactionService.hs` to map `NoAmendmentInProgress` to a `TransactionError "..."` for now — the proper public error surface for this case is internal-only (the saga never issues these commands out of order in valid streams), and surfacing as `TransactionError` is fine for the rare race-condition / malformed-payload corner.

- [ ] **Step 5.8: Run handler tests, see pass.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Transaction.AmendmentCommandHandler/"`
Expected: PASS — except the `amendmentInProgress` field is not yet folded into the projection; the test for `CompleteTransferAmendment` after a prior `AmendTransfer` will need a manual `& #amendmentInProgress .~ True` in its arrange step until Task 6 lands. Document this in the test.

- [ ] **Step 5.9: Run full Transaction bucket.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Transaction/"`
Expected: PASS.

- [ ] **Step 5.10: `just check`.**

- [ ] **Step 5.11: Commit.**

```bash
git add src/Domain/Transaction/Commands.hs src/Domain/Transaction/CommandHandler.hs src/Domain/Transaction/Projection.hs src/Application/Services/TransactionService.hs test/Domain/Transaction/AmendmentCommandHandlerSpec.hs
git commit -m "feat(transactions): AmendTransfer + saga-completion commands

Adds the AmendTransfer user command and the two saga-internal commands
(CompleteTransferAmendment, FailTransferAmendment). The pure handler
enforces lifecycle (Completed), structural (distinct accounts, nonzero
amounts), and ordering (amendmentInProgress) rules. TransferType
vs account-type checking remains at the service edge (needs account
read model). Adds an amendmentInProgress :: Bool field on the
projection record; fold updates land in Task 6.

Refs #81"
```

---

## Task 6 — Transaction projection: amendmentCount + amendment-event folds

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs`
- Test: `test/Domain/Transaction/AmendmentPropertySpec.hs`
- Test: `test/Domain/Transaction/CommandHandlerSpec.hs` (extend existing projection tests)

- [ ] **Step 6.1: Write the failing property test.**

Create `test/Domain/Transaction/AmendmentPropertySpec.hs`:

```haskell
module Domain.Transaction.AmendmentPropertySpec (spec) where

import qualified Data.List as L
import Domain.Transaction.Events
  ( TransferAmendmentCompleted (..),
    TransferAmendmentFailed (..),
    TransferAmendmentInitiated (..),
  )
import Domain.Transaction.Projection
  ( Transaction (..),
    TransactionEvent (..),
    handleTransactionEvent,
  )
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Testkit.Generators ( ... )

spec :: Spec
spec = describe "Transaction amendment projection" $ do
  prop "amendmentCount equals folded Completed-event count" $ \completedTx amendments ->
    let events =
          concatMap
            ( \a ->
                [ TransferAmendmentInitiatedTransactionEvent (toInitiated a),
                  TransferAmendmentCompletedTransactionEvent a
                ]
            )
            amendments
        finalTx = L.foldl' handleTransactionEvent completedTx events
     in finalTx.amendmentCount === fromIntegral (length amendments)

  prop "last amendment wins" $ \completedTx amendments ->
    not (null amendments) ==>
      let events = ...
          finalTx = L.foldl' handleTransactionEvent completedTx events
          lastA = last amendments
       in finalTx.sourceAccountId === lastA.newSourceAccountId
            .&. finalTx.targetAccountId === lastA.newTargetAccountId
            .&. finalTx.sourceAmount === lastA.newSourceAmount
            .&. finalTx.targetAmount === lastA.newTargetAmount

  prop "TransferAmendmentInitiated is a no-op on canonical fields" ...
  prop "TransferAmendmentFailed is a no-op on canonical fields" ...
  prop "amendmentInProgress flips on Initiated and clears on Completed/Failed" ...
```

- [ ] **Step 6.2: Run, see compile failure.**

Expected: COMPILE FAIL — `amendmentCount` field doesn't yet exist on the projection.

- [ ] **Step 6.3: Extend the `Transaction` record.**

In `src/Domain/Transaction/Projection.hs`:

```haskell
data Transaction = Transaction
  { ...,
    -- (existing fields),
    ...,
    -- | Count of 'TransferAmendmentCompleted' events folded so far.
    -- Exposed on the API surface so clients can detect amendments and
    -- fetch the audit history if interested. Always @0@ on a
    -- transaction that has never been amended.
    amendmentCount :: Word,
    -- (the new field added in Task 5.5)
    amendmentInProgress :: Bool
  }
```

Initialise both in `transactionDefault`:

```haskell
amendmentCount = 0,
amendmentInProgress = False
```

(Add `Word` to imports if not already present — it's from `Prelude` / `RIO`.)

- [ ] **Step 6.4: Add fold arms.**

In `handleTransactionEvent`, after the existing `TransactionDateChangedTransactionEvent` arm:

```haskell
handleTransactionEvent transaction (TransferAmendmentInitiatedTransactionEvent _evt) =
  -- Saga-internal marker. Canonical fields are unchanged; flip the
  -- in-progress flag so the command handler accepts the saga's
  -- completion or failure command.
  transaction & #amendmentInProgress .~ True
handleTransactionEvent transaction (TransferAmendmentCompletedTransactionEvent evt) =
  -- Replace the posting facts with the amended values; bump the
  -- amendment count; clear the in-progress flag.
  transaction
    & #sourceAccountId .~ evt.newSourceAccountId
    & #targetAccountId .~ evt.newTargetAccountId
    & #sourceAmount .~ evt.newSourceAmount
    & #targetAmount .~ evt.newTargetAmount
    & #exchangeRate .~ evt.newExchangeRate
    & #transferType .~ evt.newTransferType
    & #amendmentCount %~ (+ 1)
    & #amendmentInProgress .~ False
handleTransactionEvent transaction (TransferAmendmentFailedTransactionEvent _evt) =
  -- Informational only — canonical fields are unchanged; clear the
  -- in-progress flag.
  transaction & #amendmentInProgress .~ False
```

(The `(%~)` operator is `over`, already imported via `Optics`.)

- [ ] **Step 6.5: Run the property tests, see them pass.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Transaction.AmendmentProperty/"`
Expected: PASS.

- [ ] **Step 6.6: Run all Transaction tests.**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Transaction/"`
Expected: PASS — including the test from Task 5 that now no longer needs the manual `amendmentInProgress` setup (remove that workaround).

- [ ] **Step 6.7: `just check`.**

- [ ] **Step 6.8: Commit.**

```bash
git add src/Domain/Transaction/Projection.hs test/Domain/Transaction/AmendmentPropertySpec.hs test/Domain/Transaction/AmendmentCommandHandlerSpec.hs
git commit -m "feat(transactions): amendment projection + amendmentCount

Adds amendmentCount :: Word and amendmentInProgress :: Bool to the
Transaction projection. The fold rules:

- TransferAmendmentInitiated -> flip amendmentInProgress on
- TransferAmendmentCompleted -> replace posting facts, bump
  amendmentCount, flip in-progress off
- TransferAmendmentFailed   -> in-progress off, canonical unchanged

Refs #81"
```

---

## Task 7 — TransferAmendmentManager process manager

The saga that orchestrates the cross-aggregate work. Closest precedent: `src/Application/ProcessManagers/TransferManager.hs`.

**Files:**
- Create: `src/Application/ProcessManagers/TransferAmendmentManager.hs`
- Modify: `src/Application/ProcessManagers.hs` (re-export)
- Test: `test/Application/ProcessManagers/TransferAmendmentManagerSpec.hs`
- Test: `test/Application/ProcessManagers/TransferAmendmentManagerPropertySpec.hs`

- [ ] **Step 7.1: Sketch the per-amendment state record.**

```haskell
-- | Per-amendment tracking. Snapshotting the old values at amend-start
-- decouples the saga from races against another concurrent amendment
-- on the same transaction — the optimistic-concurrency check on the
-- TX aggregate's (uuid, version) serialises the second amendment, so
-- the snapshot captured at amend-start is what we need to reverse.
data TransferAmendmentData = TransferAmendmentData
  { oldSourceAccountId :: AccountId,
    oldTargetAccountId :: AccountId,
    oldSourceAmount :: Money,
    oldTargetAmount :: Money,
    newSourceAccountId :: AccountId,
    newTargetAccountId :: AccountId,
    newSourceAmount :: Money,
    newTargetAmount :: Money,
    newExchangeRate :: Maybe ExchangeRate,
    newTransferType :: TransferType,
    amendedBy :: UserId,
    phase :: TransferAmendmentPhase,
    -- | The TX-aggregate's current 'at' captured at amend-start. Used
    -- as the @at@ on every reversal event the saga emits, so the
    -- account stream's reversed-leg events carry the correct business
    -- date (matching the TX aggregate, per spec §2.1).
    at :: UTCTime
  }
  deriving (Show, Eq)

data TransferAmendmentPhase
  = AwaitingNewSourceDebit
  | NewSourceDebited
  | OldTargetCreditReversed
  | OldSourceDebitReversed
  | NewTargetCredited
  deriving (Show, Eq)
```

- [ ] **Step 7.2: Write the failing saga unit tests.**

Create `test/Application/ProcessManagers/TransferAmendmentManagerSpec.hs`. Cover each row of spec §4.2's table:

- **Note on identity amend.** The saga is *never* invoked on the identity payload — the service layer (Task 11) computes the diff and short-circuits before dispatching `AmendTransfer`. The saga unit tests therefore never receive an empty-diff `TransferAmendmentInitiated`; do not write a "no-op saga" test case. Spec §4.3 is honoured at the service edge.

- **Amount-only, source larger**: source and target accounts unchanged, both amounts increased by Δ.
  - Effects: a `DebitAccount` on the existing source for `+Δ_src` (fallible — same compensation as the original transfer) and a `CreditAccount` on the existing target for `+Δ_tgt`. Then `CompleteTransferAmendment`.
  - Assertion: effects list length and contents.

- **Amount-only, source smaller**: source and target accounts unchanged, both amounts decreased by Δ.
  - Effects: `ReverseAccountDebit` on the source for `Δ_src`, `ReverseAccountCredit` on the target for `Δ_tgt`. Then `CompleteTransferAmendment`.

- **Target account swap** (source unchanged, amounts unchanged): `ReverseAccountCredit` on the old target for `oldTargetAmount`, then `CreditAccount` on the new target for `newTargetAmount`. Then `CompleteTransferAmendment`.

- **Source account swap** (target unchanged): `DebitAccount` on the new source for `newSourceAmount` (fallible), then `ReverseAccountDebit` on the old source for `oldSourceAmount`. Then `CompleteTransferAmendment`.

- **Both accounts swap (full 4-leg)**: in order — `DebitAccount` (new source, fallible) → `ReverseAccountCredit` (old target) → `ReverseAccountDebit` (old source) → `CreditAccount` (new target) → `CompleteTransferAmendment`.

- **Failure path**: `DebitAccount` (new source) is rejected → compensation declared in the `IssueCommandWithCompensation` issues `FailTransferAmendment`. No other effects.

Pattern after `test/Application/ProcessManagers/TransferManagerSpec.hs` — same fixture style, same `StreamEvent` / `VersionedStreamEvent` construction, same `(^.)` optics for state inspection.

- [ ] **Step 7.3: Run, see compile failure.**

Expected: COMPILE FAIL — module doesn't exist.

- [ ] **Step 7.4: Create the module skeleton.**

Create `src/Application/ProcessManagers/TransferAmendmentManager.hs` modelled exactly on `TransferManager.hs`:

```haskell
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Application.ProcessManagers.TransferAmendmentManager
  ( -- * Types
    TransferAmendmentManager (..),
    TransferAmendmentData (..),
    TransferAmendmentPhase (..),

    -- * Process Manager
    TransferAmendmentProcessManager,
    transferAmendmentProcessManager,

    -- * Projection
    transferAmendmentManagerProjection,

    -- * Internal (exported for testing)
    handleTransferAmendmentEvent,
    reactToTransferAmendmentEvent,
    diffAmendmentLegs,
  )
where

-- imports ...

data TransferAmendmentManager = TransferAmendmentManager
  { amendments :: Map TransactionId TransferAmendmentData
  }
  deriving (Show)

makeFieldLabelsNoPrefix ''TransferAmendmentManager

transferAmendmentManagerDefault :: TransferAmendmentManager
transferAmendmentManagerDefault = TransferAmendmentManager Map.empty
```

The `Eventium` API needs the projection to fold *VersionedStreamEvent AccountingEvent* (the same envelope `TransferManager` consumes). Both the TX stream (`TransferAmendmentInitiated`, `TransferAmendmentCompleted`, `TransferAmendmentFailed`) and the account streams (`AccountDebited`, `AccountDebitReversed`, `AccountCredited`, `AccountCreditReversed`) flow through.

- [ ] **Step 7.5: Implement `handleTransferAmendmentEvent`.**

State updates only — same shape as `TransferManager.handleTransferEvent`:

```haskell
handleTransferAmendmentEvent ::
  TransferAmendmentManager ->
  VersionedStreamEvent AccountingEvent ->
  TransferAmendmentManager
-- Start tracking on TransferAmendmentInitiated; snapshot old values
-- by reading them from a *separate* state source. The PM does NOT
-- have direct access to the TX aggregate's current state — but the
-- TransferAmendmentInitiated payload carries `transactionId` and
-- the *new* values. The *old* values are recovered from the prior
-- TransferInitiated on the same stream (plus any earlier
-- TransferAmendmentCompleted events).
handleTransferAmendmentEvent manager (StreamEvent txUuid _ _ (TransferAmendmentInitiatedEvent evt)) = ...
-- Advance phase on each leg event observed (matching by transactionId).
handleTransferAmendmentEvent manager (StreamEvent _ _ _ (AccountDebitedEvent evt)) = ...
handleTransferAmendmentEvent manager (StreamEvent _ _ _ (AccountDebitReversedEvent evt)) = ...
-- ... etc.
-- Clean up tracking when CompleteTransferAmendment / FailTransferAmendment lands.
handleTransferAmendmentEvent manager (StreamEvent _ _ _ (TransferAmendmentCompletedEvent evt)) =
  manager & #amendments %~ Map.delete evt.transactionId
handleTransferAmendmentEvent manager (StreamEvent _ _ _ (TransferAmendmentFailedEvent _)) = ...
-- TransferInitiated on a stream we don't yet track: also fold its
-- payload so we can recover oldSource/Target on a later amendment.
handleTransferAmendmentEvent manager (StreamEvent _ _ _ (TransferInitiatedEvent evt)) = ...
-- Default no-op.
handleTransferAmendmentEvent manager _ = manager
```

**Key design decision (extends spec §4.5).** The PM tracks `TransferInitiated` payloads in a *separate* map keyed by `TransactionId`, so that when a later `TransferAmendmentInitiated` arrives, the PM can look up the *current* old-source/old-target/old-amounts from the most-recently-amended values. The spec's §4.5 describes only `amendments :: Map TransactionId TransferAmendmentData` — the additional `currentPostings :: Map TransactionId TransferPostings` field is a plan-level extension required because the saga has no other way to recover the *current* posting facts at amend-start. **Flag this in the PR description; update spec §4.5 prose to mention the second map.** Hold both in `TransferAmendmentManager`:

```haskell
data TransferAmendmentManager = TransferAmendmentManager
  { amendments :: Map TransactionId TransferAmendmentData,
    -- | Per-transaction snapshot of the current (post all prior
    -- amendments) canonical posting facts. Updated by
    -- 'TransferInitiated' and 'TransferAmendmentCompleted'; read by
    -- 'reactToTransferAmendmentEvent' when an
    -- 'TransferAmendmentInitiated' arrives to compute the diff.
    currentPostings :: Map TransactionId TransferPostings
  }

data TransferPostings = TransferPostings
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    at :: UTCTime,
    transferType :: TransferType
  }
  deriving (Show, Eq)
```

This mirrors the way `TransferManager` keeps a `Map TransactionId TransferData` — the PM is the right place for this denormalised state because it already needs per-TX context to drive the saga.

- [ ] **Step 7.6: Implement `diffAmendmentLegs`.**

Pure helper:

```haskell
-- | Compute the minimal leg-command set for an amendment.
--
-- See spec §4.2's table. Inputs: snapshot of old postings (source/target
-- account + amount) and the new payload. Output: an ordered list of
-- @AccountingCommand@s plus the optional @CompleteTransferAmendment@
-- payload to emit at the end.
--
-- Concretely the function returns @[LegEffect]@ where 'LegEffect'
-- enumerates the four leg-action kinds plus the meta "fallible: the
-- new-source debit can be rejected, attach compensation".
diffAmendmentLegs :: TransferPostings -> TransferAmendmentInitiated -> [LegEffect]
```

Decision rules (per spec §4.2):

- if `newSourceAccountId == oldSourceAccountId`:
  - if `newSourceAmount > oldSourceAmount`: emit `DebitAccount(oldSource, delta)` (FALLIBLE).
  - if `newSourceAmount < oldSourceAmount`: emit `ReverseAccountDebit(oldSource, |delta|)`.
  - if equal: emit nothing for the source side.
- else (account swap):
  - emit `DebitAccount(newSource, newSourceAmount)` (FALLIBLE), then
  - emit `ReverseAccountDebit(oldSource, oldSourceAmount)`.
- symmetric for target side, but with `ReverseAccountCredit` / `CreditAccount`.
- the FALLIBLE flag attaches the saga compensation: on rejection, issue `FailTransferAmendment` on the TX stream.

Order of the emitted list matters: spec §4.1 prescribes
`DebitNewSource → ReverseAccountCredit(oldTarget) → ReverseAccountDebit(oldSource) → CreditAccount(newTarget)`.

When a side has no action (no change on accounts AND amount unchanged), skip its slot but keep the remaining order.

- [ ] **Step 7.7: Implement `reactToTransferAmendmentEvent`.**

Pure react function returning effects, modelled on `TransferManager.reactToTransferEvent`. The function reacts to:

- `TransferAmendmentInitiated`: look up current postings, run `diffAmendmentLegs`, translate `LegEffect` → `ProcessManagerEffect`. The first FALLIBLE effect uses `IssueCommandWithCompensation`; subsequent effects use `IssueCommand`. The compensation handler issues `FailTransferAmendment` on the TX stream. If `diffAmendmentLegs` returns empty (true identity amend), emit `CompleteTransferAmendment` on the TX stream immediately.
- The final leg's success event (`AccountCreditedEvent` for the new-target, or `AccountDebitReversedEvent` for source-only changes) → emit `CompleteTransferAmendment`.
- All other events: no reaction.

The "final leg" is dynamic — it depends on which side(s) were collapsed. Encode the next-step decision on the phase the projection stamps onto `TransferAmendmentData`: when we transition to the last phase, the next react fires `CompleteTransferAmendment`.

Adopt this pattern: `reactToTransferAmendmentEvent` queries `phase` and uses it to decide. The projection's `handleTransferAmendmentEvent` advances `phase` as each leg event lands.

- [ ] **Step 7.8: Wire the projection and process manager.**

```haskell
transferAmendmentManagerProjection ::
  Projection TransferAmendmentManager (VersionedStreamEvent AccountingEvent)
transferAmendmentManagerProjection =
  Projection
    transferAmendmentManagerDefault
    handleTransferAmendmentEvent

type TransferAmendmentProcessManager =
  ProcessManager TransferAmendmentManager AccountingEvent AccountingCommand

transferAmendmentProcessManager :: TransferAmendmentProcessManager
transferAmendmentProcessManager =
  ProcessManager
    transferAmendmentManagerProjection
    reactToTransferAmendmentEvent
```

- [ ] **Step 7.9: Re-export from `Application.ProcessManagers`.**

In `src/Application/ProcessManagers.hs`, add:

```haskell
import Application.ProcessManagers.TransferAmendmentManager as X
```

and update the haddock at the top of the file to mention the new manager.

- [ ] **Step 7.10: Run the saga unit tests, see them pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.ProcessManagers.TransferAmendmentManager/"`
Expected: PASS — covering each row of spec §4.2 plus the failure path.

- [ ] **Step 7.11: Add the property test.**

Create `test/Application/ProcessManagers/TransferAmendmentManagerPropertySpec.hs`:

```haskell
spec :: Spec
spec = describe "Diff property" $ do
  prop "net effect on source account equals (newSrc - oldSrc)" $ \old new ->
    let legs = diffAmendmentLegs old new
        netSrc = ... -- sum of +DebitAccount, -ReverseAccountDebit
     in netSrc === unMoney new.newSourceAmount - unMoney old.sourceAmount

  prop "net effect on target account equals (newTgt - oldTgt)" ...

  prop "account swap forces a 4-leg ordering" $ \old new ->
    old.sourceAccountId /= new.newSourceAccountId
      && old.targetAccountId /= new.newTargetAccountId
      ==> length (diffAmendmentLegs old new) === 4

  prop "no change at all → empty diff" $ \old amendedBy ->
    let new = identityAmendment old amendedBy
     in diffAmendmentLegs old new === []
```

- [ ] **Step 7.12: Run all PM tests.**

Run: `cabal test all --test-option='--match' --test-option="/Application.ProcessManagers/"`
Expected: PASS (existing `TransferManagerSpec` unaffected).

- [ ] **Step 7.13: `just check`.**

- [ ] **Step 7.14: Commit.**

```bash
git add src/Application/ProcessManagers/TransferAmendmentManager.hs src/Application/ProcessManagers.hs test/Application/ProcessManagers/TransferAmendmentManagerSpec.hs test/Application/ProcessManagers/TransferAmendmentManagerPropertySpec.hs
git commit -m "feat(transactions): TransferAmendmentManager process manager

A sibling of TransferManager. On TransferAmendmentInitiated, diffs the
snapshotted old postings against the new payload (per spec §4.2's
table) and issues the minimum set of leg commands in order. The
new-source debit is fallible; compensation issues
FailTransferAmendment. Other legs are guaranteed-success. On the
final leg's success the PM emits CompleteTransferAmendment.

State is tracked per-TX in two maps: amendments (in-flight saga state)
and currentPostings (the current canonical posting snapshot used to
compute the diff for the *next* amendment).

Refs #81"
```

> **Identity-amend resolution (was an open question; resolved before kickoff).** Spec §4.3 demands "no events at all, `amendmentCount` unchanged" on a no-op. The saga can't honour this if it ever sees an `AmendTransfer` for an identity payload, because the projection's `amendmentInProgress` flag would be left stuck-on. **Resolution:** the *service layer* (Task 11) computes the diff against current canonical state and returns the existing `TransactionData` unchanged when the diff is empty — `AmendTransfer` is never dispatched. The pure command handler, the saga, and the projection stay clean of identity-case special handling. Update the spec's §4.3 prose to reflect "the service layer short-circuits" rather than "the saga short-circuits" — flag in PR review.

---

## Task 8 — Account read model: fold reversal events

**Files:**
- Modify: `src/Application/ReadModels/Account.hs`
- Test: `test/Application/ReadModels/AmendmentBalanceSpec.hs`

- [ ] **Step 8.1: Write the failing test.**

Create `test/Application/ReadModels/AmendmentBalanceSpec.hs`:

```haskell
spec :: Spec
spec = describe "Account read model — reversal events" $ do
  it "AccountDebitReversed adds back to the live balance" $ do
    -- Apply: AccountCreated (1000) → AccountDebited (200, txA) →
    --        AccountDebitReversed (200, txA)
    -- Expected current balance: 1000.
    ...

  it "AccountCreditReversed subtracts from the live balance" $ do
    -- Apply: AccountCreated (0) → AccountCredited (100, txA) →
    --        AccountCreditReversed (100, txA)
    -- Expected current balance: 0.
    ...

  it "AccountCreditReversed can take the balance negative" $ do
    -- Apply: AccountCreated (0) → AccountCredited (100, txA) →
    --        AccountDebited (80, txB) →  -- spent
    --        AccountCreditReversed (100, txA)
    -- Expected: -80.
    ...

  it "balanceAsOf folds reversals symmetrically" $ do
    -- balanceAsOf cutoff (lookup) on a stream with an AccountDebitReversed
    -- whose effective at <= cutoff adds the amount back; with at > cutoff
    -- the reversal is skipped.
    ...
```

Use the same `processEvent` / `handleAccountEvents` plumbing as `test/Application/ReadModels/AccountReadModelSpec.hs` (or whatever the current file is — verify with `ls test/Application/ReadModels/`).

- [ ] **Step 8.2: Run, see fail.**

Expected: FAIL — reversal events not yet folded.

- [ ] **Step 8.3: Extend `processEvent` in `src/Application/ReadModels/Account.hs`.**

After the `AccountCreditedEvent` arm:

```haskell
        AccountDebitReversedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    case addMoney account.balance evt.amount of
                      Right newBalance ->
                        account
                          { balance = newBalance,
                            version = account.version + 1
                          }
                      Left _ -> account
                )
                accountId
                accounts
        AccountCreditReversedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> accounts
            Just accountId ->
              Map.adjust
                ( \account ->
                    case subtractMoney account.balance evt.amount of
                      Right newBalance ->
                        account
                          { balance = newBalance,
                            version = account.version + 1
                          }
                      Left _ -> account
                )
                accountId
                accounts
```

- [ ] **Step 8.4: Extend `foldBalanceAsOf` / `applyAsOf`.**

```haskell
applyAsOf cutoff lookup_ bal (AccountDebitReversedEvent e)
  | Just effectiveAt <- lookup_ e.transactionId,
    effectiveAt <= cutoff =
      case addMoney bal e.amount of
        Right newBal -> newBal
        Left _ -> bal
applyAsOf cutoff lookup_ bal (AccountCreditReversedEvent e)
  | Just effectiveAt <- lookup_ e.transactionId,
    effectiveAt <= cutoff =
      case subtractMoney bal e.amount of
        Right newBal -> newBal
        Left _ -> bal
```

- [ ] **Step 8.5: Add imports for `AccountDebitReversed`, `AccountCreditReversed`.**

- [ ] **Step 8.6: Run tests, see pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.ReadModels.AmendmentBalance/"`
Expected: PASS.

- [ ] **Step 8.7: Run all read-model tests.**

Run: `cabal test all --test-option='--match' --test-option="/Application.ReadModels/"`
Expected: PASS.

- [ ] **Step 8.8: `just check`.**

- [ ] **Step 8.9: Commit.**

```bash
git add src/Application/ReadModels/Account.hs test/Application/ReadModels/AmendmentBalanceSpec.hs
git commit -m "feat(read-model): fold reversal events in account read model

handleAccountEvents and foldBalanceAsOf now fold AccountDebitReversed
(adds back) and AccountCreditReversed (subtracts) symmetrically. No
overdraft check on either fold — a reversal records the undo of a
fact, and the live read model must reflect that truthfully.

Refs #81"
```

---

## Task 9 — Transaction read model: amendmentCount + amendment events

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Test: extend the existing transaction read-model spec (covered transitively by Task 13's integration test if no dedicated unit file exists; verify).

- [ ] **Step 9.1: Add the field to `TransactionData`.**

```haskell
data TransactionData = TransactionData
  { ...,
    -- (existing fields, including `date`),
    ...,
    -- | Count of 'TransferAmendmentCompleted' events folded on this
    -- transaction. @0@ when never amended.
    amendmentCount :: Word
  }
```

Default `amendmentCount = 0` in the `TransferInitiatedEvent` branch of `processEvent`.

- [ ] **Step 9.2: Fold the amendment events.**

In `processEvent`, after the `TransactionDateChangedEvent` arm:

```haskell
        TransferAmendmentInitiatedEvent _evt ->
          transactions -- no canonical change; saga-internal marker
        TransferAmendmentCompletedEvent evt ->
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
                        transferType = evt.newTransferType,
                        amendmentCount = transaction.amendmentCount + 1
                      }
                )
                transactionId
                transactions
        TransferAmendmentFailedEvent _evt ->
          transactions -- informational; no canonical change
```

Add to the pattern-match imports from `Domain.Models`:

```haskell
import Domain.Models
  ( AccountingEvent
      ( ...,
        TransferAmendmentCompletedEvent,
        TransferAmendmentFailedEvent,
        TransferAmendmentInitiatedEvent
      ),
  )
```

And the payload-record imports:

```haskell
import Domain.Transaction.Events
  ( ...,
    TransferAmendmentCompleted (..),
  )
```

- [ ] **Step 9.3: Build green.**

Run: `just build`
Expected: PASS.

- [ ] **Step 9.4: Commit.**

```bash
git add src/Application/ReadModels/Transaction.hs
git commit -m "feat(read-model): fold amendment events in transaction read model

TransactionData gains amendmentCount :: Word.
TransferAmendmentCompleted replaces the canonical posting fields and
bumps the count; the other two amendment events are no-ops at the
read-model level.

Refs #81"
```

---

## Task 10 — Audit history read service

**Files:**
- Create: `src/Application/Services/TransactionHistoryService.hs`
- Test: `test/Application/Services/TransactionHistoryServiceSpec.hs`

- [ ] **Step 10.1: Sketch the public DTO and service signature.**

```haskell
module Application.Services.TransactionHistoryService
  ( getTransactionHistory,
    TransactionHistory (..),
    TransactionHistoryEntry (..),
  )
where

data TransactionHistory = TransactionHistory
  { transactionId :: TransactionId,
    entries :: [TransactionHistoryEntry]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionHistory
instance FromJSON TransactionHistory

-- | A single entry in the audit history. Constructors mirror the
-- events that move the TX aggregate's state; account-leg events are
-- *not* exposed here — the audit endpoint is per-transaction, and
-- account leg events live on the account streams.
--
-- Sorted chronologically by Eventium event version.
data TransactionHistoryEntry
  = HistoryInitiated TransferInitiated
  | HistoryCompleted
  | HistoryFailed TransferFailed
  | HistoryLabelsSet TransactionLabelsSet
  | HistoryCategoryChanged TransactionCategoryChanged
  | HistoryDescriptionChanged TransactionDescriptionChanged
  | HistoryDateChanged TransactionDateChanged
  | HistoryAmendmentInitiated TransferAmendmentInitiated
  | HistoryAmendmentCompleted TransferAmendmentCompleted
  | HistoryAmendmentFailed TransferAmendmentFailed
  deriving (Show, Eq, Generic)

instance ToJSON TransactionHistoryEntry
instance FromJSON TransactionHistoryEntry

getTransactionHistory ::
  UserId ->
  TransactionId ->
  AppM (Either DomainError (Maybe TransactionHistory))
```

- [ ] **Step 10.2: Write the failing test.**

Create `test/Application/Services/TransactionHistoryServiceSpec.hs`. Synthesise an event stream covering:

1. `TransferInitiated`
2. `TransferCompleted`
3. `TransactionLabelsSet`
4. `TransferAmendmentInitiated`
5. `TransferAmendmentCompleted`

and assert `getTransactionHistory` returns exactly the matching list in order.

Also test: an `AccessDenied`-style filter when the requesting user has no access to either current source/target — match the access rule used by `ensureEditorAccess`, but relaxed to Editor *or* Viewer (per spec §6.2).

- [ ] **Step 10.3: Implement the service.**

```haskell
getTransactionHistory userId transactionId = runExceptT $ do
  txnRM <- lift (view transactionReadModelL)
  transaction <-
    liftMaybeM
      (NotFound "Transaction" (tshow transactionId))
      (liftIO (ReadModel.getTransaction txnRM transactionId))
  -- Access: caller has at least one of Viewer/Editor/Owner on either
  -- the current source or target account.
  accountRM <- lift (view accountReadModelL)
  ...
  guardE allowed (AccountError "User does not have access to this transaction")
  -- Read the stream directly; audit views are low-frequency and need
  -- the canonical stream rather than a denormalised snapshot.
  reader <- lift (view transactionEventStoreReaderL)
  events <-
    liftIO
      $ readEvents reader (allEvents (unTransactionId transactionId))
  let entries = map toHistoryEntry events
  pure (Just (TransactionHistory transactionId entries))
```

Use `transactionEventStoreReaderL` from `Infrastructure.App` (or whatever the equivalent versioned reader for `TransactionEvent` is — verify; if it doesn't exist yet add a `HasTransactionEventStoreReader` class capability and wire it in `app/Main.hs` next to the existing readers).

Implement `toHistoryEntry :: VersionedStreamEvent TransactionEvent -> TransactionHistoryEntry` as a straight pattern match over the TX-event constructors.

- [ ] **Step 10.4: Run service tests, see pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.TransactionHistoryService/"`
Expected: PASS.

- [ ] **Step 10.5: `just check`.**

- [ ] **Step 10.6: Commit.**

```bash
git add src/Application/Services/TransactionHistoryService.hs src/Infrastructure/App.hs app/Main.hs test/Application/Services/TransactionHistoryServiceSpec.hs
git commit -m "feat(transactions): audit-history read service

Adds getTransactionHistory, backed by a direct event-store read on
the TX aggregate's stream (not a cached projection). Returns the full
ordered list of TX-aggregate events as a TransactionHistory DTO.
Access requires at least Viewer on one of the current source/target
accounts.

Refs #81"
```

---

## Task 11 — Service layer: amendTransfer orchestration

The largest task. Orchestrates auth, books-close, account-type-vs-transferType validation, command dispatch, and synchronous wait for the saga.

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`
- Test: `test/Application/Services/TransactionAmendmentSpec.hs`

- [ ] **Step 11.1: Write the failing service tests.**

Create `test/Application/Services/TransactionAmendmentSpec.hs`. Use the in-memory event store (`Testkit/InMemoryEventStore.hs`) and follow the shape of `test/Application/Services/TransactionMetadataEditSpec.hs`. Cover:

- **Happy path (amount only)**: setup a Completed Income; user has Editor on the regular account; amend to a higher amount; assert the new source-account balance equals (previous balance − Δ), the target-account balance equals (previous + Δ), and the TX read model reflects the new amounts plus `amendmentCount = 1`.
- **Happy path (target swap)**: amend a Transfer's target to a different regular account; assert old target balance restored, new target balance bumped.
- **Auth failure**: user lacks Editor on the new target → `AccessDenied`-flavoured error (use the same `AccountError` shape `ensureEditorAccess` returns).
- **Books-close gate**: cutoff is set above the TX's `at` → `CannotEditClosedPeriod`.
- **Same-account pair**: `newSourceAccountId == newTargetAccountId` → `CannotAmendToSameAccountPair` (surfaced from the pure handler).
- **Zero amount**: → `CannotAmendToZeroAmount`.
- **TransferType across External boundary mismatch**: amend a Regular→Regular transfer to make target an External account but keep `newTransferType = Transfer` → `CannotAmendTransferTypeAcrossExternalBoundary`.
- **Insufficient funds**: the new source can't cover the new debit → service returns `InsufficientFundsForAmendment <reason>`; assert no leg events landed on the old accounts (the original transfer is intact).
- **Identity no-op**: payload equals current state → returns the current `TransactionData` *unchanged* (same `amendmentCount`, same posting fields). No events are written to either the TX stream or any account stream. Verify by reading the post-call TX stream length: it equals the pre-call length.
- **Category validity on transfer-type change**: amend a Transfer to an Income; supply an unknown category id in `newTransferType` → `CategoryNotFound`.

- [ ] **Step 11.2: Run, see compile failure.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.TransactionAmendment/"`
Expected: COMPILE FAIL — `amendTransfer` not defined.

- [ ] **Step 11.3: Implement `amendTransfer`.**

In `src/Application/Services/TransactionService.hs`:

```haskell
-- | Amend a completed transfer's posting facts.
--
-- See @docs/specs/2026-05-20-transfer-amendment-saga-design.md@ §3.1
-- and §6.1.
--
-- Orchestration:
--   1. Load the transaction; require it exists.
--   2. Authorize: caller has Editor+ on each of the four accounts
--      (old source, old target, new source, new target).
--   3. Books-close gate against the TX's current 'at' (single check
--      — the reversing and forward leg events all carry the same 'at').
--   4. Validate the new account / transferType pairing per spec §3.5.
--   5. If the new transferType carries a category id (Income / Expense),
--      verify the id exists in the user's dictionary.
--   6. Dispatch 'AmendTransfer'. The pure handler rejects same-account
--      and zero-amount payloads.
--   7. Synchronously wait for the saga to emit
--      'TransferAmendmentCompleted' or 'TransferAmendmentFailed' on
--      the TX stream, then return the post-amendment read-model entry.
--   8. On 'TransferAmendmentFailed', surface 'InsufficientFundsForAmendment'.
amendTransfer ::
  UserId ->
  TransactionId ->
  AmendTransfer ->
  AppM (Either DomainError TransactionData)
```

Implementation sketch (mirror `setTransactionLabels` for the top half; `initiateTransfer`'s dispatch-then-query pattern for the saga half — Eventium's event-bus dispatch runs synchronously to depth before `runTransactionCmd` returns, so by the time the dispatch helper hands back, the saga has finished and `TransferAmendmentCompleted` / `TransferAmendmentFailed` is already in the TX read model):

```haskell
amendTransfer userId transactionId amendCmd = runExceptT $ do
  lift $ logInfo $ "Amending transaction " <> displayShow transactionId
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  ExceptT (ensureEditorOnNewAccounts userId
             amendCmd.newSourceAccountId
             amendCmd.newTargetAccountId)
  ExceptT (validateTransferTypeAcrossBoundary
             amendCmd.newSourceAccountId
             amendCmd.newTargetAccountId
             amendCmd.newTransferType)
  ExceptT (validateCategoryIfApplicable userId amendCmd.newTransferType)
  -- Identity short-circuit (spec §4.3): if the payload exactly matches
  -- the current canonical state, do not dispatch — return the read-model
  -- entry unchanged. Compares accounts, amounts, exchange rate, and
  -- transferType.
  if isIdentityAmend transaction amendCmd
    then pure transaction
    else do
      let cmd = AmendTransferTransactionCommand amendCmd
      ExceptT (dispatchAndAwaitAmendment transactionId cmd)
```

Where `isIdentityAmend :: TransactionData -> AmendTransfer -> Bool` is a pure helper checking all six replace-value fields for equality.

`dispatchAndAwaitAmendment`:

```haskell
dispatchAndAwaitAmendment txId cmd = runExceptT $ do
  -- Dispatch is synchronous w.r.t. the in-process event bus: by the
  -- time runTransactionCmd returns, the process manager has reacted
  -- to every event emitted by the command (including transitively).
  -- This is the same pattern initiateTransfer uses.
  runTransactionCmd translateTransactionError id (unTransactionId txId) cmd
  (_, td) <- ExceptT (queryTransactionResult txId)
  -- Distinguish success / failure of the saga: a fresh
  -- TransferAmendmentFailed event will sit at the head of the TX
  -- aggregate's stream. Re-read it.
  outcome <- ExceptT (readLastAmendmentOutcome txId)
  case outcome of
    AmendmentSucceeded -> pure td
    AmendmentFailed reason ->
      throwE (InsufficientFundsForAmendment reason)
```

`readLastAmendmentOutcome` queries the TX event store reader (the same `transactionEventStoreReaderL` capability Task 10 adds) and inspects the most-recent amendment-terminating event. If the last `TransferAmendment*` event is `TransferAmendmentCompleted`, succeed; if `TransferAmendmentFailed`, return the reason.

Three new private helpers (all in the same module):

- `ensureEditorOnNewAccounts userId newSrc newTgt` — checks that the caller is Editor or Owner on each. Pattern after the existing `canModifyAccount` call inside `ensureEditorAccess` but for two specific accounts. Returns `AccountError "..."` on failure.

- `validateTransferTypeAcrossBoundary newSrc newTgt newType` — looks up both accounts in the account read model; matches their `accountType` (Regular vs External) against `newType` per spec §3.5's table:

    | new source | new target | required newTransferType  |
    | ---------- | ---------- | ------------------------- |
    | External   | Regular    | `Income categoryId`       |
    | Regular    | External   | `Expense categoryId`      |
    | Regular    | Regular    | `Transfer`                |
    | External   | External   | (rejected as the "boundary" case) |

  Mismatch returns `CannotAmendTransferTypeAcrossExternalBoundary`. `Adjustment` is invalid as `newTransferType` — reject the same way.

- `validateCategoryIfApplicable userId newType` — if `newType` is `Income catId` / `Expense catId`, verify `catId` is in the user's income/expense dictionary respectively (re-use `categoryExists`). Return `CategoryNotFound` on miss.

- `dispatchAndAwaitAmendment txId cmd` — see the concrete sketch above. **No polling, no subscription wait, no sleep.** Eventium's in-process event bus dispatches synchronously and depth-first: by the time `runTransactionCmd` returns, every event the command emitted has been delivered to every subscribed process manager, and every command that PM issued has itself completed (transitively). This is the same pattern `initiateTransfer` already relies on (see `src/Application/Services/TransactionService.hs:149-154` — it issues `InitiateTransferTransactionCommand` then queries the read model directly, with no wait, and the existing `TransferWorkflowSpec.hs` integration test confirms the credit / debit / complete events have already landed by then).

  After `runTransactionCmd` returns, query the read model with `queryTransactionResult` (already in the module). To distinguish saga success from saga failure, read the TX aggregate's event stream via the versioned `EventStoreReader` (the same capability Task 10 adds for the audit endpoint) and inspect the most-recent `TransferAmendment*` event. If `TransferAmendmentCompleted`, return `Right td`. If `TransferAmendmentFailed reason`, return `Left (InsufficientFundsForAmendment reason)`. (Distinguishing on `amendmentCount` alone is brittle if the read model lags; reading the stream is authoritative.)

- [ ] **Step 11.4: Translate `NoAmendmentInProgress` in `translateTransactionError`** (added earlier in Step 5.7 if not done):

```haskell
translateTransactionError (CommandRejected TxCh.NoAmendmentInProgress) =
  TransactionError "No amendment in progress"
```

This case should be unreachable in valid streams (the PM never issues completion/failure commands without a prior `TransferAmendmentInitiated`); the translation exists so the type system doesn't complain.

- [ ] **Step 11.5: Run service tests, see them pass.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services.TransactionAmendment/"`
Expected: PASS.

- [ ] **Step 11.6: Run the full Services bucket.**

Run: `cabal test all --test-option='--match' --test-option="/Application.Services/"`
Expected: PASS (existing labels/category/description/date services unaffected).

- [ ] **Step 11.7: `just check`.**

- [ ] **Step 11.8: Commit.**

```bash
git add src/Application/Services/TransactionService.hs test/Application/Services/TransactionAmendmentSpec.hs
git commit -m "feat(transactions): amendTransfer service orchestration

Wires the amendment endpoint:
  - Editor+ on all four affected accounts (old source/target +
    new source/target)
  - books-close gate against the TX's current 'at'
  - account-type vs newTransferType validation (spec §3.5)
  - category-id validity when newTransferType carries one
  - dispatch AmendTransfer; await the saga's
    TransferAmendmentCompleted or TransferAmendmentFailed; surface
    InsufficientFundsForAmendment on the failure path.

Refs #81"
```

---

## Task 12 — Web layer: amendment + audit endpoints + TransactionResponse field

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/TransactionAPI.hs`

- [ ] **Step 12.1: Add `AmendTransactionRequest`.**

In `src/Web/Types.hs`:

```haskell
-- | Body for PUT /api/transactions/:id/amendment.
--
-- Replaces the transaction's posting facts. The client supplies the
-- complete desired end-state; the saga computes the diff.
data AmendTransactionRequest = AmendTransactionRequest
  { sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount :: Double,
    sourceCurrency :: Text,
    targetAmount :: Double,
    targetCurrency :: Text,
    exchangeRate :: Maybe Double,
    -- | "income" | "expense" | "transfer". Income/Expense additionally
    -- require the @category@ field.
    transferType :: Text,
    category :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AmendTransactionRequest
instance FromJSON AmendTransactionRequest
```

Match the existing `InternalTransferRequest` for the currency / amount / exchangeRate fields.

- [ ] **Step 12.2: Add `TransactionHistoryResponse`.**

```haskell
-- | Audit-history response. Each entry tags itself with the kind of
-- TX-aggregate event it represents. Account-leg events are intentionally
-- not included.
data TransactionHistoryResponse = TransactionHistoryResponse
  { transactionId :: UUID,
    entries :: [Value] -- raw ToJSON of TransactionHistoryEntry
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionHistoryResponse
instance FromJSON TransactionHistoryResponse
```

Actually simpler: re-use the service-layer `TransactionHistory` directly as the response body since its `ToJSON` already produces the right shape. Verify that's preferable; if so, drop `TransactionHistoryResponse` entirely.

Decision: **import and re-export `TransactionHistory` from the service module as the response type.** Avoid a second DTO.

- [ ] **Step 12.3: Extend `TransactionResponse`.**

```haskell
data TransactionResponse = TransactionResponse
  { ...,
    -- (existing fields),
    ...,
    amendmentCount :: Word
  }
```

In `fromTransactionData`:

```haskell
  amendmentCount = td.amendmentCount
```

(Need to import `Word` if not present — it's from `Prelude` / `RIO`.)

- [ ] **Step 12.4: Add routes to `TransactionAPI`.**

In `src/Web/API/TransactionAPI.hs`, alongside `/labels`, `/category`, `/description`, `/date`:

```haskell
    -- PUT /api/transactions/:id/amendment - Amend posting facts.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "amendment"
      :> ReqBody '[JSON] AmendTransactionRequest
      :> Put '[JSON] TransactionResponse
    -- GET /api/transactions/:id/history - Audit history.
    :<|> AuthProtect "jwt"
      :> "api"
      :> "transactions"
      :> Capture "id" UUID
      :> "history"
      :> Get '[JSON] TransactionHistory
```

Update `transactionServer` to wire the two new handlers.

- [ ] **Step 12.5: Add the handlers.**

```haskell
amendmentHandler ::
  AuthenticatedUser ->
  UUID ->
  AmendTransactionRequest ->
  AppM TransactionResponse
amendmentHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  newSource <- validateField "sourceAccountId" $ mkAccountId req.sourceAccountId
  newTarget <- validateField "targetAccountId" $ mkAccountId req.targetAccountId
  srcCur <- validateField "sourceCurrency" $ parseCurrency req.sourceCurrency
  tgtCur <- validateField "targetCurrency" $ parseCurrency req.targetCurrency
  let srcMoney = toDomainMoney srcCur req.sourceAmount
      tgtMoney = toDomainMoney tgtCur req.targetAmount
  newType <- validateField "transferType" $ parseTransferType req.transferType req.category
  maybeRate <- validateField "exchangeRate" $ parseOptionalExchangeRate srcCur tgtCur req.exchangeRate
  let cmd =
        AmendTransfer
          { transactionId = transactionId,
            newSourceAccountId = newSource,
            newTargetAccountId = newTarget,
            newSourceAmount = srcMoney,
            newTargetAmount = tgtMoney,
            newExchangeRate = maybeRate,
            newTransferType = newType,
            amendedBy = user.userId
          }
  result <- TransactionService.amendTransfer user.userId transactionId cmd
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

historyHandler ::
  AuthenticatedUser ->
  UUID ->
  AppM TransactionHistory
historyHandler user rawId = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  result <- TransactionHistoryService.getTransactionHistory user.userId transactionId
  case result of
    Right (Just history) -> pure history
    Right Nothing -> throwDomainError (NotFound "Transaction" (tshow transactionId))
    Left err -> throwDomainError err
```

Add `parseTransferType` and `parseOptionalExchangeRate` helpers to `Web.Validation` or `Web.Types` if they don't exist yet — verify against the existing creation handlers for the conventions. (`parseCategoryId` is already there.)

- [ ] **Step 12.6: Update the haddock at the top of `TransactionAPI` to list the new endpoints.**

- [ ] **Step 12.7: Build green.**

Run: `just build`
Expected: PASS.

- [ ] **Step 12.8: Commit.**

```bash
git add src/Web/Types.hs src/Web/API/TransactionAPI.hs
git commit -m "feat(api): PUT /api/transactions/:id/amendment + GET .../history

Adds the two endpoints from spec §6. Synchronous response semantics
on amendment (blocks until the saga emits Completed/Failed). The
audit-history endpoint returns the canonical TX-stream events.
TransactionResponse gains amendmentCount :: Word.

Refs #81"
```

---

## Task 13 — Wire the process manager in Main.hs

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 13.1: Wire `transferAmendmentProcessManager`.**

Find the existing `wireProcessManager transferProcessManager` call. Add a sibling call for the amendment manager — both managers run against the same accounting event store and global stream.

```haskell
          (wireProcessManager transferProcessManager)
          (wireProcessManager transferAmendmentProcessManager)
```

(Verify the exact wiring shape — `wireProcessManager` may be combined via `(<>)` of `EventHandler` or by passing multiple in a list. Mirror whatever the existing single-PM wiring does.)

Add the import:

```haskell
import Application.ProcessManagers (transferProcessManager, transferAmendmentProcessManager)
```

- [ ] **Step 13.2: Build green.**

Run: `just build`
Expected: PASS.

- [ ] **Step 13.3: Boot smoke test (optional, not a commit gate).**

Run: `just run` (foreground). Confirm the server starts and the HTTP listener binds; press `Ctrl-C` to stop. This is a sanity check that the PM doesn't deadlock the bootstrap. The integration tests in Task 14 are the load-bearing verification.

- [ ] **Step 13.4: Commit.**

```bash
git add app/Main.hs
git commit -m "feat(main): wire TransferAmendmentManager process manager

Refs #81"
```

---

## Task 14 — Integration tests

End-to-end scenarios from spec §7.

**Files:**
- Test: `test/Integration/TransferAmendmentIntegrationSpec.hs`

- [ ] **Step 14.1: Write the spec.**

Create `test/Integration/TransferAmendmentIntegrationSpec.hs` modelled on `test/Integration/TransactionMetadataEditIntegrationSpec.hs`. Cover, in order:

1. **Amount-only amend on Income** (collapsed delta legs): create a $100 Income on a USD regular account; amend to $150; verify regular-account balance shifted by +$50; verify `amendmentCount = 1`.
2. **Amount-only amend, decreasing**: create $100, amend to $60; verify a `ReverseAccountDebit` (or symmetric) lands; balance shifted by −$40.
3. **Source swap**: create a Transfer A→B for $50; amend to C→B for $50; verify A's balance restored, C's debited.
4. **Target swap**: A→B amended to A→D.
5. **Both accounts swap (full 4-leg saga)**: A→B amended to C→D.
6. **Identity amend (no-op)**: amend with the same payload; response equals the pre-call TX state (same `amendmentCount`, same posting fields). Assert the TX event-stream length is unchanged after the call.
7. **TransferType flip across External boundary**: create a Transfer A→B; amend to A→external with `newTransferType = Expense someCat` → succeeds (Regular→External + Expense = legal).
8. **Same flip but with wrong transferType**: amend Transfer to External target but keep `transferType = Transfer` → 409 `CANNOT_AMEND_TRANSFER_TYPE_ACROSS_EXTERNAL_BOUNDARY`.
9. **Amend on Pending TX**: 409 `TRANSACTION_NOT_COMPLETED`.
10. **Insufficient funds on new source**: amend so that the new source's balance can't cover the new debit → 409 `INSUFFICIENT_FUNDS_FOR_AMENDMENT`. Verify original transfer is untouched (read the TX read-model `amendmentCount` is unchanged on the failure-path resolution).
11. **Books-close gate**: close books through 2026-03-31; create a TX with `at = 2026-04-10`, then close further through 2026-04-15; attempt to amend → 409 `CANNOT_EDIT_CLOSED_PERIOD`.
12. **Audit endpoint**: after a successful amend, `GET /api/transactions/:id/history` returns an entries list that includes `HistoryInitiated`, `HistoryCompleted`, `HistoryAmendmentInitiated`, `HistoryAmendmentCompleted` in order.
13. **Reversal-on-spent-target scenario (spec §7)**: target had been credited $100; another transfer spent $80 from it; amend the original to a different target; verify the old target's balance goes to −$80 (the spent portion is now unbacked, accurately reflected).

Use the existing HTTP integration harness (see `test/Integration/TransactionMetadataEditIntegrationSpec.hs` for setup helpers).

- [ ] **Step 14.2: Run, see them fail / pass.**

Run: `cabal test all --test-option='--match' --test-option="/Integration.TransferAmendment/"`
Expected: PASS once the integration scenarios match the implementation. If any specific scenario hits an unintended divergence (especially around the no-op / identity case from Task 7's open question), document the divergence in the PR and either update the spec or adjust the implementation.

- [ ] **Step 14.3: Run the full suite.**

Run: `just test`
Expected: PASS.

- [ ] **Step 14.4: `just check`.**

- [ ] **Step 14.5: Commit.**

```bash
git add test/Integration/TransferAmendmentIntegrationSpec.hs
git commit -m "test(integration): transfer amendment end-to-end

Covers each amendment shape from spec §7, plus the audit endpoint and
the reversal-on-spent-target scenario.

Refs #81"
```

---

## Task 15 — Verification + draft PR follow-up

- [ ] **Step 15.1: Full test run.**

```bash
just build
just test
just check
```

Expected: PASS at every step. Use `superpowers:verification-before-completion` to ensure no claim of "done" is made without evidence.

- [ ] **Step 15.2: Self-review the diff.**

```bash
git log --oneline master..HEAD
git diff master --stat
```

Confirm every new file maps to a spec section; no surprise edits. Pay special attention to:

- The identity-amend short-circuit is at the service edge (Task 11), not in the saga. The saga never receives a no-op `TransferAmendmentInitiated`.
- The `amendmentInProgress` flag on `Transaction`: confirm it's a *transient* projection field (no JSON exposure on `TransactionResponse`) and that the read model does NOT expose it either.
- The `at` on reversal events: confirm every saga-emitted reversal carries the TX-aggregate's *current* `at` (post any prior `TransactionDateChanged` edits), not the original leg's `at`.

- [ ] **Step 15.3: Push and mark PR #82 ready.**

```bash
git push
gh pr ready 82
```

(Decision deferred to user — do not flip from draft to ready without explicit confirmation. Default: leave as draft and surface to the user.)

- [ ] **Step 15.4: Update spec frontmatter status.**

In `docs/specs/2026-05-20-transfer-amendment-saga-design.md`, flip `status: draft` → `status: in-progress` once Task 1 commits, then to `completed` at the end. Use a separate, dedicated commit per status change so the spec history reads cleanly.

---

## Cross-cutting checks (run after each task; not their own task)

- After Task 2: `grep -n "AccountDebitReversed\|AccountCreditReversed" src/` returns hits in `Domain/Account/Events.hs` and `Domain/Account/Projection.hs` only; no spurious references elsewhere.
- After Task 3: the saga-only commands aren't exposed via any HTTP route — `grep -rn "ReverseAccountDebit\|ReverseAccountCredit" src/Web/` returns nothing.
- After Task 6: the projection's `amendmentInProgress` field is set/cleared as expected by every event arm — single source of truth is the `handleTransactionEvent` function.
- After Task 7: pure-saga tests cover each row of spec §4.2 individually; no row is unaddressed.
- After Task 9: the read model exposes `amendmentCount`, not `amendmentInProgress`.
- After Task 12: `TransactionResponse` round-trips: encode → decode → encode gives the same bytes. (Property test if helpful.)
- After Task 13: the PM is genuinely wired — manually verify by booting the server, creating an Income via the HTTP API, amending it via the new endpoint, and confirming the response has `amendmentCount = 1`.

## Order-of-operations notes

- Task 1 lands first — every subsequent task uses the new `DomainError` constructors.
- Tasks 2–3 (account side) are independent of Tasks 4–6 (transaction side) and can be parallelised.
- Task 7 (the saga) depends on Tasks 2–6 — without the events / commands / projection it has nothing to issue / fold.
- Tasks 8–9 (read models) depend on Tasks 2 / 6 respectively.
- Task 10 (audit) is independent of Tasks 2–9 once Tasks 4–6 land.
- Task 11 (service) depends on Tasks 5, 6, 7.
- Task 12 (web) depends on Task 10 (audit) and Task 11 (amend).
- Task 13 (wiring) depends on Task 7.
- Task 14 (integration) depends on Task 13.
- Suggested linear order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14 → 15.
- Tasks are deliberately small (~20–40 minutes of focused work each, except Tasks 7 and 11 which are 1–2 hours). Subagent-driven execution is recommended; if running inline, take an explicit checkpoint after Tasks 3, 6, 7, 11, and 14.
