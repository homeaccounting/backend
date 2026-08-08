---
status: completed
date: 2026-08-07
---

# Composable transfer matchers + cross-currency conversion → Transfer (tracker#46 Phase 2)

> **Implemented** on `feat/privatbank-business-file-import`: composable
> `TransferMatcher` (Semigroup/Monoid), generic `fxTransferMatcher` + PrivatBank
> business `fxSignal`, and cross-currency `postInternalTransfer` (per-leg amounts
> + implied `ExchangeRate`). Verified end-to-end — a synthetic conversion imports
> as one cross-currency Transfer, and a real-file smoke test pairs exactly the
> three USD↔UAH conversions (and nothing else). Known pre-existing caveat
> surfaced: `Money`/`ExchangeRate` JSON round-trips through `Double` (exactness
> caveat), tracked separately — not introduced here.

Phase 2 of the PrivatBank business import (Phase 1 =
[XLSX statement import](2026-08-07-privatbank-business-file-import-design.md)).
Makes an imported **currency conversion** — a debit on one account in currency A
and a credit on another account in currency B, e.g. `-918.99 USD` +
`+41051.28 UAH` — collapse into **one cross-currency `Transfer`**, and unifies
the bank transfer-matching strategies behind one composable abstraction.

## Problem

Import pairs two opposite bank-transaction legs into an internal `Transfer` via a
single per-provider `TransferMatcher` (`Infrastructure.Banking.Provider`), fed to
`pairInternalTransfers` (`Application.Services.BankImport.TransferPairing`). Two
gaps:

1. **The matcher can't see a conversion.** `defaultTransferMatcher` →
   `isTransferMatch` → `Leg.sameMovement` requires **equal magnitude AND equal
   currency** (`Domain/Transaction/Matching/Leg.hs`). A USD sale and its UAH
   proceeds share neither, so the legs never pair — they import as two unrelated
   transactions.
2. **Matchers don't compose.** There's one `transferMatcher` per provider;
   PrivatBank's is a hand-written *decorator* (`default AND card-last-4 check`).
   Adding an FX strategy means a second, orthogonal rule, with no composition
   primitive.

The **domain already supports cross-currency transfers** (verified): the posting
command/event carry per-leg `sourceAmount`/`targetAmount :: Money` +
`exchangeRate :: Maybe ExchangeRate`, the handler imposes no same-currency
invariant, and each account is debited/credited in its own currency. So Phase 2
needs **no new events/commands/aggregate fields** — only the matcher and the
import transfer-posting path change.

## Decisions (agreed)

1. **Composable `TransferMatcher` = OR of complete, provider-chosen strategies.**
   Keep the single `transferMatcher :: TransferMatcher` field; give
   `TransferMatcher` a `Semigroup`/`Monoid` instance that ORs `matchesTransfer`
   (`mempty` = never matches). Each strategy is a *complete* "are these two one
   transfer?" predicate; a provider composes the set it wants. **The generic
   default is NOT force-included** — a restrictive strategy (PrivatBank's
   card-last-4 check) *replaces* the default rather than being OR'd with it
   (OR-ing the bare default back in would re-admit exactly the coincidental
   same-currency pairs the card check exists to reject).
2. **Reconciliation stays its own shape.** Manual↔import reconciliation
   (`Domain/Transaction/Matching/Reconciliation.hs`, `NoMatch|Unique|Ambiguous`
   over a candidate set) is deliberately *not* folded into the boolean
   `TransferMatcher` (that would discard its ambiguity guard). Both families keep
   sharing the pure `Leg` kernel. The kernel/design should *allow* a future
   per-provider `ReconciliationMatcher` seam, but none is added now (YAGNI).

## Design

### 1. Composable `TransferMatcher`

In `Infrastructure.Banking.Provider`:

```haskell
instance Semigroup TransferMatcher where
  TransferMatcher f <> TransferMatcher g = TransferMatcher (\a b -> f a b || g a b)
instance Monoid TransferMatcher where
  mempty = TransferMatcher (\_ _ -> False)
```

Provider composition (illustrative):
- Monobank: `defaultTransferMatcher w` (unchanged).
- PrivatBank (personal): `privatBankCardMatcher w` — the existing
  `default AND card-last-4` predicate, now named as one complete strategy
  (behaviour unchanged; **no bare default OR'd in**).
- PrivatBank business: `defaultTransferMatcher w <> fxTransferMatcher
  privatBusinessFxSignal w` — same-currency own-transfers via the default, plus
  cross-currency conversions via the FX strategy.

This is behaviour-preserving for the existing providers (each keeps the exact
predicate it has today, just expressed through the composition primitive).

### 2. Generic FX matcher + provider signal

The generic algorithm lives in the shared banking layer; providers plug only the
signal (keeps provider-specific text-parsing out of the generic algorithm):

```haskell
-- Provider-supplied: recognise a currency-conversion leg and extract the
-- conversion amount it states. Nothing ⇒ not a conversion leg.
type FxSignal = BankTransaction -> Maybe FxLeg
data FxLeg = FxLeg { fxAmount :: Rational }  -- the conversion amount (e.g. 918.99 USD)

-- Generic, reusable by any provider:
fxTransferMatcher :: FxSignal -> NominalDiffTime -> TransferMatcher
fxTransferMatcher signal window = TransferMatcher $ \a b ->
  case (signal a, signal b) of
    (Just la, Just lb) ->
         a.currencyCode /= b.currencyCode             -- cross-currency
      && (a.amount < 0) /= (b.amount < 0)             -- opposite direction
      && withinWindow window a.time b.time
      && fxAmount la == fxAmount lb     -- EXACT shared conversion amount
    _ -> False
```

**Match on the exact shared conversion amount, not a rate.** Both legs state the
same conversion amount (`918.99`): the USD sale leg's own magnitude, and the
`продажу 918.99 USD` text on the UAH proceeds leg. Exact `Rational` equality is a
clean, tolerance-free pairing key — the earlier "|conversion|·rate ≈ |local|" idea
needed a rounding tolerance (the bank rounds the UAH to kopecks, and the stated
rate has limited precision), which this avoids. Two conversions in the same
window with the *same* conversion amount are the only ambiguous case → greedy
one-to-one picks one (documented edge, as with same-currency pairing). The rate
is **not** used for matching; it is derived at posting time as the implied
`targetAmount / sourceAmount`, which reproduces the credit amount exactly by
construction.

**PrivatBank business `fxSignal`** (in the PrivatBank provider module): returns
`Just` iff **`tx.description`** contains a currency-sale counterparty marker
(`Продаж UAH клієнтів` / `Продаж USD клієнта`), parsing the **conversion amount**
from the description (the USD leg states it as `в сумі 918.99, USD`; the UAH leg
as `продажу 918.99 USD`). **Read `tx.description`, not `tx.contact`** — the Phase-1
business parser folds the counterparty *name* (`Назва контрагента`) and the
payment *purpose* (`Призначення платежу`, which carries `по курсу N`) both into
`description`, whereas `contact` holds the EDRPOU tax id (not the sale marker).
So the single `description` field carries both the marker and the rate. The
counterparty match confirms "this is an FX leg"; the rate + magnitude
reconciliation confirms "these two are the pair" — belt and suspenders,
near-zero false-positive. **Statement-format assumption** (to encode in the
integration fixture from a real synthetic-PII sample): the sale marker *and*
the shared conversion amount appear on **both** legs (the USD-debit and the
UAH-credit rows).

> **Pairing note:** `pairInternalTransfers` is greedy one-to-one over legs that
> resolve to different local accounts, delegating the predicate to the composed
> `TransferMatcher`. The FX pair satisfies the different-local-accounts invariant
> (USD acct ≠ UAH acct). If a statement ever had two conversions with identical
> rate+magnitude in the same window, greedy pairing could mis-assign; this is an
> accepted edge (documented), consistent with how same-currency pairing already
> behaves.

### 3. Cross-currency import transfer posting

`postInternalTransfer` / `importTransferPair`
(`Application.Services.BankImportService`) today assume one currency: they build a
single `money` from the debit leg and set `sourceAmount = targetAmount = money`,
`exchangeRate = Nothing`, and guard **both** accounts to that one currency.
Generalise:

- `sourceAmount` = the **debit** leg's own `Money` (e.g. 918.99 USD);
  `targetAmount` = the **credit** leg's own `Money` (e.g. 41051.28 UAH).
- When the two leg currencies differ, set `exchangeRate = Just (mkExchangeRate
  sourceCur targetCur (targetMag / sourceMag))` — the **implied** rate from the
  two amounts (not an ECB lookup; the statement *is* the source of truth).
  `mkExchangeRate` rejects same-currency, so same-currency pairs keep
  `Nothing` (current behaviour).
- Currency guard: guard the **debit** account against the debit leg's currency
  and the **credit** account against the credit leg's currency (today it forces
  both to one) — so a USD account and a UAH account each validate against their
  own leg.

Same-currency internal transfers are unchanged (source == target amount, no
rate). The `importInfo` (both external ids) and dedup are unchanged.

**Reconciliation candidate search stays debit-leg-only — deliberately.**
`importTransferPair` builds a debit-leg `money`/`importedLeg` to look for a
pre-existing *manual* transfer to reconcile onto (`BankImportService` ~L377/384).
Leave this **unchanged**: for a cross-currency import it searches with the USD
`money` against the UAH credit account, finds nothing, and falls through to
`postFresh` — the FX posting above. Consequence to state plainly (not "unchanged"
by omission): **cross-currency imports always post fresh, never reconcile onto a
manual entry.** That's correct for now — manual cross-currency transfers can't
exist until the #44 merge is generalized (out of scope). Only the two
currency-construction sites *inside* `postInternalTransfer` change.

## Out of scope (Phase 2)

- **Manual transfer-merge cross-currency** (`TransactionService.transferMerge`,
  tracker#44) — still same-currency-only. Technically a small follow-on (relax
  the same-currency guard + carry the implied rate, mirroring what this phase did
  for the import path — the domain already supports asymmetric transfers). **But
  deliberately NOT built, because the use-case is thin:** it only serves the
  niche *retroactive* case of two **already-separately-recorded** manual legs in
  different currencies that turn out to be one conversion. The two common paths
  are already covered — entering a conversion fresh uses the direct
  cross-currency create-transfer flow (`resolveAndInitiate`/`resolveAmounts` with
  an ECB/user rate), and *imported* conversions are auto-merged by this phase.
  The remaining cleanup case also has a workaround (delete the two legs, add one
  transfer). Defer until a concrete user need appears; the fix is cheap when it
  does.
- A `ReconciliationMatcher` per-provider seam (YAGNI; kernel left open to it).
- FX rate *validation* against market/ECB rates — the statement's implied rate is
  authoritative for an already-settled conversion.
- Non-PrivatBank FX signals (monobank corporate etc.) — the generic
  `fxTransferMatcher` is ready for them; each supplies its own `fxSignal` later.

## Testing

- **Composable `TransferMatcher`** (`ProviderSpec` or a matcher spec): Semigroup
  laws-ish behaviour (OR, `mempty` identity); a composed `a <> b` matches iff
  either does; PrivatBank's card matcher unchanged (existing tests stay green).
- **`fxTransferMatcher`** (unit): pairs an opposite-direction cross-currency pair
  with agreeing rate + reconciling magnitudes; rejects same-currency, same
  direction, disagreeing rate, non-reconciling magnitudes, and non-conversion
  legs (signal `Nothing`).
- **PrivatBank `fxSignal`** (unit): recognises `Продаж UAH/USD` counterparties,
  parses the conversion amount from the description, `Nothing` for ordinary rows.
  Synthetic Ukrainian text.
- **Import integration**: an XLSX statement (Phase-1 parser) containing the real
  conversion shape (a USD debit + a UAH credit on two mapped accounts) imports as
  **one cross-currency `Transfer`** with per-leg amounts + the implied
  `ExchangeRate`, and the two accounts move in their own currencies. Same-currency
  internal transfer still posts as before. **Acceptance test:** the `-918.99 USD`
  / `+41051.28 UAH` pair → one Transfer (rate ≈ 44.67).
- No real PII; synthetic fixtures.

Follow TDD: matcher/Semigroup + fxTransferMatcher + fxSignal (pure) first, then
the posting generalisation, then the import integration test.

## Backward compatibility

No stored-event/command shape change (the cross-currency fields already exist on
the posting command/event; conversions simply start populating
`exchangeRate`/asymmetric amounts, which older transfers left symmetric). No
migration. Behaviour-preserving for all existing providers and same-currency
transfers.

## References

- Phase 1 spec: `2026-08-07-privatbank-business-file-import-design.md`.
- tracker#44 — transfer-merge saga (manual merge; cross-currency generalization is
  the out-of-scope follow-on).
- Key files: `Infrastructure/Banking/Provider.hs` (`TransferMatcher`,
  `TransactionInterpretation`, `defaultTransferMatcher`),
  `Infrastructure/Banking/PrivatBank.hs` (card matcher + new `fxSignal`),
  `Application/Services/BankImport/TransferPairing.hs` (`pairInternalTransfers`),
  `Application/Services/BankImportService.hs` (`postInternalTransfer` /
  `importTransferPair`), `Domain/Transaction/Matching/{Leg,Transfer}.hs` (shared
  kernel), `Domain/Core/Types.hs` (`Money`, `ExchangeRate`, `mkExchangeRate`).
