{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.BuilderSpec (spec) where

import Application.Services.Prompt.Builder (buildMessages)
import Application.Services.Prompt.Transaction.Intent
  ( PromptContext (..),
    recordTransactionsGuide,
  )
import Infrastructure.Llm.Provider (LlmMessage (..), LlmRole (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec

sampleContext :: PromptContext
sampleContext =
  PromptContext
    { accountNames = ["Cash", "Bank"],
      incomeCategoryNames = ["Salary"],
      expenseCategoryNames = ["Food"],
      labelNames = []
    }

spec :: Spec
spec = describe "Application.Services.Prompt.Builder.buildMessages" $ do
  let today = "2026-07-01"
      userText = "готівка 123 їжа"
      guide = recordTransactionsGuide sampleContext
      intentNames = ["record_transactions"]
      msgs = buildMessages today intentNames [guide] userText

  it "returns exactly a System then a User message" $ do
    map (.role) msgs `shouldBe` [System, User]

  it "System message contains today's date" $ do
    let sys = systemContent msgs
    (today `T.isInfixOf` sys) `shouldBe` True

  it "System message mentions the intent envelope field and the passed intent names" $ do
    let sys = systemContent msgs
    ("intent" `T.isInfixOf` sys) `shouldBe` True
    all (`T.isInfixOf` sys) intentNames `shouldBe` True

  it "System message embeds the intent guide content (e.g. an account name)" $ do
    let sys = systemContent msgs
    ("Cash" `T.isInfixOf` sys) `shouldBe` True

  it "User message is the raw user text verbatim" $ do
    userContent msgs `shouldBe` userText
  where
    systemContent ms = T.concat [m.content | m <- ms, isSystem m.role]
    userContent ms = T.concat [m.content | m <- ms, not (isSystem m.role)]
    isSystem System = True
    isSystem _ = False
