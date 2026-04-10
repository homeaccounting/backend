{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.StorePropertySpec (spec) where

import Data.List (minimum)
import Data.Time (Day, addDays, diffDays, fromGregorian, toModifiedJulianDay)
import Infrastructure.ExchangeRate.Store (lookupNearestDate)
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Arbitrary instance for Day — generates dates within a reasonable range.
instance Arbitrary Day where
  arbitrary = fromGregorian <$> choose (2000, 2030) <*> choose (1, 12) <*> choose (1, 28)
  shrink day = [addDays (-1) day, addDays 1 day]

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.Store" $ do
  describe "lookupNearestDate" $ do
    prop "exact match always returns that date"
      $ \(dates :: [Day]) (target :: Day) ->
        let dayMap = Map.fromList [(d, d) | d <- target : dates]
         in lookupNearestDate dayMap target === Just (target, target)

    prop "prefers earlier date over later when equidistant"
      $ \(Positive n :: Positive Integer) ->
        let target = fromGregorian 2025 6 15
            earlier = addDays (negate (fromIntegral n)) target
            later = addDays (fromIntegral n) target
            dayMap = Map.fromList [(earlier, "early" :: Text), (later, "late")]
         in fmap fst (lookupNearestDate dayMap target) === Just earlier

    prop "returns Nothing for empty map"
      $ \(target :: Day) ->
        lookupNearestDate (Map.empty :: Map Day ()) target === Nothing

    prop "result date is always the closest to target"
      $ \(entries :: [(Day, Int)]) (target :: Day) ->
        not (null entries) ==>
          let dayMap = Map.fromList entries
           in case lookupNearestDate dayMap target of
                Nothing -> property False
                Just (foundDay, _) ->
                  let foundDist = abs (diffDays target foundDay)
                      minDist = minimum [abs (diffDays target d) | d <- Map.keys dayMap]
                   in foundDist === minDist

    prop "single-element map always returns that element"
      $ \(day :: Day) (val :: Int) (target :: Day) ->
        lookupNearestDate (Map.singleton day val) target === Just (day, val)
