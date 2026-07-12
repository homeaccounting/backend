{-# LANGUAGE OverloadedStrings #-}

module Telegram.KeyboardsSpec (spec) where

import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Domain.Core.Types (AccountId, Currency (..), Money, unsafeAccountId, unsafeMoney)
import Telegram.Keyboards
  ( InlineButton (..),
    InlineKeyboard (..),
    accountSelectionKeyboard,
  )
import Test.Hspec

acc :: Int -> AccountId
acc n =
  let s = "00000000-0000-0000-0000-" <> replicate (12 - length (show n)) '0' <> show n
   in unsafeAccountId (fromMaybe (error "bad uuid") (UUID.fromString s))

-- Two sample accounts with USD balances.
sampleAccounts :: [(AccountId, T.Text, Money)]
sampleAccounts =
  [ (acc 1, "Cash", unsafeMoney USD 1200),
    (acc 2, "Card", unsafeMoney USD 350)
  ]

buttonTexts :: InlineKeyboard -> [T.Text]
buttonTexts kb = [b.text | row <- kb.rows, b <- row]

spec :: Spec
spec = do
  describe "accountSelectionKeyboard" $ do
    it "prefixes the selected account with a check mark in the select context" $ do
      let kb = accountSelectionKeyboard sampleAccounts (Just (acc 2)) "select"
          texts = buttonTexts kb
      any (\t -> "Card" `T.isInfixOf` t && "\x2713" `T.isInfixOf` t) texts `shouldBe` True
      any (\t -> "Cash" `T.isInfixOf` t && "\x2713" `T.isInfixOf` t) texts `shouldBe` False

    it "adds a Clear selection row when an account is selected in the select context" $ do
      let kb = accountSelectionKeyboard sampleAccounts (Just (acc 1)) "select"
      any (\b -> b.callbackData == "unselect") (concat kb.rows) `shouldBe` True

    it "omits the Clear selection row when nothing is selected" $ do
      let kb = accountSelectionKeyboard sampleAccounts Nothing "select"
      any (\b -> b.callbackData == "unselect") (concat kb.rows) `shouldBe` False

    it "never marks or offers Clear in transfer contexts" $ do
      let kb = accountSelectionKeyboard sampleAccounts (Just (acc 1)) "transfer_src"
          texts = buttonTexts kb
      any (\t -> "\x2713" `T.isInfixOf` t) texts `shouldBe` False
      any (\b -> b.callbackData == "unselect") (concat kb.rows) `shouldBe` False
