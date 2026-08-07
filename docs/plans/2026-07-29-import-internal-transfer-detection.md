# Import-Time Internal Transfer Detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When importing from two linked bank accounts, detect an internal transfer between them and post it as a single `Transfer` instead of a double-booked income + expense pair — generically across providers (Monobank pull, PrivatBank file) and both transports.

**Architecture:** A pure pairing engine (`pairInternalTransfers`) runs as a pre-pass inside the shared import sink `importMany` (used by both the pull and file transports). It partitions the batch into internal-transfer pairs and leftovers; pairs become one `Transfer`, leftovers flow through the unchanged income/expense path. Provider interpretation is grouped into one **`TransactionInterpretation`** capability on `BankProviderDescriptor` (replacing the standalone `classify` field): a per-line `classify` plus a `TransferMatcher` for the "are these two legs the same movement?" decision, defaulting to a heuristic (opposite sign, equal magnitude, same currency, within a time window) and overridable by any provider with a stronger signal. It is threaded as a single parameter through the resolvers and handlers. The pull entry point (`importConnection`) is restructured to fetch all linked accounts first so both legs are visible in one batch. `ImportInfo` carries a `NonEmpty` of external ids so both legs deduplicate.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude, `NoImplicitPrelude`), Hspec + QuickCheck, Eventium event store, Cabal/Hpack via `just`.

**Spec:** `docs/specs/2026-07-29-import-internal-transfer-detection-design.md`

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `src/Infrastructure/Banking/Provider.hs` | `TransferMatcher` + `TransactionInterpretation` types, `defaultTransferPairingWindow`, `defaultTransferMatcher`, `defaultInterpretation`; `interpretation` field replaces `classify` on `BankProviderDescriptor` | Modify |
| `src/Infrastructure/Banking/Monobank.hs` | `classify` field → `interpretation = defaultInterpretation` | Modify (`~59`) |
| `src/Infrastructure/Banking/PrivatBank.hs` | Define `ownCardCounterpartLast4`, `privatBankTransferMatcher`, `privatBankInterpretation`; `classify` field → `interpretation = privatBankInterpretation` | Modify (`~19`) |
| `src/Application/Services/BankImport/TransferPairing.hs` | Pure `pairInternalTransfers` (consumes a `TransferMatcher`) + `InternalTransfer` type & accessors | **Create** |
| `src/Domain/Core/Types.hs` | `ImportInfo` carries `NonEmpty ExternalTransactionId`; accessor returns the set | Modify (`~1388-1417`) |
| `src/Application/ReadModels/BankImportReadModel.hs` | Fan out one dedup row per external id | Modify (`~118-124`) |
| `src/Application/Services/BankImportService.hs` | `importMany`/`importConnection` take a `TransactionInterpretation` (replacing `classify`); pre-pass; `importTransferPair`; `groupAccountResults` extension | Modify |
| `src/Application/Services/ConfigurationService.hs` | `getConnectionProvider` / `getConnectionFileImport` return `desc.interpretation` | Modify (`~678`, `~713`) |
| `src/Web/API/BankingAPI.hs` | Handlers destructure + pass the matcher | Modify (`~352`, `~374`, `~421`, `~459`) |
| `backend.cabal` / `package.yaml` | Register new module | Modify (via `hpack`) |
| `test/Application/Services/BankImport/TransferPairingSpec.hs` | Example tests for pure pairing | **Create** |
| `test/Application/Services/BankImport/TransferPairingPropertySpec.hs` | QuickCheck invariants (primary coverage) | **Create** |
| `test/Application/Services/BankImportServiceSpec.hs` | Unit: transfer detection, partial-dedup fall-through, single-leg unchanged, **file/PrivatBank multi-account batch** | Modify |
| `test/Integration/BankImportWorkflowSpec.hs` | Integration (pull): two linked accounts + internal transfer → one `Transfer`, balances correct | Modify |

**Ordering rationale:** the capability type (Task 1) is a leaf the pure engine depends on; the engine (Task 2) is pure and independent; the `ImportInfo` change (Task 3) is foundational for writing both dedup ids; the `importMany` wiring (Task 4) needs all three; the end-to-end wiring (Task 5: `importConnection` + resolvers + handlers) needs the wiring; verification (Task 6) closes out.

Notes for the implementer:
- `NoImplicitPrelude` is on — `import RIO` and `import qualified RIO.*`. `NonEmpty`/`:|` are re-exported by `RIO`.
- Never export data-constructor or field selectors (`NoFieldSelectors`); expose accessor functions instead.
- Run `just build` / `just test` inside `nix develop`. A one-off `Cabal-7125` / flaky `-j` failure is spurious — re-run before treating it as real.
- `ormolu` reformats; run `just format` before each commit. Do not fight its operator-chain splitting.

---

## Task 1: `TransactionInterpretation` provider capability

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs`
- Modify: `src/Infrastructure/Banking/Monobank.hs:59`, `src/Infrastructure/Banking/PrivatBank.hs:19`
- Modify (other `BankProviderDescriptor` construction sites — the new field is **mandatory**, so `-Wmissing-fields`/`-Werror` fails until each sets it):
  - `test/Testkit/AppEnv.hs:149` (`stubPullDescriptor`), `test/Testkit/AppEnv.hs:174` (`stubFileOnlyDescriptor`)
  - `test/Infrastructure/Banking/RegistrySpec.hs:29` (`mkDescriptor`), `test/Infrastructure/Banking/RegistrySpec.hs:54` (inline `d`)
- Modify (descriptor `.classify` READER — the field moves into `interpretation`): `test/Infrastructure/Banking/MonobankSpec.hs:81` binds `let classify = d.classify`; change to `d.interpretation.classify`. (Confirmed the only `.classify` reader beyond the resolvers/handlers already covered.)

- [ ] **Step 1: Write a failing unit test for `defaultTransferMatcher`**

Add a small spec (or a `describe` in an existing provider spec — check `test/Infrastructure/Banking/` for an existing home; otherwise create `test/Infrastructure/Banking/TransferMatcherSpec.hs`). Assertions using `Testkit.BankingHelpers`:

```haskell
-- matchesTransfer of (defaultTransferMatcher defaultTransferPairingWindow):
--   True  for opposite-sign, equal-magnitude, same-currency, same-time legs
--   False for same-sign, for unequal magnitude, for different currency,
--   and for legs 10 minutes apart
```

- [ ] **Step 2: Run to confirm failure**

Run: `cabal test all --test-option='--match' --test-option="/defaultTransferMatcher/"`
Expected: FAIL (not defined / not exported).

- [ ] **Step 3: Add the capability to `Provider.hs`**

Add exports `TransferMatcher (..)`, `TransactionInterpretation (..)`, `defaultTransferMatcher`, `defaultTransferPairingWindow`, `defaultInterpretation`, and change the descriptor's `classify` field to `interpretation`. Implementation:

```haskell
-- | How a provider decides that two statement lines are the two legs of one
-- internal transfer between the user's own accounts. Provider-neutral in shape:
-- 'defaultTransferMatcher' is the heuristic used by providers with no stronger
-- signal; a provider that exposes a shared reference id or counterparty account
-- can supply its own matcher. The matcher answers ONLY "same movement?" — the
-- pairing engine owns the different-account and one-to-one invariants.
newtype TransferMatcher = TransferMatcher
  { matchesTransfer :: BankTransaction -> BankTransaction -> Bool
  }

-- | How a provider interprets its raw statement lines into domain intents:
-- the per-line direction ('classify') and the pairwise same-movement predicate
-- ('transferMatcher'). Grouped so a provider has ONE cohesive interpretation
-- seam rather than a growing set of parallel hooks.
data TransactionInterpretation = TransactionInterpretation
  { classify :: BankTransaction -> TransactionClassification,
    transferMatcher :: TransferMatcher
  }

-- | Default time gap allowed between two legs of the same transfer. Monobank
-- posts both cards near-simultaneously; five minutes is a generous bound.
defaultTransferPairingWindow :: NominalDiffTime
defaultTransferPairingWindow = 300

-- | The default heuristic: opposite signs, equal magnitude, same currency,
-- timestamps within @window@.
defaultTransferMatcher :: NominalDiffTime -> TransferMatcher
defaultTransferMatcher window =
  TransferMatcher $ \a b ->
    a.currencyCode == b.currencyCode
      && signum a.amount /= signum b.amount
      && abs a.amount == abs b.amount
      && abs (diffUTCTime a.time b.time) <= window

-- | Interpretation for providers with no stronger signal: sign-based direction
-- plus the default transfer heuristic.
defaultInterpretation :: TransactionInterpretation
defaultInterpretation =
  TransactionInterpretation defaultClassify (defaultTransferMatcher defaultTransferPairingWindow)
```

Change the field on `BankProviderDescriptor` from `classify :: BankTransaction -> TransactionClassification` to:

```haskell
    interpretation :: TransactionInterpretation,
```

Because `classify` now lives on `TransactionInterpretation` and no longer on the descriptor, there is exactly one record with a `classify` field — no `DuplicateRecordFields` dot-access ambiguity. Consumers read `desc.interpretation.classify` / `desc.interpretation.transferMatcher`.

Imports: `Provider.hs` uses a **selective** `Data.Time (UTCTime)` import (line 30) and a **curated selective** RIO import (line 33). Merge `NominalDiffTime, diffUTCTime` into the existing `Data.Time (…)` line (don't add a second), and expand the RIO import to add the operators/functions the matcher body needs: `(==)`, `(/=)`, `(&&)`, `(<=)`, `signum`, `abs`. `OverloadedRecordDot` is already on (line 1).

- [ ] **Step 4: Set the field in both descriptors**

Each construction site listed in **Files** currently sets `classify = defaultClassify`. Replace that field with an `interpretation`:

- **Monobank descriptor** and the **four test stubs** → `interpretation = defaultInterpretation`.
- **PrivatBank descriptor** → `interpretation = privatBankInterpretation` (defined in Step 4b).

`defaultInterpretation` comes from `Infrastructure.Banking.Provider` (replace `defaultClassify` with `defaultInterpretation` in the selective import lists of `Monobank.hs`, `test/Testkit/AppEnv.hs`, and `test/Infrastructure/Banking/RegistrySpec.hs`). All six sites construct `BankProviderDescriptor`, not just the two real descriptors.

- [ ] **Step 4b: PrivatBank self-label matcher** (validated against real Privat24 exports — see `docs/specs/…`)

In `src/Infrastructure/Banking/PrivatBank.hs`, add (and **widen its export list** — it currently exports only `(descriptor)` — to also export `ownCardCounterpartLast4` and `privatBankTransferMatcher` so `PrivatBankTransferSpec.hs` can import them; `privatBankInterpretation` may stay unexported if only `descriptor` uses it):

```haskell
-- | Last 4 digits of the counterpart own-card named on a PrivatBank
-- self-labeled transfer row, else Nothing. Both legs are labeled:
--   outgoing: description "На свою картку *NNNN"   (category "Переказ на свою картку")
--   incoming: description "Зі своєї картки *NNNN"  (category "Зарахування зі своєї картки")
ownCardCounterpartLast4 :: BankTransaction -> Maybe Text
ownCardCounterpartLast4 tx =
  listToMaybe
    [ d
    | marker <- ["На свою картку *", "Зі своєї картки *"],
      Just rest <- [T.stripPrefix marker (T.strip tx.description)],
      let d = T.takeWhile isDigit rest,
      not (T.null d)
    ]

-- | Precise PrivatBank transfer matcher: opposite sign, equal magnitude, same
-- currency, within window, AND at least one leg names the other's card last-4.
privatBankTransferMatcher :: NominalDiffTime -> TransferMatcher
privatBankTransferMatcher window =
  TransferMatcher $ \a b ->
    a.currencyCode == b.currencyCode
      && signum a.amount /= signum b.amount
      && abs a.amount == abs b.amount
      && abs (diffUTCTime a.time b.time) <= window
      && (namesOther a b || namesOther b a)
  where
    last4 = T.takeEnd 4 . T.filter isDigit . unExternalAccountId
    namesOther x y = ownCardCounterpartLast4 x == Just (last4 y.externalAccountId)

privatBankInterpretation :: TransactionInterpretation
privatBankInterpretation =
  TransactionInterpretation defaultClassify (privatBankTransferMatcher defaultTransferPairingWindow)
```

Imports: `T` = `RIO.Text`; `isDigit` from `RIO.Char`; `listToMaybe` from `RIO.List`; `NominalDiffTime`/`diffUTCTime` from `Data.Time`; `unExternalAccountId` from `Domain.Banking.Types`; `TransferMatcher (..)`, `TransactionInterpretation (..)`, `defaultClassify`, `defaultTransferPairingWindow` from `Infrastructure.Banking.Provider`. (`last4` filters to digits first so the masked format `4627 **** **** 2222` yields `2222`.)

Add unit tests (new `test/Infrastructure/Banking/PrivatBankTransferSpec.hs`, or a `describe` in an existing PrivatBank spec), using the real observed rows as fixtures:
- `ownCardCounterpartLast4` returns `Just "2222"` for description `На свою картку *2222`, `Just "1111"` for `Зі своєї картки *1111`, and `Nothing` for a normal row (e.g. `Іваненко І.`) and for a ФОП `Зарахування … Переказ власних коштiv` row (no card).
- `matchesTransfer (privatBankTransferMatcher defaultTransferPairingWindow)` is `True` for the outgoing `…1111 / *2222 / −20000 UAH` leg against the incoming `…2222 / *1111 / +20000 UAH` leg (1 s apart), and `False` when the named last-4 doesn't match the other card, when magnitudes differ, when currencies differ, or when one leg is a non-self-labeled row.

- [ ] **Step 5: Build**

Run: `just build`
Expected: compiles once all six construction sites (two descriptors + four test stubs) set `transferMatcher`. `-Wmissing-fields` under `-fci` flags any you miss.

- [ ] **Step 6: Run the matcher test**

Run: `cabal test all --test-option='--match' --test-option="/defaultTransferMatcher/"`
Expected: PASS.

- [ ] **Step 7: Format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "feat(banking): TransactionInterpretation provider capability (classify + transfer matcher)"
```

---

## Task 2: Pure internal-transfer pairing engine

**Files:**
- Create: `src/Application/Services/BankImport/TransferPairing.hs`
- Create: `test/Application/Services/BankImport/TransferPairingSpec.hs`
- Create: `test/Application/Services/BankImport/TransferPairingPropertySpec.hs`
- Modify: `package.yaml` (run `hpack` after adding the module)

- [ ] **Step 1: Write the module skeleton (types + signature)**

Create `src/Application/Services/BankImport/TransferPairing.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.BankImport.TransferPairing
-- Description : Pure detection of internal transfers between two linked accounts.
--
-- When a user links two of their own accounts and imports from both, an
-- internal transfer appears on BOTH statements — a debit on one account and a
-- credit on the other. This engine pairs those two legs so the import sink can
-- post a single 'Transfer' instead of a double-booked income + expense.
--
-- The "same movement?" decision is delegated to a provider-supplied
-- 'TransferMatcher' (default: a heuristic). This engine owns the
-- provider-independent invariants: legs must be on DIFFERENT linked accounts,
-- pairing is one-to-one, and collisions resolve deterministically.
module Application.Services.BankImport.TransferPairing
  ( InternalTransfer,
    debitLocalAccount,
    creditLocalAccount,
    debitLeg,
    creditLeg,
    pairInternalTransfers,
  )
where

import Domain.Banking.Types (ExternalAccountId)
import Domain.Core.Types (AccountId)
import Infrastructure.Banking.Provider (BankTransaction (..), TransferMatcher (..))
import RIO
import RIO.List (sortBy)

-- | A matched internal transfer: the debit leg (money leaving) and the credit
-- leg (money arriving), plus the local account each was routed to.
data InternalTransfer = InternalTransfer
  { debitLocalAccount' :: AccountId,
    creditLocalAccount' :: AccountId,
    debitLeg' :: BankTransaction,
    creditLeg' :: BankTransaction
  }
  deriving (Show, Eq)

debitLocalAccount :: InternalTransfer -> AccountId
debitLocalAccount = debitLocalAccount'

creditLocalAccount :: InternalTransfer -> AccountId
creditLocalAccount = creditLocalAccount'

debitLeg :: InternalTransfer -> BankTransaction
debitLeg = debitLeg'

creditLeg :: InternalTransfer -> BankTransaction
creditLeg = creditLeg'

pairInternalTransfers ::
  TransferMatcher ->
  [(ExternalAccountId, AccountId, BankTransaction)] ->
  ([InternalTransfer], [(ExternalAccountId, AccountId, BankTransaction)])
pairInternalTransfers _ _ = ([], [])  -- replaced in Step 5
```

- [ ] **Step 2: Register the module and confirm it compiles**

Run: `hpack && just build`
Expected: compiles. If the module is not found, confirm `package.yaml` `source-dirs` covers it (it should, `src` is recursive) and re-run `hpack`.

- [ ] **Step 3: Write the failing example spec**

Create `test/Application/Services/BankImport/TransferPairingSpec.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.BankImport.TransferPairingSpec (spec) where

import Application.Services.BankImport.TransferPairing
  ( creditLeg,
    debitLeg,
    pairInternalTransfers,
  )
import Data.Time (UTCTime, addUTCTime)
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Core.Types (AccountId, unsafeExternalTransactionId)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
import RIO
import qualified RIO.List as L
import Test.Hspec
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Helpers (mockAccountIdN)

matcher :: TransferMatcher
matcher = defaultTransferMatcher defaultTransferPairingWindow

extA, extB :: ExternalAccountId
extA = unsafeExternalAccountId "card-A"
extB = unsafeExternalAccountId "card-B"

localA, localB :: AccountId
localA = mockAccountIdN 10
localB = mockAccountIdN 20

debitA :: BankTransaction
debitA = mkSameCurrencyBankTx (unsafeExternalTransactionId "a-1") extA (-100)

creditB :: BankTransaction
creditB = mkSameCurrencyBankTx (unsafeExternalTransactionId "b-1") extB 100

triple :: ExternalAccountId -> AccountId -> BankTransaction -> (ExternalAccountId, AccountId, BankTransaction)
triple = (,,)

spec :: Spec
spec = describe "pairInternalTransfers" $ do
  it "pairs a debit and credit of equal magnitude across two linked accounts" $ do
    let (pairs, leftovers) =
          pairInternalTransfers matcher [triple extA localA debitA, triple extB localB creditB]
    length pairs `shouldBe` 1
    leftovers `shouldBe` []
    case pairs of
      [t] -> do
        (debitLeg t).externalId `shouldBe` debitA.externalId
        (creditLeg t).externalId `shouldBe` creditB.externalId
      _ -> expectationFailure "expected exactly one pair"

  it "does not pair legs on the SAME external account" $ do
    let creditA = mkSameCurrencyBankTx (unsafeExternalTransactionId "a-2") extA 100
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extA localA creditA]
    pairs `shouldBe` []

  it "does not pair two different cards that map to the SAME local account (sibling cards)" $ do
    -- extA and extC are different cards, but both routed to localA (one account,
    -- multiple cards) — a within-account move, not a transfer.
    let extC = unsafeExternalAccountId "card-A2"
        creditC = mkSameCurrencyBankTx (unsafeExternalTransactionId "c-9") extC 100
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extC localA creditC]
    pairs `shouldBe` []

  it "does not pair different magnitudes" $ do
    let creditB' = mkSameCurrencyBankTx (unsafeExternalTransactionId "b-2") extB 99
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extB localB creditB']
    pairs `shouldBe` []

  it "does not pair different currencies" $ do
    let creditUsd = (mkSameCurrencyBankTx (unsafeExternalTransactionId "b-3") extB 100) {currencyCode = 840}
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extB localB creditUsd]
    pairs `shouldBe` []

  it "does not pair legs outside the time window" $ do
    let farCredit = creditB {time = addUTCTime 600 creditB.time}
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extB localB farCredit]
    pairs `shouldBe` []

  it "partitions: every input tx is either paired or a leftover, never both, never lost" $ do
    let solo = mkSameCurrencyBankTx (unsafeExternalTransactionId "c-1") extA (-7)
        input = [triple extA localA debitA, triple extB localB creditB, triple extA localA solo]
        (pairs, leftovers) = pairInternalTransfers matcher input
        pairedIds = concatMap (\t -> [(debitLeg t).externalId, (creditLeg t).externalId]) pairs
        leftoverIds = [tx.externalId | (_, _, tx) <- leftovers]
    L.sort (pairedIds <> leftoverIds) `shouldBe` L.sort [tx.externalId | (_, _, tx) <- input]
```

Add `import Infrastructure.Banking.Provider (…, TransferMatcher)` to the import list.

- [ ] **Step 4: Run to confirm failure**

Run: `cabal test all --test-option='--match' --test-option="/pairInternalTransfers/"`
Expected: FAIL (stub returns `([], …)`).

- [ ] **Step 5: Implement `pairInternalTransfers`**

Replace the stub body:

```haskell
pairInternalTransfers (TransferMatcher matches) entries =
  go (sortByStable entries) [] []
  where
    -- Deterministic order so collisions pair predictably: by time, then id.
    sortByStable = sortBy (comparing (\(_, _, tx) -> (tx.time, tx.externalId)))

    go [] pairs leftover = (reverse pairs, reverse leftover)
    go (e : rest) pairs leftover =
      case findPartner e rest of
        Just (partner, rest') -> go rest' (mkTransfer e partner : pairs) leftover
        Nothing -> go rest pairs (e : leftover)

    findPartner e = pick []
      where
        pick _ [] = Nothing
        pick seen (c : cs)
          | isPair e c = Just (c, reverse seen <> cs)
          | otherwise = pick (c : seen) cs

    -- Engine invariant: legs must resolve to DIFFERENT LOCAL accounts. Keyed on
    -- the local account, not the card/external id: one local account can own
    -- multiple cards (PrivatBank universal + additional card share a balance),
    -- so sibling-card legs map to the same local account and must not pair.
    -- Everything else is the provider's matcher.
    isPair (_, localX, a) (_, localY, b) = localX /= localY && matches a b

    mkTransfer (_, localX, txX) (_, localY, txY) =
      let ((dl, dtx), (cl, ctx)) =
            if txX.amount < 0
              then ((localX, txX), (localY, txY))
              else ((localY, txY), (localX, txX))
       in InternalTransfer
            { debitLocalAccount' = dl,
              creditLocalAccount' = cl,
              debitLeg' = dtx,
              creditLeg' = ctx
            }
```

Add `import Data.Ord (comparing)` (or `RIO.Ord`), following ormolu.

- [ ] **Step 6: Run the example spec**

Run: `cabal test all --test-option='--match' --test-option="/pairInternalTransfers/"`
Expected: PASS (all 6 examples).

- [ ] **Step 7: Write the QuickCheck property spec** (spec + CLAUDE.md require property tests as the primary coverage for pure invariants)

Create `test/Application/Services/BankImport/TransferPairingPropertySpec.hs`:

```haskell
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.BankImport.TransferPairingPropertySpec (spec) where

import Application.Services.BankImport.TransferPairing
  ( creditLeg,
    creditLocalAccount,
    debitLeg,
    debitLocalAccount,
    pairInternalTransfers,
  )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Core.Types (AccountId, ExternalTransactionId, unsafeExternalTransactionId)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
import RIO
import qualified RIO.List as L
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Helpers (mockAccountIdN)

matcher :: TransferMatcher
matcher = defaultTransferMatcher defaultTransferPairingWindow

-- A generated leg: a small set of external accounts, small amounts, and a time
-- jittered within a window a few multiples of the pairing window wide, so both
-- matches and non-matches occur.
genLeg :: Gen (ExternalAccountId, AccountId, BankTransaction)
genLeg = do
  accIx <- choose (1, 3) :: Gen Int
  eid <- unsafeExternalTransactionId . T.pack . show <$> choose (1, 1000000 :: Int)
  amt <- elements [-100, -50, 50, 100] :: Gen Rational
  ccy <- elements [980, 840]
  secs <- choose (1700000000, 1700002000) :: Gen Integer
  let extAcc = unsafeExternalAccountId (T.pack ("card-" <> show accIx))
      localAcc = mockAccountIdN (fromIntegral accIx)
      tx =
        (mkSameCurrencyBankTx eid extAcc amt)
          { currencyCode = ccy,
            time = posixSecondsToUTCTime (fromIntegral secs)
          }
  pure (extAcc, localAcc, tx)

ids :: [(ExternalAccountId, AccountId, BankTransaction)] -> [ExternalTransactionId]
ids xs = [tx.externalId | (_, _, tx) <- xs]

spec :: Spec
spec = describe "pairInternalTransfers properties" $ do
  prop "partitions input: paired legs ∪ leftovers = input (no loss, no duplication)" $
    forAll (listOf genLeg) $ \input ->
      let (pairs, leftovers) = pairInternalTransfers matcher input
          pairedIds = concatMap (\t -> [(debitLeg t).externalId, (creditLeg t).externalId]) pairs
       in L.sort (pairedIds <> ids leftovers) === L.sort (ids input)

  prop "each transaction is consumed at most once" $
    forAll (listOf genLeg) $ \input ->
      let (pairs, _) = pairInternalTransfers matcher input
          pairedIds = concatMap (\t -> [(debitLeg t).externalId, (creditLeg t).externalId]) pairs
       in L.nub pairedIds === pairedIds

  prop "every pair is a valid transfer (diff LOCAL account, opposite sign, equal magnitude, same currency)" $
    forAll (listOf genLeg) $ \input ->
      let (pairs, _) = pairInternalTransfers matcher input
       in all validPair pairs
  where
    validPair t =
      let d = debitLeg t
          c = creditLeg t
       in debitLocalAccount t /= creditLocalAccount t
            && d.currencyCode == c.currencyCode
            && d.amount < 0
            && c.amount > 0
            && abs d.amount == abs c.amount
```

Add `import Infrastructure.Banking.Provider (…, TransferMatcher)`.

- [ ] **Step 8: Run the property spec**

Run: `cabal test all --test-option='--match' --test-option="/pairInternalTransfers properties/"`
Expected: PASS (all three properties).

- [ ] **Step 9: Format, lint, commit**

```bash
just format && just lint
git add src/Application/Services/BankImport/TransferPairing.hs test/Application/Services/BankImport/ package.yaml backend.cabal
git commit -m "feat(banking): pure internal-transfer pairing engine"
```

---

## Task 3: `ImportInfo` carries a NonEmpty of external ids

**Files:**
- Modify: `src/Domain/Core/Types.hs:1388-1417`
- Modify: `src/Application/ReadModels/BankImportReadModel.hs:118-124`
- Modify: `src/Application/Services/BankImportService.hs` (income/expense write site, `~744-749`)
- Modify (test call sites that construct/inspect `ImportInfo` — the `-fci` build in Step 5 surfaces the full set; known ones):
  - `test/Application/Services/BankImportServiceSpec.hs` (two sites, `~887`, `~911`)
  - `test/Integration/TransferWorkflowSpec.hs:852`
  - `test/Integration/CrossKindAmendmentIntegrationSpec.hs:125`
  - `test/Application/ProcessManagers/TransactionPostingManagerSpec.hs:128`
  - `test/Domain/Transaction/CommandHandlerSpec.hs:186,194` — **note `:194` uses the accessor** (`importInfoExternalTransactionId <$> …`); its result type becomes `NonEmpty`, so adjust the assertion (e.g. compare against `id :| []`), not just rename the field.
  - `test/Domain/Transaction/EventsSpec.hs:64`
  - `test/Domain/Transaction/CommandHandlerPropertySpec.hs:104`

- [ ] **Step 1: Write a failing dedup fan-out test**

In `test/Application/Services/BankImportServiceSpec.hs`, add a unit test asserting that an `ImportInfo` carrying two external ids records BOTH in the dedup table. Follow the existing in-memory-store pattern (`createTestAppEnvWithProcessManager`, `runDb`, `isImported`). (Completed by Task 4; here just add it and let it fail against the new type.)

```haskell
a <- runAppM env $ runDb (isImported legOneId)
b <- runAppM env $ runDb (isImported legTwoId)
(a, b) `shouldBe` (True, True)
```

- [ ] **Step 2: Change the `ImportInfo` type**

In `src/Domain/Core/Types.hs`:

```haskell
data ImportInfo = ImportInfo
  { externalTransactionIds :: NonEmpty ExternalTransactionId,
    mcc :: Maybe MCC
  }
  deriving (Show, Eq, Generic)
```

Update the Haddock ("one or more external ids; a normal import carries one, a detected internal transfer carries both legs'"). Replace the accessor:

```haskell
importInfoExternalTransactionIds :: ImportInfo -> NonEmpty ExternalTransactionId
importInfoExternalTransactionIds ImportInfo {externalTransactionIds = e} = e
```

Update the export list (`importInfoExternalTransactionId` → `importInfoExternalTransactionIds`). Keep `importInfoMcc` unchanged.

- [ ] **Step 3: Fan out the dedup read model**

In `src/Application/ReadModels/BankImportReadModel.hs`:

```haskell
          case (importInfoExternalTransactionIds <$> evt.importInfo, mkTransactionIdSafe streamUuid) of
            (Just extIds, Just txId) ->
              forM_ extIds $ \extId ->
                void $ insertUnique (ImportedTransactionEntity extId txId)
            _ -> pure ()
```

Update the accessor import.

- [ ] **Step 4: Fix the income/expense write site**

In `src/Application/Services/BankImportService.hs` `buildTransferCmd`:

```haskell
          importInfo =
            Just
              ImportInfo
                { externalTransactionIds = bankTx.externalId :| [],
                  mcc = bankTx.mcc
                },
```

Fix every other `ImportInfo{externalTransactionId = …}` construction/pattern the compiler flags (see the test list above).

- [ ] **Step 5: Build**

Run: `just build`
Expected: compiles.

- [ ] **Step 6: Run the existing import suite**

Run: `cabal test all --test-option='--match' --test-option="/BankImport/"`
Expected: PASS (the fan-out test may stay red until Task 4 — expected).

- [ ] **Step 7: Format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "refactor(banking): ImportInfo carries a NonEmpty of external ids for two-leg dedup"
```

---

## Task 4: Wire pairing into `importMany` + `importTransferPair`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (`importMany` signature + pre-pass, new `importTransferPair`)
- Modify: `test/Application/Services/BankImportServiceSpec.hs`

> `importMany`'s `classify` parameter is **replaced** by a leading `TransactionInterpretation` parameter (which bundles `classify` + `transferMatcher`); the per-tx worker `importTransaction` keeps its plain `classify` parameter unchanged. Existing `importMany` test call sites to update: `test/Application/Services/BankImportServiceSpec.hs:417, 426, 441` (plus the new cases below) — replace `mockClassify` with a `testInterp = TransactionInterpretation mockClassify (defaultTransferMatcher defaultTransferPairingWindow)` bound in the spec. `importTransaction` call sites keep `mockClassify`. The file handler + `importConnection` sites are updated in Task 5.

- [ ] **Step 1: Write the failing unit tests**

Add to `BankImportServiceSpec` (follow the existing `importMany` block: two accounts via `createAccount`, both in `accountLink`, and `testInterp = TransactionInterpretation mockClassify (defaultTransferMatcher defaultTransferPairingWindow)`). Cases:

1. **Two-leg transfer.** Batch = `[debit on A, credit on B]` (equal magnitude, same currency, same time). Expect: exactly one `TransactionId`; `Transfer`-typed (assert via `TransactionRM.getTransaction`); appears in **both** A's and B's `succeeded`; both external ids `isImported`.
2. **File / PrivatBank merged multi-account batch.** Frame as the file transport with the PrivatBank interpretation: `importMany privatBankInterpretation userId accountLink batch` (this is what `importStatementFileHandler` does with a merged statement). Model the real data as synthetic `BankTransaction`s: card `…1111` self-labeled `На свою картку *2222 −20000` and card `…2222` self-labeled `Зі своєї картки *1111 +20000` (1 s apart), with `accountLink` mapping `…1111 → A`, `…2222 → B`, and a **sibling card `…3333 → B`** (same local account as `…2222`). Expect: (a) exactly one `Transfer` A→B for the labeled pair; (b) a within-account `…2222`↔`…3333` equal-amount opposite-sign decoy pair is **not** collapsed (different cards, same local account B). Proves provider/transport-neutrality and the many-cards-per-account invariant without a real CSV.
3. **Partial dedup fall-through.** Pre-seed A's leg as already imported. Import `[debit A, credit B]`. Expect: A's leg `Skipped AlreadyImported`; B's leg imported as **income** (not dropped, not a transfer).
4. **Single leg unchanged.** Batch = `[credit on B]`. Expect: income as before.

- [ ] **Step 2: Run to confirm failure**

Run: `cabal test all --test-option='--match' --test-option="/importMany/"`
Expected: FAIL.

- [ ] **Step 3: Restructure `importMany`**

```haskell
importMany ::
  TransactionInterpretation ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  [BankTransaction] ->
  AppM ImportResult
importMany interpretation userId accountLink txns = do
  let classify = interpretation.classify
      routed =
        [ (tx.externalAccountId, localAccId, tx)
        | tx <- txns,
          Just localAccId <- [lookup tx.externalAccountId accountLink]
        ]
      unmatched = [tx.externalAccountId | tx <- txns, isNothing (lookup tx.externalAccountId accountLink)]
      (pairs, leftovers) = pairInternalTransfers interpretation.transferMatcher routed
  pairEntries <- concat <$> forM pairs (importTransferPair classify userId accountLink)
  leftoverEntries <- forM leftovers $ \(extAccId, localAccId, tx) -> do
    outcome <- importTransaction classify userId accountLink tx
    pure (extAccId, localAccId, outcome)
  pure
    ImportResult
      { accounts = groupAccountResults (pairEntries <> leftoverEntries),
        unresolved = nubOrd (map unExternalAccountId unmatched)
      }
```

- [ ] **Step 4: Implement `importTransferPair`**

```haskell
-- | Import one detected internal transfer. If both legs are new, post a single
-- 'Transfer' between the two local accounts (attributed to BOTH accounts). If
-- either leg is already imported, do NOT form a transfer — route each leg
-- through the normal income/expense path so a genuinely-new partner leg is
-- never dropped.
importTransferPair ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  InternalTransfer ->
  AppM [(ExternalAccountId, AccountId, ImportOutcome)]
importTransferPair classify userId accountLink transfer = do
  let dLeg = debitLeg transfer
      cLeg = creditLeg transfer
      dLocal = debitLocalAccount transfer
      cLocal = creditLocalAccount transfer
  dImported <- runDb (isImported dLeg.externalId)
  cImported <- runDb (isImported cLeg.externalId)
  if dImported || cImported
    then do
      dOut <- importTransaction classify userId accountLink dLeg
      cOut <- importTransaction classify userId accountLink cLeg
      pure [(dLeg.externalAccountId, dLocal, dOut), (cLeg.externalAccountId, cLocal, cOut)]
    else do
      outcome <- postInternalTransfer userId dLocal cLocal dLeg cLeg
      pure [(dLeg.externalAccountId, dLocal, outcome), (cLeg.externalAccountId, cLocal, outcome)]
```

Then `postInternalTransfer`: convert the leg currency (`currencyFromNumericCode dLeg.currencyCode`), build `Money` from the magnitude, load both local accounts and guard that both currencies match the leg currency (reuse the `CurrencyMismatch` skip semantics from `commitImport`), build the `InitiateTransactionPosting`:

```haskell
        InitiateTransactionPosting
          { sourceAccountId = dLocal,
            targetAccountId = cLocal,
            sourceAmount = money,
            targetAmount = money,       -- same-currency transfer
            exchangeRate = Nothing,
            description = dLeg.description,
            initiatedBy = userId,
            at = dLeg.time,
            transactionType = Transfer,
            importInfo =
              Just ImportInfo
                { externalTransactionIds = dLeg.externalId :| [cLeg.externalId],
                  mcc = Nothing
                },
            labels = Set.empty,
            contactId = Nothing,
            relation = Nothing
          }
```

Call `TransactionService.initiateTransaction`; map `Right (txId, _)` → `Imported txId`, `Left err` → `Failed err`, currency mismatch → `Skipped (CurrencyMismatch …)`. Add the `TransferPairing` import.

- [ ] **Step 5: Run the tests**

Run: `cabal test all --test-option='--match' --test-option="/importMany/"`
Expected: PASS (all four cases + the Task-3 fan-out dedup test).

- [ ] **Step 6: Service sweep**

Run: `cabal test all --test-option='--match' --test-option="/BankImport/"`
Expected: PASS.

- [ ] **Step 7: Format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "feat(banking): detect internal transfers at import time"
```

---

## Task 5: End-to-end wiring — `importConnection` restructure + capability threading

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (`importConnection` signature + fetch-all)
- Modify: `src/Application/Services/ConfigurationService.hs` (`getConnectionProvider` `~678`, `getConnectionFileImport` `~713`; the module imports `Infrastructure.Banking.Provider` **selectively** at lines 168-175 — add `TransactionInterpretation` to that list). **Tuple arity is unchanged** — the first element changes from `desc.classify` (a function) to `desc.interpretation` (a record), so callers keep their 2-tuple patterns.
- Modify: `src/Web/API/BankingAPI.hs` (both handlers + `externalAccountsHandler` — same 2-tuple shape, first element now the interpretation)
- Modify: `test/Application/Services/ConfigurationServiceSpec.hs:382` — `Right (_classify, cap) -> …` becomes `Right (_interp, cap) -> …` (rename only; arity unchanged, so no pattern-arity break). Other matches in that spec are `Right _`/`Left …` and are unaffected; `getConnectionProvider` has no test callers.
- Modify: `test/Integration/BankImportWorkflowSpec.hs`

- [ ] **Step 1: Write the failing integration test**

In `BankImportWorkflowSpec`, add a case: a mock provider whose `fetchStatements` returns, for account A, a debit leg, and for account B the matching credit leg (equal magnitude, same currency, within window). Link both accounts. After `importConnection interp pull userId accountLink from to`, assert:
- exactly one `Transfer` transaction exists (query the transaction read model);
- account A balance decreased by the amount, account B increased by it (no External double-count);
- `ImportResult.accounts` still has one row per link entry.

(The existing calls in this spec — currently `importConnection mockClassify pull …` — become `importConnection interp pull …` with `interp = TransactionInterpretation mockClassify (defaultTransferMatcher defaultTransferPairingWindow)`.)

- [ ] **Step 2: Run to confirm failure**

Run: `cabal test all --test-option='--match' --test-option="/BankImportWorkflow/"`
Expected: FAIL (each account imported in its own scoped batch → two txns).

- [ ] **Step 3: Restructure `importConnection`**

Replace the `classify` parameter with a `TransactionInterpretation` parameter. Change `processAccount` to only **fetch** (returning `Either err (extAcc, local, [tx])`), collect across all link entries, then run ONE `importMany interpretation userId accountLink (concat allTxns)` over the full link. Re-group into per-link-entry `AccountImportResult`:
- start from the combined `ImportResult.accounts`;
- for each link entry with no row (empty/failed fetch), synthesize a zero row (as the current `fetchSucceeded` `[]` branch does);
- fold each fetch failure's `err` into that entry's `failed`.

Preserve the Haddock contract (one row per link entry; `unresolved` stays `[]`). Keep the per-account fetch-failure logging.

- [ ] **Step 4: Thread the matcher through the resolvers**

In `src/Application/Services/ConfigurationService.hs`:
- `getConnectionProvider` (`~678`): return `(desc.interpretation, mkPull cred)` — change the first tuple element's type from the classifier function to `TransactionInterpretation`.
- `getConnectionFileImport` (`~713`): return `(desc.interpretation, cap)` — same first-element type change.

The resolver type signatures now name `TransactionInterpretation` — add it to the **selective** `Infrastructure.Banking.Provider` import list (lines 168-175); it is not currently imported.

- [ ] **Step 5: Thread through the handlers**

In `src/Web/API/BankingAPI.hs` (all 2-tuple shapes, unchanged arity — only the first bound value's type changes):
- `importConnectionHandler` (`~352`): destructure `(interpretation, pull)`; call `BankImportService.importConnection interpretation pull userId accountLink request.from request.to` (`~374`).
- `importStatementFileHandler` (`~421`): destructure `(interpretation, cap)`; call `BankImportService.importMany interpretation userId accountLink goods` (`~459`).
- `externalAccountsHandler` (`~503`): currently binds `(_classify, pull)`; rename to `(_interpretation, pull)`.

- [ ] **Step 6: Build + run the integration test**

Run: `just build && cabal test all --test-option='--match' --test-option="/BankImportWorkflow/"`
Expected: builds; integration test PASSES.

- [ ] **Step 7: Format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "refactor(banking): fetch-all import + thread TransactionInterpretation through pull & file paths"
```

---

## Task 6: Full verification

- [ ] **Step 1: Clean rebuild with the CI flag** (warm `.o` cache can mask `-Werror`)

Run: `just rebuild`
Expected: builds clean, no warnings-as-errors.

- [ ] **Step 2: Full test suite**

Run: `just test`
Expected: all pass. (A manually-created `eventium_test` Postgres DB is required for the full integration suite; ~28 failures without it are environmental, not regressions. A one-off `Cabal-7125`/`-j` flake is spurious — re-run.)

- [ ] **Step 3: Confirm deferred / non-goal behaviour by test**

Verify a cross-currency two-account batch (UAH debit + USD credit) produces income/expense, NOT a transfer (covered in `TransferPairingSpec`/`BankImportServiceSpec`; add if missing). Confirm the file/PrivatBank multi-account case (Task 4, case 2) is green — this is the PrivatBank end-to-end proof.

- [ ] **Step 4: Update the spec status**

Set the spec frontmatter `status: draft` → `status: completed`.

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "chore(banking): mark internal-transfer-detection spec completed"
```

- [ ] **Step 6: Request code review** — REQUIRED SUB-SKILL: superpowers:requesting-code-review, then open a PR titled `fix(banking): detect internal transfers between linked accounts at import time`.
