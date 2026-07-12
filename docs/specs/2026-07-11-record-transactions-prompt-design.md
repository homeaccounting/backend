---
status: completed
date: 2026-07-11
issue: homeaccounting/tracker#39
supersedes: homeaccounting/backend#128
---

# Record one or more transactions from a single prompt (`record_transactions`)

## Problem

The natural-language prompt path (#86) currently exposes a single
`create_transaction` intent (envelope discriminator `"intent": "transaction"`)
that records exactly **one** transaction, whose lines may be split across
categories via `allocations`. A pasted multi-item capture that is really
*several distinct transactions* (mixed kinds/accounts) cannot be expressed —
`allocations` only split one payment.

An earlier slice (backend#128, unmerged) tried a second sibling intent,
`import_transactions`, so the model would classify single-vs-multi. That
classification is unreliable: "one payment split across categories" vs "several
distinct transactions" is genuinely ambiguous from free text, so a pasted
multi-line capture was mis-routed. #128 also aimed at structured bank exports,
where the LLM is the wrong tool (truncation, non-determinism, fragile
output-keyed dedup); that path moves to deterministic banking import (#38),
out of the LLM entirely.

On `master`, only `create_transaction` exists — `import_transactions`,
`Prompt/Import/*`, and the dedup module never landed here. So this is a clean
generalization of the single-transaction path, not a revert.

## Proposal

Collapse the transaction prompt into a **single `record_transactions` intent
whose payload is a list of 1..N transactions**, each carrying the existing rich
transaction shape, with allocations nested per transaction:

```jsonc
{ "intent": "record_transactions",
  "transactions": [
    { "kind": "expense", "sourceAccount": "ATB",
      "allocations": [ {"amount":"20","category":"Food"}, {"amount":"15","category":"Food"} ] }, // one split payment
    { "kind": "income", "targetAccount": "Bank", "amount": "5000" }                              // a distinct transaction
  ] }
```

The model **never classifies single-vs-multi** — it emits however many
transactions it identifies. Allocations stay *within* a transaction only to
split one payment across categories. This removes the ambiguity by construction
(no competing intent).

- `cash 123 food` → list of **1**.
- `ATB: milk 20, bread 15` → **1** transaction, 2 allocations.
- `salary 5000 to bank, coffee 45 cash, taxi 120 cash` → **3** transactions.

Deduplication is dropped entirely: free-text capture is one-shot, not import.
(`BankImportService` keeps the `externalId` dedup it owns — unaffected, and not
touched here.)

## Approach

Generalize the existing `Application.Services.Prompt.Transaction.*` modules in
place. `master`'s single-transaction code is already structured the way #39
wants the per-element path to behave: `resolveIntent` is pure and
per-transaction, and commit is a per-element dispatch to
`TransactionService.initiate{Income,Expense,Transfer}`. So the change wraps the
element-level logic in a list rather than introducing a new module tree
(rejected: it would duplicate the resolver and commit dispatch for no gain).

The generic envelope / exhaustive-dispatch machinery (`Prompt/Types.hs`,
`Prompt/Builder.hs`) is retained: it is the extensibility seam for future
intents (e.g. `report`), and `record_transactions` is simply its sole current
member.

### 1. Intent shape — `Prompt/Transaction/Intent.hs`

- `transactionIntentName` value `"transaction"` → `"record_transactions"`
  (the module-level constant is renamed to `recordTransactionsIntentName`).
- `TransactionIntent` (the per-element type) is **unchanged**: it already carries
  `kind`, `amount` (transfer total), `allocations`, `currency`, `sourceAccount`,
  `targetAccount`, `description`, `date`. Its element JSON no longer carries an
  `intent` field — `intent` lives at the envelope level, which the element
  parser already ignores.
- Add `parseRecordTransactionsFields :: Object -> Parser [TransactionIntent]`
  reading the `transactions` array, each element via the existing
  `parseTransactionFields`. `transactions` is required and must be a JSON array.
- `transactionSchema` → `recordTransactionsSchema`: an object with `intent`
  (const `record_transactions`) and `transactions` (array of the existing
  per-element object schema).
- `transactionGuide` → `recordTransactionsGuide`: describes the `transactions`
  wrapper and states the rule with contrasting few-shot examples —
  **separate list elements = distinct transactions** (own account/date/kind);
  **allocations = split one payment across categories**. Reuses the existing
  single / split-payment / Ukrainian examples and adds a mixed-multi example
  (`salary 5000 to bank, coffee 45 cash, taxi 120 cash` → 3 elements). Each
  example is wrapped in the `{"intent":"record_transactions","transactions":[…]}`
  envelope.

### 2. Envelope, result, dispatch — `Prompt/Types.hs`

- `PromptIntent`: `CreateTransactionIntent TransactionIntent` →
  `RecordTransactionsIntent [TransactionIntent]`. `decodePromptIntent`'s
  name-dispatch matches `recordTransactionsIntentName` and calls
  `parseRecordTransactionsFields`.
- `PromptResult`: `TransactionCreated {interpretation, txId, tx}` →

  ```haskell
  data PromptResult = TransactionsRecorded
    { succeeded :: ![RecordedTransaction]
    , failed    :: ![FailedTransaction]
    }

  data RecordedTransaction = RecordedTransaction
    { index :: !Int, interpretation :: !Text, txId :: !TransactionId, tx :: !TransactionData }

  data FailedTransaction = FailedTransaction { index :: !Int, reason :: !Text }
  ```

  `index` is the 0-based position in the `transactions` list, carried on both the
  success and failure halves. `interpretation` is
  retained per recorded transaction for Telegram/logging; the HTTP DTO omits it
  (see §4). No `skipped` variant — dedup is gone.

### 3. Handler — `Prompt/Transaction/Handler.hs`

- `runCreateTransaction` → `runRecordTransactions :: UserId -> ResolveContext ->
  Text -> [TransactionIntent] -> AppM (Either DomainError PromptResult)`.
- **Commit-good / report-bad per element.** For each `(index, ti)` (0-based):
  1. run pure `resolveIntent`; on `Left (ResolveError f m)` → `FailedTransaction`
     with a reason built from field+message; else
  2. commit via the existing `dispatch` (initiate{Income,Expense,Transfer});
     on commit `Left DomainError` → `FailedTransaction` (reason from the domain
     error); else a `RecordedTransaction`.
  Both outcomes carry the transaction's `index`. Transactions are independent —
  one failure never blocks the others (matches per-aggregate event-sourced writes
  and #39's explicit "commit-good/report-bad per transaction"). The function
  returns `Right (TransactionsRecorded …)` even when some transactions failed; it
  returns `Left DomainError` only for a whole-request infrastructure failure
  (none in the normal per-transaction path).
- `gatherContext` is unchanged.

### 4. HTTP — `Web/API/PromptAPI.hs`

Response follows #39 exactly:

```jsonc
{ "kind": "transactions",
  "succeeded": [ <TransactionResponse>, … ],
  "failed":    [ { "index": <int>, "reason": <text> }, … ] }
```

A single capture is `succeeded` of length 1. This **drops the top-level
`interpretation`** field emitted today (`kind:"transaction"` →
`kind:"transactions"`). Client-facing change, acceptable — no back-compat phase;
the web client is updated separately. `succeeded` items are built with the
existing `fromTransactionData txId tx`.

### 5. Router edge cases — `PromptService.hs`

`handlePrompt` is unchanged in structure (feature-gate → context → LLM call →
decode → dispatch, with one retry on a malformed body). Two adjustments:

- Dispatch calls `Txn.runRecordTransactions` with the decoded list.
- **Empty `transactions`**: if the model returns an empty array, treat it like a
  malformed body — retry once with the "return only valid JSON" nudge; if it is
  still empty, surface a friendly `PromptDomainError` 400 ("couldn't identify a
  transaction in that text") rather than a 502. (A non-empty request text that
  yields zero transactions is a comprehension miss, not an upstream outage.)

### 6. Telegram — `Telegram/Commands.hs`

`handlePromptText` matches the new `TransactionsRecorded` result and replies
with a **full structured confirmation block per recorded transaction** (reuse
`replyRecordedTransaction` for each), then, if `failed` is non-empty, a single
follow-up message listing the failed transactions (`transaction N: reason`, N
being `index + 1`). A single recorded
transaction therefore keeps today's exact rich confirmation with no
special-casing. Feature-disabled / upstream / domain-error branches are
unchanged.

## Data flow

```
user text
  → handlePrompt (feature gate, gather context, build messages)
  → LLM → decodePromptIntent → RecordTransactionsIntent [TransactionIntent]
  → runRecordTransactions: per element (0-based index)
        resolveIntent (pure) ─ Left ─→ FailedTransaction
              │ Right
              ▼
        initiate{Income,Expense,Transfer} ─ Left ─→ FailedTransaction
              │ Right
              ▼
        RecordedTransaction
  → PromptResult { succeeded, failed }
  → Web: kind:"transactions" {succeeded:[TransactionResponse], failed:[{index,reason}]}
  → Telegram: rich confirmation per recorded + failures note
```

## Error handling

| Situation | Result |
|---|---|
| LLM feature disabled | `PromptFeatureDisabled` → 503 |
| LLM unreachable / unparseable after retry | `PromptUpstreamError` → 502 |
| Envelope names an unknown intent | 400 ValidationErr (unsupported request) |
| Empty `transactions` after retry | 400 ValidationErr ("couldn't identify a transaction") |
| A row fails to resolve or commit | that row → `failed`; others still commit |
| Empty prompt text | 400 ValidationErr (unchanged) |

## Testing (TDD: property/unit → integration)

- `IntentSpec` — decode the `record_transactions` envelope into
  `[TransactionIntent]` (single, split-payment, mixed-multi); reject a missing /
  non-array `transactions`; guide contains the contrasting examples.
- `ResolveSpec` — the per-element resolver is unchanged; existing cases stay
  green.
- `TypesSpec` — `decodePromptIntent` → `RecordTransactionsIntent`; unknown
  intent → `UnknownIntent`; malformed → `MalformedResponse`.
- `PromptAPISpec` — `TransactionsRecorded` serializes to
  `kind:"transactions"` with `recorded`/`failed` arrays.
- `TransactionPromptIntegrationSpec` — end-to-end via in-memory store:
  single→1 recorded; split-payment→1 recorded with 2 allocations; mixed→3
  recorded (income + 2 expenses); **partial failure** (one bad account among
  several) → good ones in `succeeded`, bad one in `failed`; empty text → 400.

## Out of scope

- Structured statement file import (→ #38, deterministic banking subsystem).
- Deduplication of any kind on the prompt path.
- Multi-turn / propose-then-confirm — auto-commit in one shot, as today.
