{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Banking.TypesSpec
-- Description : Unit tests for Domain.Banking.Types
--
-- This module tests the banking subdomain value types with validation and
-- round-trip behavior.
--
-- Test Coverage:
--   - BankConnectionId: Smart constructor validation, round-trip
module Domain.Banking.TypesSpec (spec) where

import qualified Data.Aeson as Aeson
import Data.Text (isInfixOf)
import Data.UUID (nil)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Banking.Types
import RIO
import Test.Hspec
import Testkit.Helpers

spec :: Spec
spec = do
  bankConnectionIdSpec
  providerCredentialSpec

-- -----------------------------------------------------------------------------
-- BankConnectionId Tests
-- -----------------------------------------------------------------------------

bankConnectionIdSpec :: Spec
bankConnectionIdSpec = describe "BankConnectionId" $ do
  describe "unsafeBankConnectionId / unBankConnectionId" $ do
    it "Then round-trips a sample UUID" $ do
      let uuid = UUID.fromWords 1 2 3 4
      unBankConnectionId (unsafeBankConnectionId uuid) `shouldBe` uuid

  describe "mkBankConnectionId" $ do
    context "Given valid UUID" $ do
      it "Then creates BankConnectionId" $ do
        uuid <- UUID.nextRandom
        let result = mkBankConnectionId uuid
        shouldBeRight result
        case result of
          Right connId -> unBankConnectionId connId `shouldBe` uuid
          Left _ -> expectationFailure "Expected Right"

    context "Given nil UUID" $ do
      it "Then rejects with error message" $ do
        let result = mkBankConnectionId nil
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "cannot be nil" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

-- -----------------------------------------------------------------------------
-- ProviderCredential Tests
-- -----------------------------------------------------------------------------

providerCredentialSpec :: Spec
providerCredentialSpec = describe "ProviderCredential" $ do
  describe "JSON round-trip" $ do
    it "round-trips a StaticSecret through toJSON/fromJSON" $ do
      let cred = StaticSecret "u_supersecrettoken1234"
      Aeson.decode (Aeson.encode cred) `shouldBe` Just cred

  describe "StaticSecret JSON shape" $ do
    it "encodes as a stable explicitly-tagged object, not a bare/untagged string" $ do
      Aeson.toJSON (StaticSecret "abc123")
        `shouldBe` Aeson.object ["kind" Aeson..= ("static" :: Text), "secret" Aeson..= ("abc123" :: Text)]

    it "decodes the same tagged shape back into StaticSecret" $ do
      let wire = Aeson.object ["kind" Aeson..= ("static" :: Text), "secret" Aeson..= ("xyz" :: Text)]
      (Aeson.fromJSON wire :: Aeson.Result ProviderCredential) `shouldBe` Aeson.Success (StaticSecret "xyz")
