---
status: completed
date: 2026-06-02
issue: homeaccounting/backend#93
supersedes:
  - homeaccounting/backend#93
---

# Transaction naming consistency

## Problem

The codebase mixes two naming conventions for transaction-stream
events, commands, and types.

`Transfer*` family — the original saga vocabulary, born when the only
posting kind was the Regular→Regular Transfer:

- Type: `TransferType` (a sum with constructors `Income | Expense |
  Transfer | Adjustment`) and its tag-only projection `TransferKind`.
- Field: `transferType :: TransferType` on the `Transaction`
  aggregate and on the `TransferInitiated` event payload.
- Posting-saga events: `TransferInitiated`, `TransferCompleted`,
  `TransferFailed`.
- Posting-saga commands: `InitiateTransfer`, `CompleteTransfer`,
  `FailTransfer`.
- Amendment-saga events: `TransferAmendmentInitiated`,
  `TransferAmendmentCompleted`, `TransferAmendmentFailed`.
- Amendment-saga commands: `AmendTransfer`,
  `CompleteTransferAmendment`, `FailTransferAmendment`.
- Process managers: `TransferManager`, `TransferAmendmentManager`.
- Service helpers: `initiateTransfer` (the generic command runner),
  `initiateInternalTransfer` (the Transfer-kind helper),
  `amendTransfer`.
- Web DTOs: `InternalTransferRequest`, `AmendTransferRequest`.

`Transaction*` family — the newer field-edit and cancellation
surface:

- Events: `TransactionLabelsSet`, `TransactionAllocationsChanged`,
  `TransactionDescriptionChanged`, `TransactionDateChanged`,
  `TransactionCancellationInitiated`,
  `TransactionCancellationCompleted`.
- Commands: `CancelTransaction`, `SetTransactionLabels`, etc.
- Process manager: `TransactionCancellationManager`.

The `Transfer*` prefix carries two foot-guns:

1. `TransferType` reads as "kinds of Transfer", but only one of its
   four constructors is a Transfer. The same applies to `TransferKind`.
   A reader who knows only the type name will mis-model the domain.
2. `TransferInitiated` reads as "the Transfer-kind saga started", but
   it fires for `Income`, `Expense`, `Transfer`, and `Adjustment`
   alike. The same applies to the whole saga event/command family.
   The prefix is doing the wrong work — it suggests the *kind* when
   it actually denotes *the posting saga*.

Aligning the vocabulary to a single `Transaction*` family with
sub-domain qualifiers (`Posting`, `Amendment`, `Cancellation`) on
saga-internal names removes both foot-guns and gives the codebase one
coherent vocabulary.

## Design

Pure rename across `src/` and `test/`. No behaviour change.
Mechanical text substitution; the compiler catches misses. Per the
project's no-backcompat-phase policy: clean JSON event-shape break,
no upcasters, no coexistence.

### Type rename

In `src/Domain/Core/Types.hs`:

| Old | New |
| --- | --- |
| `TransferType` | `TransactionType` |
| `TransferKind` | `TransactionKind` |
| `rescaleTransferType` | `rescaleTransactionType` |

Constructors of `TransactionType` keep their existing names: `Income`,
`Expense`, `Transfer`, `Adjustment`. The `Transfer` constructor names
the kind (Regular→Regular) — it's correctly named.

Constructors of `TransactionKind` keep their existing names:
`IncomeKind`, `ExpenseKind`, `TransferKind`, `AdjustmentKind`. The
`TransferKind` constructor is the tag for the `Transfer` constructor
of `TransactionType` — consistent with how `IncomeKind` tags `Income`.

Helpers `kindOf`, `allocationsOf`, `categorisedAmount`,
`isCategorised`, `replaceAllocations`, `mkIncome`, `mkExpense` keep
their names; signatures change to reference the renamed types.

### Field rename

| Old | New |
| --- | --- |
| `transferType :: TransferType` | `transactionType :: TransactionType` |

Affects: the `Transaction` aggregate state, the saga-trigger event
payload (`TransactionPostingInitiated`, after the event rename
below), and any DTOs that carry it. JSON tag `"transferType"` →
`"transactionType"`.

### Saga family — events

Sub-domain qualifiers (`Posting`, `Amendment`) make the posting saga
structurally consistent with Amendment and Cancellation, all three of
which can fire on the same `Transaction` aggregate stream.

In `src/Domain/Transaction/Events.hs`:

| Old | New |
| --- | --- |
| `TransferInitiated` | `TransactionPostingInitiated` |
| `TransferCompleted` | `TransactionPostingCompleted` |
| `TransferFailed` | `TransactionPostingFailed` |
| `TransferAmendmentInitiated` | `TransactionAmendmentInitiated` |
| `TransferAmendmentCompleted` | `TransactionAmendmentCompleted` |
| `TransferAmendmentFailed` | `TransactionAmendmentFailed` |

The TH-generated wrapped constructors follow the same rename
mechanically (`TransferInitiatedEvent` →
`TransactionPostingInitiatedEvent`, etc.).

After this rename, the full event family on a `Transaction` stream
is:

- Posting: `TransactionPostingInitiated`,
  `TransactionPostingCompleted`, `TransactionPostingFailed`
- Amendment: `TransactionAmendmentInitiated`,
  `TransactionAmendmentCompleted`, `TransactionAmendmentFailed`
- Cancellation: `TransactionCancellationInitiated`,
  `TransactionCancellationCompleted`
- Field edits: `TransactionLabelsSet`,
  `TransactionAllocationsChanged`,
  `TransactionDescriptionChanged`, `TransactionDateChanged`

### Saga family — commands

User-facing commands keep the simple verb+`Transaction` shape
(`InitiateTransaction`, `AmendTransaction`, `CancelTransaction`).
Saga-internal acknowledgement commands carry the sub-domain qualifier
to disambiguate which saga is acknowledging.

In `src/Domain/Transaction/Commands.hs`:

| Old | New |
| --- | --- |
| `InitiateTransfer` | `InitiateTransaction` |
| `CompleteTransfer` | `CompleteTransactionPosting` |
| `FailTransfer` | `FailTransactionPosting` |
| `AmendTransfer` | `AmendTransaction` |
| `CompleteTransferAmendment` | `CompleteTransactionAmendment` |
| `FailTransferAmendment` | `FailTransactionAmendment` |

TH-generated wrapped constructors follow.

### Process managers

| Old module / type | New |
| --- | --- |
| `Application.ProcessManagers.TransferManager` | `Application.ProcessManagers.TransactionPostingManager` |
| `Application.ProcessManagers.TransferAmendmentManager` | `Application.ProcessManagers.TransactionAmendmentManager` |
| `TransferManager` (record) | `TransactionPostingManager` |
| `TransferData` / `TransferPhase` | `TransactionPostingData` / `TransactionPostingPhase` |
| `TransferAmendmentManager` (record) | `TransactionAmendmentManager` |
| `TransferAmendmentData` / `TransferAmendmentPhase` | `TransactionAmendmentData` / `TransactionAmendmentPhase` |
| `TransferProcessManager` / `TransferAmendmentProcessManager` (aliases) | `TransactionPostingProcessManager` / `TransactionAmendmentProcessManager` |
| `transferManagerDefault`, `transferManagerProjection`, `handleTransferEvent`, `reactToTransferEvent` | `transactionPostingManagerDefault`, `transactionPostingManagerProjection`, `handleTransactionPostingEvent`, `reactToTransactionPostingEvent` |

### Service helpers

In `src/Application/Services/TransactionService.hs`:

| Old | New |
| --- | --- |
| `initiateTransfer` (generic command runner) | `initiateTransaction` |
| `amendTransfer` | `amendTransaction` |
| `initiateInternalTransfer` | `initiateTransfer` |

The kind-specific helpers `initiateIncome` and `initiateExpense`
stay — they reflect the kind. `initiateInternalTransfer` drops its
`Internal` qualifier because, after this rename, the `Transfer`
constructor of `TransactionType` is unambiguously the Regular→Regular
kind — the `Internal` qualifier is redundant.

### Web layer

In `src/Web/Types.hs` and `src/Web/API/TransactionAPI.hs`:

| Old | New |
| --- | --- |
| `InternalTransferRequest` | `TransferRequest` |
| `AmendTransferRequest` | `AmendTransactionRequest` |
| `amendTransferHandler` | `amendTransactionHandler` |
| `transferHandler` | (stays — already kind-named) |

Routes unchanged: `POST /transactions/transfer`,
`POST /transactions/{id}/amend`.

### Test helpers

| Old | New |
| --- | --- |
| `seedInternalTransfer` | `seedTransfer` |

### Out of scope

- The `Transfer` constructor of `TransactionType` — it names the
  kind correctly.
- The `TransferKind` constructor of `TransactionKind` — it's the tag
  for the `Transfer` constructor, consistent with `IncomeKind`,
  `ExpenseKind`, `AdjustmentKind`.
- Generic local variable names like `transferDate`, `transferCmd`,
  `transferAmount` where they don't shadow a record field that's
  being renamed.
- Comments using generic English "transfer" wording where the
  meaning is unambiguous.

## Compatibility

No backcompat phase, per the project's documented policy. JSON
event-payload tags break:

- Event tags: `TransferInitiated` → `TransactionPostingInitiated`,
  `TransferAmendmentCompleted` → `TransactionAmendmentCompleted`,
  etc.
- Field tag: `"transferType"` → `"transactionType"`.

Event-stream replay against pre-rename data is not supported by this
PR. The PR represents a clean snap; the test/dev event stores are
reset.

## PR shape

Single PR on branch `refactor/rename-transfer-to-transaction`.
Supersedes #93. Independent of #94 (cross-kind amendment) — whichever
lands second rebases on the first (trivial: both are mechanical
rename edits affecting overlapping call sites).

## Risk

Mechanical text replacement; the type checker catches misses. The
JSON tag break is a known clean snap (project policy). No semantic
change means existing unit, property, and integration tests continue
to validate behaviour — they only need their references updated.
