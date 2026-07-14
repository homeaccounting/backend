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

import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import Data.Aeson.Types (Pair)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
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
import Testkit.HspecWai (bearerHeader, getJSONAuth, jsonAuthHeaders, registerAndGetToken)
import Web.API.ConfigurationAPI
  ( BankProviderDTO (..),
    BankingConfigurationDTO (..),
    ConfigurationDefaultsDTO (..),
    ConfigurationResponse (..),
  )
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

-- -----------------------------------------------------------------------------
-- Spec entry point
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  updateDefaultsSpec
  updateBankingMccMapSpec
  getBankingInResponseSpec
  listProvidersSpec

-- -----------------------------------------------------------------------------
-- PUT /api/users/me/configuration/defaults
-- -----------------------------------------------------------------------------

updateDefaultsSpec :: Spec
updateDefaultsSpec =
  describe "PUT /api/users/me/configuration/defaults"
    $ with mkAppSeeded
    $ do
      it "returns 200 with updated defaultIncomeCategory when valid UUID supplied" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["incomeCategory" .= incomeOtherUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String ConfigurationResponse of
            Left err -> expectationFailure $ "body is not a ConfigurationResponse: " <> err
            Right cfg -> do
              let ConfigurationResponse {defaults = ConfigurationDefaultsDTO {incomeCategory = mInc}} = cfg
              mInc `shouldBe` Just incomeOtherUUID

      it "returns 200 with updated defaultExpenseCategory when valid UUID supplied" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["expenseCategory" .= expenseOtherUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String ConfigurationResponse of
            Left err -> expectationFailure $ "body is not a ConfigurationResponse: " <> err
            Right cfg -> do
              let ConfigurationResponse {defaults = ConfigurationDefaultsDTO {expenseCategory = mExp}} = cfg
              mExp `shouldBe` Just expenseOtherUUID

      it "returns 200 with no state change for empty body {}" $ do
        tok <- registerAndGetToken
        let body = encode $ object ([] :: [Pair])
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String ConfigurationResponse of
            Left err -> expectationFailure $ "body is not a ConfigurationResponse: " <> err
            Right cfg -> do
              -- The seeded configuration has the global defaults populated, and
              -- clone-on-write carries them forward.  An empty PUT body makes no
              -- changes, so the returned config must still reflect the seeded values.
              let ConfigurationResponse {defaults = ConfigurationDefaultsDTO {incomeCategory = mInc, expenseCategory = mExp}} = cfg
              mInc `shouldBe` Just incomeOtherUUID
              mExp `shouldBe` Just expenseOtherUUID

      it "returns 400 when income category UUID is not in the income-category dictionary" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["incomeCategory" .= unknownUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
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
        let body = encode $ object ["expenseCategory" .= unknownUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
            Left err -> expectationFailure $ "400 body is not an ErrorResponse: " <> err
            Right errResp ->
              errResp.code `shouldBe` "CONFIGURATION_ERROR"

      it "returns 400 when the income category UUID is malformed" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["incomeCategory" .= ("not-a-uuid" :: Text)]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            body
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 400 when the default account is not owned by the user" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["account" .= unknownUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            body
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 401 when no JWT is provided" $ do
        let body = encode $ object ["incomeCategory" .= incomeOtherUUID]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
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
      it "returns a top-level defaultIncomeCategory after a PUT to /defaults" $ do
        tok <- registerAndGetToken
        -- Set the income default via PUT
        let putBody = encode $ object ["incomeCategory" .= incomeOtherUUID]
        _ <-
          request
            "PUT"
            "/api/users/me/configuration/defaults"
            (jsonAuthHeaders tok)
            putBody
        -- Now GET and verify the top-level field is populated
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
            Right cfg -> do
              let ConfigurationResponse {defaults = ConfigurationDefaultsDTO {incomeCategory = mInc}} = cfg
              mInc `shouldBe` Just incomeOtherUUID

-- -----------------------------------------------------------------------------
-- GET /api/users/me/configuration/banking/providers
-- -----------------------------------------------------------------------------

listProvidersSpec :: Spec
listProvidersSpec =
  describe "GET /api/users/me/configuration/banking/providers"
    $ with mkAppSeeded
    $ do
      it "lists available providers with capability flags" $ do
        tok <- registerAndGetToken
        resp <- getJSONAuth "/api/users/me/configuration/banking/providers" tok
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String [BankProviderDTO] of
            Left err -> expectationFailure $ "body is not a [BankProviderDTO]: " <> err
            Right providers ->
              providers
                `shouldBe` [ BankProviderDTO
                               { id = "monobank",
                                 displayName = "Monobank",
                                 supportsPull = True,
                                 supportsFile = False
                               }
                           ]

      it "returns 401 when no JWT is provided" $ do
        resp <- request "GET" "/api/users/me/configuration/banking/providers" [(hContentType, "application/json")] ""
        liftIO $ simpleStatus resp `shouldBe` status401
