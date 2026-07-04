---
status: draft
---

# Consistent Telegram "Recorded Transaction" Confirmation

## Summary

Every Telegram path that records a transaction — `/income`, `/expense`, `/transfer`, and the
natural-language prompt — currently confirms it differently:

| Path | Current reply | Source |
| --- | --- | --- |
| `/income` | `Income recorded: 4.50 UAH` | `handleIncomeDescription` (`Commands.hs:630`) |
| `/expense` | `Expense recorded: 4.50 UAH` | `handleExpenseDescription` (`Commands.hs:702`) |
| `/transfer` | `Transfer completed: 4.50 UAH` | `handleTransferDescription` (`Commands.hs:775`) |
| NL prompt | `✅ {free-form LLM interpretation}` | `runPrompt` (`Commands.hs:499-500`) |

Wording, verb tense, and emoji all differ; only amount + currency is shown; account and
category names, comments, and date are dropped; and the NL path echoes whatever free-form
string the LLM produced (which varies run to run). Users can't tell from the confirmation
*what* was actually recorded.

This spec introduces **one shared confirmation renderer** that all four paths call after a
transaction is recorded, producing the same rich, structured message built from the recorded
`TransactionData` (not from LLM text).

## Motivation

- **Consistency.** The four entry points should confirm identically — same layout, same
  fields, same emoji — regardless of how the transaction was entered.
- **Show what was recorded.** The confirmation should reflect the persisted transaction:
  kind, amount(s), account(s), each allocation's category + comment, date, and any labels.
- **Deterministic NL confirmation.** The NL path stops using the LLM's free-form `interp`
  string as its user-facing confirmation and instead renders the same structured view from
  the recorded data. Whether the now-unused `interp` string is logged for diagnostics is out
  of scope for this change — it is neither required nor prohibited.

## Non-Goals

- No change to the web/REST confirmation (`PromptAPI` / `TransactionAPI` keep returning
  structured JSON `TransactionResponse`). This renderer is Telegram presentation only.
- No change to how transactions are created, validated, or persisted.
- No change to the interactive command *flows* (category/amount/description prompts) — only
  their final success reply changes.

## Design

### Two pieces (pure formatting split from effectful resolution)

Following the project's "effects at the boundary" rule, the work splits in two.

**1. Pure renderer** in `src/Telegram/Formatting.hs`, alongside the existing
`formatTransactionLine` (which already takes a category/label name map):

```haskell
formatRecordedTransaction ::
  Map DictionaryEntryId Text -> -- category + label names
  Map AccountId Text ->         -- resolved account names
  TransactionData ->
  Text
```

No IO; fully unit- and property-testable. It renders the layout below by pattern-matching on
`td.transactionType` via the existing `allocationsOf` / `allAllocations` accessors, and reuses
`formatMoney`, `showCurrency`, `formatDate`.

**2. Effectful reply helper** in `src/Telegram/Commands.hs`:

```haskell
replyRecordedTransaction :: TelegramId -> Int64 -> TransactionData -> AppM ()
```

It:
1. Fetches the category/label name map via the existing
   `getDictionaryEntryNames telegramId :: AppM (Map DictionaryEntryId Text)`.
2. Resolves the relevant account names — `sourceAccountId` and (for transfers)
   `targetAccountId` — via `runDb (getAccount …)` → `.name`, collecting them into a
   `Map AccountId Text`. Missing accounts simply don't appear in the map.
3. Calls `sendMsg chatId (formatRecordedTransaction entryNames accountNames txData)`.

### Call-site changes

All four success branches already hold `txData :: TransactionData` in scope (the NL path
currently discards it as the third field of `TransactionCreated interp txId txData`). Each
success reply collapses to a single call:

- `handleIncomeDescription` (`Commands.hs:630`) → `replyRecordedTransaction telegramId chatId txData`
- `handleExpenseDescription` (`Commands.hs:702`) → same
- `handleTransferDescription` (`Commands.hs:775`) → same
- `runPrompt` / `handlePromptText` (`Commands.hs:499-500`) → same; the `interp` value is no
  longer sent to the user.

The existing `Failed failureReason` branches at each call site are **unchanged** — the
renderer is only reached on a non-failed status.

### Rename: `runPrompt` → `handlePromptText`

`runPrompt` is the only Telegram handler not following the `handle*` convention
(`handleIncome`, `handleExpense`, `handleTransferDescription`, `handlePromptCommand`, …). It
is renamed to `handlePromptText`. The name `handlePrompt` was rejected because it would
collide conceptually with `PromptService.handlePrompt`, which this function calls; reading
`handlePrompt` calling `PromptService.handlePrompt` invites confusion. `handlePromptText`
reads cleanly next to `handlePromptCommand` (the `/prompt` command entry point that delegates
to it) and against free-text message routing. All call sites are updated.

### Message format

One unified layout driven by `transactionType`.

**Expense / Income** — account is the source for expense, target for income; one bullet per
allocation:

```
✅ Expense recorded
20.00 UAH · Cash
• Coffee 4.50 — morning latte
• Snacks 15.50 — office
2026-07-04 14:30
```

- Line 2 is `<total> <currency> · <account>`, where the total is `sourceAmount` (expense) or
  `targetAmount` (income).
- One `• <category> <amount> — <comment>` line per allocation. `— <comment>` is omitted when
  the allocation has no comment. The category name falls back to the bare amount when the id
  is absent from the name map (mirrors `formatTransactionLine`).
- A single-allocation expense reads as header + amount line + one bullet + date — no special
  case; single and multi render through the same code path.

**Transfer** — no allocations; both amounts + rate when cross-currency:

```
✅ Transfer recorded
Cash → Savings
100.00 USD → 4150.00 UAH
Rate: 41.50
2026-07-04 14:30
```

A same-currency transfer shows a single amount line and no `Rate:` line.

Transfer-line degradation: an account absent from the name map falls back to its short id
(first 8 chars of the UUID, as `findAccountByShortId` uses), so the `A → B` line always
renders both endpoints and the arrow is never dropped.

**Adjustment.** `TransactionType` has a fourth constructor, `Adjustment` (single-account, no
allocations). It is not producible from any of the four Telegram paths in scope, but the
renderer must be total: it renders a generic single-account line —
`✅ Adjustment recorded` / `<amount> <currency> · <account>` / date — with no allocation
bullets. This keeps the function total without inventing UX for an unreachable path.

**Status marker.** The marker mirrors `formatTransactionLine` exactly: `Pending` (transfer
saga mid-flight) appends `  [Pending]` to the header; `Cancelled` appends `  [Cancelled]`;
`Completed` renders clean. `Failed` is never reached here — it is handled upstream at each
call site before the renderer is invoked. `Cancelled` is not producible for a freshly
recorded transaction either, but is handled for totality rather than left partial.

**Labels.** When `td.labels` is non-empty, a trailing `Labels: a, b` line is appended, names
resolved from the same map; omitted when empty.

**Header verbs.** `✅ Income recorded` / `✅ Expense recorded` / `✅ Transfer recorded` —
uniform "recorded", uniform ✅.

### Data flow

```
recorded TransactionData
        │
        ▼
replyRecordedTransaction (AppM)
   ├── getDictionaryEntryNames telegramId      -> Map DictionaryEntryId Text
   ├── runDb (getAccount source/target)        -> Map AccountId Text
   └── formatRecordedTransaction (pure)        -> Text  ──► sendMsg
```

## Error Handling

- The renderer is total: unresolved account or category ids degrade gracefully (account line
  omits the ` · <name>` suffix; category falls back to the bare amount). It never throws.
- Name-resolution failures (user/config not found) already return empty maps from
  `getDictionaryEntryNames`; account lookups return `Nothing` and are simply absent from the
  map. The confirmation still renders with amounts and date.
- The `Failed` status path is untouched and continues to surface the failure reason.

## Testing

Pure `formatRecordedTransaction` is the primary test surface (Hspec unit + QuickCheck where
useful), covering:

- Expense and income, single allocation and multiple allocations.
- Allocation with and without a comment.
- Same-currency transfer (one amount line, no rate) and cross-currency transfer (both amounts
  + rate).
- Unresolved category id → bare-amount fallback; unresolved account id → Expense/Income
  account suffix omitted, transfer endpoint falls back to short id.
- Empty labels → no `Labels:` line; non-empty → sorted, comma-joined.
- `Pending` / `Cancelled` status → header marker present; `Completed` → clean header.
- `Adjustment` → generic single-account line, no allocation bullets (totality guard).

Property angle: the total on line 2 equals the sum of rendered allocation amounts for
income/expense (guards against divergence between the summary line and the bullets).
Transfers are covered by example-based tests only (no allocation-sum analog).

The four call-site rewrites are exercised by existing Telegram handler tests; assertions on
the reply string are updated to the new format.

## Rollout

Single change set; no migration, no config, no event/DTO changes. Consistent with the
project's no-backward-compat phase — the old reply strings are simply replaced.
