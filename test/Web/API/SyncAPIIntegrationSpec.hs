{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.SyncAPIIntegrationSpec
-- Description : HTTP integration tests for GET /api/sync/version
--
-- Three cases:
--
--   * No\/invalid token               -> 401
--   * Authenticated request           -> 200 with a JSON @{ "version": <number> }@
--   * A write affecting the caller (account creation) bumps the counter, so a
--     second GET returns a strictly greater number than the first. This
--     exercises the whole producer (DataVersion read model) -> endpoint path.
module Web.API.SyncAPIIntegrationSpec (spec) where

import Data.Aeson (eitherDecode)
import Domain.Core.Types (UserId)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Network.HTTP.Types (hAuthorization, hContentType, status200, status401)
import Network.Wai.Test (SResponse, simpleBody, simpleStatus)
import RIO
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv)
import Testkit.TransactionEditFixture (authHeaders, httpRequest)
import Web.Server (buildApplication)
import Web.Types (SyncVersionResponse (..))

spec :: Spec
spec = do
  unauthenticatedSpec
  authenticatedSpec
  bumpsAfterWriteSpec

-- -----------------------------------------------------------------------------
-- No / invalid token -> 401
-- -----------------------------------------------------------------------------

unauthenticatedSpec :: Spec
unauthenticatedSpec =
  describe "GET /api/sync/version (unauthenticated)" $ do
    it "returns 401 when no Authorization header is present" $ do
      env <- createTestAppEnv
      let app = buildApplication env
      resp <- httpRequest app "GET" "/api/sync/version" [(hContentType, "application/json")] ""
      simpleStatus resp `shouldBe` status401

    it "returns 401 when the Authorization header carries an invalid token" $ do
      env <- createTestAppEnv
      let app = buildApplication env
          headers =
            [ (hContentType, "application/json"),
              (hAuthorization, "Bearer not-a-real-token")
            ]
      resp <- httpRequest app "GET" "/api/sync/version" headers ""
      simpleStatus resp `shouldBe` status401

-- -----------------------------------------------------------------------------
-- Authenticated -> 200 with the caller's counter
-- -----------------------------------------------------------------------------

authenticatedSpec :: Spec
authenticatedSpec =
  describe "GET /api/sync/version (authenticated)"
    $ it "returns 200 with a JSON { version: <number> } body"
    $ do
      env <- createTestAppEnv
      userId <- registerUser env "sync-version-test@example.com"
      jwt <- mintToken userId "sync-version-test@example.com"
      let app = buildApplication env

      resp <- httpRequest app "GET" "/api/sync/version" (authHeaders jwt) ""
      simpleStatus resp `shouldBe` status200
      _ <- decodeVersion resp
      pure ()

-- -----------------------------------------------------------------------------
-- A write affecting the caller bumps the counter
-- -----------------------------------------------------------------------------

bumpsAfterWriteSpec :: Spec
bumpsAfterWriteSpec =
  describe "GET /api/sync/version (after a write)"
    $ it "returns a strictly greater number after the caller creates an account"
    $ do
      env <- createTestAppEnv
      userId <- registerUser env "sync-version-bump-test@example.com"
      jwt <- mintToken userId "sync-version-bump-test@example.com"
      let app = buildApplication env
          getVersion = do
            resp <- httpRequest app "GET" "/api/sync/version" (authHeaders jwt) ""
            simpleStatus resp `shouldBe` status200
            decodeVersion resp

      before <- getVersion

      _ <- createDefaultAccount env userId "Wallet"

      after <- getVersion
      after.version `shouldSatisfy` (> before.version)

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

mintToken :: UserId -> Text -> IO Text
mintToken userId email = do
  res <- generateToken defaultJWTConfig userId email
  case res of
    Left err -> fail $ "generateToken failed: " <> show err
    Right tok -> pure tok

decodeVersion :: SResponse -> IO SyncVersionResponse
decodeVersion resp =
  case eitherDecode (simpleBody resp) :: Either String SyncVersionResponse of
    Left err -> fail $ "failed to decode SyncVersionResponse: " <> err
    Right r -> pure r
