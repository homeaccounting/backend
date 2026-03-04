{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Auth.TelegramSpec
-- Description : Tests for Telegram authentication
module Infrastructure.Auth.TelegramSpec (spec) where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Infrastructure.Auth.Telegram
import Test.Hspec

-- Test configuration
testConfig :: TelegramConfig
testConfig =
  TelegramConfig
    { botToken = "123456789:ABCdefGHIjklMNOpqrsTUVwxyz",
      botUsername = "test_bot",
      authMaxAge = 86400, -- 24 hours
      webhookUrl = Nothing,
      usePolling = True,
      pollingTimeout = 30
    }

-- Helper to create auth data
mkAuthData :: Int64 -> Text -> Int64 -> Text -> TelegramAuthData
mkAuthData tgId firstName' authDate' hash' =
  TelegramAuthData
    { id = tgId,
      firstName = firstName',
      lastName = Nothing,
      username = Nothing,
      photoUrl = Nothing,
      authDate = authDate',
      hash = hash'
    }

spec :: Spec
spec = describe "Telegram Authentication" $ do
  describe "verifyTelegramAuthWithTime" $ do
    it "rejects expired auth data" $ do
      let authTime = 1000000000 -- Very old timestamp
          currentTime = posixSecondsToUTCTime 2000000000 -- Much later
          authData = mkAuthData 12345 "Test" authTime "somehash"
      verifyTelegramAuthWithTime testConfig authData currentTime
        `shouldBe` Left AuthDataExpired

    it "rejects invalid hash" $ do
      let authTime = 2000000000
          currentTime = posixSecondsToUTCTime (fromIntegral authTime + 100)
          authData = mkAuthData 12345 "Test" authTime "invalidhash"
      verifyTelegramAuthWithTime testConfig authData currentTime
        `shouldBe` Left InvalidHash

  describe "authenticateViaTelegram" $ do
    it "returns error for invalid auth" $ do
      let authData = mkAuthData 12345 "Test" 1700000000 "invalidhash"
      result <- authenticateViaTelegram testConfig authData
      case result of
        Left _ -> pure ()
        Right _ -> expectationFailure "Expected authentication to fail"

  describe "TelegramConfig" $ do
    it "has correct default max age of 24 hours" $ do
      testConfig.authMaxAge `shouldBe` 86400

    it "has correct default polling timeout of 30 seconds" $ do
      testConfig.pollingTimeout `shouldBe` 30
