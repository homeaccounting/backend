{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.ConfigurationLocalizationAPISpec
-- Description : HTTP-level tests for the language/country/localization-options
--               configuration endpoints.
--
-- Runs through the full Servant stack via hspec-wai against a seeded in-memory
-- event store. Verifies route wiring, the country regional preset applied
-- end-to-end, validation rejection, and the localization-options registry.
module Web.API.ConfigurationLocalizationAPISpec (spec) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import Network.HTTP.Types (status200, status204, status400)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkAppSeeded)
import Testkit.HspecWai (jsonAuthHeaders, registerAndGetToken)
import Web.API.ConfigurationAPI (ConfigurationResponse (..), LocalizationOptionsResponse (..))

spec :: Spec
spec = do
  localizationOptionsSpec
  changeCountrySpec
  changeLanguageSpec

localizationOptionsSpec :: Spec
localizationOptionsSpec =
  describe "GET /api/users/me/configuration/localization-options"
    $ with mkAppSeeded
    $ do
      it "returns the supported locales and countries" $ do
        tok <- registerAndGetToken
        resp <- request "GET" "/api/users/me/configuration/localization-options" (jsonAuthHeaders tok) ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String LocalizationOptionsResponse of
            Left err -> expectationFailure $ "not a LocalizationOptionsResponse: " <> err
            Right opts -> do
              let LocalizationOptionsResponse {languages = langs, countries = ctrys} = opts
              langs `shouldBe` ["en", "uk"]
              ctrys `shouldSatisfy` (\cs -> all (`elem` cs) ["US", "UA", "DE"])

changeCountrySpec :: Spec
changeCountrySpec =
  describe "PUT /api/users/me/configuration/country"
    $ with mkAppSeeded
    $ do
      it "applies the UA preset and reflects it in the configuration" $ do
        tok <- registerAndGetToken
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/country"
            (jsonAuthHeaders tok)
            (encode (object ["country" .= ("UA" :: Text)]))
        liftIO $ simpleStatus resp `shouldSatisfy` (\s -> s == status204 || s == status200)
        cfgResp <- request "GET" "/api/users/me/configuration" (jsonAuthHeaders tok) ""
        liftIO $ case eitherDecode (simpleBody cfgResp) :: Either String ConfigurationResponse of
          Left err -> expectationFailure $ "not a ConfigurationResponse: " <> err
          Right cfg -> do
            let ConfigurationResponse {language = lang, country = ctry, baseCurrency = bc, defaultCurrency = dc} = cfg
            lang `shouldBe` "uk"
            ctry `shouldBe` Just "UA"
            bc `shouldBe` "UAH"
            dc `shouldBe` "UAH"

      it "rejects an unsupported country with 400" $ do
        tok <- registerAndGetToken
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/country"
            (jsonAuthHeaders tok)
            (encode (object ["country" .= ("XX" :: Text)]))
        liftIO $ simpleStatus resp `shouldBe` status400

changeLanguageSpec :: Spec
changeLanguageSpec =
  describe "PUT /api/users/me/configuration/language"
    $ with mkAppSeeded
    $ do
      it "changes the UI language" $ do
        tok <- registerAndGetToken
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/language"
            (jsonAuthHeaders tok)
            (encode (object ["language" .= ("uk" :: Text)]))
        liftIO $ simpleStatus resp `shouldSatisfy` (\s -> s == status204 || s == status200)
        cfgResp <- request "GET" "/api/users/me/configuration" (jsonAuthHeaders tok) ""
        liftIO $ case eitherDecode (simpleBody cfgResp) :: Either String ConfigurationResponse of
          Left err -> expectationFailure $ "not a ConfigurationResponse: " <> err
          Right cfg -> do
            let ConfigurationResponse {language = lang} = cfg
            lang `shouldBe` "uk"

      it "rejects an unsupported language with 400" $ do
        tok <- registerAndGetToken
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/language"
            (jsonAuthHeaders tok)
            (encode (object ["language" .= ("fr" :: Text)]))
        liftIO $ simpleStatus resp `shouldBe` status400
