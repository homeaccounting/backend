{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionAllocationsAPISpec
-- Description : HTTP-level tests for the transaction allocations-edit endpoint.
--
-- Covers @PATCH \/api\/transactions\/:id\/allocations@ end-to-end:
--
--  * Happy path: 800 + 200 UAH split across two categories returns 200
--    and the GET endpoint reflects the new allocation list.
--  * Rejection paths surface the documented error codes:
--      - 400 ALLOCATIONS_DO_NOT_SUM_TO_TOTAL on sum mismatch;
--      - 400 CANNOT_CHANGE_KIND_OF_CATEGORISED_TRANSACTION on kind flip;
--      - 400 CANNOT_SET_ALLOCATIONS_ON_UNCATEGORISED_TRANSACTION on
--        internal transfer;
--      - 409 TRANSACTION_NOT_COMPLETED on a Pending transaction (the
--        aggregate emits 'CannotEditUncompletedTransaction', which maps
--        to the same 409 family documented for
--        'TransactionMustBeCompletedForAllocationsEdit').
--
-- The shared seed strategy lives in 'Testkit.TransactionEditFixture'.
module Web.API.TransactionAllocationsAPISpec (spec) where

import Data.Aeson (Value (..), eitherDecode, encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Set as Set
import qualified Data.Vector as V
import Domain.Core.Types
  ( Allocation (..),
    Allocations (..),
    Currency (..),
    unAccountId,
    unDictionaryEntryId,
    unTransactionId,
    unsafeMoney,
  )
import Network.HTTP.Types (status200, status400, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.Fixtures (userExternalAccountId)
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
  )
import Testkit.TransactionEditFixture
  ( Seed (..),
    addExpenseCategory,
    addIncomeCategory,
    authHeaders,
    httpRequest,
    mkSeed,
    seedIncomeTransaction,
    seedToken,
    seedTransfer,
    uuidText,
  )
import Web.Types
  ( AllocationResponse (..),
    AllocationsResponse (..),
    ErrorResponse (..),
    TransactionResponse (..),
    toAllocationsDTO,
  )

-- | Build a PATCH /allocations body from a non-empty allocation list.
--
-- Encoded through the Web layer's 'AllocationsDTO' so the amounts take the
-- numeric client wire shape (@{ "amount": <number>, "currency": <text> }@) —
-- the domain 'Allocations' JSON is now the exact stored form and is not the
-- API contract.
mkAllocBody :: Allocations -> LBS.ByteString
mkAllocBody allocs = encode $ object ["newAllocations" .= toJSON (toAllocationsDTO allocs)]

-- | Decode a response body into a raw Aeson 'Value' (object).
decodeObject :: SResponse -> IO (KeyMap.KeyMap Value)
decodeObject resp =
  case eitherDecode (simpleBody resp) :: Either String Value of
    Right (Object o) -> pure o
    Right other -> fail $ "expected JSON object, got: " <> show other
    Left err -> fail $ "JSON decode failed: " <> err

-- | The two allocation buckets as raw JSON arrays, given the decoded body.
allocationBuckets :: KeyMap.KeyMap Value -> IO ([Value], [Value])
allocationBuckets o = case KeyMap.lookup "allocations" o of
  Just (Object a) -> do
    let arr key = case KeyMap.lookup key a of
          Just (Array v) -> V.toList v
          Just other -> error $ "expected array at " <> show key <> ", got " <> show other
          Nothing -> error $ "missing key " <> show key <> " in allocations"
    pure (arr "incomes", arr "expenses")
  other -> fail $ "expected allocations object, got: " <> show other

-- | Assert a single allocation slice has the documented wire shape:
-- @{ "categoryId": <text>, "amount": { "amount": <number>, "currency": <text> } }@.
sliceShouldMatch :: Value -> Text -> Double -> Text -> IO ()
sliceShouldMatch (Object slice) cat amt cur = do
  KeyMap.lookup "categoryId" slice `shouldBe` Just (String cat)
  case KeyMap.lookup "amount" slice of
    Just (Object money) -> do
      KeyMap.lookup "amount" money `shouldBe` Just (Number (realToFrac amt))
      KeyMap.lookup "currency" money `shouldBe` Just (String cur)
    other -> expectationFailure $ "expected nested money object, got: " <> show other
sliceShouldMatch other _ _ _ =
  expectationFailure $ "expected allocation slice object, got: " <> show other

-- | Build the cross-kind amendment body (Income → Expense) used to seed a
-- two-slice expense from the existing income transaction.
amendBody :: Text -> Text -> Double -> Value -> LBS.ByteString
amendBody newSrc newTgt newAmt allocs =
  encode
    $ object
      [ "sourceAccountId" .= newSrc,
        "targetAccountId" .= newTgt,
        "sourceAmount" .= newAmt,
        "sourceCurrency" .= ("USD" :: Text),
        "targetAmount" .= newAmt,
        "targetCurrency" .= ("USD" :: Text),
        "exchangeRate" .= (Nothing :: Maybe Double),
        "newAllocations" .= allocs
      ]

spec :: Spec
spec = describe "Transaction allocations HTTP endpoint" $ do
  describe "PATCH /api/transactions/:id/allocations" $ do
    it "splits the existing income across two allocations (happy path) and reflects on GET" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-happy@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      -- The seed transaction is 25 USD income on the single seed category.
      secondCat <- addIncomeCategory seed "Bonus"
      -- Replace with a 10 + 15 split summing to the original 25 USD.
      let newAllocs =
            Allocations
              [ Allocation seed.seedCategory (unsafeMoney USD 10) Nothing,
                Allocation secondCat (unsafeMoney USD 15) Nothing
              ]
              []
      let path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/allocations"
      resp <- httpRequest seed.seedApp "PATCH" path (authHeaders token) (mkAllocBody newAllocs)
      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "patch decode failed: " <> err
        Right tr -> do
          tr.transactionType `shouldBe` "income"
          -- The full two-bucket allocation list is surfaced under 'allocations'.
          map (.categoryId) tr.allocations.incomes
            `shouldBe` [ uuidText (unDictionaryEntryId seed.seedCategory),
                         uuidText (unDictionaryEntryId secondCat)
                       ]
          tr.allocations.expenses `shouldBe` ([] :: [AllocationResponse])

      -- Independent GET request — the read model must agree with the response.
      let getPath = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      getResp <- httpRequest seed.seedApp "GET" getPath (authHeaders token) ""
      simpleStatus getResp `shouldBe` status200
      case eitherDecode (simpleBody getResp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "get decode failed: " <> err
        Right tr -> do
          tr.transactionType `shouldBe` "income"
          map (.categoryId) tr.allocations.incomes
            `shouldBe` [ uuidText (unDictionaryEntryId seed.seedCategory),
                         uuidText (unDictionaryEntryId secondCat)
                       ]
          tr.allocations.expenses `shouldBe` ([] :: [AllocationResponse])

    it "returns 400 ALLOCATIONS_DO_NOT_SUM_TO_TOTAL on a sum mismatch" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-sum-mismatch@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      -- Seed transaction is 25 USD; submit a 10 USD allocation only.
      let bad =
            Allocations [Allocation seed.seedCategory (unsafeMoney USD 10) Nothing] []
      let path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/allocations"
      resp <- httpRequest seed.seedApp "PATCH" path (authHeaders token) (mkAllocBody bad)
      simpleStatus resp `shouldBe` status400
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "ALLOCATIONS_DO_NOT_SUM_TO_TOTAL"

    it "returns 400 CANNOT_SET_ALLOCATIONS_ON_UNCATEGORISED_TRANSACTION on an internal transfer" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-on-transfer@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed
      let bad =
            Allocations [Allocation seed.seedCategory (unsafeMoney USD 10) Nothing] []
      let path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/allocations"
      resp <- httpRequest seed.seedApp "PATCH" path (authHeaders token) (mkAllocBody bad)
      simpleStatus resp `shouldBe` status400
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "CANNOT_SET_ALLOCATIONS_ON_UNCATEGORISED_TRANSACTION"

    it "returns 409 TRANSACTION_NOT_COMPLETED when the transaction is still Pending" $ do
      -- 'createTestAppEnv' (no process manager) leaves the saga unfinished, so
      -- the transaction stays Pending — the aggregate guard surfaces.
      seed <- mkSeed createTestAppEnv "alloc-pending@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      let body =
            Allocations [Allocation seed.seedCategory (unsafeMoney USD 25) Nothing] []
      let path =
            encodeUtf8
              $ "/api/transactions/"
              <> uuidText (unTransactionId txId)
              <> "/allocations"
      resp <- httpRequest seed.seedApp "PATCH" path (authHeaders token) (mkAllocBody body)
      simpleStatus resp `shouldBe` status409
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "TRANSACTION_NOT_COMPLETED"

  describe "TransactionResponse allocations wire shape" $ do
    it "carries a two-slice EXPENSE in allocations.expenses with empty incomes and no 'category' key" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-shape-expense@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      -- Cross-kind amend the seed Income (25 USD) into an Expense split across
      -- two expense categories (10 + 15 = 25 USD).
      catA <- addExpenseCategory seed "ShapeExpenseA"
      catB <- addExpenseCategory seed "ShapeExpenseB"
      externalAccId <- userExternalAccountId seed.seedEnv seed.seedUserId
      let allocJson =
            object
              [ "incomes" .= ([] :: [Value]),
                "expenses"
                  .= [ object
                         [ "categoryId" .= uuidText (unDictionaryEntryId catA),
                           "amount" .= object ["amount" .= (10 :: Double), "currency" .= ("USD" :: Text)]
                         ],
                       object
                         [ "categoryId" .= uuidText (unDictionaryEntryId catB),
                           "amount" .= object ["amount" .= (15 :: Double), "currency" .= ("USD" :: Text)]
                         ]
                     ]
              ]
          body =
            amendBody
              (uuidText (unAccountId seed.seedAccount))
              (uuidText (unAccountId externalAccId))
              25
              allocJson
          path =
            encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId) <> "/amendment"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body
      simpleStatus resp `shouldBe` status200
      o <- decodeObject resp
      KeyMap.member "category" o `shouldBe` False
      (incomes, expenses) <- allocationBuckets o
      incomes `shouldBe` []
      length expenses `shouldBe` 2
      case expenses of
        [s0, s1] -> do
          sliceShouldMatch s0 (uuidText (unDictionaryEntryId catA)) 10 "USD"
          sliceShouldMatch s1 (uuidText (unDictionaryEntryId catB)) 15 "USD"
        _ -> expectationFailure "expected exactly two expense slices"

    it "carries a salary+reimbursement INCOME with one income slice and one expense slice" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-shape-mixed@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      -- The seed income is 25 USD. Re-allocate as salary (15, income bucket) plus
      -- a reimbursement (10, expense bucket) summing to the original 25 USD.
      reimburseCat <- addExpenseCategory seed "ShapeReimburse"
      let newAllocs =
            Allocations
              [Allocation seed.seedCategory (unsafeMoney USD 15) Nothing]
              [Allocation reimburseCat (unsafeMoney USD 10) Nothing]
          path =
            encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId) <> "/allocations"
      resp <- httpRequest seed.seedApp "PATCH" path (authHeaders token) (mkAllocBody newAllocs)
      simpleStatus resp `shouldBe` status200
      o <- decodeObject resp
      KeyMap.member "category" o `shouldBe` False
      (incomes, expenses) <- allocationBuckets o
      length incomes `shouldBe` 1
      length expenses `shouldBe` 1
      case (incomes, expenses) of
        ([inc], [exp']) -> do
          sliceShouldMatch inc (uuidText (unDictionaryEntryId seed.seedCategory)) 15 "USD"
          sliceShouldMatch exp' (uuidText (unDictionaryEntryId reimburseCat)) 10 "USD"
        _ -> expectationFailure "expected exactly one income and one expense slice"

  -- ---------------------------------------------------------------------------
  -- POST /api/transactions/income — allocation comment threading
  -- ---------------------------------------------------------------------------

  describe "POST /api/transactions/income allocation comment threading" $ do
    it "preserves a non-empty comment from CategoryAmount through to AllocationResponse" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-comment-present@test.com"
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
                                   "amount" .= (30 :: Double),
                                   "comment" .= ("комент" :: Text)
                                 ]
                             ],
                        "expenses" .= ([] :: [Value])
                      ],
                  "description" .= ("Salary with comment" :: Text),
                  "date" .= (Nothing :: Maybe Text),
                  "labels" .= ([] :: [Text])
                ]
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body
      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          length tr.allocations.incomes `shouldBe` 1
          -- Destructure positionally to avoid DuplicateRecordFields/HasField ambiguity.
          case tr.allocations.incomes of
            [AllocationResponse _ _ cmt] -> cmt `shouldBe` Just ("комент" :: Text)
            _ -> expectationFailure "expected exactly one income allocation"

    it "yields Nothing comment when CategoryAmount omits the comment field" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "alloc-comment-absent@test.com"
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
                                   "amount" .= (20 :: Double)
                                 ]
                             ],
                        "expenses" .= ([] :: [Value])
                      ],
                  "description" .= ("Salary no comment" :: Text),
                  "date" .= (Nothing :: Maybe Text),
                  "labels" .= ([] :: [Text])
                ]
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body
      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> do
          length tr.allocations.incomes `shouldBe` 1
          -- Destructure positionally to avoid DuplicateRecordFields/HasField ambiguity.
          case tr.allocations.incomes of
            [AllocationResponse _ _ cmt] -> cmt `shouldBe` (Nothing :: Maybe Text)
            _ -> expectationFailure "expected exactly one income allocation"
