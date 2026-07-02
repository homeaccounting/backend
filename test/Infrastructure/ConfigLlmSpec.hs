{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ConfigLlmSpec (spec) where

import Data.Aeson (eitherDecode)
import Infrastructure.Config (LlmConfig (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "LlmConfig FromJSON" $ do
  it "parses full object" $ do
    let j = eitherDecode "{\"enabled\":true,\"base_url\":\"http://x/v1\",\"model\":\"m\",\"api_key\":\"k\",\"timeout_ms\":15000}" :: Either String LlmConfig
    fmap (.model) j `shouldBe` Right ("m" :: Text)
  it "applies defaults for missing optional fields" $ do
    let j = eitherDecode "{}" :: Either String LlmConfig
    fmap (.enabled) j `shouldBe` Right False
