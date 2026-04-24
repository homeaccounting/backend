---
status: draft
---

# Bank Integration Phase 2 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-request `defaultCategory` body field on `/api/banking/resync` with per-user banking configuration (default categories + MCC→category map) stored on the `Configuration` aggregate, and move MCC→category resolution entirely server-side.

**Architecture:** Three waves. (1) **Additive domain work** — new `type MCC = Text` and `type CategoryId = DictionaryEntryId` aliases, new `Domain/Configuration/Defaults.hs` module with `expense` / `income` namespace records and the hardcoded `defaultMccExpenseCategoryMap`, new `BankingConfiguration` sub-record on `Configuration`, three new commands / events / handler branches, projection updates, read-model field, configuration service operations, `PUT /api/users/me/configuration/banking` endpoint. These are all additive: the branch compiles and existing behavior is preserved at every task. (2) **Provider / service refactor** — `TransactionClassification` collapses to a direction discriminator, `BankTransaction.mcc` becomes `Maybe MCC`, Monobank adapter stringifies the numeric MCC, `BankImportService` inlines category resolution, `ResyncRequest` drops `defaultCategory`. These tasks are tightly coupled; they ship together. (3) **Seed / clone / tests / polish** — extend `seedDefaultConfiguration`, extend `cloneConfiguration` (clone-on-write carries banking fields forward), new test coverage, format + lint. No migration/backfill: the database is recreated on Phase 2 deploy.

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Servant + Warp, Eventium event sourcing, Hspec + QuickCheck, LiquidHaskell, ormolu, hlint. Build via `just build`, test via `just test`.

**Spec:** `docs/specs/2026-04-23-bank-integration-phase-2-design.md`

---

## File Structure

### Created

| File | Responsibility |
|------|----------------|
| `src/Domain/Configuration/Defaults.hs` | `DefaultEntry`, `ExpenseDefaults`, `IncomeDefaults`, `expense`, `income`, `defaultExpenseCategories`, `defaultIncomeCategories`, `defaultMccExpenseCategoryMap`, plus `configNamespace`, `mkDeterministicEntryId`, `incomeCategoryDictId`, `expenseCategoryDictId` (extracted from `ConfigurationService`). |
| `test/Domain/Configuration/DefaultsSpec.hs` | Sanity check on `defaultMccExpenseCategoryMap` (MCC keys distinct and non-empty text, every value resolves to a `CategoryId` present in `defaultExpenseCategories` or `defaultIncomeCategories`) and on `mkDeterministicEntryId` roundtripping via `expense.*.entryId` / `income.*.entryId`. |
| `test/Web/API/ConfigurationBankingAPISpec.hs` | Endpoint tests for `PUT /api/configuration/banking` and the extended `GET /api/configuration` response. |

### Modified

| File | Changes |
|------|---------|
| `src/Domain/Core/Types.hs` | Add `type MCC = Text` and `type CategoryId = DictionaryEntryId` aliases (export both). |
| `src/Domain/Configuration/Events.hs` | Add `BankingDefaultIncomeCategorySet`, `BankingDefaultExpenseCategorySet`, `BankingMccExpenseCategoryMapSet` records; include them in `configurationEvents`; add `deriveJSON` splices. |
| `src/Domain/Configuration/Commands.hs` | Add `SetBankingDefaultIncomeCategory`, `SetBankingDefaultExpenseCategory`, `SetBankingMccExpenseCategoryMap` records. |
| `src/Domain/Configuration/CommandHandler.hs` | Add three new handler branches; extend the `RemoveDictionaryEntry` in-use check to include the new banking slots. |
| `src/Domain/Configuration/Projection.hs` | Add `BankingConfiguration` record; add `banking :: BankingConfiguration` to `Configuration`; update `configurationDefault`; handle the three new events. |
| `src/Domain/Configuration/Errors.hs` | Add message constructors for the new invariants. |
| `src/Application/ReadModels/Configuration.hs` | Add `banking :: BankingConfiguration` to `ConfigurationData`; fold the new events. |
| `src/Application/Services/ConfigurationService.hs` | Import from `Domain.Configuration.Defaults` (remove duplicated constants); add `setBankingDefaultIncomeCategory` / `setBankingDefaultExpenseCategory` / `setBankingMccCategoryMap` service operations; extend `seedDefaultConfiguration` to emit the three new events. |
| `src/Web/API/ConfigurationAPI.hs` | Add `PUT /api/configuration/banking` route; extend the configuration read response DTO with `banking`. |
| `src/Infrastructure/Banking/Provider.hs` | `TransactionClassification` collapses to `ClassifiedIncome | ClassifiedExpense`; `BankTransaction.mcc` changes from `Maybe Int32` to `Maybe MCC`. |
| `src/Infrastructure/Banking/Monobank.hs` | `monoClassifyTransaction` returns a direction only; `toProviderTransaction` stringifies `stmtMcc` (treating `0` as `Nothing` as today). |
| `src/Application/Services/BankImportService.hs` | Drop `defaultCategory` parameter from `resync` / `importTransaction`; inline configuration lookup; do MCC→CategoryId resolution with existence check + default fallback. |
| `src/Web/API/BankingAPI.hs` | Drop `defaultCategory` from `ResyncRequest`; drop the `mkDictionaryEntryId` validation; update `resyncHandler`. |
| `test/Testkit/InMemoryEventStore.hs` | Fixture `Configuration` records construct with empty `BankingConfiguration`. |
| `test/Application/Services/BankImportServiceSpec.hs` | Replace `defaultCategory`-passing call sites with in-configuration defaults; add MCC-hit, stale-MCC, missing-default cases. |
| `test/Application/Services/ConfigurationServiceSpec.hs` (create if absent) | Verify `seedDefaultConfiguration` emits the three new events. |
| `test/Domain/Configuration/CommandHandlerSpec.hs` | Invariant tests for the three new commands and the extended `RemoveDictionaryEntry` guard. |
| `test/Domain/Configuration/ProjectionSpec.hs` | Replay tests for the three new events. |
| `test/Integration/BankImportWorkflowSpec.hs` | Update fixtures; drop `defaultCategory` from calls; assert MCC-driven category selection. |

---

## Task 1: Add `MCC` and `CategoryId` type aliases

**Files:**
- Modify: `src/Domain/Core/Types.hs`

**Goal:** Make `MCC` and `CategoryId` available to downstream modules as text/UUID aliases.

- [ ] **Step 1: Add the two aliases to `Domain.Core.Types`**

In `src/Domain/Core/Types.hs`, near the existing `DictionaryEntryId` block (around line 566), add:

```haskell
-- | Alias for a category entry id. Matches the intent of a
--   'DictionaryEntryId' used in the income-category / expense-category
--   dictionaries; documents call-site meaning without introducing a
--   parallel type. Mirrors the 'LabelId' alias added for transaction labels.
type CategoryId = DictionaryEntryId

-- | ISO 18245 Merchant Category Code, rendered as text.
--
-- Monobank-produced MCCs are 4-digit numeric codes but they are
-- consistently transported and stored as strings (API payloads, JSON
-- map keys, log lines). Modeling as 'Text' also keeps the door open
-- for future providers that emit non-numeric category keys through
-- the same field.
type MCC = Text
```

Add `CategoryId,` and `MCC,` to the module export list (near the other `Dictionary*` exports, ~line 59 and nearby).

- [ ] **Step 2: Build**

Run: `just build`
Expected: PASS. Pure type-alias addition has no other ripple.

- [ ] **Step 3: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "feat(core): add MCC and CategoryId type aliases"
```

---

## Task 2: Extract `Domain/Configuration/Defaults.hs`

**Files:**
- Create: `src/Domain/Configuration/Defaults.hs`
- Modify: `src/Application/Services/ConfigurationService.hs`
- Test: `test/Domain/Configuration/DefaultsSpec.hs` (create)

**Goal:** Move the deterministic-ID helper, well-known dictionary IDs, default category name data, and the hardcoded MCC map into a dedicated Domain module inside the Configuration bounded context. Eliminates the string-duplication of category names between seed and MCC map.

- [ ] **Step 1: Failing test for `Domain.Configuration.Defaults`**

Create `test/Domain/Configuration/DefaultsSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Configuration.DefaultsSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Domain.Configuration.Defaults
  ( DefaultEntry (..)
  , defaultExpenseCategories
  , defaultIncomeCategories
  , defaultMccExpenseCategoryMap
  , expense
  , income
  , mkDeterministicEntryId
  , expenseCategoryDictId
  , incomeCategoryDictId
  )
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Configuration.Defaults" $ do
  describe "record-dot lookups" $ do
    it "expense.food.entryName is \"Food\"" $
      expense.food.entryName `shouldBe` "Food"

    it "expense.food.entryId matches the deterministic UUIDv5" $
      expense.food.entryId `shouldBe` mkDeterministicEntryId expenseCategoryDictId "Food"

    it "income.salary.entryName is \"Salary\"" $
      income.salary.entryName `shouldBe` "Salary"

    it "income.salary.entryId matches the deterministic UUIDv5" $
      income.salary.entryId `shouldBe` mkDeterministicEntryId incomeCategoryDictId "Salary"

  describe "default category lists" $ do
    it "defaultExpenseCategories has the expected size and includes 'Food'" $ do
      length defaultExpenseCategories `shouldBe` 16
      map (.entryName) defaultExpenseCategories `shouldContain` ["Food", "Transport", "Other"]

    it "defaultIncomeCategories has the expected size and includes 'Salary'" $ do
      length defaultIncomeCategories `shouldBe` 8
      map (.entryName) defaultIncomeCategories `shouldContain` ["Salary", "Other"]

  describe "defaultMccExpenseCategoryMap" $ do
    it "has all keys as non-empty text" $
      Map.keys defaultMccExpenseCategoryMap `shouldSatisfy` all (not . T.null)

    it "every value is a CategoryId present in the default expense or income categories" $ do
      let knownIds =
            map (.entryId) defaultExpenseCategories
              <> map (.entryId) defaultIncomeCategories
      Map.elems defaultMccExpenseCategoryMap `shouldSatisfy` all (`elem` knownIds)

    it "contains the canonical grocery MCC" $
      Map.lookup "5411" defaultMccExpenseCategoryMap `shouldBe` Just expense.food.entryId
```

- [ ] **Step 2: Run the test — expect failure (module does not exist)**

Run: `cabal test all --test-option='--match' --test-option='/Domain.Configuration.Defaults/'`
Expected: FAIL (missing module).

- [ ] **Step 3: Create the `Defaults` module**

Create `src/Domain/Configuration/Defaults.hs`:

```haskell
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.Defaults
-- Description : Hardcoded defaults for the Configuration bounded context.
--
-- Lives inside the Configuration bounded context (next to Events,
-- Commands, Projection, Errors) because everything here is Configuration-
-- specific: well-known dictionary IDs, default category entry names, the
-- deterministic UUIDv5 helper that ties entries to stable IDs, and the
-- MCC→CategoryId seed map used by the banking import flow.
module Domain.Configuration.Defaults
  ( -- * UUIDv5 helpers
    configNamespace
  , mkDeterministicEntryId

    -- * Well-known dictionary IDs
  , incomeCategoryDictId
  , expenseCategoryDictId

    -- * Default-entry value
  , DefaultEntry (..)

    -- * Expense namespace
  , ExpenseDefaults
  , expense

    -- * Income namespace
  , IncomeDefaults
  , income

    -- * Derived lists (seed loop consumes these)
  , defaultExpenseCategories
  , defaultIncomeCategories

    -- * Banking seed data
  , defaultMccExpenseCategoryMap
  ) where

import qualified Data.ByteString.Char8 as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.UUID (UUID)
import qualified Data.UUID.V5 as UUID5
import Domain.Core.Types
  ( CategoryId
  , DictionaryId (..)
  , MCC
  , unsafeDictionaryEntryId
  )
import RIO

-- | Deterministic-ID namespace. Matches the previous constant in
--   'Application.Services.ConfigurationService' — renaming would change
--   every default entry's UUID, which would break both the deterministic
--   seed and this module's MCC map.
configNamespace :: UUID
configNamespace =
  UUID5.generateNamed UUID5.namespaceURL (BS.unpack $ encodeUtf8 "https://homeaccounting.app/config")

-- | Generate a deterministic 'CategoryId' from a dictionary id and entry
--   name. Every invocation with the same inputs returns the same UUID.
mkDeterministicEntryId :: DictionaryId -> Text -> CategoryId
mkDeterministicEntryId (DictionaryId dictIdText) entryNameText =
  unsafeDictionaryEntryId
    $ UUID5.generateNamed configNamespace
    $ BS.unpack (encodeUtf8 (dictIdText <> ":" <> entryNameText))

incomeCategoryDictId :: DictionaryId
incomeCategoryDictId = DictionaryId "income-category"

expenseCategoryDictId :: DictionaryId
expenseCategoryDictId = DictionaryId "expense-category"

-- | One default category entry; the name is what 'AddDictionaryEntry' will
--   see, the id is the deterministic 'CategoryId' both the seed code and
--   the MCC map point to.
data DefaultEntry = DefaultEntry
  { entryName :: !Text
  , entryId   :: !CategoryId
  }
  deriving (Show, Eq)

mkExpense :: Text -> DefaultEntry
mkExpense n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictId n)

mkIncome :: Text -> DefaultEntry
mkIncome n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictId n)

data ExpenseDefaults = ExpenseDefaults
  { food          :: !DefaultEntry
  , transport     :: !DefaultEntry
  , utilities     :: !DefaultEntry
  , rent          :: !DefaultEntry
  , entertainment :: !DefaultEntry
  , health        :: !DefaultEntry
  , education     :: !DefaultEntry
  , clothing      :: !DefaultEntry
  , insurance     :: !DefaultEntry
  , subscriptions :: !DefaultEntry
  , household     :: !DefaultEntry
  , travel        :: !DefaultEntry
  , gifts         :: !DefaultEntry
  , charity       :: !DefaultEntry
  , taxesFees     :: !DefaultEntry
  , other         :: !DefaultEntry
  }

data IncomeDefaults = IncomeDefaults
  { salary     :: !DefaultEntry
  , freelance  :: !DefaultEntry
  , investment :: !DefaultEntry
  , business   :: !DefaultEntry
  , rental     :: !DefaultEntry
  , gift       :: !DefaultEntry
  , refund     :: !DefaultEntry
  , other      :: !DefaultEntry
  }

-- Each name string appears exactly once, on the line that defines the
-- entry. The seed list and the MCC map below reach the entry through the
-- 'expense' / 'income' namespace.
expense :: ExpenseDefaults
expense =
  ExpenseDefaults
    { food          = mkExpense "Food"
    , transport     = mkExpense "Transport"
    , utilities     = mkExpense "Utilities"
    , rent          = mkExpense "Rent"
    , entertainment = mkExpense "Entertainment"
    , health        = mkExpense "Health & Wellness"
    , education     = mkExpense "Education"
    , clothing      = mkExpense "Clothing"
    , insurance     = mkExpense "Insurance"
    , subscriptions = mkExpense "Subscriptions"
    , household     = mkExpense "Household"
    , travel        = mkExpense "Travel"
    , gifts         = mkExpense "Gifts"
    , charity       = mkExpense "Charity"
    , taxesFees     = mkExpense "Taxes & Fees"
    , other         = mkExpense "Other"
    }

income :: IncomeDefaults
income =
  IncomeDefaults
    { salary     = mkIncome "Salary"
    , freelance  = mkIncome "Freelance"
    , investment = mkIncome "Investment"
    , business   = mkIncome "Business"
    , rental     = mkIncome "Rental"
    , gift       = mkIncome "Gift"
    , refund     = mkIncome "Refund"
    , other      = mkIncome "Other"
    }

defaultExpenseCategories :: [DefaultEntry]
defaultExpenseCategories =
  [ expense.food
  , expense.transport
  , expense.utilities
  , expense.rent
  , expense.entertainment
  , expense.health
  , expense.education
  , expense.clothing
  , expense.insurance
  , expense.subscriptions
  , expense.household
  , expense.travel
  , expense.gifts
  , expense.charity
  , expense.taxesFees
  , expense.other
  ]

defaultIncomeCategories :: [DefaultEntry]
defaultIncomeCategories =
  [ income.salary
  , income.freelance
  , income.investment
  , income.business
  , income.rental
  , income.gift
  , income.refund
  , income.other
  ]

defaultMccExpenseCategoryMap :: Map MCC CategoryId
defaultMccExpenseCategoryMap =
  Map.fromList
    [ ("5411", expense.food.entryId)          -- Grocery stores, supermarkets
    , ("5499", expense.food.entryId)          -- Misc food stores
    , ("5812", expense.food.entryId)          -- Restaurants
    , ("5814", expense.food.entryId)          -- Fast food
    , ("5813", expense.entertainment.entryId) -- Bars, nightclubs
    , ("5541", expense.transport.entryId)     -- Service stations (fuel)
    , ("5542", expense.transport.entryId)     -- Automated fuel dispensers
    , ("4111", expense.transport.entryId)     -- Local transit
    , ("4121", expense.transport.entryId)     -- Taxis
    , ("4131", expense.transport.entryId)     -- Bus lines
    , ("7523", expense.transport.entryId)     -- Parking
    , ("4511", expense.travel.entryId)        -- Airlines
    , ("4722", expense.travel.entryId)        -- Travel agencies
    , ("7011", expense.travel.entryId)        -- Lodging
    , ("5912", expense.health.entryId)        -- Drug stores, pharmacies
    , ("8011", expense.health.entryId)        -- Doctors
    , ("8062", expense.health.entryId)        -- Hospitals
    , ("8099", expense.health.entryId)        -- Medical services
    , ("8220", expense.education.entryId)     -- Colleges, universities
    , ("8299", expense.education.entryId)     -- Educational services
    , ("5651", expense.clothing.entryId)      -- Family clothing
    , ("5691", expense.clothing.entryId)      -- Apparel
    , ("5661", expense.clothing.entryId)      -- Shoes
    , ("4900", expense.utilities.entryId)     -- Utilities
    , ("4814", expense.utilities.entryId)     -- Telecom services
    , ("4815", expense.utilities.entryId)     -- Cable/satellite
    , ("4829", expense.other.entryId)         -- Wire transfers
    , ("5968", expense.subscriptions.entryId) -- Direct-marketing subscriptions
    , ("5947", expense.gifts.entryId)         -- Gift shops
    , ("8398", expense.charity.entryId)       -- Charities
    , ("9311", expense.taxesFees.entryId)     -- Tax payments
    , ("5200", expense.household.entryId)     -- Home supply
    , ("5712", expense.household.entryId)     -- Furniture
    , ("5999", expense.other.entryId)         -- Misc specialty
    ]
```

- [ ] **Step 4: Run test**

Run: `cabal test all --test-option='--match' --test-option='/Domain.Configuration.Defaults/'`
Expected: PASS.

- [ ] **Step 5: Refactor `ConfigurationService` to consume `Defaults`**

In `src/Application/Services/ConfigurationService.hs`:

- Remove local `incomeCategoryDictId`, `expenseCategoryDictId`, `configNamespace`, `mkDeterministicEntryId`, `defaultIncomeCategories`, `defaultExpenseCategories` (the existing `[Text]` lists).
- Replace the imports block with an import from `Domain.Configuration.Defaults` exposing the symbols above plus `defaultExpenseCategories` and `defaultIncomeCategories` (now `[DefaultEntry]`).
- Update the seeding loop inside `seedDefaultConfiguration` to iterate `defaultExpenseCategories` / `defaultIncomeCategories` directly and call `AddDictionaryEntry` with `entry.entryName`. Because `DefaultEntry.entryId` already matches the deterministic id the aggregate will compute internally, no behavior changes.

Keep every existing service function (everything outside the seed loop) unchanged.

- [ ] **Step 6: Run full test suite**

Run: `just test`
Expected: PASS. The refactor is behavior-neutral; existing tests continue to pass.

- [ ] **Step 7: Commit**

```bash
git add src/Domain/Configuration/Defaults.hs \
        src/Application/Services/ConfigurationService.hs \
        test/Domain/Configuration/DefaultsSpec.hs
git commit -m "refactor(configuration): extract Domain.Configuration.Defaults

Move UUIDv5 namespace, deterministic-id helper, well-known dictionary
IDs and the default category entries into the Configuration bounded
context. Introduces expense/income namespace records so each default
name appears exactly once. Seed loop now iterates DefaultEntry values
directly, eliminating the previous parallel [Text] list."
```

---

## Task 3: Add `BankingConfiguration` record to the Configuration aggregate

**Files:**
- Modify: `src/Domain/Configuration/Projection.hs`
- Test: `test/Domain/Configuration/ProjectionSpec.hs` (extend)

**Goal:** Grow the `Configuration` aggregate with a `banking` field holding the new `BankingConfiguration` record. Additive only; no event changes yet. The field is empty on every existing projection because no event yet writes to it.

- [ ] **Step 1: Failing test — `configurationDefault` has an empty banking record**

In `test/Domain/Configuration/ProjectionSpec.hs`, add near the existing `configurationDefault` tests:

```haskell
describe "configurationDefault" $ do
  it "has an empty banking configuration" $ do
    let b = configurationDefault.banking
    b.defaultIncomeCategory  `shouldBe` Nothing
    b.defaultExpenseCategory `shouldBe` Nothing
    b.mccExpenseCategoryMap `shouldBe` Map.empty
```

Add the `import Application.ReadModels.Configuration (...)` or the correct module import for `BankingConfiguration`. Because the `BankingConfiguration` type will live in `Domain.Configuration.Projection`, the test imports that module directly.

- [ ] **Step 2: Run — expect failure**

Run: `cabal test all --test-option='--match' --test-option='/configurationDefault has an empty banking/'`
Expected: FAIL — `banking` field / `BankingConfiguration` doesn't exist.

- [ ] **Step 3: Add `BankingConfiguration` and the field**

In `src/Domain/Configuration/Projection.hs`:

```haskell
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Domain.Core.Types (CategoryId, MCC)

-- …existing imports…

data BankingConfiguration = BankingConfiguration
  { defaultIncomeCategory  :: !(Maybe CategoryId)
  , defaultExpenseCategory :: !(Maybe CategoryId)
  , mccExpenseCategoryMap         :: !(Map MCC CategoryId)
  }
  deriving (Show, Eq, Generic)
```

Extend `Configuration`:

```haskell
data Configuration = Configuration
  { baseCurrency    :: Currency,
    defaultCurrency :: Currency,
    dictionaries    :: Map DictionaryId Dictionary,
    banking         :: BankingConfiguration,  -- NEW
    createdBy       :: CreatedBy,
    isCreated       :: Bool
  }
  deriving (Show, Eq)
```

Update `configurationDefault`:

```haskell
configurationDefault =
  Configuration
    { baseCurrency = USD
    , defaultCurrency = USD
    , dictionaries = Map.empty
    , banking = emptyBankingConfiguration
    , createdBy = System
    , isCreated = False
    }

emptyBankingConfiguration :: BankingConfiguration
emptyBankingConfiguration =
  BankingConfiguration
    { defaultIncomeCategory = Nothing
    , defaultExpenseCategory = Nothing
    , mccExpenseCategoryMap = Map.empty
    }
```

Export `BankingConfiguration (..)` and `emptyBankingConfiguration` from the module.

- [ ] **Step 4: Run test**

Run: `cabal test all --test-option='--match' --test-option='/configurationDefault has an empty banking/'`
Expected: PASS.

- [ ] **Step 5: Fix downstream fixture construction**

Grep the repo for places that construct a literal `Configuration { baseCurrency = … }` (the in-memory testkit fixture is the obvious one):

```bash
grep -rn "Configuration { baseCurrency" src/ test/
grep -rn "Configuration {baseCurrency" src/ test/
```

In every match, add `banking = emptyBankingConfiguration,`. Expected: one or two hits in `test/Testkit/InMemoryEventStore.hs` and maybe in projection tests.

- [ ] **Step 6: Run full suite**

Run: `just test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/Domain/Configuration/Projection.hs test/
git commit -m "feat(configuration): add BankingConfiguration sub-record

Additive only — the field is empty on every existing projection
until the Set*/MccMap events in the next task begin populating it."
```

---

## Task 4: Add the three new Configuration events

**Files:**
- Modify: `src/Domain/Configuration/Events.hs`

**Goal:** Wire `BankingDefaultIncomeCategorySet`, `BankingDefaultExpenseCategorySet`, and `BankingMccExpenseCategoryMapSet` into the aggregate's event sum type. No projection handling yet.

- [ ] **Step 1: Add the three records and their JSON splices**

In `src/Domain/Configuration/Events.hs`:

```haskell
import Data.Map.Strict (Map)
import Domain.Core.Types (..., CategoryId, MCC, ..., EntryName)

-- New events — append to the existing event list below the `Removed` event.

data BankingDefaultIncomeCategorySet = BankingDefaultIncomeCategorySet
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

data BankingDefaultExpenseCategorySet = BankingDefaultExpenseCategorySet
  { categoryId :: CategoryId
  }
  deriving (Show, Eq)

data BankingMccExpenseCategoryMapSet = BankingMccExpenseCategoryMapSet
  { mapping :: Map MCC CategoryId
  }
  deriving (Show, Eq)
```

At the bottom of the module add the `deriveJSON defaultOptions` splices for each record (after the existing splices).

Add all three to `configurationEvents`:

```haskell
configurationEvents :: [Name]
configurationEvents =
  [ ''ConfigurationCreated
  , ''BaseCurrencyChanged
  , ''DefaultCurrencyChanged
  , ''DictionaryEntryAdded
  , ''DictionaryEntryRenamed
  , ''DictionaryEntryRemoved
  , ''BankingDefaultIncomeCategorySet
  , ''BankingDefaultExpenseCategorySet
  , ''BankingMccExpenseCategoryMapSet
  ]
```

Add all three to the module export list (alongside the existing event exports).

- [ ] **Step 2: Build**

Run: `just build`
Expected: PASS. Adding constructors to the generated `ConfigurationEvent` sum type changes the set of valid `Either` matches in the projection — but `handleConfigurationEvent` uses named patterns with no wildcard, so GHC will report non-exhaustive pattern warnings under `-Werror`. That is resolved in the next task.

If the build actually fails on non-exhaustive, add a `_ -> config` catch-all temporarily in `handleConfigurationEvent` as a scratch measure *inside this commit* — then Task 5 replaces it with the real branches. Prefer not to: pushing the real handlers into this commit is equivalent effort. If you do add a catch-all, leave a `-- TODO: remove in Task 5` comment.

- [ ] **Step 3: Commit**

```bash
git add src/Domain/Configuration/Events.hs
git commit -m "feat(configuration): add banking default-category and mcc-map events"
```

---

## Task 5: Project the new events onto `BankingConfiguration`

**Files:**
- Modify: `src/Domain/Configuration/Projection.hs`
- Test: `test/Domain/Configuration/ProjectionSpec.hs` (extend)

**Goal:** Make the projection actually populate `banking` when the three new events arrive.

- [ ] **Step 1: Failing tests for each event**

In `test/Domain/Configuration/ProjectionSpec.hs`:

```haskell
describe "banking projection" $ do
  let entryA = unsafeDictionaryEntryId (UUID.fromWords 1 2 3 4)
      entryB = unsafeDictionaryEntryId (UUID.fromWords 5 6 7 8)

  it "BankingDefaultIncomeCategorySet sets the income slot" $ do
    let c =
          foldl
            (project configurationProjection)
            configurationDefault
            [ BankingDefaultIncomeCategorySetConfigurationEvent
                (BankingDefaultIncomeCategorySet entryA)
            ]
    c.banking.defaultIncomeCategory `shouldBe` Just entryA

  it "BankingDefaultExpenseCategorySet sets the expense slot" $ do
    let c =
          foldl
            (project configurationProjection)
            configurationDefault
            [ BankingDefaultExpenseCategorySetConfigurationEvent
                (BankingDefaultExpenseCategorySet entryB)
            ]
    c.banking.defaultExpenseCategory `shouldBe` Just entryB

  it "BankingMccExpenseCategoryMapSet replaces the mcc map wholesale" $ do
    let m1 = Map.singleton "5411" entryA
        m2 = Map.singleton "5812" entryB
        c =
          foldl
            (project configurationProjection)
            configurationDefault
            [ BankingMccExpenseCategoryMapSetConfigurationEvent (BankingMccExpenseCategoryMapSet m1)
            , BankingMccExpenseCategoryMapSetConfigurationEvent (BankingMccExpenseCategoryMapSet m2)
            ]
    c.banking.mccExpenseCategoryMap `shouldBe` m2
```

The `project` helper is the existing `Eventium.project :: Projection s e -> s -> e -> s`. If the test file already uses a wrapper, follow its style.

- [ ] **Step 2: Run — expect failure**

Run: `cabal test all --test-option='--match' --test-option='/banking projection/'`
Expected: FAIL — the events compile but the handler doesn't set the fields (old catch-all returns `config`), or the test helpers don't exist yet.

- [ ] **Step 3: Add handler branches**

In `handleConfigurationEvent`:

```haskell
handleConfigurationEvent config (BankingDefaultIncomeCategorySetConfigurationEvent evt) =
  config { banking = config.banking { defaultIncomeCategory = Just evt.categoryId } }

handleConfigurationEvent config (BankingDefaultExpenseCategorySetConfigurationEvent evt) =
  config { banking = config.banking { defaultExpenseCategory = Just evt.categoryId } }

handleConfigurationEvent config (BankingMccExpenseCategoryMapSetConfigurationEvent evt) =
  config { banking = config.banking { mccExpenseCategoryMap = evt.mapping } }
```

Remove the catch-all introduced in Task 4 (if any).

- [ ] **Step 4: Run test**

Run: `cabal test all --test-option='--match' --test-option='/banking projection/'`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Configuration/Projection.hs test/Domain/Configuration/ProjectionSpec.hs
git commit -m "feat(configuration): project banking events onto aggregate state"
```

---

## Task 6: Add the three new Configuration commands

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs`

**Goal:** Surface commands in the domain so the service layer has something to issue.

- [ ] **Step 1: Add command records**

In `src/Domain/Configuration/Commands.hs`:

```haskell
import Data.Map.Strict (Map)
import Domain.Core.Types (CategoryId, MCC, ...)

data SetBankingDefaultIncomeCategory = SetBankingDefaultIncomeCategory
  { categoryId :: CategoryId
  }

data SetBankingDefaultExpenseCategory = SetBankingDefaultExpenseCategory
  { categoryId :: CategoryId
  }

data SetBankingMccExpenseCategoryMap = SetBankingMccExpenseCategoryMap
  { mapping :: Map MCC CategoryId
  }
```

Add them to the generated `ConfigurationCommand` sum type (mirrors how existing commands are wired — look at how `AddDictionaryEntry` is included; add the same three `''Set…` names to the `configurationCommands :: [Name]` list if that's the pattern, or else extend whatever splice combines commands).

Export each record from the module.

- [ ] **Step 2: Build**

Run: `just build`
Expected: PASS. Command handler will need new branches — covered in Task 7.

- [ ] **Step 3: Commit**

```bash
git add src/Domain/Configuration/Commands.hs
git commit -m "feat(configuration): add banking Set* commands"
```

---

## Task 7: Command handler for Set* + extended `RemoveDictionaryEntry` guard

**Files:**
- Modify: `src/Domain/Configuration/CommandHandler.hs`
- Modify: `src/Domain/Configuration/Errors.hs`
- Test: `test/Domain/Configuration/CommandHandlerSpec.hs` (extend)

**Goal:** Validate the new commands and prevent removal of a dictionary entry that is referenced by `banking.*`.

- [ ] **Step 1: Failing tests for the new handler paths**

In `test/Domain/Configuration/CommandHandlerSpec.hs`, add (using the existing spec-building helpers — extend with whatever `runCommand` / `applyCommand` equivalent is already in the spec):

```haskell
describe "SetBankingDefaultIncomeCategory" $ do
  it "rejects a category not present in income-category dictionary" $ do
    -- seed a config with only expense entries
    -- issue SetBankingDefaultIncomeCategory with an id in the expense dict
    -- expect Left ConfigurationError matching "not a member of income-category"

  it "accepts a category present in income-category dictionary" $ do
    -- seed a config with an income entry
    -- issue SetBankingDefaultIncomeCategory with that id
    -- expect Right [ BankingDefaultIncomeCategorySetConfigurationEvent … ]

describe "SetBankingDefaultExpenseCategory" $ do
  -- Symmetric cases.

describe "SetBankingMccExpenseCategoryMap" $ do
  it "rejects a map referencing an unknown CategoryId" $ …
  it "accepts a map where every value is a known category" $ …

describe "RemoveDictionaryEntry guard" $ do
  it "rejects removing an entry bound as banking.defaultIncomeCategory" $ …
  it "rejects removing an entry bound as banking.defaultExpenseCategory" $ …
  it "rejects removing an entry referenced in banking.mccExpenseCategoryMap" $ …
  it "allows removal when not referenced" $ …
```

Follow the style of the existing `CommandHandlerSpec`. If it uses a `runHandler :: Configuration -> ConfigurationCommand -> Either DomainError [ConfigurationEvent]` helper, use it unchanged.

- [ ] **Step 2: Run — expect failures**

Run: `cabal test all --test-option='--match' --test-option='/SetBankingDefault\|SetBankingMccExpenseCategoryMap\|RemoveDictionaryEntry guard/'`
Expected: FAIL everywhere.

- [ ] **Step 3: Implement new handler branches**

In `src/Domain/Configuration/CommandHandler.hs`:

```haskell
import Domain.Configuration.Defaults (expenseCategoryDictId, incomeCategoryDictId)

-- After the existing RemoveDictionaryEntry branch, add:

handleConfigurationCommand config (SetBankingDefaultIncomeCategoryConfigurationCommand cmd) =
  requireEntryIn incomeCategoryDictId cmd.categoryId config
    >> Right [BankingDefaultIncomeCategorySetConfigurationEvent
                (BankingDefaultIncomeCategorySet cmd.categoryId)]

handleConfigurationCommand config (SetBankingDefaultExpenseCategoryConfigurationCommand cmd) =
  requireEntryIn expenseCategoryDictId cmd.categoryId config
    >> Right [BankingDefaultExpenseCategorySetConfigurationEvent
                (BankingDefaultExpenseCategorySet cmd.categoryId)]

handleConfigurationCommand config (SetBankingMccExpenseCategoryMapConfigurationCommand cmd) = do
  traverse_ (\cid -> requireEntryInEither cid config) (Map.elems cmd.mapping)
  Right [BankingMccExpenseCategoryMapSetConfigurationEvent (BankingMccExpenseCategoryMapSet cmd.mapping)]
```

Add the two helper predicates near the existing `dictionaryExists` / `entryExists` helpers:

```haskell
requireEntryIn :: DictionaryId -> CategoryId -> Configuration -> Either DomainError ()
requireEntryIn dictId entryId config =
  case Map.lookup dictId config.dictionaries of
    Nothing -> Left (ConfigurationError "Dictionary not found")
    Just dict
      | any (\e -> e.entryId == entryId) dict.entries -> Right ()
      | otherwise ->
          Left $ ConfigurationError
            $ "Entry " <> tshow entryId <> " is not a member of " <> unDictionaryId dictId

requireEntryInEither :: CategoryId -> Configuration -> Either DomainError ()
requireEntryInEither entryId config =
  let inIncome  = requireEntryIn incomeCategoryDictId  entryId config
      inExpense = requireEntryIn expenseCategoryDictId entryId config
   in case (inIncome, inExpense) of
        (Right (), _) -> Right ()
        (_, Right ()) -> Right ()
        (Left _, Left _) ->
          Left $ ConfigurationError
            $ "MCC map references " <> tshow entryId <> " which is not in any category dictionary"
```

Extend `RemoveDictionaryEntry` validation with a `banking`-usage check:

```haskell
handleConfigurationCommand config (RemoveDictionaryEntryConfigurationCommand cmd) = do
  unless (entryExists cmd.entryId cmd.dictionaryId config)
    $ Left (entryNotFound cmd.dictionaryId cmd.entryId)
  when (isLastEntry cmd.dictionaryId config)
    $ Left (lastEntryError cmd.dictionaryId)
  when (isBankingDefault cmd.entryId config)
    $ Left (ConfigurationError "Cannot remove the entry while it is set as a banking default")
  when (isInMccMap cmd.entryId config)
    $ Left (ConfigurationError "Cannot remove the entry while it is referenced by the MCC map")
  Right [RemoveDictionaryEntryEvent …]
  where
    isBankingDefault eid c =
      c.banking.defaultIncomeCategory == Just eid
        || c.banking.defaultExpenseCategory == Just eid
    isInMccMap eid c = elem eid (Map.elems c.banking.mccExpenseCategoryMap)
```

- [ ] **Step 4: Run tests**

Run: `cabal test all --test-option='--match' --test-option='/SetBankingDefault\|SetBankingMccExpenseCategoryMap\|RemoveDictionaryEntry guard/'`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Configuration/CommandHandler.hs src/Domain/Configuration/Errors.hs \
        test/Domain/Configuration/CommandHandlerSpec.hs
git commit -m "feat(configuration): validate banking Set* commands, guard entry removal"
```

---

## Task 8: Extend `ConfigurationData` read model with `banking`

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs`

**Goal:** Surface the new aggregate field in the read model so the HTTP response and the `BankImportService` both see it.

- [ ] **Step 1: Add `banking` to `ConfigurationData`**

```haskell
import Domain.Configuration.Projection (BankingConfiguration (..), emptyBankingConfiguration)

data ConfigurationData = ConfigurationData
  { baseCurrency    :: Currency
  , defaultCurrency :: Currency
  , dictionaries    :: Map DictionaryId DictionaryData
  , banking         :: BankingConfiguration   -- NEW
  , createdBy       :: CreatedBy
  , version         :: Int
  }
  deriving (Show, Eq, Generic)
```

Constructor is not exported (convention — check the module header). If the module exports `ConfigurationData (..)` keep it; otherwise add a `banking` accessor via record dot which already works with `NoFieldSelectors`.

- [ ] **Step 2: Fold the three new events in the read-model handler**

The existing `handleConfigurationReadModelEvent` pattern-matches by event constructor. Add branches that update the matching `ConfigurationData`:

```haskell
BankingDefaultIncomeCategorySetConfigurationEvent evt ->
  updateConfig cid $ \d -> d { banking = d.banking { defaultIncomeCategory = Just evt.categoryId } }

BankingDefaultExpenseCategorySetConfigurationEvent evt ->
  updateConfig cid $ \d -> d { banking = d.banking { defaultExpenseCategory = Just evt.categoryId } }

BankingMccExpenseCategoryMapSetConfigurationEvent evt ->
  updateConfig cid $ \d -> d { banking = d.banking { mccExpenseCategoryMap = evt.mapping } }
```

Initial `ConfigurationData` construction on `ConfigurationCreated` now sets `banking = emptyBankingConfiguration`.

- [ ] **Step 3: Build + test**

Run: `just build && just test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Application/ReadModels/Configuration.hs
git commit -m "feat(read-model): surface banking configuration in ConfigurationData"
```

---

## Task 9: Service operations for Set*

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs`

**Goal:** Expose typed service functions that wrap the three new commands (analogous to the existing `changeBaseCurrency` / `addDictionaryEntry`).

- [ ] **Step 1: Add three service functions**

```haskell
setBankingDefaultIncomeCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setBankingDefaultExpenseCategory :: UserId -> CategoryId -> AppM (Either DomainError ())
setBankingMccCategoryMap :: UserId -> Map MCC CategoryId -> AppM (Either DomainError ())
```

All three follow the existing clone-on-write pattern (`ensureClonedConfiguration` → `applyConfigurationCommand`). Copy from `addDictionaryEntry`.

- [ ] **Step 2: Build + test**

Run: `just build && just test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/Application/Services/ConfigurationService.hs
git commit -m "feat(service): setBanking* operations on ConfigurationService"
```

---

## Task 10: `PUT /api/configuration/banking` endpoint + read-endpoint extension

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs`
- Test: `test/Web/API/ConfigurationBankingAPISpec.hs` (create)

**Goal:** Expose partial-update endpoint for the two default-category slots and surface `banking` in the read endpoint.

- [ ] **Step 1: Failing integration test**

Create `test/Web/API/ConfigurationBankingAPISpec.hs` with:

- Setup fixture config with one "Other" entry in each category dictionary.
- `PUT /api/configuration/banking` with `{"defaultIncomeCategory": "<uuid-of-other>"}` → 200; follow-up `GET /api/configuration` shows `banking.defaultIncomeCategory` equal to that UUID.
- `PUT /api/configuration/banking` with a UUID that isn't in the income dictionary → 400 `CONFIGURATION_ERROR`.
- `PUT /api/configuration/banking` with `{}` → 200 no-op.
- Missing JWT → 401.

Use the in-memory test environment helpers already in the repo (mirror `test/Web/API/*Spec.hs` that exists for transactions or accounts).

- [ ] **Step 2: Run — expect failure**

Run: `cabal test all --test-option='--match' --test-option='/ConfigurationBankingAPI/'`
Expected: FAIL (endpoint doesn't exist).

- [ ] **Step 3: Add the endpoint**

In `src/Web/API/ConfigurationAPI.hs`:

- Extend the `type ConfigurationAPI` union with:

  ```haskell
  :<|> AuthProtect "jwt"
       :> "api" :> "configuration" :> "banking"
       :> ReqBody '[JSON] UpdateBankingRequest
       :> Put '[JSON] BankingConfigurationDTO
  ```

- Define the DTOs:

  ```haskell
  data UpdateBankingRequest = UpdateBankingRequest
    { defaultIncomeCategory  :: Maybe (Maybe UUID)  -- Nothing = absent, Just Nothing = null, Just (Just u) = present
    , defaultExpenseCategory :: Maybe (Maybe UUID)
    }
    deriving (Generic)

  instance FromJSON UpdateBankingRequest where
    parseJSON = withObject "UpdateBankingRequest" $ \v ->
      UpdateBankingRequest
        <$> v .:! "defaultIncomeCategory"
        <*> v .:! "defaultExpenseCategory"

  data BankingConfigurationDTO = BankingConfigurationDTO
    { defaultIncomeCategory  :: Maybe UUID
    , defaultExpenseCategory :: Maybe UUID
    , mccExpenseCategoryMap         :: Map Text UUID
    }
    deriving (Show, Eq, Generic)
  instance ToJSON BankingConfigurationDTO
  instance FromJSON BankingConfigurationDTO
  ```

  Helper:

  ```haskell
  toBankingDTO :: BankingConfiguration -> BankingConfigurationDTO
  toBankingDTO b =
    BankingConfigurationDTO
      { defaultIncomeCategory  = unDictionaryEntryId <$> b.defaultIncomeCategory
      , defaultExpenseCategory = unDictionaryEntryId <$> b.defaultExpenseCategory
      , mccExpenseCategoryMap         = Map.map unDictionaryEntryId b.mccExpenseCategoryMap
      }
  ```

- Handler:

  ```haskell
  updateBankingHandler :: AuthenticatedUser -> UpdateBankingRequest -> AppM BankingConfigurationDTO
  updateBankingHandler user req = do
    let uid = user.userId
    forM_ req.defaultIncomeCategory $ \case
      Just uuid -> do
        cid <- validateField "defaultIncomeCategory" $ mkDictionaryEntryId uuid
        ConfigurationService.setBankingDefaultIncomeCategory uid cid >>= orThrowDomain
      Nothing ->
        -- Null = clear: Phase 2 does not support clearing; reject as the spec says.
        throwDomainError (ConfigurationError "Clearing banking default categories is not supported in Phase 2")
    forM_ req.defaultExpenseCategory $ \case
      Just uuid -> …
      Nothing   -> …
    -- Read back
    result <- ConfigurationService.getConfigurationForUser uid
    case result of
      Right cfg -> return (toBankingDTO cfg.banking)
      Left err -> throwDomainError err
  ```

  `orThrowDomain :: Either DomainError a -> AppM a` — reuse whatever the existing handlers use (usually `either throwDomainError pure`).

- Extend the configuration read DTO (whatever `ConfigurationResponse` is called in this file) with `banking :: BankingConfigurationDTO` and populate it from `cfg.banking`.

- [ ] **Step 4: Run test**

Run: `cabal test all --test-option='--match' --test-option='/ConfigurationBankingAPI/'`
Expected: PASS.

- [ ] **Step 5: Run full suite**

Run: `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/Web/API/ConfigurationAPI.hs test/Web/API/ConfigurationBankingAPISpec.hs
git commit -m "feat(api): PUT /api/configuration/banking + read banking field"
```

---

## Task 11: Extend seeding AND cloning with banking configuration

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs` (both `seedDefaultConfiguration` and `cloneConfiguration`)
- Test: `test/Application/Services/ConfigurationServiceSpec.hs` (create or extend)

**Goal:** Two related flows.
1. Freshly seeded configurations land with `banking.defaultIncomeCategory = income.other.entryId`, `banking.defaultExpenseCategory = expense.other.entryId`, `banking.mccExpenseCategoryMap = defaultMccExpenseCategoryMap`.
2. When a user first edits a shared (system-default) configuration, `cloneConfiguration` (`src/Application/Services/ConfigurationService.hs:369-430`) must carry the source's `banking` field into the new per-user configuration. Without this, the user silently loses all banking defaults the first time they change any configuration field.

The current clone implementation replays dictionary entries via `AddDictionaryEntry` but does not emit any banking events — a Phase 2 regression if left uncorrected.

- [ ] **Step 1: Failing seed test**

```haskell
it "seedDefaultConfiguration populates banking defaults" $ do
  env <- createTestAppEnv
  runRIO env ConfigurationService.seedDefaultConfiguration
  cfgs <- readTVarIO env.configurationReadModel
  let [defaultCfg] = Map.elems cfgs.summaryData
  defaultCfg.banking.defaultIncomeCategory
    `shouldBe` Just income.other.entryId
  defaultCfg.banking.defaultExpenseCategory
    `shouldBe` Just expense.other.entryId
  defaultCfg.banking.mccExpenseCategoryMap `shouldBe` defaultMccExpenseCategoryMap
```

- [ ] **Step 2: Failing clone test**

```haskell
it "cloneConfiguration carries banking fields from source" $ do
  env <- createTestAppEnv
  runRIO env $ do
    -- seed the default (populates banking)
    ConfigurationService.seedDefaultConfiguration
    -- a user triggers clone-on-write via any config edit
    void $ ConfigurationService.changeDefaultCurrency testUserId EUR
  cfgs <- readTVarIO env.configurationReadModel
  let userCfg = Map.elems cfgs.summaryData !! 1  -- second config is the clone
  userCfg.banking.defaultIncomeCategory
    `shouldBe` Just income.other.entryId
  userCfg.banking.defaultExpenseCategory
    `shouldBe` Just expense.other.entryId
  userCfg.banking.mccExpenseCategoryMap `shouldBe` defaultMccExpenseCategoryMap
```

- [ ] **Step 3: Run — expect failure**

Run: `just test`
Expected: both new tests FAIL.

- [ ] **Step 4: Emit the three events at the end of `seedDefaultConfiguration`**

After the existing loops that add default income/expense entries:

```haskell
let cfgUuid = unConfigurationId seededConfigId
writer <- view eventStoreWriterL
reader <- view eventStoreReaderL
void . liftIO $ applyConfigurationCommand writer reader id cfgUuid
  (SetBankingDefaultIncomeCategoryConfigurationCommand
     (SetBankingDefaultIncomeCategory income.other.entryId))
void . liftIO $ applyConfigurationCommand writer reader id cfgUuid
  (SetBankingDefaultExpenseCategoryConfigurationCommand
     (SetBankingDefaultExpenseCategory expense.other.entryId))
void . liftIO $ applyConfigurationCommand writer reader id cfgUuid
  (SetBankingMccExpenseCategoryMapConfigurationCommand
     (SetBankingMccExpenseCategoryMap defaultMccExpenseCategoryMap))
```

Reuse helpers if the existing service has a tidier wrapper (it does; use it).

- [ ] **Step 5: Extend `cloneConfiguration` to copy banking fields**

Inside `cloneConfiguration` (around line 415, right after the dictionary-entries copy loop), add a banking-fields copy block that reads from the source `configData.banking` and issues the same three `Set*` commands against the new configuration:

```haskell
-- 3b. Copy banking configuration
let srcBanking = configData.banking
forM_ srcBanking.defaultIncomeCategory $ \eid -> do
  let cmd = SetBankingDefaultIncomeCategoryConfigurationCommand
              (SetBankingDefaultIncomeCategory eid)
  result <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
  case result of
    Left err -> logWarn $ "Failed to clone banking.defaultIncomeCategory: " <> displayShow err
    Right _  -> return ()

forM_ srcBanking.defaultExpenseCategory $ \eid -> do
  let cmd = SetBankingDefaultExpenseCategoryConfigurationCommand
              (SetBankingDefaultExpenseCategory eid)
  result <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
  case result of
    Left err -> logWarn $ "Failed to clone banking.defaultExpenseCategory: " <> displayShow err
    Right _  -> return ()

unless (Map.null srcBanking.mccExpenseCategoryMap) $ do
  let cmd = SetBankingMccExpenseCategoryMapConfigurationCommand
              (SetBankingMccExpenseCategoryMap srcBanking.mccExpenseCategoryMap)
  result <- liftIO $ applyConfigurationCommand writer reader id newConfigUuidVal cmd
  case result of
    Left err -> logWarn $ "Failed to clone banking.mccExpenseCategoryMap: " <> displayShow err
    Right _  -> return ()
```

Use `logWarn` (not `Left`) for individual banking-copy failures, mirroring the existing dictionary-entry-copy behavior at lines 412–414. The rationale: a clone that succeeds in copying dictionaries but fails a banking step should still produce a usable cloned config — the user gets the dictionaries and the missing banking field can be set later via `PUT /api/configuration/banking`.

- [ ] **Step 6: Run tests — both should now pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/Application/Services/ConfigurationService.hs \
        test/Application/Services/ConfigurationServiceSpec.hs
git commit -m "feat(configuration): seed and clone banking defaults + MCC map

seedDefaultConfiguration now emits SetBankingDefaultIncomeCategory,
SetBankingDefaultExpenseCategory, and SetBankingMccExpenseCategoryMap
after seeding the dictionaries. cloneConfiguration carries the three
banking fields forward from the source so clone-on-write does not
silently drop user-level banking state."
```

---

## Task 12: (removed)

Previously specified a one-shot startup backfill for pre-Phase-2 configurations. The deployment plan recreates the database instead, so no backfill ships. The task is intentionally left as a placeholder to preserve the numbering of Tasks 13–16.

---

## Task 13: Collapse `TransactionClassification` and change `BankTransaction.mcc` to `Maybe MCC`

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs`
- Modify: `src/Infrastructure/Banking/Monobank.hs`
- Modify: `test/Infrastructure/Banking/MonobankSpec.hs`
- Modify: `test/Application/Services/BankImportServiceSpec.hs` (compile fix only; real rewrite in Task 14)
- Modify: `test/Integration/BankImportWorkflowSpec.hs` (compile fix only)

**Goal:** Simplify the classifier to report direction only, and widen the MCC field. This task plus Task 14 ship together; between them the build may be intermediate.

- [ ] **Step 1: Update `Provider.hs`**

```haskell
data TransactionClassification
  = ClassifiedIncome
  | ClassifiedExpense
  deriving (Show, Eq)

data BankTransaction = BankTransaction
  { externalId     :: !ExternalTransactionId
  , accountId      :: !BankAccountId
  , time           :: !UTCTime
  , amount         :: !Rational
  , currencyCode   :: !Int
  , description    :: !Text
  , hold           :: !Bool
  , mcc            :: !(Maybe MCC)          -- was Maybe Int32
  , originalAmount :: !(Maybe Rational)
  , notes          :: !(Maybe Text)
  , categoryHint   :: !(Maybe Text)
  }
  deriving (Show, Eq)
```

Import `MCC` from `Domain.Core.Types`.

- [ ] **Step 2: Update `Monobank.hs`**

`monoClassifyTransaction`:

```haskell
monoClassifyTransaction :: BankTransaction -> TransactionClassification
monoClassifyTransaction tx
  | tx.amount >= 0 = ClassifiedIncome
  | otherwise      = ClassifiedExpense
```

`toProviderTransaction`:

```haskell
mcc = if ms.stmtMcc == 0 then Nothing else Just (T.pack (show ms.stmtMcc))
```

- [ ] **Step 3: Fix downstream fixture types**

Grep:

```bash
grep -rnE "mcc = Just [0-9]|mcc = Nothing|ClassifiedIncome Nothing|ClassifiedExpense Nothing" test/ src/
```

In `test/Infrastructure/Banking/MonobankSpec.hs`, `test/Testkit/BankingHelpers.hs` (if exists), `test/Application/Services/BankImportServiceSpec.hs`, `test/Integration/BankImportWorkflowSpec.hs`, and any other match:

- `mcc = Just 4829` → `mcc = Just "4829"`
- `ClassifiedIncome Nothing` → `ClassifiedIncome`
- `ClassifiedExpense Nothing` → `ClassifiedExpense`

Compilation-only fixes here; semantic rewrites land in Task 14.

- [ ] **Step 4: Build**

Run: `just build`
Expected: PASS. `BankImportService` likely fails to compile because `classifyEndpoints` still pattern-matches on `ClassifiedExpense (Maybe DictionaryEntryId)`. If that's the case, temporarily inline `const expenseCategoryArgument` — Task 14 replaces this code wholesale. Keep the branch compilable.

- [ ] **Step 5: Commit**

```bash
git add src/Infrastructure/Banking/Provider.hs \
        src/Infrastructure/Banking/Monobank.hs \
        src/Application/Services/BankImportService.hs \
        test/
git commit -m "refactor(banking): simplify classifier + widen mcc to Maybe MCC"
```

---

## Task 14: Move MCC→CategoryId resolution into `BankImportService`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`
- Modify: `src/Web/API/BankingAPI.hs`
- Modify: `test/Application/Services/BankImportServiceSpec.hs`
- Modify: `test/Integration/BankImportWorkflowSpec.hs`

**Goal:** Drop the `defaultCategory` parameter from `resync` / `importTransaction`; read the user's banking configuration; resolve category via MCC map + default fallback.

- [ ] **Step 1: Failing tests**

Extend `BankImportServiceSpec`:

```haskell
describe "category resolution" $ do
  it "maps a known MCC to the configured category id" $ do
    -- seed configuration with banking.mccExpenseCategoryMap containing "5411" -> foodId
    -- run importTransaction for a negative-amount tx with mcc = Just "5411"
    -- assert emitted InitiateTransfer has transferType = Expense foodId

  it "falls back to defaultExpenseCategory when MCC maps to a missing entry" $ do
    -- seed banking.mccExpenseCategoryMap with "5411" -> stale (not in dict)
    -- seed banking.defaultExpenseCategory = defaultId
    -- assert Expense defaultId

  it "falls back to defaultExpenseCategory when MCC is not in the map" $ …

  it "records a BankingError when no default is configured" $ …

  it "income direction mirrors the same resolution logic" $ …
```

- [ ] **Step 2: Run — expect failure**

Expected: FAIL.

- [ ] **Step 3: Rewrite `BankImportService`**

Drop the `DictionaryEntryId` parameter from `resync` and `importTransaction`. Add a helper:

```haskell
resolveCategory ::
  Configuration.BankingConfiguration ->
  Configuration.ConfigurationData ->
  TransactionClassification ->
  Maybe MCC ->
  Either DomainError CategoryId
resolveCategory banking cfg direction maybeMcc =
  let (dictId, deflt) = case direction of
        ClassifiedIncome  -> (incomeCategoryDictId,  banking.defaultIncomeCategory)
        ClassifiedExpense -> (expenseCategoryDictId, banking.defaultExpenseCategory)
      dictEntries = maybe Map.empty (.entries) (Map.lookup dictId cfg.dictionaries)
      mccHit = maybeMcc >>= \m -> Map.lookup m banking.mccExpenseCategoryMap
      existsInDict eid = Map.member eid dictEntries
   in case mccHit of
        Just eid | existsInDict eid -> Right eid
        _ -> case deflt of
          Just eid -> Right eid
          Nothing  -> Left $ BankingError $
            "No banking " <> directionName direction <> " category configured"
  where
    directionName ClassifiedIncome  = "income"
    directionName ClassifiedExpense = "expense"
```

Update `importTransaction` to:

1. After the dedup / account-matching block, look up `ConfigurationData` via `ConfigurationService.getConfigurationForUser`.
2. Pass `cfg.banking`, `cfg`, `direction`, `tx.mcc` to `resolveCategory`.
3. On `Left`, record in `AccountResyncResult.failures` and return `Right Nothing` (skip this tx, do not abort).
4. On `Right categoryId`, build `InitiateTransfer` with `transferType = Expense categoryId` / `Income categoryId`.

- [ ] **Step 4: Update `BankingAPI.resyncHandler`**

Drop `defaultCategory` from `ResyncRequest` (drop the field, drop the `validateField "defaultCategory"` call, drop the import of `mkDictionaryEntryId` if no longer used). `resync` no longer takes a `CategoryId` argument.

- [ ] **Step 5: Update tests**

Run the tests added in Step 1, plus:

- `BankImportWorkflowSpec`: drop `defaultCategory` from every call; seed banking configuration on fixture setup.

- [ ] **Step 6: Run tests**

Run: `just test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/Application/Services/BankImportService.hs \
        src/Web/API/BankingAPI.hs \
        test/
git commit -m "feat(banking): server-side MCC -> CategoryId resolution

Drop defaultCategory from resync; read banking configuration inline;
apply MCC map hit + existence check + default-fallback chain."
```

---

## Task 15: Fixture cleanup — `InMemoryEventStore` + misc

**Files:**
- Modify: `test/Testkit/InMemoryEventStore.hs`
- Modify: `test/Testkit/BankingHelpers.hs` (if it exists)

**Goal:** Ensure any `ConfigurationData` / `BankTransaction` fixtures that existed pre-Phase-2 are spelled consistently.

- [ ] **Step 1: Grep for stale patterns**

```bash
grep -rnE "BankingConfiguration\b" test/
grep -rn "mcc = Just" test/
grep -rn "ClassifiedIncome (Just" test/ src/
```

Any remaining matches should be fixed to use `emptyBankingConfiguration`, text-typed MCCs, and the direction-only classifier.

- [ ] **Step 2: Run full suite**

Run: `just test`
Expected: PASS.

- [ ] **Step 3: Commit (only if there were changes)**

```bash
git add test/
git commit -m "test: final fixture cleanup for Phase 2 types"
```

If the step found no changes, skip the commit.

---

## Task 16: Format, lint, CI-flags build

- [ ] **Step 1: Format**

Run: `just format`

- [ ] **Step 2: Lint**

Run: `just lint`
Fix any warnings reported.

- [ ] **Step 3: CI build**

Run: `cabal build -fci`
Expected: PASS with no warnings (the `-Werror` CI profile).

- [ ] **Step 4: Full test run**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Commit polish changes if any**

```bash
git add -A
git commit -m "chore: format + lint fixes for phase 2"
```

---

## Verification checklist (all must be true before merging)

- [ ] `just build` passes.
- [ ] `just test` passes.
- [ ] `just check` (ormolu + hlint) passes.
- [ ] `cabal build -fci` passes with `-Werror`.
- [ ] `grep -rn "defaultCategory" src/Web/API/BankingAPI.hs` returns no matches.
- [ ] `grep -rn "Maybe Int32" src/Infrastructure/Banking/Provider.hs` returns no matches (mcc is now `Maybe MCC`).
- [ ] `grep -rn "ClassifiedIncome (" src/ test/` returns no matches (classifier is direction-only; no more `Maybe CategoryId` payload).
- [ ] `grep -rn "configNamespace\|mkDeterministicEntryId\|incomeCategoryDictId\|expenseCategoryDictId" src/Application/Services/ConfigurationService.hs` returns only import-site matches, not definitions.
- [ ] `GET /api/configuration` response includes `banking` with `defaultIncomeCategory`, `defaultExpenseCategory`, and `mccExpenseCategoryMap`.
- [ ] `PUT /api/configuration/banking` with a valid `defaultIncomeCategory` UUID returns 200 and the subsequent `GET` reflects it.
- [ ] `POST /api/banking/resync` body no longer accepts `defaultCategory`; imports still categorize via MCC map + configured defaults.
- [ ] Fresh `seedDefaultConfiguration` leaves `banking.defaultIncomeCategory`, `banking.defaultExpenseCategory`, and `banking.mccExpenseCategoryMap` populated from `Domain.Configuration.Defaults`.
- [ ] `runBankingBackfill` on a pre-Phase-2 fixture populates `banking` and is a no-op on re-run.
