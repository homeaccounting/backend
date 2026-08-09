{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.CategoryDefaults
-- Description : Provider category defaults seeded into a user's category map.
--
-- The banking-import category defaults live in the Infrastructure banking layer
-- (not the Configuration domain) because they are provider knowledge: the
-- universal ISO-18245 MCC→category assignments plus each label-based provider's
-- own label→category defaults. 'defaultBankProviderExpenseCategoryMap' unions them into the
-- single 'BankProviderCategory'→'CategoryId' map that
-- 'Application.Services.ConfigurationService' seeds at configuration creation.
--
-- The category ids still come from 'Domain.Configuration.Defaults' (the default
-- expense categories), so a value here always references a real seeded category.
module Infrastructure.Banking.CategoryDefaults
  ( defaultMccExpenseCategoryMap,
    defaultBankProviderExpenseCategoryMap,
  )
where

import qualified Data.Map.Strict as Map
import Domain.Banking.Signal (BankProviderCategory, MCC, mkByLabel, mkByMcc, unsafeMcc)
import Domain.Configuration.Defaults (DefaultEntry (entryId), ExpenseDefaults (..), expense)
import Domain.Core.Types (CategoryId)
#ifdef PROVIDER_PRIVATBANK
import qualified Infrastructure.Banking.PrivatBank as PrivatBank
#endif
import RIO

-- | Default MCC assignments grouped by expense category — the maintainable
-- source of truth. Each category is named once and every code it should map to
-- is listed beneath it, so adding a code is a one-line change under the right
-- heading and a miscategorised code shows up under the wrong category at a
-- glance. Codes are 'unsafeMcc' of the numeric ISO-18245 value (validated
-- 'MCC' newtype); 'defaultMccExpenseCategoryMap' is derived by inverting this.
defaultCategoryMccs :: [(DefaultEntry, [MCC])]
defaultCategoryMccs =
  [ ( expense.groceries,
      [ unsafeMcc 5411, -- Grocery stores, supermarkets
        unsafeMcc 5422, -- Meat provisioners
        unsafeMcc 5451, -- Dairy product stores
        unsafeMcc 5462, -- Bakeries
        unsafeMcc 5499 -- Misc food stores
      ]
    ),
    ( expense.dining,
      [ unsafeMcc 5811, -- Caterers
        unsafeMcc 5812, -- Restaurants
        unsafeMcc 5813, -- Bars, nightclubs
        unsafeMcc 5814 -- Fast food
      ]
    ),
    ( expense.entertainment,
      [ unsafeMcc 5735, -- Record/music stores
        unsafeMcc 7832, -- Movie theaters
        unsafeMcc 7841, -- Video rental
        unsafeMcc 7922, -- Theatrical, concerts
        unsafeMcc 7929, -- Bands, orchestras
        unsafeMcc 7994, -- Video game arcades
        unsafeMcc 7996, -- Amusement parks
        unsafeMcc 7998, -- Aquariums, zoos
        unsafeMcc 7999 -- Recreation Services
      ]
    ),
    ( expense.fitness,
      [ unsafeMcc 7941, -- Sports clubs, fields
        unsafeMcc 7997 -- Country clubs, gyms
      ]
    ),
    ( expense.transport,
      [ unsafeMcc 4111, -- Local transit
        unsafeMcc 4112, -- Passenger railways
        unsafeMcc 4121, -- Taxis
        unsafeMcc 4131, -- Bus lines
        unsafeMcc 4789, -- Transportation services
        unsafeMcc 5511, -- Car dealers
        unsafeMcc 5533, -- Auto parts
        unsafeMcc 5541, -- Service stations (fuel)
        unsafeMcc 5542, -- Automated fuel dispensers
        unsafeMcc 7523, -- Parking
        unsafeMcc 7538, -- Auto service shops
        unsafeMcc 7542, -- Car washes
        unsafeMcc 7549 -- Towing
      ]
    ),
    ( expense.travel,
      [ unsafeMcc 4411, -- Cruise lines
        unsafeMcc 4511, -- Airlines
        unsafeMcc 4722, -- Travel agencies
        unsafeMcc 7011, -- Lodging, hotels
        unsafeMcc 7512 -- Car rentals
      ]
    ),
    ( expense.health,
      [ unsafeMcc 5912, -- Drug stores, pharmacies
        unsafeMcc 8011, -- Doctors
        unsafeMcc 8021, -- Dentists
        unsafeMcc 8031, -- Osteopaths
        unsafeMcc 8041, -- Chiropractors
        unsafeMcc 8042, -- Optometrists
        unsafeMcc 8043, -- Opticians
        unsafeMcc 8049, -- Podiatrists
        unsafeMcc 8050, -- Nursing/personal care
        unsafeMcc 8062, -- Hospitals
        unsafeMcc 8071, -- Medical labs
        unsafeMcc 8099 -- Medical services
      ]
    ),
    ( expense.education,
      [ unsafeMcc 5192, -- Books, periodicals, newspapers
        unsafeMcc 5942, -- Book stores
        unsafeMcc 8211, -- Elementary/secondary schools
        unsafeMcc 8220, -- Colleges, universities
        unsafeMcc 8241, -- Correspondence schools
        unsafeMcc 8244, -- Business/secretarial schools
        unsafeMcc 8249, -- Vocational schools
        unsafeMcc 8299 -- Educational services
      ]
    ),
    ( expense.clothing,
      [ unsafeMcc 5611, -- Men's clothing
        unsafeMcc 5621, -- Women's clothing
        unsafeMcc 5631, -- Women's accessories
        unsafeMcc 5641, -- Children's/infants' wear
        unsafeMcc 5651, -- Family clothing
        unsafeMcc 5655, -- Sports/riding apparel
        unsafeMcc 5661, -- Shoes
        unsafeMcc 5691, -- Men's & women's apparel
        unsafeMcc 5697, -- Tailors, alterations
        unsafeMcc 5699 -- Misc apparel & accessories
      ]
    ),
    ( expense.utilities,
      [ unsafeMcc 4814, -- Telecom services
        unsafeMcc 4815, -- Monthly telecom
        unsafeMcc 4816, -- Computer network/information services
        unsafeMcc 4899, -- Cable, satellite, pay TV
        unsafeMcc 4900 -- Utilities (electric, gas, water)
      ]
    ),
    ( expense.subscriptions,
      [ unsafeMcc 5968, -- Direct-marketing subscriptions
        unsafeMcc 5969 -- Direct marketing - other
      ]
    ),
    ( expense.household,
      [ unsafeMcc 5200, -- Home supply warehouse
        unsafeMcc 5211, -- Lumber, building materials
        unsafeMcc 5231, -- Glass, paint, wallpaper
        unsafeMcc 5251, -- Hardware stores
        unsafeMcc 5261, -- Nurseries, garden supply
        unsafeMcc 5712, -- Furniture
        unsafeMcc 5713, -- Floor covering
        unsafeMcc 5714, -- Drapery, upholstery
        unsafeMcc 5719, -- Misc home furnishings
        unsafeMcc 5722, -- Household appliance stores
        unsafeMcc 7623 -- A/C, refrigeration repair
      ]
    ),
    ( expense.electronics,
      [ unsafeMcc 4812, -- Telecom equipment & phone sales
        unsafeMcc 5045, -- Computers, peripherals
        unsafeMcc 5732, -- Electronics stores
        unsafeMcc 5734, -- Computer software stores
        unsafeMcc 5816, -- Digital goods - games
        unsafeMcc 5817, -- Digital goods - applications
        unsafeMcc 5818 -- Digital goods - large merchant
      ]
    ),
    ( expense.beauty,
      [ unsafeMcc 5977, -- Cosmetic stores
        unsafeMcc 7230, -- Barber & beauty shops
        unsafeMcc 7297, -- Massage parlors
        unsafeMcc 7298 -- Health & beauty spas
      ]
    ),
    ( expense.pets,
      [ unsafeMcc 742, -- Veterinary services
        unsafeMcc 5995 -- Pet shops, pet food
      ]
    ),
    ( expense.shopping,
      [ unsafeMcc 5300, -- Wholesale clubs
        unsafeMcc 5310, -- Discount stores
        unsafeMcc 5311, -- Department stores
        unsafeMcc 5331, -- Variety stores
        unsafeMcc 5399, -- Misc general merchandise
        unsafeMcc 5944, -- Jewelry
        unsafeMcc 5945 -- Hobby, toy, game shops
      ]
    ),
    ( expense.gifts,
      [ unsafeMcc 5947, -- Gift, card, novelty shops
        unsafeMcc 5992 -- Florists
      ]
    ),
    ( expense.insurance,
      [ unsafeMcc 5960, -- Direct marketing - insurance
        unsafeMcc 6300 -- Insurance sales, underwriting
      ]
    ),
    ( expense.charity,
      [unsafeMcc 8398] -- Charitable & social service orgs
    ),
    ( expense.taxesFees,
      [ unsafeMcc 4829, -- Money transfers (transfer fees)
        unsafeMcc 9211, -- Court costs
        unsafeMcc 9222, -- Fines
        unsafeMcc 9311, -- Tax payments
        unsafeMcc 9399 -- Government services
      ]
    ),
    ( expense.other,
      [ unsafeMcc 6051, -- Non-financial institutions (money orders, crypto)
        unsafeMcc 6540, -- Non-financial - stored value
        unsafeMcc 5964, -- Direct marketing - catalog
        unsafeMcc 5999 -- Misc specialty retail
      ]
    )
  ]

-- | Flat MCC→category seed, derived by inverting 'defaultCategoryMccs' (one
-- @(code, categoryId)@ entry per code).
defaultMccExpenseCategoryMap :: Map MCC CategoryId
defaultMccExpenseCategoryMap =
  Map.fromList
    [ (mcc, category.entryId)
    | (category, codes) <- defaultCategoryMccs,
      mcc <- codes
    ]

-- | The universal provider-category seed unioned into a user's category map at
-- configuration-seed time: the ISO-18245 MCC defaults as 'ByMcc' keys, plus
-- each compiled-in label-based provider's own label defaults as 'ByLabel' keys.
-- Each label-provider's term is CPP-guarded (mirroring
-- 'Infrastructure.Banking.Providers') so a build with that provider's flag off
-- simply omits its labels — the map is then just the ByMcc defaults. The MCC
-- defaults never collide with label keys since 'ByMcc' and 'ByLabel' keys are
-- structurally disjoint.
defaultBankProviderExpenseCategoryMap :: Map BankProviderCategory CategoryId
defaultBankProviderExpenseCategoryMap =
  Map.mapKeys mkByMcc defaultMccExpenseCategoryMap <> labelDefaults providerLabelMaps

-- | Every compiled-in label-based provider's pure @labelExpenseCategories@ binding.
-- The binding is CPP-guarded at the declaration level (mirroring
-- 'Infrastructure.Banking.Providers') so a build with a provider's flag off
-- contributes nothing — with all label providers off this is @[]@ and
-- 'defaultBankProviderExpenseCategoryMap' is just the ByMcc defaults. A new label provider
-- adds its @labelExpenseCategories@ to the guarded list here (this is the only place
-- that needs a CPP guard per label provider).
providerLabelMaps :: [Map Text CategoryId]
#ifdef PROVIDER_PRIVATBANK
providerLabelMaps = [PrivatBank.labelExpenseCategories]
#else
providerLabelMaps = []
#endif

-- | Re-key providers' pure label→category defaults as 'ByLabel' provider
-- categories, dropping any blank label 'mkByLabel' rejects (there are none in
-- practice).
labelDefaults :: [Map Text CategoryId] -> Map BankProviderCategory CategoryId
labelDefaults maps =
  Map.fromList
    [ (pc, cat)
    | labels <- maps,
      (label, cat) <- Map.toList labels,
      Just pc <- [mkByLabel label]
    ]
