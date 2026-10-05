{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Auth.TelegramSpec
-- Description : Tests for the Telegram webhook secret token
module Infrastructure.Auth.TelegramSpec (spec) where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import qualified Data.Text as T
import Infrastructure.Auth.Telegram
import Test.Hspec
import Test.QuickCheck

botToken :: T.Text
botToken = "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"

spec :: Spec
spec = describe "Telegram webhook secret" $ do
  describe "webhookSecret" $ do
    it "is absent when the bot token is empty" $
      webhookSecret "" `shouldBe` Nothing

    it "is deterministic per bot token" $
      webhookSecret botToken `shouldBe` webhookSecret botToken

    it "differs between bot tokens" $
      webhookSecret botToken `shouldNotBe` webhookSecret "654321:other"

    it "never reveals the bot token" $
      fmap (T.isInfixOf botToken) (webhookSecret botToken) `shouldBe` Just False

    it "satisfies Telegram's secret_token format (1-256 chars of A-Za-z0-9_-)" $
      property $ \(NonEmpty s) ->
        let token = T.pack s
            valid c = isAsciiUpper c || isAsciiLower c || isDigit c || c == '_' || c == '-'
         in case webhookSecret token of
              Nothing -> T.null token
              Just secret -> T.length secret >= 1 && T.length secret <= 256 && T.all valid secret

  describe "verifyWebhookSecret" $ do
    it "accepts the derived secret" $
      verifyWebhookSecret botToken (webhookSecret botToken) `shouldBe` True

    it "rejects a missing header" $
      verifyWebhookSecret botToken Nothing `shouldBe` False

    it "rejects a wrong secret" $
      verifyWebhookSecret botToken (Just "forged") `shouldBe` False

    it "rejects the secret of another bot" $
      verifyWebhookSecret botToken (webhookSecret "654321:other") `shouldBe` False

    it "rejects everything when the bot is disabled (empty token)" $ do
      verifyWebhookSecret "" Nothing `shouldBe` False
      verifyWebhookSecret "" (Just "") `shouldBe` False
