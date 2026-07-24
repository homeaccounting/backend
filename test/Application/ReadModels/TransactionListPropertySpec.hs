{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionListPropertySpec
-- Description : QuickCheck property: date-range filter is sound
module Application.ReadModels.TransactionListPropertySpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionData (..),
    applyTransactionEvent,
    listTransactions,
    mkTransactionFilter,
    resetTransaction,
  )
import qualified Data.Set as Set
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Page (Page (..), defaultLimit)
import Domain.Core.Range (Range (..))
import Domain.Core.Types (TransactionType (..))
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Helpers (mockAccountId, mockTransactionId)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.TransactionEvents (postingInitiatedGlobal)

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
spec = describe "listTransactions / date bounds (property)"
  $
  -- One environment shared across all QuickCheck iterations; the transaction
  -- tables are reset between iterations so each draw starts from empty.
  before createTestAppEnvWithProcessManager
  $ it "every returned entry has from <= date <= to when both bounds are set"
  $ \env ->
    property
      $ forAll (resize 20 (listOf genBoundedDay))
      $ \dates ->
        forAll genBoundedRange $ \(fromD, toD) -> ioProperty $ do
          let acctA = mockAccountId (UUID.fromWords 1 0 0 0)
              acctB = mockAccountId (UUID.fromWords 2 0 0 0)
              events =
                [ postingInitiatedGlobal
                    (mockTransactionId (UUID.fromWords (fromIntegral i) 0 0 0))
                    acctA
                    acctB
                    Transfer
                    Set.empty
                    d
                    d
                    (fromIntegral i)
                    Nothing
                | (i, d) <- zip [(1 :: Word32) ..] dates
                ]
          runDbIn env resetTransaction
          runDbIn env (mapM_ applyTransactionEvent events)
          let filt = mkTransactionFilter Nothing (Just (Range (Just fromD) (Just toD))) Nothing Nothing
          (_, results) <- runDbIn env (listTransactions (Set.singleton acctA) filt (Page defaultLimit 0))
          pure $ all (\(_, td) -> td.date >= fromD && td.date <= toD) results
