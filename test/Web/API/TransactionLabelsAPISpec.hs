{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionLabelsAPISpec
-- Description : HTTP-level tests for the transaction label surface.
--
-- Exercises the request/response DTO additions (@labels@ on create and
-- read paths) and the label-edit endpoint
-- @PUT \/api\/transactions\/:id\/labels@. The per-test seed strategy
-- lives in 'Testkit.TransactionEditFixture' — see its haddock for the
-- rationale.
module Web.API.TransactionLabelsAPISpec (spec) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID4
import Domain.Core.Types
  ( unAccountId,
    unDictionaryEntryId,
    unTransactionId,
  )
import Network.HTTP.Types (status200, status404, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified RIO.List as List
import Test.Hspec
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
  )
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedIncomeTransaction,
    seedToken,
    seedTransfer,
    uuidText,
  )
import Web.Types
  ( ErrorResponse (..),
    TransactionResponse (..),
  )

spec :: Spec
spec = describe "Transaction labels HTTP endpoints" $ do
  describe "POST /api/transactions/income" $ do
    it "returns 200 and echoes a valid label set in the response" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "income-http-ok@test.com"
      token <- seedToken seed

      let body =
            encode
              $ object
                [ "accountId" .= uuidText (unAccountId seed.seedAccount),
                  "currency" .= ("USD" :: Text),
                  "allocations"
                    .= object
                      [ "incomes"
                          .= [ object
                                 [ "category" .= uuidText (unDictionaryEntryId seed.seedCategory),
                                   "amount" .= (50 :: Double)
                                 ]
                             ],
                        "expenses" .= ([] :: [Value])
                      ],
                  "description" .= ("Paycheck" :: Text),
                  "date" .= (Nothing :: Maybe Text),
                  "labels"
                    .= [ uuidText (unDictionaryEntryId seed.seedLabelA),
                         uuidText (unDictionaryEntryId seed.seedLabelB)
                       ]
                ]
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr ->
          List.sort tr.labels
            `shouldBe` List.sort
              [ unDictionaryEntryId seed.seedLabelA,
                unDictionaryEntryId seed.seedLabelB
              ]

    it "returns 404 LABEL_NOT_FOUND when any label id is unknown" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "income-http-unknown@test.com"
      token <- seedToken seed
      alien <- UUID4.nextRandom

      let body =
            encode
              $ object
                [ "accountId" .= uuidText (unAccountId seed.seedAccount),
                  "currency" .= ("USD" :: Text),
                  "allocations"
                    .= object
                      [ "incomes"
                          .= [ object
                                 [ "category" .= uuidText (unDictionaryEntryId seed.seedCategory),
                                   "amount" .= (50 :: Double)
                                 ]
                             ],
                        "expenses" .= ([] :: [Value])
                      ],
                  "description" .= ("Paycheck" :: Text),
                  "date" .= (Nothing :: Maybe Text),
                  "labels" .= [uuidText alien]
                ]
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body

      simpleStatus resp `shouldBe` status404
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "LABEL_NOT_FOUND"

  describe "PUT /api/transactions/:id/labels" $ do
    it "returns 404 for an unknown transaction id" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-labels-404@test.com"
      token <- seedToken seed
      unknown <- UUID4.nextRandom

      let body = encode $ object ["labels" .= ([] :: [Text])]
          path = encodeUtf8 $ "/api/transactions/" <> uuidText unknown <> "/labels"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status404

    it "returns 409 TRANSACTION_NOT_COMPLETED for a Pending transaction" $ do
      -- No process manager: transactions stay Pending forever, so the
      -- aggregate rejects the edit.
      seed <- mkSeed createTestAppEnv "put-labels-pending@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed

      let body =
            encode
              $ object
                ["labels" .= [uuidText (unDictionaryEntryId seed.seedLabelA)]]
          path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/labels"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status409
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "TRANSACTION_NOT_COMPLETED"

    it "returns 404 LABEL_NOT_FOUND when an unknown label id is supplied" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-labels-unknown@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      alien <- UUID4.nextRandom

      let body = encode $ object ["labels" .= [uuidText alien]]
          path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/labels"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status404
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "LABEL_NOT_FOUND"

    it "returns 200 and the new label set on success" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-labels-ok@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed (Set.singleton seed.seedLabelA)

      let body =
            encode
              $ object
                ["labels" .= [uuidText (unDictionaryEntryId seed.seedLabelB)]]
          path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/labels"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr ->
          tr.labels `shouldBe` [unDictionaryEntryId seed.seedLabelB]
