---
status: draft
date: 2026-04-18
issue: homeaccounting/backend#47
---

# List Transactions Endpoint

## Problem

`Web.API.TransactionAPI` exposes only single-transaction lookup
(`GET /api/transactions/:id`). There is no way to enumerate transactions
for a given account or time window. This is needed by:

- The Monobank resync verification script (today it can only check
  `importedCount` and balance deltas).
- The Telegram bot's recent-activity views.
- A future web UI.
- Audit / reconciliation flows.

## Goals

1. Expose a read-only HTTP endpoint that returns transactions visible to
   the authenticated user, with optional filters by account and date
   range.
2. Reuse the existing `Application.ReadModels.Transaction` read model —
   no new write-side events, no projection rebuilds.
3. Honour the existing access model: a user can only see transactions
   that touch at least one account they have Owner/Editor/Viewer access
   to.
4. Keep the shape forward-compatible: it should be possible to add more
   filter fields (status, category, type) and pagination later without
   breaking clients.

## Non-Goals

- Pagination / cursor-based fetch (follow-up once volume warrants it).
- Additional filters (status, category, amount range, transfer type).
- Changes to commands, events, or the write side.
- Client consumers — the Telegram bot and the Monobank resync script
  will adopt the endpoint in separate PRs.
- A dedicated per-account secondary index in the read model (v1
  filter-at-query-time is sufficient for personal-accounting volumes).

## Design

### 1. HTTP surface

Add a single endpoint to `Web.API.TransactionAPI`:

```
GET /api/transactions
  ?accountId=<uuid>     -- optional
  &from=<ISO-8601>      -- optional, inclusive lower bound
  &to=<ISO-8601>        -- optional, inclusive upper bound
```

- Auth: `AuthProtect "jwt"`.
- All query params are optional; omitting all three returns every
  transaction the caller can see.
- Route must be declared before `Capture "id" UUID` in the
  `TransactionAPI` type so Servant picks it for bare `GET
  /api/transactions`.
- `from` / `to` parsed as `UTCTime` via Servant's existing
  `FromHttpApiData` instance — full ISO-8601 datetime strings with a
  UTC designator, e.g. `2026-04-10T14:30:00Z`. Date-only and local-time
  values are rejected. Malformed values → 400 from Servant.
- `from > to` → 400 `ValidationErr` (enforced by
  `mkTransactionQuery`, see §3).
- Happy path response: 200 with `TransactionListResponse` (the
  `transactions` array may be empty when no records match).

Response DTO (new, in `Web.Types`, modelled on the existing
`AccountListResponse`):

```haskell
data TransactionListResponse = TransactionListResponse
  { transactions :: [TransactionResponse],
    totalCount   :: Int
  }
```

Leaves room for `nextCursor`/`total` later without a breaking change.

### 2. Query record

Defined next to `TransactionData` in
`Application.ReadModels.Transaction`:

```haskell
data TransactionQuery = TransactionQuery
  { accountId :: Maybe AccountId,
    from      :: Maybe UTCTime,
    to        :: Maybe UTCTime
  }
  deriving (Show, Eq)

mkTransactionQuery ::
  Maybe AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Either Text TransactionQuery

emptyTransactionQuery :: TransactionQuery
```

- Data constructor and field selectors are NOT exported (per project
  rules); callers use `mkTransactionQuery` /
  `emptyTransactionQuery` and exported accessor functions.
- `mkTransactionQuery` enforces the one cross-field invariant:
  when both bounds are present, `from <= to`.
- `emptyTransactionQuery` is provided for tests and callers that
  want an "all transactions visible to the user" query.

Rationale for putting it here rather than in `Domain/`: it is a
read-model query concept, not a domain invariant, and it references
`AccountId` which is already imported by this module.

The `Set AccountId` parameter introduced in §3 means
`Application.ReadModels.Transaction` gains a new `Data.Set` import.

### 3. Read-model query

Add to `Application.ReadModels.Transaction`:

```haskell
listTransactions ::
  MonadIO m =>
  TVar TransactionReadModel ->
  Set AccountId ->              -- visible-to-user set (access control)
  TransactionQuery ->      -- user-supplied filters
  m [(TransactionId, TransactionData)]
```

The visible set is kept as a separate parameter — it is computed by the
service from the authenticated user, not supplied by the caller, and it
is a precondition rather than a user-controlled filter.

Semantics (filter at query time, mirrors
`getAccessibleAccounts` / `getUserRegularAccounts` style):

1. Fold `summaryData`, keep entries where `sourceAccountId ∈ visible
   || targetAccountId ∈ visible`.
2. If `accountId = Just a`: further require `sourceAccountId == a ||
   targetAccountId == a`. An `accountId` the user can't see is not in
   `visible`, so it naturally produces zero matches — no separate 404
   branch required.
3. Apply `from` / `to` against `TransactionData.date` (inclusive both
   ends). This is the transaction's **business** timestamp: the
   `TransferInitiated` event's `occurredAt` when set (explicit
   backdated transfers — #41), falling back to `createdAt` only when
   `occurredAt` is `Nothing` (the project-wide "unset ⇒ same as
   createdAt" convention from
   2026-04-10-backdated-transactions-design.md). The event's
   persistence timestamp (`createdAt`) is never consulted directly by
   the filter — it is only reachable indirectly through the
   read-model's populated `date` field when `occurredAt` was never
   set. A backdated transfer persisted today with
   `occurredAt = 2026-01-15T10:00:00Z` must match a query with
   `from = 2026-01-14` / `to = 2026-01-16` and must NOT match a query
   bounded around today.
4. Sort the result by `date` descending (most-recent first). Ties are
   broken by `TransactionId` (the read model is a
   `Map TransactionId TransactionData`, so the underlying enumeration
   is keyed by id).

All statuses (`Pending`, `Completed`, `Failed _`) are included. Callers
that need to filter by status can do so client-side off the existing
`status` field in `TransactionResponse`; a `status` query param can be
added later without a breaking change.

Complexity: O(N) per query, N = number of transactions in the read
model. Acceptable for a personal accounting app; revisit when
pagination lands.

### 4. Service layer

Add to `Application.Services.TransactionService`:

```haskell
listTransactions ::
  UserId ->
  TransactionQuery ->
  AppM [(TransactionId, TransactionData)]
```

Flow:

1. `accountRM <- view accountReadModelL`
2. `accessible <- AccountRM.getAccessibleAccounts accountRM userId`
   — any role (Owner / Editor / Viewer) grants read access.
3. `visible = Set.fromList [aid | (aid, _, _) <- accessible]`.
4. `readModel <- view transactionReadModelL`
5. Delegate to `ReadModel.listTransactions readModel visible query`.
6. Return the list as-is; the handler performs DTO conversion.

Returns `[]` rather than an error when the user has zero accessible
accounts, or when `query.accountId` points at an account the user
can't see. This is intentional: the endpoint is a filter, so "no
matches" is a natural empty result and avoids leaking account
existence.

### 5. Handler

Add to `Web.API.TransactionAPI`:

```haskell
listTransactionsHandler ::
  AuthenticatedUser ->
  Maybe UUID ->        -- accountId
  Maybe UTCTime ->     -- from
  Maybe UTCTime ->     -- to
  AppM TransactionListResponse
listTransactionsHandler user maybeAccountUuid maybeFrom maybeTo = do
  let userId = user.userId
  accountIdDomain <- traverse (validateField "accountId" . mkAccountId) maybeAccountUuid
  query           <- validateField "query" $
                       mkTransactionQuery accountIdDomain maybeFrom maybeTo
  results <- TransactionService.listTransactions userId query
  let responses  = map (uncurry fromTransactionData) results
      totalCount = length responses
  pure $ TransactionListResponse responses totalCount
```

The validation helpers (`validateField` from `Web.Validation`) are the
standard pattern used by every other handler in this module.

Register the new route in `TransactionAPI` and `transactionServer`
before the `Capture "id"` line. Add the new handler to the module
export list (tests import handlers directly).

### 6. Testing

Follows the project's TDD + property-first approach.

**Unit spec — `test/Application/ReadModels/TransactionSpec.hs` (new)**

Seeds a `TransactionReadModel` via the existing `handleTransactionEvents`
helper and exercises `listTransactions`:

- Visibility filter: source-only accessible, target-only accessible,
  both accessible, neither accessible (latter excluded).
- `accountId` filter narrows further (source match, target match,
  neither — produces empty).
- `from` / `to` inclusive boundaries (boundary dates included).
- Descending sort by `date`.
- Mixed statuses (Pending / Completed / Failed) all appear.
- **Backdated filter behaviour:** seed a transfer whose
  `TransferInitiated` metadata has `createdAt = today` and
  `occurredAt = some past date T`. Assert that a query with `from` /
  `to` bracketing `T` returns the transfer, and a query bracketing
  `today` (but not `T`) does not. This pins the filter to the
  business timestamp and rules out accidental use of `createdAt`.

**Unit spec — `TransactionQuerySpec.hs` (new, alongside the module)**

Covers `mkTransactionQuery`:

- `from > to` → `Left`.
- `from == to` → `Right`.
- Only-one-bound / no-bound combinations → `Right`.

**Property-based spec**

For any random `from` / `to` that satisfy `from <= to`, every returned
transaction has `from <= date <= to`.

**Handler / API spec — `test/Web/API/TransactionAPISpec.hs` (new)**

Pattern from `test/Web/API/BankingAPISpec.hs`:

- Happy path: returns a correctly scoped, date-sorted list.
- Malformed `accountId` → 400 validation error.
- `from > to` → 400 validation error.
- Unknown or forbidden `accountId` → 200 with empty list.
- `TransactionListResponse.totalCount` == `length transactions`.

## Cross-Cutting Concerns

**Access control:** The "visible" set is recomputed on every call from
the account read model. This keeps behaviour correct when access is
granted/revoked at runtime and matches how the rest of the service
layer already treats access checks.

**Shared accounts:** Because the visible set contains every account the
user has any role on, transactions on shared accounts appear for every
co-accessor — matching how `GET /api/accounts` already works.

**Information leakage:** When a transaction's source and target cross
an access boundary (user has access to one side but not the other), the
DTO still surfaces both `sourceAccountId` and `targetAccountId`. This
matches the existing `GET /api/transactions/:id` behaviour, so no new
leak is introduced.

**Ordering and filtering on business time:** Both the sort key and
the `from`/`to` filter use `TransactionData.date` — the transaction's
business timestamp (`occurredAt`, with `createdAt` as the
"`occurredAt` unset" fallback per #41). Event persistence time is
never used as the filter key. If a future change introduces a
separate "persisted at" column or cursor for pagination, that value
must stay out of the `from`/`to` semantics. Ties are broken by
`TransactionId` — a stable, deterministic fallback since the read
model is a `Map TransactionId TransactionData`.

**Backwards compatibility:** The new route lives at a previously
unused path; no existing endpoint changes shape. `TransactionResponse`
is reused unchanged.

**Forward compatibility:** Adding further filter fields to
`TransactionQuery` is a non-breaking change because the smart
constructor takes each field as a separate argument and the HTTP layer
adds new optional `QueryParam`s.
