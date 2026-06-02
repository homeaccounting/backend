{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.AmendmentPropertySpec
-- Description : Property-based tests for the amendment projection fold.
--
-- Verifies the invariants from spec §4 / plan Task 6:
--
--   * @amendmentCount@ equals the count of folded
--     'TransactionAmendmentCompleted' events.
--   * "Last amendment wins": canonical posting fields after a fold are
--     those of the most-recent 'TransactionAmendmentCompleted'.
--   * 'TransactionAmendmentInitiated' / 'TransactionAmendmentFailed' are no-ops
--     on the canonical posting fields.
--   * The transient @amendmentInProgress@ flag flips on 'Initiated' and
--     clears on 'Completed' / 'Failed'.
module Domain.Transaction.AmendmentPropertySpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    ExchangeRate,
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    allocationsOf,
    kindOf,
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionAmendmentFailed (..),
    TransactionAmendmentInitiated (..),
    TransactionPostingCompleted (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Projection
  ( Transaction,
    TransactionEvent (..),
    transactionDefault,
    transactionProjection,
  )
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.Generators ()
import Testkit.Helpers (singletonIncome)
import Prelude (last)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

txId :: TransactionId
txId = unsafeTransactionId (UUID.fromWords 88 0 0 0)

amendedByU :: UserId
amendedByU = unsafeUserId (UUID.fromWords 9 0 0 0)

-- Fixed seed posting facts used to project a known-completed transaction.
-- Avoid 'transactionDefault'\''s identity fields which are intentionally
-- bottom — the seed must replace them via 'TransactionPostingInitiated'.
seedSrc :: AccountId
seedSrc = unsafeAccountId (UUID.fromWords 11 0 0 0)

seedTgt :: AccountId
seedTgt = unsafeAccountId (UUID.fromWords 12 0 0 0)

seedSrcAmt :: Money
seedSrcAmt = unsafeMoney USD 100

seedTgtAmt :: Money
seedTgtAmt = unsafeMoney USD 100

seedTransactionType :: TransactionType
seedTransactionType = singletonIncome (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)) seedTgtAmt

-- | Replay the projection from a 'TransactionPostingInitiated' + 'TransactionPostingCompleted'
-- seed followed by the given amendment events.
projectAmendments :: [TransactionEvent] -> Transaction
projectAmendments extra =
  latestProjection
    transactionProjection
    ( TransactionPostingInitiatedTransactionEvent
        TransactionPostingInitiated
          { sourceAccountId = seedSrc,
            targetAccountId = seedTgt,
            sourceAmount = seedSrcAmt,
            targetAmount = seedTgtAmt,
            exchangeRate = Nothing,
            description = "seed",
            by = amendedByU,
            at = transactionDefault ^. #at,
            transactionType = seedTransactionType,
            externalTransactionId = Nothing,
            labels = Set.empty
          }
        : TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
        : extra
    )

-- -----------------------------------------------------------------------------
-- Generators
-- -----------------------------------------------------------------------------

-- | Generator for a 'TransactionAmendmentCompleted' targeting the fixture 'txId'.
--
-- The event carries a handler-computed 'newAllocations'. In real use the
-- handler rescales the prior allocations against the new categorised
-- amount; for property purposes we reuse the seed allocations (same kind),
-- which is what the projection now applies via 'replaceAllocations'.
genCompleted :: Gen TransactionAmendmentCompleted
genCompleted = do
  newSrc <- arbitrary :: Gen AccountId
  newTgt <- arbitrary :: Gen AccountId
  newSrcAmt <- arbitrary :: Gen Money
  newTgtAmt <- arbitrary :: Gen Money
  newRate <- oneof [pure Nothing, Just <$> (arbitrary :: Gen ExchangeRate)]
  pure
    TransactionAmendmentCompleted
      { transactionId = txId,
        newSourceAccountId = newSrc,
        newTargetAccountId = newTgt,
        newSourceAmount = newSrcAmt,
        newTargetAmount = newTgtAmt,
        newExchangeRate = newRate,
        newAllocations = allocationsOf seedTransactionType,
        amendedBy = amendedByU
      }

-- | Newtype wrapper to provide 'Arbitrary' for 'TransactionAmendmentCompleted'
-- without an orphan instance.
newtype AmendmentC = AmendmentC {unC :: TransactionAmendmentCompleted}
  deriving (Show)

instance Arbitrary AmendmentC where
  arbitrary = AmendmentC <$> genCompleted

-- | Project a 'TransactionAmendmentCompleted' into the saga's leading
-- 'TransactionAmendmentInitiated' event.
toInitiated :: TransactionAmendmentCompleted -> TransactionAmendmentInitiated
toInitiated c =
  TransactionAmendmentInitiated
    { transactionId = c.transactionId,
      newSourceAccountId = c.newSourceAccountId,
      newTargetAccountId = c.newTargetAccountId,
      newSourceAmount = c.newSourceAmount,
      newTargetAmount = c.newTargetAmount,
      newExchangeRate = c.newExchangeRate,
      amendedBy = c.amendedBy
    }

-- | Saga event pair for a single amendment: Initiated then Completed.
amendmentEvents :: TransactionAmendmentCompleted -> [TransactionEvent]
amendmentEvents c =
  [ TransactionAmendmentInitiatedTransactionEvent (toInitiated c),
    TransactionAmendmentCompletedTransactionEvent c
  ]

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Transaction amendment projection" $ do
  prop "amendmentCount equals number of folded Completed events"
    $ \(amendments :: [AmendmentC]) ->
      let cs = (.unC) <$> amendments
          tx = projectAmendments (concatMap amendmentEvents cs)
       in (tx ^. #amendmentCount) === fromIntegral (length cs)

  prop "last amendment wins: canonical fields equal the last Completed"
    $ \(NonEmpty (amendments :: [AmendmentC])) ->
      let cs = (.unC) <$> amendments
          tx = projectAmendments (concatMap amendmentEvents cs)
          c = last cs
       in conjoin
            [ (tx ^. #sourceAccountId) === c.newSourceAccountId,
              (tx ^. #targetAccountId) === c.newTargetAccountId,
              (tx ^. #sourceAmount) === c.newSourceAmount,
              (tx ^. #targetAmount) === c.newTargetAmount,
              (tx ^. #exchangeRate) === c.newExchangeRate,
              -- 'transactionType' kind is preserved across amendments; for
              -- categorised seeds the allocations are auto-rescaled to
              -- the new categorised side so the sum stays consistent.
              kindOf (tx ^. #transactionType) === kindOf seedTransactionType,
              (tx ^. #amendmentInProgress) === False
            ]

  prop "TransactionAmendmentInitiated alone is a no-op on canonical fields"
    $ \(c :: AmendmentC) ->
      let baseSrc = seedSrc
          baseTgt = seedTgt
          baseSrcA = seedSrcAmt
          baseTgtA = seedTgtAmt
          tx = projectAmendments [TransactionAmendmentInitiatedTransactionEvent (toInitiated c.unC)]
       in conjoin
            [ (tx ^. #sourceAccountId) === baseSrc,
              (tx ^. #targetAccountId) === baseTgt,
              (tx ^. #sourceAmount) === baseSrcA,
              (tx ^. #targetAmount) === baseTgtA,
              (tx ^. #amendmentInProgress) === True,
              (tx ^. #amendmentCount) === 0
            ]

  prop "TransactionAmendmentFailed is a no-op on canonical fields and clears in-progress"
    $ \(c :: AmendmentC) ->
      let baseSrc = seedSrc
          baseTgt = seedTgt
          baseSrcA = seedSrcAmt
          baseTgtA = seedTgtAmt
          tx =
            projectAmendments
              [ TransactionAmendmentInitiatedTransactionEvent (toInitiated c.unC),
                TransactionAmendmentFailedTransactionEvent (TransactionAmendmentFailed "reason")
              ]
       in conjoin
            [ (tx ^. #sourceAccountId) === baseSrc,
              (tx ^. #targetAccountId) === baseTgt,
              (tx ^. #sourceAmount) === baseSrcA,
              (tx ^. #targetAmount) === baseTgtA,
              (tx ^. #amendmentInProgress) === False,
              (tx ^. #amendmentCount) === 0
            ]
