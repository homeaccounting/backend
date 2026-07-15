{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.TypesSpec (spec) where

import Application.Services.Prompt.Transaction.Intent
  ( IntentAllocation (..),
    IntentKind (..),
    TransactionDecodeError (..),
    TransactionIntent (..),
  )
import Application.Services.Prompt.Types
  ( PromptDecodeError (..),
    PromptIntent (..),
    decodePromptIntent,
  )
import RIO
import Test.Hspec

isMalformed :: Either PromptDecodeError a -> Bool
isMalformed (Left (MalformedResponse _)) = True
isMalformed _ = False

spec :: Spec
spec = describe "Application.Services.Prompt.Types" $ do
  describe "decodePromptIntent" $ do
    it "decodes a well-formed record_transactions envelope" $ do
      let bs = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}]}"
      case decodePromptIntent bs of
        Right (RecordTransactionsIntent [Right ti]) -> do
          ti.kind `shouldBe` ExpenseKind
          map (.amount) ti.allocations `shouldBe` ["123"]
        other -> expectationFailure ("expected RecordTransactionsIntent, got: " <> show other)

    it "rejects an unknown intent name" $ do
      let bs = "{\"intent\":\"build_report\"}"
      decodePromptIntent bs `shouldBe` Left (UnknownIntent "build_report")

    it "treats a missing intent field as malformed" $ do
      let bs = "{\"kind\":\"expense\",\"amount\":\"1\"}"
      decodePromptIntent bs `shouldSatisfy` isMalformed

    it "treats non-JSON as malformed" $ do
      let bs = "oops"
      decodePromptIntent bs `shouldSatisfy` isMalformed

    it "recovers a bad transactions element as a Left, not a malformed envelope" $ do
      -- 'kind' is required by the per-transaction parser; a single element that
      -- omits it is recovered per-element rather than failing the whole decode.
      let bs = "{\"intent\":\"record_transactions\",\"transactions\":[{\"sourceAccount\":\"Cash\"}]}"
      case decodePromptIntent bs of
        Right (RecordTransactionsIntent [Left (TransactionDecodeError _)]) -> pure ()
        other -> expectationFailure ("expected one recovered bad element, got: " <> show other)

    it "treats a record_transactions payload without the transactions array as malformed" $ do
      let bs = "{\"intent\":\"record_transactions\"}"
      decodePromptIntent bs `shouldSatisfy` isMalformed

    it "treats a non-array transactions field as malformed" $ do
      let bs = "{\"intent\":\"record_transactions\",\"transactions\":\"nope\"}"
      decodePromptIntent bs `shouldSatisfy` isMalformed
