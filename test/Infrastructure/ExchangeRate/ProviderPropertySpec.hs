{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.ProviderPropertySpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateValue)
import Infrastructure.ExchangeRate.Provider (deriveCrossRates, getRate)
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Generate a non-empty subset of non-base currencies with positive rates.
genBaseRates :: Currency -> Gen (Map Currency Rational)
genBaseRates base = do
  let others = filter (/= base) [minBound .. maxBound]
  selected <- sublistOf others `suchThat` (not . null)
  rates <- mapM (\c -> (c,) . toRational <$> (choose (0.01, 1000.0) :: Gen Double)) selected
  pure $ Map.fromList rates

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.Provider" $ do
  describe "deriveCrossRates" $ do
    prop "produces N*(N-1) pairs for N currencies (base + input keys)" $ do
      base <- elements [minBound .. maxBound]
      baseRates <- genBaseRates base
      let result = deriveCrossRates base baseRates
          n = Map.size baseRates + 1 -- input keys + base
          expectedPairs = n * (n - 1)
      pure $ Map.size result === expectedPairs

    prop "inverse rates multiply to ~1" $ do
      base <- elements [minBound .. maxBound]
      baseRates <- genBaseRates base
      let result = deriveCrossRates base baseRates
          allCurrencies = base : Map.keys baseRates
          inversePairs = do
            src <- allCurrencies
            tgt <- allCurrencies
            guard (src /= tgt)
            case (getRate result src tgt, getRate result tgt src) of
              (Just ab, Just ba) -> [exchangeRateValue ab * exchangeRateValue ba]
              _ -> []
      pure
        $ counterexample "inverse rates should multiply to ~1"
        $ all (\product' -> abs (product' - 1) < 1e-6) inversePairs

    prop "transitivity: rate(A,C) ~ rate(A,B) * rate(B,C)" $ do
      base <- elements [minBound .. maxBound]
      baseRates <- genBaseRates base `suchThat` (\m -> Map.size m >= 2)
      let result = deriveCrossRates base baseRates
          allCurrencies = base : Map.keys baseRates
          transitivityChecks = do
            a <- allCurrencies
            b <- allCurrencies
            c <- allCurrencies
            guard (a /= b && b /= c && a /= c)
            case (getRate result a b, getRate result b c, getRate result a c) of
              (Just ab, Just bc, Just ac) ->
                let derived = exchangeRateValue ab * exchangeRateValue bc
                    direct = exchangeRateValue ac
                 in [abs (derived - direct) / max 1 (abs direct)]
              _ -> []
      pure
        $ counterexample "transitivity should hold within tolerance"
        $ all (< 1e-6) transitivityChecks
