# Bank-Provider Scoping by Country (p13n P2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Annotate each bank provider with its country coverage and a per-user "in my country" flag so the connect/import UI can curate the provider list by where the user banks — a soft default, never a hard gate.

**Architecture:** Add a `ProviderCoverage` sum to the compiled-in `BankProviderDescriptor`; tag the three UA providers. Add a pure `providerInCountry` predicate. The `GET …/banking/providers` handler loads the caller's stored `country` (from P1) once and annotates every provider DTO with `countries` + `inUserCountry` — it returns the *full* enabled registry annotated (annotate, not filter). No country gate exists anywhere on connect/import; the existing `providerEnabled` + registry-membership checks remain the only gates.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude, `NoImplicitPrelude`), Servant, Hspec/QuickCheck, hpack (`package.yaml` → `backend.cabal`), `just`/cabal, ormolu, hlint. `-Werror` via the `ci` flag (`-fci`).

**Spec:** `docs/specs/2026-08-18-p13n-provider-scoping-design.md`

**Ground rules for the implementer:**
- Run `nix develop` first so GHC/cabal/ormolu/hlint/just are on `PATH`.
- Build/test with the `-fci` flag to catch `-Werror` (adding a record field triggers `-Wincomplete-record-updates`/`-Wmissing-fields` on any un-updated construction site). Use `cabal build all -fci` and `cabal test backend-test -fci`. A **cold** `just rebuild` is the only definitive `-Werror` check (the warm `.o` cache can mask regressions).
- `just test` runs `cabal test all`, which pulls eventium's own suites needing an absent `eventium_test` DB — use **`cabal test backend-test -fci`** for this app's suite.
- Run `just format` (ormolu) and `just lint` (hlint) before each commit; no hlint suppressions.
- After editing `package.yaml`, run `hpack` before cabal sees new modules. (This plan does **not** edit `package.yaml`.)

---

## File Structure

**Modify:**
- `src/Infrastructure/Banking/Provider.hs` — add `ProviderCoverage`, the `coverage` field on `BankProviderDescriptor`, and pure helpers `providerInCountry` / `coverageCountries`; export them.
- `src/Infrastructure/Banking/Monobank.hs` — tag descriptor `RegionalCoverage {UA}`.
- `src/Infrastructure/Banking/PrivatBank.hs` — tag descriptor `RegionalCoverage {UA}`.
- `src/Infrastructure/Banking/PrivatBankBusiness.hs` — tag descriptor `RegionalCoverage {UA}`.
- `src/Web/API/ConfigurationAPI.hs` — add `countries` + `inUserCountry` to `BankProviderDTO`; give `toBankProviderDTO` a `Maybe Country` argument; rework `listProvidersHandler` to load the caller's country once and annotate.

**Test:**
- `test/Infrastructure/Banking/ProviderSpec.hs` — unit truth-table for `providerInCountry` + `coverageCountries`.
- `test/Web/API/ConfigurationBankingAPISpec.hs` — integration: the endpoint reflects the caller's stored country.

**No changes:** `package.yaml`/CPP (compile-time provider flags stay as-is per spec), `app/Main.hs` (wires via `BankProviders.buildRegistry`), stored events / upcasters (`accountingSchemaRegistry` untouched).

---

## Task 1: `ProviderCoverage` + pure helpers

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs`
- Test: `test/Infrastructure/Banking/ProviderSpec.hs`

Add the type and helpers **without** the record field yet, so the pure predicate can be test-driven in isolation before the field forces a multi-site edit.

- [ ] **Step 1: Write the failing test**

In `test/Infrastructure/Banking/ProviderSpec.hs`, first add `{-# LANGUAGE OverloadedStrings #-}` at the top of the file (it currently has only `NoImplicitPrelude`; `OverloadedStrings` is **not** a global default, and the `unsafeCountry "UA"` string literals below need `Text`). Then add a `describe` block (imports: `Infrastructure.Banking.Provider (ProviderCoverage (..), providerInCountry, coverageCountries)` — this file uses an open whole-module `Infrastructure.Banking.Provider` import, so once exported these are already in scope; plus `Domain.Localization.Country (unsafeCountry)` and `qualified Data.Set as Set`):

```haskell
describe "providerInCountry" $ do
  let ua = unsafeCountry "UA"
      pl = unsafeCountry "PL"
      us = unsafeCountry "US"
      regionalUA = RegionalCoverage (Set.singleton ua)
      regionalUAPL = RegionalCoverage (Set.fromList [ua, pl])

  it "global coverage is in-country for any set country" $
    providerInCountry (Just us) GlobalCoverage `shouldBe` True

  it "global coverage is in-country when country is unset" $
    providerInCountry Nothing GlobalCoverage `shouldBe` True

  it "regional matches a member country" $
    providerInCountry (Just ua) regionalUA `shouldBe` True

  it "regional excludes a non-member country" $
    providerInCountry (Just us) regionalUA `shouldBe` False

  it "regional shows everything when country is unset" $
    providerInCountry Nothing regionalUA `shouldBe` True

  it "multi-country regional matches every member" $ do
    providerInCountry (Just ua) regionalUAPL `shouldBe` True
    providerInCountry (Just pl) regionalUAPL `shouldBe` True

  it "multi-country regional excludes a non-member" $
    providerInCountry (Just us) regionalUAPL `shouldBe` False

describe "coverageCountries" $ do
  it "global projects to the empty list" $
    coverageCountries GlobalCoverage `shouldBe` []

  it "regional projects to sorted ISO codes" $
    coverageCountries (RegionalCoverage (Set.fromList [unsafeCountry "UA", unsafeCountry "PL"]))
      `shouldBe` ["PL", "UA"]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test backend-test -fci --test-option='--match' --test-option='/providerInCountry/'`
Expected: FAIL to **compile** — `ProviderCoverage` / `providerInCountry` / `coverageCountries` not in scope.

- [ ] **Step 3: Add the type + helpers**

In `src/Infrastructure/Banking/Provider.hs`:

Add to the module export list (near `BankProviderDescriptor (..)`):
```haskell
    ProviderCoverage (..),
    providerInCountry,
    coverageCountries,
```

Add imports (the file already imports `qualified Data.Map.Strict as Map`; add):
```haskell
import qualified Data.Set as Set
import Data.Set (Set)
import Domain.Localization.Country (Country, unCountry)
```
Extend the `RIO` import list with `Foldable (toList)` and `map`, `sort` as needed — or add `import Data.List (sort)` and use `RIO.toList`. (Match the module's existing explicit-import style; if the explicit `RIO (...)` list is used, add `Maybe (..)`, `Bool (..)` are already present — add `map`.)

Add the type + helpers (place near `BankProviderDescriptor`):
```haskell
-- | A provider's country coverage. 'GlobalCoverage' is country-agnostic (shown
-- to everyone); 'RegionalCoverage' serves exactly the given countries. An
-- explicit sum (rather than a bare 'Set Country' with empty = global) so a
-- provider that forgets to declare coverage is a compile error, not a silent
-- everyone-sees-it default.
data ProviderCoverage
  = GlobalCoverage
  | RegionalCoverage (Set Country)
  deriving (Show, Eq)

-- | Is a provider with this coverage in the given user's country? A soft
-- curation predicate, not a gate. 'GlobalCoverage' is always in-country; a
-- 'RegionalCoverage' matches when the user's country is a member; an unset
-- country ('Nothing') shows everything (nothing to curate against).
providerInCountry :: Maybe Country -> ProviderCoverage -> Bool
providerInCountry _ GlobalCoverage = True
providerInCountry mUserCty (RegionalCoverage cs) =
  maybe True (`Set.member` cs) mUserCty

-- | Project coverage to sorted ISO alpha-2 codes for the wire DTO. 'GlobalCoverage'
-- is the empty list (no restriction).
coverageCountries :: ProviderCoverage -> [Text]
coverageCountries GlobalCoverage = []
coverageCountries (RegionalCoverage cs) = sort (map unCountry (Set.toList cs))
```
(Add `import Data.List (sort)` if `sort` is not already available; `Set.toList` is already ascending, but `sort` on the projected `Text` keeps determinism explicit.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cabal test backend-test -fci --test-option='--match' --test-option='/providerInCountry/'`
Expected: PASS (both `providerInCountry` and `coverageCountries` groups green).

- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Infrastructure/Banking/Provider.hs test/Infrastructure/Banking/ProviderSpec.hs
git commit -m "feat(banking): ProviderCoverage type + providerInCountry predicate (tracker#47)"
```

---

## Task 2: Add `coverage` field + tag the three UA providers

Adding the record field forces every descriptor construction site to set it (else `-Werror`). This is one atomic build-green change across four files.

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs` (add field)
- Modify: `src/Infrastructure/Banking/Monobank.hs`
- Modify: `src/Infrastructure/Banking/PrivatBank.hs`
- Modify: `src/Infrastructure/Banking/PrivatBankBusiness.hs`
- Test: `test/Infrastructure/Banking/ProvidersSpec.hs` (assert the tags)

- [ ] **Step 1: Write the failing test**

In `test/Infrastructure/Banking/ProvidersSpec.hs` (or `RegistrySpec.hs` if it already builds the registry — follow whichever already constructs the provider list), add:

```haskell
describe "provider coverage tags" $ do
  let ua = RegionalCoverage (Set.singleton (unsafeCountry "UA"))
  it "monobank is UA-regional" $
    coverage Monobank.descriptorFromConfigTestFixture `shouldBe` ua   -- see note
  it "privatbank is UA-regional" $
    coverage PrivatBank.descriptor `shouldBe` ua
  it "privatbank-business is UA-regional" $
    coverage PrivatBankBusiness.descriptor `shouldBe` ua
```

Note: Monobank's descriptor is built via `descriptorFromConfig cfg manager`. `ProvidersSpec.hs` already provides the reusable fixture — obtain the monobank descriptor with `Monobank.descriptorFromConfig (bankingConfigWith True KM.empty) unusedManager` (both `bankingConfigWith` and `unusedManager` are defined in that spec). If you place these assertions in a file without those fixtures, either import them from the Testkit/spec helper or assert only the two pure descriptors (`PrivatBank.descriptor`, `PrivatBankBusiness.descriptor`) here and cover monobank's tag via the registry integration in Task 3. Add imports `Domain.Localization.Country (unsafeCountry)` and `qualified Data.Set as Set`; `ProviderCoverage (..)` and `coverage` come in via the existing open `Infrastructure.Banking.Provider` import once exported. Ensure `{-# LANGUAGE OverloadedStrings #-}` is present (it already is in `ProvidersSpec.hs`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test backend-test -fci --test-option='--match' --test-option='/provider coverage tags/'`
Expected: FAIL to compile — `coverage` not a field of `BankProviderDescriptor`.

- [ ] **Step 3: Add the field**

In `src/Infrastructure/Banking/Provider.hs`, add to the `BankProviderDescriptor` record (after `displayName`):
```haskell
    coverage :: !ProviderCoverage,
```

- [ ] **Step 4: Tag each provider**

In each provider module, add `coverage = ...` to the `BankProviderDescriptor { … }` literal. Each module already imports `Infrastructure.Banking.Provider` openly, so `ProviderCoverage (..)` is in scope once exported; add only `Domain.Localization.Country (unsafeCountry)` and `qualified Data.Set as Set` to each. (All three modules already have `OverloadedStrings`, so `unsafeCountry "UA"` compiles.)

- `src/Infrastructure/Banking/Monobank.hs` (in `descriptor`, after `displayName = "Monobank",`):
  ```haskell
      coverage = RegionalCoverage (Set.singleton (unsafeCountry "UA")),
  ```
- `src/Infrastructure/Banking/PrivatBank.hs` (after `displayName = "PrivatBank",`):
  ```haskell
      coverage = RegionalCoverage (Set.singleton (unsafeCountry "UA")),
  ```
- `src/Infrastructure/Banking/PrivatBankBusiness.hs` (after `displayName = "PrivatBank (Business)",`):
  ```haskell
      coverage = RegionalCoverage (Set.singleton (unsafeCountry "UA")),
  ```

- [ ] **Step 5: Build (catch every un-updated site) + run test**

Run: `cabal build all -fci`
Expected: compiles clean (no `-Wmissing-fields`). If any other descriptor construction site exists it will error here — set its `coverage` too.

Run: `cabal test backend-test -fci --test-option='--match' --test-option='/provider coverage tags/'`
Expected: PASS.

- [ ] **Step 6: Format, lint, commit**

```bash
just format && just lint
git add src/Infrastructure/Banking/Provider.hs src/Infrastructure/Banking/Monobank.hs src/Infrastructure/Banking/PrivatBank.hs src/Infrastructure/Banking/PrivatBankBusiness.hs test/Infrastructure/Banking/ProvidersSpec.hs
git commit -m "feat(banking): tag monobank + PrivatBank providers as UA-regional (tracker#47)"
```

---

## Task 3: Annotate `BankProviderDTO` + rework the handler

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs`
- Test: `test/Web/API/ConfigurationBankingAPISpec.hs`

- [ ] **Step 1: Write the failing test**

In `test/Web/API/ConfigurationBankingAPISpec.hs`, follow the existing patterns in that file for registering a user, obtaining an auth token, and issuing requests (reuse the Testkit helpers already used there; do **not** hand-roll new setup). Add integration cases against `GET /api/users/me/configuration/banking/providers`:

```haskell
describe "GET banking/providers country annotation" $ do
  it "a UA user sees UA providers as inUserCountry=true" $ do
    -- register user; PUT /api/users/me/configuration/country {"country":"UA"}
    -- GET .../banking/providers
    -- every returned provider has inUserCountry == True and countries == ["UA"]

  it "a US user sees UA providers as inUserCountry=false (still listed)" $ do
    -- PUT country US; GET providers
    -- all three providers still present; each inUserCountry == False; countries == ["UA"]

  it "a user with no country set sees everything as inUserCountry=true" $ do
    -- fresh user, no PUT country; GET providers
    -- each inUserCountry == True
```

Assert on the parsed JSON: presence of the `countries` array and the `inUserCountry` boolean, and the count of providers is unchanged across all three cases (annotate, not filter). Match the JSON-assertion style already used in this spec file (e.g. `hspec-wai-json` / decoding to `[BankProviderDTO]`).

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test backend-test -fci --test-option='--match' --test-option='/country annotation/'`
Expected: FAIL to compile (`BankProviderDTO` has no `countries`/`inUserCountry`) or FAIL assertions.

- [ ] **Step 3: Extend the DTO**

In `src/Web/API/ConfigurationAPI.hs`, add to `BankProviderDTO` (after `supportsFile :: Bool`):
```haskell
    countries :: [Text],
    inUserCountry :: Bool
```
Add the `Country` type to the existing import:
```haskell
import Domain.Localization.Country (Country, mkCountry, supportedCountries, unCountry)
```
(the file imports `Infrastructure.Banking.Provider` as an **open whole-module import** — there is no explicit list to edit; once `coverage`, `coverageCountries`, `providerInCountry`, and `ProviderCoverage (..)` are exported from that module they are automatically in scope here.)

- [ ] **Step 4: Give `toBankProviderDTO` the user's country**

Replace the current `toBankProviderDTO`:
```haskell
toBankProviderDTO :: Maybe Country -> BankProviderDescriptor -> BankProviderDTO
toBankProviderDTO userCountry d =
  BankProviderDTO
    { id = unBankProviderId d.providerId,
      displayName = d.displayName,
      supportsPull = providerSupportsPull d,
      supportsFile = providerSupportsFile d,
      countries = coverageCountries d.coverage,
      inUserCountry = providerInCountry userCountry d.coverage
    }
```

- [ ] **Step 5: Rework the handler**

Replace `listProvidersHandler` so it loads the caller's country once (surfacing the `Left` via `throwDomainError`, mirroring `loadConnection`):
```haskell
listProvidersHandler :: AuthenticatedUser -> AppM [BankProviderDTO]
listProvidersHandler user = do
  reg <- view bankProviderRegistryL
  configResult <- ConfigService.getConfigurationForUser user.userId
  case configResult of
    Left err -> throwDomainError err
    Right configData ->
      pure $ map (toBankProviderDTO configData.country) (Map.elems reg)
```
(Confirm the field name for the user id on `AuthenticatedUser` — match the sibling handler at `ConfigurationAPI.hs:744` which uses `user.userId`. Confirm `ConfigurationData` exposes `country :: Maybe Country` — it does, per `Application.ReadModels.Configuration`.)

- [ ] **Step 6: Run the endpoint test + full suite**

Run: `cabal test backend-test -fci --test-option='--match' --test-option='/country annotation/'`
Expected: PASS.

Run: `cabal test backend-test -fci`
Expected: whole app suite green (catches any other `toBankProviderDTO` call site that now needs the country argument).

- [ ] **Step 7: Format, lint, commit**

```bash
just format && just lint
git add src/Web/API/ConfigurationAPI.hs test/Web/API/ConfigurationBankingAPISpec.hs
git commit -m "feat(web): annotate provider list with country coverage + inUserCountry (tracker#47)"
```

---

## Task 4: Final verification

- [ ] **Step 1: Cold rebuild (definitive `-Werror` check)**

Run: `just rebuild`
Expected: clean build, no warnings-as-errors. (The warm `.o` cache can mask `-Werror`; only a cold build is definitive.)

- [ ] **Step 2: Full app test suite**

Run: `cabal test backend-test -fci --test-show-details=direct`
Expected: all green, 0 failures.

- [ ] **Step 3: Lint clean**

Run: `just lint`
Expected: no hints.

- [ ] **Step 4: Confirm no stored-event / migration drift**

Verify (by inspection) that no event type, `accountingSchemaRegistry`, or `test/fixtures/events/*.json` was touched — this change is DTO/descriptor-only and requires no upcaster or DB recreate.

- [ ] **Step 5 (informational): note the downstream web work**

The web repo (`../monorepo`) consumes the new `countries` / `inUserCountry` fields: default-show `inUserCountry` providers, reveal the rest behind a "show providers from other countries" affordance. Out of scope for this backend plan; flag it in the PR description.
