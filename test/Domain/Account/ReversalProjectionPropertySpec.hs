{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Account.ReversalProjectionPropertySpec
-- Description : Property-based tests for account debit/credit reversal events
--
-- Verifies that folding [AccountDebited, AccountDebitReversed] and
-- [AccountCredited, AccountCreditReversed] leaves the account balance
-- identical to the baseline (just AccountCreated), confirming that
-- reversal events are exact inverses of the original postings.
--
-- The 'hasTransactions' field is intentionally excluded from comparison
-- because it is set to True by both the original posting and the reversal
-- event — its value after reversal differs from the post-creation baseline
-- by design (spec §2.1).
module Domain.Account.ReversalProjectionPropertySpec (spec) where

import Data.Time (UTCTime (..), secondsToDiffTime)
import Domain.Account.Events
  ( AccountCreated (..),
    AccountCreditReversed (..),
    AccountCredited (..),
    AccountDebitReversed (..),
    AccountDebited (..),
  )
import Domain.Account.Projection
import Domain.Core.Types
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators
import Testkit.Helpers

spec :: Spec
spec = do
  debitReversalSpec
  creditReversalSpec

-- -----------------------------------------------------------------------------
-- Helper: apply events to produce an Account
-- -----------------------------------------------------------------------------

applyEvents :: [AccountEvent] -> Account
applyEvents = latestProjection accountProjection

-- | Generate a UTCTime derived from the Arbitrary Day instance already in
-- Testkit.Generators. The time-of-day component is fixed at midnight so that
-- shrinking stays simple.
genUTCTime :: Gen UTCTime
genUTCTime = do
  day <- arbitrary
  pure $ UTCTime day (secondsToDiffTime 0)

-- -----------------------------------------------------------------------------
-- Debit reversal cancels balance
-- -----------------------------------------------------------------------------

debitReversalSpec :: Spec
debitReversalSpec =
  describe "AccountDebitReversed" $ do
    it "restores balance after AccountDebited"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll genUTCTime $ \t ->
          forAll (genPositiveMoneyIn USD) $ \amt ->
            let baseEvents =
                  [ AccountCreatedAccountEvent
                      $ AccountCreated
                        { name = "Test",
                          initialBalance = mockMoney 1000,
                          by = ownerId,
                          accountType = Regular defaultCash,
                          overdraftLimit = Just (mockMoney 500)
                        }
                  ]
                baseline = applyEvents baseEvents
                finalEvents =
                  baseEvents
                    <> [ AccountDebitedAccountEvent $ AccountDebited amt txId,
                         AccountDebitReversedAccountEvent $ AccountDebitReversed amt txId t
                       ]
                final = applyEvents finalEvents
             in final ^. #balance === baseline ^. #balance

-- -----------------------------------------------------------------------------
-- Credit reversal cancels balance
-- -----------------------------------------------------------------------------

creditReversalSpec :: Spec
creditReversalSpec =
  describe "AccountCreditReversed" $ do
    it "restores balance after AccountCredited"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll genUTCTime $ \t ->
          forAll (genPositiveMoneyIn USD) $ \amt ->
            let baseEvents =
                  [ AccountCreatedAccountEvent
                      $ AccountCreated
                        { name = "Test",
                          initialBalance = mockMoney 1000,
                          by = ownerId,
                          accountType = Regular defaultCash,
                          overdraftLimit = Just (mockMoney 0)
                        }
                  ]
                baseline = applyEvents baseEvents
                finalEvents =
                  baseEvents
                    <> [ AccountCreditedAccountEvent $ AccountCredited amt txId,
                         AccountCreditReversedAccountEvent $ AccountCreditReversed amt txId t
                       ]
                final = applyEvents finalEvents
             in final ^. #balance === baseline ^. #balance
