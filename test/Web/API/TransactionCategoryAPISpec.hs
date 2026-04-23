{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionCategoryAPISpec
-- Description : HTTP-level tests for the transaction category-edit endpoint.
--
-- Covers @PUT \/api\/transactions\/:id\/category@ — the two guards
-- that can reject the edit (internal transfer, unknown category id).
-- The shared seed strategy lives in 'Testkit.TransactionEditFixture'.
module Web.API.TransactionCategoryAPISpec (spec) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID4
import Domain.Core.Types (unDictionaryEntryId, unTransactionId)
import Network.HTTP.Types (status404, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedIncomeTransaction,
    seedInternalTransfer,
    seedToken,
    uuidText,
  )
import Web.Types (ErrorResponse (..))

spec :: Spec
spec = describe "Transaction category HTTP endpoints" $ do
  describe "PUT /api/transactions/:id/category" $ do
    it "returns 409 CATEGORY_NOT_APPLICABLE for an internal transfer" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-cat-internal@test.com"
      token <- seedToken seed
      txId <- seedInternalTransfer seed

      let body =
            encode
              $ object
                ["categoryId" .= uuidText (unDictionaryEntryId seed.seedCategory)]
          path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/category"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status409
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "CATEGORY_NOT_APPLICABLE"

    it "returns 404 CATEGORY_NOT_FOUND when the new category id is unknown" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-cat-unknown@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      alien <- UUID4.nextRandom

      let body = encode $ object ["categoryId" .= uuidText alien]
          path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/category"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status404
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "CATEGORY_NOT_FOUND"
