{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.TransferFeesCommandHandlerPropertySpec
-- Description : Command-handler enforcement of transfer fee rules (spec §4)
module Domain.Transaction.TransferFeesCommandHandlerPropertySpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Domain.Core.Types
import Domain.Transaction
import Optics ((&), (.~))
import RIO hiding ((&), (.~))
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators (genPositiveMoney, genTransferFees)
import Testkit.Helpers

mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

srcId, tgtId :: AccountId
srcId = mockAccountIdN 1
tgtId = mockAccountIdN 2

userId :: UserId
userId = mockUserIdN 1

feeOf :: Word32 -> Money -> Allocation
feeOf n m = Allocation (mockCategoryIdN n) m Nothing

feesOf :: [Allocation] -> Allocations
feesOf = Allocations []

feeSum :: Allocations -> Rational
feeSum a = sum (fmap (\x -> x.amount.amount) (allAllocations a))

-- | A positive source amount with generated (always present) fees.
genSourceAndFees :: Gen (Money, Allocations)
genSourceAndFees = do
  src <- genPositiveMoney
  fees <- genTransferFees src `suchThat` isJust
  pure (src, fromMaybe (feesOf []) fees)

posting :: Money -> Money -> Maybe ExchangeRate -> Maybe Allocations -> TransactionCommand
posting src tgt rate fees =
  InitiateTransactionPostingTransactionCommand
    InitiateTransactionPosting
      { sourceAccountId = srcId,
        targetAccountId = tgtId,
        sourceAmount = src,
        targetAmount = tgt,
        exchangeRate = rate,
        description = "fee transfer",
        initiatedBy = userId,
        at = mockTime,
        transactionType = Transfer fees,
        importInfo = Nothing,
        labels = Set.empty,
        contactId = Nothing,
        relation = Nothing
      }

completedTransfer :: Money -> Money -> Maybe Allocations -> Transaction
completedTransfer src tgt fees =
  transactionDefault
    & #status
    .~ Completed
    & #sourceAccountId
    .~ srcId
    & #targetAccountId
    .~ tgtId
    & #sourceAmount
    .~ src
    & #targetAmount
    .~ tgt
    & #transactionType
    .~ Transfer fees

amend :: Money -> Money -> Maybe ExchangeRate -> Maybe Allocations -> TransactionCommand
amend src tgt rate fees =
  InitiateTransactionAmendmentTransactionCommand
    InitiateTransactionAmendment
      { transactionId = mockTransactionIdN 1,
        newSourceAccountId = srcId,
        newTargetAccountId = tgtId,
        newSourceAmount = src,
        newTargetAmount = tgt,
        newExchangeRate = rate,
        newAllocations = Nothing,
        newTransactionType = Transfer fees,
        contactId = Nothing,
        allowOverdraft = False,
        by = userId
      }

changeAllocs :: Allocations -> TransactionCommand
changeAllocs new =
  ChangeTransactionAllocationsTransactionCommand
    ChangeTransactionAllocations
      { transactionId = mockTransactionIdN 1,
        newAllocations = new
      }

isLeftOf :: TransactionError -> Either TransactionError a -> Property
isLeftOf e r = case r of
  Left e' -> e' === e
  Right _ -> counterexample ("expected Left " <> show e <> ", got Right") False

spec :: Spec
spec = describe "TransferFees command handler" $ do
  describe "posting" $ do
    it "posting a generated fee transfer with target = source - sum fees succeeds"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let tgt = unsafeMoney (moneyCurrency src) (unMoney src - feeSum fees)
         in isRight (handleTransactionCommand transactionDefault (posting src tgt Nothing (Just fees))) === True

    it "same-currency posting with target /= source - sum fees is rejected"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let tgt = src
         in isLeftOf TransferFeesDoNotBalance (handleTransactionCommand transactionDefault (posting src tgt Nothing (Just fees)))

    it "cross-currency posting does not check the equation"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        forAll (genPositiveMoneyOther (moneyCurrency src))
          $ \tgt ->
            isRight (handleTransactionCommand transactionDefault (posting src tgt Nothing (Just fees))) === True

    it "rejects fees not below the source amount"
      $ forAll genPositiveMoney
      $ \src ->
        let fees = feesOf [feeOf 1 src]
         in isLeftOf TransferFeesNotBelowSource (handleTransactionCommand transactionDefault (posting src src Nothing (Just fees)))

    it "income-bucket fee rejected on posting"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let bad = fees {incomes = [feeOf 9 (unsafeMoney (moneyCurrency src) 1)]}
         in isLeftOf TransferFeeIncomeNotSupported (handleTransactionCommand transactionDefault (posting src src Nothing (Just bad)))

  describe "amendment" $ do
    it "income-bucket fee rejected on amendment"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let bad = fees {incomes = [feeOf 9 (unsafeMoney (moneyCurrency src) 1)]}
         in isLeftOf TransferFeeIncomeNotSupported (handleTransactionCommand (completedTransfer src src Nothing) (amend src src Nothing (Just bad)))

    it "amendment to Transfer Nothing is accepted"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let tgt = unsafeMoney (moneyCurrency src) (unMoney src - feeSum fees)
         in isRight (handleTransactionCommand (completedTransfer src tgt (Just fees)) (amend src src Nothing Nothing)) === True

    it "amendment with balanced fees is accepted"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let tgt = unsafeMoney (moneyCurrency src) (unMoney src - feeSum fees)
         in isRight (handleTransactionCommand (completedTransfer src src Nothing) (amend src tgt Nothing (Just fees))) === True

  describe "change allocations" $ do
    it "change allocations re-splits fees with the same feeSum"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let tgt = unsafeMoney (moneyCurrency src) (unMoney src - feeSum fees)
            resplit = feesOf [feeOf 7 (unsafeMoney (moneyCurrency src) (feeSum fees))]
         in isRight (handleTransactionCommand (completedTransfer src tgt (Just fees)) (changeAllocs resplit)) === True

    it "change allocations with a different total is rejected"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        let tgt = unsafeMoney (moneyCurrency src) (unMoney src - feeSum fees)
            other = feesOf [feeOf 7 (unsafeMoney (moneyCurrency src) (feeSum fees / 2))]
         in isLeftOf TransferFeeTotalChanged (handleTransactionCommand (completedTransfer src tgt (Just fees)) (changeAllocs other))

    it "change allocations on a plain transfer is rejected"
      $ forAll genSourceAndFees
      $ \(src, fees) ->
        isLeftOf CannotSetAllocationsOnUncategorisedTransaction (handleTransactionCommand (completedTransfer src src Nothing) (changeAllocs fees))
  where
    genPositiveMoneyOther cur = genPositiveMoney `suchThat` (\x -> moneyCurrency x /= cur)
