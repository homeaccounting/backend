{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Telegram.I18nSpec (spec) where

import Domain.Localization.Language (Language (..))
import Telegram.I18n
  ( AccountStrings (..),
    CommandStrings (..),
    CommonStrings (..),
    ErrorStrings (..),
    PromptStrings (..),
    TelegramStrings (..),
    TransactionStrings (..),
    telegramStrings,
  )
import Telegram.Types (botCommands)
import Test.Hspec

spec :: Spec
spec = do
  telegramStringsSpec
  botCommandsSpec

telegramStringsSpec :: Spec
telegramStringsSpec = describe "Telegram.I18n.telegramStrings" $ do
  it "renders English chrome for En" $
    (telegramStrings En).common.cancelled `shouldBe` "Operation cancelled."

  it "renders Ukrainian chrome for Uk" $
    (telegramStrings Uk).common.cancelled `shouldBe` "Операцію скасовано."

  it "interpolates the unknown-command message (En)" $
    (telegramStrings En).common.unknownCommand "/foo"
      `shouldBe` "Unknown command: /foo. Use /help to see available commands."

  it "interpolates account-created (En)" $
    (telegramStrings En).accounts.createdSelected "Cash" "USD"
      `shouldBe` "Account \"Cash\" created and selected! (USD)"

  it "localizes the transaction type label (Uk)" $
    (telegramStrings Uk).transactions.expenseLabel `shouldBe` "Витрата"

  it "keeps the English transaction type label byte-identical" $
    (telegramStrings En).transactions.transferLabel `shouldBe` "Transfer"

  it "renders the failed status marker with its reason (En)" $
    (telegramStrings En).transactions.failedMarker "insufficient funds"
      `shouldBe` "  [Failed: insufficient funds]"

  it "renders the recorded confirmation header (En)" $
    (telegramStrings En).transactions.recorded "Income"
      `shouldBe` "\9989 Income recorded"

  it "renders a prompt failed-transaction line (En)" $
    (telegramStrings En).prompt.failedTransactionLine 1 "bad input"
      `shouldBe` " \8226 transaction 1: bad input"

  it "carries a command description (En)" $
    (telegramStrings En).commands.start `shouldBe` "Start using the bot"

  it "carries a generic error message (En)" $
    (telegramStrings En).errors.accountNotFound `shouldBe` "Account not found."

botCommandsSpec :: Spec
botCommandsSpec = describe "Telegram.Types.botCommands" $ do
  it "keeps command tokens stable across locales" $
    map fst (botCommands Uk) `shouldBe` map fst (botCommands En)

  it "localizes command descriptions" $
    map snd (botCommands Uk) `shouldNotBe` map snd (botCommands En)

  it "uses the localized description for a known command (Uk)" $
    lookup "/start" (botCommands Uk) `shouldBe` Just "Почати користуватися ботом"
