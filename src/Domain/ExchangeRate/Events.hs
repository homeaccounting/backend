{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.ExchangeRate.Events
-- Description : Exchange-rate-publication domain events.
--
-- The business date (the day the rates are for) is carried in the
-- payload as @at :: Day@, matching the bare-preposition convention
-- (alongside @by@ on user-initiated events).
--
-- Follows the two-tier eventium pattern used by the Account,
-- Transaction, User and Configuration bounded contexts:
--
--   1. Individual event records (e.g. 'ExchangeRatesPublished') are
--      defined here.
--   2. 'exchangeRateEvents' — a Template Haskell name list — enumerates
--      them for eventium's sum-type machinery.
--   3. The 'ExchangeRateEvent' sum type is generated in
--      "Domain.ExchangeRate.Projection" via 'constructSumType' with the
--      @AppendTypeNameToTags@ tag rule, mirroring Account/Transaction.
module Domain.ExchangeRate.Events
  ( -- * Event List
    exchangeRateEvents,

    -- * ExchangeRate Events
    ExchangeRatesPublished (..),

    -- * Types
    ExchangeRateMap,
    Provider (..),
    unProvider,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Time (Day)
import Domain.Core.Types (Currency, ExchangeRate)
import Language.Haskell.TH (Name)
import RIO

-- | Map from a currency pair to its exchange rate.
type ExchangeRateMap = Map (Currency, Currency) ExchangeRate

-- | Name of an exchange-rate provider (e.g. @"ecb"@, @"nbu"@).
--
-- Wraps 'Text' so the same identifier is used consistently as:
--   * the config key in 'Infrastructure.Config.ExchangeRateConfig',
--   * the 'RateProvider' name,
--   * the per-provider event-stream key, and
--   * the read-model lookup key.
--
-- Serializes to/from JSON as a bare string for wire compatibility.
newtype Provider = Provider Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (IsString, FromJSON, ToJSON, Display)

-- | Extract the underlying text identifier.
unProvider :: Provider -> Text
unProvider (Provider t) = t

-- -----------------------------------------------------------------------------
-- ExchangeRate Events
-- -----------------------------------------------------------------------------

-- | Event emitted when a set of exchange rates is published by a provider.
--
-- @at@ is the business date the rates are for.
data ExchangeRatesPublished = ExchangeRatesPublished
  { provider :: !Provider,
    rates :: !ExchangeRateMap,
    at :: !Day
  }
  deriving (Show, Eq)

deriveJSON defaultOptions ''ExchangeRatesPublished

-- -----------------------------------------------------------------------------
-- Event List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all exchange-rate event type names for Template Haskell processing.
--
-- Used by eventium's Template Haskell machinery to generate the
-- 'Domain.ExchangeRate.Projection.ExchangeRateEvent' sum type and, via
-- @Domain.Models@, to contribute to the unified 'AccountingEvent' sum
-- type.
exchangeRateEvents :: [Name]
exchangeRateEvents =
  [ ''ExchangeRatesPublished
  ]
