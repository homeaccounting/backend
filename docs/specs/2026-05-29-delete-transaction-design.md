---
status: draft
date: 2026-05-29
issue: homeaccounting/backend#85
depends_on:
  - 2026-05-20-transfer-amendment-saga-design.md
---

# Delete (Cancel) Transaction

## Problem

After
[`2026-05-20-transfer-amendment-saga-design.md`](2026-05-20-transfer-amendment-saga-design.md)
lands, completed transactions are editable in every meaningful
dimension — description, business date, category, labels, posting
facts. The remaining lifecycle gap is **cancellation**: a user records
a transaction that should not have existed (a duplicate import, a
misclick, a mis-categorisation across the internal/external boundary
that amendment cannot express) and needs to back it out.

The amendment spec deferred cancellation explicitly as a non-goal,
calling it "a degenerate case of amend with no new postings — separate
spec." This is that spec.

The standard accounting-system resolution is the same one amendment
adopts: **reversing entries**. Posting facts stay immutable;
cancellation is expressed as counter-postings on the original accounts
that drive the affected balances back to their pre-transaction values.
Unlike amendment, cancellation never has a fallible leg — all of its
work is reversal commands that the account aggregate cannot refuse.

## Goals

1. Users can cancel any `Completed` transaction through a single
   endpoint, undoing the postings on both accounts and marking the
   transaction `Cancelled`.
2. The original `TransferInitiated` event and all original leg events
   remain unmodified — cancellation appears as additional events in
   each affected stream, never as overwrites.
3. Account balances return to the values they would have held had the
   cancelled transaction never been posted (assuming no later
   transactions touch the same accounts).
4. Cancellation is gated by the books-close cutoff on the
   transaction's business date — symmetric with amend and the metadata
   edits.
5. Cancelled transactions are **hidden by default** from the
   standard list endpoint but opt-in visible via a query parameter,
   and remain retrievable by direct id lookup and through the audit
   history endpoint. This matches mainstream accounting-software
   convention (QuickBooks, Xero, SAP): voided / reversed entries stay
   on the ledger with the original posting and its reversal both
   visible, so the audit trail is preserved.
6. Existing event payloads on disk continue to deserialise unchanged.

## Non-Goals

- Restoring / un-cancelling a transaction. `Cancelled` is terminal;
  to re-post, create a new transaction.
- Cancelling a `Pending` (in-flight saga) or `Failed` transaction.
  Pending aborts would require entangling with the live transfer
  saga; failed transactions never affected balances and have nothing
  to reverse.
- Bulk cancellation endpoints.
- Approval workflows or per-role cancellation limits.
- A separate "soft delete" / "trash" UX. Cancellation is final.

## Design

### 1. Domain types

No new id or value types. The TX aggregate's `TransactionStatus` gains
a terminal `Cancelled` constructor and the projection gains a single
new transient flag, mirroring the amend saga's `amendmentInProgress`:

```haskell
-- Domain.Transaction.Projection
data TransactionStatus
  = Pending
  | Completed
  | Failed Text
  | Cancelled  -- new terminal state

-- Domain.Transaction.Projection.Transaction is extended with:
cancellationInProgress :: Bool
-- True between TransactionCancellationInitiated and
-- TransactionCancellationCompleted; gates CompleteTransactionCancellation
-- in the pure handler.
```

### 2. Account aggregate

**No changes.** The reversal commands and events introduced by the
amendment spec are reused as-is:

- `ReverseAccountDebit` / `AccountDebitReversed` (`amount`,
  `transactionId`, `at`)
- `ReverseAccountCredit` / `AccountCreditReversed` (`amount`,
  `transactionId`, `at`)

Both remain guaranteed-success (no overdraft check; may take a Regular
account negative). They are saga-only commands and stay un-exposed via
HTTP.

The `at` value on each reversal event is the **snapshot's `at`** — i.e.
the original `TransferInitiated.at` carried by the saga's
`TransferPostings` snapshot. The snapshot is *not* updated by
`TransactionDateChanged` events; this matches the existing
`TransferAmendmentManager` behaviour: `oldAt = old.at` at
`TransferAmendmentManager.hs:208` threads the snapshot's original `at`
into every reversal leg, and `at = p.at` at `:326` preserves it across
`TransferAmendmentCompletedEvent` snapshot updates. Date edits made via
`ChangeTransactionDate` therefore do not flow into the reversal events'
business timestamps. If a future change updates the amendment snapshot
on date edits, cancellation picks that up automatically — both managers
consume the same snapshot type.

### 3. Transaction aggregate

#### 3.1 New commands

```haskell
-- Domain.Transaction.Commands
data CancelTransaction = CancelTransaction
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }

data CompleteTransactionCancellation = CompleteTransactionCancellation
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }
```

`CancelTransaction` is the user-facing trigger (mirrors
`AmendTransfer`). `CompleteTransactionCancellation` is issued
exclusively by the `TransactionCancellationManager` saga (mirrors
`CompleteTransferAmendment`). `cancelledBy` on the completion command
is purely an audit field — the projection at §3.3 does not read it; it
is echoed back so the resulting event is self-contained for
read-model replay.

There is no `FailTransactionCancellation`: the saga's only work is
reversal commands, which the account aggregate cannot refuse.

**Cross-saga concurrency is enforced in the pure handler**, not in the
service layer. Two operations on the same `Completed` transaction must
not start simultaneously (even at the same aggregate version), and the
pure handler is the only place that can reject deterministically based
on the projection's transient flags. This mirrors how
`CompleteTransferAmendment` is gated on `amendmentInProgress` already.

Rejection cases (in the pure handler):

| Command | Aggregate state | Error |
| --- | --- | --- |
| `CancelTransaction` | `status = Cancelled` | `TransactionAlreadyCancelled` (new) |
| `CancelTransaction` | `status ∈ {Pending, Failed _}` | `CannotEditUncompletedTransaction` (reused) |
| `CancelTransaction` | `status = Completed`, `amendmentInProgress = True` | `CannotCancelDuringAmendment` (new) |
| `CancelTransaction` | `status = Completed`, `cancellationInProgress = True` | `CancellationAlreadyInProgress` (new) |
| `CompleteTransactionCancellation` | `cancellationInProgress = False` | `NoCancellationInProgress` (new) |
| `AmendTransfer` (existing handler, new arm) | `cancellationInProgress = True` | `CannotAmendDuringCancellation` (new) |

Five new `TransactionError` constructors are added to
`Domain.Transaction.CommandHandler.TransactionError`:

```haskell
| TransactionAlreadyCancelled
| CannotCancelDuringAmendment
| CancellationAlreadyInProgress
| NoCancellationInProgress
| CannotAmendDuringCancellation
```

The existing `AmendTransfer` arm gains a single early reject:

```haskell
handleTransactionCommand transaction (AmendTransferTransactionCommand AmendTransfer {..}) =
  case transaction ^. #status of
    Completed
      | transaction ^. #cancellationInProgress -> Left CannotAmendDuringCancellation
      | ...existing checks
    _ -> Left CannotEditUncompletedTransaction
```

This is the only modification to existing pure-handler logic; every
other change in this spec is additive.

The books-close gate and the editor-access check remain in the
**service layer** — same as amend. The aggregate-state checks above
are the *only* preconditions the pure handler enforces.

`Domain.Core.Errors.DomainError` gains parallel typed variants for the
HTTP boundary:

```haskell
| TransactionAlreadyCancelled
| CannotCancelDuringAmendment
| CannotAmendDuringCancellation
```

Plus translation arms in `translateTransactionError`
(`TransactionService.hs`):

| `TransactionError` | `DomainError` |
| --- | --- |
| `TransactionAlreadyCancelled` | `TransactionAlreadyCancelled` |
| `CannotCancelDuringAmendment` | `CannotCancelDuringAmendment` |
| `CancellationAlreadyInProgress` | `CancellationAlreadyInProgress` (typed; **reachable** via two near-simultaneous `DELETE` requests on the same TX — this is the user-visible race the pure-handler gate exists to catch, so it deserves a 409 mapping symmetric with `TransactionAlreadyCancelled`) |
| `NoCancellationInProgress` | `TransactionError "No cancellation in progress"` (free-text; saga-internal — only fires from a misbehaving process manager) |
| `CannotAmendDuringCancellation` | `CannotAmendDuringCancellation` |

`DomainError` therefore gains four typed variants:

```haskell
| TransactionAlreadyCancelled
| CancellationAlreadyInProgress
| CannotCancelDuringAmendment
| CannotAmendDuringCancellation
```

All four map to **409 Conflict** in `Web.ErrorMapping`.

#### 3.2 New events

```haskell
-- Domain.Transaction.Events
data TransactionCancellationInitiated = TransactionCancellationInitiated
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }

data TransactionCancellationCompleted = TransactionCancellationCompleted
  { transactionId :: TransactionId
  , cancelledBy   :: UserId
  }
```

`TransactionCancellationInitiated` is the saga-trigger marker, emitted
when `CancelTransaction` is accepted. `TransactionCancellationCompleted`
is emitted only after both reversal events have landed and carries
the same payload, replayed from the saga's tracked state so the event
itself is self-contained for read-model rebuilds.

#### 3.3 Projection

```haskell
handleTransactionEvent tx (TransactionCancellationInitiatedTransactionEvent _) =
  tx & #cancellationInProgress .~ True
     -- status stays Completed; saga is in flight

handleTransactionEvent tx (TransactionCancellationCompletedTransactionEvent _) =
  tx & #status                  .~ Cancelled
     & #cancellationInProgress  .~ False
```

Once status is `Cancelled`, all existing edit-command arms naturally
reject (their `_ -> Left CannotEditUncompletedTransaction` catch-all
fires) — no new arms required.

#### 3.4 Interaction with amendment

`CancelTransaction` and `AmendTransfer` are both edits on a
`Completed` transaction. The pure handler is solely responsible for
preventing them from running concurrently on the same transaction:

- After `TransactionCancellationInitiated` lands but before
  `TransactionCancellationCompleted` lands, `status` is still
  `Completed` but `cancellationInProgress = True`. The pure handler's
  new arm in `AmendTransfer` rejects with `CannotAmendDuringCancellation`.
  Symmetric for `CancelTransaction` against an in-flight amendment via
  `CannotCancelDuringAmendment`.
- Once cancellation completes (`status = Cancelled`), the
  `CancelTransaction` arm of the pure handler emits
  `TransactionAlreadyCancelled`, and every other edit command rejects
  via the existing `_ -> Left CannotEditUncompletedTransaction`
  catch-all (the error name is slightly misleading for a terminal
  `Cancelled` state but the rejection behaviour is correct;
  introducing a per-command `CannotEditCancelledTransaction` would
  require modifying every existing edit handler, which the additive
  change rule discourages).

This is the same gating strategy `CompleteTransferAmendment` already
uses with `amendmentInProgress`, so the precedent is established.

Stale `cancellationInProgress = True` (an `Initiated` event with no
corresponding `Completed`) is a "shouldn't happen" state — the saga's
legs are guaranteed-success and Eventium's dispatch is synchronous in
a single process. If it ever occurs (manual data fix, eventium bug),
the aggregate is wedged: both `CancelTransaction` and `AmendTransfer`
will reject forever. Recovery is a manual `CompleteTransactionCancellation`
event injection. This corner is documented but not engineered around.

### 4. Process manager: `TransactionCancellationManager`

A new process manager (sibling to `TransferAmendmentManager`) lives at
`Application.ProcessManagers.TransactionCancellationManager`. It
reacts to `TransactionCancellationInitiated` on the TX stream,
orchestrates the two reversal steps, and emits
`CompleteTransactionCancellation` on the TX stream when both have
landed.

#### 4.1 Saga step sequence

```
TransactionCancellationInitiated
        │
        ├──► ReverseAccountDebit  (old source, original sourceAmount, tx.at)
        ├──► ReverseAccountCredit (old target, original targetAmount, tx.at)
        │
        ▼  (both reversal events observed, in any order)
CompleteTransactionCancellation
        │
        ▼
TransactionCancellationCompleted   (status := Cancelled)
```

Both reversals are issued in the same reaction cycle (no ordering
constraint between them since neither can fail). The saga waits for
**both** `AccountDebitReversed` and `AccountCreditReversed` events
matching its `transactionId` before issuing
`CompleteTransactionCancellation`.

Compare to amendment, where the new-source debit is fallible and must
land before the tail legs. Here, every leg is guaranteed-success; the
saga structure simplifies accordingly.

#### 4.2 Saga state

A cancellation always issues exactly two reversal legs (source-debit
and target-credit). Saga progress is therefore fully captured by two
flags rather than a leg set.

```haskell
data TransactionCancellationManager = TransactionCancellationManager
  { cancellations    :: Map TransactionId TransactionCancellationData
  , currentPostings  :: Map TransactionId TransferPostings
  }

data TransactionCancellationData = TransactionCancellationData
  { transactionId   :: TransactionId
  , cancelledBy     :: UserId
  , sourceReversed  :: Bool
  , targetReversed  :: Bool
  }
```

Mapping from account event to flag is deterministic:

- `AccountDebitReversedEvent` (matching `transactionId`) → sets
  `sourceReversed = True` (a debit was issued against the source on the
  original `TransferInitiated`).
- `AccountCreditReversedEvent` (matching `transactionId`) → sets
  `targetReversed = True`.

When both flags become `True`, the react function emits
`CompleteTransactionCancellation`.

`TransferPostings` is the same type the amendment manager uses to
snapshot canonical posting facts. It is extracted from
`TransferAmendmentManager.hs` to a shared module
(`Application.ProcessManagers.Snapshots`) and imported by both
managers; the type itself is unchanged.

This extraction is the **only non-additive change in the existing
codebase** introduced by this spec. The alternative (duplicating the
type and the two folding rules) would split a single source of truth
across two managers that must keep their snapshot semantics in sync —
worse for long-term maintenance than a mechanical extraction. The
amendment manager's exports are widened (re-export from the new
shared module); no consumer needs to change its import paths.

Both managers fold `TransferInitiated` and `TransferAmendmentCompleted`
events identically into `currentPostings`, so a transaction amended
once and then cancelled reverses **the amended posting facts** (the
only ones that affected balances net).

#### 4.3 Event handlers (projection)

The `TransferInitiatedEvent` and `TransferAmendmentCompletedEvent`
arms are **structurally identical** to
`TransferAmendmentManager.handleTransferAmendmentEvent`'s
corresponding arms (`TransferAmendmentManager.hs:271-284` and
`:313-328`). The implementation should call into a shared helper in
`Application.ProcessManagers.Snapshots` so the two managers don't
drift.

```haskell
handleTransactionCancellationEvent m (StreamEvent txUuid _ _ (TransferInitiatedEvent e)) =
  -- identical to TransferAmendmentManager's TransferInitiatedEvent arm
  case mkTransactionIdSafe txUuid of
    Nothing  -> m
    Just txId ->
      m & #currentPostings % at txId ?~ TransferPostings
        { sourceAccountId = e.sourceAccountId
        , targetAccountId = e.targetAccountId
        , sourceAmount    = e.sourceAmount
        , targetAmount    = e.targetAmount
        , at              = e.at
        }

handleTransactionCancellationEvent m (StreamEvent _ _ _ (TransferAmendmentCompletedEvent e)) =
  -- identical to TransferAmendmentManager's TransferAmendmentCompletedEvent arm
  m & #currentPostings % at e.transactionId %~ fmap
    (\p -> TransferPostings
      { sourceAccountId = e.newSourceAccountId
      , targetAccountId = e.newTargetAccountId
      , sourceAmount    = e.newSourceAmount
      , targetAmount    = e.newTargetAmount
      , at              = p.at  -- preserve original at; see §2
      })

handleTransactionCancellationEvent m (StreamEvent _ _ _ (TransactionCancellationInitiatedEvent e)) =
  case m ^. #currentPostings % at e.transactionId of
    Nothing -> m
    Just _  -> m & #cancellations % at e.transactionId ?~ TransactionCancellationData
      { transactionId  = e.transactionId
      , cancelledBy    = e.cancelledBy
      , sourceReversed = False
      , targetReversed = False
      }

handleTransactionCancellationEvent m (StreamEvent _ _ _ (AccountDebitReversedEvent e)) =
  m & #cancellations % at e.transactionId
    %~ fmap (\c -> c { sourceReversed = True })

handleTransactionCancellationEvent m (StreamEvent _ _ _ (AccountCreditReversedEvent e)) =
  m & #cancellations % at e.transactionId
    %~ fmap (\c -> c { targetReversed = True })

handleTransactionCancellationEvent m (StreamEvent _ _ _ (TransactionCancellationCompletedEvent e)) =
  m & #cancellations    %~ Map.delete e.transactionId
    & #currentPostings  %~ Map.delete e.transactionId
    -- both wiped: the transaction is terminal, no further reads needed
```

#### 4.4 React (effects)

```haskell
reactToTransactionCancellationEvent m (StreamEvent _ _ _ (TransactionCancellationInitiatedEvent e)) =
  case (m ^. #cancellations % at e.transactionId,
        m ^. #currentPostings % at e.transactionId) of
    (Just _, Just postings) ->
      [ IssueCommand (unAccountId postings.sourceAccountId)
          (embedWith accountCommandEmbedding
            (ReverseAccountDebitAccountCommand
              ReverseAccountDebit
                { amount        = postings.sourceAmount
                , transactionId = e.transactionId
                , at            = postings.at
                })) id
      , IssueCommand (unAccountId postings.targetAccountId)
          (embedWith accountCommandEmbedding
            (ReverseAccountCreditAccountCommand
              ReverseAccountCredit
                { amount        = postings.targetAmount
                , transactionId = e.transactionId
                , at            = postings.at
                })) id
      ]
    _ -> []

reactToTransactionCancellationEvent m (StreamEvent _ _ _ (AccountDebitReversedEvent e)) =
  completeIfReady m e.transactionId

reactToTransactionCancellationEvent m (StreamEvent _ _ _ (AccountCreditReversedEvent e)) =
  completeIfReady m e.transactionId

completeIfReady m txId =
  case m ^. #cancellations % at txId of
    Just c | c.sourceReversed && c.targetReversed ->
      [ IssueCommand (unTransactionId txId)
          (embedWith transactionCommandEmbedding
            (CompleteTransactionCancellationTransactionCommand
              CompleteTransactionCancellation
                { transactionId = txId
                , cancelledBy   = c.cancelledBy
                }))
          id
      ]
    _ -> []
```

`handleTransactionCancellationEvent` runs first and toggles the flag.
The react function then sees the post-toggle state; whichever reversal
event flips the second flag is the one that emits
`CompleteTransactionCancellation`. Re-emission on event replay is
prevented by the cancellation entry being deleted by
`TransactionCancellationCompletedEvent` — once deleted,
`completeIfReady` returns `[]`.

### 5. Read model

`Application.ReadModels.Transaction`:

1. `processEvent` handlers for the two new events:
   - `TransactionCancellationInitiatedEvent _` → no-op (saga-internal
     marker, mirrors `TransferAmendmentInitiatedEvent`).
   - `TransactionCancellationCompletedEvent _` → `Map.adjust` setting
     `status = Cancelled` on the matching entry. Other fields
     unchanged so the audit history endpoint can still render the
     transaction's final posting facts.

2. `listTransactions` accepts a new `includeCancelled :: Bool`
   parameter (default `False`) on `TransactionQuery`:

   ```haskell
   data TransactionQuery = TransactionQuery
     { qAccountId        :: Maybe AccountId
     , qFrom             :: Maybe UTCTime
     , qTo               :: Maybe UTCTime
     , qIncludeCancelled :: Bool  -- new; defaults to False via mkTransactionQuery
     }

   isVisibleByStatus q td = case td.status of
     Cancelled -> q.qIncludeCancelled
     _         -> True
   ```

   Default behaviour: cancelled transactions are excluded. Opt-in:
   `GET /api/transactions?includeCancelled=true` returns them with
   `status = Cancelled` so the client can render them distinctly
   (muted, strikethrough, etc.). `mkTransactionQuery` is extended with
   a fourth argument and continues to enforce the `from <= to`
   invariant. `emptyTransactionQuery` sets `qIncludeCancelled = False`
   to keep the existing default safe.

3. `getTransaction` is unchanged. A cancelled transaction is still
   returned by `GET /api/transactions/{id}` with `status = Cancelled`.

4. `findReferencingTransactions` extends its filter with `&& td.status
   /= Cancelled` so a cancelled transaction no longer blocks deletion
   of dictionary entries it once referenced. Its postings have been
   reversed; from a "this entry is in use" perspective it no longer
   counts.

   **Behaviour change for API consumers**: before this spec, a
   cancelled transaction (which couldn't exist) would have prevented
   dictionary entry deletion if it had referenced a label or
   category. With cancellation now in play, labels and categories
   referenced only by `Cancelled` transactions become deletable. The
   regression row in the §Testing matrix covers this; consumers that
   depended on a cancelled-but-referencing transaction blocking
   deletion should not exist today and so no migration is required.

### 6. Service layer

`Application.Services.TransactionService` gains:

```haskell
cancelTransaction ::
  UserId -> TransactionId -> AppM (Either DomainError TransactionData)
cancelTransaction userId transactionId = runExceptT $ do
  transaction <- ExceptT (ensureEditorAccess userId transactionId)
  ExceptT (guardBooksClosed userId transaction.date)
  ExceptT
    ( dispatchAndAwaitCancellation
        transactionId
        ( CancelTransactionTransactionCommand
            CancelTransaction { transactionId, cancelledBy = userId }
        )
    )
```

- `ensureEditorAccess` reuses the existing helper.
- `guardBooksClosed` is the existing helper from the metadata-edit
  spec — single gate against `transaction.date`.
- **No read-model-based concurrency guard.** All cross-saga
  (cancel-vs-amend, double-cancel) checks are handled by the pure
  handler via `cancellationInProgress` / `amendmentInProgress` on the
  *aggregate projection*. The read model already processes both
  `Initiated` events as no-ops (`TransferAmendmentInitiatedEvent _evt
  -> transactions` at `ReadModels/Transaction.hs:358`); the spec
  preserves that no-op behaviour. Adding the flags to
  `TransactionData` would push surface area to the read model for
  nothing the pure handler can't already enforce deterministically.
- `dispatchAndAwaitCancellation` mirrors `dispatchAndAwaitAmendment`
  but watches for `TransactionCancellationCompletedEvent`. There is
  no saga-failure branch — once the saga starts, completion is
  guaranteed. A defensive `CancellationUnknown` case (no terminal
  event observed after the timeout) maps to
  `TransactionError "Cancellation saga did not produce a terminal event"`,
  matching the `AmendmentUnknown` precedent in `dispatchAndAwaitAmendment`.

The amend service flow is **not modified** beyond what the pure
handler already does — `AmendTransfer`'s
`CannotAmendDuringCancellation` rejection is produced by the pure
handler and translated by `translateTransactionError`. No service-layer
read-model check is added.

The audit history service
(`Application.Services.TransactionHistoryService`) gains two new
history entries (`HistoryCancellationInitiated`,
`HistoryCancellationCompleted`) and one step-function arm each.

### 7. Web layer

`Web.API.TransactionAPI`:

```
DELETE /api/transactions/:id                              →  204 No Content
GET    /api/transactions?includeCancelled=<bool>          →  list (existing route, new optional param)
```

The list endpoint gains an optional `includeCancelled` query
parameter (default `False`). The existing `accountId` / `from` / `to`
parameters are unchanged. The handler threads the parsed boolean into
`mkTransactionQuery`.

Servant fragment for the new `DELETE`:

```haskell
:<|> AuthProtect "jwt"
   :> Capture "id" UUID
   :> DeleteNoContent
```

Servant fragment for the list endpoint adds:

```haskell
:> QueryParam "includeCancelled" Bool
```

The handler defaults `Nothing` to `False`.

Handler (follows the existing `changeDateHandler` / `setLabelsHandler`
pattern: parses the id via `validateField`, delegates to the service,
maps errors):

```haskell
cancelTransactionHandler ::
  AuthenticatedUser -> UUID -> AppM NoContent
cancelTransactionHandler user rawId = do
  transactionId <- validateField "id" (mkTransactionId rawId)
  result <- TransactionService.cancelTransaction user.userId transactionId
  case result of
    Right _   -> pure NoContent
    Left err  -> throwDomainError err
```

`Web.ErrorMapping` extensions (also listed in §3.1):

- `TransactionAlreadyCancelled` → 409 Conflict.
- `CancellationAlreadyInProgress` → 409 Conflict.
- `CannotCancelDuringAmendment` → 409 Conflict.
- `CannotAmendDuringCancellation` → 409 Conflict.
- `CannotEditClosedPeriod` already maps to 403 — reused.
- `CannotEditUncompletedTransaction` already mapped; reused for `Pending` /
  `Failed _` source states.

### 8. JSON / on-disk compatibility

- New events (`TransactionCancellationInitiated`,
  `TransactionCancellationCompleted`) are added to the
  `TransactionEvent` sum type via the existing Template Haskell
  splice. They serialise with `deriveJSON defaultOptions`; no
  hand-written `FromJSON` instance is required because no field
  defaulting is needed.
- The new `Cancelled` constructor is appended to `TransactionStatus`.
  Aeson's default `Generic` encoding tags each variant by its
  constructor name, so existing on-disk `Pending` / `Completed` /
  `Failed` payloads continue to deserialise unchanged.
- New error variants on `DomainError` are additive and do not affect
  any persisted representation.

## Testing

| Suite | File | Coverage |
| ----- | ---- | -------- |
| Unit (command handler) | `test/Domain/Transaction/CancellationCommandHandlerSpec.hs` | `CancelTransaction` × every status: emits `Initiated` on `Completed` & both flags False; rejects on `Pending` / `Failed _` with `CannotEditUncompletedTransaction`; rejects on `Cancelled` with `TransactionAlreadyCancelled`; rejects on `Completed` + `amendmentInProgress` with `CannotCancelDuringAmendment`; rejects on `Completed` + `cancellationInProgress` with `CancellationAlreadyInProgress`. `CompleteTransactionCancellation` × flag: emits `Completed` when `cancellationInProgress`; rejects with `NoCancellationInProgress` otherwise. `AmendTransfer` × `cancellationInProgress = True` → `CannotAmendDuringCancellation`. **`AmendTransfer` regression with `cancellationInProgress = False`**: existing same-account-pair (`AmendTransferToSameAccountPair`) and zero-amount (`AmendTransferToZeroAmount`) checks still fire — verifies the new pattern guard interleaves correctly with the existing handler arms. Existing edit commands (`Change*`, `SetTransactionLabels`) on `Cancelled` state → `CannotEditUncompletedTransaction` (regression). |
| Property (domain) | `test/Domain/Transaction/CancellationPropertySpec.hs` | Handler determinism; idempotency of `Cancelled` terminal state; `cancellationInProgress` invariant (`True` only between `Initiated` and `Completed`); status monotonicity (no event transitions a `Cancelled` projection back to `Completed`). |
| Unit (saga) | `test/Application/ProcessManagers/TransactionCancellationManagerSpec.hs` | `TransferInitiatedEvent` populates `currentPostings`; `TransferAmendmentCompletedEvent` updates the snapshot (cancellation after amendment reverses the amended amounts); `TransactionCancellationInitiatedEvent` emits exactly two reversal commands with the snapshot's amounts and `at`; either reversal order toggles flags; both flags True triggers exactly one `CompleteTransactionCancellation`; `TransactionCancellationCompletedEvent` deletes both `cancellations` and `currentPostings` entries; replay of `AccountDebitReversedEvent` after `Completed` is a no-op. |
| Property (saga) | `test/Application/ProcessManagers/TransactionCancellationManagerPropertySpec.hs` | For all valid `TransferPostings`, the saga emits exactly one `ReverseAccountDebit` and one `ReverseAccountCredit` with the original amounts. Permutation invariance: across all orderings of the four-event sequence (`Initiated`, two reversals, `Completed`), the saga produces the same final state and the same set of issued commands. Per-transaction independence: cancellations on different `transactionId`s never affect each other's state. |
| Integration | `test/Application/Services/TransactionServiceCancellationIntegrationSpec.hs` | Happy path: initiate transfer, complete it, cancel it. Verify source & target balances return to pre-transfer values; account streams contain `AccountDebited`, `AccountCredited`, `AccountDebitReversed`, `AccountCreditReversed` in order; TX stream ends with `TransactionCancellationCompleted`; projection status is `Cancelled`; read model excludes the transaction from `listTransactions` *by default* and includes it when `includeCancelled = True`; direct `getTransaction` still returns it. Cancellation of an amended transaction reverses the *amended* amounts. Books-close rejection (`CannotEditClosedPeriod`). Authorisation rejection (`Forbidden` when caller lacks Editor+). Double-cancel rejected with `TransactionAlreadyCancelled`. Cancel-during-amend rejected with `CannotCancelDuringAmendment`. Amend-during-cancel rejected with `CannotAmendDuringCancellation`. |
| Read-model (regression) | extension of existing dictionary-deletion test in `test/Application/Services/*` | Deleting a label or category that is referenced **only** by `Cancelled` transactions succeeds (the new `&& td.status /= Cancelled` filter in `findReferencingTransactions` no longer counts them as in-use). |
| HTTP | extension of `test/Web/API/TransactionAPISpec.hs` | `DELETE /api/transactions/{id}` happy path (204); 401 unauthenticated; 403 unauthorised; 403 books-close; 404 unknown id; 409 already-cancelled / amend-in-progress; 422 malformed UUID. `GET /api/transactions` default omits cancelled transactions; `?includeCancelled=true` includes them; `?includeCancelled=false` matches the default. |

## Open Questions

- Account-deletion mid-saga: if an account is somehow removed (today
  impossible via the public API, but possible via direct admin
  intervention) between `TransactionCancellationInitiated` and the
  reversal events, the reversal command would fail and the saga would
  stall. The current design treats reversals as guaranteed-success;
  if account deletion ever becomes a feature, this needs revisiting
  (likely with a `FailTransactionCancellation` event).
- Endpoint shape: `DELETE /api/transactions/:id` was chosen for REST
  idiomaticity over `POST /api/transactions/:id/cancellation` (which
  would parallel `PUT /api/transactions/:id/amendment`). Either works;
  this can be revisited if API consistency outweighs REST convention.

## Alternatives Considered

- **Extend `TransferAmendmentManager` to handle "amendment with zero
  postings"** — rejected. The amend command's pure handler explicitly
  rejects zero amounts (`AmendTransferToZeroAmount`); bending that
  invariant conflates two distinct user intents on the audit history
  and pollutes the `amendmentInProgress` flag for a different
  semantic operation.

- **Synchronous reversals from the service layer (no saga)** —
  rejected. Since reversals are guaranteed-success there is no
  failure path the saga buys safety against, but the transfer and
  amend flows both use process managers for the same cross-aggregate
  orchestration and the consistency value outweighs the small saga
  setup cost. Doing it differently here would be the only edit flow
  not driven by a saga.

- **Soft-delete with restore** — rejected. Restore reintroduces the
  problem amendment is meant to solve (re-posting) and complicates
  the books-close story: a restore after the period closes would
  silently un-reverse postings in a closed period.

- **Cancelled transactions completely hidden from list (no opt-in)**
  — initially considered, rejected. Mainstream accounting practice
  keeps voided / reversed entries visible on the ledger with the
  original posting and its reversal both present, so the audit trail
  is preserved. The spec hides them by default (clean UX) but exposes
  them via `includeCancelled=true` for users who need to see history,
  matching how QuickBooks / Xero / SAP surface voided transactions.
