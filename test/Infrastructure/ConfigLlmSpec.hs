{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ConfigLlmSpec (spec) where

import Data.Aeson (eitherDecode)
import Infrastructure.Config (LlmConfig (..), llmActive)
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "LlmConfig FromJSON" $ do
    it "parses full object" $ do
      let j = eitherDecode "{\"enabled\":true,\"base_url\":\"http://x/v1\",\"model\":\"m\",\"api_key\":\"k\",\"timeout_ms\":15000}" :: Either String LlmConfig
      fmap (.model) j `shouldBe` Right ("m" :: Text)
    it "applies defaults for missing optional fields" $ do
      let j = eitherDecode "{}" :: Either String LlmConfig
      fmap (.enabled) j `shouldBe` Right True

  describe "llmActive" $ do
    let cfg on key = LlmConfig {enabled = on, baseUrl = "http://x/v1", model = "m", apiKey = key, timeoutMs = 1}
    it "is True when enabled with a key" $ llmActive (cfg True "k") `shouldBe` True
    it "is False when enabled without a key" $ llmActive (cfg True "") `shouldBe` False
    it "is False when explicitly disabled, even with a key" $ llmActive (cfg False "k") `shouldBe` False
