{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.IdTokenConfigSpec (spec) where

import Data.Aeson (eitherDecode)
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (IdTokenConfig (..), OAuthConfig (..), defaultIdTokenConfig, idTokenAudiences)
import Infrastructure.Config (AppConfig (..), loadConfigWithEnv)
import RIO
import System.Environment (unsetEnv)
import Test.Hspec

spec :: Spec
spec = describe "IdTokenConfig" $ do
  it "defaults both lists when the id_token block is missing"
    $ fmap (.idToken) (eitherDecode "{}" :: Either String OAuthConfig)
    `shouldBe` Right defaultIdTokenConfig

  it "splits, trims and drops empty entries in a comma-separated string"
    $ eitherDecode "{\"google_audiences\":\" a , b,,\",\"apple_audiences\":\"\"}"
    `shouldBe` Right IdTokenConfig {googleAudiences = ["a", "b"], appleAudiences = []}

  it "accepts a JSON array"
    $ fmap (.appleAudiences) (eitherDecode "{\"apple_audiences\":[\"x\",\"y\"]}" :: Either String IdTokenConfig)
    `shouldBe` Right ["x", "y"]

  it "maps providers to their audience list" $ do
    let c = IdTokenConfig {googleAudiences = ["g"], appleAudiences = ["a"]}
    idTokenAudiences c Google `shouldBe` ["g"]
    idTokenAudiences c Apple `shouldBe` ["a"]
    idTokenAudiences c GitHub `shouldBe` []

  it "config/local.yaml yields the official defaults when the env vars are unset" $ do
    unsetEnv "GOOGLE_ID_TOKEN_AUDIENCES"
    unsetEnv "APPLE_ID_TOKEN_AUDIENCES"
    res <- loadConfigWithEnv "config/local.yaml"
    fmap (\c -> c.oauth.idToken) res `shouldBe` Right defaultIdTokenConfig
