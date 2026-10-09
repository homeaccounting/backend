{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.JWTConfigSpec (spec) where

import Data.Aeson (eitherDecode)
import Infrastructure.Auth.JWT (JWTConfig (..))
import RIO
import Test.Hspec

spec :: Spec
spec = describe "JWTConfig refresh expiry" $ do
  let base = "\"jwt_secret\":\"s\",\"jwt_expiry_seconds\":3600,\"jwt_issuer\":\"i\",\"jwt_audience\":\"a\""
  it "defaults to 60 days when absent"
    $ fmap (.refreshExpirySeconds) (eitherDecode ("{" <> base <> "}") :: Either String JWTConfig)
    `shouldBe` Right 5184000
  it "reads jwt_refresh_expiry_seconds"
    $ fmap (.refreshExpirySeconds) (eitherDecode ("{" <> base <> ",\"jwt_refresh_expiry_seconds\":120}") :: Either String JWTConfig)
    `shouldBe` Right 120
