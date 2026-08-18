# Country + Language Signal Foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add server-persisted per-user `country` (ISO 3166-1 alpha-2) and `language` (`en`/`uk`) signals to the Configuration aggregate, with a country→regional preset (US/EU/UA) that sets language + currencies on selection.

**Architecture:** New `Domain.Localization` value-type namespace (`Country`, `Language`, `CountryPreset`), two new Configuration events/commands, an upcast-on-read migration re-activating `accountingSchemaRegistry`, additive read-model columns, and Web endpoints mirroring the base-currency pattern. Country change applies the preset in two legs: an atomic Configuration event bundle (leg 1) and a service-orchestrated base-currency change that also updates the External account (leg 2).

**Tech Stack:** GHC 9.10, RIO (NoImplicitPrelude), Servant, Persistent/PostgreSQL, eventium 0.6.0 (local at `/Users/oleksandrsy/Projects/Self/eventium/`), Hspec + QuickCheck, LiquidHaskell.

**Spec:** `docs/specs/2026-08-11-p13n-country-language-signal-design.md`. Read it first.

**Conventions (must follow):**
- After any `package.yaml`/module-list change or before a definitive build: `just build` (runs hpack + `cabal build -fci`). Warm-cache `-Werror` can be masked — use `just rebuild` for a definitive check (see CLAUDE.md).
- Format + lint before every commit: `just format && just lint`.
- New test files MUST end in `Spec.hs` (hspec-discover) and live under `test/` mirroring the module path.
- Run a single spec: `cabal test all --test-option='--match' --test-option="/Domain.Localization/"`.
- Full unit suite needs a running PG (`just docker-up`) and a manually-created `eventium_test` DB (see CLAUDE.md); pure-domain specs run without it.
- Never export data constructors/field selectors; use smart constructors + accessors.
- Commit after each task (frequent commits).

---

## File Structure

**New files:**
- `src/Domain/Localization/Language.hs` — `Language = En | Uk`, `languageCode`, `parseLanguage`, pinned JSON.
- `src/Domain/Localization/Country.hs` — `Country` newtype, `mkCountry`/`unCountry`/`unsafeCountry`, `supportedCountries`, `euroAreaCountries`, JSON.
- `src/Domain/Localization/Preset.hs` — `CountryPreset`, `presetFor`.
- `test/Domain/Localization/LanguageSpec.hs`, `CountrySpec.hs`, `PresetSpec.hs` — pure-domain specs.
- `test/fixtures/events/configuration-created-v1.json` — legacy stored-event fixture.

**Modified files:**
- `src/Domain/Configuration/Events.hs` — augment `ConfigurationCreated`; add `LanguageChanged`, `CountryChanged`.
- `src/Domain/Configuration/Commands.hs` — add `ChangeLanguage`, `ChangeCountry`.
- `src/Domain/Configuration/CommandHandler.hs` — new handler equations; seed defaults in `CreateConfiguration`.
- `src/Domain/Configuration/Projection.hs` — no-op aggregate equations for the two new events.
- `src/Infrastructure/Database/Orphans.hs` — `PersistField`/`PersistFieldSql` for `Country`, `Language`.
- `src/Infrastructure/Eventium/Schema.hs` — register the `ConfigurationCreated` v1→v2 upcaster.
- `test/Infrastructure/Eventium/SchemaSpec.hs` — legacy-decode + round-trip test.
- `src/Application/ReadModels/Configuration.hs` — entity columns, projection cases, `ConfigurationData`, `getConfiguration`.
- `src/Application/Services/ConfigurationService.hs` — `baseCurrencyEditable`, `changeLanguage`, `changeCountry`, clone propagation.
- `src/Web/API/ConfigurationAPI.hs` — response fields, request DTOs, routes, handlers, `localization-options` GET, delegate editability.
- `package.yaml` is NOT edited manually for new modules — hpack auto-discovers `src/**`; just run `just build` (which runs hpack). New test files are auto-discovered by hspec-discover.

**Note on `package.yaml`:** this repo uses hpack with directory globs, so new `src/` modules need no manual `package.yaml` edit — but you MUST run `just build` (which runs `hpack`) after adding a module so `backend.cabal` regenerates. If a new module is "hidden module" errored, that means hpack didn't run.

---

## Task 1: `Domain.Localization.Language`

**Files:**
- Create: `src/Domain/Localization/Language.hs`
- Test: `test/Domain/Localization/LanguageSpec.hs`

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Localization.LanguageSpec (spec) where

import Data.Aeson (decode, encode)
import Domain.Localization.Language (Language (..), languageCode, parseLanguage)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Language" $ do
  it "round-trips code <-> value" $ do
    parseLanguage (languageCode En) `shouldBe` Right En
    parseLanguage (languageCode Uk) `shouldBe` Right Uk

  it "parses lowercase ISO 639-1 codes, trimming and case-folding" $ do
    parseLanguage "en" `shouldBe` Right En
    parseLanguage "UK" `shouldBe` Right Uk
    parseLanguage "  uk " `shouldBe` Right Uk

  it "rejects unsupported codes" $ do
    parseLanguage "ua" `shouldSatisfy` isLeft   -- must be uk, not ua
    parseLanguage "fr" `shouldSatisfy` isLeft

  it "encodes JSON as the lowercase code (not the constructor name)" $ do
    encode En `shouldBe` "\"en\""
    encode Uk `shouldBe` "\"uk\""
    (decode "\"uk\"" :: Maybe Language) `shouldBe` Just Uk
    (decode "\"Uk\"" :: Maybe Language) `shouldBe` Nothing
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Language/"`
Expected: FAIL — module `Domain.Localization.Language` not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Language
-- Description : UI language signal (closed locale set).
--
-- A shared value type in the 'Domain.Localization' namespace (parallel to
-- 'Domain.Banking'), keyed off by both the personalization and localization
-- epics. Closed sum because every locale is a real code change (a new catalog).
--
-- JSON is pinned to the lowercase ISO 639-1 code ("en"/"uk") by a hand-written
-- single-shape instance, mirroring 'Domain.Core.Types.Currency'. NOT derived —
-- 'deriveJSON' would emit the constructor names ("En"/"Uk"), which is the wrong
-- wire contract and would break the ConfigurationCreated upcaster.
module Domain.Localization.Language
  ( Language (..),
    languageCode,
    parseLanguage,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import qualified Data.Text as T
import RIO

-- | Supported UI languages. 'En' is the default and fallback.
data Language = En | Uk
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- | The lowercase ISO 639-1 wire code. Note 'Uk' -> "uk" (not "ua").
languageCode :: Language -> Text
languageCode En = "en"
languageCode Uk = "uk"

-- | Parse a language from its ISO 639-1 code (case-insensitive, trimmed).
-- Mirrors 'Domain.Core.Types.parseCurrency' in returning 'Either Text'.
parseLanguage :: Text -> Either Text Language
parseLanguage raw = case T.toLower (T.strip raw) of
  "en" -> Right En
  "uk" -> Right Uk
  other -> Left ("Unsupported language: " <> other)

instance ToJSON Language where
  toJSON = toJSON . languageCode

instance FromJSON Language where
  parseJSON = withText "Language" $ \t ->
    case parseLanguage t of
      Right l -> pure l
      Left err -> fail (T.unpack err)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Language/"`
Expected: PASS (4 examples).

- [ ] **Step 5: Format, lint, build, commit**

```bash
just format && just lint && just build
git add src/Domain/Localization/Language.hs test/Domain/Localization/LanguageSpec.hs
git commit -m "feat(localization): Language value type (en/uk) with pinned lowercase JSON"
```

---

## Task 2: `Domain.Localization.Country`

**Files:**
- Create: `src/Domain/Localization/Country.hs`
- Test: `test/Domain/Localization/CountrySpec.hs`

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Localization.CountrySpec (spec) where

import Data.Aeson (decode, encode)
import qualified Data.Set as Set
import Domain.Localization.Country
  ( Country,
    euroAreaCountries,
    mkCountry,
    supportedCountries,
    unCountry,
    unsafeCountry,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Country" $ do
  it "accepts supported codes (US, UA, a euro-area member), normalizing case/space" $ do
    fmap unCountry (mkCountry "US") `shouldBe` Right "US"
    fmap unCountry (mkCountry "ua") `shouldBe` Right "UA"
    fmap unCountry (mkCountry " de ") `shouldBe` Right "DE"

  it "rejects malformed codes" $ do
    mkCountry "U" `shouldSatisfy` isLeft
    mkCountry "USA" `shouldSatisfy` isLeft
    mkCountry "1A" `shouldSatisfy` isLeft

  it "rejects well-formed but unsupported codes" $ do
    mkCountry "ZZ" `shouldSatisfy` isLeft
    mkCountry "JP" `shouldSatisfy` isLeft   -- valid ISO, not in launch set

  it "supported set is US + UA + euro-area" $ do
    supportedCountries `shouldBe` Set.insert "US" (Set.insert "UA" euroAreaCountries)

  it "round-trips JSON as the plain code" $ do
    encode (unsafeCountry "DE") `shouldBe` "\"DE\""
    fmap unCountry (decode "\"UA\"" :: Maybe Country) `shouldBe` Just "UA"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Country/"`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Country
-- Description : User country signal (ISO 3166-1 alpha-2, launch-scoped set).
--
-- A shared 'Domain.Localization' value type. Validated over ISO 3166-1 alpha-2,
-- but the *supported set* for launch is exactly the countries the 3 presets
-- cover (US, UA, euro-area) — we do not build the full ~249-entry ISO table yet.
-- No LiquidHaskell refinement, matching the 'Currency'/'EntryName' precedent;
-- validation is in the smart constructor + tests.
module Domain.Localization.Country
  ( Country,
    unCountry,
    mkCountry,
    unsafeCountry,
    supportedCountries,
    euroAreaCountries,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import qualified Data.Set as Set
import qualified Data.Text as T
import RIO

-- | An ISO 3166-1 alpha-2 country code from the supported set. Constructor is
-- not exported; use 'mkCountry' (validating) or 'unsafeCountry' (trusted).
newtype Country = Country {unCountry :: Text}
  deriving (Show, Eq, Ord, Generic)

-- | Extract the alpha-2 code.
unCountry :: Country -> Text
unCountry (Country t) = t

-- | Euro-area member states (currency preset EUR). Extended as coverage grows.
euroAreaCountries :: Set Text
euroAreaCountries =
  Set.fromList
    ["AT", "BE", "HR", "CY", "EE", "FI", "FR", "DE", "GR", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PT", "SK", "SI", "ES"]

-- | The launch supported/selectable set: US + UA + euro-area. This is also the
-- set the picker renders and 'localization-options' returns.
supportedCountries :: Set Text
supportedCountries = Set.insert "US" (Set.insert "UA" euroAreaCountries)

-- | Smart constructor: well-formed alpha-2 AND in the supported set. Returns
-- 'Either Text' to match 'parseCurrency' and plug into 'validateFieldCtx'.
mkCountry :: Text -> Either Text Country
mkCountry raw
  | not wellFormed = Left ("Malformed country code: " <> raw)
  | not (code `Set.member` supportedCountries) = Left ("Unsupported country: " <> code)
  | otherwise = Right (Country code)
  where
    code = T.toUpper (T.strip raw)
    wellFormed = T.length code == 2 && T.all (\ch -> ch >= 'A' && ch <= 'Z') code

-- | Reconstruct without validation. For trusted sources only (DB reads):
-- values were validated on write. Mirrors 'unsafeEntryName'.
unsafeCountry :: Text -> Country
unsafeCountry = Country

instance ToJSON Country where
  toJSON = toJSON . unCountry

-- | Lenient decode (trusted stored form), mirroring 'EntryName' — API input is
-- validated via 'mkCountry' at the boundary, not here.
instance FromJSON Country where
  parseJSON v = Country <$> parseJSON v
```

Note: the `newtype` field `unCountry` and the standalone `unCountry :: Country -> Text` share a name on purpose — this compiles *because* the project-wide `NoFieldSelectors` extension suppresses the field selector, leaving the standalone function as the sole `unCountry`. This is exactly the confirmed `EntryName` pattern (`src/Domain/Core/Types.hs:662-669`). Write it as shown above; do not rename the field or drop the standalone.

- [ ] **Step 4: Run test to verify it passes**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Country/"`
Expected: PASS.

- [ ] **Step 5: Format, lint, build, commit**

```bash
just format && just lint && just build
git add src/Domain/Localization/Country.hs test/Domain/Localization/CountrySpec.hs
git commit -m "feat(localization): Country value type + launch supported set (US/UA/euro-area)"
```

---

## Task 3: `Domain.Localization.Preset`

**Files:**
- Create: `src/Domain/Localization/Preset.hs`
- Test: `test/Domain/Localization/PresetSpec.hs`

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Localization.PresetSpec (spec) where

import Domain.Core.Types (Currency (..))
import Domain.Localization.Country (unsafeCountry)
import Domain.Localization.Language (Language (..))
import Domain.Localization.Preset (CountryPreset (..), presetFor)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Preset" $ do
  it "US -> English + USD" $
    presetFor (unsafeCountry "US") `shouldBe` CountryPreset En (Just USD) (Just USD)

  it "UA -> Ukrainian + UAH" $
    presetFor (unsafeCountry "UA") `shouldBe` CountryPreset Uk (Just UAH) (Just UAH)

  it "euro-area member -> English + EUR" $
    presetFor (unsafeCountry "DE") `shouldBe` CountryPreset En (Just EUR) (Just EUR)

  it "uncovered code -> English + no currency (fallback)" $
    presetFor (unsafeCountry "ZZ") `shouldBe` CountryPreset En Nothing Nothing
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Preset/"`
Expected: FAIL — module not found.

- [ ] **Step 3: Write minimal implementation**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Preset
-- Description : Country -> regional defaults (US / EU / UA profiles).
--
-- Pure country->defaults table. Three launch profiles; 'EU' is a profile the
-- euro-area codes all map to (each user's stored country stays their real ISO
-- code). 'presetFor' is total; the fallback (En, no currency) is only reachable
-- if the supported set is later widened ahead of this table.
module Domain.Localization.Preset
  ( CountryPreset (..),
    presetFor,
  )
where

import qualified Data.Set as Set
import Domain.Core.Types (Currency (..))
import Domain.Localization.Country (Country, euroAreaCountries, unCountry)
import Domain.Localization.Language (Language (..))
import RIO

-- | Regional defaults applied on country selection. Currencies are 'Maybe' so
-- an uncovered country can leave them untouched.
data CountryPreset = CountryPreset
  { language :: Language,
    baseCurrency :: Maybe Currency,
    defaultCurrency :: Maybe Currency
  }
  deriving (Show, Eq, Generic)

-- | Resolve the preset for a country.
presetFor :: Country -> CountryPreset
presetFor c = case unCountry c of
  "US" -> CountryPreset En (Just USD) (Just USD)
  "UA" -> CountryPreset Uk (Just UAH) (Just UAH)
  code
    | code `Set.member` euroAreaCountries -> CountryPreset En (Just EUR) (Just EUR)
    | otherwise -> CountryPreset En Nothing Nothing
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Preset/"`
Expected: PASS.

- [ ] **Step 5: Format, lint, build, commit**

```bash
just format && just lint && just build
git add src/Domain/Localization/Preset.hs test/Domain/Localization/PresetSpec.hs
git commit -m "feat(localization): CountryPreset table (US/EU/UA profiles)"
```

---

## Task 4: Persistent orphans for `Country` and `Language`

**Files:**
- Modify: `src/Infrastructure/Database/Orphans.hs` (add instances near the `Currency`/`Provider` instances at lines ~249-288)

- [ ] **Step 1: Add the instances**

Add the imports for the two types at the top import block, then append these instances (mirroring `Provider` for the text newtype and `StatusKind` for the code-token sum):

```haskell
import Domain.Localization.Country (Country, unCountry, unsafeCountry)
import Domain.Localization.Language (Language, languageCode, parseLanguage)
```

```haskell
-- | 'Country' wraps an alpha-2 'Text' code; stored as the bare code (no JSON
-- quotes), mirroring 'Provider'. Reads use 'unsafeCountry' (stored values were
-- validated on write).
instance PersistField Country where
  toPersistValue = toPersistValue . unCountry
  fromPersistValue v = unsafeCountry <$> fromPersistValue v

instance PersistFieldSql Country where
  sqlType _ = SqlString

-- | 'Language' stored as its lowercase code token, mirroring 'StatusKind'.
instance PersistField Language where
  toPersistValue = PersistText . languageCode
  fromPersistValue v = fromPersistValue v >>= parseLanguage

instance PersistFieldSql Language where
  sqlType _ = SqlString
```

- [ ] **Step 2: Build to verify it compiles**

Run: `just build`
Expected: builds clean (orphan warnings suppressed by the file's `-fno-warn-orphans`).

- [ ] **Step 3: Commit**

```bash
just format && just lint
git add src/Infrastructure/Database/Orphans.hs
git commit -m "feat(localization): PersistField instances for Country and Language"
```

---

## Task 5: Configuration events — augment `ConfigurationCreated`, add `LanguageChanged`/`CountryChanged`

**Files:**
- Modify: `src/Domain/Configuration/Events.hs`

- [ ] **Step 1: Add imports**

```haskell
import Domain.Localization.Country (Country)
import Domain.Localization.Language (Language)
```

- [ ] **Step 2: Augment `ConfigurationCreated`** (lines ~103-111) — add two fields:

```haskell
data ConfigurationCreated = ConfigurationCreated
  { baseCurrency :: Currency,
    defaultCurrency :: Currency,
    -- | UI language at creation. Defaults to 'En'.
    language :: Language,
    -- | User country, if known at creation. Defaults to 'Nothing'.
    country :: Maybe Country,
    createdBy :: CreatedBy
  }
  deriving (Show, Eq)
```

- [ ] **Step 3: Add the two new events** (after `DefaultCurrencyChanged`):

```haskell
-- | Event emitted when the UI language is changed.
newtype LanguageChanged = LanguageChanged
  { language :: Language
  }
  deriving (Show, Eq)

-- | Event emitted when the user country is changed.
newtype CountryChanged = CountryChanged
  { country :: Country
  }
  deriving (Show, Eq)
```

- [ ] **Step 4: Register in the TH list and exports**

- Add `LanguageChanged (..)` and `CountryChanged (..)` to the module export list (near line 27).
- Add `''LanguageChanged` and `''CountryChanged` to `configurationEvents` (line ~78).
- Add `deriveJSON defaultOptions ''LanguageChanged` and `''CountryChanged` (near line 300).

- [ ] **Step 5: Build**

Run: `just build`
Expected: FAILS to compile in `CommandHandler.hs`, `Projection.hs`, and `Application/ReadModels/Configuration.hs` because `ConfigurationCreated` now needs the new fields at construction/other sites. That is expected — the next tasks fix each site. To keep this task self-contained and green, do Steps 6-7 below in the SAME commit.

- [ ] **Step 6: Fix the aggregate command-handler + projection construction sites so the tree compiles**

In `src/Domain/Configuration/CommandHandler.hs`, the `CreateConfiguration` case (lines ~298-309) constructs `ConfigurationCreated` — add the defaults:

```haskell
      Right
        [ ConfigurationCreatedConfigurationEvent
            ConfigurationCreated
              { baseCurrency = baseCurrency,
                defaultCurrency = defaultCurrency,
                language = En,
                country = Nothing,
                createdBy = createdBy
              }
        ]
```
(add `import Domain.Localization.Language (Language (..))` for `En`.)

In `src/Domain/Configuration/Projection.hs`, the `ConfigurationCreated` case (lines ~255-261) uses `{..}` and does not reference the new fields — it still compiles unchanged.

- [ ] **Step 6b: Patch every explicit-field `ConfigurationCreated` construction site (REQUIRED — else `-Wmissing-fields`/`-Werror` breaks the test suite).** Adding fields breaks every site that builds `ConfigurationCreated` with named-field syntax (not `{..}`). Add `language = En, country = Nothing` to each (import `Domain.Localization.Language (Language (..))` where needed). The sites (verify with `grep -rn "ConfigurationCreated$\|ConfigurationCreated\b" test/ src/` and check each):
  - `test/Domain/Configuration/CommandHandlerSpec.hs` — ~22 sites (around lines 133, 145, 165, 193, 213, 233, 261, 290, 323, 356, 389, 421, 441, 470, 676, 724, 1360, 1423, 1591, 1687, 1709, 1776)
  - `test/Application/ReadModels/DataVersionIntegrationSpec.hs:237`
  - `test/Application/ReadModels/PersistentConfigurationReadModelSpec.hs:66`
  - `test/Domain/Configuration/ProjectionSpec.hs:154`
  - `test/Domain/Configuration/ConfigurationTreePropertySpec.hs:52`

  Tip: a project-wide `grep -rln "ConfigurationCreated" src test` then compile-driven iteration (`just build` surfaces each missing-fields error with its line) is the reliable way to catch all of them.

- [ ] **Step 7: Build to confirm the aggregate layer compiles** (read model fixed in Task 9)

Run: `just build`
Expected: the read model `Application/ReadModels/Configuration.hs` may still fail (its `ConfigurationCreatedEvent` insert). If so, that's fixed in Task 9; to keep commits green, MERGE Task 9's entity+projection edits into this build before committing, OR temporarily add the read-model construction in this task. **Recommended:** do Tasks 5, 7, 9's read-model-projection edits together if the build must stay green per-commit; otherwise commit Task 5 with a `[wip]` note. Prefer keeping green — see the combined build in Task 9.

- [ ] **Step 8: Commit**

```bash
just format && just lint
git add src/Domain/Configuration/Events.hs src/Domain/Configuration/CommandHandler.hs \
  test/Domain/Configuration/CommandHandlerSpec.hs \
  test/Application/ReadModels/DataVersionIntegrationSpec.hs \
  test/Application/ReadModels/PersistentConfigurationReadModelSpec.hs \
  test/Domain/Configuration/ProjectionSpec.hs \
  test/Domain/Configuration/ConfigurationTreePropertySpec.hs
git commit -m "feat(config): add language/country to ConfigurationCreated + LanguageChanged/CountryChanged events"
```

---

## Task 6: Configuration commands — `ChangeLanguage`, `ChangeCountry`

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs`

- [ ] **Step 1: Add imports + command records** (after `ChangeDefaultCurrency`):

```haskell
import Domain.Localization.Country (Country)
import Domain.Localization.Language (Language)
```

```haskell
-- | Command to change the UI language. Emits 'LanguageChanged'.
newtype ChangeLanguage = ChangeLanguage
  { language :: Language
  }
  deriving (Show, Eq)

-- | Command to change the user country. Emits (leg 1) 'CountryChanged' +
-- 'LanguageChanged' + optionally 'DefaultCurrencyChanged', from the pure
-- 'presetFor'. Base currency (leg 2) is applied separately in the service
-- because it also updates the External account.
newtype ChangeCountry = ChangeCountry
  { country :: Country
  }
  deriving (Show, Eq)
```

- [ ] **Step 2: Register in TH list + exports + JSON**

- Export `ChangeLanguage (..)`, `ChangeCountry (..)` (near line 20).
- Add `''ChangeLanguage`, `''ChangeCountry` to `configurationCommands` (line ~71).
- Add `deriveJSON defaultOptions ''ChangeLanguage` and `''ChangeCountry` (near line 344).

- [ ] **Step 3: Build**

Run: `just build`
Expected: FAILS — `handleConfigurationCommand` is now non-exhaustive over `ConfigurationCommand` (`-Wincomplete-patterns`/`-Werror`). Fixed in Task 7 (do together to stay green).

- [ ] **Step 4: Commit (with Task 7)** — see Task 7.

---

## Task 7: Command handler + aggregate projection equations

**Files:**
- Modify: `src/Domain/Configuration/CommandHandler.hs`
- Modify: `src/Domain/Configuration/Projection.hs`
- Test: `test/Domain/Configuration/CommandHandlerSpec.hs` (existing; add a `describe` block — check the exact filename with `ls test/Domain/Configuration/`)

- [ ] **Step 1: Write the failing test** (leg-1 handler behavior)

Append to the Configuration command-handler spec (use existing helpers/fixtures in that file for building a created `Configuration`; the pattern mirrors the existing `ChangeBaseCurrency` tests):

```haskell
  describe "ChangeLanguage" $ do
    it "emits a single LanguageChanged on a created config" $ do
      let config = createdConfig   -- reuse the spec's created-config fixture
      handleConfigurationCommand config (ChangeLanguageConfigurationCommand (ChangeLanguage Uk))
        `shouldBe` Right [LanguageChangedConfigurationEvent (LanguageChanged Uk)]

    it "rejects when not created" $
      handleConfigurationCommand emptyConfig (ChangeLanguageConfigurationCommand (ChangeLanguage Uk))
        `shouldBe` Left ConfigurationNotCreated

  describe "ChangeCountry (leg 1 bundle)" $ do
    it "UA emits Country + Language uk + DefaultCurrency UAH" $ do
      let config = createdConfig
      handleConfigurationCommand config (ChangeCountryConfigurationCommand (ChangeCountry (unsafeCountry "UA")))
        `shouldBe` Right
          [ CountryChangedConfigurationEvent (CountryChanged (unsafeCountry "UA")),
            LanguageChangedConfigurationEvent (LanguageChanged Uk),
            DefaultCurrencyChangedConfigurationEvent (DefaultCurrencyChanged UAH)
          ]

    it "a euro-area country emits Language en + DefaultCurrency EUR" $ do
      let config = createdConfig
      handleConfigurationCommand config (ChangeCountryConfigurationCommand (ChangeCountry (unsafeCountry "DE")))
        `shouldBe` Right
          [ CountryChangedConfigurationEvent (CountryChanged (unsafeCountry "DE")),
            LanguageChangedConfigurationEvent (LanguageChanged En),
            DefaultCurrencyChangedConfigurationEvent (DefaultCurrencyChanged EUR)
          ]
```
(imports: `Domain.Localization.Country (unsafeCountry)`, `Domain.Localization.Language (Language (..))`, `Domain.Core.Types (Currency (..))`.)

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/ChangeCountry/"`
Expected: FAIL (no handler equations).

- [ ] **Step 3: Add handler equations** in `CommandHandler.hs` (after the `ChangeDefaultCurrency` case, ~line 330). Add `import Domain.Localization.Preset (CountryPreset (..), presetFor)` and `Domain.Configuration.Events` already re-exports the events:

```haskell
-- Handle ChangeLanguage command
handleConfigurationCommand config (ChangeLanguageConfigurationCommand ChangeLanguage {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise = Right [LanguageChangedConfigurationEvent (LanguageChanged {language = language})]

-- Handle ChangeCountry command (leg 1: the atomic Configuration bundle).
-- Base currency is NOT emitted here — it spans the Account aggregate and is
-- applied by the service (leg 2).
handleConfigurationCommand config (ChangeCountryConfigurationCommand ChangeCountry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | otherwise =
      let preset = presetFor country
       in Right $
            [ CountryChangedConfigurationEvent (CountryChanged {country = country}),
              LanguageChangedConfigurationEvent (LanguageChanged {language = preset.language})
            ]
              ++ [ DefaultCurrencyChangedConfigurationEvent (DefaultCurrencyChanged {defaultCurrency = c})
                   | Just c <- [preset.defaultCurrency]
                 ]
```

- [ ] **Step 4: Add no-op aggregate projection equations** in `Projection.hs` (after the `DefaultCurrencyChanged` case, ~line 283). The aggregate `Configuration` record does not track language/country, so these are no-ops (they exist only for pattern exhaustiveness):

```haskell
handleConfigurationEvent config (LanguageChangedConfigurationEvent _) = config
handleConfigurationEvent config (CountryChangedConfigurationEvent _) = config
```

- [ ] **Step 5: Run tests + build**

Run: `cabal test all --test-option='--match' --test-option="/ChangeCountry/"` then `cabal test all --test-option='--match' --test-option="/ChangeLanguage/"`
Expected: PASS. Then `just build` — the aggregate layer compiles (read model handled in Task 9).

- [ ] **Step 6: Commit** (bundle Tasks 6 + 7)

```bash
just format && just lint
git add src/Domain/Configuration/Commands.hs src/Domain/Configuration/CommandHandler.hs src/Domain/Configuration/Projection.hs test/Domain/Configuration/CommandHandlerSpec.hs
git commit -m "feat(config): ChangeLanguage/ChangeCountry commands + handler (leg-1 preset bundle)"
```

---

## Task 8: Upcaster — `ConfigurationCreated` v1→v2

**Files:**
- Modify: `src/Infrastructure/Eventium/Schema.hs`
- Create: `test/fixtures/events/configuration-created-v1.json`
- Test: `test/Infrastructure/Eventium/SchemaSpec.hs`

- [ ] **Step 1: Write the legacy fixture** `test/fixtures/events/configuration-created-v1.json` — the pre-`language`/`country` shape (bare payload, no envelope; `contents` fields must match the *other* current `ConfigurationCreated` fields). Base/default currency use the current `Currency` JSON (`"USD"`); `createdBy` uses its current JSON. Confirm `createdBy`'s JSON shape by checking how `CreatedBy` serializes (grep `instance ToJSON CreatedBy` or a committed fixture); a `System` creator is simplest:

```json
{
  "tag": "ConfigurationCreated",
  "contents": {
    "baseCurrency": "USD",
    "defaultCurrency": "USD",
    "createdBy": {"tag": "System"}
  }
}
```
**Important:** verify the exact `createdBy` JSON by encoding one in GHCi or copying from an existing store row — the fixture must decode against the *current* `CreatedBy` `FromJSON`. Adjust the `createdBy` value to whatever the real shape is.

- [ ] **Step 2: Write the failing test** in `SchemaSpec.hs` (mirror the existing `ConfigurationCreated`-free cases; add imports `Domain.Configuration.Events (ConfigurationCreated (..))`, `Domain.Localization.Language (Language (..))`, `Domain.Core.Types (Currency (..), CreatedBy (..))`):

```haskell
  it "upcasts a v1 ConfigurationCreated (no language/country) to language=En, country=Nothing" $ do
    stored <- loadStoredEvent "test/fixtures/events/configuration-created-v1.json"
    case accountingEventCodec.decode stored of
      Nothing -> expectationFailure "v1 ConfigurationCreated failed to decode"
      Just event -> do
        case event of
          ConfigurationCreatedEvent cc -> do
            cc.language `shouldBe` En
            cc.country `shouldBe` Nothing
          _ -> expectationFailure "decoded to the wrong event constructor"
        -- round-trip stability at the current (v2) shape
        accountingEventCodec.decode (accountingEventCodec.encode event) `shouldBe` Just event
```

- [ ] **Step 3: Run to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/upcasts a v1 ConfigurationCreated/"`
Expected: FAIL — decode returns `Nothing` (missing `language` field, no upcaster yet).

- [ ] **Step 4: Register the upcaster** in `Schema.hs`. Update imports and the registry:

```haskell
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KeyMap
import Domain.Configuration.Events (ConfigurationCreated)
import Domain.Models (AccountingEvent)
import Eventium.Codec (Codec)
import Eventium.SchemaEvolution.Json (addFieldIfAbsent, atKey)
import Eventium.SchemaEvolution.Types (SchemaRegistry, emptyRegistry, registerUpcasters)
import Eventium.Store.Postgresql (JSONString, upcastingJsonStringCodec)
import Eventium.Store.Types (EventTypeName, eventTypeName)
import RIO
```

```haskell
-- | v1 -> v2: 'ConfigurationCreated' gained 'language' (default "en") and
-- 'country' (default null). Inject 'language:"en"' if absent; 'country' is a
-- 'Maybe' so an absent field already decodes as 'Nothing' (injected explicitly
-- for a self-describing v2 shape). Transforms under "contents" (the app's
-- {tag, contents} envelope).
configurationCreatedV1toV2 :: Value -> Value
configurationCreatedV1toV2 =
  atKey "contents" (addFieldIfAbsent "language" (String "en") . addFieldIfAbsent "country" Null)

accountingSchemaRegistry :: SchemaRegistry Value
accountingSchemaRegistry =
  registerUpcasters (eventTypeName @ConfigurationCreated) [configurationCreatedV1toV2] emptyRegistry
```
(`eventTypeName @ConfigurationCreated` requires `{-# LANGUAGE TypeApplications #-}` — add it. Update the module haddock: the registry is no longer empty.)

- [ ] **Step 5: Run test + build**

Run: `cabal test all --test-option='--match' --test-option="/upcasts a v1 ConfigurationCreated/"`
Expected: PASS. Also re-run the whole `SchemaSpec`: `cabal test all --test-option='--match' --test-option="/schema evolution/"` — all existing round-trip cases still green.

- [ ] **Step 6: Commit**

```bash
just format && just lint && just build
git add src/Infrastructure/Eventium/Schema.hs test/Infrastructure/Eventium/SchemaSpec.hs test/fixtures/events/configuration-created-v1.json
git commit -m "feat(config): ConfigurationCreated v1->v2 upcaster (re-activates accountingSchemaRegistry)"
```

---

## Task 9: Read model — columns, projection, `ConfigurationData`, builder

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs`
- Test: an existing Configuration read-model / integration spec (find with `ls test/Application/ReadModels/` and `grep -rl Configuration test/**/*Integration*`)

> This task makes the whole tree compile again (Task 5 augmented `ConfigurationCreated`, whose read-model insert lives here). If you kept commits green by bundling, this is where the read model catches up.

- [ ] **Step 1: Add columns to `ConfigurationEntity`** (the `configurations` block, lines 227-239). Insert after `defaultCurrency`:

```
    language Language default='en'
    country Country Maybe
```
(imports: `Domain.Localization.Country (Country)`, `Domain.Localization.Language (Language (..))`. The `default='en'` keeps the NOT NULL column additive on a populated table — see spec "Migration mechanics".)

- [ ] **Step 2: Update the projection** (`applyConfigurationEvent`, lines 328-346):

Augment the `ConfigurationCreatedEvent` insert (add two fields):

```haskell
          ConfigurationCreatedEvent evt ->
            void $
              insertUnique
                ConfigurationEntity
                  { configurationEntityConfigId = configId,
                    configurationEntityBaseCurrency = evt.baseCurrency,
                    configurationEntityDefaultCurrency = evt.defaultCurrency,
                    configurationEntityLanguage = evt.language,
                    configurationEntityCountry = evt.country,
                    configurationEntityDefaultIncomeCategory = Nothing,
                    configurationEntityDefaultExpenseCategory = Nothing,
                    configurationEntityDefaultAccount = Nothing,
                    configurationEntityDefaultSubtypeAccounts = DefaultSubtypeAccounts Map.empty,
                    configurationEntityBooksClosedThrough = Nothing,
                    configurationEntityCreatedBy = evt.createdBy,
                    configurationEntityVersion = ver
                  }
```

Add two new cases after `DefaultCurrencyChangedEvent` (line 346), mirroring it:

```haskell
          LanguageChangedEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityLanguage = evt.language, configurationEntityVersion = ver})
          CountryChangedEvent evt ->
            modifyConfig configId (\e -> e {configurationEntityCountry = Just evt.country, configurationEntityVersion = ver})
```
(add these event constructors to the `Domain.Configuration.Events` import list at lines 98-120.)

- [ ] **Step 3: Extend `ConfigurationData`** (lines 147-165) — add after `defaultCurrency`:

```haskell
    -- | UI language.
    language :: Language,
    -- | User country, if set.
    country :: Maybe Country,
```

- [ ] **Step 4: Extend `getConfiguration`** builder (lines 505-506) — add:

```haskell
              language = e.configurationEntityLanguage,
              country = e.configurationEntityCountry,
```

- [ ] **Step 5: Build**

Run: `just build`
Expected: whole tree compiles now.

- [ ] **Step 6: Write/extend a read-model test** — seed a `ConfigurationCreated` then a `LanguageChanged`/`CountryChanged` through the projection and assert `getConfiguration` reflects `language`/`country`. Reuse the existing Configuration read-model integration spec's harness (needs `eventium_test` DB + `just docker-up`). If a pure projection unit exists, prefer it.

Run: `cabal test all --test-option='--match' --test-option="/Configuration/"` (read-model portion)
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
just format && just lint
git add src/Application/ReadModels/Configuration.hs test/...
git commit -m "feat(config): read-model columns + projection for language/country"
```

---

## Task 10: Service — `baseCurrencyEditable`, `changeLanguage`, `changeCountry`, clone propagation

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs`
- Test: the existing Configuration service integration spec

- [ ] **Step 1: Add `baseCurrencyEditable` (Application-layer)** — the moved logic from `Web`'s `computeBaseCurrencyEditable`. Near the other service helpers:

```haskell
-- | Whether the user's base/reporting currency can still change: true when the
-- user has no External account, or that account has no transactions. This is the
-- Application-layer home of the rule the Web layer used to compute inline.
baseCurrencyEditable :: UserId -> AppM Bool
baseCurrencyEditable uid = do
  extResult <- runExceptT (getUserExternalAccountId uid)
  case extResult of
    Left _ -> pure True
    Right extAccId -> do
      mAccount <- runDb (getAccount extAccId)
      pure $ maybe True (not . (.hasTransactions)) mAccount
```
(ensure `getAccount` is imported from the account read model, as the Web module did; export `baseCurrencyEditable` from the service module.)

- [ ] **Step 2: Add `changeLanguage`** (mirror `changeDefaultCurrency`, lines 215-223):

```haskell
changeLanguage :: UserId -> Language -> AppM (Either DomainError ())
changeLanguage userId newLanguage = runExceptT $ do
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (ChangeLanguageConfigurationCommand ChangeLanguage {language = newLanguage})
```

- [ ] **Step 3: Add `changeCountry`** (leg 1 command + leg 2 base-currency reuse):

```haskell
changeCountry :: UserId -> Country -> AppM (Either DomainError ())
changeCountry userId newCountry = runExceptT $ do
  let preset = presetFor newCountry
  configId <- ExceptT (ensureClonedConfiguration userId)
  -- Leg 1: atomic Configuration bundle (country + language + default currency)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (ChangeCountryConfigurationCommand ChangeCountry {country = newCountry})
  -- Leg 2: base currency (also updates the External account) only if editable
  editable <- lift (baseCurrencyEditable userId)
  when editable $
    forM_ preset.baseCurrency $ \c ->
      ExceptT (changeBaseCurrency userId c)
```
(imports: `Domain.Localization.Country (Country)`, `Domain.Localization.Language (Language)`, `Domain.Localization.Preset (CountryPreset (..), presetFor)`, and the two new commands from `Domain.Configuration.Commands`.)

- [ ] **Step 4: Propagate language/country in `cloneConfiguration`** (lines 943-947) — extend the `CreateConfiguration` command with the source config's values:

```haskell
    ( CreateConfigurationConfigurationCommand
        CreateConfiguration
          { baseCurrency = configData.baseCurrency,
            defaultCurrency = configData.defaultCurrency,
            createdBy = ClonedBy userId sourceConfigId
          }
    )
```
**Problem:** `CreateConfiguration` has no language/country fields (it only feeds `ConfigurationCreated` defaults). Two options — pick one and note it in the commit:
- **(a) Preferred:** after the `CreateConfiguration` call in the clone, issue `ChangeLanguage`/`ChangeCountry` for the source values so the clone matches (only when they differ from the `En`/`Nothing` defaults). Insert alongside `copyDefaults` (line ~955):

```haskell
  when (configData.language /= En) $
    runConfigurationCmd translateConfigurationError newConfigUuidVal
      (ChangeLanguageConfigurationCommand ChangeLanguage {language = configData.language})
  forM_ configData.country $ \ctry ->
    runConfigurationCmd translateConfigurationError newConfigUuidVal
      (ChangeCountryConfigurationCommand ChangeCountry {country = ctry})
```
  ⚠ Note: issuing `ChangeCountry` here re-applies the preset (language + default currency) on the clone. If that is undesirable for a clone (which already copied currencies), prefer emitting `CountryChanged` directly — but the aggregate command is `ChangeCountry`. Simpler: add `language`/`country` fields to `CreateConfiguration` (option b).
- **(b) Alternative:** add `language :: Language` and `country :: Maybe Country` to the `CreateConfiguration` command + `ConfigurationCreated` handler case, defaulting `En`/`Nothing` at the registration/`seedFresh` call sites (lines 816-822) and copying the source values in the clone. This is cleaner (no preset re-application) — **recommend (b)**. It touches `seedFresh` (line 816) and the registration path that builds `CreateConfiguration`.

**Decision:** implement **(b)** — thread `language`/`country` through `CreateConfiguration`. Steps:
- Add `language :: Language`, `country :: Maybe Country` to the `CreateConfiguration` command record (`Domain/Configuration/Commands.hs`) and to the handler's `CreateConfiguration` case so it passes them into `ConfigurationCreated` (**replacing** the hardcoded `En`/`Nothing` added in Task 5 Step 6 — this is the intended supersession; Task 5's version compiled correctly in isolation).
- `seedFresh` (`ConfigurationService.hs:816-822`): set `language = En, country = Nothing`.
- `cloneConfiguration` (`ConfigurationService.hs:943-947`): set `language = configData.language, country = configData.country` (no `ChangeCountry` re-application, so the clone's copied currencies are preserved).
- **Patch every explicit-field `CreateConfiguration` construction site** (same `-Wmissing-fields` hazard). Add `language = En, country = Nothing` to: `test/Domain/Configuration/CommandHandlerSpec.hs:509, 531, 554` (verify with `grep -rn "CreateConfiguration" test/ src/` — cover any others surfaced by `just build`).

- [ ] **Step 5: Write the failing service test** (leg-2 behavior): `changeCountry userId (unsafeCountry "UA")` on a fresh user makes both the External account currency and config base currency `UAH`; on a user whose External account has transactions, base currency is unchanged while language/default-currency still apply. Use the existing service integration harness.

- [ ] **Step 6: Run + build**

Run: `cabal test all --test-option='--match' --test-option="/changeCountry/"`
Expected: PASS. `just build` clean.

- [ ] **Step 7: Commit**

```bash
just format && just lint
git add src/Application/Services/ConfigurationService.hs src/Domain/Configuration/Commands.hs src/Domain/Configuration/CommandHandler.hs test/...
git commit -m "feat(config): changeCountry (2-leg preset) + changeLanguage + editability helper + clone propagation"
```

---

## Task 11: Web API — response fields, endpoints, `localization-options`, delegate editability

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs`
- Test: the Web/API Configuration spec (MSW-style handler tests / servant tests — find with `grep -rl ConfigurationAPI test/`)

- [ ] **Step 1: Extend `ConfigurationResponse`** (lines 402-426) — add:

```haskell
    language :: Text,
    country :: Maybe Text,
```
and in `toConfigurationResponse` (lines 1052-1053):

```haskell
          language = languageCode configData.language,
          country = unCountry <$> configData.country,
```
(imports `Domain.Localization.Language (languageCode)`, `Domain.Localization.Country (unCountry)`.)

- [ ] **Step 2: Add request DTOs** (near `ChangeCurrencyRequest`, line 476):

```haskell
newtype ChangeLanguageRequest = ChangeLanguageRequest {language :: Text}
  deriving (Show, Eq, Generic)
instance ToJSON ChangeLanguageRequest
instance FromJSON ChangeLanguageRequest

newtype ChangeCountryRequest = ChangeCountryRequest {country :: Text}
  deriving (Show, Eq, Generic)
instance ToJSON ChangeCountryRequest
instance FromJSON ChangeCountryRequest
```
And a response DTO for the options endpoint:

```haskell
data LocalizationOptionsResponse = LocalizationOptionsResponse
  { languages :: [Text],   -- ISO 639-1 codes: ["en","uk"]
    countries :: [Text]    -- supported alpha-2 codes, sorted
  }
  deriving (Show, Eq, Generic)
instance ToJSON LocalizationOptionsResponse
instance FromJSON LocalizationOptionsResponse
```

- [ ] **Step 3: Add routes to `type ConfigurationAPI`** — insert two PUTs + one GET at a stable position (e.g. right after the `default-currency` PUT). Mirror the base-currency route shape (lines 119-127). Example for language:

```haskell
    :<|> AuthProtect "jwt"
      :> "api" :> "users" :> "me" :> "configuration" :> "language"
      :> ReqBody '[JSON] ChangeLanguageRequest
      :> Put '[JSON] NoContent
    :<|> AuthProtect "jwt"
      :> "api" :> "users" :> "me" :> "configuration" :> "country"
      :> ReqBody '[JSON] ChangeCountryRequest
      :> Put '[JSON] NoContent
    :<|> AuthProtect "jwt"
      :> "api" :> "users" :> "me" :> "configuration" :> "localization-options"
      :> Get '[JSON] LocalizationOptionsResponse
```

- [ ] **Step 4: Add handlers**:

```haskell
changeLanguageHandler :: AuthenticatedUser -> ChangeLanguageRequest -> AppM NoContent
changeLanguageHandler user req = do
  lang <- validateFieldCtx "language" req.language $ parseLanguage req.language
  result <- ConfigService.changeLanguage user.userId lang
  either throwDomainError (const (pure NoContent)) result

changeCountryHandler :: AuthenticatedUser -> ChangeCountryRequest -> AppM NoContent
changeCountryHandler user req = do
  ctry <- validateFieldCtx "country" req.country $ mkCountry req.country
  result <- ConfigService.changeCountry user.userId ctry
  either throwDomainError (const (pure NoContent)) result

localizationOptionsHandler :: AuthenticatedUser -> AppM LocalizationOptionsResponse
localizationOptionsHandler _ =
  pure
    LocalizationOptionsResponse
      { languages = [languageCode En, languageCode Uk],
        countries = Set.toList supportedCountries
      }
```
(imports: `Domain.Localization.Language (Language (..), languageCode, parseLanguage)`, `Domain.Localization.Country (mkCountry, supportedCountries)`, `qualified Data.Set as Set`.)

- [ ] **Step 5: Delegate `computeBaseCurrencyEditable` to the service** — replace its body (lines 1079-1086) with a call to the new Application helper, removing the duplicated logic:

```haskell
computeBaseCurrencyEditable :: UserId -> AppM Bool
computeBaseCurrencyEditable = ConfigService.baseCurrencyEditable
```
(remove now-unused imports if the getAccount/getUserExternalAccountId usages are gone from this module; `just lint`/`-Wunused` will flag them.)

- [ ] **Step 6: Wire handlers into `configurationServer`** (lines 649-666) at the SAME positions as the routes in Step 3:

```haskell
    :<|> changeLanguageHandler
    :<|> changeCountryHandler
    :<|> localizationOptionsHandler
```

- [ ] **Step 7: Write failing API tests** — `PUT /configuration/language` with `{"language":"uk"}` persists and shows in `GET /configuration`; invalid `{"language":"fr"}` → 400/validation error; `PUT /configuration/country` with `{"country":"UA"}` applies the preset; `GET /configuration/localization-options` returns `languages=["en","uk"]` and the supported country set. Reuse the existing ConfigurationAPI test harness.

- [ ] **Step 8: Run + build**

Run: `cabal test all --test-option='--match' --test-option="/ConfigurationAPI/"`
Expected: PASS. `just build` clean.

- [ ] **Step 9: Commit**

```bash
just format && just lint
git add src/Web/API/ConfigurationAPI.hs test/...
git commit -m "feat(config): language/country endpoints + localization-options + ConfigurationResponse fields"
```

---

## Task 12: Full verification + docs

- [ ] **Step 1: Definitive build + full suite**

```bash
just docker-up          # ensure PG; ensure eventium_test DB exists (see CLAUDE.md)
just rebuild            # clean + -fci build (definitive -Werror check)
just test               # full suite
```
Expected: green (modulo the documented environmental `eventium_test` failures if the DB is absent).

- [ ] **Step 2: Update `docs/architecture.md`** — note the new `Domain.Localization` namespace and the re-activated `accountingSchemaRegistry` (first live upcaster).

- [ ] **Step 3: Update `docs/deployment.md`** — note the additive `configurations.language`/`country` columns (safe via `default='en'`); no event-store recreate.

- [ ] **Step 4: Commit docs + open PR**

```bash
git add docs/architecture.md docs/deployment.md
git commit -m "docs: record Domain.Localization namespace + country/language read-model columns"
git push -u origin feat/p13n-country-language-signal
gh pr create --repo homeaccounting/backend --base master --title "feat(config): user country + language signal foundation (tracker#48/#56/#47/#35)" --body "Implements docs/specs/2026-08-11-p13n-country-language-signal-design.md. Shared signal foundation for the personalization (#48) and localization (#56) epics."
```

---

## Sequencing note

Tasks 1-4 are independent pure/infra units (commit each green). Tasks 5-9 form a **compile-coupled cluster** — augmenting `ConfigurationCreated` breaks the read-model insert until Task 9. To keep every commit green, either (i) implement Tasks 5→7→9 as one working set before committing, or (ii) accept a transient red between them and only push once Task 9 lands. Prefer (i). Tasks 10-11 depend on 5-9. Task 12 is the finish gate.
