# Backend Localization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render all backend-generated Telegram output in the user's persisted UI language, and localize untouched default categories to the user's current locale — built on a shared, area-agnostic localization foundation.

**Architecture:** A pure localization foundation in `Domain.Localization` (the existing `Language` value type + a new `resolve` fallback combinator). Two *areas* hang off it: the Telegram bot output (a closed record-per-language catalog in the Telegram layer) and the default category names (an open key→text catalog in Domain). Language is a per-message value threaded explicitly (never an ambient effect). Slice B rewrites stored default-category names via the existing `RenameDictionaryEntry` command ("materialized re-translation"), guarded by an ID anchor so user content is never touched. No stored-event-shape change, no upcaster, no DB recreate.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude, `NoImplicitPrelude`), Hspec + QuickCheck, `-Werror` via the `ci`/`-fci` cabal flag. Build: `just build`; test: `just test`; a single spec: `cabal test all --test-option='--match' --test-option="/PATTERN/"`.

**Spec:** `docs/specs/2026-08-20-backend-localization-design.md`

---

## Conventions for every task

- **TDD, Red→Green→Refactor.** Write the failing test first, run it, see it fail for the *right* reason, then implement.
- **Verify each type before use.** `type CategoryId = DictionaryEntryId` (`Domain/Core/Types.hs:651`) — they are the same type. `Language` derives `Enum, Bounded` (`Domain/Localization/Language.hs:30`), so `[minBound .. maxBound]` enumerates locales.
- **Extensions gotcha:** the project uses `NoFieldSelectors` + `DuplicateRecordFields` + `OverloadedRecordDot`. Dot-access (`x.field`) needs the record type to be unambiguous at that point; when a field name is shared across records, destructure via the constructor instead (see `changeCountry` at `ConfigurationService.hs:271`). Never export data constructors or field selectors — use smart constructors/accessors.
- **After each task:** `just build` must be clean under `-fci` (a warm `.o` cache can mask `-Werror`; if in doubt `just rebuild`). Commit at the end of each task.
- Do **not** put issue/ticket numbers in test `describe`/`it` titles — behaviour names only.

---

## File Structure

**Create:**
- `src/Domain/Localization/Catalog.hs` — pure `resolve` fallback primitive (foundation).
- `src/Domain/Localization/CategoryCatalog.hs` — `uk` default-category name overrides + `localizedCategoryName` (Slice B area).
- `src/Telegram/I18n.hs` — `TelegramStrings` record-per-language catalog, `en`/`uk` values, `telegramStrings` dispatch (Slice A area).
- `test/Domain/Localization/CatalogSpec.hs`
- `test/Domain/Localization/CategoryCatalogSpec.hs`
- `test/Telegram/I18nSpec.hs`

**Modify:**
- `src/Application/Services/ConfigurationService.hs` — add `relocalizeDefaultDictionaries`; call it from `changeCountry` and `changeLanguage`.
- `src/Domain/Configuration/Defaults.hs` — export a `defaultCategoryNamesById :: Map CategoryId Text` (canonical-name-by-id) helper (or expose the lists so the service can build it).
- `src/Telegram/Formatting.hs` — thread `Language` into renderers; pull labels from `telegramStrings`.
- `src/Telegram/Keyboards.hs` — thread `Language` into static-label keyboards.
- `src/Telegram/Types.hs` — `botCommands :: Language -> [(Text, Text)]`.
- `src/Telegram/Api.hs` — register `setMyCommands` per supported locale.
- `src/Telegram/Commands.hs` — resolve + thread `Language`; replace `sendMsg` string literals with `telegramStrings` lookups.
- `src/Telegram/Bot.hs` — call per-locale command registration.
- `package.yaml` → run `hpack` (new modules are picked up automatically by the `src`/`test` globs, but run `just build` which runs hpack first).
- `test/Application/Services/ConfigurationServiceIntegrationSpec.hs` — Slice B integration coverage.
- `test/Telegram/FormattingSpec.hs` — per-language renderer coverage.

---

## Phase 0 — Foundation

### Task 1: `Domain.Localization.Catalog` — the pure fallback primitive

**Files:**
- Create: `src/Domain/Localization/Catalog.hs`
- Test: `test/Domain/Localization/CatalogSpec.hs`

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Domain.Localization.CatalogSpec (spec) where

import Domain.Localization.Catalog (resolve)
import Domain.Localization.Language (Language (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Catalog.resolve" $ do
  let base k = "base:" <> k
      overrides Uk "hit" = Just "uk-hit"
      overrides _ _ = Nothing
      r = resolve overrides base

  it "returns the locale override when present" $
    r Uk "hit" `shouldBe` "uk-hit"

  it "falls back to the English base when the locale has no override" $
    r Uk "miss" `shouldBe` "base:miss"

  it "always uses the base for English (identity locale)" $
    r En "hit" `shouldBe` "base:hit"
```

- [ ] **Step 2: Run it and confirm it fails to compile** (`resolve` undefined)

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Catalog/"`
Expected: build failure — `Variable not in scope: resolve`.

- [ ] **Step 3: Implement the module**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Catalog
-- Description : Pure, area-agnostic localization primitive.
--
-- The single reusable rule every open (key->text) localization area shares:
-- resolve a key in the target language, falling back to a total English base
-- that can never fail. Closed record-per-language catalogs (e.g. 'Telegram.I18n')
-- do not need this — the record is total per locale — but this keeps the
-- fallback logic in one place for data-driven areas (e.g.
-- 'Domain.Localization.CategoryCatalog'). Pure: no IO, no resource loading.
module Domain.Localization.Catalog
  ( resolve,
  )
where

import Domain.Localization.Language (Language)
import RIO

-- | Resolve a key with English fallback.
--
-- @resolve overrides base lang k@ tries the per-locale @overrides@ table; on a
-- miss it uses the total English @base@. English needs no override entry — the
-- base is the English text by construction.
resolve ::
  -- | Per-locale overrides (uk, ...); 'En' may return 'Nothing' throughout.
  (Language -> k -> Maybe Text) ->
  -- | Total English base — never fails.
  (k -> Text) ->
  Language ->
  k ->
  Text
resolve overrides base lang k = fromMaybe (base k) (overrides lang k)
```

- [ ] **Step 4: Run the test — expect PASS**

Run: `cabal test all --test-option='--match' --test-option="/Domain.Localization.Catalog/"`

- [ ] **Step 5: Commit**

```bash
git add src/Domain/Localization/Catalog.hs test/Domain/Localization/CatalogSpec.hs
git commit -m "feat(localization): pure resolve fallback primitive (localization foundation)"
```

---

## Phase 1 — Slice B: localized default categories

### Task 2: `Domain.Localization.CategoryCatalog` — uk category names

**Files:**
- Create: `src/Domain/Localization/CategoryCatalog.hs`
- Test: `test/Domain/Localization/CategoryCatalogSpec.hs`

The canonical English names are the exact strings in `Domain/Configuration/Defaults.hs`
(e.g. `"Groceries"`, `"Dining"`, `"Transport"`, `"Taxes & Fees"`, `"Beauty & Personal Care"`,
income `"Salary"`, `"Freelance"`, …, and the group names `"Food"`, `"Housing"`,
`"Wellness"`, `"Goods"`, `"Leisure"`, `"Earned"`, `"Passive"`). There are **36
distinct** canonical names (`"Other"` appears in both the income and expense lists
with the identical string, so one map entry covers both); every one needs a `uk`
translation. The completeness test below (`untranslated == []`) is the gate.

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Domain.Localization.CategoryCatalogSpec (spec) where

import qualified Data.Text as T
import Domain.Configuration.Defaults (defaultExpenseCategories, defaultIncomeCategories, DefaultEntry (entryName))
import Domain.Localization.CategoryCatalog (localizedCategoryName)
import Domain.Localization.Language (Language (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "localizedCategoryName" $ do
  it "returns the canonical English name unchanged for En" $
    localizedCategoryName En "Groceries" `shouldBe` "Groceries"

  it "translates a known canonical name for Uk" $
    localizedCategoryName Uk "Groceries" `shouldBe` "Продукти"

  it "falls back to the input for an unknown key" $
    localizedCategoryName Uk "Nonexistent Category" `shouldBe` "Nonexistent Category"

  it "has a Uk translation for every default category (completeness)" $ do
    let canon = map entryName (defaultIncomeCategories <> defaultExpenseCategories)
        untranslated = [n | n <- canon, localizedCategoryName Uk n == n]
    untranslated `shouldBe` []
```

> Note: `entryName` is exported from `Domain.Configuration.Defaults` via
> `DefaultEntry (entryName, ...)` — confirm the export list includes it (it does,
> `Defaults.hs:27`).

- [ ] **Step 2: Run it — expect FAIL** (module missing, then completeness red until all translated).

- [ ] **Step 3: Implement the module**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.CategoryCatalog
-- Description : Localized display names for the default category tree (an area
--               on the localization foundation).
--
-- App-authored reference data: the 'Domain.Configuration.Defaults' canonical
-- English names, translated per locale. Keyed by the canonical English name (the
-- same string that derives each default's deterministic id), so this never
-- touches ids. Pure; open key->text shape resolved via 'Domain.Localization.Catalog.resolve'.
module Domain.Localization.CategoryCatalog
  ( localizedCategoryName,
  )
where

import qualified Data.Map.Strict as Map
import Domain.Localization.Catalog (resolve)
import Domain.Localization.Language (Language (..))
import RIO

-- | Localized display name for a default category, keyed by its canonical
-- English name. 'En' and any unknown key return the canonical name unchanged.
localizedCategoryName :: Language -> Text -> Text
localizedCategoryName = resolve overrides id
  where
    overrides :: Language -> Text -> Maybe Text
    overrides Uk k = Map.lookup k ukNames
    overrides En _ = Nothing

-- | Ukrainian names for every default category (canonical English -> uk).
-- MUST cover every entry in 'defaultIncomeCategories'/'defaultExpenseCategories'.
-- Best-effort wording; native-speaker review is a follow-up (mirrors web PR #94).
ukNames :: Map Text Text
ukNames =
  Map.fromList
    [ -- Expense groups
      ("Food", "Їжа"),
      ("Housing", "Житло"),
      ("Wellness", "Здоров'я та догляд"),
      ("Goods", "Товари"),
      ("Leisure", "Дозвілля"),
      -- Expense items
      ("Groceries", "Продукти"),
      ("Dining", "Кафе та ресторани"),
      ("Transport", "Транспорт"),
      ("Utilities", "Комунальні послуги"),
      ("Rent", "Оренда"),
      ("Entertainment", "Розваги"),
      ("Fitness", "Фітнес"),
      ("Health", "Здоров'я"),
      ("Education", "Освіта"),
      ("Clothing", "Одяг"),
      ("Insurance", "Страхування"),
      ("Subscriptions", "Підписки"),
      ("Household", "Побут"),
      ("Travel", "Подорожі"),
      ("Gifts", "Подарунки"),
      ("Charity", "Благодійність"),
      ("Taxes & Fees", "Податки та збори"),
      ("Beauty & Personal Care", "Краса та особистий догляд"),
      ("Pets", "Домашні улюбленці"),
      ("Electronics", "Електроніка"),
      ("Shopping", "Покупки"),
      ("Other", "Інше"),
      -- Income groups
      ("Earned", "Активний дохід"),
      ("Passive", "Пасивний дохід"),
      -- Income items
      ("Salary", "Зарплата"),
      ("Freelance", "Фріланс"),
      ("Investment", "Інвестиції"),
      ("Business", "Бізнес"),
      ("Rental", "Оренда (дохід)"),
      ("Gift", "Подарунок"),
      ("Refund", "Повернення коштів")
    ]
```

> `"Other"` appears in **both** income and expense default lists but with the
> **same** canonical string, so one map entry covers both. That is correct: the
> catalog is keyed by name, and both resolve to `"Інше"`.

- [ ] **Step 4: Run the test — expect PASS** (fix any wording the completeness check flags).

- [ ] **Step 5: Commit**

```bash
git add src/Domain/Localization/CategoryCatalog.hs test/Domain/Localization/CategoryCatalogSpec.hs
git commit -m "feat(localization): uk default-category name catalog"
```

---

### Task 3: `relocalizeDefaultDictionaries` — the ID-anchored rename pass

**Files:**
- Modify: `src/Domain/Configuration/Defaults.hs` (export a canonical-name-by-id map)
- Modify: `src/Application/Services/ConfigurationService.hs`
- Test: `test/Application/Services/ConfigurationServiceIntegrationSpec.hs`

- [ ] **Step 1: Add the canonical-name-by-id helper to `Defaults.hs`**

Add to the export list and body:

```haskell
-- in the export list:
    defaultCategoryNamesById,

-- in the body (needs: import qualified Data.Map.Strict as Map; Domain.Core.Types (CategoryId)):
-- | Every default entry's canonical English name, keyed by its deterministic id.
-- The ID anchor for locale re-translation: an entry counts as an untouched app
-- default only if its id is a key here.
defaultCategoryNamesById :: Map CategoryId Text
defaultCategoryNamesById =
  Map.fromList
    [ (e.entryId, e.entryName)
      | e <- defaultIncomeCategories <> defaultExpenseCategories
    ]
```

- [ ] **Step 2: Write the failing integration test**

Add to `ConfigurationServiceIntegrationSpec.hs` (follow the existing setup helpers in that file for creating a user + writable config; reuse Testkit rather than re-deriving):

```haskell
describe "default-category localization" $ do
  it "renames untouched default categories to Ukrainian on changeCountry UA" $ do
    -- Arrange: a fresh user whose config has the untouched English defaults.
    -- Act: changeCountry userId (mkUA)
    -- Assert: the expense dictionary contains "Продукти" and no longer "Groceries".
    pending

  it "leaves a user-renamed default untouched when locale changes" $ do
    -- Arrange: rename the "Groceries" default to "My Food" via renameDictionaryEntry.
    -- Act: changeLanguage userId Uk
    -- Assert: "My Food" is still present (not translated), other defaults are uk.
    pending

  it "leaves user-created categories untouched" $ do
    -- Arrange: addDictionaryEntry a new "Coffee" category (random id).
    -- Act: changeLanguage userId Uk
    -- Assert: "Coffee" still present verbatim.
    pending
```

Flesh out each `pending` into a real Arrange-Act-Assert using the spec file's
existing helpers (look at neighbouring `it` blocks for how they build a user,
ensure a writable config, and read it back via `getConfiguration`). Assert on the
names returned by `dictionaryItems` for the income/expense dictionaries.

- [ ] **Step 3: Run — expect FAIL** (behaviour not implemented).

- [ ] **Step 4: Implement `relocalizeDefaultDictionaries` in `ConfigurationService.hs`**

Add near the dictionary helpers. It reads the user's writable config, then for
each entry that passes the ID anchor + canonical-name guard, issues a best-effort
rename to `lang`.

```haskell
-- imports to add:
--   import Domain.Configuration.Defaults (defaultCategoryNamesById)
--   import Domain.Localization.CategoryCatalog (localizedCategoryName)
--   import qualified Data.Map.Strict as Map
--   add `unEntryName` to the existing `Domain.Core.Types (...)` import
--     (`unsafeEntryName` is already imported; `unEntryName` is not).
--   NOTE: `Language` is ALREADY imported (Domain.Localization.Language (Language, languageCode)).
--   NOTE: `dictionaryEntriesParentFirst` and `getConfiguration` are ALREADY imported
--     from Application.ReadModels.Configuration; `dictionaryItems` is NOT (and must
--     not be used here — see below).

-- | Re-translate the user's *untouched* default categories to @lang@.
--
-- Materialized re-translation: rewrites the stored name via 'renameDictionaryEntry'.
-- An entry qualifies only if (a) its id is a known default id AND (b) its current
-- name equals that default's canonical name in some supported language — so
-- user-renamed or user-created entries are never touched. Best-effort per entry:
-- a 'DuplicateEntryName' (or any) failure is logged and skipped, never aborting
-- the caller (mirrors 'copyDictionaries'/'seedFresh').
--
-- Uses 'dictionaryEntriesParentFirst' (NOT 'dictionaryItems') so GROUP nodes
-- ("Food", "Housing", …) — which are default entries and must be localized too —
-- are included. 'dictionaryItems' is leaf-only (ADR 002) and would leave group
-- names in English.
relocalizeDefaultDictionaries :: UserId -> Language -> AppM ()
relocalizeDefaultDictionaries userId lang = do
  ensured <- ensureClonedConfiguration userId
  case ensured of
    Left err -> logWarn $ "relocalize: could not ensure config: " <> displayShow err
    Right configId -> do
      maybeConfig <- runDb (getConfiguration configId)
      case maybeConfig of
        Nothing -> logWarn "relocalize: config not found after ensure"
        Just configData ->
          forM_ (Map.toList configData.dictionaries) $ \(dictKind, dictData) ->
            forM_ (dictionaryEntriesParentFirst dictData) $ \(eid, nm, _role, _parent) ->
              case Map.lookup eid defaultCategoryNamesById of
                Nothing -> pure () -- not a default entry (user-created)
                Just canonical -> do
                  let current = unEntryName nm
                      acceptable = [localizedCategoryName l canonical | l <- [minBound .. maxBound]]
                      target = localizedCategoryName lang canonical
                  when (current `elem` acceptable && current /= target) $ do
                    result <- renameDictionaryEntry userId dictKind eid (unsafeEntryName target)
                    case result of
                      Left err -> logWarn $ "relocalize: skip " <> display current <> ": " <> displayShow err
                      Right () -> pure ()
```

> Group nodes are localized because they are keys in `defaultCategoryNamesById`
> (built from `defaultExpenseCategories`/`defaultIncomeCategories`, which include
> `mkExpenseGroup`/`mkIncomeGroup` entries). `configData.dictionaries` dot-access
> is unambiguous here — it is already used in this file at `ConfigurationService.hs:1020`.

- [ ] **Step 5: Run the test — expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Configuration/Defaults.hs src/Application/Services/ConfigurationService.hs test/Application/Services/ConfigurationServiceIntegrationSpec.hs
git commit -m "feat(config): ID-anchored relocalization of untouched default categories"
```

---

### Task 4: Trigger relocalization from `changeCountry` and `changeLanguage`

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs`
- Test: `test/Application/Services/ConfigurationServiceIntegrationSpec.hs` (extend Task 3 tests to assert the end-to-end trigger, if not already)

- [ ] **Step 1: Wire the trigger**

In `changeLanguage`, after the `ChangeLanguage` command succeeds:

```haskell
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (ChangeLanguageConfigurationCommand ChangeLanguage {language = newLanguage})
  lift (relocalizeDefaultDictionaries userId newLanguage)   -- <-- add
  lift $ logInfo "Language changed successfully"
```

In `changeCountry`, after leg 1 (and leg 2), using the preset's language:

```haskell
  let CountryPreset {baseCurrency = presetBaseCurrency, language = presetLanguage} = presetFor newCountry
  ...
  -- after ChangeCountry command + base-currency leg:
  lift (relocalizeDefaultDictionaries userId presetLanguage)   -- <-- add
  lift $ logInfo "Country changed successfully"
```

> `ChangeCountry` already emits `LanguageChanged` (cascade), so the config's
> language and the categories are consistent. Destructure the preset (do not use
> `presetFor newCountry` dot-access) to avoid the `DuplicateRecordFields`
> ambiguity — see the existing line at `ConfigurationService.hs:271`.

- [ ] **Step 2: Run the Slice B integration tests — expect PASS** (the Task 3 tests already exercise the public `changeCountry`/`changeLanguage` entry points).

- [ ] **Step 3: Confirm no stored-shape regression**

Run: `cabal test all --test-option='--match' --test-option="/Infrastructure.Eventium.Schema/"`
Expected: PASS, `accountingSchemaRegistry` still empty (no upcaster added).

- [ ] **Step 4: Commit**

```bash
git add src/Application/Services/ConfigurationService.hs test/Application/Services/ConfigurationServiceIntegrationSpec.hs
git commit -m "feat(config): relocalize default categories on country/language change"
```

---

## Phase 2 — Slice A: Telegram output localization

> **⚠ Compile-unit warning for Phase 2.** Tasks 6, 7, 8, and 9 all change the
> **signatures** of functions that `Telegram/Commands.hs` calls (`formatRecordedTransaction`,
> `formatTransactionLine`, keyboard builders, `formatCommandList`, `botCommands`),
> but the Commands.hs call sites are not fully re-threaded until **Task 9**.
> Therefore **Tasks 6–9 form a single build-green unit**: the library will not
> compile cleanly *between* these tasks. Two acceptable ways to execute:
>
> - **Preferred:** treat Tasks 6→9 as one checkpoint — implement all four, then
>   require a clean `-fci` build + full Telegram suite green once, at the end of
>   Task 9. Still commit per task (a mid-unit commit that doesn't build is fine on
>   a feature branch), but only *gate* on green after Task 9.
> - **Alternative:** as you change each signature, add the new `Language` param but
>   keep a thin `…En`-defaulting wrapper at the old name so Commands.hs keeps
>   compiling; Task 9 removes the wrappers when it threads `lang`.
>
> Task 5 (the catalog module) is self-contained and *does* build/commit green on
> its own.

### Task 5: `Telegram.I18n` — the bot catalog (record-per-language)

**Files:**
- Create: `src/Telegram/I18n.hs`
- Test: `test/Telegram/I18nSpec.hs`

Structure the catalog by feature namespace. Collect the strings from their current
call sites: `Telegram/Commands.hs` (the ~150 `sendMsg` literals), `Telegram/Formatting.hs`
(type/status labels, `"recorded"`, `"Labels:"`, `"Rate:"`), `Telegram/Types.hs`
(`botCommands` descriptions), `Telegram/Keyboards.hs` (static button labels:
`"Confirm"`, `"Cancel"`, `"Clear selection"`).

Do this **namespace by namespace** to keep each change reviewable; commit after each
if desired. Build the record types with function-typed fields for interpolating
messages.

- [ ] **Step 1: Write the failing test** (assert both locales + a representative interpolation)

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Telegram.I18nSpec (spec) where

import Domain.Localization.Language (Language (..))
import RIO
import Telegram.I18n (telegramStrings, common, accounts)
import Test.Hspec

spec :: Spec
spec = describe "Telegram.I18n.telegramStrings" $ do
  it "renders English chrome for En" $
    (telegramStrings En).common.cancelled `shouldBe` "Operation cancelled."

  it "renders Ukrainian chrome for Uk" $
    (telegramStrings Uk).common.cancelled `shouldBe` "Операцію скасовано."

  it "interpolates account-created (En)" $
    (telegramStrings En).accounts.createdSelected "Cash" "USD"
      `shouldBe` "Account \"Cash\" created and selected! (USD)"
```

- [ ] **Step 2: Run — expect FAIL** (module missing).

- [ ] **Step 3: Implement `Telegram.I18n`** — record types + `en` + `uk` + dispatch.

Skeleton (extend each sub-record with the full set of strings for that namespace):

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.I18n
-- Description : Telegram bot output catalog (localization area).
--
-- A closed record-per-language catalog on the 'Domain.Localization' foundation.
-- Completeness is compiler-enforced: an omitted field is '-Wmissing-fields',
-- an error under '-fci'/'-Werror'. Pure: static compiled catalogs.
module Telegram.I18n
  ( TelegramStrings (..),
    CommonStrings (..),
    AccountStrings (..),
    TransactionStrings (..),
    PromptStrings (..),
    ErrorStrings (..),
    telegramStrings,
  )
where

import Domain.Localization.Language (Language (..))
import RIO

data TelegramStrings = TelegramStrings
  { common :: CommonStrings,
    accounts :: AccountStrings,
    transactions :: TransactionStrings,
    prompt :: PromptStrings,
    errors :: ErrorStrings
  }

data CommonStrings = CommonStrings
  { cancelled :: Text,
    nothingToCancel :: Text,
    tapButtonOrCancel :: Text,
    unknownCommand :: Text -> Text -- command token
    -- ... add the rest
  }

data AccountStrings = AccountStrings
  { enterName :: Text,
    nameEmpty :: Text,
    createdSelected :: Text -> Text -> Text, -- name, currency code
    notFound :: Text
    -- ... add the rest
  }

data TransactionStrings = TransactionStrings
  { incomeLabel :: Text,
    expenseLabel :: Text,
    transferLabel :: Text,
    adjustmentLabel :: Text,
    recorded :: Text -> Text, -- kind label -> "<kind> recorded"
    pendingMarker :: Text,
    cancelledMarker :: Text,
    failedMarker :: Text -> Text, -- reason
    labelsPrefix :: Text, -- "Labels: "
    ratePrefix :: Text, -- "Rate: "
    noneFound :: Text
    -- ... add the rest
  }

data PromptStrings = PromptStrings
  { enterAmount :: Text,
    invalidAmount :: Text,
    unavailable :: Text,
    couldNotProcess :: Text
    -- ... add the rest
  }

data ErrorStrings = ErrorStrings
  { userNotFound :: Text,
    noAccountSelected :: Text,
    invalidCurrency :: Text
    -- ... add the rest
  }

telegramStrings :: Language -> TelegramStrings
telegramStrings En = en
telegramStrings Uk = uk

en :: TelegramStrings
en =
  TelegramStrings
    { common =
        CommonStrings
          { cancelled = "Operation cancelled.",
            nothingToCancel = "Nothing to cancel.",
            tapButtonOrCancel = "Please tap one of the buttons above, or /cancel to start over.",
            unknownCommand = \cmd -> "Unknown command: " <> cmd <> ". Use /help to see available commands."
          },
      accounts =
        AccountStrings
          { enterName = "Enter a name for your new account:",
            nameEmpty = "Account name cannot be empty. Please enter a name:",
            createdSelected = \n c -> "Account \"" <> n <> "\" created and selected! (" <> c <> ")",
            notFound = "Account not found."
          },
      transactions =
        TransactionStrings
          { incomeLabel = "Income",
            expenseLabel = "Expense",
            transferLabel = "Transfer",
            adjustmentLabel = "Adjustment",
            recorded = \k -> k <> " recorded",
            pendingMarker = "  [Pending]",
            cancelledMarker = "  [Cancelled]",
            failedMarker = \r -> "  [Failed: " <> r <> "]",
            labelsPrefix = "Labels: ",
            ratePrefix = "Rate: ",
            noneFound = "No transactions found."
          },
      prompt =
        PromptStrings
          { enterAmount = "Enter amount:",
            invalidAmount = "Invalid amount. Please enter a positive number:",
            unavailable = "Text prompts aren't available right now. Try /income, /expense or /transfer.",
            couldNotProcess = "Sorry, I couldn't process that. Please rephrase, or use /help to see the commands."
          },
      errors =
        ErrorStrings
          { userNotFound = "Could not find your user account. Use /start first.",
            noAccountSelected = "No account selected. Use /accounts to select one first.",
            invalidCurrency = "Invalid currency. Please select from the keyboard."
          }
    }

uk :: TelegramStrings
uk =
  TelegramStrings
    { common =
        CommonStrings
          { cancelled = "Операцію скасовано.",
            nothingToCancel = "Немає що скасовувати.",
            tapButtonOrCancel = "Натисніть одну з кнопок вище або /cancel, щоб почати спочатку.",
            unknownCommand = \cmd -> "Невідома команда: " <> cmd <> ". Скористайтесь /help, щоб побачити доступні команди."
          },
      accounts =
        AccountStrings
          { enterName = "Введіть назву нового рахунку:",
            nameEmpty = "Назва рахунку не може бути порожньою. Введіть назву:",
            createdSelected = \n c -> "Рахунок \"" <> n <> "\" створено та вибрано! (" <> c <> ")",
            notFound = "Рахунок не знайдено."
          },
      transactions =
        TransactionStrings
          { incomeLabel = "Дохід",
            expenseLabel = "Витрата",
            transferLabel = "Переказ",
            adjustmentLabel = "Коригування",
            recorded = \k -> k <> " записано",
            pendingMarker = "  [В обробці]",
            cancelledMarker = "  [Скасовано]",
            failedMarker = \r -> "  [Помилка: " <> r <> "]",
            labelsPrefix = "Мітки: ",
            ratePrefix = "Курс: ",
            noneFound = "Транзакцій не знайдено."
          },
      prompt =
        PromptStrings
          { enterAmount = "Введіть суму:",
            invalidAmount = "Некоректна сума. Введіть додатне число:",
            unavailable = "Текстові запити зараз недоступні. Спробуйте /income, /expense або /transfer.",
            couldNotProcess = "Вибачте, не вдалося обробити. Перефразуйте або скористайтесь /help."
          },
      errors =
        ErrorStrings
          { userNotFound = "Не вдалося знайти ваш обліковий запис. Скористайтесь /start.",
            noAccountSelected = "Рахунок не вибрано. Скористайтесь /accounts, щоб вибрати.",
            invalidCurrency = "Некоректна валюта. Виберіть із клавіатури."
          }
    }
```

> **This is the bulk of the work.** The skeleton above shows the pattern; extend
> every sub-record to cover ALL strings from `Telegram/Commands.hs`,
> `Telegram/Formatting.hs`, `Telegram/Types.hs`, and the static labels in
> `Telegram/Keyboards.hs`. Because `telegramStrings` and each record must be fully
> constructed, the `-fci` build will **fail** until every field is present in both
> `en` and `uk` — that failure list is your checklist. Grep each source file for
> string literals: `grep -noE '"[^"]+"' src/Telegram/Commands.hs`.

- [ ] **Step 4: Run the test + build — expect PASS and clean `-fci` build.**

Run: `just build && cabal test all --test-option='--match' --test-option="/Telegram.I18n/"`

- [ ] **Step 5: Commit**

```bash
git add src/Telegram/I18n.hs test/Telegram/I18nSpec.hs
git commit -m "feat(telegram): bot output catalog (en/uk) on the localization foundation"
```

---

### Task 6: Localize `Telegram.Formatting` renderers

**Files:**
- Modify: `src/Telegram/Formatting.hs`
- Test: `test/Telegram/FormattingSpec.hs`

- [ ] **Step 1: Add failing per-language tests**

For `formatRecordedTransaction` and `formatTransactionLine`, assert that with `Uk`
the type/status labels are Ukrainian while **user content stays verbatim**:

```haskell
it "localizes the type label but keeps the description verbatim (Uk)" $ do
  let out = formatRecordedTransaction Uk mempty mempty (expenseTdWithDescription "McDonald's")
  out `shouldSatisfy` ("Витрата" `T.isInfixOf`)
  out `shouldSatisfy` ("McDonald's" `T.isInfixOf`)   -- user content untranslated
```

(Reuse this spec file's existing `TransactionData` builders/fixtures; add the
`Language` argument to existing call sites — they will fail to compile first,
which is your Red.)

- [ ] **Step 2: Run — expect FAIL / compile error.**

- [ ] **Step 3: Thread `Language` through the renderers**

- `formatRecordedTransaction :: Language -> Map ... -> Map ... -> TransactionData -> Text`
- `formatTransactionLine :: Language -> Map DictionaryEntryId Text -> (TransactionId, TransactionData) -> Text`
- Replace the hard-coded `"Income"/"Expense"/"Transfer"/"Adjustment"`, the status
  markers, `header kind = "\9989 " <> kind <> " recorded"`, `"Labels: "`, `"Rate: "`
  with `(telegramStrings lang).transactions.*`. Keep `formatMoney`, `showCurrency`,
  `formatDate` unchanged (international default — spec §A.5).
- Leave category/label/account names and descriptions routed exactly as today
  (user content — never through the catalog).

- [ ] **Step 4: Run the tests — expect PASS.**

- [ ] **Step 5: Commit**

```bash
git add src/Telegram/Formatting.hs test/Telegram/FormattingSpec.hs
git commit -m "feat(telegram): localize transaction renderers"
```

---

### Task 7: Localize static keyboard labels

**Files:**
- Modify: `src/Telegram/Keyboards.hs`

Only the **static** labels localize: `"Confirm"`, `"Cancel"` (`cancelButton`,
`confirmCancelKeyboard`, `cancelKeyboard`), and `"Clear selection"`. Currency codes
(`UAH/USD/EUR/GBP`) and category names (user content) stay verbatim.

- [ ] **Step 1: Thread `Language` into the builders that emit static labels**

Give `confirmCancelKeyboard`, `cancelKeyboard`, and `accountSelectionKeyboard`
(for its `"Clear selection"` + `cancelButton`) a `Language` parameter, and make
`cancelButton :: Language -> InlineButton`. `currencyKeyboard` and
`categoryKeyboard` need `Language` only if they include a cancel row (they do —
thread it). Pull labels from `(telegramStrings lang).common.*` (add `confirm`,
`cancel`, `clearSelection` fields to `CommonStrings` in Task 5 if not already).

- [ ] **Step 2: Fix all call sites in `Telegram/Commands.hs`** (they now pass `lang`).
  This will not fully compile until Task 9 threads `lang` — acceptable if you do
  Tasks 7→9 back-to-back; otherwise temporarily pass the already-resolved `lang`.

- [ ] **Step 3: Build — expect clean once call sites updated.**

- [ ] **Step 4: Commit**

```bash
git add src/Telegram/Keyboards.hs
git commit -m "feat(telegram): localize static keyboard labels"
```

---

### Task 8: Localize `botCommands` + `/help` + per-locale `setMyCommands`

**Files:**
- Modify: `src/Telegram/Types.hs`, `src/Telegram/Formatting.hs` (`formatCommandList`), `src/Telegram/Api.hs`, `src/Telegram/Bot.hs`

- [ ] **Step 1: Make `botCommands` locale-aware**

`botCommands :: Language -> [(Text, Text)]` — command tokens stay stable; only
descriptions localize (pull from a `commands :: CommandStrings` namespace you add
to `Telegram.I18n`, or from a simple `case lang` table in `Types.hs`). Update
`formatCommandList :: Language -> [Text]` accordingly (used by in-chat `/help`,
`/start` — uses the user's stored signal).

- [ ] **Step 2: Register the command menu per supported locale**

In `Telegram.Api` (`registerCommands`), and its caller in `Telegram.Bot`
(`setupBotCommands`), loop over supported locales: call the `setMyCommands`
wrapper once with `setMyCommandsLanguageCode = Nothing` + `botCommands En` (the
default menu) and once with `Just "uk"` + `botCommands Uk`. This menu follows the
**Telegram client** locale (platform limit — spec §A.4), distinct from in-chat
`/help`.

- [ ] **Step 3: Build + a small unit test** that `botCommands Uk` differs from
  `botCommands En` in descriptions but shares tokens.

- [ ] **Step 4: Commit**

```bash
git add src/Telegram/Types.hs src/Telegram/Formatting.hs src/Telegram/Api.hs src/Telegram/Bot.hs
git commit -m "feat(telegram): localize command list + per-locale setMyCommands menus"
```

---

### Task 9: Resolve + thread `Language` through the handlers; replace literals

**Files:**
- Modify: `src/Telegram/Commands.hs`

This is the second bulk task: every `sendMsg chatId "literal"` becomes
`sendMsg chatId ((telegramStrings lang).<ns>.<field> ...)`.

- [ ] **Step 1: Add the resolution helper**

```haskell
languageForTelegram :: TelegramId -> AppM Language
languageForTelegram telegramId = do
  maybeUser <- runDb (getUserByTelegramId telegramId)
  case maybeUser of
    Nothing -> pure En
    Just (_, userData) -> do
      maybeConfig <- runDb (getConfiguration userData.configurationId)
      pure (maybe En (.language) maybeConfig)
```

- [ ] **Step 2: Resolve once per update and thread it**

At the top of `handleCommand` / `handleMessage` / `handleCallbackQuery`, resolve
`lang <- languageForTelegram telegramId` and pass it into the per-command helpers.
Where a helper already loads `ConfigurationData` (`getCategoryEntries`,
`getDictionaryEntryNames`, `replyRecordedTransaction`), read `.language` from that
value instead of re-fetching (spec §A.1). Pre-signup branches (`/start`,
`/signup`, unknown user) use `En`.

- [ ] **Step 3: Replace every user-facing literal** in `Telegram/Commands.hs` with
  the corresponding `telegramStrings` field. Verify with:
  `grep -noE 'sendMsg [^)]*"[^"]+"' src/Telegram/Commands.hs` — expect no
  user-facing literals remain (a few control strings like callback-data prefixes
  are not user-facing and stay).

- [ ] **Step 4: Build clean under `-fci`**, run the full Telegram suite:
  `cabal test all --test-option='--match' --test-option="/Telegram/"`

- [ ] **Step 5: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): thread user language through handlers, localize all replies"
```

---

## Phase 3 — Verification

### Task 10: Full-suite + cold-build verification

- [ ] **Step 1: Cold build under the CI gate**

Run: `just rebuild` (clean + `-fci` build) — expect no warnings/errors (the warm
`.o` cache can mask `-Werror`).

- [ ] **Step 2: Full test suite**

Run: `just test` — expect green. (Note: full `cabal test all` needs a manually
created `eventium_test` Postgres DB; the ~28 event-store integration failures
without it are environmental, not regressions.)

- [ ] **Step 3: Lint + format**

Run: `just check` (ormolu + hlint) — no new lint; no suppressions.

- [ ] **Step 4: Manual smoke (optional but recommended)** — see @skills `verify`/`run`:
  start the app + a Telegram session, set language to `uk` via the API, and
  confirm a `/expense` confirmation renders Ukrainian chrome with a verbatim
  description; set country=UA and confirm default categories show Ukrainian names.

- [ ] **Step 5: Final commit / open PR**

```bash
git commit -am "chore: backend localization verification pass" --allow-empty
# open PR against master per project conventions (branch feat/backend-localization)
```

---

## Notes for the executor

- **Order flexibility:** Phase 1 (Slice B) and Phase 2 (Slice A) are independent;
  Phase 0 (foundation) must come first. Tasks 7 and 9 touch `Telegram/Commands.hs`
  call sites together — do them back-to-back to avoid a transient non-compiling
  state, or keep a temporary `lang` in scope.
- **No stored-shape change anywhere** — if you find yourself editing an event's
  `FromJSON`/`ToJSON` or `accountingSchemaRegistry`, stop: the design forbids it.
- **User content is sacred** — category/label/contact names, descriptions, and
  account names are never routed through any catalog. If a test needs them
  translated, the test is wrong.
- **Reuse Testkit** (`test/Testkit/*`) for fixtures/helpers rather than re-deriving
  per spec.
```
