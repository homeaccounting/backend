---
status: completed
---

# Import-Time Internal Transfer Detection

## Problem

When a user links two of their own bank accounts (e.g. two Monobank cards/jars) and
imports from both, an internal transfer between them is reported on **both**
statements — a debit on card A and a credit on card B. `BankImportService` processes
every statement line independently and routes each through the synthetic **External**
account, so one real money movement becomes **two** transactions:

- Card A line (`amount < 0`) → `Expense` (local A → External), with an expense category.
- Card B line (`amount > 0`) → `Income` (External → local B), with an income category.

Two consequences:

1. **Report pollution.** The movement is booked as both spending and earning, inflating
   income and expense figures for money that never left the user's control.
2. **Balance corruption on manual correction.** When the user converts the A-leg into a
   real `Transfer A→B`, money now moves A→B directly, but the B-leg income (External→B)
   still stands. B is credited twice.

### Why the legs cannot be joined by a shared id

Monobank's personal API assigns a distinct statement-item `id` to each account's own
statement line; the two legs of an own-transfer are two separate items with different
ids. `BankTransaction.externalId` is that `id`
(`Infrastructure/Banking/Monobank/Internal.hs`, `externalId = extId` from `ms.stmtId`).

This is confirmed by the bug itself: deduplication keys on `externalId` with a `UNIQUE`
constraint (`BankImportReadModel.UniqueExternalTransactionId`, checked by `isImported`).
If both legs shared an id, the second import would hit `AlreadyImported` and be skipped —
yielding one transaction. The observed double-import proves the ids differ. The Monobank
API also exposes no shared reference and no counterparty account id
(`MonoStatement` carries only `id`, `time`, `description`, `mcc`, `amount`,
`operationAmount`, `currencyCode`, `hold`, `comment`). An exact join is therefore
impossible; detection must be heuristic.

### Validation against the live Monobank API

Checked against the Monobank open API (`v250818`) `GET /personal/statement/{account}/{from}/{to}`
`StatementItem` schema. Findings that back this design:

- **The heuristic's inputs are all present and already mapped.** `amount` is signed and in
  the account currency, `currencyCode` is the ISO-4217 numeric code, and `time` is unix
  seconds — exactly what `defaultTransferMatcher` uses, and exactly what
  `Monobank/Internal.hs` already maps into `BankTransaction`. No adapter change is needed.
- **No shared reference; no usable counterparty for personal accounts.** The counterparty
  fields `counterIban` / `counterEdrpou` are **ФОП (business) accounts only** and are empty
  for regular personal cards and jars; there is no `counterName` field at all. So for
  personal Monobank there is no signal stronger than the heuristic — the default matcher is
  not a shortcut but the only viable strategy, and the shared-id join is confirmed
  impossible from the schema, not just inferred from the bug.
- **An own-account transfer is two opposite-signed items with no link.** A card→jar (or
  card→card) move appears as one `StatementItem` per account with opposite-signed `amount`;
  a same-currency own transfer has equal magnitudes. Own transfers are commission-free, so
  magnitudes match. Were a commission ever bundled into one leg, equal-magnitude would fail
  and the pair would **safely fall through to income/expense** rather than mispair.
- **The `TransferMatcher` seam is justified by a real future consumer.** Monobank **ФОП**
  statements *do* populate `counterIban`; a business-account integration could later supply
  a `counterIban`-equality `TransferMatcher` with zero engine changes — the exact
  extension point this design adds.

## Goals

- Detect an internal transfer between two of the user's linked accounts **at import time**
  and post it as a single `Transfer`, so it is never double-booked.
- Deduplicate on **both** legs' external ids, so a re-sync never re-imports either leg.
- Leave the existing income/expense import path unchanged for every transaction that is
  not part of a detected internal-transfer pair.

## Non-goals

- **Cross-currency own-transfers** (e.g. UAH card → USD jar): legs differ in both currency
  and magnitude and can only be matched via a derived FX rate. Deferred; these keep the
  current income/expense behaviour and are a documented follow-up.
- **Backfilling existing double-imported history.** This change is forward-only. Pairs
  already recorded in the event store are left as-is; a reconciliation effort, if wanted,
  is separate.
- **Cross-provider internal transfers.** A single import batch is one provider connection,
  so a transfer between accounts at two different providers (e.g. a Monobank card and a
  PrivatBank card) will not pair. The mechanism is provider-neutral in *shape* (any
  provider can plug in a matcher), but pairing across two providers in one pass is out of
  scope.

## Approach

Detection is inherently cross-account application logic (it needs the user's account link
and both accounts' transactions together), so it lives in the shared import sink
`importMany`, which already receives the full batch and the full
`[(ExternalAccountId, AccountId)]` link. `importMany` runs a **pure pairing pre-pass** that
partitions the batch into internal-transfer pairs and leftovers; pairs become one
`Transfer` posting, leftovers flow through the unchanged `importTransaction` path.

### Provider- and transport-neutral by construction

The mechanism must serve **all** bank providers and **both** transports (live pull and
file import), not just Monobank pull. Two design choices guarantee that:

1. **Transport neutrality — already structural.** `importMany` is the single sink both the
   pull path (`importConnection`) and the file-import path (`importStatementFileHandler`)
   route through. The pairing pre-pass lives there, so it applies to both transports with
   no per-transport code. The pull path additionally needs the fetch-all restructure
   (below) so both legs land in one batch; the file path already passes the full batch.

   Because pairing is within-batch and pure, both legs must arrive in **one** batch: the
   pull path's fetch-all restructure guarantees this across a connection's accounts, and
   file import pairs when the uploaded statement is **multi-account** (both legs in one
   file). Separate per-account file uploads do not pair — the second leg falls through to
   income/expense via the partial-dedup path. This is the same "same-batch" scoping as the
   cross-provider non-goal, not a provider-specific gap.

   **PrivatBank (file-import only).** Validated against real Privat24 exports: statements
   are **per-card**, so an own-card transfer's two legs live in two separate files. To
   detect them, the user merges both cards' data rows into one file (one shared
   preamble+header) and imports it against a connection whose `accountMap` maps each card
   mask to a **distinct** local account — see *PrivatBank workflow* below. In that merged
   batch, PrivatBank's own signal makes detection precise: both legs are self-labeled with
   the counterpart card's last four digits — the outgoing leg as
   `Переказ на свою картку` / `На свою картку *NNNN`, the incoming leg as
   `Зарахування зі своєї картки` / `Зі своєї картки *NNNN`. PrivatBank therefore plugs a
   **self-label `TransferMatcher`** into the generic seam (see Component 0), pairing far
   more precisely than the bare amount+time heuristic would in a noisy multi-month
   statement.

2. **Provider neutrality — one cohesive interpretation capability.** The heuristic is the
   *default*, not the only, way to recognise a transfer. Rather than bolt a second loose
   hook onto `BankProviderDescriptor` next to the existing
   `classify :: BankTransaction -> TransactionClassification`, both facets of "how a
   provider reads its raw statement lines into domain intents" are grouped into one
   capability:

   ```haskell
   newtype TransferMatcher = TransferMatcher
     { matchesTransfer :: BankTransaction -> BankTransaction -> Bool }

   data TransactionInterpretation = TransactionInterpretation
     { classify        :: BankTransaction -> TransactionClassification  -- 1-ary: direction
     , transferMatcher :: TransferMatcher                               -- 2-ary: same-movement
     }
   ```

   `BankProviderDescriptor` carries `interpretation :: TransactionInterpretation`
   (replacing the standalone `classify` field). `defaultInterpretation` pairs
   `defaultClassify` with `defaultTransferMatcher` (opposite-sign + equal-magnitude +
   same-currency + within-window); every provider with no stronger signal (Monobank,
   PrivatBank) uses it. A provider that *does* expose a stronger transfer signal — a
   shared reference id, a counterparty account/IBAN — supplies its own `TransferMatcher`
   inside its `TransactionInterpretation` without touching the engine.

   This grouping fixes a cohesion smell (two parallel provider hooks answering the same
   kind of question would invite a third and a fourth) while keeping the two questions
   distinct by arity. It deliberately does **not** fold pairing into a single
   batch-classifier: the pure engine `pairInternalTransfers` still takes a bare
   `TransferMatcher` and owns the **provider-independent invariants** (legs on *different*
   linked accounts, one-to-one, deterministic order). Pushing the pairing algorithm into
   providers would reintroduce the very leak of the rejected "provider-layer
   pre-processing" alternative.

   The capability is threaded as **one** parameter: the connection→provider resolvers in
   `ConfigurationService` return `desc.interpretation`, and the Web handlers pass it into
   `importConnection` / `importMany`. The service pulls `interpretation.classify` and
   `interpretation.transferMatcher` apart at the point of use, staying provider-agnostic
   (it consumes a `TransactionInterpretation`, never a descriptor).

Alternatives rejected:

- **Reactive convert-to-transfer guard** (cancel the opposite phantom leg when the user
  converts a leg): reactive, depends on user action, and moot under the forward-only scope.
- **Provider-layer pre-processing** (pair inside the Monobank adapter): the adapter fetches
  one account at a time and must not know about the user's account link.

## Components

### 0. `TransactionInterpretation` capability (`Infrastructure.Banking.Provider`)

Replace the standalone `classify` field on `BankProviderDescriptor` with a grouped
capability, and add the transfer-matching pieces:

```haskell
newtype TransferMatcher = TransferMatcher
  { matchesTransfer :: BankTransaction -> BankTransaction -> Bool }

data TransactionInterpretation = TransactionInterpretation
  { classify        :: BankTransaction -> TransactionClassification
  , transferMatcher :: TransferMatcher
  }

defaultTransferPairingWindow :: NominalDiffTime  -- ~5 minutes
defaultTransferMatcher :: NominalDiffTime -> TransferMatcher
defaultInterpretation :: TransactionInterpretation
-- = TransactionInterpretation defaultClassify (defaultTransferMatcher defaultTransferPairingWindow)
```

`defaultTransferMatcher window` returns a matcher that is `True` iff the two legs have the
**same `currencyCode`**, **opposite signs**, **equal magnitude**, and timestamps within
`window`. The **Monobank** descriptor uses `defaultInterpretation`. The matcher decides
*only* the "same movement?" question — it does **not** check the account link or the
different-account rule (those are engine invariants).

**PrivatBank self-label matcher** (`Infrastructure.Banking.PrivatBank`). PrivatBank marks
own-card transfers on both legs with the counterpart card's last four digits, so it
overrides the heuristic with a precise matcher:

```haskell
-- Extract the counterpart own-card's last-4 from a self-labeled row, else Nothing:
--   "На свою картку *NNNN"    (outgoing, category "Переказ на свою картку")
--   "Зі своєї картки *NNNN"   (incoming, category "Зарахування зі своєї картки")
ownCardCounterpartLast4 :: BankTransaction -> Maybe Text

privatBankTransferMatcher :: NominalDiffTime -> TransferMatcher
-- True iff: opposite signs, equal magnitude, same currencyCode, within window, AND
-- at least one leg's ownCardCounterpartLast4 equals the last-4 of the other leg's
-- externalAccountId (card mask). Bidirectional confirmation is the common case.

privatBankInterpretation :: TransactionInterpretation
-- = TransactionInterpretation defaultClassify (privatBankTransferMatcher defaultTransferPairingWindow)
```

The PrivatBank descriptor sets `interpretation = privatBankInterpretation`. Own-transfers
from the sole-proprietor (ФОП) account (`Зарахування … Переказ власних коштiв`, no card
last-4) carry no card signal and are **not** paired — their counterpart lives in a separate
ФОП statement — so they fall through to income/expense, which is correct.

### 1. Pure pairing function

New small module (e.g. `Application.Services.BankImport.TransferPairing`). Application may
import `BankTransaction` and `TransferMatcher` from `Infrastructure.Banking.Provider`; the
function itself is pure.

```
pairInternalTransfers
  :: TransferMatcher
  -> [(ExternalAccountId, AccountId, BankTransaction)]
  -> ([InternalTransfer], [(ExternalAccountId, AccountId, BankTransaction)])
```

`InternalTransfer` records the debit leg, the credit leg, and each leg's local account.

A candidate pair requires **all** of:

- the two legs resolve to **different local accounts** (`localX /= localY`) — *engine
  invariant*. This is keyed on the **local** account, not the external id/card: one local
  account can own **multiple cards** (e.g. a PrivatBank universal card `…2222` and its
  additional card `…3333` share one balance), so two sibling-card legs map to the *same*
  local account and must **not** be treated as a transfer. Checking the local account
  subsumes the weaker "different card" check (same card → same local; sibling cards → same
  local; both rejected) and correctly rejects a within-account card-to-card move as a
  degenerate self-transfer.
- both external accounts are present in the caller's link — guaranteed because the input
  is the already-matched triples (unmatched rows go to `unresolved` upstream);
- `matchesTransfer` of the provider's `TransferMatcher` returns `True` for the two legs —
  for the default matcher this is opposite signs + equal magnitude + same `currencyCode` +
  within `defaultTransferPairingWindow`.

Pairing is greedy and one-to-one: each transaction is consumed at most once. When several
legs collide on the same key, pairing is deterministic (order by `time`, then `externalId`)
and any remainder is left unpaired. The result is a partition:
`leftovers ∪ (all paired legs) = input`.

**Residual false-positive risk.** Because detection is heuristic, two *unrelated*
transactions — an expense on one linked account and an income on the other of equal
magnitude, same currency, within the window — would be mis-paired as a transfer. The
tight `transferPairingWindow` is the primary mitigation; the test matrix must cover this
boundary. The window value can be tuned if false positives are observed in practice.

The resulting transfer's `description` and `at` are taken from the **debit leg** (a
deliberate default, not a hard requirement — the debit side is the money-out origin).

### 2. `importMany` pre-pass

`importMany` takes a `TransactionInterpretation` (replacing its `classify` parameter);
`interpretation.classify` feeds the leftover income/expense path and
`interpretation.transferMatcher` feeds the pairing engine.

1. Route the batch as today into matched `(extAcc, localAcc, tx)` triples; transactions
   whose external account is absent from the link still go to `unresolved`.
2. Run `pairInternalTransfers interpretation.transferMatcher` over the matched triples.
3. **Each pair →** `importTransferPair` (new): skip if **either** leg is already
   `isImported`; otherwise build one `InitiateTransactionPosting`:
   - `transactionType = Transfer`
   - `sourceAccountId = debit leg's local account`, `targetAccountId = credit leg's local account`
   - `sourceAmount = targetAmount = magnitude`, `exchangeRate = Nothing` (same-currency)
   - `description = debit leg's description`, `at = debit leg's time`
   - `importInfo = Just ImportInfo { externalTransactionIds = both ids, mcc = Nothing }`
   - no External account, no category or contact resolution.
   On success, the resulting `TransactionId` is recorded under **both** external accounts'
   outcomes so both accounts' `succeeded` lists show it. A failure is likewise attributed
   to both accounts' `failed`.
4. **Leftovers →** existing `importTransaction` (income/expense), fully unchanged. This is
   the fallback: an unpaired leg — because the second account is not linked, or its partner
   is simply absent from the batch — imports exactly as today.
5. `groupAccountResults` is extended so a transfer contributes to two accounts.

### 3. `importConnection` restructure (pull path)

Today `importConnection` fetches and imports **per account** with a one-entry scoped link,
so `importMany` never sees two cards together and the pre-pass cannot fire. Restructure to:

1. Fetch **all** linked accounts' statements first, collecting per-account fetch failures.
2. Concatenate into one batch tagged by external account.
3. Run **one** `importMany interpretation userId fullLink allTxns`.
4. Re-group the flat result into the existing contract: one `AccountImportResult` per link
   entry, with zero-value rows for accounts that returned nothing and fetch failures still
   surfaced in `failed`. `unresolved` stays `[]` for a well-behaved provider.

The file-import path (`importStatementFileHandler`) already calls `importMany` with the full
multi-account link and needs no restructure beyond passing the `interpretation`.

### 3b. Threading the capability (`ConfigurationService` + `BankingAPI`)

The two connection→provider resolvers return the whole `interpretation` from the descriptor
in place of the bare classifier:

- `getConnectionProvider` → `(desc.interpretation, mkPull cred)`
- `getConnectionFileImport` → `(desc.interpretation, cap)`

`importConnectionHandler` and `importStatementFileHandler` pass the `interpretation`
straight into `importConnection` / `importMany`. Net parameter count is unchanged from
today (one classifier value became one interpretation value); no widening tuple.

### 4. `ImportInfo` dedup shape

Change `ImportInfo.externalTransactionId :: ExternalTransactionId` to
`externalTransactionIds :: NonEmpty ExternalTransactionId`; `mcc` is unchanged. A normal
income/expense import carries a one-element `NonEmpty`; a detected transfer carries both
legs' ids.

`BankImportReadModel.applyBankImportEvent` fans out: it inserts one `imported_transactions`
row per id (all mapping to the same `TransactionId`). `isImported` is unchanged, so after a
transfer import both legs are recorded and a re-sync skips them.

Blast radius is contained: the external id is read only by the dedup read model; the
transaction read model reads `mcc`, which stays `Maybe MCC`. Per the project's
no-backward-compat stance, the event/DTO shape change needs no upcaster.

### 5. Configuration

`defaultTransferPairingWindow` is a module constant (initially ~5 minutes) baked into
`defaultTransferMatcher`. Promotion to per-user/per-connection configuration is out of
scope; a constant is sufficient for the default heuristic (both cards post
near-simultaneously). A provider needing different behaviour supplies its own
`TransferMatcher` rather than tuning a global.

### 6. PrivatBank merge workflow (documented user step, no new UI)

PrivatBank internal-transfer detection requires both legs in one import batch. This stays a
**documented user workflow**, not new upload/merge code:

1. Export each card's Privat24 statement.
2. Merge them into one CSV: keep a **single** preamble + header, then append every card's
   **data rows** (each row already carries its own `Картка` mask). Do not repeat the
   title/header from the second file — those two lines would parse as junk rows and surface
   in `unresolved`.
3. Configure the PrivatBank connection's `accountMap` (`Map ExternalAccountId AccountId`,
   set via `ConfigurationService.setBankConnectionAccountMap`). The key is the **card mask**
   exactly as it appears in the file's `Картка` column (that is what the parser stores as
   `externalAccountId`). The map is **many-to-one**: every card of one account maps to that
   **same** local account (e.g. `…2222` and `…3333` → account B), while a card of a
   *different* account maps elsewhere (`…1111` → account A). Two accounts that hold a
   genuine transfer between them must therefore map to two **distinct** local accounts —
   but sibling cards of one account must share theirs. A single-entry `accountMap` is a
   trap: `importStatementFileHandler` routes *every* card in the file to the one target, so
   the engine's different-local-account check would (correctly) refuse to pair anything.
4. Import the merged file; the self-label matcher plus the different-local-account invariant
   collapse each genuine inter-account own-transfer into one `Transfer`, and ignore
   within-account card-to-card moves.

**Web-client dependency (separate `../monorepo` effort).** The backend contract is
unchanged, and the Monobank fix works with the current UI. But the web client today maps a
file-import connection with a single sentinel key (`accountMap = { "statement": accountId }`
in `BankConnectionDialog.tsx`) and gates the multi-account mapping dialog on `supportsPull`
(`ProfileBankingPane.tsx`), so a PrivatBank connection can only route the whole file to one
account. The merge workflow above therefore requires a client change: for
`supportsFile && !supportsPull` providers, allow mapping **multiple card masks → distinct
local accounts** via **manual entry** (no `fetchAccounts` discovery exists for file
providers). Until then, PrivatBank transfer detection is not reachable from the UI, though
the backend fully supports it. This is out of scope for this (backend) spec.

## Error handling

- **Currency-mismatch guard.** Leftover legs retain the existing guard (local account
  currency must equal the transaction currency). A paired transfer is same-currency by
  construction, and both local accounts are expected to match that currency; a mismatch on
  either leg skips the pair with a clear reason rather than initiating a doomed posting.
- **Partial dedup.** If exactly one of a pair's ids is already imported, do **not** drop the
  other leg. This case is legitimate: when the second account is linked *after* the first
  account's history was already imported as income/expense, leg A is already in
  `imported_transactions` while leg B is genuinely new. In that case the pair is **not**
  formed as a transfer; the un-imported leg falls through to the normal `importTransaction`
  income/expense path (and the already-imported leg stays skipped). This preserves the
  invariant that no genuinely-new statement line is ever silently dropped.
- **Pair posting failure.** Surfaced as a `Failed` outcome under both accounts; other
  transactions in the batch are unaffected.

## Testing

- **Property (`pairInternalTransfers`).** Partition invariant (`leftovers ∪ paired legs =
  input`); each transaction consumed at most once; non-matches never pair (different
  currency, different magnitude, outside the window, **same local account** — including two
  different cards that map to the same local account); pairing is symmetric in leg order.
- **Unit.** Two-leg batch → one `Transfer`, both dedup rows written, both accounts report
  the `TransactionId`; single leg → income/expense unchanged; re-run → skipped;
  cross-currency legs → **not** paired, fall through to income/expense; **partial dedup**
  (one leg already imported, partner new) → new leg imported as income/expense, not dropped;
  false-positive boundary (equal-magnitude unrelated income+expense just outside the window)
  → **not** paired.
- **Integration (pull).** `importConnection` over two linked accounts containing one
  internal transfer → a single `Transfer` and correct balances on both accounts.
- **PrivatBank self-label matcher (unit).** `ownCardCounterpartLast4` extracts `NNNN` from
  both `На свою картку *NNNN` and `Зі своєї картки *NNNN`, and `Nothing` for a normal row.
  `privatBankTransferMatcher` pairs an outgoing `*2222` leg with the `…2222` card's incoming
  leg (opposite sign, equal magnitude, same currency), and does **not** pair when the named
  last-4 differs, magnitudes differ, or a leg is a ФОП `Переказ власних коштiв` (no card).
- **Integration (file / PrivatBank).** A merged multi-account batch (two cards, each mapped
  to a distinct local account) containing the self-labeled `−20000 / +20000` own-card
  transfer → a single `Transfer`, proving provider- and transport-neutrality end-to-end.
  Use a small **synthetic** fixture distilled from the observed format (do not commit real
  statement data); include a decoy equal-amount unrelated pair to prove the self-label
  matcher does not mispair it.

## Affected code

- `src/Infrastructure/Banking/Provider.hs` — new `TransferMatcher`,
  `TransactionInterpretation`, `defaultTransferPairingWindow`, `defaultTransferMatcher`,
  `defaultInterpretation`, and the `interpretation :: TransactionInterpretation` field on
  `BankProviderDescriptor` (replacing the standalone `classify` field).
- `src/Infrastructure/Banking/Monobank.hs` — set `interpretation = defaultInterpretation`.
- `src/Infrastructure/Banking/PrivatBank.hs` — define `ownCardCounterpartLast4`,
  `privatBankTransferMatcher`, `privatBankInterpretation`; set
  `interpretation = privatBankInterpretation`.
- `src/Application/Services/ConfigurationService.hs` — `getConnectionProvider` /
  `getConnectionFileImport` return `desc.interpretation` from the descriptor.
- `src/Web/API/BankingAPI.hs` — handlers destructure and pass the matcher through.
- New `src/Application/Services/BankImport/TransferPairing.hs` — pure pairing engine
  consuming a `TransferMatcher`.
- `src/Application/Services/BankImportService.hs` — `importMany` pre-pass (`classify` param
  replaced by a `TransactionInterpretation` param), new `importTransferPair`,
  `groupAccountResults` extension, `importConnection` restructure (same param change).
- `src/Domain/Core/Types.hs` — `ImportInfo` field change and its accessor.
- `src/Application/ReadModels/BankImportReadModel.hs` — fan-out apply over the id set.
- Import call sites that build `ImportInfo` (income/expense in `BankImportService`) — wrap
  the single id in a `NonEmpty`.
- Tests under `test/` per the Testing section.
