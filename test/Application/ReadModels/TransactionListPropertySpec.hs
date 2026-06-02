{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionListPropertySpec
-- Description : QuickCheck property: date-range filter is sound
module Application.ReadModels.TransactionListPropertySpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    TransactionReadModel,
    createTransactionReadModel,
    handleTransactionEvents,
    listTransactions,
    mkTransactionQuery,
  )
import qualified Data.Set as Set
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    TransactionId,
    TransactionType (..),
    unTransactionId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionPostingInitiated (..))
import Eventium (StreamEvent (..), emptyMetadata)
import qualified Eventium
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Helpers
  ( mockAccountId,
    mockMoneyWith,
    mockTransactionId,
    mockUserId,
  )

-- | Duplicated locally from TransactionListSpec so each Spec stays
-- self-contained. If a third call site lands, promote to
-- Testkit/Generators.hs as a follow-up PR.
mkInitiatedEvent ::
  TransactionId ->
  AccountId ->
  AccountId ->
  UTCTime ->
  UTCTime ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
mkInitiatedEvent txId src tgt businessAt persistedAt seqNo =
  let inner =
        StreamEvent
          (unTransactionId txId)
          0
          ( (emptyMetadata "TransactionPostingInitiated")
              { Eventium.createdAt = Just persistedAt
              }
          )
          ( TransactionPostingInitiatedEvent
              TransactionPostingInitiated
                { sourceAccountId = src,
                  targetAccountId = tgt,
                  sourceAmount = mockMoneyWith USD 100,
                  targetAmount = mockMoneyWith USD 100,
                  exchangeRate = Nothing,
                  description = "seed",
                  by = mockUserId (UUID.fromWords 9 0 0 0),
                  at = businessAt,
                  transactionType = Transfer,
                  externalTransactionId = Nothing,
                  labels = Set.empty
                }
          )
   in StreamEvent () seqNo (emptyMetadata "TransactionPostingInitiated") inner

-- | A random UTC instant inside a fixed 366-day window starting 2026-01-01.
-- Uses addUTCTime so the day counter is normalised correctly.
genBoundedDay :: Gen UTCTime
genBoundedDay = do
  dayOffset <- choose (0 :: Int, 365)
  let base = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)
      delta = fromIntegral (dayOffset * 86400) :: NominalDiffTime
  pure $ addUTCTime delta base

-- | Generator for an ordered pair (from, to) with @from <= to@, drawn
-- inside the fixed 366-day window. Using a pair generator (rather than
-- two independent bound draws swapped with @min@/@max@) keeps all
-- random inputs visible to QuickCheck's shrinker.
genBoundedRange :: Gen (UTCTime, UTCTime)
genBoundedRange = do
  a <- genBoundedDay
  b <- genBoundedDay
  pure (min a b, max a b)

spec :: Spec
spec = describe "listTransactions / date bounds (property)" $ do
  it "every returned entry has from <= date <= to when both bounds are set"
    $ property
    $ forAll (resize 20 (listOf genBoundedDay))
    $ \dates ->
      forAll genBoundedRange $ \(fromD, toD) -> ioProperty $ do
        let acctA = mockAccountId (UUID.fromWords 1 0 0 0)
            acctB = mockAccountId (UUID.fromWords 2 0 0 0)
            events =
              [ mkInitiatedEvent
                  (mockTransactionId (UUID.fromWords (fromIntegral i) 0 0 0))
                  acctA
                  acctB
                  d
                  d
                  (fromIntegral i)
              | (i, d) <- zip [(1 :: Word32) ..] dates
              ]
        tvar <- createTransactionReadModel :: IO (TVar TransactionReadModel)
        let h = handleTransactionEvents tvar
        h.handleEvent events
        q <-
          either (fail . show) pure
            $ mkTransactionQuery Nothing (Just fromD) (Just toD) False
        results <- listTransactions tvar (Set.singleton acctA) q
        pure $ all (\(_, td) -> td.date >= fromD && td.date <= toD) results
