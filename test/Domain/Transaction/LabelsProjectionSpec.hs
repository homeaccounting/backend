{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.LabelsProjectionSpec
-- Description : Projection fold rules + property for labels / category edits.
module Domain.Transaction.LabelsProjectionSpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( DictionaryEntryId,
    TransferType (..),
    unsafeDictionaryEntryId,
    unsafeTransactionId,
  )
import Domain.Transaction.Events
  ( TransactionCategoryChanged (..),
    TransactionLabelsSet (..),
    TransferCompleted (..),
    TransferInitiated (..),
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
import Prelude (last)

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Default TransferInitiated event shape; callers override individual
-- fields via record update.
mkInitiated :: TransferInitiated
mkInitiated =
  TransferInitiated
    { sourceAccountId = transactionDefault ^. #sourceAccountId,
      targetAccountId = transactionDefault ^. #targetAccountId,
      sourceAmount = transactionDefault ^. #sourceAmount,
      targetAmount = transactionDefault ^. #targetAmount,
      exchangeRate = Nothing,
      description = "",
      by = transactionDefault ^. #initiatedBy,
      at = anyTime,
      transferType = Income (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)),
      externalTransactionId = Nothing,
      labels = Set.empty
    }

-- | Placeholder business date for projection-fold tests. The labels /
-- category specs do not exercise date semantics; this value is here
-- only because 'TransferInitiated' carries 'at' as a load-bearing field.
anyTime :: UTCTime
anyTime = UTCTime (fromGregorian 2026 3 15) (secondsToDiffTime 0)

-- | Seed event for a transaction with the given initial labels.
seedInitiatedLabels :: [DictionaryEntryId] -> TransactionEvent
seedInitiatedLabels ls =
  TransferInitiatedTransactionEvent
    mkInitiated {labels = Set.fromList ls}

-- | Seed event for a transaction with the given initial TransferType.
seedInitiatedWithType :: TransferType -> TransactionEvent
seedInitiatedWithType tt =
  TransferInitiatedTransactionEvent
    mkInitiated {transferType = tt}

completed :: TransactionEvent
completed = TransferCompletedTransactionEvent TransferCompleted

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Transaction projection / labels + category edits" $ do
  it "folds TransactionLabelsSet after completion replaces the set" $ do
    let l1 = unsafeDictionaryEntryId (UUID.fromWords 10 0 0 0)
        l2 = unsafeDictionaryEntryId (UUID.fromWords 20 0 0 0)
        l3 = unsafeDictionaryEntryId (UUID.fromWords 30 0 0 0)
        txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)
        evts =
          [ seedInitiatedLabels [l1],
            completed,
            TransactionLabelsSetTransactionEvent
              TransactionLabelsSet
                { transactionId = txId,
                  labels = Set.fromList [l2, l3]
                }
          ]
        projected = latestProjection transactionProjection evts
    projected ^. #labels `shouldBe` Set.fromList [l2, l3]

  it "TransactionLabelsSet before completion is ignored" $ do
    let l1 = unsafeDictionaryEntryId (UUID.fromWords 10 0 0 0)
        l2 = unsafeDictionaryEntryId (UUID.fromWords 20 0 0 0)
        txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)
        evts =
          [ seedInitiatedLabels [l1],
            TransactionLabelsSetTransactionEvent
              TransactionLabelsSet
                { transactionId = txId,
                  labels = Set.singleton l2
                }
          ]
        projected = latestProjection transactionProjection evts
    projected ^. #labels `shouldBe` Set.singleton l1

  it "TransactionCategoryChanged rewrites an Income category in place" $ do
    let original = unsafeDictionaryEntryId (UUID.fromWords 40 0 0 0)
        replacement = unsafeDictionaryEntryId (UUID.fromWords 50 0 0 0)
        txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)
        evts =
          [ seedInitiatedWithType (Income original),
            completed,
            TransactionCategoryChangedTransactionEvent
              TransactionCategoryChanged
                { transactionId = txId,
                  newCategory = replacement
                }
          ]
        projected = latestProjection transactionProjection evts
    projected ^. #transferType `shouldBe` Income replacement

  it "TransactionCategoryChanged rewrites an Expense category in place" $ do
    let original = unsafeDictionaryEntryId (UUID.fromWords 41 0 0 0)
        replacement = unsafeDictionaryEntryId (UUID.fromWords 51 0 0 0)
        txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)
        evts =
          [ seedInitiatedWithType (Expense original),
            completed,
            TransactionCategoryChangedTransactionEvent
              TransactionCategoryChanged
                { transactionId = txId,
                  newCategory = replacement
                }
          ]
        projected = latestProjection transactionProjection evts
    projected ^. #transferType `shouldBe` Expense replacement

  describe "Property: last TransactionLabelsSet wins"
    $ it "fold of N label-set events yields the last event's set"
    $ property
    $ \(NonEmpty labelSets) ->
      let txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)
          seed = seedInitiatedLabels []
          setEvents =
            [ TransactionLabelsSetTransactionEvent
                TransactionLabelsSet
                  { transactionId = txId,
                    labels = s
                  }
            | s <- labelSets
            ]
          projected = latestProjection transactionProjection (seed : completed : setEvents)
       in projected ^. #labels === last labelSets

  describe "Property: last TransactionCategoryChanged wins"
    $ it "fold of N category-change events yields the last event's category (Income)"
    $ property
    $ \(NonEmpty cats) ->
      let txId = unsafeTransactionId (UUID.fromWords 77 0 0 0)
          seed = seedInitiatedWithType (Income (unsafeDictionaryEntryId (UUID.fromWords 99 0 0 0)))
          changeEvents =
            [ TransactionCategoryChangedTransactionEvent
                TransactionCategoryChanged
                  { transactionId = txId,
                    newCategory = c
                  }
            | c <- cats
            ]
          projected = latestProjection transactionProjection (seed : completed : changeEvents)
       in projected ^. #transferType === Income (last cats)
