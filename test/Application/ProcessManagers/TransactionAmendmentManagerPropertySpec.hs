{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionAmendmentManagerPropertySpec
-- Description : Property-based tests for 'diffAmendmentLegs'.
--
-- Invariants checked:
--
--   * Net effect on the source account equals (newSrcAmount - oldSrcAmount).
--   * Net effect on the target account equals (newTgtAmount - oldTgtAmount).
--   * A two-account swap forces exactly 4 legs (fallible + 3 non-fallible).
--   * The identity payload (same accounts, same amounts) yields no legs.
module Application.ProcessManagers.TransactionAmendmentManagerPropertySpec (spec) where

import Application.ProcessManagers.TransactionAmendmentManager
  ( FallibleLeg (..),
    NonFallibleLeg (..),
    TransferPostings (..),
    diffAmendmentLegs,
  )
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    unMoney,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.Events (TransactionAmendmentInitiated (..))
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

sampleAt :: UTCTime
sampleAt = UTCTime (fromGregorian 2026 4 1) 0

txId :: TransactionId
txId = unsafeTransactionId (UUID.fromWords 1 0 0 1)

userId_ :: UserId
userId_ = unsafeUserId (UUID.fromWords 4 0 0 4)

oldSrc, oldTgt, newSrc, newTgt :: AccountId
oldSrc = unsafeAccountId (UUID.fromWords 10 0 0 1)
oldTgt = unsafeAccountId (UUID.fromWords 20 0 0 1)
newSrc = unsafeAccountId (UUID.fromWords 11 0 0 1)
newTgt = unsafeAccountId (UUID.fromWords 21 0 0 1)

-- | Positive USD money amount in [1, 100000] cents.
genUsd :: Gen Money
genUsd = do
  cents <- choose (1, 100000) :: Gen Integer
  pure (unsafeMoney USD (fromInteger cents))

postings :: AccountId -> AccountId -> Money -> Money -> TransferPostings
postings s t sa ta =
  TransferPostings
    { sourceAccountId = s,
      targetAccountId = t,
      sourceAmount = sa,
      targetAmount = ta,
      at = sampleAt
    }

amendment :: AccountId -> AccountId -> Money -> Money -> TransactionAmendmentInitiated
amendment s t sa ta =
  TransactionAmendmentInitiated
    { transactionId = txId,
      newSourceAccountId = s,
      newTargetAccountId = t,
      newSourceAmount = sa,
      newTargetAmount = ta,
      newExchangeRate = Nothing,
      newTransactionType = Transfer,
      amendedBy = userId_
    }

-- | Net signed effect of the diff result on a given account.
netOn :: AccountId -> (Maybe FallibleLeg, [NonFallibleLeg]) -> Rational
netOn acct (mDebit, legs) =
  maybe 0 (fallibleNet acct) mDebit + sum (map (nonFallibleNet acct) legs)
  where
    fallibleNet a (DebitNewSource (acc, amt, _))
      | acc == a = unMoney amt
      | otherwise = 0
    nonFallibleNet a (ReverseOldSource acc amt _ _)
      | acc == a = -unMoney amt
      | otherwise = 0
    nonFallibleNet a (CreditNewTarget acc amt _)
      | acc == a = unMoney amt
      | otherwise = 0
    nonFallibleNet a (ReverseOldTarget acc amt _ _)
      | acc == a = -unMoney amt
      | otherwise = 0

-- | Total leg count: counts the fallible head (if any) plus the non-fallible tail.
totalLegs :: (Maybe FallibleLeg, [NonFallibleLeg]) -> Int
totalLegs (mDebit, legs) = maybe 0 (const 1) mDebit + length legs

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "diffAmendmentLegs" $ do
  prop "net source effect equals newSrc - oldSrc when account is unchanged"
    $ forAll genUsd
    $ \oldA ->
      forAll genUsd $ \newA ->
        forAll genUsd $ \oldB ->
          forAll genUsd $ \newB ->
            let result = diffAmendmentLegs (postings oldSrc oldTgt oldA oldB) (amendment oldSrc oldTgt newA newB)
             in netOn oldSrc result === (unMoney newA - unMoney oldA)

  prop "net target effect equals newTgt - oldTgt when account is unchanged"
    $ forAll genUsd
    $ \oldA ->
      forAll genUsd $ \newA ->
        forAll genUsd $ \oldB ->
          forAll genUsd $ \newB ->
            let result = diffAmendmentLegs (postings oldSrc oldTgt oldA oldB) (amendment oldSrc oldTgt newA newB)
             in netOn oldTgt result === (unMoney newB - unMoney oldB)

  prop "account swap forces a 4-leg ordering (1 fallible + 3 non-fallible)"
    $ forAll genUsd
    $ \oldA ->
      forAll genUsd $ \newA ->
        forAll genUsd $ \oldB ->
          forAll genUsd $ \newB ->
            let result = diffAmendmentLegs (postings oldSrc oldTgt oldA oldB) (amendment newSrc newTgt newA newB)
             in totalLegs result === 4

  prop "identity payload (same accounts, same amounts) yields empty diff"
    $ forAll genUsd
    $ \a ->
      forAll genUsd $ \b ->
        let result = diffAmendmentLegs (postings oldSrc oldTgt a b) (amendment oldSrc oldTgt a b)
         in result === (Nothing, [])
