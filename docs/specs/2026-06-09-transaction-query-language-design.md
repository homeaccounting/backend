---
status: draft
date: 2026-06-09
---

# Transaction Query Language

## Problem

`GET /api/transactions` (added 2026-04-18) filters by `accountId`, `from`,
and `to`, plus two boolean flags — `includeCancelled` and `includeFailed`.
Those flags are not a status filter: they are additive opt-ins layered on a
hard-coded "Pending + Completed always visible" default. The consequences:

- You **cannot** ask for "only failed" or "only cancelled" — the flags only
  *add* terminal statuses to the always-on Pending/Completed set.
- Each new filterable concept (status, label, category, …) arrives as a
  bespoke parameter with its own ad-hoc semantics, so the surface grows
  without a shared grammar.
- The status semantics are special-cased and differ from how every other
  filter behaves ("absent param" means different things for `from` vs
  `includeFailed`).

We want one **standardized, uniformly-extensible query grammar** for the
list endpoint: optional `date` range, a real `status` set-membership
filter, a `label` filter, and a documented recipe for adding more fields
with no new conventions.

## Goals

1. Replace the `includeCancelled` / `includeFailed` flags with a real
   `status` filter expressing set membership (status ∈ {…}).
2. Define one wire grammar applied uniformly across every field:
   - **range** → `<field>From` / `<field>To` pair (inclusive),
   - **enum / id set** → comma-separated list meaning IN (membership),
   - **absent param** → no constraint on that field.
3. Model the filter as a single typed `TransactionFilter` record so adding
   a field is a small, fully compiler-checked change.
4. Reuse the existing `Application.ReadModels.Transaction` read model and
   its query-time filtering — no new events, no projection rebuild.
5. Keep filtering on the transaction's **business** timestamp
   (`TransactionData.date`) exactly as the current endpoint does.
6. Support offset/limit pagination on request and response, with a bounded
   default page size, designed to push down to a DB query unchanged when the
   read model is later materialized.

## Non-Goals

- **Category filtering.** `TransactionData` has no `category` field today; it
  exists only on write-side request DTOs. Category is the worked example in
  the "Adding a field" recipe (§8) but is deferred to a follow-up that first
  extends the read model and projection fold.
- **Cross-field OR / NOT / grouping.** The grammar is restricted to
  conjunction-of-fields with per-field disjunction (see §1, "Boolean model").
  Full boolean expressions would require a different transport (RSQL/OData in
  a `?q=` param, or a POST JSON predicate tree) and are out of scope.
- **Cursor / keyset pagination.** Offset/limit *is* in scope (§4, §6).
  Cursor was evaluated and deliberately deferred: it ages better against the
  planned DB-materialized projection (index *seek* vs `OFFSET` *scan*, and
  stable under concurrent inserts), and the existing `(date DESC,
  TransactionId)` sort is already a usable keyset — so it is the documented
  future upgrade. But offset/limit is sufficient at personal-ledger volume
  and gives random page access ("page N of M"), which cursor cannot.
- **Sort controls.** Result ordering stays date-descending, ties broken by
  `TransactionId`.
- **Amount / type / description filters.** Not in this pass; they slot into
  the same grammar later via §8.
- **Write side.** No command, event, or projection-shape changes.

## Design

### 1. HTTP surface and wire grammar

`GET /api/transactions`, `AuthProtect "jwt"`, all params optional:

```
GET /api/transactions
  ?accountId=<uuid>                         -- single value
  &dateFrom=<ISO-8601>                       -- inclusive lower bound
  &dateTo=<ISO-8601>                         -- inclusive upper bound
  &status=pending,completed,failed,cancelled -- CSV, IN
  &label=<uuid>,<uuid>                        -- CSV, IN (set overlap)
  &limit=<int>                                -- pagination, default 50, max 200
  &offset=<int>                               -- pagination, default 0, >= 0
```

`limit` / `offset` are **control** params (pagination), orthogonal to the
filter grammar above — they do not participate in the AND/OR semantics and
are validated separately (see §4, `Page`).

**Grammar rules (uniform across all current and future fields):**

| Kind | Param form | Meaning |
|------|------------|---------|
| range | `<field>From` / `<field>To` | inclusive interval; either bound optional |
| enum / id set | `<field>=a,b,c` | membership: field ∈ {a, b, c} |
| single | `<field>=v` | equality / participation |
| *(absent)* | — | no constraint on that field |

**Boolean model (restricted, de-facto REST standard).** Different params are
AND-combined; the comma list within one param is OR (set membership). There
is no cross-field OR and no negation:

```
filter   =  accountId ∧ date ∧ status ∧ label
status   =  (pending ∨ completed ∨ …)
```

This is the expressiveness ceiling the query-string transport fixes. It is
sufficient for a personal ledger (the only OR a user wants is *within*
`status` / `label`). Negation is unnecessary: `StatusKind` has four values,
so "not failed" is the other three listed explicitly. The upgrade path stays
open — see §7 ("No lock-in").

**Renames** (safe under the project's no-backward-compat phase):

- `from` / `to` → `dateFrom` / `dateTo` (so future ranges — `amountFrom`,
  etc. — follow the same `<field>From`/`<field>To` shape).
- `TransactionQuery` → `TransactionFilter`; `mkTransactionQuery` →
  `mkTransactionFilter`; `emptyTransactionQuery` → `emptyTransactionFilter`.

**Removed:** `includeCancelled`, `includeFailed`. See §6 ("Behaviour change").

Route stays declared before `Capture "id" UUID` so Servant routes bare
`GET /api/transactions`. The route comment (`TransactionAPI.hs:~126`) and the
handler haddock (`~397-409`) that document the old `from`/`to`/
`includeCancelled`/`includeFailed` params must be rewritten to the new
grammar — not just the type — per the project's "treat docs as intentional"
rule.

**Response envelope** (`TransactionListResponse`, in `Web.Types`) gains the
pagination fields and `totalCount` is redefined:

```haskell
data TransactionListResponse = TransactionListResponse
  { transactions :: [TransactionResponse]   -- the current page slice
  , totalCount   :: Int                      -- ALL matches, pre-pagination
  , limit        :: Int                       -- echo of the applied page size
  , offset       :: Int                       -- echo of the applied offset
  }
```

`totalCount` changes meaning: previously it was the length of the returned
list; now it is the count of **all** matching transactions before slicing, so
clients can compute `pages = ceil(totalCount / limit)`. `transactions` holds
only the requested page. `limit`/`offset` echo the *effective* values (after
defaulting), so a client that sent neither still learns the page size used.

### 2. `StatusKind` — payload-free status discriminator (Domain)

`Domain.Transaction.Projection.TransactionStatus` is
`Pending | Completed | Failed Text | Cancelled`. The `Failed Text` reason is
write-side detail the query layer must not depend on, so the filter matches
on a payload-free discriminator defined next to it:

```haskell
data StatusKind = PendingK | CompletedK | FailedK | CancelledK
  deriving (Show, Eq, Ord, Enum, Bounded, Generic)

statusKind :: TransactionStatus -> StatusKind   -- Failed _ -> FailedK

-- Pure wire codec (no third-party dep; keeps Domain pure):
parseStatusKind  :: Text -> Maybe StatusKind     -- lowercase tokens
renderStatusKind :: StatusKind -> Text
```

`statusKind`, `parseStatusKind`, `renderStatusKind`, and the `StatusKind`
type are added to the module export list. Constructors are not exported (per
project rules); the value set is reached via `[minBound .. maxBound]` (from
the derived `Enum`/`Bounded`) and the codec. The wire tokens are the
lowercased constructor names: `pending`, `completed`, `failed`, `cancelled`.

### 3. `Range a` — reusable inclusive range (Domain.Core)

```haskell
-- Domain.Core.Range
data Range a = Range { from :: Maybe a, to :: Maybe a }
  deriving (Show, Eq)

-- Returns Nothing when both bounds absent (no constraint); Left when
-- both present and from > to.
mkRange :: Ord a => Maybe a -> Maybe a -> Either Text (Maybe (Range a))

within :: Ord a => Range a -> a -> Bool   -- inclusive on both ends
```

Pure, base-only — belongs in `Domain.Core` alongside `Domain.Core.Errors`.
Constructor not exported; callers use `mkRange` / `within` and dot-access
`r.from` / `r.to`. Reusable by any future range field (amount, etc.).

The three-way return is deliberate: `mkRange` yields `Left` (invalid),
`Right Nothing` (no date constraint — both bounds absent), or
`Right (Just r)`. At the handler boundary `validateField` peels the `Either`
and the `Maybe (Range UTCTime)` is carried into `TransactionFilter`
unchanged (see §7).

**LiquidHaskell:** refine `Range` so that when both bounds are present
`from <= to`, mirrored exactly by `mkRange`'s validation (per project RDD
rules). The refinement attaches to the inner `Range` value, not to the outer
`Maybe` — the "no constraint" case is `Nothing` and carries no refinement.
Add the measure/predicate to the export list.

### 4. Query value objects: `TransactionFilter` and `Page`

#### `TransactionFilter` (Application.ReadModels.Transaction)

Replaces `TransactionQuery`. Dot-notation fields, **no prefixes** (the
project uses `NoFieldSelectors` + `DuplicateRecordFields` +
`OverloadedRecordDot`; field-name collisions with `TransactionData` and
`Range` are expected and allowed):

```haskell
data TransactionFilter = TransactionFilter
  { accountId :: Maybe AccountId
  , date      :: Maybe (Range UTCTime)
  , status    :: Maybe (NonEmpty StatusKind)
  , label     :: Maybe (NonEmpty LabelId)
  }
  deriving (Show, Eq)

mkTransactionFilter ::
  Maybe AccountId ->
  Maybe (Range UTCTime) ->     -- already validated by mkRange at the boundary
  Maybe (NonEmpty StatusKind) ->
  Maybe (NonEmpty LabelId) ->
  TransactionFilter

emptyTransactionFilter :: TransactionFilter   -- all Nothing; "everything visible"
```

- Constructor and field selectors **not** exported; callers use
  `mkTransactionFilter` / `emptyTransactionFilter` and dot access.
- `NonEmpty` encodes "if the param is present, it lists at least one value" —
  an empty list is rejected at parse time (§5), not represented here.
- Cross-field validation (`dateFrom <= dateTo`) lives in `mkRange` (§3); the
  filter constructor is total.
- `LabelId` is a `type` alias for `DictionaryEntryId`
  (`Domain.Core.Types:630`); it carries no validation distinct from
  `DictionaryEntryId`, whose smart constructor is `mkDictionaryEntryId`
  (used at the handler boundary, §7).

Rationale for the Application layer (not Domain): this is a read-model query
concept, not a domain invariant, and it already references read-model types.

#### `Page` — pagination control (Domain.Core)

```haskell
-- Domain.Core.Page
data Page = Page { limit :: Int, offset :: Int }   -- constructor not exported

defaultLimit :: Int   -- 50
maxLimit     :: Int   -- 200

-- Applies defaults for absent params; validates bounds.
--   limit  : 1 .. maxLimit          (absent -> defaultLimit)
--   offset : >= 0                    (absent -> 0)
-- Out-of-range values are REJECTED (Left), not silently clamped, so a
-- client bug surfaces as a 400 rather than as quietly wrong paging.
mkPage :: Maybe Int -> Maybe Int -> Either Text Page
```

Pure, base-only — belongs in `Domain.Core` next to `Range`. Reusable by any
future paginated endpoint. The validated `Page` always carries concrete
`limit`/`offset`, which is what the handler echoes back into the response
envelope (§1). `defaultLimit`/`maxLimit` are module constants; if another
endpoint later needs different caps, parameterize then (YAGNI).

Rejecting (rather than clamping) keeps the contract honest and matches the
project's "validate at the boundary, return `Left` on bad input" philosophy.

### 5. Parsing layer (Web)

A small `Web.Query` module houses reusable wire-parsing:

```haskell
newtype CommaSep a = CommaSep { values :: NonEmpty a }

instance FromHttpApiData a => FromHttpApiData (CommaSep a) where
  parseQueryParam = -- split on ',', strip each token, reject empty tokens,
                    -- parse each via parseQueryParam @a, collect to NonEmpty,
                    -- Left "<descriptive>" on any failure

-- Orphan FromHttpApiData for StatusKind, delegating to the pure
-- Domain.parseStatusKind. The class comes from Servant (already a direct
-- dep; no new dependency). Kept in Web rather than Domain so the Domain
-- layer takes no dependency on a web/wire concern, per CLAUDE.md layering.
instance FromHttpApiData StatusKind where
  parseQueryParam = maybe (Left "unknown status") Right . parseStatusKind
```

Servant query params in `TransactionAPI`:

```haskell
:> QueryParam "accountId" UUID
:> QueryParam "dateFrom"  UTCTime
:> QueryParam "dateTo"    UTCTime
:> QueryParam "status"    (CommaSep StatusKind)
:> QueryParam "label"     (CommaSep UUID)
```

Any malformed token (unknown status, empty CSV element, bad UUID, non-ISO
datetime) makes `parseQueryParam` return `Left`, which Servant turns into a
**400** automatically. `UUID` / `UTCTime` reuse Servant's existing instances;
`CommaSep UUID` parses elements with the library's `FromHttpApiData UUID`.

The orphan instance is harmless to the build: the library ghc-options carry
`-fno-warn-orphans` (`package.yaml:120`), and because the instance lives in
this library module the test stanza — which lacks that flag but enables
`-Werror` under `flag(ci)` — only imports it and never defines an orphan.
(Note: `Domain.Events` already defines a `FromHttpApiData AccountId` orphan
*inside* Domain — a layering violation this spec deliberately does not
follow; the new instance goes in Web instead.)

### 6. Read-model filtering (Application.ReadModels.Transaction)

`listTransactions` keeps the access-control visible-set precondition and the
date-descending / `TransactionId`-tiebreak sort. The predicate set changes
(each field a uniform `maybe True` check, AND-combined), and it gains a `Page`
parameter and returns the total match count alongside the page slice:

```haskell
listTransactions ::
  MonadIO m =>
  TVar TransactionReadModel ->
  Set AccountId ->            -- visible-to-user set (access control precondition)
  TransactionFilter ->
  Page ->
  m (Int, [(TransactionId, TransactionData)])   -- (totalMatches, pageSlice)
```

Evaluation order: **filter → sort → count → slice**. `totalMatches` is the
length of the filtered+sorted list (all matches, before paging); the slice is
`take page.limit . drop page.offset`. An `offset` past the end yields an empty
slice with `totalMatches` still correct. This maps directly onto a future DB
query — `COUNT(*)` for the total and `ORDER BY date DESC, id DESC OFFSET ?
LIMIT ?` for the slice — so the signature survives materialization unchanged.

Predicates:

- `matchesAccount td` — unchanged: `Nothing` ⇒ True; `Just a` ⇒
  `td.sourceAccountId == a || td.targetAccountId == a`.
- `matchesDate td` — `maybe True (\r -> within r td.date) filter.date`.
  Filters on the **business** timestamp `TransactionData.date` (the
  `occurredAt`/`createdAt` fallback semantics from the 2026-04-18 and
  backdated-transactions designs are preserved unchanged).
- `matchesStatus td` —
  `maybe True (\ks -> statusKind td.status `elem` ks) filter.status`
  (`elem` over a `NonEmpty` is in the standard `Prelude` this module uses).
- `matchesLabel td` — set **overlap** ("any of"):
  `maybe True (\ls -> not (Set.disjoint td.labels (Set.fromList (NE.toList ls)))) filter.label`.

This module uses the standard `Prelude` with qualified imports (not RIO), so
use the already-present `NE.toList` (qualified `Data.List.NonEmpty`) rather
than a bare `toList`, and add `Data.Set (disjoint)` to the `Set` import.

Complexity stays O(N) per query (filter + sort over the in-memory map);
paging is `drop`/`take` on the sorted list — acceptable at personal-accounting
volume.

### 7. Service and handler

`Application.Services.TransactionService.listTransactions` gains a `Page`
parameter and returns `(Int, [(TransactionId, TransactionData)])`; the access
flow (recompute the visible set from the account read model, delegate to the
read model) is identical to the 2026-04-18 design.

Handler in `Web.API.TransactionAPI`:

```haskell
listTransactionsHandler ::
  AuthenticatedUser ->
  Maybe UUID ->                  -- accountId
  Maybe UTCTime ->               -- dateFrom
  Maybe UTCTime ->               -- dateTo
  Maybe (CommaSep StatusKind) -> -- status
  Maybe (CommaSep UUID) ->       -- label
  Maybe Int ->                   -- limit
  Maybe Int ->                   -- offset
  AppM TransactionListResponse
listTransactionsHandler user mAccount mFrom mTo mStatus mLabel mLimit mOffset = do
  accountId <- traverse (validateField "accountId" . mkAccountId) mAccount
  dateRange <- validateField "date" $ mkRange mFrom mTo      -- 400 on from > to
  -- LabelId = DictionaryEntryId; its smart constructor is mkDictionaryEntryId.
  labels    <- traverse (traverse (validateField "label" . mkDictionaryEntryId) . (.values)) mLabel
  page      <- validateField "page" $ mkPage mLimit mOffset  -- 400 on bad limit/offset
  let statuses = (.values) <$> mStatus
      f = mkTransactionFilter accountId dateRange statuses labels
  (total, results) <- TransactionService.listTransactions user.userId f page
  let responses = map (uncurry fromTransactionData) results
  pure $ TransactionListResponse responses total page.limit page.offset
```

The Servant type adds `QueryParam "limit" Int :> QueryParam "offset" Int`
after the filter params. A non-integer `limit`/`offset` is a 400 from Servant
(parse failure); an out-of-range integer is a 400 from `mkPage` via
`validateField`.

`validateField` (from `Web.Validation`) is the standard pattern used by every
other handler. The new handler is added to the module export list (tests
import handlers directly).

**No lock-in.** Filtering reduces to a single predicate
`TransactionData -> Bool`. If full boolean expressions are ever needed, a
`BoolExpr` / RSQL parser producing that same predicate can be layered on
without touching the per-field parsers or the read-model evaluation. Choosing
the restricted model now does not foreclose the expressive model later.

### 8. Adding a field later (the extensibility payoff)

Adding a filterable field that **already exists** on `TransactionData` is
three compiler-checked touch-points plus (for enums) one parser:

1. Add the field to `TransactionFilter` (§4).
2. Add the `QueryParam` + assemble it in `listTransactionsHandler` (§5, §7).
3. Add a `matchesX` predicate to `listTransactions` (§6).
4. *(enums only)* add a pure codec in Domain + a `FromHttpApiData` in
   `Web.Query` (§2, §5).

Omitting any of (1)–(3) fails to compile (the record forces the wiring).

**Worked example — `category` (deferred).** Category is *not* on
`TransactionData`, so it additionally requires: add `category` to
`TransactionData`, project it in the event fold, and decide handling for
events persisted before the field existed. That read-model change is a
separate follow-up; once landed, the four steps above apply unchanged.

### 9. Testing

Property-first, per the project's TDD approach.

**Property (primary):**

- `mkRange`: for any `from`/`to`, `Left` iff both present and `from > to`;
  `Right Nothing` iff both absent.
- `within`: `within (Range f t) x` iff `maybe True (<= x) f && maybe True (x <=) t`.
- `listTransactions`: every returned row satisfies all active predicates —
  `statusKind status ∈ statuses`, `within date`, `labels ∩ requested ≠ ∅`,
  account participation — and rows violating any active predicate are absent.
- `statusKind` total over all `TransactionStatus` constructors;
  `parseStatusKind . renderStatusKind == Just`.
- `mkPage`: `limit` outside `1..maxLimit` → `Left`; negative `offset` →
  `Left`; absent → `defaultLimit`/`0`.
- Pagination invariants over any valid `Page`: returned slice length
  `<= page.limit`; `totalMatches` equals the unpaged filtered count and is
  independent of `limit`/`offset`; concatenating successive non-overlapping
  pages (`offset` 0, limit, 2·limit, …) reconstructs the full sorted result;
  `offset >= totalMatches` ⇒ empty slice with `totalMatches` unchanged.

**Unit:**

- `CommaSep` parsing: single value, multiple values, surrounding whitespace
  trimmed, empty element (`a,,b`) → `Left`, empty string → `Left`.
- `FromHttpApiData StatusKind`: each valid token, unknown token → `Left`,
  case handling.
- `mkTransactionFilter` / `emptyTransactionFilter` shape.

**Integration — rewrite `TransactionQuerySpec` / `TransactionListSpec` and
the API spec:**

- New default: omitting `status` returns **all** statuses (incl. Failed /
  Cancelled) — pins the behaviour change in §6.
- `status=failed,cancelled` returns exactly those; `status=completed` only
  Completed.
- `label` overlap: a transaction with any requested label matches; none →
  excluded.
- `dateFrom`/`dateTo` inclusive boundaries; `dateFrom > dateTo` → 400.
- Unknown status token / malformed label UUID → 400.
- Combined filters AND together.
- Pagination: `limit`/`offset` slice the result; `totalCount` reflects all
  matches (not the page length); `limit`/`offset` echoed in the response;
  omitted → `defaultLimit`/`0`; `limit=0` / `limit>maxLimit` / negative
  `offset` → 400.
- Backdated business-time behaviour preserved (a transfer with past
  `occurredAt` matches a range bracketing `occurredAt`, not one bracketing
  its persistence date).

**LiquidHaskell:** `Range` refinement verifies the `from <= to`
invariant; no redundant runtime test duplicates it.

## Cross-Cutting Concerns

**Behaviour change (breaking, intentional).** Removing `includeCancelled` /
`includeFailed` and adopting "absent = no constraint" means **omitting
`status` now returns every status**, including Failed and Cancelled — the
opposite of today's hide-by-default. Clients wanting the previous default
view must send `status=pending,completed`. This is the deliberate breaking
change accepted under the project's no-backward-compat phase; it must be
called out to the Telegram bot and any web/UI consumers.

**Pagination (behaviour change).** A bounded default page size means
omitting `limit` no longer returns *every* matching transaction — it returns
the first `defaultLimit` (50). Consumers that enumerate the full history (the
Monobank resync verification script, audit flows) must now page using
`totalCount` to know when they are done. `totalCount` also changes meaning
(all matches, not the returned length). Both are intentional under the
no-backward-compat phase and must be called out to those consumers alongside
the `status`-default change.

**Access control / shared accounts / information leakage.** Unchanged from
the 2026-04-18 design: the visible set is recomputed per call; transactions
on shared accounts appear for every co-accessor; both account ids remain on
the DTO. No new leak.

**Business-time filtering.** Sort key and `date` filter both use
`TransactionData.date` (business timestamp). Event persistence time is never
the filter key — preserved verbatim from the prior design.

**Layering.** `Range` and `StatusKind` (with pure codecs) live in Domain and
take no third-party dependency. The `FromHttpApiData` wire instances (class
supplied by Servant, already a dep) live in `Web.Query`; the
`FromHttpApiData StatusKind` orphan is intentional and contained there so
Domain stays free of web concerns. Orphan warnings are silenced by
`-fno-warn-orphans` in the library ghc-options (`package.yaml:120`); the test
stanza lacks that flag but only imports the instance, so no orphan is defined
there. `Domain.Events` already carries a `FromHttpApiData AccountId` orphan
inside Domain (a layering violation); this spec deliberately does not extend
that pattern.

**Forward compatibility.** New filter fields are non-breaking additions
following §8. The `(total, slice)` read-model signature and offset/limit
contract map directly onto a DB query when the projection is materialized.
Adopting cursor/keyset pagination later (the documented upgrade, see
Non-Goals) would add a `cursor` param and a `nextCursor` envelope field
alongside the existing offset/limit — the `(date DESC, TransactionId)` sort
is already the keyset it needs.
