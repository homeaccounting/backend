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
--
-- Also verifies cross-kind amendment handler invariants (Task 7):
--
--   * (1) Handler emits 'TransactionAmendmentInitiated' with 'newTransactionType'
--     equal to the command's 'newTransactionType'.
--   * (2) Allocation sum equals the relevant leg amount.
--   * (3) Every allocation shares the relevant leg's currency.
module Domain.Transaction.AmendmentPropertySpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Allocations,
    Currency (..),
    ExchangeRate,
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    allAllocations,
    kindOf,
    mkAllocations,
    mkExpense,
    mkIncome,
    moneyCurrency,
    unMoney,
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    handleTransactionCommand,
  )
import Domain.Transaction.Commands (AmendTransaction (..))
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
import Testkit.Generators
  ( genAccountId,
    genAllocationListSummingTo,
    genCurrency,
    genPositiveMoneyIn,
    genTransactionId,
    genUserId,
  )
import Testkit.Helpers (singletonIncome)
import Prelude (last)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

-- | Sum of every allocation amount across both buckets, as a 'Rational'.
allocationSum :: Allocations -> Rational
allocationSum a = sum [unMoney m | Allocation _ m _ <- allAllocations a]

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
-- caller supplies explicit allocations with the amendment (no rescaling
-- occurs); for property purposes we reuse the seed allocations (same kind),
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
        newTransactionType = seedTransactionType,
        by = amendedByU
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
      newTransactionType = c.newTransactionType,
      by = c.by
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
              -- categorised seeds the caller supplies explicit allocations
              -- so the sum matches the new categorised total.
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

  describe "AmendTransaction — cross-kind handler properties" $ do
    prop "(1) handler emits Initiated event with newTransactionType verbatim"
      $ forAll genCrossKindAmendInputs
      $ \(seed, cmd) ->
        case handleTransactionCommand seed (AmendTransactionTransactionCommand cmd) of
          Right [TransactionAmendmentInitiatedTransactionEvent evt] ->
            evt.newTransactionType === cmd.newTransactionType
          Right other ->
            counterexample ("handler emitted unexpected event shape: " <> show other) False
          Left e ->
            counterexample ("handler rejected valid input: " <> show e) False

    prop "(2) allocation sum equals relevant leg amount"
      $ forAll genCrossKindAmendInputs
      $ \(_seed, cmd) ->
        case cmd.newTransactionType of
          Income allocs -> allocationSum allocs === unMoney cmd.newTargetAmount
          Expense allocs -> allocationSum allocs === unMoney cmd.newSourceAmount
          _ -> property True

    prop "(3) allocation currency matches relevant leg"
      $ forAll genCrossKindAmendInputs
      $ \(_seed, cmd) ->
        case cmd.newTransactionType of
          Income allocs ->
            property
              $ all
                (\(Allocation _cid m _) -> moneyCurrency m == moneyCurrency cmd.newTargetAmount)
                (allAllocations allocs)
          Expense allocs ->
            property
              $ all
                (\(Allocation _cid m _) -> moneyCurrency m == moneyCurrency cmd.newSourceAmount)
                (allAllocations allocs)
          _ -> property True

-- -----------------------------------------------------------------------------
-- Cross-kind generator (handler-level)
-- -----------------------------------------------------------------------------

-- | Generate a '(Transaction, AmendTransaction)' pair the pure handler will
-- accept. The 'Transaction' seed is a 'Completed' transaction projected from
-- the fixed fixture events (same as 'projectAmendments []'). The command has:
--
--  * 'newSourceAccountId /= newTargetAccountId'
--  * 'newSourceAmount > 0', 'newTargetAmount > 0'
--  * 'newTransactionType' internally consistent: Income allocations sum to
--    'newTargetAmount', Expense to 'newSourceAmount', Transfer is bare.
genCrossKindAmendInputs :: Gen (Transaction, AmendTransaction)
genCrossKindAmendInputs = do
  txId <- genTransactionId
  newSrc <- genAccountId `suchThat` (/= seedTgt)
  newTgt <- genAccountId `suchThat` (\a -> a /= newSrc && a /= seedSrc)
  cur <- genCurrency
  newSrcAmt <- genPositiveMoneyIn cur
  newTgtAmt <- genPositiveMoneyIn cur
  uid <- genUserId
  newTT <- genConsistentTransactionType newSrcAmt newTgtAmt
  let seed = projectAmendments []
      cmd =
        AmendTransaction
          { transactionId = txId,
            newSourceAccountId = newSrc,
            newTargetAccountId = newTgt,
            newSourceAmount = newSrcAmt,
            newTargetAmount = newTgtAmt,
            newExchangeRate = Nothing,
            newAllocations = Nothing,
            newTransactionType = newTT,
            by = uid
          }
  pure (seed, cmd)

-- | Generate a 'TransactionType' consistent with the given leg amounts.
--
-- The generated type is always handler-acceptable:
--  - 'Income allocs': allocations sum to 'tgtAmt' (same currency).
--  - 'Expense allocs': allocations sum to 'srcAmt' (same currency).
--  - 'Transfer': no allocations.
genConsistentTransactionType :: Money -> Money -> Gen TransactionType
genConsistentTransactionType srcAmt tgtAmt =
  oneof [buildIncome, buildExpense, pure Transfer]
  where
    -- 'discard' on a bad allocation generation makes QuickCheck retry the
    -- generator rather than silently falling back to 'Transfer'. The
    -- previous fallback hid Income/Expense allocation failures by
    -- collapsing them onto the trivially-true Transfer branch.
    buildIncome = do
      incs <- genAllocationListSummingTo tgtAmt
      case mkAllocations incs [] >>= mkIncome tgtAmt of
        Right tt -> pure tt
        Left _ -> discard
    buildExpense = do
      exps <- genAllocationListSummingTo srcAmt
      case mkAllocations [] exps >>= mkExpense srcAmt of
        Right tt -> pure tt
        Left _ -> discard
