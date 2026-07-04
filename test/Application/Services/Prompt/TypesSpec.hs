{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.TypesSpec (spec) where

import Application.Services.Prompt.Transaction.Intent
  ( IntentAllocation (..),
    IntentKind (..),
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
    it "decodes a well-formed transaction envelope" $ do
      let bs = "{\"intent\":\"transaction\",\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}"
      case decodePromptIntent bs of
        Right (CreateTransactionIntent ti) -> do
          ti.kind `shouldBe` ExpenseKind
          map (.amount) ti.allocations `shouldBe` ["123"]
        other -> expectationFailure ("expected CreateTransactionIntent, got: " <> show other)

    it "rejects an unknown intent name" $ do
      let bs = "{\"intent\":\"build_report\"}"
      decodePromptIntent bs `shouldBe` Left (UnknownIntent "build_report")

    it "treats a missing intent field as malformed" $ do
      let bs = "{\"kind\":\"expense\",\"amount\":\"1\"}"
      decodePromptIntent bs `shouldSatisfy` isMalformed

    it "treats non-JSON as malformed" $ do
      let bs = "oops"
      decodePromptIntent bs `shouldSatisfy` isMalformed

    it "treats a transaction with a bad payload as malformed" $ do
      -- 'kind' is required by the transaction parser; omitting it is malformed.
      let bs = "{\"intent\":\"transaction\",\"sourceAccount\":\"Cash\"}"
      decodePromptIntent bs `shouldSatisfy` isMalformed
