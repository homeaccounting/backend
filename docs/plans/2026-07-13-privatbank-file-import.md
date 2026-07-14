# PrivatBank File Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PrivatBank as a file-only bank provider (CSV statement import) routed through bank connections, sharing one import core with the existing pull path, and wire the web UI (provider select on accounts + statement upload).

**Architecture:** Fill the `FileImportCapability` seam from PR #131 with a deterministic PrivatBank CSV parser. Both transports (pull, file) are routed through a `BankConnection` and converge on one `importMany` sink over the canonical `[BankTransaction]`. Take the opportunity — first real file provider — to de-leak three PR #131 abstractions (unify the external-account id type, per-row parse results, format→parser map) and unify the result vocabulary (`Resync* → Import*`).

**Tech Stack:** Haskell (GHC 9.10, RIO, Servant, cassava, LiquidHaskell), CQRS/event-sourcing via Eventium; React 18 + TypeScript, TanStack Query, react-hook-form + Zod, shadcn/ui, Vitest + MSW.

**Spec:** `docs/specs/2026-07-13-privatbank-file-import-design.md`

---

## Conventions (read once)

**Backend (`/Users/oleksandrsy/Projects/Current/Wix/server-infra`):**
- Enter the dev shell first: `nix develop` (puts `ghc`, `cabal`, `hpack`, `ormolu`, `hlint`, `just` on PATH).
- Build: `just build` (runs hpack + `cabal build -fci`). Tests: `just test`. Format: `just format` (ormolu, mandatory). Lint: `just lint`.
- `-Werror` is on via `-fci`; the warm `.o` cache can mask regressions — use `just rebuild` for a definitive check before finishing the phase.
- Full `cabal test all` needs a manually-created `eventium_test` Postgres DB; if 28 integration tests fail on a missing DB that is environmental, not your regression.
- After editing `package.yaml`, run `hpack` (or `just build`) to regenerate `backend.cabal`.
- Layering: `Domain` (pure, LiquidHaskell refinements required) → `Infrastructure` → `Application` → `Web`. Never export data constructors/field selectors; use smart constructors + accessors. `by :: UserId` for actor fields. Full `Kind` suffix on enum constructors.
- Run a single test: `cabal test all --test-option='--match' --test-option="/Pattern/"`.

**Web (`/Users/oleksandrsy/Projects/Current/Wix/monorepo`):**
- Test: `pnpm test` (`vitest run`). Single file: `pnpm test src/path/to/file.test.tsx`.
- MSW: every new endpoint needs a handler in `src/test/handlers.ts` or unhandled-request errors fail tests. Use the render helper in `src/test/utils.tsx`.
- Path alias `@/*` → `src/*`. Keep `src/api/types.ts` in lockstep with backend, citing the backend source in a comment.

**Both:** commit after every green step. Conventional Commits. Branch `feat/privatbank-file-import` (backend) already exists; create the matching branch in the monorepo at the start of Phase 2.

---

# Phase 1 — Backend (server-infra)

Order matters: the abstraction de-leaks (Tasks 1–3) are foundational; the provider, resolver, and endpoint (Tasks 6–8) build on them.

## File Structure (Phase 1)

- Modify `src/Domain/Banking/Types.hs` — promote `ExternalAccountId` to a newtype (C1).
- Modify `src/Infrastructure/Banking/Provider.hs` — use `ExternalAccountId`; add `RowError`/`StatementParser` (C2); `FileImportCapability { parsers }` (C3); rename `BankTransaction.accountId`/`BankAccount.externalId` → `externalAccountId`.
- Modify `src/Infrastructure/Banking/Monobank/Internal.hs` — adopt renamed fields / id type.
- Modify `src/Application/Services/BankImportService.hs` — rename `Resync*`→`Import*`, `resync`→`importConnection`; add `unresolved` to `ImportResult`; extract `importMany`.
- Modify `src/Application/Services/ConfigurationService.hs` — add `getConnectionFileImport`; token-optional connection resolution.
- Modify `src/Domain/Configuration/{Commands,Events,Projection}.hs` + `src/Application/ReadModels/Configuration.hs` — token-optional connection.
- Create `src/Infrastructure/Banking/PrivatBank.hs`, `src/Infrastructure/Banking/PrivatBank/Internal.hs` — provider + CSV parser.
- Modify `src/Infrastructure/Banking/Providers.hs` — additive per-flag `candidates`.
- Modify `src/Web/API/BankingAPI.hs` — rename `/resync`→`/import`; add `/import/file`; `StatementFormat` `FromHttpApiData`; `Import*` DTO + `unresolved`.
- Modify `src/Web/API/ConfigurationAPI.hs` — `ProviderInfoDTO`→`BankProviderDTO`; `ExternalAccountId` re-keying.
- Modify `package.yaml`, `config/local.yaml`, `config/test.yaml`.
- Tests under `test/` mirroring the above; helpers in `test/Testkit/BankingHelpers.hs`.

---

### Task 1: C1 — `ExternalAccountId` newtype

**Files:**
- Modify: `src/Domain/Banking/Types.hs:109` (+ export list ~27)
- Modify: `src/Infrastructure/Banking/Provider.hs:33,44,55,94` (remove `type BankAccountId = Text`; rename fields)
- Modify: `src/Infrastructure/Banking/Monobank/Internal.hs` (construction sites)
- Modify: `src/Web/API/ConfigurationAPI.hs` (`toExternalKeyedMap`, ~851-854), `src/Web/API/BankingAPI.hs:303-304`
- Test: existing suites are the regression guard (this is a compile-driven rename)

- [ ] **Step 1: Promote the type to a newtype.** Replace `type ExternalAccountId = Text` with the newtype below. **Critical:** unlike `ExternalTransactionId`, this type is a **`Map` key** (`accountMap :: Map ExternalAccountId AccountId`, TH-derived JSON on the Configuration events/command/projection) and is **logged** (`display extAccId` in `BankImportService`). So it needs `ToJSONKey`/`FromJSONKey` (mirror `BankProviderId`'s `toJSONKeyText unBankProviderId` — one screen up in a sibling module) and a `Display` instance — none of which `ExternalTransactionId` has.

```haskell
-- | Identifier for a bank account in an external provider (e.g. a Monobank
--   account id, or a PrivatBank card mask). Must be non-empty.
newtype ExternalAccountId = ExternalAccountId Text
  deriving (Show, Eq, Ord, Generic)

unExternalAccountId :: ExternalAccountId -> Text
unExternalAccountId (ExternalAccountId t) = t

mkExternalAccountId :: Text -> Either Text ExternalAccountId
mkExternalAccountId t
  | T.null t = Left "ExternalAccountId must not be empty"
  | otherwise = Right (ExternalAccountId t)

unsafeExternalAccountId :: Text -> ExternalAccountId
unsafeExternalAccountId = ExternalAccountId

instance ToJSONKey ExternalAccountId where
  toJSONKey = toJSONKeyText unExternalAccountId   -- mirror BankProviderId

instance FromJSONKey ExternalAccountId where
  fromJSONKey = FromJSONKeyText unsafeExternalAccountId

instance Display ExternalAccountId where
  textDisplay = unExternalAccountId
```

Also keep the value-level `ToJSON`/`FromJSON` (via `Generic` or explicit) that the `Text` alias implicitly had. Export the type, `mkExternalAccountId`, `unExternalAccountId`, `unsafeExternalAccountId` (never the constructor). Mirror the LiquidHaskell treatment `ExternalTransactionId` has, if any, in that module.

- [ ] **Step 2: Delete `type BankAccountId = Text`** in `Provider.hs:33`. Replace every `BankAccountId` with `ExternalAccountId` (imports from `Domain.Banking.Types`). Rename record fields: `BankTransaction.accountId → externalAccountId` (`:55`), `BankAccount.externalId → externalAccountId` (`:44`), and `PullCapability.fetchStatements :: ExternalAccountId -> …` (`:94`).

- [ ] **Step 3: Fix construction/consumption sites.** `Monobank/Internal.hs` builds `BankTransaction`/`BankAccount` — wrap ids with `unsafeExternalAccountId` (provider already trusts them) and rename fields. In `ConfigurationAPI.hs`, `toExternalKeyedMap :: Map Text UUID -> Map ExternalAccountId UUID` becomes a real key map via `mkExternalAccountId`/`unsafeExternalAccountId` (was identity on a `Text` alias). Update the `BankingAPI.hs:303-304` comment/usage.

- [ ] **Step 4: Build + format + tests.** Run:
```bash
nix develop -c just build && nix develop -c just format && nix develop -c just test
```
Expected: compiles under `-fci`; existing banking tests green (rename is behaviour-preserving). Fix all call sites the compiler flags.

- [ ] **Step 5: Commit**
```bash
git add -A && git commit -m "refactor(banking): unify external-account id into ExternalAccountId newtype (C1)"
```

---

### Task 2: C2 + C3 — per-row parse results & format→parser map

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs:100-111` (+ exports ~13-20)
- Test: none standalone — these type changes are compile-verified here; behavioural coverage (`Map.keys parsers == [StatementCsv]`, per-row `RowError`) lands in Task 6's descriptor/parser tests where a real consumer exists.

- [ ] **Step 1: Add the row-error + parser types** (C2) near `ParseError`:

```haskell
-- | A single statement row that failed to parse (structural failures use
--   'ParseError' for the whole file instead).
data RowError = RowError {rowNumber :: !Int, message :: !Text}
  deriving (Show, Eq)

-- | Parse a statement of one already-selected format into per-row results:
--   'Left ParseError' for a whole-file/structural failure; otherwise one entry
--   per row, each 'Left RowError' or 'Right BankTransaction'.
type StatementParser = ByteString -> Either ParseError [Either RowError BankTransaction]
```

- [ ] **Step 2: Replace `FileImportCapability`** (C3) — drop `supportedFormats` + the `StatementFormat ->` arg:

```haskell
newtype FileImportCapability = FileImportCapability
  {parsers :: Map StatementFormat StatementParser}
```

Export `FileImportCapability (..)`, `parsers`, `RowError (..)`, `StatementParser`, keep `StatementFormat (..)`, `ParseError (..)`. Add `import qualified RIO.Map as Map` if needed. **Remove the now-orphaned `import Data.List.NonEmpty (NonEmpty)` at `Provider.hs:25`** (dropping `supportedFormats` was its only use) — otherwise the unused-import warning fails the `-fci`/`-Werror` build. `Monobank` sets `fileImport = Nothing`, so it is unaffected.

- [ ] **Step 3: Build + format.**
```bash
nix develop -c just build && nix develop -c just format
```
Expected: compiles (no provider fills `fileImport` yet, so no other breakage).

- [ ] **Step 4: Commit**
```bash
git add -A && git commit -m "refactor(banking): per-row parse results + format→parser map (C2, C3)"
```

---

### Task 3: Rename `Resync*`→`Import*`, extract `importMany`, add `unresolved`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (types ~94-114, `resync` ~128-146, `importTransaction` ~296)
- Modify: `src/Web/API/BankingAPI.hs` (result DTO + handler usages)
- Test: `test/Application/Services/BankImportServiceSpec.hs` (or the existing spec) + `test/Testkit/BankingHelpers.hs`

- [ ] **Step 1 (rename, compile-driven):** In `BankImportService.hs` rename `AccountResyncResult → AccountImportResult`, `ResyncResult → ImportResult`, `resync → importConnection`, `resyncHandler` references. Add `unresolved :: ![Text]` to `ImportResult` (default `[]`). In `BankingAPI.hs` rename `AccountResyncSummary → AccountImportSummary`, `ResyncResponse → ImportResponse`, `ResyncRequest → ConnectionImportRequest`, `resyncHandler → importConnectionHandler`; add `unresolved :: ![Text]` to `ImportResponse` and project it through. Build to find all sites:
```bash
nix develop -c just build
```

- [ ] **Step 2: Write the failing test for `importMany`** in `BankImportServiceSpec.hs`. Use the in-memory event store (`test/Testkit/InMemoryEventStore.hs`) + `BankingHelpers`. Cover: (a) two rows on a mapped external account → 2 imported in that account; (b) a row whose `externalAccountId` is NOT in the link → 0 imported, its id in `result.unresolved`; (c) a link with a single account and rows carrying different card ids, where the caller pre-expanded the link to map each card → same account (single-account mode) → all imported.

```haskell
it "routes mapped rows and collects unmapped into unresolved" $ do
  -- arrange: link maps "card-A" -> localAcct; txns on "card-A" and "card-B"
  -- act: importMany defaultClassify uid [("card-A", localAcct)] [txA1, txA2, txB]
  -- assert: 2 imported under localAcct; result.unresolved contains "card-B"
```

- [ ] **Step 3: Run it — expect FAIL** (`importMany` not defined):
```bash
nix develop -c cabal test all --test-option='--match' --test-option="/importMany/"
```

- [ ] **Step 4: Extract `importMany`.** Signature (spec §3):
```haskell
importMany ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  [BankTransaction] ->
  AppM ImportResult
```
For each tx: `lookup tx.externalAccountId link` — `Nothing` → append `unExternalAccountId tx.externalAccountId` (deduped) to `unresolved`, do not commit; `Just localAcct` → delegate to the existing `importTransaction` (dedup + classify + category unchanged) and accumulate into that account's `AccountImportResult`. Group results per touched local account. Refactor `importConnection` (pull) to build its link from mapped accounts and call `importMany` (so `unresolved` stays `[]` for pull).

- [ ] **Step 5: Run tests — expect PASS.** Then full `just test`; existing pull/resync tests (updated to the new names) stay green.

- [ ] **Step 6: Format + commit**
```bash
nix develop -c just format
git add -A && git commit -m "refactor(banking): shared importMany sink + Import* vocabulary + unresolved bucket"
```

---

### Task 4: `BankProviderDTO` rename + config entry

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs` (`ProviderInfoDTO`→`BankProviderDTO`, `toProviderInfoDTO`→`toBankProviderDTO`, exports, `listProvidersHandler`)
- Modify: `config/local.yaml`, `config/test.yaml`

- [ ] **Step 1:** Rename `ProviderInfoDTO → BankProviderDTO` and its projection function; update the route return type `Get '[JSON] [BankProviderDTO]` and exports. `supportsFile = isJust d.fileImport` unchanged.
- [ ] **Step 2:** Add to both config files under `banking.providers`:
```yaml
    privatbank:
      enabled: ${BANKING_PRIVATBANK_ENABLED:-true}
```
- [ ] **Step 3: Build + format + commit**
```bash
nix develop -c just build && nix develop -c just format
git add -A && git commit -m "refactor(banking): rename ProviderInfoDTO→BankProviderDTO; add privatbank config"
```

---

### Task 5: Token-optional connections

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs` (`AddBankConnection`), `Events.hs` (`BankConnectionAdded`), `Projection.hs:105-119` (`BankConnection`)
- Modify: `src/Application/ReadModels/Configuration.hs` (persistence)
- Modify: `src/Web/API/ConfigurationAPI.hs` (`AddConnectionRequest`, `addConnectionHandler` validation)
- Modify: `src/Application/Services/ConfigurationService.hs` (`getConnectionProvider` — already errors without pull)
- Test: `test/Domain/Configuration/*Spec.hs`, `test/Web/API/ConfigurationAPI*Spec.hs`

- [ ] **Step 1: Write failing tests.** (a) domain: adding a connection for a file-only provider with no token succeeds; (b) web: `addConnectionHandler` rejects a pull-capable provider with no token (validation error), accepts a file-only provider with no token.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Make the credential optional.** The projection fields are
`encryptedToken :: EncryptedSecret` and `tokenHint :: Text` (`Projection.hs:113-115`);
the command/event carry the plaintext token. Make them optional
(`encryptedToken :: Maybe EncryptedSecret`, `tokenHint :: Maybe Text`, and the
command/event token `Maybe`) — no-backcompat: change the event schema directly. Note the
projection folds at `Projection.hs:336-360` copy these fields and must be updated. In `addConnectionHandler`, look up the provider in the registry and require a token **iff** `isJust descriptor.pull`; otherwise allow absent. `ChangeTokenRequest` errors for a connection whose provider has no pull. `BankConnectionDTO.tokenSet :: Bool` computed from presence (unchanged shape).
- [ ] **Step 4: Run — expect PASS**, then `just test`.
- [ ] **Step 5: Format + commit**
```bash
nix develop -c just format
git add -A && git commit -m "feat(banking): token-optional connections for file-only providers"
```

---

### Task 6: PrivatBank provider + CSV parser

**Files:**
- Create: `src/Infrastructure/Banking/PrivatBank.hs`, `src/Infrastructure/Banking/PrivatBank/Internal.hs`
- Modify: `package.yaml` (flag `privatbank`, `cassava` dep, exposed modules), `src/Infrastructure/Banking/Providers.hs` (additive `candidates`)
- Test: `test/Infrastructure/Banking/PrivatBankSpec.hs`; fixture CSV in `test/fixtures/privatbank-sample.csv`

- [ ] **Step 1: Fixture already committed** at `test/fixtures/privatbank-sample.csv` (104 lines: 1 title + 1 header + 102 data rows). No copy needed.

- [ ] **Step 2: Add the `privatbank` flag + cassava dep + module exposure** in `package.yaml`. Mirror the `monobank` flag block (`default: true, manual: true`); in the flag's `library.when` set `cpp-options: -DPROVIDER_PRIVATBANK` and expose `Infrastructure.Banking.PrivatBank[.Internal]`. **Add `cassava` as a `dependencies:` key inside that same `when: condition: flag(privatbank)` block** — note the `monobank` block has no `dependencies` key to copy from, but hpack supports `dependencies` inside a `when` condition, so the parser dep enters the build only when the flag is on. Run `nix develop -c hpack`.

- [ ] **Step 3: Write failing parser tests** (`PrivatBankSpec.hs`) against the fixture, per spec §Testing: total row count matches the file; a `Зарахування` row (positive) classifies income and a `Платежі` row (negative) classifies expense; `"UAH"→980`; `categoryHint` carries `Категорія`; header-only input → `Right []`; a row with a corrupted date → that row is `Left RowError`, others survive; a file with a renamed header column → `Left ParseError`; parsing identical bytes twice yields identical `externalId`s.

- [ ] **Step 4: Run — expect FAIL.**

- [ ] **Step 5: Implement `PrivatBank/Internal.hs`.** `parsePrivatBankCsv :: StatementParser`. Drop the title preamble line; `decodeByName` (cassava) keyed on the Cyrillic headers (`FromNamedRecord` with UTF-8 `ByteString` keys). Per row build a `BankTransaction` per the spec column table: `time` via `%d.%m.%Y %H:%M:%S`; `amount :: Rational` signed; `currencyCode` via `parseCurrency >>> currencyNumericCode`; `externalAccountId = unsafeExternalAccountId <card>`; `externalId = mkExternalTransactionId ("privatbank:" <> iso8601 time <> ":" <> tshow amount <> ":" <> balance)`; `categoryHint = Just <Категорія>` when non-empty; `mcc/originalAmount/notes = Nothing`; `hold = False`. Thread per-row `Either` (bad date/amount/currency, empty externalId) into `Left RowError {rowNumber, message}`. Structural cassava failure → `Left ParseError`.

- [ ] **Step 6: Implement `PrivatBank.hs`** — `descriptor :: BankProviderDescriptor` per spec §1 (`providerId = "privatbank"`, `pull = Nothing`, `fileImport = Just (FileImportCapability {parsers = Map.singleton StatementCsv parsePrivatBankCsv})`, `classify = defaultClassify`).

- [ ] **Step 7: Wire `Providers.hs`.** Restructure `candidates` into an additive form: `candidates cfg manager = monobankCandidates <> privatbankCandidates` where each is `#ifdef`-guarded (`[]` when the flag is off). `privatbankCandidates = [PrivatBank.descriptor]` under `#ifdef PROVIDER_PRIVATBANK`.

- [ ] **Step 8: Run parser tests — expect PASS**, then `just build && just test`.

- [ ] **Step 9: Format + commit**
```bash
nix develop -c just format
git add -A && git commit -m "feat(banking): PrivatBank CSV file-import provider (tracker#38)"
```

---

### Task 7: `getConnectionFileImport` resolver

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs` (near `getConnectionProvider` ~552-575)
- Test: `test/Application/Services/ConfigurationServiceSpec.hs`

- [ ] **Step 1: Failing test** — for a PrivatBank connection returns `(classify, FileImportCapability)`; for a Monobank connection returns `Left BankingError` (no file transport); unknown connection → `Left`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Implement** `getConnectionFileImport :: BankConnectionId -> AppM (Either DomainError (BankTransaction -> TransactionClassification, FileImportCapability))`, mirroring `getConnectionProvider` but reading `descriptor.fileImport`.
- [ ] **Step 4: Run — expect PASS.**
- [ ] **Step 5: Format + commit**
```bash
nix develop -c just format
git add -A && git commit -m "feat(banking): getConnectionFileImport resolver"
```

---

### Task 8: Endpoints — rename `/resync`→`/import`, add `/import/file`

**Files:**
- Modify: `src/Web/API/BankingAPI.hs` (API type, `FromHttpApiData StatementFormat`, handlers)
- Test: `test/Web/API/BankingAPIIntegrationSpec.hs`

- [ ] **Step 1: Rename the pull route** `…/connections/:id/resync` → `…/connections/:id/import` (keep `ConnectionImportRequest` body, `importConnectionHandler`). Build.
- [ ] **Step 2: Add `FromHttpApiData StatementFormat`** (`"csv"→StatementCsv`, `"xlsx"→StatementXlsx`, else `Left`).
- [ ] **Step 3: Write failing integration tests** (`*IntegrationSpec`, needs `eventium_test` DB): upload the fixture to a PrivatBank connection mapped single-account → all rows imported, `unresolved` empty; re-upload identical bytes → all skipped; upload with a corrupted row → that row in `unresolved`, others imported; `?format=xlsx` → 422; POST to a connection the caller doesn't own → error.
- [ ] **Step 4: Run — expect FAIL.**
- [ ] **Step 5: Add the route + handler:**
```
POST /api/banking/connections/:connId/import/file
  Capture "connId" UUID :> QueryParam' '[Required,Strict] "format" StatementFormat
  :> ReqBody '[OctetStream] ByteString :> Post '[JSON] ImportResponse
```
Handler (spec §5): resolve + own-connection check → `getConnectionFileImport` → `Map.lookup format parsers` (miss → 422) → run parser (`Left ParseError` → 422) → split goods/`RowError`s → build `accountLink` per the §6 routing rule (single-account: expand every card in goods → the sole account; multi-account: use `accountMap` filtered to Owner/Editor) → `importMany` → append `RowError` messages to `unresolved` → `ImportResponse`. Register the route in the server and (if present) the API type alias.
- [ ] **Step 6: Run — expect PASS** (skip if `eventium_test` DB unavailable; note it).
- [ ] **Step 7: `just rebuild` (definitive -Werror), format, lint, commit**
```bash
nix develop -c just rebuild && nix develop -c just format && nix develop -c just lint
git add -A && git commit -m "feat(banking): connection-routed statement-file import endpoint"
```

---

### Task 9: Testkit + flag-off sanity

**Files:**
- Modify: `test/Testkit/BankingHelpers.hs` (add a PrivatBank `BankTransaction`/connection helper if a generic one is missing)

- [ ] **Step 1:** Add reusable helpers only if the existing ones don't cover file-connection setup (per CLAUDE: reuse, don't copy-paste). 
- [ ] **Step 2:** Confirm a flag-off library+exe build still compiles: `nix develop -c cabal build -f-privatbank`. (Test suite remains flag-unaware per spec; not gated here.)
- [ ] **Step 3: Commit** any helper additions.

---

# Phase 2 — Web (monorepo)

**Setup:** `cd /Users/oleksandrsy/Projects/Current/Wix/monorepo && git checkout -b feat/privatbank-file-import`. Backend endpoints (Phase 1) should be running/available for E2E, but unit work uses MSW.

## File Structure (Phase 2)

- Modify `src/api/types.ts` — `Import*` renames + `unresolved`, `BankProviderDTO`, request-name alignment.
- Modify `src/api/client.ts` — `postBinary`.
- Modify `src/api/configuration.ts` — `listProviders`.
- Modify `src/api/banking.ts` — `importConnection`, `importStatement`.
- Create `src/features/banking/useProviders.ts`, `useImportStatement.ts`; modify `useResync.ts` → `useImportConnection.ts`.
- Modify `src/features/accounts/SubtypeFields.tsx`, `schema.ts` — bank Select.
- Modify `src/features/profile/BankConnectionDialog.tsx`, `bankConnectionSchema.ts` — provider Select + conditional token.
- Create `src/features/accounts/ImportStatementButton.tsx`; modify `SyncNowButton.tsx` (`summarize`/`formatSummary` extended with `unresolved`).
- Modify `src/test/handlers.ts`, `src/test/fixtures.ts`.

---

### Task 10: Types + `postBinary`

**Files:** Modify `src/api/types.ts`, `src/api/client.ts`

- [ ] **Step 1:** In `types.ts`: rename `ResyncAccountResult → AccountImportSummary`, `ResyncResponse → ImportResponse` (add `unresolved: string[]`), `ResyncRequest → ConnectionImportRequest`; rename `AddBankConnectionRequest → AddConnectionRequest`, `UpdateBankConnectionRequest → UpdateConnectionRequest`, `ChangeBankTokenRequest → ChangeTokenRequest` (align to backend); add `BankProviderDTO { id; displayName; supportsPull; supportsFile }`. Cite `ConfigurationAPI.hs`/`BankingAPI.hs` in comments.
- [ ] **Step 2:** Add `postBinary` to `ApiClient` (reuse auth header + `ApiError`/`fieldErrors`; body = `Blob`, `Content-Type: application/octet-stream`; no `JSON.stringify`).
- [ ] **Step 3:** `pnpm test` (type-check compiles; update any references). Commit.
```bash
git add -A && git commit -m "refactor(api): Import* types + BankProviderDTO + postBinary path"
```

### Task 11: list-providers hook

**Files:** Modify `src/api/configuration.ts`; Create `src/features/banking/useProviders.ts`; Modify `src/test/handlers.ts`

- [ ] **Step 1:** Failing test for `useProviders` (renderHook + MSW handler returning two providers). **Step 2:** add `listProviders()` → `GET …/configuration/banking/providers` and the query hook (fails soft on error/empty). **Step 3:** add the MSW handler. **Step 4:** test PASS. **Step 5:** commit.

### Task 12: banking api + import hooks

**Files:** Modify `src/api/banking.ts`; rename `useResync.ts`→`useImportConnection.ts`; Create `useImportStatement.ts`

- [ ] **Step 1:** `banking.ts`: rename `resync`→`importConnection(connId,{from,to})` hitting `…/connections/:id/import`; add `importStatement(connId,{format,file})` → `postBinary` to `…/connections/:id/import/file?format=`. **Step 2:** rename hook `useResync`→`useImportConnection`; add `useImportStatement` (mirror the mutation shape, share `ImportResponse`). **Step 3:** update MSW handlers (renamed `/import` + new `/import/file`). **Step 4:** tests green; commit.

### Task 13: Account-form bank Select

**Files:** Modify `src/features/accounts/SubtypeFields.tsx`, `schema.ts`; Test `SubtypeFields.test.tsx`

- [ ] **Step 1: Failing component test** — bankAccount branch shows a Select of provider display names + an "Other…" item; picking a provider sets `bankName`; choosing "Other…" reveals an Input; editing an account whose `bankName` is unknown opens in custom mode. **Step 2:** run — FAIL. **Step 3:** implement using the `"__custom__"` sentinel pattern (from `AccountSelect`/`LinkAccountsDialog`); consume `useProviders`; fall back to a plain Input when providers unavailable. `bankAccountSchema` keeps `bankName: string`. **Step 4:** PASS. **Step 5:** commit.

### Task 14: Connection dialog — provider Select + conditional token

**Files:** Modify `src/features/profile/BankConnectionDialog.tsx`, `bankConnectionSchema.ts`; Test its `*.test.tsx`

- [ ] **Step 1: Failing test** — provider Select is populated from `useProviders` (not hardcoded); selecting a file-only provider (PrivatBank) hides the token field; selecting a pull provider (monobank) shows it and requires it. **Step 2:** FAIL. **Step 3:** implement; `bankConnectionSchema` makes token conditional on the selected provider's `supportsPull`; for a file-only provider offer a single "import into" account creating the one-entry `accountMap`. **Step 4:** PASS. **Step 5:** commit.

### Task 15: ImportStatementButton + toast

**Files:** Create `src/features/accounts/ImportStatementButton.tsx`; Modify `SyncNowButton.tsx`; add to `AccountsPane.tsx` toolbar; Test `ImportStatementButton.test.tsx`

- [ ] **Step 1:** Extract/extend `summarize`/`formatSummary` to also render `unresolved` (shared by both buttons). **Step 2: Failing test** — button shows when banking enabled and the account has a file-capable connection (found via the same lookup `SyncNowButton` uses); opens a dialog with a `.csv` picker; on submit calls `useImportStatement(connId,…)` and toasts imported/skipped/failed + unresolved; hidden with a hint when no connection. **Step 3:** FAIL. **Step 4:** implement. **Step 5:** PASS. **Step 6:** commit.

### Task 16: Handlers, fixtures, and full green

**Files:** Modify `src/test/handlers.ts`, `src/test/fixtures.ts`

- [ ] **Step 1:** Ensure MSW handlers exist for all three endpoints (`banking/providers`, renamed `connections/:id/import`, `connections/:id/import/file`) with realistic `ImportResponse` (incl. `unresolved`) fixtures. **Step 2:** `pnpm test` full suite green; `pnpm build` (tsc) clean. **Step 3:** commit.

---

## Definition of Done

- Backend: `just rebuild` + `just test` green (modulo the environmental `eventium_test` DB note); `just lint` clean; PrivatBank flag on by default, `-f-privatbank` still builds lib+exe.
- Web: `pnpm test` + `pnpm build` green.
- A PrivatBank connection (no token) can be created, mapped to an account, and a real CSV imported with correct income/expense split, idempotent re-import, and unmapped/bad rows surfaced in `unresolved`.
- Two PRs (backend, then web), each Conventional-Commit titled, based on `master`.
