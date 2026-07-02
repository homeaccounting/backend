{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.Transaction.IntentSpec (spec) where

import Application.Services.Prompt.Transaction.Intent
  ( IntentKind (..),
    PromptContext (..),
    TransactionIntent (..),
    decodeTransactionIntent,
    transactionGuide,
  )
import RIO
import qualified RIO.Text as T
import Test.Hspec

sampleContext :: PromptContext
sampleContext =
  PromptContext
    { accountNames = ["Cash", "Card"],
      incomeCategoryNames = ["Salary"],
      expenseCategoryNames = ["Food", "Transport"],
      labelNames = []
    }

spec :: Spec
spec = describe "Application.Services.Prompt.Transaction.Intent" $ do
  describe "decodeTransactionIntent" $ do
    it "decodes an expense with nulls" $ do
      let j = "{\"kind\":\"expense\",\"amount\":\"123\",\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"category\":\"Food\",\"description\":null,\"date\":null}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` ExpenseKind
          i.amount `shouldBe` "123"
          i.sourceAccount `shouldBe` Just "Cash"
          i.category `shouldBe` Just "Food"
        Left e -> expectationFailure (T.unpack e)
    it "decodes a transfer" $ do
      let j = "{\"kind\":\"transfer\",\"amount\":\"200\",\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\"}"
      case decodeTransactionIntent j of
        Right i -> i.kind `shouldBe` TransferKind
        Left e -> expectationFailure (T.unpack e)
    it "ignores the envelope intent field when present" $ do
      let j = "{\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":\"5\",\"sourceAccount\":\"Cash\"}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` ExpenseKind
          i.amount `shouldBe` "5"
        Left e -> expectationFailure (T.unpack e)
    it "rejects an unknown kind"
      $ decodeTransactionIntent "{\"kind\":\"nonsense\",\"amount\":\"1\",\"sourceAccount\":\"x\"}"
      `shouldSatisfy` isLeft
    it "rejects non-JSON"
      $ decodeTransactionIntent "oops"
      `shouldSatisfy` isLeft
  describe "transactionGuide" $ do
    let guide = transactionGuide sampleContext
    it "embeds account names" $ ("Cash" `T.isInfixOf` guide) `shouldBe` True
    it "embeds category names" $ ("Food" `T.isInfixOf` guide) `shouldBe` True
    it "mentions multilingual mapping" $ ("language" `T.isInfixOf` T.toLower guide) `shouldBe` True
    it "names the transaction intent" $ ("transaction" `T.isInfixOf` guide) `shouldBe` True
