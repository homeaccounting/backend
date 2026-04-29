{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.AuthAPIIntegrationSpec
-- Description : HTTP integration tests for POST /api/auth/telegram/link-code
--
-- Two cases:
--
--   * Unauthenticated request → 401
--   * Authenticated request   → 200 with a valid Telegram deep-link
--
-- The authenticated case also verifies that the issued token round-trips:
-- the raw token extracted from the deep-link can be redeemed via
-- 'Application.LinkCodeStore.redeemAt' and resolves to the same 'UserId'
-- that made the request.
module Web.API.AuthAPIIntegrationSpec (spec) where

import Application.LinkCodeStore (mkLinkCodeToken, redeemAt)
import Data.Aeson (eitherDecode)
import qualified Data.Text as T
import Data.Time (addUTCTime, getCurrentTime)
import Infrastructure.App (AppEnv (..))
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Network.HTTP.Types (hAuthorization, hContentType, status200, status401, status404)
import qualified Network.Wai as Wai
import Network.Wai.Test (SRequest (..), SResponse (..), defaultRequest, runSession, setPath, srequest)
import RIO
import Test.Hspec
import Test.Hspec.Wai (request, with)
import Testkit.AppEnv (mkApp)
import Testkit.Fixtures (registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv)
import Web.API.AuthAPI (TelegramLinkCodeResponse (..))
import Web.Server (buildApplication)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  unauthenticatedSpec
  authenticatedSpec
  removedWidgetEndpointsSpec

-- -----------------------------------------------------------------------------
-- Unauthenticated → 401
-- -----------------------------------------------------------------------------

unauthenticatedSpec :: Spec
unauthenticatedSpec =
  describe "POST /api/auth/telegram/link-code (unauthenticated)"
    $ with mkApp
    $ it "returns 401 when no Authorization header is present"
    $ do
      resp <-
        request
          "POST"
          "/api/auth/telegram/link-code"
          [(hContentType, "application/json")]
          "{}"
      liftIO $ simpleStatus resp `shouldBe` status401

-- -----------------------------------------------------------------------------
-- Authenticated → 200 with deep-link
-- -----------------------------------------------------------------------------

authenticatedSpec :: Spec
authenticatedSpec =
  describe "POST /api/auth/telegram/link-code (authenticated)"
    $ it "returns 200 with a deep-link whose token round-trips via redeemAt"
    $ do
      env <- createTestAppEnv
      userId <- registerUser env "link-code-test@example.com"
      tokenResult <- generateToken defaultJWTConfig userId "link-code-test@example.com"
      jwt <- case tokenResult of
        Left err -> fail $ "generateToken failed: " <> show err
        Right t -> pure t

      let app = buildApplication env
          headers =
            [ (hContentType, "application/json"),
              (hAuthorization, "Bearer " <> encodeUtf8 jwt)
            ]
          baseReq = setPath defaultRequest "/api/auth/telegram/link-code"
          req =
            baseReq
              { Wai.requestMethod = "POST",
                Wai.requestHeaders = headers
              }
          sreq = SRequest req "{}"

      resp <- runSession (srequest sreq) app
      simpleStatus resp `shouldBe` status200

      decoded <-
        case eitherDecode (simpleBody resp) :: Either String TelegramLinkCodeResponse of
          Left err -> fail $ "failed to decode TelegramLinkCodeResponse: " <> err
          Right r -> pure r

      -- Assert the deep-link has the expected shape
      decoded.deepLink `shouldSatisfy` T.isPrefixOf "https://t.me/"
      decoded.deepLink `shouldSatisfy` T.isInfixOf "?start=LINK_"

      -- Extract the raw token after "?start=LINK_" and verify round-trip
      let rawToken = extractLinkToken decoded.deepLink
      now <- getCurrentTime
      let futureNow = addUTCTime 60 now -- 1 minute from now; well within 10-min TTL
      maybeUid <- redeemAt env.linkCodeStore (mkLinkCodeToken rawToken) futureNow
      maybeUid `shouldBe` Just userId

-- | Extract the token portion that follows @?start=LINK_@ in the deep-link URL.
extractLinkToken :: Text -> Text
extractLinkToken url =
  case T.splitOn "?start=LINK_" url of
    [_, tokenPart] -> tokenPart
    _ -> ""

-- -----------------------------------------------------------------------------
-- Removed widget endpoints → 404
-- -----------------------------------------------------------------------------

-- | Regression guards: the Telegram login-widget surfaces were removed in
-- favour of the bot deep-link flow. Both routes must return 404 so that
-- any accidental re-introduction is caught immediately.
--
-- Note: Servant returns 404 (not 405) for these paths because the URL
-- prefixes no longer match any defined endpoint in 'AuthAPI'.
removedWidgetEndpointsSpec :: Spec
removedWidgetEndpointsSpec =
  describe "removed widget endpoints"
    $ with mkApp
    $ do
      it "POST /api/auth/telegram returns 404 (route deleted)" $ do
        resp <-
          request
            "POST"
            "/api/auth/telegram"
            [(hContentType, "application/json")]
            "{}"
        liftIO $ simpleStatus resp `shouldBe` status404

      it "POST /api/auth/link-telegram returns 404 (route deleted)" $ do
        resp <-
          request
            "POST"
            "/api/auth/link-telegram"
            [(hContentType, "application/json")]
            "{}"
        liftIO $ simpleStatus resp `shouldBe` status404
