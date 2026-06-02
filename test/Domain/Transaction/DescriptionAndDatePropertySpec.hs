{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.DescriptionAndDatePropertySpec
-- Description : Property-based tests for the description / date projection fold:
--               the last edit wins.
module Domain.Transaction.DescriptionAndDatePropertySpec (spec) where

import qualified Data.Set as Set
import qualified Data.Text as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( Currency (..),
    TransactionId,
    TransactionType (..),
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
  )
import Domain.Transaction.Events
  ( TransactionDateChanged (..),
    TransactionDescriptionChanged (..),
    TransactionPostingCompleted (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Projection
  ( TransactionEvent (..),
    transactionDefault,
    transactionProjection,
  )
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators ()
import Testkit.Helpers (singletonIncome)
import Prelude (last)

-- -----------------------------------------------------------------------------
-- Fixtures / helpers
-- -----------------------------------------------------------------------------

txId :: TransactionId
txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)

seedInitiated :: TransactionEvent
seedInitiated =
  TransactionPostingInitiatedTransactionEvent
    TransactionPostingInitiated
      { sourceAccountId = transactionDefault ^. #sourceAccountId,
        targetAccountId = transactionDefault ^. #targetAccountId,
        sourceAmount = transactionDefault ^. #sourceAmount,
        targetAmount = transactionDefault ^. #targetAmount,
        exchangeRate = Nothing,
        description = "seed",
        by = transactionDefault ^. #initiatedBy,
        at = UTCTime (fromGregorian 1970 1 1) 0,
        transactionType = singletonIncome (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)) (unsafeMoney USD 100),
        externalTransactionId = Nothing,
        labels = Set.empty
      }

completed :: TransactionEvent
completed = TransactionPostingCompletedTransactionEvent TransactionPostingCompleted

-- | QuickCheck-friendly 'UTCTime' built from an arbitrary 'Day' plus a clamped
-- second-of-day component.
genUTCTime :: Gen UTCTime
genUTCTime = do
  day <- arbitrary
  secs <- choose (0, 86399) :: Gen Integer
  pure $ UTCTime day (secondsToDiffTime secs)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "Property: last TransactionDescriptionChanged wins" $ do
    it "fold of N description-change events yields the last event's description"
      $ property
      $ \(NonEmpty descs) ->
        let changeEvents =
              [ TransactionDescriptionChangedTransactionEvent
                  TransactionDescriptionChanged
                    { transactionId = txId,
                      newDescription = Text.pack d
                    }
              | d <- descs
              ]
            projected =
              latestProjection
                transactionProjection
                (seedInitiated : completed : changeEvents)
         in projected ^. #description === Text.pack (last descs)

  describe "Property: last TransactionDateChanged wins" $ do
    it "fold of N date-change events yields the last event's date"
      $ forAll (listOf1 genUTCTime)
      $ \dates ->
        let changeEvents =
              [ TransactionDateChangedTransactionEvent
                  TransactionDateChanged
                    { transactionId = txId,
                      newAt = d
                    }
              | d <- dates
              ]
            projected =
              latestProjection
                transactionProjection
                (seedInitiated : completed : changeEvents)
         in projected ^. #at === last dates
