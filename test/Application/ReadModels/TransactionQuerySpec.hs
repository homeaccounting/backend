{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.TransactionQuerySpec
-- Description : Smart-constructor tests for TransactionQuery
module Application.ReadModels.TransactionQuerySpec (spec) where

import Application.ReadModels.Transaction
  ( emptyTransactionQuery,
    mkTransactionQuery,
    queryAccountId,
    queryFrom,
    queryTo,
  )
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types (AccountId)
import RIO
import Test.Hspec
import Testkit.Helpers (mockAccountId)

sampleAccountId :: AccountId
sampleAccountId = mockAccountId (UUID.fromWords 1 0 0 0)

jan15 :: UTCTime
jan15 = UTCTime (fromGregorian 2026 1 15) (secondsToDiffTime 0)

jan20 :: UTCTime
jan20 = UTCTime (fromGregorian 2026 1 20) (secondsToDiffTime 0)

spec :: Spec
spec = describe "mkTransactionQuery" $ do
  it "accepts no bounds" $ do
    case mkTransactionQuery Nothing Nothing Nothing of
      Right q -> do
        queryAccountId q `shouldBe` Nothing
        queryFrom q `shouldBe` Nothing
        queryTo q `shouldBe` Nothing
      Left err -> expectationFailure $ "expected Right, got Left " <> show err

  it "accepts only-from"
    $ mkTransactionQuery Nothing (Just jan15) Nothing
    `shouldSatisfy` isRight

  it "accepts only-to"
    $ mkTransactionQuery Nothing Nothing (Just jan20)
    `shouldSatisfy` isRight

  it "accepts from == to"
    $ mkTransactionQuery Nothing (Just jan15) (Just jan15)
    `shouldSatisfy` isRight

  it "accepts from < to"
    $ mkTransactionQuery Nothing (Just jan15) (Just jan20)
    `shouldSatisfy` isRight

  it "rejects from > to" $ do
    case mkTransactionQuery Nothing (Just jan20) (Just jan15) of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected Left for from > to"

  it "preserves accountId filter"
    $ case mkTransactionQuery (Just sampleAccountId) Nothing Nothing of
      Right q -> queryAccountId q `shouldBe` Just sampleAccountId
      Left err -> expectationFailure $ "expected Right, got Left " <> show err

  it "emptyTransactionQuery has no filters" $ do
    let q = emptyTransactionQuery
    queryAccountId q `shouldBe` Nothing
    queryFrom q `shouldBe` Nothing
    queryTo q `shouldBe` Nothing
