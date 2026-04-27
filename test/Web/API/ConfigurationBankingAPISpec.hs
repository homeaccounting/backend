{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.ConfigurationBankingAPISpec
-- Description : HTTP-level tests for PUT /api/users/me/configuration/banking
--
-- Covers the partial-update banking configuration endpoint introduced in
-- Phase 2.  All tests run through the full Servant stack via hspec-wai;
-- the in-memory event store is seeded with the default configuration before
-- each test group so that income-category and expense-category dictionaries
-- are populated with well-known entries.
--
-- Setup: each test registers a fresh user via POST /api/auth/register to
-- obtain a JWT token that refers to an existing user record.  The default
-- configuration is seeded before building the application so both the
-- income-category and expense-category dictionaries are pre-populated.
--
-- Test matrix:
--   1. PUT with a valid income category UUID → 200, body shows the new value.
--   2. PUT with a valid expense category UUID → 200, body shows the new value.
--   3. PUT with body {} → 200, no state change.
--   4. PUT with income UUID not in dictionary → 400 CONFIGURATION_ERROR.
--   5. PUT with expense UUID not in dictionary → 400 CONFIGURATION_ERROR.
--   6. PUT without JWT → 401.
--   7. GET /api/users/me/configuration after PUT → banking.defaultIncomeCategory set.
module Web.API.ConfigurationBankingAPISpec (spec) where

import Data.Aeson (FromJSON (..), eitherDecode, encode, object, withObject, (.:), (.=))
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (Pair)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Configuration.Defaults
  ( expenseCategoryDictId,
    incomeCategoryDictId,
    mkDeterministicEntryId,
  )
import Domain.Core.Types (unDictionaryEntryId)
import Network.HTTP.Types
  ( hContentType,
    status200,
    status400,
    status401,
  )
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkAppSeeded)
import Testkit.HspecWai (bearerHeader, jsonAuthHeaders)
import Web.API.ConfigurationAPI (BankingConfigurationDTO (..), ConfigurationResponse (..))
import Web.Types (ErrorResponse (..))

-- -----------------------------------------------------------------------------
-- Well-known deterministic UUIDs from the default seed
-- -----------------------------------------------------------------------------

-- | UUID of the "Other" entry in the income-category dictionary.
incomeOtherUUID :: UUID.UUID
incomeOtherUUID = unDictionaryEntryId (mkDeterministicEntryId incomeCategoryDictId "Other")

-- | UUID of the "Other" entry in the expense-category dictionary.
expenseOtherUUID :: UUID.UUID
expenseOtherUUID = unDictionaryEntryId (mkDeterministicEntryId expenseCategoryDictId "Other")

-- | A random UUID that is not in any dictionary.
unknownUUID :: UUID.UUID
unknownUUID = UUID.fromWords 0xDEAD 0xBEEF 0 1

-- -----------------------------------------------------------------------------
-- Request helpers
-- -----------------------------------------------------------------------------

-- | Register a fresh user and return the JWT token.
--
-- Each test that needs a real user calls this helper so the JWT corresponds to
-- an existing user record in the read model.  A random UUID suffix is used
-- in the email address so multiple calls within the same app instance do not
-- collide on duplicate email registration.
registerAndGetToken :: WaiSession st Text
registerAndGetToken = do
  uid <- liftIO UUID.nextRandom
  let email = "test+" <> fromString (UUID.toString uid) <> "@example.com" :: Text
      body =
        encode
          $ object
            [ "email" .= email,
              "password" .= ("testpassword123" :: Text)
            ]
  resp <- request "POST" "/api/auth/register" [(hContentType, "application/json")] body
  case eitherDecode (simpleBody resp) :: Either String RegisterTokenResponse of
    Left err -> liftIO $ throwString $ "registerAndGetToken: failed to parse response: " <> err
    Right r -> pure r.token

-- | Minimal DTO to extract the token from the registration response.
data RegisterTokenResponse = RegisterTokenResponse
  { token :: Text
  }
  deriving (Show, Generic)

instance FromJSON RegisterTokenResponse where
  parseJSON = withObject "RegisterTokenResponse" $ \o ->
    RegisterTokenResponse <$> o .: "token"

-- -----------------------------------------------------------------------------
-- Spec entry point
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  updateBankingSpec
  updateBankingMccMapSpec
  getBankingInResponseSpec

-- -----------------------------------------------------------------------------
-- PUT /api/users/me/configuration/banking
-- -----------------------------------------------------------------------------

updateBankingSpec :: Spec
updateBankingSpec =
  describe "PUT /api/users/me/configuration/banking"
    $ with mkAppSeeded
    $ do
      it "returns 200 with updated defaultIncomeCategory when valid UUID supplied" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["defaultIncomeCategory" .= incomeOtherUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String BankingConfigurationDTO of
            Left err -> expectationFailure $ "body is not a BankingConfigurationDTO: " <> err
            Right dto ->
              dto.defaultIncomeCategory `shouldBe` Just incomeOtherUUID

      it "returns 200 with updated defaultExpenseCategory when valid UUID supplied" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["defaultExpenseCategory" .= expenseOtherUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String BankingConfigurationDTO of
            Left err -> expectationFailure $ "body is not a BankingConfigurationDTO: " <> err
            Right dto ->
              dto.defaultExpenseCategory `shouldBe` Just expenseOtherUUID

      it "returns 200 with no state change for empty body {}" $ do
        tok <- registerAndGetToken
        let body = encode $ object ([] :: [Pair])
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String BankingConfigurationDTO of
            Left err -> expectationFailure $ "body is not a BankingConfigurationDTO: " <> err
            Right dto -> do
              -- The seeded configuration has banking defaults populated, and clone-on-write
              -- carries them forward.  An empty PUT body makes no changes, so the returned
              -- DTO must still reflect the seeded values.
              dto.defaultIncomeCategory `shouldBe` Just incomeOtherUUID
              dto.defaultExpenseCategory `shouldBe` Just expenseOtherUUID
              Map.null dto.mccExpenseCategoryMap `shouldBe` False

      it "returns 400 when income category UUID is not in the income-category dictionary" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["defaultIncomeCategory" .= unknownUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          LBS.null (simpleBody resp) `shouldBe` False
          case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
            Left err -> expectationFailure $ "400 body is not an ErrorResponse: " <> err
            Right errResp ->
              errResp.code `shouldBe` "CONFIGURATION_ERROR"

      it "returns 400 when expense category UUID is not in the expense-category dictionary" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["defaultExpenseCategory" .= unknownUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
            Left err -> expectationFailure $ "400 body is not an ErrorResponse: " <> err
            Right errResp ->
              errResp.code `shouldBe` "CONFIGURATION_ERROR"

      it "returns 401 when no JWT is provided" $ do
        let body = encode $ object ["defaultIncomeCategory" .= incomeOtherUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            [(hContentType, "application/json")]
            body
        liftIO $ simpleStatus resp `shouldBe` status401

-- -----------------------------------------------------------------------------
-- PUT /api/users/me/configuration/banking — mccExpenseCategoryMap field
-- -----------------------------------------------------------------------------

updateBankingMccMapSpec :: Spec
updateBankingMccMapSpec =
  describe "PUT /api/users/me/configuration/banking (mccExpenseCategoryMap)"
    $ with mkAppSeeded
    $ do
      it "returns 200 and GET reflects a single-entry MCC map" $ do
        tok <- registerAndGetToken
        let mcc = "5411" :: Text
            body = encode $ object ["mccExpenseCategoryMap" .= object [Key.fromText mcc .= expenseOtherUUID]]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String BankingConfigurationDTO of
            Left err -> expectationFailure $ "body is not a BankingConfigurationDTO: " <> err
            Right dto ->
              Map.lookup mcc dto.mccExpenseCategoryMap `shouldBe` Just expenseOtherUUID
        -- Verify GET also shows the map
        getResp <-
          request
            "GET"
            "/api/users/me/configuration"
            [bearerHeader tok]
            ""
        liftIO $ do
          simpleStatus getResp `shouldBe` status200
          case eitherDecode (simpleBody getResp) :: Either String ConfigurationResponse of
            Left err -> expectationFailure $ "body is not a ConfigurationResponse: " <> err
            Right cfg ->
              Map.lookup mcc cfg.banking.mccExpenseCategoryMap `shouldBe` Just expenseOtherUUID

      it "returns 200 and GET shows empty map when {} supplied" $ do
        tok <- registerAndGetToken
        -- First set a map entry
        let setupBody = encode $ object ["mccExpenseCategoryMap" .= object ["5411" .= expenseOtherUUID]]
        _ <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            setupBody
        -- Now clear via empty map
        let clearBody = encode $ object ["mccExpenseCategoryMap" .= object ([] :: [Pair])]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            clearBody
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String BankingConfigurationDTO of
            Left err -> expectationFailure $ "body is not a BankingConfigurationDTO: " <> err
            Right dto ->
              Map.null dto.mccExpenseCategoryMap `shouldBe` True

      it "returns 400 when a map UUID value is not in the expense-category dictionary" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["mccExpenseCategoryMap" .= object ["5411" .= unknownUUID]]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
            Left err -> expectationFailure $ "400 body is not an ErrorResponse: " <> err
            Right errResp ->
              errResp.code `shouldBe` "CONFIGURATION_ERROR"

-- -----------------------------------------------------------------------------
-- GET /api/users/me/configuration shows banking field
-- -----------------------------------------------------------------------------

getBankingInResponseSpec :: Spec
getBankingInResponseSpec =
  describe "GET /api/users/me/configuration"
    $ with mkAppSeeded
    $ do
      it "returns a banking section with defaultIncomeCategory after a PUT" $ do
        tok <- registerAndGetToken
        -- Set the income default via PUT
        let putBody = encode $ object ["defaultIncomeCategory" .= incomeOtherUUID]
        _ <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            putBody
        -- Now GET and verify the banking field is populated
        resp <-
          request
            "GET"
            "/api/users/me/configuration"
            [bearerHeader tok]
            ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String ConfigurationResponse of
            Left err -> expectationFailure $ "body is not a ConfigurationResponse: " <> err
            Right cfg ->
              cfg.banking.defaultIncomeCategory `shouldBe` Just incomeOtherUUID
