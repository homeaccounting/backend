---
status: completed
date: 2026-08-07
---

# PrivatBank business accounts via statement-file import (tracker#46)

> **Phase 1 (XLSX parse + multi-account import) implemented** on branch
> `feat/privatbank-business-file-import`: `Infrastructure.Banking.Statement`
> (neutral `parseSignedDecimal`), reusable `Infrastructure.Banking.Xlsx`
> (raw-cell reader + `xlsxStatementParser` driver), the `privatbank-business`
> XLSX parser (multi-account via col M, exact `Rational` amounts, external id =
> Референс), and the descriptor under `StatementXlsx`. Verified end-to-end
> against a real statement (12/12 rows, two accounts, exact amounts). **Phase 2
> (composable `TransferMatcher` for cross-currency conversions) is next** — see
> below. Spec stays `in-progress` until Phase 2 lands.

> **Revision (pivot to XLSX).** An earlier draft of this spec targeted the
> PrivatBank business **CSV** export. A smoke test against a real file showed
> that (a) the Автоклієнт CSV export is not RFC4180 — it emits unescaped
> embedded double-quotes (`АТ КБ "ПРИВАТБАНК"`) that break cassava — and (b)
> the **default** business export from Приват24 для бізнесу is **XLSX**, not
> CSV. So the business provider targets **XLSX**. The reusable CSV
> infrastructure (`Infrastructure.Banking.Csv`) built during the CSV attempt is
> **kept** — the personal PrivatBank parser uses it and future CSV providers
> can — and a symmetric reusable **`Infrastructure.Banking.Xlsx`** module is
> added for this and future XLSX providers.

## Problem

Every bank we support exposes personal and business/corporate surfaces, and our
banking layer silently assumes *personal*. A user's PrivatBank **business**
account (Приват24 для бізнесу) produces a perfectly importable statement, but
there is no way to represent or connect to a business surface. This spec adds a
business file-import provider.

## Scope & phasing

- **Phase 1 (this spec's primary scope): XLSX statement parsing + multi-account
  import.** Parse the business XLSX export into `[BankTransaction]` and import
  through the existing file-import seam. A statement spans **multiple of the
  user's own accounts** (e.g. a UAH and a USD account) in one file; each
  transaction carries its own account, and the connection's `accountMap` links
  each to a local account. Cross-currency conversions import as **two separate
  transactions** (one per account/currency) in this phase.
- **Phase 2 (captured here, implemented next): cross-currency conversion →
  single Transfer**, via **composable transfer matchers**. See
  [Phase 2](#phase-2-cross-currency-transfer-via-composable-matchers).

**Deferred — AutoAPI (Автоклієнт) live pull.** PrivatBank business also exposes a
programmatic *Автоклієнт* API; a pull adapter would let the backend fetch
statements automatically (scheduled/on-demand), like the Monobank provider, instead
of the user manually exporting + uploading the XLSX. It is **not** "just pull the
file we already parse": it reuses the entire accounting core (`BankTransaction`
downward — `BankImportService`, `accountMap`, dedup, and the Phase-2 conversion
matcher), but adds three genuinely new pieces — (1) a **pull transport**
(`PullCapability` instead of `FileImportCapability`); (2) a **different decoder** —
Автоклієнт returns JSON/XML, not the `.xlsx`, so `Infrastructure.Banking.Xlsx` does
NOT apply and a new API-response→`BankTransaction` adapter is needed; and (3) the
**`BankProviderCredential` generalization** — Автоклієнт auth is token + client-id
(possibly request-signing), which the current `StaticSecret Text` can't represent,
so a new credential variant is required (touching the credential type, the
connection-creation DTO, and the pull-capability builder, preserving the
encrypted-at-rest / last-4-hint / never-return-secret invariants). It also needs a
**live business Автоклієнт token** to build and verify against. Since it is pure
convenience (automation) over the working file-import path and is blocked on live
credentials, it stays deferred until auto-sync is actually wanted; the fix is a
self-contained provider-seam addition when it is.

## Decision: surface modeling

A new first-class provider slug, **`privatbank-business`** (issue option 1), not
a `Personal | Business` axis. Reuses the registry / per-provider `enabled` gate
/ `BankConnection` / `accountMap` / import-saga / dedup machinery unchanged. The
only user-visible change is one extra provider-picker entry, `PrivatBank
(Business)`. `fileImport` registers a parser under **`StatementXlsx`**
(`pull = Nothing`).

## The business XLSX format

From the real export (`stmts_<edrpou>_<ts>.xlsx`), verified with a sheet dump:

- A standard `.xlsx` (zip of `xl/sharedStrings.xml`, `xl/worksheets/sheet1.xml`,
  …). Text cells are shared strings (`t="s"`); **the amount cell is numeric**
  (no `t`).
- Rows 1–8 are a **title/period preamble** (bank name, export timestamp,
  "Виписка по декількох рахунках з … по …"). The **header is row 9**; data rows
  follow.
- **15 columns (A–O):**

| Col | Header (Cyrillic) | Meaning | Used as |
|-----|-------------------|---------|---------|
| A | № | document number | — |
| B | Дата проводки | posting date `DD.MM.YYYY` | `time` (with C) |
| C | Час проводки | posting time `HH:MM:SS` | `time` (with B) |
| D | Сума | **numeric** signed amount | `amount` |
| E | Валюта | currency (alpha) | `currencyCode` |
| F | Призначення платежу | purpose | `description` |
| G | ЄДРПОУ | counterparty tax id | `contact` |
| H | Назва контрагента | counterparty name | `description` |
| I | Рахунок контрагента | counterparty IBAN | — |
| J | МФО контрагента | counterparty bank code | — |
| K | Ваш МФО | your bank code | — |
| L | Ваш ЄДРПОУ | your tax id | — |
| M | **Ваш рахунок** | **your account IBAN** | `externalAccountId` |
| N | Назва вашого рахунку | your account name | — |
| O | **Референс** | **unique transaction reference** | `externalId` |

Key properties confirmed on the real file:

- **Multi-account:** column M varies per row (a UAH IBAN and a USD IBAN in the
  sample). Each transaction's `externalAccountId` is its own M value.
- **Референс (O) is unique** (12/12 distinct, none empty) → use it **directly**
  as `ExternalTransactionId`. No synthesized composite key.
- **Amount (D) is a numeric cell** → must be read as its **raw string** (e.g.
  `"41051.28"`) and parsed with `parseSignedDecimal` to an exact `Rational`.
  Going through a `Double` risks precision loss and scientific-notation on large
  amounts — unacceptable for money.
- **Date + time** are separate columns → precise `UTCTime`, not midnight.
- Only column D is numeric; all others are text.

## Design (Phase 1)

### Module layout — symmetric CSV / XLSX reusable infra

- **`Infrastructure.Banking.Statement`** (new, format-neutral): holds
  cross-format leaf helpers. Move `parseSignedDecimal` (+ `parseUnsignedDecimal`,
  `readDigits`) here from `Csv` so both CSV- and XLSX-based providers use them
  without either infra module depending on the other. This requires updating the
  existing importers — `Infrastructure.Banking.Csv` and
  `Infrastructure.Banking.PrivatBank.Internal` (which imports `parseSignedDecimal`
  from `Csv` today) — to import from `Statement` (compiler-caught refactor).
  Note: `parseSignedDecimal` accepts only `[-]digits[.digits]`; an XLSX `<v>` in
  scientific form (`4.1E4`) or with a leading `+` would fail to a per-row
  `RowError` (a safe failure, not silent corruption). Real amounts observed are
  plain decimals; if exponent forms ever appear, extend the parser then.
- **`Infrastructure.Banking.Csv`** (kept, CSV-specific): `decodeStatementBytes`,
  `csvColumn`, `csvStatementParser`, delimiter constants. Personal PrivatBank
  and future CSV providers use it. (Imports `parseSignedDecimal` from
  `Statement`.)
- **`Infrastructure.Banking.Xlsx`** (new, XLSX-specific reusable infra):
  - A **raw-cell sheet reader**, split for testability:
    - `parseSharedStrings :: ByteString -> Vector Text` and
      `parseSheetRows :: Vector Text -> ByteString -> [[Text]]` — **pure**,
      resolve `t="s"` cells against the shared-string table and take numeric/
      other cells' `<v>` **verbatim as Text**. **Critical:** OOXML *omits empty
      cells*, and each `<c>` carries its column via its `r` reference
      (`<c r="G9" …>`). `parseSheetRows` MUST place each cell at the positional
      slot decoded from `r`'s column letters (A→0, B→1, …) and **pad absent
      cells** with `""`, so a blank cell (e.g. a missing counterparty tax id in
      col G) does not shift every later column left. A naive
      document-order-dense collection would silently mismap columns on real
      rows. Assumption: cells are shared strings (`t="s"`) or numeric `<v>`;
      inline strings (`t="inlineStr"`/`"str"`) are not expected in this export —
      if encountered, read their text too. Unit-testable with inline XML, no zip.
    - `readXlsxSheet :: ByteString -> Either ParseError [[Text]]` — the thin zip
      layer (unzip the `.xlsx`, locate `sharedStrings.xml` + first worksheet,
      call the pure parsers). Structural failures → `Left ParseError`.
  - A generic driver mirroring `csvStatementParser`:

    ```haskell
    xlsxStatementParser
      :: Text                                          -- error-message label
      -> ([Text] -> Bool)                              -- header-row detector
      -> ((Text -> Maybe Text) -> Int -> Either RowError BankTransaction)
      -> StatementParser
    ```

    It reads rows, finds the header row via the detector (skipping the
    preamble), builds a column-name→index map, and for each subsequent data row
    passes a **by-name accessor** (`Text -> Maybe Text`) plus a 1-based data-row
    index to the validator. Header not found / no rows → `Left ParseError`;
    per-row failures → `Left RowError`. By-name access (not positional) is
    robust to column reordering, mirroring the CSV `FromNamedRecord` approach.

### Business provider (`PrivatBankBusiness`)

Replace the CSV parser with an XLSX one; delete the CSV fixtures/tests.

```haskell
parsePrivatBankBusinessXlsx :: StatementParser
parsePrivatBankBusinessXlsx =
  xlsxStatementParser "PrivatBank business XLSX" isHeaderRow validateRow
  where
    isHeaderRow cells = "Референс" `elem` cells && "Сума" `elem` cells
```

`validateRow col idx` (by-name `col :: Text -> Maybe Text`):

- **externalId**: `mkExternalTransactionId` on `col "Референс"` (empty/missing →
  `RowError`; no synthesis).
- **externalAccountId**: `col "Ваш рахунок"` (per-row → multi-account).
- **time**: parse `col "Дата проводки"` (`%d.%m.%Y`) + `col "Час проводки"`
  (`%H:%M:%S`) into one `UTCTime`.
- **amount**: `parseSignedDecimal` on `col "Сума"` (raw numeric string) → exact
  `Rational`.
- **currencyCode**: `currencyNumericCode <$> parseCurrency (col "Валюта")`.
- **contact**: `mkBankProviderContact (col "ЄДРПОУ")` (counterparty tax id;
  blank → `Nothing`).
- **description**: counterparty name (`col "Назва контрагента"`) + purpose
  (`col "Призначення платежу"`).
- **category**: `Nothing`. **hold/originalAmount/notes**: `False`/`Nothing`.

A missing required column, an unparseable date/amount/currency, or a blank
Референс yields a per-row `RowError`; a structurally-broken file yields a
whole-file `ParseError`.

Descriptor: slug `privatbank-business`, display `PrivatBank (Business)`,
`interpretation = defaultInterpretation`, `pull = Nothing`,
`fileImport = Just (FileImportCapability (Map.singleton StatementXlsx
parsePrivatBankBusinessXlsx))` (the field is `Maybe`).

### Multi-account import

No change to the import core: each `BankTransaction` already carries its own
`externalAccountId` (col M). The connection's `accountMap` maps each external
IBAN → a local account, so one file import populates all the user's accounts the
statement covers. Mixed currencies per file are fine — currency is read per row
(col E).

### Dependencies & gating

- XLSX reading uses **`zip-archive`** (unzip the `.xlsx`; available, new dep) +
  **`xml-conduit`** (parse the sheet/shared-strings XML — **already a direct
  project dependency**). This raw read keeps numeric amount cells as their raw
  decimal strings. **Do not** use `Codec.Xlsx` (its `CellDouble` eagerly
  converts numbers to `Double`, losing money precision). `zip-archive`, `xml`,
  `xml-conduit`, `zip`, `zlib`, and `xlsx` were all confirmed present in the
  snapshot; `xml-conduit` is already used elsewhere in the app.
- Cabal: the business flag block gains the XLSX deps and exposes
  `PrivatBankBusiness` + `Internal`. `Infrastructure.Banking.Xlsx` + its deps
  (`zip-archive`; `xml-conduit` already global) sit under a condition keyed off
  the XLSX-provider flag(s) (`flag(privatbank-business)` now; future XLSX
  providers extend with `||`), mirroring the CSV combined-condition block.
  **Narrow the existing CSV block:** since the business provider is now XLSX-only
  and no longer uses `Csv`/cassava, revert that block's condition from
  `flag(privatbank) || flag(privatbank-business)` back to **`flag(privatbank)`**
  (otherwise a business-only build needlessly compiles Csv + pulls cassava).
  `Infrastructure.Banking.Statement` is always compiled (no external deps).

## Testing (Phase 1)

- **`Infrastructure.Banking.Statement`**: `parseSignedDecimal` cases (moved
  with the code).
- **`Infrastructure.Banking.Xlsx`**:
  - Pure `parseSharedStrings`/`parseSheetRows` over inline XML — shared-string
    resolution, numeric-cell raw-string preservation (`"41051.28"` stays exact),
    column-order preservation.
  - `xlsxStatementParser` driver — header detection past a preamble, by-name
    access, 1-indexed `RowError`, whole-file `ParseError` on a headerless sheet.
  - `readXlsxSheet` over one small committed **synthetic** `.xlsx` fixture.
- **`PrivatBankBusiness`** (`PrivatBankBusinessSpec`): a synthetic `.xlsx`
  fixture with a preamble, header on row 9, and rows exercising: a UAH and a USD
  row on **two different accounts** (multi-account, mixed currency); a decimal
  amount that must stay exact; a **conversion pair** (USD-debit + UAH-credit —
  the Phase-2 fixture, imported as two transactions here); a row missing
  Референс (→ `RowError`); a bad amount (→ `RowError`). Assert field mapping
  (exact `Rational` amount, numeric currency, date+time `UTCTime`, per-row
  account from col M, tax-id `contact`, `Nothing` category, Референс external
  id), and the descriptor's capability flags (`supportsFile`, not `supportsPull`,
  `StatementXlsx`).
- **No real PII**: all fixtures synthetic. The real sample stays local
  (`~/Downloads/privatbank/privatbank-business/`).

Follow TDD: pure XLSX parsers first, then the driver, then the provider.

## Phase 2: cross-currency transfer via composable matchers

*Captured here; implemented as the next slice after Phase 1 lands.*

A currency conversion is semantically **one transfer** across two of the user's
own accounts, e.g. `-918.99 USD` ("валютно-обмінні операції") on the USD account
and `+41051.28 UAH` ("Гривні від продажу 918.99 USD по курсу 44.67") on the UAH
account — with `918.99 × 44.67 = 41051.28`. The current
`defaultTransferMatcher` cannot pair these: it requires **same currency and
equal magnitude**.

Design direction:

- **Make `TransferMatcher` composable (single field, value-level composition).**
  Keep `TransactionInterpretation`'s single `transferMatcher :: TransferMatcher`
  field. `TransferMatcher` is a `newtype` over
  `BankTransaction -> BankTransaction -> Bool`; give it a **`Semigroup`/`Monoid`**
  instance that ORs `matchesTransfer` (`mempty` = never matches). Providers then
  compose many strategies into one value —
  `defaultTransferMatcher w <> providerFxMatcher w` — instead of the field
  becoming a list. This generalizes the existing per-provider customization
  (PrivatBank already overrides `transferMatcher` for card-to-card
  self-transfers) with no change to the `TransactionInterpretation` shape.
- **Generic FX algorithm in the shared layer; providers plug only a signal.**
  A reusable `fxTransferMatcher :: (BankTransaction -> Maybe FxLeg) ->
  NominalDiffTime -> TransferMatcher` holds the provider-agnostic algorithm:
  pair two opposite-direction legs across two of the user's own accounts when
  their `FxLeg`s reconcile (`|a| × rate ≈ |b|`) within the window. Each provider
  supplies only the extractor `fxSignal :: BankTransaction -> Maybe FxLeg`
  (marks a conversion leg + its rate/counter-amount). This keeps the generic
  algorithm out of providers (a stated project preference); monobank/WIX bank
  reuse `fxTransferMatcher` with their own `fxSignal`.
- **PrivatBank's `fxSignal`** recognizes a currency sale from its **counterparty
  signal** ("Продаж UAH клієнтів" / "Продаж USD клієнта") and extracts the rate
  from "по курсу N"; the counterparty text is *input to the extractor*, not the
  matching mechanism. Emits a single USD→UAH `Transfer`, extending the
  tracker#44 transfer-merge saga with an exchange rate and relaxed magnitude.
- **Open investigation (decides the pairing key):** check whether both legs of a
  real conversion carry a **common reference token** (e.g. the `RIDSQ…` seen in
  the USD leg). If so, pair deterministically by that reference (ideal);
  otherwise fall back to rate/amount reconciliation. To be resolved at the start
  of Phase 2 against the real file.
- **Acceptance test:** the two conversion rows above collapse into one Transfer.

Out of scope even for Phase 2: a generic FX aggregator; changes to the import
saga's double-entry/per-leg-FX accounting beyond representing the merged
transfer.

## Backward compatibility

No stored-event / command / read-model / credential shape changes. `BankProviderId`
is a bare-string slug. No migration.

## References

- tracker#46 — support business accounts.
- #38 — file-import transport seam (reused).
- tracker#44 — transfer-merge saga (Phase 2 extends it).
- backend#97 — provider-agnostic banking layer.
- Provider contact-signal (tracker#54) — the name-agnostic contact map the
  tax-id `contact` feeds.
- Key files: `Infrastructure/Banking/Provider.hs`
  (`FileImportCapability`, `StatementFormat` incl. `StatementXlsx`,
  `TransactionInterpretation`/`TransferMatcher`),
  `Infrastructure/Banking/Csv.hs` (retained CSV infra),
  `Infrastructure/Banking/PrivatBank/Internal.hs` (personal CSV parser),
  `Infrastructure/Banking/Providers.hs` (registration), `config/*.yaml`.
