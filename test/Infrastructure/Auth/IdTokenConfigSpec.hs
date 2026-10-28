{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.IdTokenConfigSpec (spec) where

import Data.Aeson (Value (..), eitherDecode)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import qualified Data.Yaml as Yaml
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (IdTokenConfig (..), OAuthConfig (..), defaultIdTokenConfig, idTokenAudiences)
import Infrastructure.Config (AppConfig (..), loadConfigWithEnv, substituteEnvVars)
import RIO
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Hspec

idTokenVars :: [String]
idTokenVars = ["GOOGLE_ID_TOKEN_AUDIENCES", "APPLE_ID_TOKEN_AUDIENCES", "ID_TOKEN_SERVER_URLS"]

-- | Run with the variables unset, restoring their previous values afterwards.
withEnvUnset :: [String] -> IO a -> IO a
withEnvUnset vars act = bracket save restore (const (mapM_ unsetEnv vars >> act))
  where
    save = mapM (\v -> (,) v <$> lookupEnv v) vars
    restore = mapM_ (\(v, old) -> maybe (unsetEnv v) (setEnv v) old)

-- | The @oauth.id_token@ block of a config file, env-substituted. Reads only
-- that block, so prod.yaml's required secrets need not be set.
loadIdTokenBlock :: FilePath -> IO (Either String IdTokenConfig)
loadIdTokenBlock path = do
  doc <- Yaml.decodeFileThrow path
  let block = case doc of
        Object o | Just (Object oauth) <- KM.lookup "oauth" o, Just b <- KM.lookup "id_token" oauth -> Just b
        _ -> Nothing
  case block of
    Nothing -> pure (Left ("no oauth.id_token block in " <> path))
    Just b -> either (Left . show) (parseEither Aeson.parseJSON) <$> substituteEnvVars b

spec :: Spec
spec = describe "IdTokenConfig" $ do
  it "defaults both lists when the id_token block is missing"
    $ fmap (.idToken) (eitherDecode "{}" :: Either String OAuthConfig)
    `shouldBe` Right defaultIdTokenConfig

  it "splits, trims and drops empty entries in a comma-separated string"
    $ eitherDecode "{\"google_audiences\":\" a , b,,\",\"apple_audiences\":\"\"}"
    `shouldBe` Right IdTokenConfig {googleAudiences = ["a", "b"], appleAudiences = [], serverUrls = []}

  it "accepts a JSON array"
    $ fmap (.appleAudiences) (eitherDecode "{\"apple_audiences\":[\"x\",\"y\"]}" :: Either String IdTokenConfig)
    `shouldBe` Right ["x", "y"]

  it "parses server_urls like the audiences, defaulting to none" $ do
    fmap (.serverUrls) (eitherDecode "{\"server_urls\":\" http://a , https://b,,\"}" :: Either String IdTokenConfig)
      `shouldBe` Right ["http://a", "https://b"]
    fmap (.serverUrls) (eitherDecode "{\"server_urls\":[\"http://a\"]}" :: Either String IdTokenConfig)
      `shouldBe` Right ["http://a"]
    fmap (.serverUrls) (eitherDecode "{}" :: Either String IdTokenConfig) `shouldBe` Right []

  it "maps providers to their audience list" $ do
    let c = IdTokenConfig {googleAudiences = ["g"], appleAudiences = ["a"], serverUrls = []}
    idTokenAudiences c Google `shouldBe` ["g"]
    idTokenAudiences c Apple `shouldBe` ["a"]
    idTokenAudiences c GitHub `shouldBe` []

  it "config/local.yaml yields the official defaults when the env vars are unset" $ withEnvUnset idTokenVars $ do
    res <- loadConfigWithEnv "config/local.yaml"
    fmap (\c -> c.oauth.idToken) res `shouldBe` Right defaultIdTokenConfig

  it "config/prod.yaml yields the official defaults when the env vars are unset"
    $ withEnvUnset idTokenVars
    $ loadIdTokenBlock "config/prod.yaml"
    `shouldReturn` Right defaultIdTokenConfig
