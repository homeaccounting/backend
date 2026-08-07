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
  ( expenseCategoryDictKind,
    incomeCategoryDictKind,
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
  ( AddEntryResponse (..),
    BankProviderDTO (..),
    BankingConfigurationDTO (..),
    ConfigurationDefaultsDTO (..),
    ConfigurationResponse (..),
  )
import Web.Types (ErrorResponse (..), ValidationErrorResponse (..))

-- -----------------------------------------------------------------------------
-- Well-known deterministic UUIDs from the default seed
-- -----------------------------------------------------------------------------

-- | UUID of the "Other" entry in the income-category dictionary.
incomeOtherUUID :: UUID.UUID
incomeOtherUUID = unDictionaryEntryId (mkDeterministicEntryId incomeCategoryDictKind "Other")

-- | UUID of the "Other" entry in the expense-category dictionary.
expenseOtherUUID :: UUID.UUID
expenseOtherUUID = unDictionaryEntryId (mkDeterministicEntryId expenseCategoryDictKind "Other")

-- | A random UUID that is not in any dictionary.
unknownUUID :: UUID.UUID
unknownUUID = UUID.fromWords 0xDEAD 0xBEEF 0 1

-- -----------------------------------------------------------------------------
-- Request helpers
-- -----------------------------------------------------------------------------

-- | Add a contact-dictionary item entry via the HTTP API and return its id.
-- Contacts have no default seed (dictionaries are user-curated), so the
-- provider-contact-map tests need to create one before they can point a
-- contact-map value at it.
addContactEntry :: Text -> Text -> WaiSession st UUID.UUID
addContactEntry tok name = do
  resp <-
    request
      "POST"
      "/api/users/me/configuration/dictionaries/contact/entries"
      (jsonAuthHeaders tok)
      (encode $ object ["name" .= name, "type" .= ("item" :: Text)])
  case eitherDecode (simpleBody resp) :: Either String AddEntryResponse of
    Left err -> do
      liftIO $ expectationFailure ("addContactEntry: body is not an AddEntryResponse: " <> err)
      pure UUID.nil
    Right (AddEntryResponse {id = eid}) -> pure eid

-- -----------------------------------------------------------------------------
-- Spec entry point
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  updateDefaultsSpec
  updateBankingMccMapSpec
  updateBankingContactMapSpec
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
  describe "PUT /api/users/me/configuration/banking (expenseCategoryMap)"
    $ with mkAppSeeded
    $ do
      it "returns 200 and GET reflects a single-entry provider-category map" $ do
        tok <- registerAndGetToken
        let mcc = "mcc:5411" :: Text
            body = encode $ object ["expenseCategoryMap" .= object [Key.fromText mcc .= expenseOtherUUID]]
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
              Map.lookup mcc dto.expenseCategoryMap `shouldBe` Just expenseOtherUUID
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
              Map.lookup mcc cfg.banking.expenseCategoryMap `shouldBe` Just expenseOtherUUID

      it "round-trips both MCC and label provider-category keys" $ do
        tok <- registerAndGetToken
        -- A leading-zero MCC key and a free-text label key, both mapped to the
        -- same valid expense category. The keys must survive PUT → GET verbatim.
        let mccKey = "mcc:0742" :: Text
            labelKey = "label:eating_out" :: Text
            body =
              encode
                $ object
                  [ "expenseCategoryMap"
                      .= object
                        [ Key.fromText mccKey .= expenseOtherUUID,
                          Key.fromText labelKey .= expenseOtherUUID
                        ]
                  ]
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
              Map.lookup mccKey dto.expenseCategoryMap `shouldBe` Just expenseOtherUUID
              Map.lookup labelKey dto.expenseCategoryMap `shouldBe` Just expenseOtherUUID
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
            Right cfg -> do
              Map.lookup mccKey cfg.banking.expenseCategoryMap `shouldBe` Just expenseOtherUUID
              Map.lookup labelKey cfg.banking.expenseCategoryMap `shouldBe` Just expenseOtherUUID

      it "returns 200 and GET shows empty map when {} supplied" $ do
        tok <- registerAndGetToken
        -- First set a map entry
        let setupBody = encode $ object ["expenseCategoryMap" .= object ["mcc:5411" .= expenseOtherUUID]]
        _ <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            setupBody
        -- Now clear via empty map
        let clearBody = encode $ object ["expenseCategoryMap" .= object ([] :: [Pair])]
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
              Map.null dto.expenseCategoryMap `shouldBe` True

      it "returns 400 when a map UUID value is not in the expense-category dictionary" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["expenseCategoryMap" .= object ["mcc:5411" .= unknownUUID]]
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
-- PUT /api/users/me/configuration/banking — contactMap field
-- -----------------------------------------------------------------------------

updateBankingContactMapSpec :: Spec
updateBankingContactMapSpec =
  describe "PUT /api/users/me/configuration/banking (contactMap)"
    $ with mkAppSeeded
    $ do
      it "returns 200 and GET reflects a single-entry provider-contact map" $ do
        tok <- registerAndGetToken
        contactId <- addContactEntry tok "Landlord"
        let providerToken = "MagazinREMONTI" :: Text
            body = encode $ object ["contactMap" .= object [Key.fromText providerToken .= contactId]]
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
              Map.lookup providerToken dto.contactMap `shouldBe` Just contactId
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
              Map.lookup providerToken cfg.banking.contactMap `shouldBe` Just contactId

      it "returns 200 and GET shows empty map when {} supplied" $ do
        tok <- registerAndGetToken
        contactId <- addContactEntry tok "Landlord"
        -- First set a map entry
        let setupBody = encode $ object ["contactMap" .= object ["MagazinREMONTI" .= contactId]]
        _ <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            setupBody
        -- Now clear via empty map
        let clearBody = encode $ object ["contactMap" .= object ([] :: [Pair])]
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
              Map.null dto.contactMap `shouldBe` True

      it "returns 400 when a contact-map UUID value is not in the contact dictionary" $ do
        tok <- registerAndGetToken
        let body = encode $ object ["contactMap" .= object ["MagazinREMONTI" .= unknownUUID]]
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

      it "returns 400 when a contact-map key is blank" $ do
        tok <- registerAndGetToken
        contactId <- addContactEntry tok "Landlord"
        let body = encode $ object ["contactMap" .= object ["" .= contactId]]
        resp <-
          request
            "PUT"
            "/api/users/me/configuration/banking"
            (jsonAuthHeaders tok)
            body
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          -- Blank-key rejection is a 'validateFieldCtx' failure, which goes
          -- through 'Web.ErrorMapping' as a 'ValidationErrorResponse'
          -- (message + fieldErrors), not the generic 'ErrorResponse' envelope
          -- used for aggregate-level 'ConfigurationError's.
          case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
            Left err -> expectationFailure $ "400 body is not a ValidationErrorResponse: " <> err
            Right env ->
              Map.lookup "contactMap" env.fieldErrors `shouldSatisfy` isJust

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
