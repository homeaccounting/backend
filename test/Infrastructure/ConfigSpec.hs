{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ConfigSpec (spec) where

import Data.Aeson (Result (..), Value (..), fromJSON, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Vector as V
import Infrastructure.Config
  ( BankingConfig (..),
    BankingProvidersConfig (..),
    MonobankProviderConfig (..),
    anyProviderEnabled,
    bankingFeatureAvailable,
    substituteEnvVars,
  )
import RIO
import qualified RIO.Text as T
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Hspec

-- | Set an env var for the duration of an action, then restore the previous state.
withEnv :: String -> String -> IO a -> IO a
withEnv name value action = do
  prev <- lookupEnv name
  setEnv name value
  action `finally` case prev of
    Just v -> setEnv name v
    Nothing -> unsetEnv name

-- | Unset an env var for the duration of an action, then restore the previous state.
withUnsetEnv :: String -> IO a -> IO a
withUnsetEnv name action = do
  prev <- lookupEnv name
  unsetEnv name
  action `finally` for_ prev (setEnv name)

spec :: Spec
spec = do
  describe "substituteEnvVars (existing behaviour)" $ do
    it "substitutes a whole-string ${VAR} with the env value as String" $ do
      result <-
        withEnv "CFG_TEST_STR" "hello"
          $ substituteEnvVars (String "${CFG_TEST_STR}")
      result `shouldBe` Right (String "hello")

    it "coerces a numeric-looking whole-string substitution to Number" $ do
      result <-
        withEnv "CFG_TEST_NUM" "5432"
          $ substituteEnvVars (String "${CFG_TEST_NUM}")
      result `shouldBe` Right (Number 5432)

    it "coerces a boolean whole-string substitution to Bool" $ do
      trueResult <-
        withEnv "CFG_TEST_BOOL" "true"
          $ substituteEnvVars (String "${CFG_TEST_BOOL}")
      trueResult `shouldBe` Right (Bool True)
      falseResult <-
        withEnv "CFG_TEST_BOOL" "false"
          $ substituteEnvVars (String "${CFG_TEST_BOOL}")
      falseResult `shouldBe` Right (Bool False)

    it "coerces the literal 'null' to Null" $ do
      result <-
        withEnv "CFG_TEST_NULL" "null"
          $ substituteEnvVars (String "${CFG_TEST_NULL}")
      result `shouldBe` Right Null

    it "returns an empty String when the resolved value is empty (coerceValue \"\" guard)"
      $ withUnsetEnv "CFG_TEST_EMPTY_VAL"
      $ do
        -- On macOS setEnv to "" is equivalent to unset; use :- empty-default
        -- to reach the same empty-string coercion path.
        result <- substituteEnvVars (String "${CFG_TEST_EMPTY_VAL:-}")
        result `shouldBe` Right (String "")

    it "uses the :- default when the variable is unset" $ do
      withUnsetEnv "CFG_TEST_MISSING" $ do
        result <- substituteEnvVars (String "${CFG_TEST_MISSING:-default_value}")
        result `shouldBe` Right (String "default_value")

    it "uses an empty :- default when the variable is unset" $ do
      withUnsetEnv "CFG_TEST_MISSING_EMPTY" $ do
        result <- substituteEnvVars (String "${CFG_TEST_MISSING_EMPTY:-}")
        result `shouldBe` Right (String "")

    it "returns Left when a required variable is unset" $ do
      withUnsetEnv "CFG_TEST_REQUIRED" $ do
        result <- substituteEnvVars (String "${CFG_TEST_REQUIRED}")
        case result of
          Left err ->
            T.isInfixOf "CFG_TEST_REQUIRED" err
              `shouldBe` True
          Right _ ->
            expectationFailure "Expected Left but got Right"

    it "leaves strings with no ${...} untouched" $ do
      result <- substituteEnvVars (String "plain-string")
      result `shouldBe` Right (String "plain-string")

    it "recurses into objects and substitutes all String values" $ do
      let obj =
            Object
              $ KM.fromList
                [ ("host", String "${CFG_TEST_HOST}"),
                  ("port", String "${CFG_TEST_PORT}")
                ]
      result <-
        withEnv "CFG_TEST_HOST" "localhost"
          $ withEnv "CFG_TEST_PORT" "5432"
          $ substituteEnvVars obj
      result
        `shouldBe` Right
          ( Object
              $ KM.fromList
                [ ("host", String "localhost"),
                  ("port", Number 5432)
                ]
          )

    it "recurses into arrays and substitutes all String elements" $ do
      let arr = Array $ V.fromList [String "${CFG_TEST_ITEM1}", String "${CFG_TEST_ITEM2}"]
      result <-
        withEnv "CFG_TEST_ITEM1" "alpha"
          $ withEnv "CFG_TEST_ITEM2" "beta"
          $ substituteEnvVars arr
      result `shouldBe` Right (Array $ V.fromList [String "alpha", String "beta"])

    it "passes non-String JSON values through unchanged" $ do
      result <- substituteEnvVars (Number 42)
      result `shouldBe` Right (Number 42)
      result2 <- substituteEnvVars (Bool True)
      result2 `shouldBe` Right (Bool True)
      result3 <- substituteEnvVars Null
      result3 `shouldBe` Right Null

  describe "substituteEnvVars (in-string substitution)" $ do
    it "substitutes ${VAR} inside a larger string"
      $ withEnv "CFG_TEST_BASE" "https://homeaccounting.com"
      $ do
        result <- substituteEnvVars (String "${CFG_TEST_BASE}/api/telegram/webhook")
        result
          `shouldBe` Right (String "https://homeaccounting.com/api/telegram/webhook")

    it "substitutes multiple ${VAR} occurrences in one string"
      $ withEnv "CFG_TEST_A" "1"
      $ withEnv "CFG_TEST_B" "2"
      $ do
        result <- substituteEnvVars (String "${CFG_TEST_A}-${CFG_TEST_B}")
        result `shouldBe` Right (String "1-2")

    it "uses :- default when variable is unset inside a larger string"
      $ withUnsetEnv "CFG_TEST_MISSING2"
      $ do
        result <- substituteEnvVars (String "${CFG_TEST_MISSING2:-fallback}/path")
        result `shouldBe` Right (String "fallback/path")

    it "returns Left when a required variable is unset inside a larger string"
      $ withUnsetEnv "CFG_TEST_REQ2"
      $ do
        result <- substituteEnvVars (String "prefix-${CFG_TEST_REQ2}-suffix")
        result `shouldSatisfy` isLeft

    it "preserves literal text surrounding the substitutions"
      $ withEnv "CFG_TEST_HOST2" "host.example"
      $ do
        result <- substituteEnvVars (String "https://${CFG_TEST_HOST2}:8080/x")
        result `shouldBe` Right (String "https://host.example:8080/x")

    it "does not coerce the result of in-string substitution to Number"
      $ withEnv "CFG_TEST_N" "42"
      $ do
        result <- substituteEnvVars (String "port=${CFG_TEST_N}")
        result `shouldBe` Right (String "port=42")

  describe "BankingConfig" $ do
    it "parses token_enc_key into tokenEncKey" $ do
      let payload =
            object
              [ "enabled" .= True,
                "token_enc_key" .= ("***REMOVED***" :: T.Text)
              ]
      case fromJSON payload :: Result BankingConfig of
        Success cfg -> do
          cfg.tokenEncKey `shouldBe` "***REMOVED***"
          cfg.enabled `shouldBe` True
        Error e -> expectationFailure ("failed to parse BankingConfig: " <> e)

    it "defaults tokenEncKey to empty when token_enc_key is absent" $ do
      let payload = object ["enabled" .= False]
      case fromJSON payload :: Result BankingConfig of
        Success cfg -> cfg.tokenEncKey `shouldBe` ""
        Error e -> expectationFailure ("failed to parse BankingConfig: " <> e)

  describe "bankingFeatureAvailable / anyProviderEnabled" $ do
    let mkCfg masterOn providerOn =
          BankingConfig masterOn (BankingProvidersConfig (MonobankProviderConfig providerOn "https://api.monobank.ua")) ""
    it "is False when the master switch is off"
      $ bankingFeatureAvailable (mkCfg False True)
      `shouldBe` False
    it "is False when the master switch is on but no provider is enabled"
      $ bankingFeatureAvailable (mkCfg True False)
      `shouldBe` False
    it "is True when the master switch is on and a provider is enabled"
      $ bankingFeatureAvailable (mkCfg True True)
      `shouldBe` True
    it "anyProviderEnabled reflects the monobank provider flag" $ do
      anyProviderEnabled (BankingProvidersConfig (MonobankProviderConfig False "x")) `shouldBe` False
      anyProviderEnabled (BankingProvidersConfig (MonobankProviderConfig True "x")) `shouldBe` True
