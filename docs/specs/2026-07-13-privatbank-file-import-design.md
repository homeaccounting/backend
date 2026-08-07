---
status: draft
date: 2026-07-13
---

# PrivatBank file import: fill the file-import seam, second provider, connection-routed upload

## Problem

PR #131 (`feat/pluggable-bank-providers`) generalized the banking layer along the
**transport** axis: a `BankProviderDescriptor` may declare a `pull` capability (API
sync) and/or a `fileImport` capability (statement upload). The `fileImport` seam —
`FileImportCapability { supportedFormats, parseStatement }` — was **defined but left
unimplemented**: no provider fills it, no endpoint calls it, and the providers-list
DTO reports `supportsFile = False` for every provider.

tracker#38 is the follow-up that fills that seam. The motivation (learned the hard
way via the LLM prompt path in backend#128): **structured bank statements must be
parsed deterministically, not through an LLM.** A 102-row PrivatBank CSV run through
the prompt pipeline truncated at ~70 rows, produced non-deterministic output (69/54/72
rows across identical calls), and had no stable dedup key, so re-imports duplicated
rows. The CSV itself carries better keys than an LLM can produce: a to-the-second
timestamp and a unique running balance per row. Deterministic parsing gives complete
extraction, a stable dedup key, and no token/rate limits — exactly what
`BankImportService` already does for API providers via a stable `externalId`.

PrivatBank is the natural first file-import provider: for most retail users it exposes
**no usable statement-pull API**, only a downloadable CSV/XLSX export. This slice adds
PrivatBank as a **file-only** provider (`pull = Nothing`), a connection-routed upload
endpoint, and the web features that make it usable.

## Core design idea: import is one operation, transport is a provider capability

A `BankConnection` is a **provider binding**: it names a `provider :: BankProviderId`,
holds an `accountMap` (external-account-id → local-account-id), and — for pull providers
— an encrypted credential. The key realization for this slice: the PrivatBank CSV's
`Картка` (card) column **is an external-account id**, so a file import routes rows
through the connection's `accountMap` in exactly the same way a pull import routes
fetched transactions. That collapses the two transports into one operation downstream:

```
pull:  connection → fetchStatements → [BankTransaction] ┐
file:  connection → parseStatement  → [BankTransaction] ┼→ importMany (accountMap) → ImportResult
```

Both transports are therefore **routed through the connection**, share one import core,
one result vocabulary, and one accountMap-based routing. The provider id is never a
request parameter — it is read from the connection.

## Scope

**In scope**

- Backend: PrivatBank provider module + deterministic CSV parser filling the
  `fileImport` seam; a shared transport-neutral `importMany` core in `BankImportService`
  (refactored out of `resync`); a connection file-import resolver; a connection-routed
  `OctetStream` upload sub-route; **token-optional connections** for file-only providers;
  the `privatbank` Cabal flag, config, and registry wiring.
- Consistency pass: unify the banking import URLs and rename the `Resync*` result/DTO
  family to a transport-neutral `Import*` family across service/HTTP/web; align the
  configuration banking DTO names (`ProviderInfoDTO → BankProviderDTO`) and the
  backend↔web request-type name drift.
- Core abstraction de-leak (PR #131, first-provider-driven): unify the external-account
  id type (`BankAccountId`→`ExternalAccountId`), per-row parse results, and a
  format→parser map. See "Core abstraction improvements".
- Web (monorepo): a list-providers query + hook; a provider select-list (with custom
  entry) driving the account form's bank-name field; a provider select + conditional
  token field in the connection dialog; a PrivatBank statement-import button on the
  account toolbar (routed via the account's connection) with a binary-upload path and
  result toast.

**Out of scope** (deferred / unchanged)

- **Telegram** document routing to the parser (tracker#38 mentions it; deferred).
- **XLSX** and any second file provider (CSV-only for v1).
- Persisting a provider association on the account subtype (the account-form select is a
  **label only**, filling free-text `bankName`).
- Changes to the import saga's accounting (double-entry, per-leg FX, category
  resolution, dedup index) — reused as-is.
- Making the **test suite build-flag-aware** (PR #131 deferred item #1). Both provider
  flags default on, so the suite compiles; flag-OFF test gating remains a follow-up.
- External-account **discovery** for file connections (no `fetchAccounts` without an
  API) — see the v1 routing rule for how mapping is handled instead.
- Rejecting a **token supplied for a file-only provider**. Validation only *requires* a
  token when the provider `supportsPull`; a token sent for a file-only provider is
  accepted and stored but never read (`getConnectionFileImport` never touches it).
  Harmless; tightening this to reject an unused token is a deferred follow-up.

## Key decisions

- **Import is routed through the connection, for both transports.** The connection
  supplies the provider id (server-side) and the `accountMap`. Two explicit sub-routes
  (chosen over a single content-negotiated route for testability and to avoid
  Content-Type-coupled dispatch):
  - `POST /api/banking/connections/:id/import` — pull (JSON `ConnectionImportRequest {from,to}`), renamed from `…/resync`.
  - `POST /api/banking/connections/:id/import/file?format=csv` — file (`OctetStream` bytes).
  Each dispatches on the connection's provider capability (422 if the provider lacks that
  transport) and returns `ImportResponse`.
- **Format is per-upload, not stored on the connection.** A provider may support several
  formats (CSV now, XLSX later), so `format` is a query param on the file sub-route; the
  connection stays format-agnostic.
- **Connections become token-optional.** The credential is required only when the chosen
  provider `supportsPull`. A PrivatBank connection is token-less: `provider + name +
  accountMap`.
- **`externalId` = deterministic composite string**, not a hash:
  `"privatbank:" <> iso8601(time) <> ":" <> amount <> ":" <> balance`. The running
  balance already makes each row unique, so the composite is exact and re-import-safe,
  needs no crypto dependency, and is debuggable.
- **Account-form provider select is label-only.** It fills the existing free-text
  `bankName`; no new domain/DTO/read-model field. (Distinct from the connection's
  provider binding — an account may carry a cosmetic `bankName` and *also* be mapped by a
  connection's `accountMap`.)
- **One transport-neutral vocabulary + aligned config DTO names.** Rename the `Resync*`
  result/DTO family to `Import*` across all layers, and rename the misnamed/ drifted
  configuration DTOs (`ProviderInfoDTO → BankProviderDTO`; web request names aligned to
  the backend). See "Consistency & naming".

## Consistency & naming

### Import result vocabulary (service / HTTP / web)

The pull and file transports emit the *same* per-account outcome, so they share one
result type. Those types are currently resync-named (and the per-account HTTP type is
even named differently on the two sides — `AccountResyncSummary` in Haskell vs
`ResyncAccountResult` in TS). Rename to a transport-neutral `Import*` family
(no-backcompat allows the rename); `resync`/pull behaviour is unchanged:

| Layer | Before | After (shared by pull + file) |
| ----- | ------ | ----------------------------- |
| Service (`BankImportService`) | `AccountResyncResult` / `ResyncResult` | `AccountImportResult` (fields unchanged: `imported::[TransactionId]`, `skipped::Int`, `failures::[Text]`) / `ImportResult` (**gains `unresolved::[Text]`**, see below) |
| HTTP DTO (`BankingAPI`) | `AccountResyncSummary` / `ResyncResponse` / `ResyncRequest` | `AccountImportSummary` / `ImportResponse` (**gains `unresolved::[Text]`**) / `ConnectionImportRequest` |
| Web (`types.ts`) | `ResyncAccountResult` / `ResyncResponse` / `ResyncRequest` | `AccountImportSummary` / `ImportResponse` (with `unresolved`) / `ConnectionImportRequest` (name-matched to backend) |

**New file-level `unresolved :: [Text]` on `ImportResult`/`ImportResponse`.** The
per-account `AccountImportResult` can only hold outcomes for rows that resolved to a
mapped local account. Two kinds of row have **no** local account to attribute to: a
per-row parse failure (`RowError`, C2) and a row whose external account (card) isn't in
the connection's `accountMap`. These land in the file-level `unresolved` list (human
readable, e.g. `"row 57: unparseable date"`, `"unmapped card 5169****1111"`) — which also
serves as the file-import **discovery** mechanism (the user learns unmapped masks and can
map them). The pull path never populates it (its link contains only mapped accounts), so
`unresolved` is empty for pull.

The backend service fn `resync` and handler `resyncHandler` are renamed to
`importConnection` / `importConnectionHandler` so no `Resync*` identifier survives; the
web keeps the **"Sync now"** button label (a good name for a live pull) but its hook
becomes `useImportConnection`.

### Configuration banking DTO names

The configuration surface (`Web.API.ConfigurationAPI`) has two naming issues fixed here:

- **`ProviderInfoDTO → BankProviderDTO`** (backend + the new web mirror), so provider and
  connection wire types share the `Bank*DTO` shape (`BankConnectionDTO`,
  `BankProviderDTO`, `BankingConfigurationDTO`, `ExternalAccountDTO`).
- **Backend↔web request-name drift**: the web calls them `AddBankConnectionRequest` /
  `UpdateBankConnectionRequest` / `ChangeBankTokenRequest` while the backend defines
  `AddConnectionRequest` / `UpdateConnectionRequest` / `ChangeTokenRequest`. Per the
  project rule "web DTOs mirror the backend," align the web to the backend's shorter
  names (context is already `…/banking/connections`).

**Naming conventions codified:** wire DTOs mirror the domain entity (`Bank*DTO`);
request bodies are `<Verb><Object>Request` in the banking namespace
(`AddConnectionRequest`, `SetAccountMapRequest`, …); the import bodies join the `Import*`
family (`ConnectionImportRequest`, `ImportResponse`).

### Banking API surface (after this slice)

Operations (actions on a connection) live under `/api/banking`; management (settings)
lives under `/api/users/me/configuration/banking`. See "Configuration API" for the open
question about whether to consolidate these.

| Method + route | Group | Transport | Request → Response |
| -------------- | ----- | --------- | ------------------ |
| `POST /api/banking/connections/:id/import` (was `…/resync`) | op | pull | `ConnectionImportRequest {from,to}` → `ImportResponse` |
| `POST /api/banking/connections/:id/import/file?format=csv` | op | file | `OctetStream` bytes → `ImportResponse` |
| `GET  /api/banking/connections/:id/external-accounts` | op | — | → `[ExternalAccountDTO]` (unchanged) |
| `GET/POST/PUT/DELETE …/configuration/banking/connections[...]` | mgmt | — | connection CRUD (DTOs renamed as above) |
| `GET  …/configuration/banking/providers` | mgmt | — | → `[BankProviderDTO]` |

## Core abstraction improvements (PR #131 first-provider de-leak)

The PR #131 provider abstractions were written speculatively, before any file provider
existed. Implementing the first one — and unifying the transports at the API level —
exposes three concrete leaks worth fixing now, in `Infrastructure.Banking.Provider` and
the types it shares. **Capability-model position:** the API unification pushes the
*sink* to unify (one `importMany` over the canonical `[BankTransaction]`), **not** the
acquire records — `PullCapability` (`(account, window) -> IO`) and `FileImportCapability`
(`(format, bytes) -> pure`) stay distinct because their inputs and effects genuinely
differ. Merging them into one `TransactionSource` would carry a union-of-inputs /
existential and obscure call sites for no real gain.

### C1. Unify the external-account id type

`type BankAccountId = Text` (Provider.hs:33) and `type ExternalAccountId = Text`
(`Domain/Banking/Types.hs:109`) are the *same* concept under **two** `Text` aliases —
`BankingAPI.hs:303-304` literally notes `BankAccountId = ExternalAccountId = Text`. Worse,
`BankTransaction.accountId` reads like a *local* `AccountId` but holds the provider-side
id (PrivatBank's card mask). Collapse **both aliases** into
**one hardened `ExternalAccountId` newtype** (promote from `Text`, updating all import
sites of either alias), used by
`BankTransaction`, `BankAccount`, `PullCapability.fetchStatements`, the `accountMap`
(`Map ExternalAccountId AccountId`, already so in the domain), and `importMany`. Rename
`BankTransaction.accountId → externalAccountId` and `BankAccount.externalId →
externalAccountId`. Touches Monobank (`Internal.hs` constructs these) and the
Configuration projection/DTO re-keying (`toExternalKeyedMap`), which mostly simplify.

### C2. Per-row parse results (not all-or-nothing)

`FileImportCapability.parseStatement :: … -> Either ParseError [BankTransaction]` fails
the *entire* file on a single bad row — contradicting tracker#38's "extract every row."
Split the two failure kinds:

```haskell
data RowError = RowError { rowNumber :: Int, message :: Text } deriving (Show, Eq)
type StatementParser = ByteString -> Either ParseError [Either RowError BankTransaction]
```

- **Structural** failure (undecodable CSV, missing/renamed header column) → `Left ParseError`
  for the whole file → HTTP 422.
- **Per-row** failure (bad date/amount/currency in one row) → `Right`, with that row as
  `Left RowError`. The handler splits goods from bads: goods go to `importMany`; each bad
  `RowError` is appended to the file-level `unresolved :: [Text]` list (see the result
  vocabulary in "Consistency & naming") — the same home as an unmapped card, since a
  failed-to-parse row has no local account to attribute to. (This is distinct from a
  per-row *import* failure on a mapped row, which stays in that account's `failures`.)

### C3. Format→parser map

`supportedFormats :: NonEmpty StatementFormat` + `parseStatement :: StatementFormat -> …`
are redundant and admit calling the parser with an unsupported format (runtime branch).
Replace with:

```haskell
newtype FileImportCapability = FileImportCapability
  { parsers :: Map StatementFormat StatementParser }
```

The keys **are** the supported formats (`supportedFormats = Map.keys …`), the
unsupported-format case is a clean `Map.lookup` miss (422), and there is no
`StatementFormat -> …` dispatch inside a parser. `supportsFile` in `BankProviderDTO`
becomes `not (null parsers)` (still `isJust fileImport` at the descriptor level).

## Backend design (server-infra)

### 1. PrivatBank provider module

New library modules, mirroring the Monobank `descriptor` / `Internal` split:

- `src/Infrastructure/Banking/PrivatBank.hs` — exports `descriptor :: BankProviderDescriptor`:
  ```haskell
  descriptor =
    BankProviderDescriptor
      { providerId  = Domain.unsafeBankProviderId "privatbank",
        displayName = "PrivatBank",
        classify    = defaultClassify,          -- sign-based; reused from Provider.hs
        pull        = Nothing,                   -- no usable pull API for retail users
        fileImport  = Just fileImportCapability
      }

  fileImportCapability =
    FileImportCapability
      { parsers = Map.singleton StatementCsv parsePrivatBankCsv }   -- see C3
  ```
  No config is needed (no API base URL), so unlike Monobank there is no
  `descriptorFromConfig`; `Providers.hs` references `PrivatBank.descriptor` directly.

- `src/Infrastructure/Banking/PrivatBank/Internal.hs` — the CSV parser and row model.

### 2. CSV parser

`parsePrivatBankCsv :: StatementParser` (i.e.
`ByteString -> Either ParseError [Either RowError BankTransaction]`, per C2), using
**cassava** (`Data.Csv`), a new dependency gated behind the `privatbank` flag.

The export has a **title preamble row** before the header (e.g.
`Історія операцій за період 11.04.2026 - 11.07.2026,,,…`). The parser drops that first
line, then `decodeByName` on the remainder keyed by the Cyrillic column names. A
missing/renamed header column or undecodable CSV is a **structural** `Left ParseError`;
a per-row problem (bad date/amount/currency) becomes a `Left RowError` in the result
list, leaving the other rows intact.

Column → field mapping (`Сума в валюті картки`/`Валюта картки` are the account-currency
amount/currency and drive classification; the transaction-currency columns are ignored
for v1):

| CSV column (UTF-8)              | `BankTransaction` field | Transform                                              |
| ------------------------------- | ----------------------- | ----------------------------------------------------- |
| `Дата`                          | `time`                  | parse `%d.%m.%Y %H:%M:%S` → `UTCTime` (no tz; treated as UTC) |
| `Категорія`                     | `categoryHint`          | `Just` (non-empty), else `Nothing`                    |
| `Опис операції`                 | `description`           | verbatim (may be quoted / contain commas)             |
| `Сума в валюті картки`          | `amount`                | signed `Rational` (e.g. `-6919.91`, `43000`)          |
| `Валюта картки`                 | `currencyCode`          | alpha → numeric via `parseCurrency >>> currencyNumericCode` (`"UAH"→980`) |
| `Залишок на кінець періоду`     | (→ `externalId` only)   | running balance, part of the composite key            |
| `Картка`                        | `externalAccountId`     | **masked card = `ExternalAccountId` (C1), used for accountMap routing** |
| —                               | `mcc`                   | `Nothing` (PrivatBank has no MCC)                     |
| —                               | `externalId`            | `mkExternalTransactionId "privatbank:<iso8601 time>:<amount>:<balance>"` |
| —                               | `hold`                  | `False`                                               |
| —                               | `originalAmount`, `notes` | `Nothing`                                           |

An unparseable date, amount, or unknown currency in a row → `Left RowError` for that row
only (other rows unaffected); a header-only statement yields `Right []`. `mkExternalTransactionId`
and amount parsing return `Either`; the parser threads each per-row `Either` into a
`RowError`. XLSX is simply not registered in `parsers` (C3), so `POST …/import/file?format=xlsx`
is a `Map.lookup` miss → 422; no in-parser "unsupported format" branch.

### 3. Shared import core (`importMany`)

`resync` currently fetches per external account and imports per row. Refactor the
transport-neutral tail into a shared core both transports call:

```haskell
importMany ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->   -- resolved account link (C1)
  [BankTransaction] ->
  AppM ImportResult                     -- { accounts :: [AccountImportResult], unresolved :: [Text] }
```

`importMany` **resolves the mapping itself**: for each row it looks up
`tx.externalAccountId` in the link. **Unmapped** rows go to `ImportResult.unresolved`
(recording the external id) and are not committed. **Mapped** rows are grouped per local
account and committed via the existing per-row `importTransaction` (dedup via
`isImported tx.externalId`, classify at commit, category fallback — all unchanged),
producing one `AccountImportResult` per touched account. This is the single import sink;
it removes the need for a separate `importStatement` / synthetic-id path.

- `importConnection` (pull, was `resync`) = `fetchStatements` per mapped account →
  `importMany` (its link contains only mapped accounts, so `unresolved` stays empty —
  behaviour identical to today's resync).
- File import = parse → split good rows → `importMany` (the handler then appends the
  parse-level `RowError`s to `unresolved`).

### 4. Connection file-import resolver

`Application.Services.ConfigurationService` gains a mirror of `getConnectionProvider`
(which resolves the pull transport from a connection):

```haskell
getConnectionFileImport ::
  BankConnectionId ->
  AppM (Either DomainError (BankTransaction -> TransactionClassification, FileImportCapability))
```

Looks up the connection, resolves its provider in the registry, and returns the
descriptor's `classify` + `fileImport` capability, or `Left (BankingError …)` when the
connection/provider is unknown or has no file transport.

### 5. Connection-routed endpoints

In `Web.API.BankingAPI`, behind auth + `requireBankingEnabled`. The pull route is the
renamed `resync`; the file sub-route is new:

```
POST /api/banking/connections/:connId/import          -- pull (renamed from /resync)
  Capture "connId" UUID
  ReqBody '[JSON] ConnectionImportRequest              -- {from, to}
  -> ImportResponse

POST /api/banking/connections/:connId/import/file      -- file (new)
  Capture "connId" UUID
  QueryParam' '[Required, Strict] "format" StatementFormat
  ReqBody '[OctetStream] ByteString
  -> ImportResponse
```

`StatementFormat` gets a `FromHttpApiData` instance in the Web layer
(`"csv"→StatementCsv`, `"xlsx"→StatementXlsx`). File-sub-route handler flow:

1. Resolve the connection; verify the caller owns it (existing connection authorization).
2. `getConnectionFileImport connId` → `(classify, cap)`; `Map.lookup format cap.parsers`
   (miss → 422).
3. Run the parser on the bytes → `Either ParseError [Either RowError BankTransaction]`.
   On `Left ParseError` (structural) → 422. Otherwise split the list into good
   `BankTransaction`s and `RowError`s.
4. Build `accountLink` from the connection's `accountMap` filtered to Owner/Editor
   local accounts (identical to the pull handler), applying the v1 routing rule below.
5. `BankImportService.importMany classify userId accountLink goods` → `ImportResult`;
   append the parse-level `RowError` messages to `ImportResult.unresolved`, then project
   to `ImportResponse`.

### 6. accountMap routing for files (v1 rule)

File providers have no `fetchAccounts`, so external accounts (card masks) can't be
discovered before an upload. The routing rule is realized **entirely in how the file
handler builds the `[(ExternalAccountId, AccountId)]` link it passes to `importMany`** —
`importTransaction`/`importMany` do an ordinary exact-match lookup, unchanged (no synthetic
keys, no special-casing in the core):

The rule is keyed off the **writable-filtered** map (the `accountMap` entries whose local
`AccountId` the caller may write, i.e. Owner/Editor — the same filter the pull handler
applies), not the raw `accountMap`:

- **Single writable account** (the writable-filtered map has exactly one entry): take its
  sole `AccountId` as the target and build the link
  `[(card, target) | card <- distinct externalAccountIds of the parsed good rows]` — i.e.
  every card present in the file maps to the one account. The stored map key is a
  placeholder; only its single value is used. This is the common PrivatBank case — no card
  typing, and nothing lands in `unresolved`. (Note: a connection whose raw `accountMap` has
  several entries but only one *writable* one also takes this path; the non-writable cards
  are not reported.)
- **Multiple writable accounts** (>1 writable entries, keyed by real card masks): pass the
  filtered map as the link directly. Rows whose card isn't a key resolve to nothing →
  `importMany` records them in `unresolved`, surfacing each mask so the user can map it and
  re-import (this is the discovery path).

### 7. Token-optional connections

- Domain: the `AddBankConnection` command / `BankConnectionAdded` event and the
  `BankConnection` projection make the credential **optional** (`Maybe`), replacing the
  always-present token (no-backcompat: change the event schema directly).
- Validation: `addConnectionHandler` requires a token **iff** the chosen provider
  `supportsPull`; file-only providers omit it. `ChangeTokenRequest` applies only to
  pull-capable connections (error otherwise).
- `BankConnectionDTO.tokenSet :: Bool` already signals presence; unchanged.
- `getConnectionProvider` (pull) already errors when a connection has no pull transport,
  so a token-less file connection can't be pull-imported.

### 8. Flag, config, and registry wiring

- **`package.yaml`**: add flag `privatbank` (`default: true, manual: true`); a
  `library.when` block `condition: flag(privatbank)` setting
  `cpp-options: -DPROVIDER_PRIVATBANK`, exposing
  `Infrastructure.Banking.PrivatBank[.Internal]`, and adding `cassava` under
  `dependencies` (dep enters only when the flag is on). Regenerate `backend.cabal` via
  hpack.
- **`Infrastructure/Banking/Providers.hs`**: `candidates` is currently a whole-function
  `#ifdef PROVIDER_MONOBANK / #else` pair threading `cfg manager`. Restructure into an
  **additive** form — `candidates = monobankCandidates <> privatbankCandidates`, each
  fragment `[]` when its flag is off (`#ifdef`-guarded) and a singleton when on.
  `PrivatBank.descriptor` takes no args.
- **`config/local.yaml`, `config/test.yaml`**: add `banking.providers.privatbank.enabled`.
- `supportsFile: true` in `BankProviderDTO` flips automatically once `fileImport = Just …`.

## Configuration API

The connection **management** endpoints (CRUD + MCC map + providers list) live under
`/api/users/me/configuration/banking`, while the connection **operations** (import,
external-accounts) live under `/api/banking`.

**Decision: keep the split** (management = settings, under `/configuration/banking`;
operations, under `/api/banking`). Only the DTO names change in this slice (the `Import*`
family + `ProviderInfoDTO → BankProviderDTO` + web request-name alignment above); no
routes move. The same connection resource being addressable under two base paths
(`/configuration/banking/connections/:id` for CRUD, `/api/banking/connections/:id` for
import) is a mild, documented incohesion — consolidating it under one base path is a
separate refactor, orthogonal to this import feature, and deliberately out of scope here.

## Web design (monorepo)

### A. list-providers plumbing

- `src/api/types.ts`: `BankProviderDTO { id: string; displayName: string; supportsPull: boolean; supportsFile: boolean }` (cite backend `ConfigurationAPI.hs`).
- `src/api/configuration.ts`: `listProviders()` → `GET …/configuration/banking/providers`.
- `useProviders` query hook. Not behind `requireBankingEnabled`; consumers degrade
  gracefully if it errors or returns empty.

### B. Account form bank select

In `src/features/accounts/SubtypeFields.tsx`, the `bankAccount` branch replaces the
free-text `bankName` Input with a shadcn `Select`:

- Options = provider `displayName`s + a `"__custom__"` sentinel item ("Other…") that
  reveals a text `Input` (existing sentinel pattern from `AccountSelect` /
  `LinkAccountsDialog`; no new Combobox dependency).
- Selecting a provider stores its `displayName` as `bankName`; custom stores typed text.
- On edit, unknown stored `bankName` opens in custom mode pre-filled; if providers are
  unavailable, fall back to a plain Input.
- `schema.ts` `bankAccountSchema` keeps `bankName: string`; the select/custom split is
  form-local UI state.

### C. Connection dialog (provider select + conditional token)

In `src/features/profile/BankConnectionDialog.tsx`:

- Replace the hardcoded/disabled `monobank` Select with one fed by `useProviders`.
- Show the token field only when the selected provider `supportsPull`; hide it for
  file-only providers (PrivatBank). `bankConnectionSchema` makes the token conditional.
- Account mapping: for a file-only provider, offer a single "import into" account picker
  that creates the one-entry `accountMap` (per the v1 routing rule); multi-account
  mapping via the existing `LinkAccountsDialog` flow.

### D. Statement import UI

- New binary-upload path on `ApiClient` (e.g. `postBinary(path, blob, contentType)`)
  reusing its auth header + `ApiError`/`fieldErrors` handling; JSON methods untouched.
- `src/api/banking.ts`: rename `resync` → `importConnection(connId, {from,to})` hitting
  `POST …/connections/:id/import`; add
  `importStatement(connId, { format, file })` → the octet-stream
  `POST …/connections/:id/import/file?format=`. Both return `ImportResponse`.
- Types (`types.ts`): rename `ResyncAccountResult → AccountImportSummary`,
  `ResyncResponse → ImportResponse`, `ResyncRequest → ConnectionImportRequest`; align the
  connection request names to the backend (`AddBankConnectionRequest → AddConnectionRequest`,
  etc.); `ProviderInfoDTO`-equivalent added as `BankProviderDTO`.
- Hooks: rename `useResync → useImportConnection`; add `useImportStatement`, sharing
  `ImportResponse` / `AccountImportSummary`.
- `SyncNowButton` keeps its "Sync now" label but calls `useImportConnection`; its
  `summarize`/`formatSummary` are reused by the import dialog, extended once to also
  surface `unresolved` (unmapped cards / bad rows) — shared by both transports (empty for
  pull).
- `ImportStatementButton` on the account toolbar next to `SyncNowButton`, shown when
  `bankingFeatureEnabled` and the account has a **file-capable connection** (found via
  the same account→connection lookup `SyncNowButton` already uses; if none, the button
  prompts to set up a connection). Opens a small dialog: a `.csv` file picker, format
  (`csv`); on submit → `importStatement(connId, …)` → toast summarizing
  imported/skipped/failed + any `unresolved` (e.g. "3 rows need a card mapping").

## Data flow

```
CSV file (browser)
  → ImportStatementButton (account → its file-capable connection, format=csv, file)
  → ApiClient.postBinary → POST /api/banking/connections/:id/import/file?format=csv (OctetStream body)
  → BankingAPI handler: own-connection check → getConnectionFileImport → parseStatement
  → [Either RowError BankTransaction]  (externalId = privatbank:time:amount:balance; externalAccountId = card)
  → split goods/row-errors; accountLink from connection.accountMap (v1 routing rule)
  → BankImportService.importMany (map-resolve → dedup via isImported → classify at commit)
  → double-entry import saga (unchanged)
  → ImportResult → ImportResponse {accounts: [{importedCount, skippedCount, failureCount}], unresolved: [...]}
  → toast (reuses "Sync now"'s summarize/formatSummary, extended with unresolved)
```

## Error handling

- **Structural parse failure** (undecodable / missing header) → `Left ParseError` → HTTP
  422; nothing committed.
- **Per-row parse failure** (`RowError`, C2) within a valid file → that row → the
  file-level `unresolved` list; other rows still import.
- **Unmapped card** (multi-account connection) → row → `unresolved`, surfacing the mask.
- **Per-row import failure** (commit error on a mapped row) → counted in that account's
  `failures`/`failureCount`, as pull already does.
- **Connection/provider unknown or no file transport** → `BankingError` → mapped HTTP.
- **Not the caller's connection** → existing connection authorization error.
- **Duplicate rows** (same file re-imported) → skipped via `isImported`, counted in
  `skipped`/`skippedCount`; idempotent by the composite `externalId`.
- **Banking disabled** → `requireBankingEnabled` gate; the web button is hidden.

## Testing

**Backend**

- Parser unit + property tests (Testkit `BankingHelpers`): row count over the real
  102-row sample; sign → income/expense; `"UAH"→980`; `categoryHint` passthrough;
  header-only → `Right []`; dedup idempotency (same bytes → identical `externalId`s).
- Per-row (C2): a bad-date/amount/currency row → `Left RowError` for *that* row while the
  rest parse; a missing/renamed header column → structural `Left ParseError`.
- Format map (C3): a format not in `parsers` → `Map.lookup` miss (handler 422).
- Descriptor test: `pull = Nothing`, `fileImport` present, `Map.keys parsers = [csv]`.
- ExternalAccountId (C1): Monobank/projection regression after the id-type unification
  (existing pull tests, updated to the newtype, are the guard).
- `importMany` test: shared by pull + file; single-account link (all cards → one
  account) vs multi-account by-card; unmapped card → `unresolved` (not committed);
  parse-level `RowError`s appended to `unresolved`; pull link leaves `unresolved` empty.
- Token-optional: create a file-only connection with no token; reject a token-less
  pull-provider connection.
- Endpoint integration (`*IntegrationSpec`): file upload → per-row commit; re-upload →
  all skipped; parse error → 422; not-owner → error.
- Regression: existing pull/resync tests, updated to the `Import*` names and
  `importConnection`, behaviour unchanged.

**Web**

- MSW handlers for `banking/providers`, `banking/connections/:id/import/file`, and the
  renamed `banking/connections/:id/import`.
- Component tests: account-form bank select (provider + `"__custom__"` mode, edit
  pre-fill); connection dialog (token hidden for file-only provider); import dialog
  (file pick → success toast → error toast).

## References

- tracker#38 — generalize import to statement export/import (this spec's driver).
- PR #131 / `docs/specs/2026-07-12-pluggable-bank-providers-design.md` — the
  `FileImportCapability` seam, registry, Cabal-flag pattern this fills.
- backend#128 / #129 — the LLM prompt path, re-scoped to free-text capture; structured
  statements move here.
