# Composable Transfer Matchers + Cross-Currency Conversion → Transfer — Phase 2 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make an imported currency conversion (a debit on one account + a credit on another, different currencies) merge into **one cross-currency `Transfer`**, and make the bank `TransferMatcher` composable so the generic, PrivatBank-card, and new FX strategies coexist.

**Architecture:** `TransferMatcher` gains a `Semigroup`/`Monoid` (OR). A generic `fxTransferMatcher` + provider `FxSignal` recognises a conversion pair by exact shared **conversion amount** (+ counterparty marker + opposite direction + different currency + window). `postInternalTransfer` is generalised to per-leg amounts + implied `ExchangeRate`. **No new events/commands/aggregate fields** — the posting command/event already carry `sourceAmount`/`targetAmount`/`exchangeRate`.

**Tech Stack:** Haskell (GHC 9.10, RIO, NoImplicitPrelude, StrictData), Hspec.

**Spec:** `docs/specs/2026-08-07-composable-transfer-matchers-fx-conversion-design.md`
**Branch:** continue on `feat/privatbank-business-file-import` (same tracker#46 feature; Phase 2 needs the Phase-1 XLSX parser for the acceptance test).

---

## Ground rules

- Nix: `nix develop -c {just build|just format|just lint|cabal test all …}`. `-Werror` via `just build`. Plain substrings in `--match`.
- RIO/NoImplicitPrelude/StrictData; total functions; no data-ctor exports beyond needed; no hlint suppressions; TDD; format+lint before commit; Conventional Commits.
- No real PII; synthetic fixtures.
- Behaviour-preserving for existing providers and same-currency transfers — the existing `PrivatBankTransfer`/import specs must stay green.

---

## Task 1: Composable `TransferMatcher` (Semigroup) + name the PrivatBank strategy

**Files:** `src/Infrastructure/Banking/Provider.hs`, `src/Infrastructure/Banking/PrivatBank.hs`, tests `test/Infrastructure/Banking/PrivatBankSpec.hs` (or a small `ProviderSpec`).

- [ ] **Step 1 (red):** Add a matcher-composition test to the **existing** `test/Infrastructure/Banking/TransferMatcherSpec.hs` (don't create a new `ProviderSpec` — both `ProviderSpec.hs` and `TransferMatcherSpec.hs` already exist): build two trivial `TransferMatcher`s and assert `(m1 <> m2).matchesTransfer` is the OR, and `mempty` never matches / is identity. Reuse `mkSameCurrencyBankTx` from `Testkit.BankingHelpers` for minimal `BankTransaction`s.
- [ ] **Step 2 (red→build):** `nix develop -c just build` — expect failure (no `Semigroup TransferMatcher`).
- [ ] **Step 3 (green):** In `Provider.hs`, add instances after the `TransferMatcher` newtype:
  ```haskell
  instance Semigroup TransferMatcher where
    TransferMatcher f <> TransferMatcher g = TransferMatcher (\a b -> f a b || g a b)
  instance Monoid TransferMatcher where
    mempty = TransferMatcher (\_ _ -> False)
  ```
  Export nothing new (instances need no export; `TransferMatcher(..)`/accessor already exported).
- [ ] **Step 4:** In `PrivatBank.hs`, rename/keep `privatBankTransferMatcher` as one **complete** strategy (it already is `default AND cardCheck`) — no behavioural change; just confirm it is NOT OR-composed with a bare default. (If you want clarity, add a Haddock line noting it replaces, not extends, the default.) `privatBankInterpretation` stays `transferMatcher = privatBankTransferMatcher w`.
- [ ] **Step 5:** `just build` (warning-clean); run `--match "Infrastructure.Banking.PrivatBank"` + the new composition test — all green (PrivatBank behaviour unchanged).
- [ ] **Step 6:** `just format` + `just lint`; commit `feat(banking): composable TransferMatcher (Semigroup/Monoid, OR of strategies)`.

---

## Task 2: Generic `fxTransferMatcher` + PrivatBank business `fxSignal`

**Files:** `src/Infrastructure/Banking/Provider.hs` (generic matcher + `FxLeg`/`FxSignal`), `src/Infrastructure/Banking/PrivatBankBusiness/Internal.hs` (`fxSignal`), `src/Infrastructure/Banking/PrivatBankBusiness.hs` (compose interpretation), tests `test/Infrastructure/Banking/PrivatBankBusinessSpec.hs`.

- [ ] **Step 1 (red):** In `PrivatBankBusinessSpec`, add:
  - `fxSignal` unit tests: a synthetic UAH-proceeds description (`"Продаж UAH клієнтів — Гривні від продажу 918.99 USD по курсу 44.67"`) → `Just (FxLeg 918.99)`; a synthetic USD-sale description (`"Продаж USD клієнта — Списання коштів … в сумі 918.99, USD, …"`) → `Just (FxLeg 918.99)`; an ordinary row → `Nothing`.
  - `fxTransferMatcher` tests: two opposite-direction, different-currency `BankTransaction`s whose `fxSignal` conversion amounts are equal, within window → matches; reject when same currency, same direction, differing conversion amount, or a leg's signal is `Nothing`.
- [ ] **Step 2 (red build).**
- [ ] **Step 3 (green):** In `Provider.hs` add (export `FxLeg(..)`, `FxSignal`, `fxTransferMatcher`, and a `defaultFxPairingWindow`):
  ```haskell
  type FxSignal = BankTransaction -> Maybe FxLeg
  newtype FxLeg = FxLeg { fxAmount :: Rational } deriving (Eq, Show)

  -- generous window: conversion legs may post minutes/hours apart the same day;
  -- the EXACT shared conversion amount is the real discriminator, so a wide window
  -- adds negligible false-positive risk.
  defaultFxPairingWindow :: NominalDiffTime
  defaultFxPairingWindow = 86400   -- 1 day

  fxTransferMatcher :: FxSignal -> NominalDiffTime -> TransferMatcher
  fxTransferMatcher signal window = TransferMatcher $ \a b ->
    case (signal a, signal b) of
      (Just la, Just lb) ->
           a.currencyCode /= b.currencyCode
        && (a.amount < 0) /= (b.amount < 0)
        && abs (diffUTCTime a.time b.time) <= window
        && fxAmount la == fxAmount lb
      _ -> False
  ```
  **Imports:** Provider.hs uses an explicit RIO import list (`Provider.hs:40`). Add the new symbols it doesn't already list: the `Semigroup`/`Monoid` classes, `(||)`, `(&&)`, `(==)`, `(/=)`, `(<=)`, `False`, and `diffUTCTime` (from `Data.Time`). `abs`/`(<)` are already imported. Let `-Werror` guide.
- [ ] **Step 4 (green):** In `PrivatBankBusiness/Internal.hs`, add `fxSignal :: FxSignal` (export it). Gate on `tx.description` containing `"Продаж UAH"` or `"Продаж USD"` (the currency-sale counterparty markers — read `description`, NOT `contact`).
  Extract the conversion amount **robustly**: the description contains the currency code more than once (e.g. `"Продаж USD клієнта — … в сумі 918.99, USD, …"` — the `Продаж USD` occurrence has NO preceding number). So do NOT take "the number before the first `USD`". Instead scan for the occurrence of a Latin currency code (`USD` initially; small extensible set) that is **immediately preceded by a parseable decimal token** (strip a trailing comma like `918.99,` before parsing), and return that number. Reuse `Statement.parseSignedDecimal`. `Nothing` if no marker or no such number. Pure + total (`RIO.Text` ops).
  **Format confirmed from the real file** (all three conversion pairs): the USD sale leg states `в сумі 918.99, USD`, the UAH proceeds leg states `продажу 918.99 USD` — both restate the identical conversion amount, so exact-`Rational` equality is a valid key. Mirror this text shape in the synthetic test fixtures.
- [ ] **Step 5 (green):** In `PrivatBankBusiness.hs`, replace `interpretation = defaultInterpretation` with an explicitly-constructed `TransactionInterpretation` (match the house style of `defaultInterpretation`/`privatBankInterpretation`, which build the record explicitly rather than update):
  ```haskell
  interpretation =
    TransactionInterpretation
      { classify = defaultClassify,
        transferMatcher =
          defaultTransferMatcher defaultTransferPairingWindow
            <> fxTransferMatcher fxSignal defaultFxPairingWindow,
        labelExpenseCategories = Map.empty
      }
  ```
  Import `fxSignal` from `.Internal`; `fxTransferMatcher`/`defaultFxPairingWindow`/`defaultTransferMatcher`/`defaultTransferPairingWindow`/`defaultClassify`/`TransactionInterpretation(..)` from `Provider`; `Map` from `RIO.Map`. (A record update on `defaultInterpretation` also compiles, but explicit construction matches the neighbors and sidesteps any `DuplicateRecordFields` corner.)
- [ ] **Step 6:** `just build`; `--match "PrivatBankBusiness"` green. `just format` + `just lint`.
- [ ] **Step 7:** Commit `feat(banking): generic fxTransferMatcher + PrivatBank business fx signal (currency-sale pairing)`.

---

## Task 3: Cross-currency `postInternalTransfer` + import acceptance test

**Files:** `src/Application/Services/BankImportService.hs` (`postInternalTransfer`, ~L410-497 + header comment), test `test/Infrastructure/Banking/…` integration spec (or extend the existing bank-import integration spec).

- [ ] **Step 1 (red):** Add an integration test that imports (via the Phase-1 XLSX parser + the import service) a synthetic `.xlsx` containing a conversion pair — a `-918.99 USD` row on account A (mapped to a USD local account) and a `+41051.28 UAH` row on account B (mapped to a UAH local account), both with the `Продаж …`/conversion-amount markers — and asserts the result is **one `Transfer`** with `sourceAmount = 918.99 USD`, `targetAmount = 41051.28 UAH`, `exchangeRate = Just (rate ≈ 44.67)`. Also assert a same-currency internal transfer still posts with equal amounts + `Nothing` rate (regression). Reuse `Testkit` bank-import harness + `Testkit.Xlsx.buildXlsx`. (Check `test/Testkit/` and existing bank-import integration specs for the harness pattern; if an in-memory event-store harness exists, use it — otherwise this may be a `*IntegrationSpec` needing the test DB.)
- [ ] **Step 2 (red build).**
- [ ] **Step 3 (green):** Generalise `postInternalTransfer` to per-leg money + implied rate:
  - Build `srcMoney` from `dLeg` and `tgtMoney` from `cLeg` (each: `currencyFromNumericCode …currencyCode` then `mkMoney cur (abs …amount)`; keep the existing `UnsupportedCurrency`/`InvalidAmount` skip vocabulary for BOTH legs).
  - `exchangeRate :: Maybe ExchangeRate` computed inside the `ExceptT ImportOutcome AppM` flow (NOT the literal `Just <$> mkExchangeRate …`, which is `Either Text (Maybe …)`):
    ```haskell
    rate <-
      if srcCur == tgtCur
        then pure Nothing
        else case mkExchangeRate srcCur tgtCur (tgtMag / srcMag) of
          Left e  -> throwE (Skipped (InvalidAmount e))
          Right r -> pure (Just r)
    ```
    where `tgtMag = abs cLeg.amount`, `srcMag = abs dLeg.amount` (both > 0 after `mkMoney`).
  - `guardCurrency dData srcMoney` and `guardCurrency cData tgtMoney` (each account against **its own** leg — replaces guarding both against one `money`).
  - Set `sourceAmount = srcMoney`, `targetAmount = tgtMoney`, `exchangeRate = <computed>`.
  - Update the header comment (L395-408): legs need NOT share currency/magnitude; a cross-currency pair posts as an asymmetric Transfer with the implied rate.
  - Leave `importTransferPair`'s reconciliation candidate `money`/`importedLeg` (debit-leg-only, ~L377/384) **unchanged** — cross-currency imports correctly fall through to `postFresh`. (Add a one-line comment noting this is deliberate.)
  - Signatures to reuse (verify): `mkExchangeRate :: Currency -> Currency -> Rational -> Either Text ExchangeRate` (`Domain/Core/Types.hs`), `mkMoney`, `currencyFromNumericCode`, `moneyCurrency`, `unMoney`.
- [ ] **Step 4:** `just build`; run the new integration test + existing bank-import specs — green.
- [ ] **Step 5:** `just format` + `just lint`; commit `feat(banking): post imported currency conversions as one cross-currency Transfer`.

---

## Task 4: Gate + docs + real-file smoke test

- [ ] **Step 1:** `nix develop -c just rebuild` then `nix develop -c just test` — green apart from the documented env-only `eventium_test` DB integration failures. Confirm banking specs pass.
- [ ] **Step 2 (real-file smoke test):** Via `cabal repl`, run the **full import interpretation** over the real `~/Downloads/privatbank/privatbank-business/stmts_*.xlsx`: parse → `pairInternalTransfers (interpretation.transferMatcher)` and confirm the **three** conversion pairs (918.99/41051.28, 1000/44570, 1524.46/67792.74) each pair into one InternalTransfer with the right two legs, and the non-conversion rows stay unpaired. (Local only; do not commit the file.)
- [ ] **Step 3:** Set the Phase-2 spec `status: completed`; set the Phase-1 spec note to reflect Phase 2 landed. Update PR #156 body to cover both phases.
- [ ] **Step 4:** Commit `docs(banking): mark Phase 2 (cross-currency conversion transfers) complete`.

---

## Verification checklist

- [ ] `just rebuild && just test` green (modulo env-only `eventium_test`).
- [ ] Existing providers/same-currency transfers unchanged (PrivatBank card matcher, Monobank, same-currency internal transfer).
- [ ] Cross-currency conversion → one Transfer with per-leg amounts + implied `ExchangeRate`; each account moves in its own currency.
- [ ] Real-file smoke test: all three conversion pairs merge.
- [ ] No new stored-event/command shape; no migration.
- [ ] No real PII; synthetic fixtures.
