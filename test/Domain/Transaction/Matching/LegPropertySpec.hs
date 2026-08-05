{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Transaction.Matching.LegPropertySpec (spec) where

import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Domain.Transaction.Matching.Leg (Leg (..), sameMovement)
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ((===))

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 8 4) (secondsToDiffTime 0)

spec :: Spec
spec = describe "Domain.Transaction.Matching.Leg.sameMovement" $ do
  it "matches equal magnitude+currency within the window"
    $ sameMovement 86400 (Leg 250 "UAH" baseTime) (Leg 250 "UAH" (addUTCTime 3600 baseTime))
    `shouldBe` True

  it "rejects different magnitude"
    $ sameMovement 86400 (Leg 250 "UAH" baseTime) (Leg 251 "UAH" baseTime)
    `shouldBe` False

  it "rejects different currency"
    $ sameMovement 86400 (Leg 250 "UAH" baseTime) (Leg 250 "USD" baseTime)
    `shouldBe` False

  it "rejects outside the window"
    $ sameMovement 3600 (Leg 250 "UAH" baseTime) (Leg 250 "UAH" (addUTCTime 7200 baseTime))
    `shouldBe` False

  prop "is symmetric in its leg arguments" $ \(m1 :: Integer) (m2 :: Integer) c1 c2 dt ->
    let a = Leg (fromIntegral m1) (c1 :: Char) baseTime
        b = Leg (fromIntegral m2) c2 (addUTCTime (fromIntegral (dt :: Int)) baseTime)
     in sameMovement 86400 a b === sameMovement 86400 b a
