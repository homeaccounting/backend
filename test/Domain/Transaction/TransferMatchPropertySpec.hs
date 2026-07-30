{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Transaction.TransferMatchPropertySpec (spec) where

import Data.Time (NominalDiffTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Transaction.TransferMatch
  ( TransferDirection (..),
    TransferLeg (..),
    isTransferMatch,
  )
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- A fixed 5-minute window for the properties.
window :: NominalDiffTime
window = 300

genLeg :: Gen (TransferLeg Int)
genLeg = do
  dir <- elements [DebitLeg, CreditLeg]
  mag <- elements [50, 100, 250] :: Gen Rational
  cur <- elements [840, 980]
  secs <- choose (1700000000, 1700002000) :: Gen Integer
  pure (TransferLeg dir mag cur (posixSecondsToUTCTime (fromIntegral secs)))

spec :: Spec
spec = describe "Domain.Transaction.TransferMatch.isTransferMatch" $ do
  prop "is symmetric"
    $ forAll genLeg
    $ \a ->
      forAll genLeg $ \b ->
        isTransferMatch window a b === isTransferMatch window b a

  prop "never matches two legs of the same direction"
    $ forAll genLeg
    $ \a ->
      forAll genLeg $ \b ->
        a.direction == b.direction ==> not (isTransferMatch window a b)

  prop "requires equal magnitude"
    $ forAll genLeg
    $ \a ->
      forAll genLeg $ \b ->
        a.magnitude /= b.magnitude ==> not (isTransferMatch window a b)

  prop "requires equal currency"
    $ forAll genLeg
    $ \a ->
      forAll genLeg $ \b ->
        a.currency /= b.currency ==> not (isTransferMatch window a b)

  it "matches an opposite-direction, equal-magnitude, same-currency pair at the window boundary" $ do
    let t0 = posixSecondsToUTCTime 1700000000
        t1 = posixSecondsToUTCTime 1700000300 -- exactly +300s
        a = TransferLeg DebitLeg 100 (840 :: Int) t0
        b = TransferLeg CreditLeg 100 840 t1
    isTransferMatch window a b `shouldBe` True

  it "rejects a pair just outside the window" $ do
    let t0 = posixSecondsToUTCTime 1700000000
        t1 = posixSecondsToUTCTime 1700000301 -- +301s
        a = TransferLeg DebitLeg 100 (840 :: Int) t0
        b = TransferLeg CreditLeg 100 840 t1
    isTransferMatch window a b `shouldBe` False
