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
    DefaultEntry (entryName, entryId, role, parentId),

    -- * Expense namespace
    ExpenseDefaults (foodAndDining, housing, healthWellness, shoppingGoods, leisureTravel, groceries, dining, transport, utilities, rent, entertainment, fitness, health, education, clothing, insurance, subscriptions, household, travel, gifts, charity, taxesFees, beauty, pets, electronics, shopping, other),
    expense,

    -- * Income namespace
    IncomeDefaults (earned, passive, salary, freelance, investment, business, rental, gift, refund, other),
    income,

    -- * Derived lists (seed loop consumes these)
    defaultExpenseCategories,
    defaultIncomeCategories,
  )
where

import qualified Data.ByteString as BS
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
    entryId :: !CategoryId,
    role :: !EntryRole,
    parentId :: !(Maybe CategoryId)
  }
  deriving (Show, Eq)

-- | A root-level expense group (container, never assignable).
mkExpenseGroup :: Text -> DefaultEntry
mkExpenseGroup n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictKind n) GroupRole Nothing

-- | A root-level expense item (leaf, assignable).
mkExpense :: Text -> DefaultEntry
mkExpense n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictKind n) ItemRole Nothing

-- | A child expense item nested under the group whose id is @pid@.
mkExpenseChild :: CategoryId -> Text -> DefaultEntry
mkExpenseChild pid n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictKind n) ItemRole (Just pid)

-- | A root-level income group (container, never assignable).
mkIncomeGroup :: Text -> DefaultEntry
mkIncomeGroup n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictKind n) GroupRole Nothing

-- | A root-level income item (leaf, assignable).
mkIncome :: Text -> DefaultEntry
mkIncome n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictKind n) ItemRole Nothing

-- | A child income item nested under the group whose id is @pid@.
mkIncomeChild :: CategoryId -> Text -> DefaultEntry
mkIncomeChild pid n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictKind n) ItemRole (Just pid)

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
      groceries = mkExpenseChild foodGroup.entryId "Groceries",
      dining = mkExpenseChild foodGroup.entryId "Dining",
      transport = mkExpense "Transport",
      utilities = mkExpenseChild housingGroup.entryId "Utilities",
      rent = mkExpenseChild housingGroup.entryId "Rent",
      entertainment = mkExpenseChild leisureGroup.entryId "Entertainment",
      fitness = mkExpenseChild wellnessGroup.entryId "Fitness",
      health = mkExpenseChild wellnessGroup.entryId "Health",
      education = mkExpense "Education",
      clothing = mkExpenseChild goodsGroup.entryId "Clothing",
      insurance = mkExpense "Insurance",
      subscriptions = mkExpense "Subscriptions",
      household = mkExpenseChild housingGroup.entryId "Household",
      travel = mkExpenseChild leisureGroup.entryId "Travel",
      gifts = mkExpenseChild goodsGroup.entryId "Gifts",
      charity = mkExpense "Charity",
      taxesFees = mkExpense "Taxes & Fees",
      beauty = mkExpenseChild wellnessGroup.entryId "Beauty & Personal Care",
      pets = mkExpense "Pets",
      electronics = mkExpenseChild goodsGroup.entryId "Electronics",
      shopping = mkExpenseChild goodsGroup.entryId "Shopping",
      other = mkExpense "Other"
    }
  where
    foodGroup = mkExpenseGroup "Food"
    housingGroup = mkExpenseGroup "Housing"
    wellnessGroup = mkExpenseGroup "Wellness"
    goodsGroup = mkExpenseGroup "Goods"
    leisureGroup = mkExpenseGroup "Leisure"

income :: IncomeDefaults
income =
  IncomeDefaults
    { earned = earnedGroup,
      passive = passiveGroup,
      salary = mkIncomeChild earnedGroup.entryId "Salary",
      freelance = mkIncomeChild earnedGroup.entryId "Freelance",
      investment = mkIncomeChild passiveGroup.entryId "Investment",
      business = mkIncomeChild earnedGroup.entryId "Business",
      rental = mkIncomeChild passiveGroup.entryId "Rental",
      gift = mkIncome "Gift",
      refund = mkIncome "Refund",
      other = mkIncome "Other"
    }
  where
    earnedGroup = mkIncomeGroup "Earned"
    passiveGroup = mkIncomeGroup "Passive"

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
