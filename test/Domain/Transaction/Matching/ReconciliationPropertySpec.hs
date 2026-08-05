{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Transaction.Matching.ReconciliationPropertySpec (spec) where

import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Domain.Transaction.Matching.Leg (Leg (..))
import Domain.Transaction.Matching.Reconciliation (ReconciliationOutcome (..), reconcile)
import RIO
import Test.Hspec

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 4) (secondsToDiffTime 0)

day :: Rational -> UTCTime
day n = addUTCTime (fromRational (n * 86400)) t0

window :: NominalDiffTime
window = 3 * 86400 -- ±3 days

leg :: Rational -> UTCTime -> Leg Text
leg m = Leg m "UAH"

spec :: Spec
spec = describe "Domain.Transaction.Matching.Reconciliation.reconcile" $ do
  it "returns UniqueMatch on exactly one exact candidate"
    $ reconcile window (leg 250 t0) [("A" :: Text, leg 250 t0)]
    `shouldBe` UniqueMatch "A"

  it "returns UniqueMatch on a single near candidate within the window"
    $ reconcile window (leg 250 t0) [("A" :: Text, leg 250 (day 2))]
    `shouldBe` UniqueMatch "A"

  it "returns Ambiguous for two distinct same-amount same-day candidates"
    $ reconcile window (leg 250 t0) [("A" :: Text, leg 250 t0), ("B", leg 250 t0)]
    `shouldBe` Ambiguous ["A", "B"]

  it "returns NoMatch when the only candidate is outside the window"
    $ reconcile window (leg 250 t0) [("A" :: Text, leg 250 (day 5))]
    `shouldBe` NoMatch

  it "returns NoMatch on differing magnitude/currency" $ do
    reconcile window (leg 250 t0) [("A" :: Text, leg 251 t0)] `shouldBe` NoMatch
    reconcile window (leg 250 t0) [("A" :: Text, Leg 250 "USD" t0)] `shouldBe` NoMatch

  it "ignores non-matching candidates when exactly one matches"
    $ reconcile window (leg 250 t0) [("A" :: Text, leg 999 t0), ("B", leg 250 (day 1))]
    `shouldBe` UniqueMatch "B"
