{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.ExchangeRatePropertySpec
-- Description : Property test (red) for the exchange-rate read model's
-- nearest-date lookup.
--
-- Semantics under test:
--
--   For any non-empty map keyed by 'Day' and any query day @d@,
--   'lookupNearestDate' returns @Just (best, v)@ where @best@ minimises
--   @abs (diffDays d best)@, breaking ties by preferring the earlier
--   day.
module Application.ReadModels.ExchangeRatePropertySpec (spec) where

import Application.ReadModels.ExchangeRate (lookupNearestDate)
import Data.List (minimum)
import Data.Time (Day, addDays, diffDays, fromGregorian)
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.Generators ()

spec :: Spec
spec = describe "Application.ReadModels.ExchangeRate.lookupNearestDate" $ do
  prop "exact match always returns that date"
    $ \(dates :: [Day]) (target :: Day) ->
      let dayMap = Map.fromList [(d, d) | d <- target : dates]
       in lookupNearestDate dayMap target === Just (target, target)

  prop "returns Nothing for empty map"
    $ \(target :: Day) ->
      lookupNearestDate (Map.empty :: Map Day ()) target === Nothing

  prop "single-element map always returns that element"
    $ \(day :: Day) (val :: Int) (target :: Day) ->
      lookupNearestDate (Map.singleton day val) target === Just (day, val)

  prop "prefers the earlier date when equidistant"
    $ \(Positive n :: Positive Integer) ->
      let target = fromGregorian 2026 6 15
          earlier = addDays (negate (fromIntegral n)) target
          later = addDays (fromIntegral n) target
          dayMap = Map.fromList [(earlier, "early" :: Text), (later, "late")]
       in fmap fst (lookupNearestDate dayMap target) === Just earlier

  prop "returned date minimises absolute distance to target"
    $ \(entries :: [(Day, Int)]) (target :: Day) ->
      not (null entries) ==>
        let dayMap = Map.fromList entries
         in case lookupNearestDate dayMap target of
              Nothing -> property False
              Just (foundDay, _) ->
                let foundDist = abs (diffDays target foundDay)
                    minDist = minimum [abs (diffDays target d) | d <- Map.keys dayMap]
                 in foundDist === minDist
