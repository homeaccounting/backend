{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionFilterSpec
-- Description : Construction tests for TransactionFilter.
module Application.ReadModels.TransactionFilterSpec (spec) where

import Application.ReadModels.Transaction
  ( TransactionFilter (..),
    emptyTransactionFilter,
    mkTransactionFilter,
  )
import qualified Data.List.NonEmpty as NE
import Domain.Transaction.Projection (StatusKind (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "TransactionFilter" $ do
  it "emptyTransactionFilter has no constraints" $ do
    let f = emptyTransactionFilter
    f.accountId `shouldBe` Nothing
    f.dateRange `shouldBe` Nothing
    f.statuses `shouldBe` Nothing
    f.label `shouldBe` Nothing

  it "mkTransactionFilter carries the status set" $ do
    let f = mkTransactionFilter Nothing Nothing (Just (FailedKind NE.:| [CancelledKind])) Nothing
    f.statuses `shouldBe` Just (FailedKind NE.:| [CancelledKind])
