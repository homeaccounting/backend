{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.Middleware.RouteLabelSpec (spec) where

import Network.Wai (defaultRequest, pathInfo)
import RIO
import Test.Hspec
import Web.Middleware.RouteLabel (normalizeRoutePath, routeLabel)

uuid :: Text
uuid = "3f2a1c9e-4b7d-4e2a-9f1a-8c6b5d4e3f21"

spec :: Spec
spec = describe "Web.Middleware.RouteLabel" $ do
  describe "normalizeRoutePath" $ do
    it "collapses a trailing UUID capture to :id"
      $ normalizeRoutePath ["api", "accounts", uuid]
      `shouldBe` "/api/accounts/:id"

    it "collapses an all-digit capture to :id"
      $ normalizeRoutePath ["api", "accounts", "12345"]
      `shouldBe` "/api/accounts/:id"

    it "keeps a static sub-resource path verbatim"
      $ normalizeRoutePath ["api", "users", "me", "configuration"]
      `shouldBe` "/api/users/me/configuration"

    it "keeps a top-level collection with no capture verbatim"
      $ normalizeRoutePath ["api", "info"]
      `shouldBe` "/api/info"

    it "collapses multiple captures in one path"
      $ normalizeRoutePath ["api", "accounts", uuid, "access", uuid]
      `shouldBe` "/api/accounts/:id/access/:id"

    it "keeps a non-id text capture (bounded value) verbatim"
      $ normalizeRoutePath ["api", "auth", "oauth", "google", "callback"]
      `shouldBe` "/api/auth/oauth/google/callback"

    it "buckets an unknown collection into other"
      $ normalizeRoutePath ["api", "wp-admin", "config"]
      `shouldBe` "other"

    it "buckets a path without the api prefix into other"
      $ normalizeRoutePath ["health"]
      `shouldBe` "other"

    it "buckets the empty path into other"
      $ normalizeRoutePath []
      `shouldBe` "other"

    it "ignores a trailing empty segment (trailing slash)"
      $ normalizeRoutePath ["api", "info", ""]
      `shouldBe` "/api/info"

  describe "routeLabel"
    $ it "derives the normalized label from a request's pathInfo"
    $ do
      let req = defaultRequest {pathInfo = ["api", "transactions", uuid]}
      routeLabel req `shouldBe` "/api/transactions/:id"
