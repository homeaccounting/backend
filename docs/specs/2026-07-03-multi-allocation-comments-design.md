---
status: draft
---

# Multi-Allocation NL Expenses with Per-Allocation Comments

## Summary

A single natural-language prompt is often **one expense split across several line items**, e.g.:

```
200 огірки розсада
700 квіти
200 яйця
500 овочі
160 огірки зелень
```

→ one expense (total 1760) with **five allocations**. Multiple lines may resolve to the
**same** category (eggs / vegetables / cucumbers → Food); each line is preserved as its
own allocation with its **original text as a comment** — not merged away.

This spec adds a `comment :: Maybe Text` field to the `Allocation` domain type and threads
it through every allocation-carrying flow (create income/expense, set-allocations, amend,
and the NL prompt path). The NL extraction is reshaped so the LLM returns a **list** of
allocations (`{amount, category, comment}`) per prompt, resolved **line-by-line**.

Implements [homeaccounting/tracker#27](https://github.com/homeaccounting/tracker/issues/27).
Builds on NL prompting (backend #86 / PR #118) and the default-account resolution (#26,
already implemented in `resolveAccount`).

## Motivation

The NL prompting feature today collapses each prompt to a **single-category** allocation
(`TransactionIntent` has one top-level `amount` + one `category`). Users writing multi-line
shopping lists lose the per-line breakdown: five lines become one lumped amount against one
category. They want each line preserved — with its raw text as a comment — even when several
lines map to the same category.

More broadly, allocations should be able to carry a free-text comment in **every** flow that
sets allocations, not only the NL path.

## Design Decisions

- **Allocations stay a list; duplicate categories are explicitly allowed.** No grouping or
  summing by category into a map. Each line is its own allocation. `mkAllocations` keeps its
  current behavior (rejects only both-buckets-empty); **no dedup is added**.
- **`Allocation` gains `comment :: Maybe Text`** (free text). For the NL path the comment is
  the **LLM-resolved item/purpose** of that line — the goods bought or the reason — with the
  amount, currency, and account words stripped out (e.g. `cash milk 120 uah` → `milk`), not the
  raw input line. The LLM performs this extraction; deterministic code threads whatever comment
  it returns. The comment is `null` when a line names nothing beyond its category.
- **Blank comments normalize to `Nothing`.** `mkAllocation` treats empty / whitespace-only
  comment text as `Nothing`, so `""` and absent are equivalent.
- **Tolerant persistence parser.** `allocParser` treats a missing `comment` JSON key as
  `Nothing`. Per the project's no-backward-compat convention event/DTO shapes may change
  freely; this choice simply avoids forcing a DB wipe and is harmless.
- **NL extraction returns an allocations list, deriving the total.** For income/expense the
  intent carries `allocations :: [IntentAllocation]`; total = sum of the amounts. Transfer
  keeps a single top-level `amount` and no allocations.
- **Top-level `kind` picks a single bucket.** All allocation lines from one prompt go into
  the `expenses` bucket (kind=expense) or `incomes` bucket (kind=income). No per-line
  income/expense mixing (not required by the example; keeps the schema and resolution
  simple).
- **Reporting is unaffected.** `aggregateSpending`'s `Map.fromListWith (+)` sums by category,
  so duplicate categories sum correctly; comments are per-allocation detail and are not
  aggregated.

## Domain Change

`src/Domain/Core/Types.hs`:

```haskell
{-@
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: {m : Money | (amount m) > 0}
  , comment    :: Maybe Text
  }
@-}
data Allocation = Allocation
  { categoryId :: CategoryId,
    amount :: Money,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)
```

- LiquidHaskell refinement keeps `amount > 0`; `comment` is unconstrained.
- Smart constructor signature changes:

  ```haskell
  mkAllocation :: CategoryId -> Money -> Maybe Text -> Either DomainError Allocation
  ```

  It normalizes the comment (strip; empty → `Nothing`) and applies the existing positivity
  check.
- `mkAllocations` is unchanged (no dedup, rejects only both-empty).
- Every existing `mkAllocation` / `Allocation` constructor call site gains the comment
  argument:
  - `Domain/Transaction/Projection.hs` placeholder → `Nothing`
  - `Application/Services/BankImportService.hs` → `Nothing`
  - `Telegram/Commands.hs` → `Nothing` (no comment input surface today; door left open)
  - `Web/API/TransactionAPI.hs` `toAlloc` (inside the Web-layer `buildAllocations`) → threads
    the request comment (see Web DTOs)
  - `test/Testkit/Generators.hs` `Arbitrary Allocation`, `partitionMoneyExact`,
    `genAllocationListSummingTo`, `genTransactionType` → generate optional comments

> Note: there are **two** distinct `buildAllocations` functions. The Web-layer one in
> `Web/API/TransactionAPI.hs` (`Currency -> AllocationsRequest -> Either DomainError (Money,
> Allocations)`) just threads a comment through `toAlloc`. The resolver one in
> `Application/Services/Prompt/Transaction/Resolve.hs` is generalized to take a list
> `[(CategoryId, Money, Maybe Text)]`. Do not conflate them.

## Persistence

`src/Infrastructure/Database/Orphans.hs`:

- `allocToValue` emits the `comment` key (omit or `null` when `Nothing`).
- `allocParser` reads `comment` with `.:?` so a missing key parses as `Nothing`.

## Web DTOs

`src/Web/Types.hs` + `src/Web/API/TransactionAPI.hs`:

- **Request side** — `CategoryAmount` gains `comment :: Maybe Text`. `toAlloc` /
  `buildAllocations` thread it into `mkAllocation`. This covers the create-income and
  create-expense flows.
- **Response side** — `AllocationResponse` gains `comment :: Maybe Text`; the
  `allocationsResponseOf` / `toAllocationResponse` projection in `Web/Types.hs` (which
  destructures `Allocation` positionally) echoes each allocation's comment.
- **Set-allocations** (`SetTransactionAllocationsRequest { newAllocations :: Allocations }`)
  and **amend** (`AmendTransactionRequest { newAllocations :: Maybe Allocations }`) use the
  **domain `Allocations`** type directly, so they serialize via the `Orphans` instances and
  gain comment support for free once the domain type + JSON carry it.
- `CommandHandler`'s `checkAllocationsAgainst` validates only sum / currency / positivity —
  it ignores comments, so comments survive amend and set-allocations untouched.

## NL Extraction / Resolution

`src/Application/Services/Prompt/Transaction/`:

- **Intent** (`Intent.hs`): introduce

  ```haskell
  data IntentAllocation = IntentAllocation
    { amount   :: !Text          -- decimal string
    , category :: !(Maybe Text)  -- name; null → default
    , comment  :: !(Maybe Text)  -- LLM-extracted item/purpose (amount/account stripped)
    }
  ```

  `TransactionIntent` carries `allocations :: [IntentAllocation]` for income/expense; transfer
  keeps a single top-level `amount`. The JSON `transactionSchema` and the human-readable
  `transactionGuide` are updated to instruct the model to emit one allocation per input line,
  with `comment` = the line's extracted item/purpose (amount, currency, and account words
  stripped; `null` when the line names nothing beyond its category), and `category` per line
  (null when nothing fits).
- **Resolve** (`Resolve.hs`): `resolveExpense` / `resolveIncome` resolve **each line
  independently** via `resolveCategory` (name match → default "Other"), building one
  `Allocation` per line carrying its comment, all into the kind's bucket. Total money = sum of
  line amounts (currency = account's native currency). The interpretation string summarizes
  the N lines. The resolver `buildAllocations` is generalized to take a list of `(CategoryId,
  Money, Maybe Text)`. The `Resolved` constructors (`ResolvedExpense` / `ResolvedIncome`)
  already carry an `Allocations`, so **no constructor arity change is needed** — the multi-line
  change is internal to how that `Allocations` value is built.
- **Account**: unchanged — the existing `resolveAccount` precedence ladder (#26) handles the
  no-account case by falling back to the configured default, else a clean validation error.

## Data Flow (NL multi-line expense)

```
POST /api/prompt {text}
  → PromptService.handlePrompt
    → gatherContext (accounts, categories, defaults)
    → LLM completes → TransactionIntent { kind=expense, allocations=[{amt,cat,comment}×N] }
    → Resolve: per-line category (match|default), sum → total, comments preserved
    → ResolvedExpense account total Allocations[expenses=N] ...
    → TransactionService.initiateExpense → event store
  → TransactionResponse (allocations echo comments)
```

## Error Handling

- Empty prompt, feature-disabled, upstream/transport errors: unchanged (existing
  `PromptError` mapping to 400/502/503).
- No-account multi-line case with no default configured → validation error (400) via
  `resolveAccount`.
- A line with non-positive amount → `mkAllocation` returns `Left` → surfaced as a validation
  error.
- Sum/currency mismatches on amend/set are still enforced by `checkAllocationsAgainst`.

## Testing (TDD)

- **Domain** (`AllocationPropertySpec` / `AllocationsSpec`): `mkAllocation` comment
  passthrough + blank→`Nothing` normalization (property + unit); duplicate-category
  allocations preserved (not merged).
- **Persistence**: `allocParser` round-trips comment; missing key → `Nothing`.
- **Resolve** (`ResolveSpec`): multi-line prompt → N allocations; per-line comment threaded
  through unchanged (the LLM supplies the extracted item text; the resolver does not rewrite
  it); per-line category resolution + default fallback; duplicate categories kept; total =
  sum.
- **Web**: `CategoryAmount` comment → `Allocation`; `TransactionResponse` echoes comment;
  round-trip comment preservation through set-allocations and amend.
- **Integration** (`TransactionPromptIntegrationSpec`): the issue's 5-line Ukrainian example →
  single expense, 5 allocations, correct total (1760), comments preserved, no-account →
  default account.
- **Reporting**: duplicate-category allocations sum correctly (comments ignored).

## Out of Scope

- Item-level / receipt modeling beyond category allocations (quantities, unit prices).
  Comments carry the raw item text; structured line-items are a separate, larger concept.
- Comment input surfaces for the Telegram and bank-import flows (they thread `Nothing`).
