{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.Transaction.IntentSpec (spec) where

import Application.Services.Prompt.Transaction.Intent
  ( IntentAllocation (..),
    IntentKind (..),
    PromptContext (..),
    TransactionIntent (..),
    decodeTransactionIntent,
    transactionGuide,
  )
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T
import Test.Hspec

-- | Encode a JSON 'Text' as a UTF-8 lazy 'ByteString'. Necessary for the
-- Cyrillic examples: an 'IsString' 'ByteString' literal truncates each char to
-- a byte (Latin1), corrupting multibyte text; going through 'encodeUtf8' keeps
-- the bytes correct.
utf8 :: T.Text -> BL.ByteString
utf8 = BL.fromStrict . T.encodeUtf8

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
    it "decodes an expense with a single allocation" $ do
      let j = "{\"kind\":\"expense\",\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null,\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` ExpenseKind
          i.sourceAccount `shouldBe` Just "Cash"
          map (.amount) i.allocations `shouldBe` ["123"]
          map (.category) i.allocations `shouldBe` [Just "Food"]
        Left e -> expectationFailure (T.unpack e)
    it "decodes a transfer" $ do
      let j = "{\"kind\":\"transfer\",\"amount\":\"200\",\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\"}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` TransferKind
          i.amount `shouldBe` Just "200"
        Left e -> expectationFailure (T.unpack e)
    it "ignores the envelope intent field when present" $ do
      let j = "{\"intent\":\"transaction\",\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"5\",\"category\":null,\"comment\":null}]}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` ExpenseKind
          map (.amount) i.allocations `shouldBe` ["5"]
        Left e -> expectationFailure (T.unpack e)
    it "decodes the 5-line issue example: each line is one allocation with its comment" $ do
      let js =
            "{\"intent\":\"transaction\",\"kind\":\"expense\",\"currency\":null,\
            \\"sourceAccount\":null,\"targetAccount\":null,\"description\":null,\"date\":null,\
            \\"allocations\":[\
            \{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"огірки розсада\"},\
            \{\"amount\":\"700\",\"category\":null,\"comment\":\"квіти\"},\
            \{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"яйця\"},\
            \{\"amount\":\"500\",\"category\":\"Food\",\"comment\":\"овочі\"},\
            \{\"amount\":\"160\",\"category\":\"Food\",\"comment\":\"огірки зелень\"}]}"
      case decodeTransactionIntent (utf8 js) of
        Right ti -> do
          ti.kind `shouldBe` ExpenseKind
          length ti.allocations `shouldBe` 5
          map (.amount) ti.allocations `shouldBe` ["200", "700", "200", "500", "160"]
          map (.comment) ti.allocations
            `shouldBe` map Just ["огірки розсада", "квіти", "яйця", "овочі", "огірки зелень"]
        Left e -> expectationFailure (T.unpack e)
    it "decodes a transfer with a top-level amount and no allocations" $ do
      let js =
            "{\"intent\":\"transaction\",\"kind\":\"transfer\",\"amount\":\"200\",\
            \\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\",\"currency\":null,\
            \\"description\":null,\"date\":null}"
      case decodeTransactionIntent js of
        Right ti -> do
          ti.kind `shouldBe` TransferKind
          ti.amount `shouldBe` Just "200"
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
