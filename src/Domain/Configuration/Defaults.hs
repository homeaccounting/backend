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
    ExpenseDefaults (food, dining, transport, utilities, rent, entertainment, fitness, health, education, clothing, insurance, subscriptions, household, travel, gifts, charity, taxesFees, beauty, pets, electronics, shopping, other),
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
      dining = mkExpense "Dining",
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
      beauty = mkExpense "Beauty & Personal Care",
      pets = mkExpense "Pets",
      electronics = mkExpense "Electronics",
      shopping = mkExpense "Shopping",
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
    expense.dining,
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
    expense.beauty,
    expense.pets,
    expense.electronics,
    expense.shopping,
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

-- | Default MCC assignments grouped by expense category — the maintainable
-- source of truth. Each category is named once and every code it should map to
-- is listed beneath it, so adding a code is a one-line change under the right
-- heading and a miscategorised code shows up under the wrong category at a
-- glance. 'defaultMccExpenseCategoryMap' is derived from this by inverting it.
defaultCategoryMccs :: [(DefaultEntry, [MCC])]
defaultCategoryMccs =
  [ ( expense.food,
      [ "5411", -- Grocery stores, supermarkets
        "5422", -- Meat provisioners
        "5451", -- Dairy product stores
        "5462", -- Bakeries
        "5499" -- Misc food stores
      ]
    ),
    ( expense.dining,
      [ "5811", -- Caterers
        "5812", -- Restaurants
        "5813", -- Bars, nightclubs
        "5814" -- Fast food
      ]
    ),
    ( expense.entertainment,
      [ "5735", -- Record/music stores
        "7832", -- Movie theaters
        "7841", -- Video rental
        "7922", -- Theatrical, concerts
        "7929", -- Bands, orchestras
        "7994", -- Video game arcades
        "7996", -- Amusement parks
        "7998" -- Aquariums, zoos
      ]
    ),
    ( expense.fitness,
      [ "7941", -- Sports clubs, fields
        "7997" -- Country clubs, gyms
      ]
    ),
    ( expense.transport,
      [ "4111", -- Local transit
        "4112", -- Passenger railways
        "4121", -- Taxis
        "4131", -- Bus lines
        "4789", -- Transportation services
        "5511", -- Car dealers
        "5533", -- Auto parts
        "5541", -- Service stations (fuel)
        "5542", -- Automated fuel dispensers
        "7523", -- Parking
        "7538", -- Auto service shops
        "7542", -- Car washes
        "7549" -- Towing
      ]
    ),
    ( expense.travel,
      [ "4411", -- Cruise lines
        "4511", -- Airlines
        "4722", -- Travel agencies
        "7011", -- Lodging, hotels
        "7512" -- Car rentals
      ]
    ),
    ( expense.health,
      [ "5912", -- Drug stores, pharmacies
        "8011", -- Doctors
        "8021", -- Dentists
        "8031", -- Osteopaths
        "8041", -- Chiropractors
        "8042", -- Optometrists
        "8043", -- Opticians
        "8049", -- Podiatrists
        "8050", -- Nursing/personal care
        "8062", -- Hospitals
        "8071", -- Medical labs
        "8099" -- Medical services
      ]
    ),
    ( expense.education,
      [ "5192", -- Books, periodicals, newspapers
        "5942", -- Book stores
        "8211", -- Elementary/secondary schools
        "8220", -- Colleges, universities
        "8241", -- Correspondence schools
        "8244", -- Business/secretarial schools
        "8249", -- Vocational schools
        "8299" -- Educational services
      ]
    ),
    ( expense.clothing,
      [ "5611", -- Men's clothing
        "5621", -- Women's clothing
        "5631", -- Women's accessories
        "5641", -- Children's/infants' wear
        "5651", -- Family clothing
        "5655", -- Sports/riding apparel
        "5661", -- Shoes
        "5691", -- Men's & women's apparel
        "5697", -- Tailors, alterations
        "5699" -- Misc apparel & accessories
      ]
    ),
    ( expense.utilities,
      [ "4814", -- Telecom services
        "4815", -- Monthly telecom
        "4816", -- Computer network/information services
        "4899", -- Cable, satellite, pay TV
        "4900" -- Utilities (electric, gas, water)
      ]
    ),
    ( expense.subscriptions,
      [ "5968", -- Direct-marketing subscriptions
        "5969" -- Direct marketing - other
      ]
    ),
    ( expense.household,
      [ "5200", -- Home supply warehouse
        "5211", -- Lumber, building materials
        "5231", -- Glass, paint, wallpaper
        "5251", -- Hardware stores
        "5261", -- Nurseries, garden supply
        "5712", -- Furniture
        "5713", -- Floor covering
        "5714", -- Drapery, upholstery
        "5719", -- Misc home furnishings
        "5722", -- Household appliance stores
        "7623" -- A/C, refrigeration repair
      ]
    ),
    ( expense.electronics,
      [ "4812", -- Telecom equipment & phone sales
        "5045", -- Computers, peripherals
        "5732", -- Electronics stores
        "5734", -- Computer software stores
        "5816", -- Digital goods - games
        "5817", -- Digital goods - applications
        "5818" -- Digital goods - large merchant
      ]
    ),
    ( expense.beauty,
      [ "5977", -- Cosmetic stores
        "7230", -- Barber & beauty shops
        "7297", -- Massage parlors
        "7298" -- Health & beauty spas
      ]
    ),
    ( expense.pets,
      [ "0742", -- Veterinary services
        "5995" -- Pet shops, pet food
      ]
    ),
    ( expense.shopping,
      [ "5300", -- Wholesale clubs
        "5310", -- Discount stores
        "5311", -- Department stores
        "5331", -- Variety stores
        "5399", -- Misc general merchandise
        "5944", -- Jewelry
        "5945" -- Hobby, toy, game shops
      ]
    ),
    ( expense.gifts,
      [ "5947", -- Gift, card, novelty shops
        "5992" -- Florists
      ]
    ),
    ( expense.insurance,
      [ "5960", -- Direct marketing - insurance
        "6300" -- Insurance sales, underwriting
      ]
    ),
    ( expense.charity,
      ["8398"] -- Charitable & social service orgs
    ),
    ( expense.taxesFees,
      [ "4829", -- Money transfers (transfer fees)
        "9211", -- Court costs
        "9222", -- Fines
        "9311", -- Tax payments
        "9399" -- Government services
      ]
    ),
    ( expense.other,
      [ "6051", -- Non-financial institutions (money orders, crypto)
        "6540", -- Non-financial - stored value
        "5964", -- Direct marketing - catalog
        "5999" -- Misc specialty retail
      ]
    )
  ]

-- | Flat MCC→category seed consumed by the banking import flow, derived by
-- inverting 'defaultCategoryMccs' (one @(code, categoryId)@ entry per code).
defaultMccExpenseCategoryMap :: Map MCC CategoryId
defaultMccExpenseCategoryMap =
  Map.fromList
    [ (code, category.entryId)
    | (category, codes) <- defaultCategoryMccs,
      code <- codes
    ]
