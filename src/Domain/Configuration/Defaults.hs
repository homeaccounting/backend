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
    configNamespace,
    mkDeterministicEntryId,

    -- * Well-known dictionary IDs
    incomeCategoryDictId,
    expenseCategoryDictId,

    -- * Default-entry value
    DefaultEntry (entryName, entryId),

    -- * Expense namespace
    ExpenseDefaults (food, transport, utilities, rent, entertainment, fitness, health, education, clothing, insurance, subscriptions, household, travel, gifts, charity, taxesFees, other),
    expense,

    -- * Income namespace
    IncomeDefaults (salary, freelance, investment, business, rental, gift, refund, other),
    income,

    -- * Derived lists (seed loop consumes these)
    defaultExpenseCategories,
    defaultIncomeCategories,

    -- * Banking seed data
    defaultMccExpenseCategoryMap,
  )
where

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.UUID (UUID)
import qualified Data.UUID.V5 as UUID5
import Domain.Core.Types
  ( CategoryId,
    DictionaryId (..),
    MCC,
    unsafeDictionaryEntryId,
  )
import RIO

-- | Deterministic-ID namespace for default configuration entries.
configNamespace :: UUID
configNamespace =
  UUID5.generateNamed UUID5.namespaceURL (BS.unpack $ encodeUtf8 "homeaccounting/config")

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
  { entryName :: !Text,
    entryId :: !CategoryId
  }
  deriving (Show, Eq)

mkExpense :: Text -> DefaultEntry
mkExpense n = DefaultEntry n (mkDeterministicEntryId expenseCategoryDictId n)

mkIncome :: Text -> DefaultEntry
mkIncome n = DefaultEntry n (mkDeterministicEntryId incomeCategoryDictId n)

data ExpenseDefaults = ExpenseDefaults
  { food :: !DefaultEntry,
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
    other :: !DefaultEntry
  }

data IncomeDefaults = IncomeDefaults
  { salary :: !DefaultEntry,
    freelance :: !DefaultEntry,
    investment :: !DefaultEntry,
    business :: !DefaultEntry,
    rental :: !DefaultEntry,
    gift :: !DefaultEntry,
    refund :: !DefaultEntry,
    other :: !DefaultEntry
  }

-- Each name string appears exactly once, on the line that defines the
-- entry. The seed list and the MCC map below reach the entry through the
-- 'expense' / 'income' namespace.
expense :: ExpenseDefaults
expense =
  ExpenseDefaults
    { food = mkExpense "Food",
      transport = mkExpense "Transport",
      utilities = mkExpense "Utilities",
      rent = mkExpense "Rent",
      entertainment = mkExpense "Entertainment",
      fitness = mkExpense "Fitness",
      health = mkExpense "Health",
      education = mkExpense "Education",
      clothing = mkExpense "Clothing",
      insurance = mkExpense "Insurance",
      subscriptions = mkExpense "Subscriptions",
      household = mkExpense "Household",
      travel = mkExpense "Travel",
      gifts = mkExpense "Gifts",
      charity = mkExpense "Charity",
      taxesFees = mkExpense "Taxes & Fees",
      other = mkExpense "Other"
    }

income :: IncomeDefaults
income =
  IncomeDefaults
    { salary = mkIncome "Salary",
      freelance = mkIncome "Freelance",
      investment = mkIncome "Investment",
      business = mkIncome "Business",
      rental = mkIncome "Rental",
      gift = mkIncome "Gift",
      refund = mkIncome "Refund",
      other = mkIncome "Other"
    }

defaultExpenseCategories :: [DefaultEntry]
defaultExpenseCategories =
  [ expense.food,
    expense.transport,
    expense.utilities,
    expense.rent,
    expense.entertainment,
    expense.fitness,
    expense.health,
    expense.education,
    expense.clothing,
    expense.insurance,
    expense.subscriptions,
    expense.household,
    expense.travel,
    expense.gifts,
    expense.charity,
    expense.taxesFees,
    expense.other
  ]

defaultIncomeCategories :: [DefaultEntry]
defaultIncomeCategories =
  [ income.salary,
    income.freelance,
    income.investment,
    income.business,
    income.rental,
    income.gift,
    income.refund,
    income.other
  ]

defaultMccExpenseCategoryMap :: Map MCC CategoryId
defaultMccExpenseCategoryMap =
  Map.fromList
    [ ("5411", expense.food.entryId), -- Grocery stores, supermarkets
      ("5499", expense.food.entryId), -- Misc food stores
      ("5812", expense.food.entryId), -- Restaurants
      ("5814", expense.food.entryId), -- Fast food
      ("5813", expense.entertainment.entryId), -- Bars, nightclubs
      ("7997", expense.fitness.entryId), -- Country clubs, gyms, sports clubs
      ("5541", expense.transport.entryId), -- Service stations (fuel)
      ("5542", expense.transport.entryId), -- Automated fuel dispensers
      ("4111", expense.transport.entryId), -- Local transit
      ("4121", expense.transport.entryId), -- Taxis
      ("4131", expense.transport.entryId), -- Bus lines
      ("7523", expense.transport.entryId), -- Parking
      ("7542", expense.transport.entryId), -- Car washes
      ("4511", expense.travel.entryId), -- Airlines
      ("4722", expense.travel.entryId), -- Travel agencies
      ("7011", expense.travel.entryId), -- Lodging
      ("5912", expense.health.entryId), -- Drug stores, pharmacies
      ("8011", expense.health.entryId), -- Doctors
      ("8062", expense.health.entryId), -- Hospitals
      ("8099", expense.health.entryId), -- Medical services
      ("8220", expense.education.entryId), -- Colleges, universities
      ("8299", expense.education.entryId), -- Educational services
      ("5651", expense.clothing.entryId), -- Family clothing
      ("5691", expense.clothing.entryId), -- Apparel
      ("5661", expense.clothing.entryId), -- Shoes
      ("4900", expense.utilities.entryId), -- Utilities
      ("4814", expense.utilities.entryId), -- Telecom services
      ("4815", expense.utilities.entryId), -- Cable/satellite
      ("4829", expense.other.entryId), -- Wire transfers
      ("5968", expense.subscriptions.entryId), -- Direct-marketing subscriptions
      ("5947", expense.gifts.entryId), -- Gift shops
      ("8398", expense.charity.entryId), -- Charities
      ("9311", expense.taxesFees.entryId), -- Tax payments
      ("5200", expense.household.entryId), -- Home supply
      ("5712", expense.household.entryId), -- Furniture
      ("5999", expense.other.entryId) -- Misc specialty
    ]
