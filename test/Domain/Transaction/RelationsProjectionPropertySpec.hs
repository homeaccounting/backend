{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.RelationsProjectionPropertySpec
-- Description : TransactionRelationAdded is an aggregate-state no-op.
--
-- Relationships are a read-model concern; the aggregate never gates on them,
-- so folding a 'TransactionRelationAdded' event must leave the projected
-- 'Transaction' state unchanged for any seed state and any related id / kind.
module Domain.Transaction.RelationsProjectionPropertySpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( RelationKind (..),
    TransactionId,
    TransactionType,
    unsafeAccountId,
    unsafeMoney,
    unsafeUserId,
  )
import qualified Domain.Core.Types as Core
import Domain.Transaction.Events
  ( TransactionPostingInitiated (..),
    TransactionRelationAdded (..),
  )
import Domain.Transaction.Projection
  ( Transaction,
    TransactionEvent (..),
    handleTransactionEvent,
    transactionProjection,
  )
import Eventium (latestProjection)
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators ()

-- | Build a seed 'Transaction' by folding a 'TransactionPostingInitiated' event
-- carrying an arbitrary 'TransactionType'. The amounts are pinned to a unit USD
-- value; the specific magnitude is irrelevant to the no-op property.
seedTransaction :: TransactionType -> Transaction
seedTransaction tt =
  latestProjection
    transactionProjection
    [ TransactionPostingInitiatedTransactionEvent
        TransactionPostingInitiated
          { sourceAccountId = unsafeAccountId (UUID.fromWords 10 0 0 0),
            targetAccountId = unsafeAccountId (UUID.fromWords 11 0 0 0),
            sourceAmount = unsafeMoney Core.USD 100,
            targetAmount = unsafeMoney Core.USD 100,
            exchangeRate = Nothing,
            description = "",
            by = unsafeUserId (UUID.fromWords 99 0 0 0),
            at = UTCTime (fromGregorian 2026 3 15) (secondsToDiffTime 0),
            transactionType = tt,
            importInfo = Nothing,
            labels = Set.empty
          }
    ]

-- | Every 'RelationKind' constructor (closed enum), for exhaustive coverage.
genRelationKind :: Gen RelationKind
genRelationKind = elements [minBound .. maxBound]

spec :: Spec
spec =
  describe "TransactionRelationAdded projection"
    $ it "is a no-op on aggregate state"
    $ property
    $ \(tt :: TransactionType) (relatedId :: TransactionId) ->
      forAll genRelationKind $ \k ->
        let tx = seedTransaction tt
            evt = TransactionRelationAddedTransactionEvent (TransactionRelationAdded relatedId k)
         in handleTransactionEvent tx evt === tx
