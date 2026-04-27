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
import Network.HTTP.Types (status200, status400)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkApp)
import Testkit.Auth (generateTestToken)
import Testkit.HspecWai (bearerHeader, getJSONAuth)
import Web.Types (TransactionListResponse (..), ValidationErrorResponse (..))

spec :: Spec
spec =
  describe "GET /api/transactions"
    $ with mkApp
    $ do
      it "returns 200 + empty list for a user with no accounts" $ do
        token <- liftIO generateTestToken
        resp <- getJSONAuth "/api/transactions" token
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "body is not a TransactionListResponse: " <> err
            Right body -> do
              body.transactions `shouldBe` []
              body.totalCount `shouldBe` 0

      it "returns 400 when from > to" $ do
        token <- liftIO generateTestToken
        resp <-
          request
            "GET"
            "/api/transactions?from=2026-04-18T00:00:00Z&to=2026-04-10T00:00:00Z"
            [bearerHeader token]
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
        resp <- getJSONAuth "/api/transactions?accountId=not-a-uuid" token
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 200 + empty list when accountId is unknown / forbidden" $ do
        token <- liftIO generateTestToken
        let uuid = "00000000-0000-4000-8000-000000000999"
        resp <- getJSONAuth ("/api/transactions?accountId=" <> fromString uuid) token
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "body is not a TransactionListResponse: " <> err
            Right body -> do
              body.transactions `shouldBe` []
              body.totalCount `shouldBe` 0
