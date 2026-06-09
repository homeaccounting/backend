{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.AppEnvSpec
-- Description : Smoke test for the banking-enabled seeded test harness.
--
-- Drives 'mkAppBankingEnabledSeeded' (Task 2b) into existence: build the
-- combined harness (banking + monobank enabled, deterministic key ring,
-- stub provider factory, default configuration seeded), register a user, and
-- hit @GET /api/users/me/configuration@. The endpoint must answer 200 and
-- must not 404 — confirming the seeded read model is in place and the
-- banking subsystem is wired without reaching for a real network provider.
--
-- Note: the @bankingFeatureEnabled@ DTO field arrives in Task 7, so this
-- spec asserts only the status code, not that field.
module Testkit.AppEnvSpec (spec) where

import Network.HTTP.Types (status200, status404)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkAppBankingEnabledSeeded)
import Testkit.HspecWai (bearerHeader, registerAndGetToken)

spec :: Spec
spec =
  describe "mkAppBankingEnabledSeeded"
    $ with mkAppBankingEnabledSeeded
    $ it "serves GET /api/users/me/configuration (200, banking did not 404)"
    $ do
      tok <- registerAndGetToken
      resp <- request "GET" "/api/users/me/configuration" [bearerHeader tok] ""
      liftIO $ do
        simpleStatus resp `shouldNotBe` status404
        simpleStatus resp `shouldBe` status200
