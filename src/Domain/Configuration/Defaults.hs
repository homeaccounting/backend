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
-- specific: well-known dictionary IDs, default category entry names, and the
-- deterministic UUIDv5 helper that ties entries to stable IDs. (The banking
-- import category defaults that reference these ids live in the Infrastructure
-- banking layer — 'Infrastructure.Banking.CategoryDefaults' — not here.)
module Domain.Configuration.Defaults
  ( -- * UUIDv5 helpers
    configNamespace,
    mkDeterministicEntryId,

    -- * Well-known dictionary kinds
    incomeCategoryDictKind,
    expenseCategoryDictKind,

    -- * Default-entry value
    DefaultEntry (entryName, slug, entryId, role, parentId),

    -- * Expense namespace
    ExpenseDefaults (foodAndDining, housing, healthWellness, shoppingGoods, leisureTravel, groceries, dining, transport, utilities, rent, entertainment, fitness, health, education, clothing, insurance, subscriptions, household, travel, gifts, charity, taxesFees, beauty, pets, electronics, shopping, other),
    expense,

    -- * Income namespace
    IncomeDefaults (earned, passive, salary, freelance, investment, business, rental, gift, refund, other),
    income,

    -- * Derived lists (seed loop consumes these)
    defaultExpenseCategories,
    defaultIncomeCategories,

    -- * ID -> slug index (locale re-translation anchor)
    defaultCategorySlugsById,
  )
where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.UUID (UUID)
import qualified Data.UUID.V5 as UUID5
import Domain.Configuration.Dictionary (DictionaryKind (..), EntryRole (..), dictionaryKindSlug)
import Domain.Core.Types
  ( CategoryId,
    unsafeDictionaryEntryId,
  )
import RIO

-- | Deterministic-ID namespace for default configuration entries.
configNamespace :: UUID
configNamespace =
  UUID5.generateNamed UUID5.namespaceURL (BS.unpack $ encodeUtf8 "homeaccounting/config")

-- | Generate a deterministic 'CategoryId' from a dictionary kind and entry
--   name. Every invocation with the same inputs returns the same UUID. Keying
--   off the kind's stable slug (rather than the old id text) is a one-time
--   reseed; anchoring to the slug — the contractually-stable representation —
--   rather than the incidental 'Show' output means a future constructor rename
--   cannot silently reseed every default-category id.
mkDeterministicEntryId :: DictionaryKind -> Text -> CategoryId
mkDeterministicEntryId kind entryNameText =
  unsafeDictionaryEntryId
    $ UUID5.generateNamed configNamespace
    $ BS.unpack (encodeUtf8 (dictionaryKindSlug kind <> ":" <> entryNameText))

incomeCategoryDictKind :: DictionaryKind
incomeCategoryDictKind = IncomeKind

expenseCategoryDictKind :: DictionaryKind
expenseCategoryDictKind = ExpenseKind

-- | One default category entry; the name is what 'AddDictionaryEntry' will
--   see, the id is the deterministic 'CategoryId' that both the seed code and
--   the provider-category defaults (in 'Infrastructure.Banking.CategoryDefaults')
--   point to. A root or group node has @parentId = Nothing@; a child carries
--   @Just@ its group's 'entryId'.
data DefaultEntry = DefaultEntry
  { entryName :: !Text,
    slug :: !Text,
    entryId :: !CategoryId,
    role :: !EntryRole,
    parentId :: !(Maybe CategoryId)
  }
  deriving (Show, Eq)

-- | A root-level expense group (container, never assignable). The @slug@ is the
--   stable locale key; the id is STILL derived from the English name.
mkExpenseGroup :: Text -> Text -> DefaultEntry
mkExpenseGroup slug' n = DefaultEntry n slug' (mkDeterministicEntryId expenseCategoryDictKind n) GroupRole Nothing

-- | A root-level expense item (leaf, assignable).
mkExpense :: Text -> Text -> DefaultEntry
mkExpense slug' n = DefaultEntry n slug' (mkDeterministicEntryId expenseCategoryDictKind n) ItemRole Nothing

-- | A child expense item nested under the group whose id is @pid@.
mkExpenseChild :: CategoryId -> Text -> Text -> DefaultEntry
mkExpenseChild pid slug' n = DefaultEntry n slug' (mkDeterministicEntryId expenseCategoryDictKind n) ItemRole (Just pid)

-- | A root-level income group (container, never assignable).
mkIncomeGroup :: Text -> Text -> DefaultEntry
mkIncomeGroup slug' n = DefaultEntry n slug' (mkDeterministicEntryId incomeCategoryDictKind n) GroupRole Nothing

-- | A root-level income item (leaf, assignable).
mkIncome :: Text -> Text -> DefaultEntry
mkIncome slug' n = DefaultEntry n slug' (mkDeterministicEntryId incomeCategoryDictKind n) ItemRole Nothing

-- | A child income item nested under the group whose id is @pid@.
mkIncomeChild :: CategoryId -> Text -> Text -> DefaultEntry
mkIncomeChild pid slug' n = DefaultEntry n slug' (mkDeterministicEntryId incomeCategoryDictKind n) ItemRole (Just pid)

data ExpenseDefaults = ExpenseDefaults
  { -- Group nodes (containers, never assignable)
    foodAndDining :: !DefaultEntry,
    housing :: !DefaultEntry,
    healthWellness :: !DefaultEntry,
    shoppingGoods :: !DefaultEntry,
    leisureTravel :: !DefaultEntry,
    -- Leaves
    groceries :: !DefaultEntry,
    dining :: !DefaultEntry,
    transport :: !DefaultEntry,
    utilities :: !DefaultEntry,
    rent :: !DefaultEntry,
    entertainment :: !DefaultEntry,
    fitness :: !DefaultEntry,
    health :: !DefaultEntry,
    education :: !DefaultEntry,
    clothing :: !DefaultEntry,
    insurance :: !DefaultEntry,
    subscriptions :: !DefaultEntry,
    household :: !DefaultEntry,
    travel :: !DefaultEntry,
    gifts :: !DefaultEntry,
    charity :: !DefaultEntry,
    taxesFees :: !DefaultEntry,
    beauty :: !DefaultEntry,
    pets :: !DefaultEntry,
    electronics :: !DefaultEntry,
    shopping :: !DefaultEntry,
    other :: !DefaultEntry
  }

data IncomeDefaults = IncomeDefaults
  { -- Group nodes (containers, never assignable)
    earned :: !DefaultEntry,
    passive :: !DefaultEntry,
    -- Leaves
    salary :: !DefaultEntry,
    freelance :: !DefaultEntry,
    investment :: !DefaultEntry,
    business :: !DefaultEntry,
    rental :: !DefaultEntry,
    gift :: !DefaultEntry,
    refund :: !DefaultEntry,
    other :: !DefaultEntry
  }

-- Each name string appears exactly once, on the line that defines the
-- entry. The seed lists below (and the banking provider-category defaults in
-- 'Infrastructure.Banking.CategoryDefaults') reach the entry through the
-- 'expense' / 'income' namespace.
expense :: ExpenseDefaults
expense =
  ExpenseDefaults
    { foodAndDining = foodGroup,
      housing = housingGroup,
      healthWellness = wellnessGroup,
      shoppingGoods = goodsGroup,
      leisureTravel = leisureGroup,
      groceries = mkExpenseChild foodGroup.entryId "groceries" "Groceries",
      dining = mkExpenseChild foodGroup.entryId "dining" "Dining",
      transport = mkExpense "transport" "Transport",
      utilities = mkExpenseChild housingGroup.entryId "utilities" "Utilities",
      rent = mkExpenseChild housingGroup.entryId "rent" "Rent",
      entertainment = mkExpenseChild leisureGroup.entryId "entertainment" "Entertainment",
      fitness = mkExpenseChild wellnessGroup.entryId "fitness" "Fitness",
      health = mkExpenseChild wellnessGroup.entryId "health" "Health",
      education = mkExpense "education" "Education",
      clothing = mkExpenseChild goodsGroup.entryId "clothing" "Clothing",
      insurance = mkExpense "insurance" "Insurance",
      subscriptions = mkExpense "subscriptions" "Subscriptions",
      household = mkExpenseChild housingGroup.entryId "household" "Household",
      travel = mkExpenseChild leisureGroup.entryId "travel" "Travel",
      gifts = mkExpenseChild goodsGroup.entryId "gifts" "Gifts",
      charity = mkExpense "charity" "Charity",
      taxesFees = mkExpense "taxesAndFees" "Taxes & Fees",
      beauty = mkExpenseChild wellnessGroup.entryId "beautyAndPersonalCare" "Beauty & Personal Care",
      pets = mkExpense "pets" "Pets",
      electronics = mkExpenseChild goodsGroup.entryId "electronics" "Electronics",
      shopping = mkExpenseChild goodsGroup.entryId "shopping" "Shopping",
      other = mkExpense "other" "Other"
    }
  where
    foodGroup = mkExpenseGroup "food" "Food"
    housingGroup = mkExpenseGroup "housing" "Housing"
    wellnessGroup = mkExpenseGroup "wellness" "Wellness"
    goodsGroup = mkExpenseGroup "goods" "Goods"
    leisureGroup = mkExpenseGroup "leisure" "Leisure"

income :: IncomeDefaults
income =
  IncomeDefaults
    { earned = earnedGroup,
      passive = passiveGroup,
      salary = mkIncomeChild earnedGroup.entryId "salary" "Salary",
      freelance = mkIncomeChild earnedGroup.entryId "freelance" "Freelance",
      investment = mkIncomeChild passiveGroup.entryId "investment" "Investment",
      business = mkIncomeChild earnedGroup.entryId "business" "Business",
      rental = mkIncomeChild passiveGroup.entryId "rental" "Rental",
      gift = mkIncome "gift" "Gift",
      refund = mkIncome "refund" "Refund",
      other = mkIncome "other" "Other"
    }
  where
    earnedGroup = mkIncomeGroup "earned" "Earned"
    passiveGroup = mkIncomeGroup "passive" "Passive"

-- | Every default entry's stable locale slug, keyed by its deterministic id.
-- The ID anchor for locale re-translation: an entry counts as an untouched app
-- default only if its id is a key here. The slug (not the English name) is the
-- key into the localization catalog.
defaultCategorySlugsById :: Map CategoryId Text
defaultCategorySlugsById =
  Map.fromList
    [ (e.entryId, e.slug)
    | e <- defaultIncomeCategories <> defaultExpenseCategories
    ]

-- | Default expense categories in seed order. Every group node precedes its
-- children so the seed loop's parent-exists guard never rejects a child.
defaultExpenseCategories :: [DefaultEntry]
defaultExpenseCategories =
  [ -- Food group + children
    expense.foodAndDining,
    expense.groceries,
    expense.dining,
    -- Housing group + children
    expense.housing,
    expense.rent,
    expense.utilities,
    expense.household,
    -- Wellness group + children
    expense.healthWellness,
    expense.health,
    expense.fitness,
    expense.beauty,
    -- Goods group + children
    expense.shoppingGoods,
    expense.clothing,
    expense.electronics,
    expense.shopping,
    expense.gifts,
    -- Leisure group + children
    expense.leisureTravel,
    expense.entertainment,
    expense.travel,
    -- Standalone roots
    expense.transport,
    expense.subscriptions,
    expense.education,
    expense.insurance,
    expense.taxesFees,
    expense.charity,
    expense.pets,
    expense.other
  ]

-- | Default income categories in seed order. Every group node precedes its
-- children so the seed loop's parent-exists guard never rejects a child.
defaultIncomeCategories :: [DefaultEntry]
defaultIncomeCategories =
  [ -- Earned group + children
    income.earned,
    income.salary,
    income.freelance,
    income.business,
    -- Passive group + children
    income.passive,
    income.investment,
    income.rental,
    -- Standalone roots
    income.gift,
    income.refund,
    income.other
  ]
