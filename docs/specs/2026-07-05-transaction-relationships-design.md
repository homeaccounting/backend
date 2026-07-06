---
status: draft
---

# Typed Transaction Relationships (Refunds + Merge/Split Lineage)

Tracking issue: **backend#88**. Prerequisite for the web features **tracker#30** (merge)
and **tracker#31** (split).

## Summary

Transactions relate to one another in ways the read model cannot currently express, and
— worse — that are **unrecoverable after the fact** in an event-sourced system:

1. **Refunds / partial refunds.** A $30 return posted a week after a $100 purchase must stay
   a separate Income transaction (posting it on the day money moved is correct accounting),
   but reports and detail views need to pair the two.
2. **Merge lineage** (tracker#30). Several transactions consolidated into one: the cancelled
   sources should record *what they were merged into*.
3. **Split lineage** (tracker#31). One multi-allocation transaction broken into several: each
   result should record *what it was split from*.

The decisive constraint is **event-sourcing provenance**: a relationship is only capturable
at the instant of the operation. If merge simply cancels + amends, or split creates + amends,
the causal edge is never an event and **cannot be reconstructed later**. So the edge must be
recorded as a domain fact (an event) when the operation happens.

This spec introduces one **general, typed, directed-edge** model — a single mechanism with
per-kind validation rules — as the shared substrate. It wires the **Refund** kind end to end
(HTTP → domain → read model → reporting) and provides the **internal** edge-creation
building block that the future merge (`Merge`) and split (`Split`) domain operations will
call. The merge/split *operations themselves* are out of scope here.

## Decisions (resolved during brainstorming)

1. **Edge mechanism — atomic in `InitiateTransaction`.** A single general event
   `TransactionRelationAdded` records every edge. At-creation edges (Refund now, `Split`
   later) are emitted **atomically** with `TransactionPostingInitiated` in one command /
   one append. Post-hoc edges (`Merge`, added to an already-existing source at cancel time)
   use a standalone `AddTransactionRelation` command. Both paths emit the same event.
2. **Refund endpoints — income create only.** A Refund is by definition an Income posting
   linked to an Expense. Only `POST /api/transactions/income` accepts `relatedTransactionId`.
   Expense and transfer create are unchanged.
3. **Cancelling a refunded expense — auto-orphan the edge.** The cancel succeeds; the edge
   remains an immutable fact in the log; reverse-index queries and reports skip endpoints
   whose status is `Cancelled`. No new cross-aggregate coupling in the cancel saga.
4. **Reporting scope — query helper + single-category attribution.** A reverse-index-aware
   helper adjusts per-category net spend so a Refund income offsets the linked expense's
   category. For a multi-category expense, the refund is attributed **pro-rata** across that
   expense's expense-bucket allocations. **Same-currency only** — cross-currency refunds are
   deferred (the edge is still recorded; reporting skips mismatched-currency refund netting).

## Naming (validated against domain conventions)

The codebase uses `OverloadedRecordDot` + `NoFieldSelectors` + `DuplicateRecordFields`;
fields are role-named with **descriptive** full names, never terse abbreviations. Precedents
that fix this exact shape: `TransactionPostingInitiated.externalTransactionId :: Maybe
ExternalTransactionId` (descriptive-role + `TransactionId`) and `transactionType ::
TransactionType` (field named for its role/type). Every transaction *edit* event/command
carries the self-aggregate as `transactionId`. The related endpoint is
`relatedTransactionId` (parallels `externalTransactionId`); the kind is `relationKind`
(parallels `transactionType`). Bare `from`/`to`/`kind` are deliberately avoided — `to` is
too terse next to `transactionId`, and `from`/`to` also collide with `Domain.Core.Range`
fields in the read model (HasField + `DuplicateRecordFields` gotcha). `from` is never stored
on the payload — it is always the stream key.

```haskell
-- Domain.Core.Types
data RelationKind = Refund | Merge | Split
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

data RelationSpec = RelationSpec
  { relatedTransactionId :: TransactionId   -- the pre-existing transaction the edge points at
  , relationKind         :: RelationKind
  }
```

Direction convention (documented, not encoded in constructor names): `relFrom` is the
transaction acted on *later* (the refund / the merged-away source / the split-off result);
`relTo` is the pre-existing one. `relFrom` is always the stream key, so the event never
stores it separately.

**Relation to the `externalTransactionId` precedent.** The `<role>TransactionId` *naming*
follows `TransactionPostingInitiated.externalTransactionId`. The *usage* deliberately
diverges, for reasons of purpose — this is intentional, not an inconsistency to "fix":
- `externalTransactionId` is an opaque *foreign* id (own `newtype` over `Text`), write-side
  only, consumed by the separate `BankImportReadModel` dedup index, and never surfaced on the
  `transactions` read model or `TransactionResponse`. `relatedTransactionId` references a
  *real internal transaction* (reuses `TransactionId`) and is a first-class, queryable,
  exposed relationship (own `transaction_relations` table + reverse index + DTO fields).
- `externalTransactionId` was added as an in-place optional field on the *existing* posting
  event (needing a back-compat `FromJSON`). Relations are recorded via a *new*
  `TransactionRelationAdded` event, leaving the widely-replayed posting event untouched.
- On the command, `externalTransactionId` is a flat scalar `Maybe`; a relation is a *pair*
  (id + kind), so it is modelled as `relation :: Maybe RelationSpec` — general enough for
  future `Split`-at-creation to set `relationKind = Split` through the same field, with no
  "id set / kind missing" invalid state.

## Per-kind validation

| Kind | Direction | Cardinality | `relatedTransactionId` cancelled? | Notes |
|---|---|---|---|---|
| `Refund` | Income → Expense | many refunds → 1 purchase | **forbidden** | refunding a cancelled purchase is nonsense — the cancel already restored balance |
| `Merge` | source → target | many sources → 1 target | **required** | the source *is* cancelled by the merge; edge points cancelled-source → surviving-target |
| `Split` | result → origin | many results → 1 origin | origin may or may not be cancelled | origin is amended-down, or cancelled if fully split out |

`Refund` **forbids** a cancelled `relatedTransactionId` while `Merge` **requires** one — the
same mechanism, different per-kind rules. This is why one bespoke field will not do.

**Common validation (all kinds), effectful, at the service layer:**
- `relatedTransactionId` exists and is **visible** to the caller (any role — same access
  semantics as the actor).
- No self-links (also enforced structurally by the pure handler:
  `relatedTransactionId /= transactionId`).
- Depth-1 only: `relatedTransactionId` must not itself already be the `from` endpoint of an
  edge of the **same kind** (no multi-hop chains). Fan-in/out (many→1, 1→many) is allowed.

**`Refund`-specific:** `relatedTransactionId` is an `Expense`; it is not `Cancelled`; the
`from` endpoint is `Income` (structural — only the income create path produces a Refund).

## Architecture

Layering is unchanged (Domain → Application → Infrastructure, Web on top). New code slots
into the existing Transaction bounded context and the persistent transaction read model.

### 1. Domain layer (`src/Domain/`)

- **`Domain.Core.Types`**: add `RelationKind` and `RelationSpec` (exported via smart
  accessors, JSON instances). `RelationKind` gets a LiquidHaskell-friendly plain enum
  treatment (no refinements needed — it is a closed nullary sum).
- **`Domain.Transaction.Events`**: add
  ```haskell
  data TransactionRelationAdded = TransactionRelationAdded
    { relatedTransactionId :: TransactionId
    , relationKind         :: RelationKind
    }
  ```
  The `from` endpoint is **not** a payload field: it is always the stream key. The pure
  `InitiateTransaction` handler cannot know the freshly-generated aggregate id when it emits
  this event (mirroring `TransactionPostingInitiated`, which likewise carries no self-id), and
  the read model reads `from` from `globalEvent.payload.key`. The standalone
  `AddTransactionRelation` **command** does carry `transactionId` (the routed aggregate is
  known there), which also lets its pure handler perform the self-link check.
  Register it in `transactionEvents` (this flows automatically into the unified
  `AccountingEvent` as `TransactionRelationAddedEvent` via the existing TH splice in
  `Domain.Models`). Hand-written/derived JSON consistent with siblings.
- **`Domain.Transaction.Commands`**: add
  ```haskell
  data AddTransactionRelation = AddTransactionRelation
    { transactionId :: TransactionId, relatedTransactionId :: TransactionId, relationKind :: RelationKind }
  ```
  and extend `InitiateTransaction` with `relation :: Maybe RelationSpec`. Register
  `AddTransactionRelation` in `transactionCommands`.
- **`Domain.Transaction.CommandHandler`**:
  - `InitiateTransaction`: when `relation = Just spec`, after the existing structural checks,
    reject `spec.relatedTransactionId == <this stream id>` with a new `RelationSelfLink`
    handler error; otherwise emit `[TransactionPostingInitiatedTransactionEvent …,
    TransactionRelationAddedTransactionEvent (TransactionRelationAdded thisId spec.relatedTransactionId spec.relationKind)]`.
    When `relation = Nothing`, behaviour is exactly as today (single event).
  - `AddTransactionRelation`: valid against a `Completed` aggregate; same self-link check;
    emits a single `TransactionRelationAdded`. (Per-kind existence/access/depth checks are
    effectful and live in the service — the pure handler only enforces the structural
    self-link rule, mirroring how allocation dictionary membership is a service concern.)
  - New `TransactionError` constructor `RelationSelfLink`.
- **`Domain.Transaction.Projection`**: `TransactionRelationAdded` is a **no-op** on aggregate
  state — relations are a read-model concern and the aggregate never gates on them.
  Documented explicitly; keeps projection laws intact (no new property tests needed beyond a
  no-op assertion).

### 2. Infrastructure layer

- **`Infrastructure.Database.Orphans`**: add a `PersistField`/`PersistFieldSql` instance for
  `RelationKind` (mirrors the existing `StatusKind` instance — stored as its lowercase text
  token). Add `renderRelationKind`/`parseRelationKind` in `Domain.Core.Types` for the wire/DB
  token, mirroring `renderStatusKind`/`parseStatusKind`.

### 3. Application layer

- **`Application.ReadModels.Transaction`**: new table
  ```
  TransactionRelationEntity sql=transaction_relations
      transactionId        TransactionId   -- the `from` / owning endpoint (= event's transactionId)
      relatedTransactionId TransactionId   -- the `to` / referenced endpoint
      relationKind         RelationKind
      UniqueTransactionRelation transactionId relatedTransactionId relationKind
  ```
  Same vocabulary as the event/command — `transactionId` (owning/`from`) +
  `relatedTransactionId` (referenced/`to`). Columns map to `transaction_id`,
  `related_transaction_id`, `relation_kind` (Persistent auto-prefixes accessors — no clash
  with the `transactions.transaction_id` column). Explicit indexes:
  `idx_transaction_relations_from (transaction_id)` (forward) and
  `idx_transaction_relations_to_kind (related_transaction_id, relation_kind)` (reverse).
  - `applyTransactionEvent`: handle `TransactionRelationAddedEvent evt` →
    `insertUnique (TransactionRelationEntity streamId evt.relatedTransactionId evt.relationKind)`
    (idempotent).
  - `resetTransaction`: also clears `transaction_relations`.
  - Queries:
    - `relationsFrom :: TransactionId -> SqlPersistT m [(TransactionId, RelationKind)]` — outbound.
    - `relationsFromMany :: [TransactionId] -> SqlPersistT m (Map TransactionId [(TransactionId, RelationKind)])` — batched for list responses (avoids N+1).
    - `reverseRelations :: TransactionId -> RelationKind -> SqlPersistT m [TransactionId]` —
      inbound per kind (e.g. `refundsOf`). The cancelled-`from` skip is **kind-specific**: for
      `Refund`, join against `transactions.status_kind` to drop edges whose `from` (the refund
      income) is `Cancelled` (auto-orphan, decision 3); for `Merge`/`Split` the `from` is
      *deliberately* cancelled (that is the lineage), so it is **not** filtered.
    - `relationsTo :: TransactionId -> SqlPersistT m [(TransactionId, RelationKind)]` — all
      inbound (for the `/relations` endpoint), same kind-specific skip.
- **`Application.Services.TransactionService`**:
  - `initiateIncome` gains a `Maybe TransactionId` (the refund target). When present:
    validate (effectful) — target exists + visible to caller, is `Expense`, not `Cancelled`,
    depth-1 (`refundsOf target` chain guard is vacuous since target is an Expense, but the
    generic depth check is applied), then thread `Just (RelationSpec target Refund)` into the
    `InitiateTransaction` command. `initiateExpense` / `initiateTransfer` unchanged.
  - `recordTransactionRelation :: UserId -> TransactionId -> TransactionId -> RelationKind -> AppM (Either DomainError ())`
    — the generic internal building block for `Merge`/`Split`. Runs the full common +
    per-kind validation and dispatches `AddTransactionRelation`. Exported for the future
    merge/split operations; **not** exposed as a public "create arbitrary edge" endpoint.
  - **Relations fetch (chosen shape):** `getTransaction`/`queryTransactionResult` keep their
    current `(TransactionId, TransactionData)` return — unchanged, so internal callers that
    do not need edges (history reads, amendment/cancel result reads) are untouched. Outbound
    edges are fetched separately by a new thin query wrapper
    `getOutboundRelations :: TransactionId -> AppM [(TransactionId, RelationKind)]`
    (delegates to `ReadModel.relationsFrom`). This keeps `TransactionData` a pure read-model
    row and avoids reshaping widely-consumed service functions.
  - New `DomainError` constructors (in `Domain.Core.Errors`, aligned to existing style):
    `RefundTargetMustBeExpense`, `CannotRefundCancelledTransaction`,
    `CannotRelateTransactionToItself`, `CannotChainRelations`. A missing target reuses
    `NotFound "Transaction" …`. Translate `RelationSelfLink` handler error →
    `CannotRelateTransactionToItself`. **Edit sites forced by the new constructors:** the
    total `renderDomainError` case-match in `Domain.Core.Errors`, and the HTTP-status mapping
    in `Web.ErrorMapping` (assign 422 for validation-shaped errors, 409 for
    `CannotRefundCancelledTransaction`). `-Wall`/`-Werror` (via `-fci`) will surface any
    missed arm.
- **`Application.Services.ReportingService`** (decision 4):
  - Pure helper `applyRefunds :: Currency -> [TransactionData] -> [(TransactionId, [TransactionId])] -> Map CategoryId Money`
    (or folded into `aggregateSpending`): for each Expense with linked refunds, subtract each
    refund income's total from that expense's categories **pro-rata** by the expense's
    expense-bucket allocation weights. Cancelled endpoints are already excluded upstream.
    Cross-currency refunds (refund income currency ≠ expense category currency) are **skipped**
    and logged, not converted (deferred).
  - `spendingByCategory` effectful wrapper: after fetching reportable transactions, fetch the
    relevant refund edges (reverse index for the reportable expenses) and apply the helper.

### 4. Web layer

- **`Web.Types`**:
  - `IncomeRequest` gains `relatedTransactionId :: Maybe UUID`.
  - `RelationResponse { transactionId :: UUID, relatedTransactionId :: UUID, relationKind :: Text }`
    — one shape, both endpoints populated, reused for inbound and outbound. Same vocabulary as
    the event: `transactionId` is always the `from`/owning endpoint, `relatedTransactionId`
    the `to`/referenced one (so in the `inbound` list `relatedTransactionId` is the queried id).
  - `TransactionResponse` gains `relations :: [RelationResponse]` (outbound edges).
  - `TransactionRelationsResponse { outbound :: [RelationResponse], inbound :: [RelationResponse] }`.
  - `fromTransactionData` gains an outbound-edges parameter:
    `fromTransactionData :: TransactionId -> [(TransactionId, RelationKind)] -> TransactionData -> TransactionResponse`.
- **`Web.API.TransactionAPI`** — `fromTransactionData` call-site handling (all ~9 sites):
  - `incomeHandler`: parse `relatedTransactionId`, pass to `initiateIncome`; then fetch the
    new tx's outbound edges (`getOutboundRelations`) for the response.
  - Single-item handlers (`expense`, `transfer`, `labels`, `allocations`, `description`,
    `date`, `amendment`, `get`): one `getOutboundRelations` call for that id (expense/transfer
    return `[]` in practice — they never declare an edge — but the call is uniform and cheap).
  - `listTransactionsHandler`: **batch** via `ReadModel.relationsFromMany` over the page's
    ids (no N+1), then zip edges into each `fromTransactionData`.
  - New endpoint `GET /api/transactions/:id/relations` → `TransactionRelationsResponse`.
    Requires visibility of `:id` (same access check as `getTransaction`); 404 when not
    visible/absent.

## Data flow — refund creation (happy path)

```
POST /api/transactions/income { accountId, currency, allocations, relatedTransactionId=P, … }
  incomeHandler → validate DTO
  TransactionService.initiateIncome (… Just P)
    ├─ validate labels, books-closed, external/target accounts       (existing)
    ├─ validate allocations against dictionary                       (existing)
    ├─ validate P: exists, visible, is Expense, not Cancelled, depth-1  (new)
    └─ initiateTransaction (InitiateTransaction { …, relation = Just (RelationSpec P Refund) })
         handler emits [TransactionPostingInitiated, TransactionRelationAdded thisId P Refund]
         → single append on the new transaction's stream
  read model (synchronous):
    TransactionPostingInitiatedEvent → insert transactions row (Pending)
    TransactionRelationAddedEvent    → insert transaction_relations (transactionId=new, relatedTransactionId=P, relationKind=Refund)
  posting saga completes → transactions row → Completed
  response: TransactionResponse { …, relations = [{transactionId=new, relatedTransactionId=P, relationKind="refund"}] }
```

Reverse view: `GET /api/transactions/P/relations` → `inbound = [{transactionId=new, relatedTransactionId=P, relationKind="refund"}]`.
After `DELETE /api/transactions/new` (cancel the refund) or `DELETE …/P` (cancel the purchase),
the edge stays in the log but reverse queries skip the cancelled endpoint.

## Error handling

- Missing / invisible target → `NotFound "Transaction"`.
- Target not an Expense → `RefundTargetMustBeExpense` (422).
- Target cancelled → `CannotRefundCancelledTransaction` (409/422).
- `relatedTransactionId == transactionId` → `CannotRelateTransactionToItself` (422).
- Depth-1 violation → `CannotChainRelations` (422).
- All validation is pure where structural (self-link in the handler) and effectful where it
  needs the read model (existence/access/kind/status/depth) — matching the existing
  service/handler split.

## Testing

- **Unit (pure handler, `*Spec.hs`):**
  - `InitiateTransaction` with `relation = Just …` emits both events, in order.
  - `InitiateTransaction` with `relation = Nothing` emits exactly one event (regression).
  - Self-link rejected (`RelationSelfLink`) for both `InitiateTransaction` and
    `AddTransactionRelation`.
  - `AddTransactionRelation` emits a single `TransactionRelationAdded`.
- **Property (`*PropertySpec.hs`):** projection is unchanged by a `TransactionRelationAdded`
  event (no-op invariant); existing status-monotonicity properties still hold.
- **Unit (reporting):** pro-rata refund attribution across a multi-category expense;
  single-category case; refund vs. in-transaction reimbursement distinction;
  cross-currency refund skipped.
- **Integration (`*IntegrationSpec.hs`):** post expense → post income refund linked to it →
  `refundsOf` reverse index returns the refund; cancel the expense → reverse query skips it
  (auto-orphan); exercise `recordTransactionRelation` for `Merge` and `Split` (existence,
  access, cancelled-endpoint rules, depth-1).
- **HTTP:** income create with `relatedTransactionId`; `TransactionResponse.relations` shape;
  `GET /:id/relations` inbound + outbound; validation errors (non-Expense target, cancelled
  target, self-link, chain).

## Non-goals

- No new `Refund` `transactionType` — a refund is an Income transaction with a `Refund`
  relation.
- No automatic refund detection from bank imports (heuristic suggestion is a later follow-up).
- No unifying Income / Expense category dictionaries.
- No general "link any two transactions for any reason" free-form edge — edges are typed and
  created only by their originating operation.
- The merge (tracker#30) and split (tracker#31) **operations** themselves — only their
  edge-creation hook (`recordTransactionRelation`) lands here.
- Cross-currency refund netting in reports (deferred; the edge is still recorded).

## Acceptance criteria (from backend#88)

- [x] `RelationKind` + relation payload modelled; edges recorded as domain facts (events),
  not derived.
- [x] Per-kind validation implemented (existence + access + the cancelled-endpoint rules).
- [x] New income posts can specify a `Refund` edge; service validates.
- [x] `TransactionResponse` carries outbound relations; reverse index queryable per kind.
- [x] Internal edge-creation (`recordTransactionRelation`) usable by merge/split so their
  lineage is captured at operation time.
- [x] Per-category net-spend query helper accounts for `Refund` edges.
- [x] Tests: unit (per-kind validation incl. the cancelled-endpoint contradiction),
  integration (post purchase → linked refund → reverse index; simulate merge/split edge
  creation), HTTP (request/response shape).
