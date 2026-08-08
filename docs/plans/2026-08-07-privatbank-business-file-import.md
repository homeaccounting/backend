# PrivatBank Business Statement Import — Phase 1 (XLSX) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

> **Supersedes the earlier CSV plan.** A smoke test showed the real Автоклієнт
> CSV export is non-RFC4180 (unescaped embedded quotes) and that the **default**
> business export is **XLSX**. This plan builds the XLSX path and removes the
> business CSV parser + CSV fixtures. The reusable `Infrastructure.Banking.Csv`
> module and the personal-parser refactor are **kept** (personal PrivatBank uses
> them). Phase 2 (composable `TransferMatcher` for cross-currency conversions)
> is a separate later plan.

**Goal:** Import PrivatBank *business* statement **XLSX** files into `[BankTransaction]` via the file-import seam, across the multiple accounts one statement covers, adding a reusable `Infrastructure.Banking.Xlsx` module symmetric to the existing `Infrastructure.Banking.Csv`.

**Architecture:** New format-neutral `Infrastructure.Banking.Statement` holds `parseSignedDecimal`. New `Infrastructure.Banking.Xlsx` holds a raw-cell sheet reader (zip-archive + xml-conduit, amounts kept as exact strings) + a generic `xlsxStatementParser` driver. `PrivatBankBusiness` uses it (parser under `StatementXlsx`). No stored-schema/credential change.

**Tech Stack:** Haskell (GHC 9.10, RIO, NoImplicitPrelude, StrictData), zip-archive (new dep) + xml-conduit (already a dep), Hspec, hpack/Cabal flags + CPP.

**Spec:** `docs/specs/2026-08-07-privatbank-business-file-import-design.md`

---

## Ground rules

- Enter Nix shell: run build/test/format/lint via `nix develop -c …` (`hpack`, `just build`, `just format`, `just lint`, `cabal test all …`).
- After any `package.yaml` edit run `hpack`. `-Werror` is enforced via `just build`/`just test`.
- RIO prelude; import extras from `RIO.*`; `Data.Text` (RIO.Text lacks `splitOn`); no partial functions; no `!!` (use `Data.Vector`/`V.!` or `Map`).
- Match test filters with **plain substrings** (e.g. `--match "PrivatBankBusiness"`); the slash-anchored form matches nothing here.
- `just format` + `just lint` before each commit; no hlint suppressions.
- **No real PII** in fixtures — build synthetic `.xlsx` bytes in-test. The real sample stays local at `~/Downloads/privatbank/privatbank-business/`.
- Conventional Commits. Branch `feat/privatbank-business-file-import` (already checked out).

---

## File structure

**Create:** `src/Infrastructure/Banking/Statement.hs`, `src/Infrastructure/Banking/Xlsx.hs`, `test/Infrastructure/Banking/StatementSpec.hs`, `test/Infrastructure/Banking/XlsxSpec.hs`.
**Rewrite:** `src/Infrastructure/Banking/PrivatBankBusiness/Internal.hs` (CSV→XLSX), `test/Infrastructure/Banking/PrivatBankBusinessSpec.hs`.
**Modify:** `src/Infrastructure/Banking/Csv.hs` (drop `parseSignedDecimal`, import from Statement), `src/Infrastructure/Banking/PrivatBank/Internal.hs` (import from Statement), `src/Infrastructure/Banking/PrivatBankBusiness.hs` (StatementCsv→StatementXlsx), `package.yaml`.
**Delete:** `test/fixtures/privatbank-business-sample-utf8.csv`, `test/fixtures/privatbank-business-sample-cp1251.csv`.

---

## Task 1: Extract `Infrastructure.Banking.Statement` (format-neutral)

**Files:** Create `src/Infrastructure/Banking/Statement.hs`, `test/Infrastructure/Banking/StatementSpec.hs`; modify `src/Infrastructure/Banking/Csv.hs`, `src/Infrastructure/Banking/PrivatBank/Internal.hs`, `package.yaml`.

- [ ] **Step 1: Move `parseSignedDecimal` (+ `parseUnsignedDecimal`, `readDigits`) into a new `Infrastructure.Banking.Statement` module**, exporting only `parseSignedDecimal`. Copy the three functions verbatim from `Csv.hs`. Imports: `Data.Ratio ((%))`, `RIO`, `RIO.Char (isDigit)`, `qualified Data.Text as T`.
- [ ] **Step 2: `package.yaml`** — the library block has **no explicit `exposed-modules`** (hpack auto-discovers from `source-dirs: src`), so just creating `src/Infrastructure/Banking/Statement.hs` auto-exposes it after `hpack` — do **not** add an explicit top-level `exposed-modules:` (that would disable auto-discovery for every other module). Also **narrow the CSV combined-condition block** back from `flag(privatbank) || flag(privatbank-business)` to just `flag(privatbank)` (business is XLSX-only now). Run `nix develop -c hpack`.
- [ ] **Step 3:** In `Csv.hs`, delete the three moved functions, drop `parseSignedDecimal` from its exports, and `import Infrastructure.Banking.Statement (parseSignedDecimal)`. In `PrivatBank/Internal.hs`, change the `parseSignedDecimal` import from `Infrastructure.Banking.Csv` to `Infrastructure.Banking.Statement`. Fix any now-unused imports (`Data.Ratio`) per `-Wall`.
- [ ] **Step 4: `StatementSpec.hs`** — move the `parseSignedDecimal` cases from `CsvSpec` here (unsigned int, signed fractional, rejects non-digit, rejects empty).
- [ ] **Step 5:** `nix develop -c just build` (warning-clean); run `--match "Infrastructure.Banking.Statement"`, `--match "Infrastructure.Banking.Csv"`, `--match "Infrastructure.Banking.PrivatBank"` — all green (personal parser unchanged).
- [ ] **Step 6:** `just format` + `just lint`; commit `refactor(banking): extract format-neutral Infrastructure.Banking.Statement`.

---

## Task 2: Reusable `Infrastructure.Banking.Xlsx` — sheet reader + driver

**Files:** Create `src/Infrastructure/Banking/Xlsx.hs`, `test/Infrastructure/Banking/XlsxSpec.hs`; modify `package.yaml`.

- [ ] **Step 1: `package.yaml`** — add a new library `when` block:
  ```yaml
  - condition: flag(privatbank-business)
    exposed-modules:
      - Infrastructure.Banking.Xlsx
    dependencies:
      - zip-archive >= 0.4 && < 0.5
      - vector >= 0.12 && < 0.14
  ```
  (`xml-conduit`, `safe`, `bytestring`, `containers`, `text` are already global deps applied to every component. **`vector` is NOT global** — it's declared only in the CSV block and test deps — so the Xlsx block must declare it, since `Xlsx.hs` uses `Vector`/`V.!?`; without it a `privatbank`-off / `privatbank-business`-on build fails to compile.) **Also add `zip-archive >= 0.4 && < 0.5` to `tests.backend-test.dependencies`** — the `XlsxSpec` `buildXlsx` helper calls `Codec.Archive.Zip` directly, so the test suite needs it too. Run `hpack`. Confirm `zip-archive` resolves (`grep zip-archive backend.cabal`).

- [ ] **Step 2: Write `XlsxSpec.hs` failing tests first** for the pure layer + driver:
  - `parseSharedStrings` over inline `<sst><si><t>Сума</t></si>…</sst>` → `Vector Text`.
  - `parseSheetRows sharedStrings sheetXml` where a `<row>` **omits** a middle cell (e.g. cells for A, C but not B, with `r="A10"`,`r="C10"`) → assert the result pads B to `""` and keeps C at index 2 (the critical `r`-alignment behaviour). Include a numeric cell (`<c r="D10"><v>41051.28</v></c>` no `t`) → asserts `"41051.28"` verbatim.
  - `xlsxStatementParser "L" headerP validate` fed a built `.xlsx` (see Step 4 helper) with a 2-row preamble, a header row, and 2 data rows: assert header detection, 1-indexed `RowError` from a stub validator on the even row, and a whole-file `ParseError` when no row satisfies `headerP`.

- [ ] **Step 3: Implement `Infrastructure.Banking.Xlsx`.** Exports: `parseSharedStrings`, `parseSheetRows`, `readXlsxSheet`, `xlsxStatementParser`, `colRefIndex`. Imports: `qualified Codec.Archive.Zip as Zip`, `Text.XML`/`Text.XML.Cursor` (xml-conduit, as `Infrastructure/ExchangeRate/ECB.hs`), `qualified Data.ByteString.Lazy as BSL`, `Safe (atMay)`, `qualified Data.Vector as V`, `qualified Data.Map.Strict as Map` (`readMaybe` comes from RIO — no separate `Text.Read` import). Key logic — **all functions total** (no `!!`, no partial `read`, no `!`):
  - **⚠️ OOXML default namespace.** `sheet1.xml`/`sharedStrings.xml` declare `xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"`, so `<row>`/`<c>`/`<v>`/`<sst>`/`<si>`/`<t>` are all namespaced. Match by **local name** with `Text.XML.Cursor.laxElement` (ignores namespace) — a bare `element "c"` would NOT match real cells. This is the #1 silent trap: the `buildXlsx` fixture (Step 4) MUST emit the same `xmlns`, or tests pass on namespace-free XML while the real file fails.
  - `colRefIndex :: Text -> Int` — decode a cell ref's leading letters as **bijective base-26** (A=1: `foldl' (\a c -> a*26 + (ord c - ord 'A' + 1)) 0 letters`), then **subtract 1** to get a 0-based index (`"A"→0`, `"G"→6`, `"AA"→26`). (Phase-1 columns are A–O, all single-letter, but get the bijective form right for reuse.)
  - `parseSheetRows :: Vector Text -> ByteString -> [[Text]]` — for each `<row>`, for each `<c>`: `idx = colRefIndex (attr "r")`; value = if `t="s"` then look the `<v>` text up via `readMaybe` → `sharedStrings V.!? i` defaulting to `""`; else the `<v>` (or `<is>/<t>`) text verbatim. Build the row list by placing each value at `idx`, pre-padding gaps with `""` up to the max index (this is the fix for OOXML omitting empty cells). Rows in sheet order.
  - `readXlsxSheet :: ByteString -> Either ParseError [[Text]]` — **`Zip.toArchiveOrFail (BSL.fromStrict bs)`** (the safe, non-partial variant — `toArchive` throws) → on `Left` a `ParseError`; find `xl/sharedStrings.xml` and the first `xl/worksheets/sheet*.xml` via `Zip.findEntryByPath`/`Zip.filesInArchive`, `Zip.fromEntry` for bytes (both lazy `ByteString`); `Left ParseError` if a required part is missing; else `Right (parseSheetRows (parseSharedStrings ss) sheet)`. Note the strict→lazy conversions: `StatementParser`'s input is **strict** `ByteString`, while zip-archive and `Text.XML.parseLBS` use **lazy**.
  - `xlsxStatementParser :: Text -> ([Text] -> Bool) -> ((Text -> Maybe Text) -> Int -> Either RowError BankTransaction) -> StatementParser` — `readXlsxSheet` → find first row satisfying the header predicate (`Left (ParseError "<label>: header row not found")` if none) → build `Map Text Int` from header cells → for each subsequent non-empty row, `col name = Map.lookup name hdr >>= \i -> atMay row i` (missing → `Nothing`), call `validate col n` with 1-based `n`. Uses `Map` + `Safe.atMay` (from the `safe` dep) — no partial indexing.

- [ ] **Step 4: In `XlsxSpec.hs` add a `buildXlsx :: [[Text]] -> ByteString` test helper** that assembles a minimal `.xlsx`: build `xl/sharedStrings.xml` (dedup strings) + `xl/worksheets/sheet1.xml` via `zip-archive` (`Zip.emptyArchive`, `Zip.toEntry path 0 (BSL.fromStrict …)`, `Zip.addEntryToArchive`, `BSL.toStrict . Zip.fromArchive`). **Both XML parts MUST declare the OOXML default namespace** `xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"` on `<worksheet>`/`<sst>` — otherwise the tests validate against namespace-free XML that the real Автоклієнт file (which IS namespaced) would not match, hiding a real bug. Emit each cell with its proper `r` ref (`A1`, `B1`, …), shared-string cells as `t="s"` with a `<v>` index, numeric cells (bare decimals) as `<v>` with no `t`. **To prove the omitted-empty-cell handling, one test row must actually omit a middle cell** (skip its `<c>` entirely) and assert the padded result. This helper exercises `readXlsxSheet` with synthetic bytes and is reused by Task 3.

- [ ] **Step 5:** `just build` (warning-clean); `--match "Infrastructure.Banking.Xlsx"` green. `just format` + `just lint`.
- [ ] **Step 6:** Commit `feat(banking): reusable Infrastructure.Banking.Xlsx (raw-cell reader + xlsxStatementParser driver)`.

---

## Task 3: Business XLSX parser (rewrite Internal + fixtures)

**Files:** Rewrite `src/Infrastructure/Banking/PrivatBankBusiness/Internal.hs`, `test/Infrastructure/Banking/PrivatBankBusinessSpec.hs`; delete the two CSV fixtures; modify `package.yaml` (business block already exposes `PrivatBankBusiness.Internal`; no CSV deps here).

- [ ] **Step 1:** `git rm test/fixtures/privatbank-business-sample-utf8.csv test/fixtures/privatbank-business-sample-cp1251.csv`.
- [ ] **Step 2: Rewrite `PrivatBankBusinessSpec.hs`** (red first) using a `buildBusinessXlsx` helper (reuse `buildXlsx` from XlsxSpec — factor it into a shared test helper module `test/Testkit/Xlsx.hs` if convenient, else duplicate minimally). Fixture rows: header at a row after a short preamble; a **UAH** row on account M1 and a **USD** row on account M2 (multi-account, mixed currency); a decimal amount `41051.28` (exactness); the conversion pair (USD −918.99 + UAH +41051.28 — imported as two txns here); a row with blank Референс (→ `RowError`); a bad amount (→ `RowError`). Assert: exact `Rational` amount, currency 980/840, `UTCTime` from date+time, `externalAccountId` per-row from col M, `contact = Just <taxid>` (and `Nothing` when blank), `category = Nothing`, `externalId` = Референс.
- [ ] **Step 3: Rewrite `PrivatBankBusiness/Internal.hs`** to XLSX:
  ```haskell
  parsePrivatBankBusinessXlsx :: StatementParser
  parsePrivatBankBusinessXlsx = xlsxStatementParser "PrivatBank business XLSX" isHeaderRow validateRow
    where isHeaderRow cells = "Референс" `elem` cells && "Сума" `elem` cells
  ```
  `validateRow :: (Text -> Maybe Text) -> Int -> Either RowError BankTransaction` — pull columns by name (`Референс`, `Ваш рахунок`, `Дата проводки`, `Час проводки`, `Сума`, `Валюта`, `ЄДРПОУ`, `Назва контрагента`, `Призначення платежу`), a missing required column → `RowError`. Reuse `Statement.parseSignedDecimal`, `Domain.Core.Types` `parseCurrency`/`currencyNumericCode`/`mkBankProviderContact`/`mkExternalTransactionId`, `Domain.Banking.Types.unsafeExternalAccountId`. `time` = `parseTimeM %d.%m.%Y` + `parseTimeM %H:%M:%S` combined into one `UTCTime`. `category = Nothing`. Export `PrivatBusinessRawRow`? No — no raw-row type now; export `parsePrivatBankBusinessXlsx`, `validateRow`.
- [ ] **Step 4:** `just build`; `--match "PrivatBankBusiness"` green (incl. multi-account + exact-amount). `just format` + `just lint`.
- [ ] **Step 5:** Commit `feat(banking): PrivatBank business XLSX parser (multi-account, exact amounts)`.

---

## Task 4: Descriptor → StatementXlsx

**Files:** `src/Infrastructure/Banking/PrivatBankBusiness.hs`, `test/Infrastructure/Banking/PrivatBankBusinessSpec.hs`.

- [ ] **Step 1:** Update the descriptor test to assert `Map.keys` of the fileImport parsers is `[StatementXlsx]` (and `providerSupportsFile`/`not providerSupportsPull`).
- [ ] **Step 2:** In `PrivatBankBusiness.hs`, change `fileImport` to `Just (FileImportCapability (Map.singleton StatementXlsx parsePrivatBankBusinessXlsx))` (import `parsePrivatBankBusinessXlsx`). Registration in `Providers.hs` is unchanged.
- [ ] **Step 3:** `just build`; `--match "PrivatBankBusiness"` green. `just format` + `just lint`. Commit `feat(banking): register privatbank-business file import under StatementXlsx`.

---

## Task 5: Gate + docs

- [ ] **Step 1:** `nix develop -c just rebuild` then `nix develop -c just test` — green apart from the documented env-only `eventium_test` DB integration failures. Confirm banking specs pass.
- [ ] **Step 2:** Set spec front-matter `status: completed`. Add a one-line note that Phase 1 (XLSX parse + multi-account import) shipped and Phase 2 (composable FX `TransferMatcher`) is next.
- [ ] **Step 3:** Commit `docs(banking): mark Phase 1 (XLSX business import) complete`.

---

## Verification checklist (before updating the PR)

- [ ] `just rebuild && just test` green (modulo env-only `eventium_test`).
- [ ] `privatbank-business` lists `supportsFile: true`, `supportsPull: false`, format `StatementXlsx`.
- [ ] Real-file **smoke test**: parse `~/Downloads/privatbank/privatbank-business/stmts_*.xlsx` via `cabal repl` and confirm all rows parse with exact amounts, per-row accounts (both IBANs), and Референс ids. (Local only; do not commit the file.)
- [ ] No real PII committed; fixtures are in-test synthetic `.xlsx`.
- [ ] Personal `PrivatBankSpec` + `CsvSpec` unchanged and green (only `parseSignedDecimal` moved).
- [ ] No stored-event/command/read-model/credential change.
