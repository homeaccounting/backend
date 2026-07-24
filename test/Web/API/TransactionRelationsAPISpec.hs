{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionRelationsAPISpec
-- Description : HTTP-level tests for the transaction relations surface.
--
-- Exercises the @relatedTransactionId@ field on the income create path (which
-- records a 'Refund' edge), the @relations@ array on 'TransactionResponse', and
-- the @GET \/api\/transactions\/:id\/relations@ endpoint (outbound + inbound).
-- Also covers the refund-target validation error mapping (non-expense → 422,
-- cancelled → 409).
--
-- Uses the shared in-memory HTTP fixture ('Testkit.TransactionEditFixture');
-- like 'Web.API.TransactionLabelsAPISpec' it runs entirely on the STM/SQLite
-- in-memory stores and needs no Postgres.
module Web.API.TransactionRelationsAPISpec (spec) where

import Application.Services.ConfigurationService (expenseCategoryDictKind)
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( TransactionId,
    unAccountId,
    unDictionaryEntryId,
    unTransactionId,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (runAppM)
import Network.HTTP.Types (status200, status404, status409, status422)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified RIO.List as List
import Test.Hspec
import Testkit.Fixtures (firstDictionaryEntry)
import Testkit.Helpers (expenseSingletonAllocation, singletonAllocation)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    uuidText,
  )
import Web.Types
  ( ErrorResponse (..),
    TransactionRelation (..),
    TransactionRelationsResponse (..),
    TransactionResponse (..),
  )

-- | Seed a Completed expense transaction on the seeded account and return its
-- id. The seed env carries the transfer process manager, so the expense
-- resolves to Completed.
seedExpense :: Seed -> IO TransactionId
seedExpense seed = do
  cat <- firstDictionaryEntry seed.seedEnv seed.seedUserId expenseCategoryDictKind
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateExpense
        seed.seedUserId
        seed.seedAccount
        (unsafeMoney Core.USD 40)
        (expenseSingletonAllocation cat (unsafeMoney Core.USD 40))
        Set.empty
        "Groceries"
        Nothing
        Nothing
        Nothing
  case res of
    Left err -> fail $ "seedExpense failed: " <> show err
    Right (txId, _) -> pure txId

-- | Body for an income create that refunds @target@ (50 USD to the seed income
-- category).
-- | Income create body carrying a nested relation of the given kind token.
relationIncomeBody :: Seed -> TransactionId -> Text -> LByteString
relationIncomeBody seed target kind =
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
        "description" .= ("Linked income" :: Text),
        "relation"
          .= object
            [ "relatedTransactionId" .= uuidText (unTransactionId target),
              "relationKind" .= kind
            ]
      ]

-- | The common case: an income refunding an expense.
refundIncomeBody :: Seed -> TransactionId -> LByteString
refundIncomeBody seed target = relationIncomeBody seed target "refund"

-- | Body for @POST \/api\/transactions\/:id\/relations@: a 'TransactionRelation'
-- naming the other end and the wire kind token.
addRelationBody :: TransactionId -> Text -> LByteString
addRelationBody related kind =
  encode
    $ object
      [ "relatedTransactionId" .= uuidText (unTransactionId related),
        "relationKind" .= kind
      ]

-- | @POST \/api\/transactions\/:id\/relations@ for the given owner/from id.
addRelation :: Seed -> Text -> TransactionId -> LByteString -> IO SResponse
addRelation seed token fromId =
  httpRequest
    seed.seedApp
    "POST"
    (encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId fromId) <> "/relations")
    (authHeaders token)

spec :: Spec
spec = describe "Transaction relations HTTP endpoints" $ do
  describe "POST /api/transactions/income with relatedTransactionId" $ do
    it "returns 200 and populates the relations array with a refund edge" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "refund-http-ok@test.com"
      token <- seedToken seed
      expenseId <- seedExpense seed

      resp <-
        httpRequest
          seed.seedApp
          "POST"
          "/api/transactions/income"
          (authHeaders token)
          (refundIncomeBody seed expenseId)

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          map (.relatedTransactionId) tr.relations
            `shouldBe` [unTransactionId expenseId]
          map (.relationKind) tr.relations `shouldBe` ["refund"]

    it "records a generic 'associated' relation (kind is not forced to refund)" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "assoc-http-ok@test.com"
      token <- seedToken seed
      -- 'associated' places no kind restriction on the target; link to an expense.
      target <- seedExpense seed

      resp <-
        httpRequest
          seed.seedApp
          "POST"
          "/api/transactions/income"
          (authHeaders token)
          (relationIncomeBody seed target "associated")

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          map (.relatedTransactionId) tr.relations `shouldBe` [unTransactionId target]
          map (.relationKind) tr.relations `shouldBe` ["associated"]

    it "returns 422 REFUND_TARGET_MUST_BE_EXPENSE when the target is not an expense" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "refund-http-non-expense@test.com"
      token <- seedToken seed
      -- The target is an income, not an expense.
      incomeRes <-
        runAppM seed.seedEnv
          $ TransactionService.initiateIncome
            seed.seedUserId
            seed.seedAccount
            (unsafeMoney Core.USD 20)
            (singletonAllocation seed.seedCategory (unsafeMoney Core.USD 20))
            Set.empty
            "Salary"
            Nothing
            Nothing
            Nothing
      incomeId <- case incomeRes of
        Left err -> fail $ "seed income failed: " <> show err
        Right (txId, _) -> pure txId

      resp <-
        httpRequest
          seed.seedApp
          "POST"
          "/api/transactions/income"
          (authHeaders token)
          (refundIncomeBody seed incomeId)

      simpleStatus resp `shouldBe` status422
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "REFUND_TARGET_MUST_BE_EXPENSE"

    it "returns 409 when the refund target is cancelled" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "refund-http-cancelled@test.com"
      token <- seedToken seed
      expenseId <- seedExpense seed
      cancelRes <-
        runAppM seed.seedEnv
          $ TransactionService.cancelTransaction seed.seedUserId expenseId
      case cancelRes of
        Left err -> fail $ "cancel expense failed: " <> show err
        Right _ -> pure ()

      resp <-
        httpRequest
          seed.seedApp
          "POST"
          "/api/transactions/income"
          (authHeaders token)
          (refundIncomeBody seed expenseId)

      simpleStatus resp `shouldBe` status409

  describe "GET /api/transactions/:id/relations" $ do
    it "returns the outbound edge on the refund income and the inbound edge on the expense" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "refund-http-relations@test.com"
      token <- seedToken seed
      expenseId <- seedExpense seed

      createResp <-
        httpRequest
          seed.seedApp
          "POST"
          "/api/transactions/income"
          (authHeaders token)
          (refundIncomeBody seed expenseId)
      simpleStatus createResp `shouldBe` status200
      incomeId <- case eitherDecode (simpleBody createResp) :: Either String TransactionResponse of
        Left err -> fail $ "bad create JSON: " <> err
        Right tr -> pure tr.id

      -- Outbound view from the refund income.
      outResp <-
        httpRequest
          seed.seedApp
          "GET"
          (encodeUtf8 $ "/api/transactions/" <> uuidText incomeId <> "/relations")
          (authHeaders token)
          ""
      simpleStatus outResp `shouldBe` status200
      case eitherDecode (simpleBody outResp) :: Either String TransactionRelationsResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right rr -> do
          map (.relatedTransactionId) rr.outbound
            `shouldBe` [unTransactionId expenseId]
          rr.inbound `shouldBe` []

      -- Inbound view from the expense.
      inResp <-
        httpRequest
          seed.seedApp
          "GET"
          (encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId expenseId) <> "/relations")
          (authHeaders token)
          ""
      simpleStatus inResp `shouldBe` status200
      case eitherDecode (simpleBody inResp) :: Either String TransactionRelationsResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right rr -> do
          rr.outbound `shouldBe` []
          map (.relatedTransactionId) rr.inbound `shouldBe` [incomeId]
          List.sort (map (.relationKind) rr.inbound) `shouldBe` ["refund"]

  describe "POST /api/transactions/:id/relations" $ do
    it "adds an 'associated' edge between two existing expenses and returns the updated owner" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "add-http-assoc@test.com"
      token <- seedToken seed
      ownerId <- seedExpense seed
      otherId <- seedExpense seed

      resp <- addRelation seed token ownerId (addRelationBody otherId "associated")

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          -- The response is the owner (:id) transaction, now carrying the edge.
          tr.id `shouldBe` unTransactionId ownerId
          map (.relatedTransactionId) tr.relations `shouldBe` [unTransactionId otherId]
          map (.relationKind) tr.relations `shouldBe` ["associated"]

    it "returns 422 for an unknown relation kind token and creates no edge" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "add-http-unknown@test.com"
      token <- seedToken seed
      ownerId <- seedExpense seed
      otherId <- seedExpense seed

      resp <- addRelation seed token ownerId (addRelationBody otherId "sideways")
      simpleStatus resp `shouldBe` status422

      -- No edge was recorded: the owner still reports no outbound relations.
      forward <- runAppM seed.seedEnv (TransactionService.getOutboundRelations ownerId)
      forward `shouldBe` []

    it "returns 404 when the owner :id is a non-existent transaction" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "add-http-missing-owner@test.com"
      token <- seedToken seed
      otherId <- seedExpense seed
      -- An owner id that was never created: the service's
      -- 'ensureCanAccessTransaction' on the owner yields NotFound → 404.
      let missingOwner = UUID.fromWords 0xDEAD 0xBEEF 0 1

      resp <-
        httpRequest
          seed.seedApp
          "POST"
          (encodeUtf8 $ "/api/transactions/" <> UUID.toText missingOwner <> "/relations")
          (authHeaders token)
          (addRelationBody otherId "associated")
      simpleStatus resp `shouldBe` status404

    it "returns 422 for the lineage kind 'merge' (not addable via this endpoint) and creates no edge" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "add-http-merge@test.com"
      token <- seedToken seed
      ownerId <- seedExpense seed
      otherId <- seedExpense seed

      resp <- addRelation seed token ownerId (addRelationBody otherId "merge")
      simpleStatus resp `shouldBe` status422

      forward <- runAppM seed.seedEnv (TransactionService.getOutboundRelations ownerId)
      forward `shouldBe` []

  describe "DELETE /api/transactions/:id/relations" $ do
    it "removes an 'associated' edge and returns the updated owner without it" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "unlink-http-assoc@test.com"
      token <- seedToken seed
      ownerId <- seedExpense seed
      otherId <- seedExpense seed

      -- Set up state: add the associated edge via the POST endpoint.
      addResp <- addRelation seed token ownerId (addRelationBody otherId "associated")
      simpleStatus addResp `shouldBe` status200

      resp <-
        httpRequest
          seed.seedApp
          "DELETE"
          ( encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId ownerId)
              <> "/relations?relatedTransactionId="
              <> uuidText (unTransactionId otherId)
              <> "&relationKind=associated"
          )
          (authHeaders token)
          ""

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          tr.id `shouldBe` unTransactionId ownerId
          tr.relations `shouldBe` []

      -- The edge is gone from the store too.
      forward <- runAppM seed.seedEnv (TransactionService.getOutboundRelations ownerId)
      forward `shouldBe` []

    it "removes an 'associated' edge issued from the 'to' endpoint (reverse direction)" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "unlink-http-assoc-reverse@test.com"
      token <- seedToken seed
      -- Edge is stored a->b (POST on 'a'); DELETE is issued on 'b' (the 'to' endpoint).
      aId <- seedExpense seed
      bId <- seedExpense seed

      addResp <- addRelation seed token aId (addRelationBody bId "associated")
      simpleStatus addResp `shouldBe` status200

      resp <-
        httpRequest
          seed.seedApp
          "DELETE"
          ( encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId bId)
              <> "/relations?relatedTransactionId="
              <> uuidText (unTransactionId aId)
              <> "&relationKind=associated"
          )
          (authHeaders token)
          ""

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          tr.id `shouldBe` unTransactionId bId
          tr.relations `shouldBe` []

      -- The stored a->b edge is resolved and removed.
      forward <- runAppM seed.seedEnv (TransactionService.getOutboundRelations aId)
      forward `shouldBe` []

    it "returns 422 for the lineage kind 'merge' (not removable via this endpoint)" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "unlink-http-merge@test.com"
      token <- seedToken seed
      ownerId <- seedExpense seed
      otherId <- seedExpense seed

      resp <-
        httpRequest
          seed.seedApp
          "DELETE"
          ( encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId ownerId)
              <> "/relations?relatedTransactionId="
              <> uuidText (unTransactionId otherId)
              <> "&relationKind=merge"
          )
          (authHeaders token)
          ""
      simpleStatus resp `shouldBe` status422

    it "returns 404 when there is no edge between the pair" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "unlink-http-absent@test.com"
      token <- seedToken seed
      ownerId <- seedExpense seed
      otherId <- seedExpense seed

      resp <-
        httpRequest
          seed.seedApp
          "DELETE"
          ( encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId ownerId)
              <> "/relations?relatedTransactionId="
              <> uuidText (unTransactionId otherId)
              <> "&relationKind=associated"
          )
          (authHeaders token)
          ""
      simpleStatus resp `shouldBe` status404
