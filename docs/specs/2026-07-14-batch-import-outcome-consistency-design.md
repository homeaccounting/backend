---
status: completed
date: 2026-07-14
---

# Batch-import outcome consistency

## Problem

Two Application services parse a batch of input rows and record one or more
transactions from them, tolerant of partial failure:

- **`BankImportService`** — consumes `[BankTransaction]` (parsed from a
  statement file via `StatementParser`, or pulled live), routes each by
  external account, and records it.
- **`Prompt.Transaction.Handler`** — consumes `[TransactionIntent]` (decoded
  from LLM JSON), resolves each against the user's data, and records it.

They rhyme but diverge in two ways that hurt clarity and robustness.

### 1. Bank collapses five distinct skip situations into `Right Nothing`

`importTransaction :: … → AppM (Either DomainError (Maybe TransactionId))`
returns `Right Nothing` for **five** unrelated outcomes:

| Situation | Site |
|---|---|
| already imported (dedup) | `BankImportService.hs:422` |
| external account not in link | `:426` |
| unsupported currency numeric code | `:449` |
| `mkMoney` construction failed | `:454` |
| account currency ≠ transaction currency | `:497` |

The *reason* survives only in a log line. The service result
(`AccountImportResult.skipped :: Int`) and the HTTP response
(`AccountImportSummary.skippedCount :: Int`) both reduce it to a bare count, so
a user who imports a file and sees "7 skipped" has no way to learn **why**.

`Right Nothing` is also a weak type: nothing stops a future edit from meaning a
sixth thing by it, and the two unit-test call sites that assert `Right Nothing`
cannot distinguish a dedup skip from a currency-mismatch skip.

### 2. Prompt fails the whole batch when one transaction is malformed

`parseRecordTransactionsFields` (`Intent.hs:147`) parses the `transactions`
array with `traverse`, so a single malformed element fails the entire decode.
The router (`PromptService.hs`) then treats that as a malformed body: it retries
once and, if still malformed, returns **502** — discarding every well-formed
transaction the model produced alongside the bad one. A user who says "coffee 45
cash, <something the model mangles>, taxi 120 cash" loses all three.

### Non-goal: unifying the row models

`BankTransaction` (a settled bank line: external account id, ISO numeric currency
code, MCC, hold flag, FX original amount) and `TransactionIntent` (an LLM's
free-text guess: text amounts in any language, optional account *names*,
allocation splits) are genuinely different domains. They must **not** be merged
into a shared row type, and there is deliberately **no shared outcome module**:
the two skip vocabularies differ (prompt never skips — its
record-over-default policy turns an unresolved account into a committed default,
never a skip), and every bank `SkipReason` constructor is bank-specific. Forcing
a shared type would make one consumer use a subset of the other's constructors —
coupling two things that only rhyme. The goal is **parallel shapes and
vocabulary**, not shared code.

## Design

Two independent, self-contained changes plus a small HTTP-contract change.
Each service keeps its own row type and its own aggregate shape.

### A. Bank: explicit per-transaction outcome

Replace the overloaded `Either DomainError (Maybe TransactionId)` with a
purpose-built sum in `BankImportService`:

```haskell
-- | Why a bank transaction was intentionally not committed (distinct from a
-- write failure). Each carries the human context that today is only logged.
data SkipReason
  = AlreadyImported            -- dedup hit
  | Unmapped                   -- external account absent from the link
  | UnsupportedCurrency Text   -- numeric currency code we cannot map
  | InvalidAmount Text         -- mkMoney construction failed (rare)
  | CurrencyMismatch Text      -- local account currency ≠ transaction currency
  deriving (Show, Eq)

-- | The outcome of attempting to import one bank transaction.
data ImportOutcome
  = Imported TransactionId
  | Skipped SkipReason
  | Failed DomainError
  deriving (Show, Eq)

importTransaction :: … → AppM ImportOutcome
```

Each existing `Right Nothing` site maps to its precise `Skipped …`
constructor, each `Left err` to `Failed err`, and `Right (Just id)` to
`Imported id`. Behavior is preserved exactly:

- `Unmapped` stays effectively dead in the batch path — `importMany` still
  looks the external account up and routes misses to `unresolved` *before*
  calling `importTransaction`, so `Unmapped` only surfaces when
  `importTransaction` is called directly (e.g. unit tests). This keeps the
  exported function total and self-contained without a redundant `unresolved`
  concept at the single-transaction level.

`importMany` / `groupAccountResults` fold `ImportOutcome` instead of
`Either _ (Maybe _)`, mapping `Skipped r` into the account's rendered skip
list and `Failed e` into its rendered failure list.

`AccountImportResult.skipped` changes from `Int` to `[Text]` (rendered skip
reasons), mirroring how the existing `failed :: [Text]` renders `DomainError`
via `renderDomainError` — the doc comment's stated reason ("keeps the type
JSON-serializable without dragging `DomainError` into the response contract")
applies identically to `SkipReason`. A `renderSkipReason :: SkipReason → Text`
produces messages like `"already imported"` and
`"currency mismatch: account is USD but the transaction is UAH"`.

### B. Prompt: per-element decode tolerance

Make the array parse per-element instead of all-or-nothing, carrying a **typed**
per-element error (not raw `Text`). It is deliberately __not__ named `RowError`:
in bank a file "row" is one transaction, but a prompt transaction spans multiple
allocation lines, so "row"/"line" is the wrong word here — and the prompt code
already calls a transaction's list position `index` (on `FailedTransaction` /
`RecordedTransaction`). The type is therefore a prompt-local
`TransactionDecodeError` carrying only the reason; its position is the
transaction's `index`, assigned by the consumer's enumeration:

```haskell
-- | One 'transactions' element the model returned that failed to decode.
-- Prompt-local; carries only the reason. Its position is the transaction's
-- 'index' (as on FailedTransaction/RecordedTransaction), assigned by the
-- consumer — so the type needs no index of its own. NOT the bank
-- 'Infrastructure.Banking.Provider.RowError': a prompt transaction is
-- multi-line (allocations), so a file-"row" concept does not transfer.
newtype TransactionDecodeError = TransactionDecodeError Text
  deriving (Show, Eq)

-- 'transactions' must be present and an array (a structural failure otherwise);
-- each element is Right ti OR Left (TransactionDecodeError …). One bad element no
-- longer fails the batch. Structural failure (missing / non-array 'transactions')
-- still fails the whole parse — see the implementation note below.
parseRecordTransactionsFields :: Object -> Parser [Either TransactionDecodeError TransactionIntent]

data PromptIntent = RecordTransactionsIntent [Either TransactionDecodeError TransactionIntent]
```

`runRecordTransactions` (`Handler.hs:134`) takes
`[Either TransactionDecodeError TransactionIntent]` and, per element:

- `Left (TransactionDecodeError msg)` → `FailedTransaction { index = idx, reason = msg }`
  (a decode failure), where `idx` is the position from the handler's `zip [0..]` —
  the single source of `index` for both good and bad rows.
- `Right ti` → the existing resolve + commit path (→ `RecordedTransaction` or
  `FailedTransaction`).

**Implementation note (the crux of preserving 502).** `parseRecordTransactionsFields`
must *hard-fail* (Aeson `fail`, → `MalformedResponse` → envelope-malformed path)
when `transactions` is absent or not an array — a structural fault — while
*recovering* a per-element parse failure into `Left TransactionDecodeError`
rather than failing the traversal. Concretely: read `transactions` as `[Value]`
(hard fail if absent/non-array), then run `parseTransactionFields` on each element
via `parseEither`, mapping its `Left` to a `TransactionDecodeError` and its
`Right` to `Right ti`.

Router retry/error semantics, keyed on **usable (`Right`) rows** rather than
list length:

- envelope malformed (invalid JSON / no `intent` / `transactions` absent or not
  an array) → retry once, then **502** — unchanged;
- ≥ 1 usable row → dispatch: commit the good rows, report the bad ones as
  `FailedTransaction`, return **200** with the mixed `PromptResult`. **This is
  the new behavior** — a partially-malformed batch no longer fails wholesale;
- zero usable rows → retry once, then **400** ("couldn't identify a
  transaction"). This unifies two former cases: the empty array (`[]`, already
  400 today) and a **non-empty array whose every element is malformed** (today
  **502**). The latter is a deliberate **502 → 400 reclassification**: the
  envelope parsed cleanly, so it is not an upstream outage; 400 "couldn't
  identify a transaction" is the honest status. This also changes
  `decodePromptIntent`'s contract — a recognized intent whose element payloads
  do not parse is no longer `MalformedResponse` — so its doc comment
  (`Types.hs:64-66`) and the decoder-level tests below must be updated.

### C. HTTP contract (approved: surface skip reasons)

`AccountImportSummary.skippedCount :: Int` becomes `skipped :: [Text]` (rendered
reasons); `importedCount` and `failureCount` are unchanged.
`toImportResponse` (`BankingAPI.hs:536`) passes `acc.skipped` straight through
(both are now `[Text]`). This breaks the DTO — acceptable under the project's
no-backward-compat policy — and requires a matching field change in the web
client (`../monorepo`), tracked as a follow-up to this backend change.

Example response fragment:

```json
{ "accounts": [ { "externalAccountId": "…", "localAccountId": "…",
                  "importedCount": 12,
                  "skipped": ["already imported", "already imported",
                              "currency mismatch: account is USD but the transaction is UAH"],
                  "failureCount": 0 } ],
  "unresolved": [] }
```

### Consistency (vocabulary), stated plainly

The two services already share the `succeeded` / `failed` field vocabulary and
the "commit-good / report-bad, partial-failure-tolerant, per-row" model. The
substantive alignment this design delivers is the two **parallel shapes** above:
an explicit per-row outcome (A) and a per-row-tolerant parse mirroring
`StatementParser`'s `… → Either WholeError [Either RowError Row]` (B). No
cosmetic renames are introduced beyond `skipped`'s type change.

## Scope boundaries

- **In:** bank `ImportOutcome`/`SkipReason`; `AccountImportResult.skipped` and
  `AccountImportSummary.skipped` as `[Text]`; prompt per-element tolerance;
  updates to the affected unit/integration tests; the web-client field rename
  (noted as a follow-up in `../monorepo`).
- **Out (recommended follow-up, separable):** surfacing bank *failure* reasons
  the same way (`failureCount :: Int` → `failed :: [Text]`). `AccountImportResult`
  already carries `failed :: [Text]`; the count is dropped only at the web
  boundary. Surfacing skip-but-not-failure reasons is mildly asymmetric, but
  this change stays within the approved scope; the symmetric failure change can
  follow.
- **Out:** any shared outcome module; any change to `BankTransaction`,
  `TransactionIntent`, the resolver, or the write path
  (`TransactionService.initiate*`).

## Testing

- **Bank unit (`BankImportServiceSpec`)** — the ~13 `importTransaction` cases
  that assert `Right Nothing` / `Right (Just _)` / `Left _` become
  assertions on `Skipped <reason>` / `Imported _` / `Failed _`. The dedup and
  unmatched-account cases gain a precise reason assertion (`AlreadyImported`,
  `Unmapped`) they could not make before. Add a case asserting a
  currency-mismatch `Skipped (CurrencyMismatch …)`.
- **Bank integration (`BankImportWorkflowSpec`)** — `.skipped` is now `[Text]`;
  count assertions become `length … .skipped` (e.g. the `sum (map (.skipped) …)`
  at `:523`) and gain reason-content checks where a skip is expected.
- **Bank file API (`test/Web/API/BankImportFileAPISpec.hs`)** — asserts the DTO
  field directly: `KeyMap.lookup "skippedCount" row == Just (Number …)` (`:263`,
  `:308`). The rename to `skipped :: [Text]` changes both the key **and** the
  JSON type (`Number` → `Array`); update these assertions.
- **Prompt decoder (`test/Application/Services/Prompt/Transaction/IntentSpec.hs`,
  `test/Application/Services/Prompt/TypesSpec.hs`)** — the
  `decodeRecordTransactions` / `decodePromptIntent` cases now return
  `[Either TransactionDecodeError TransactionIntent]` /
  `RecordTransactionsIntent [Either …]`, so pattern matches like `Right [ti]` and
  `RecordTransactionsIntent [ti]` change shape. Two cases **reclassify** and must
  be rewritten, not just retyped: `TypesSpec.hs:47-50` ("… bad element as
  malformed", asserts `isMalformed`) and `IntentSpec.hs:120-122` ("rejects a
  transactions element with a bad payload", asserts `isLeft`) — a bad element is
  now a recovered `Left TransactionDecodeError` inside a `Right` list, not a
  whole-parse failure.
- **Prompt router/integration** — add cases: (a) an array with one malformed and
  one good element records the good one and reports the bad one at its index
  (HTTP 200); (b) a non-empty all-malformed array → 400 after retry (the
  reclassified path); (c) an envelope-level malformed body still 502s after
  retry (`TransactionPromptIntegrationSpec` already covers the envelope-junk
  cases at `:239`, `:248` — confirm they still 502).

## Files touched

- `src/Application/Services/BankImportService.hs` — new types; `importTransaction`,
  `importMany`, `groupAccountResults`; `AccountImportResult.skipped`;
  `renderSkipReason`.
- `src/Application/Services/Prompt/Transaction/Intent.hs` — `TransactionDecodeError`,
  `parseRecordTransactionsFields`, `decodeRecordTransactions`.
- `src/Application/Services/Prompt/Types.hs` — `PromptIntent`, `decodePromptIntent`
  (and its doc comment re the reclassification).
- `src/Application/Services/Prompt/Transaction/Handler.hs` — `runRecordTransactions`.
- `src/Application/Services/PromptService.hs` — retry/dispatch on usable rows.
- `src/Web/API/BankingAPI.hs` — `AccountImportSummary.skipped`, `toImportResponse`.
- Tests: `test/Application/Services/BankImportServiceSpec.hs`,
  `test/Integration/BankImportWorkflowSpec.hs`,
  `test/Web/API/BankImportFileAPISpec.hs`,
  `test/Application/Services/Prompt/Transaction/IntentSpec.hs`,
  `test/Application/Services/Prompt/TypesSpec.hs`, and the prompt router/
  integration specs (`PromptAPISpec`, `TransactionPromptIntegrationSpec`).
- `../monorepo` (web client) — matching `skipped` field rename (follow-up).
