{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionAPISpec
-- Description : HTTP-level tests for GET /api/transactions
--
-- Exercises the endpoint through the full Servant stack via hspec-wai.
-- Seeded happy-path coverage (ordering, date filtering) is already provided
-- end-to-end by TransactionListSpec and TransactionListPropertySpec; this
-- file focuses on the HTTP envelope — status codes, validation wiring, and
-- the "hide existence" semantics for forbidden accountIds.
module Web.API.TransactionAPISpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.Map.Strict as Map
import Network.HTTP.Types (hAuthorization, status200, status400)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.Auth (generateTestToken)
import Testkit.InMemoryEventStore (createTestAppEnv)
import Web.Server (buildApplication)
import Web.Types (TransactionListResponse (..), ValidationErrorResponse (..))

mkApp :: IO Application
mkApp = buildApplication <$> createTestAppEnv

spec :: Spec
spec =
  describe "GET /api/transactions"
    $ with mkApp
    $ do
      it "returns 200 + empty list for a user with no accounts" $ do
        token <- liftIO generateTestToken
        let headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <- request "GET" "/api/transactions" headers ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "body is not a TransactionListResponse: " <> err
            Right body -> do
              body.transactions `shouldBe` []
              body.totalCount `shouldBe` 0

      it "returns 400 when from > to" $ do
        token <- liftIO generateTestToken
        let headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <-
          request
            "GET"
            "/api/transactions?from=2026-04-18T00:00:00Z&to=2026-04-10T00:00:00Z"
            headers
            ""
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          -- Validation errors go through Web.ErrorMapping as a
          -- 'ValidationErrorResponse' (message + fieldErrors), not the
          -- generic 'ErrorResponse' envelope. Assert on the field-level
          -- error so a regression to a different shape fails loudly.
          case eitherDecode (simpleBody resp) :: Either String ValidationErrorResponse of
            Left err -> expectationFailure $ "400 body is not a ValidationErrorResponse: " <> err
            Right env ->
              Map.lookup "query" env.fieldErrors
                `shouldBe` Just "from must be <= to"

      it "returns 400 when accountId is not a UUID" $ do
        token <- liftIO generateTestToken
        let headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <- request "GET" "/api/transactions?accountId=not-a-uuid" headers ""
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 200 + empty list when accountId is unknown / forbidden" $ do
        token <- liftIO generateTestToken
        let uuid = "00000000-0000-4000-8000-000000000999"
            headers = [(hAuthorization, "Bearer " <> encodeUtf8 token)]
        resp <-
          request
            "GET"
            ("/api/transactions?accountId=" <> fromString uuid)
            headers
            ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "body is not a TransactionListResponse: " <> err
            Right body -> do
              body.transactions `shouldBe` []
              body.totalCount `shouldBe` 0
