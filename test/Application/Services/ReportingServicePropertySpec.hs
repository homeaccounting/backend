{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.ReportingServicePropertySpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.Services.ReportingService as R
import qualified Data.Map.Strict as Map
import Domain.Core.Types
import Domain.Transaction.Types
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.Generators (genCurrency, genPositiveMoneyIn, genTransactionData)

spec :: Spec
spec = describe "ReportingService aggregation properties" $ do
  prop "allocationBase over all allocations sums exactly to the external leg"
    $ forAll genTransactionData
    $ \td ->
      case (td.transactionType, allocationsOf td.transactionType) of
        (Transfer _, _) -> property Discard
        (_, Nothing) -> property Discard
        (_, Just allocs) ->
          let summed =
                sum [unMoney (R.allocationBase td a.amount) | a <- allAllocations allocs]
           in summed === unMoney (R.externalLeg td)

  prop "aggregateIncomeExpense net equals income minus expense"
    $ forAll (listOf genTransactionData)
    $ \txs ->
      let (i, e, n) = R.aggregateIncomeExpense UAH Map.empty txs
       in unMoney n === unMoney i - unMoney e

  prop "allocationBase is identity when exchangeRate is Nothing"
    $ forAll genTransactionData
    $ \td ->
      isNothing td.exchangeRate ==>
        forAll genAllocAmount $ \m ->
          R.allocationBase td m === m
  where
    genAllocAmount = genCurrency >>= genPositiveMoneyIn
