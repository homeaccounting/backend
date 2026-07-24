{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionContactAPISpec
-- Description : HTTP-level tests for the transaction contact surface.
--
-- Exercises the request/response DTO additions (@contactId@ on create and
-- read paths), the contact-edit endpoint
-- @PUT \/api\/transactions\/:id\/contact@, and the amendment endpoint's
-- full-replacement @contactId@ threading. The per-test seed strategy lives
-- in 'Testkit.TransactionEditFixture' — see its haddock for the rationale.
module Web.API.TransactionContactAPISpec (spec) where

import Data.Aeson (Value, eitherDecode, encode, object, toJSON, (.=))
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID4
import Domain.Core.Types
  ( AccountId,
    unAccountId,
    unDictionaryEntryId,
    unTransactionId,
  )
import Network.HTTP.Types (status200, status404)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.Fixtures (userExternalAccountId)
import Testkit.InMemoryEventStore
  ( createTestAppEnvWithProcessManager,
  )
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedIncomeTransaction,
    seedToken,
    uuidText,
  )
import Web.Types
  ( ErrorResponse (..),
    TransactionResponse (..),
  )

-- | Standard income request body, with @contactId@ set from the given
-- 'Maybe UUID' (encodes as @null@ for 'Nothing').
incomeBody :: Seed -> Value -> Value
incomeBody seed contactJson =
  object
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
      "contactId" .= contactJson
    ]

-- | Body for @PUT \/api\/transactions\/:id\/amendment@ that preserves the
-- seed Income transaction's kind (External -> Regular), source\/target
-- account, and amount — varying only @contactId@. Mirrors @amendBody@ in
-- 'Web.API.TransactionAllocationsAPISpec'.
amendBody :: Seed -> AccountId -> Value -> Value
amendBody seed externalAccId contactJson =
  object
    [ "sourceAccountId" .= uuidText (unAccountId externalAccId),
      "targetAccountId" .= uuidText (unAccountId seed.seedAccount),
      "sourceAmount" .= (25 :: Double),
      "sourceCurrency" .= ("USD" :: Text),
      "targetAmount" .= (25 :: Double),
      "targetCurrency" .= ("USD" :: Text),
      "exchangeRate" .= (Nothing :: Maybe Double),
      "newAllocations"
        .= object
          [ "incomes"
              .= [ object
                     [ "categoryId" .= uuidText (unDictionaryEntryId seed.seedCategory),
                       "amount" .= object ["amount" .= (25 :: Double), "currency" .= ("USD" :: Text)]
                     ]
                 ],
            "expenses" .= ([] :: [Value])
          ],
      "contactId" .= contactJson
    ]

spec :: Spec
spec = describe "Transaction contact HTTP endpoints" $ do
  describe "POST /api/transactions/income" $ do
    it "returns 200 and echoes a valid contactId in the response" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "income-contact-ok@test.com"
      token <- seedToken seed
      let body = encode $ incomeBody seed (toJSON (uuidText (unDictionaryEntryId seed.seedContactA)))
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Just (unDictionaryEntryId seed.seedContactA)

    it "returns 200 with no contactId when the field is absent" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "income-contact-absent@test.com"
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
                  "date" .= (Nothing :: Maybe Text)
                ]
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Nothing

    it "returns 404 CONTACT_NOT_FOUND when contactId is unknown" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "income-contact-unknown@test.com"
      token <- seedToken seed
      alien <- UUID4.nextRandom
      let body = encode $ incomeBody seed (toJSON (uuidText alien))
      resp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body

      simpleStatus resp `shouldBe` status404
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "CONTACT_NOT_FOUND"

  describe "GET /api/transactions/:id" $ do
    it "includes the recorded contactId" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "get-contact@test.com"
      token <- seedToken seed
      let body = encode $ incomeBody seed (toJSON (uuidText (unDictionaryEntryId seed.seedContactA)))
      createResp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body
      created <- case eitherDecode (simpleBody createResp) :: Either String TransactionResponse of
        Left err -> fail $ "bad JSON: " <> err
        Right tr -> pure tr

      let path = encodeUtf8 $ "/api/transactions/" <> uuidText created.id
      resp <- httpRequest seed.seedApp "GET" path (authHeaders token) ""

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Just (unDictionaryEntryId seed.seedContactA)

  describe "PUT /api/transactions/:id/contact" $ do
    it "returns 200 and sets the contact on success" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-contact-ok@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty

      let body = encode $ object ["contactId" .= uuidText (unDictionaryEntryId seed.seedContactA)]
          path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId) <> "/contact"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Just (unDictionaryEntryId seed.seedContactA)

    it "clears the contact when contactId is null" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-contact-clear@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      let path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId) <> "/contact"

      setResp <-
        httpRequest
          seed.seedApp
          "PUT"
          path
          (authHeaders token)
          (encode $ object ["contactId" .= uuidText (unDictionaryEntryId seed.seedContactA)])
      simpleStatus setResp `shouldBe` status200

      clearResp <-
        httpRequest
          seed.seedApp
          "PUT"
          path
          (authHeaders token)
          (encode $ object ["contactId" .= (Nothing :: Maybe Text)])

      simpleStatus clearResp `shouldBe` status200
      case eitherDecode (simpleBody clearResp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Nothing

    it "returns 404 CONTACT_NOT_FOUND when the given contactId is unknown" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "put-contact-unknown@test.com"
      token <- seedToken seed
      txId <- seedIncomeTransaction seed Set.empty
      alien <- UUID4.nextRandom

      let body = encode $ object ["contactId" .= uuidText alien]
          path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId) <> "/contact"
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status404
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "CONTACT_NOT_FOUND"

  describe "PUT /api/transactions/:id/amendment" $ do
    it "preserves the existing contact when the amendment resends the same contactId" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "amend-contact-same@test.com"
      token <- seedToken seed
      externalAccId <- userExternalAccountId seed.seedEnv seed.seedUserId
      let createBody = encode $ incomeBody seed (toJSON (uuidText (unDictionaryEntryId seed.seedContactA)))
      createResp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) createBody
      created <- case eitherDecode (simpleBody createResp) :: Either String TransactionResponse of
        Left err -> fail $ "bad JSON: " <> err
        Right tr -> pure tr

      let path = encodeUtf8 $ "/api/transactions/" <> uuidText created.id <> "/amendment"
          body = encode $ amendBody seed externalAccId (toJSON (uuidText (unDictionaryEntryId seed.seedContactA)))
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Just (unDictionaryEntryId seed.seedContactA)

    it "changes the contact when the amendment sends a different contactId" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "amend-contact-change@test.com"
      token <- seedToken seed
      externalAccId <- userExternalAccountId seed.seedEnv seed.seedUserId
      let createBody = encode $ incomeBody seed (toJSON (uuidText (unDictionaryEntryId seed.seedContactA)))
      createResp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) createBody
      created <- case eitherDecode (simpleBody createResp) :: Either String TransactionResponse of
        Left err -> fail $ "bad JSON: " <> err
        Right tr -> pure tr

      let path = encodeUtf8 $ "/api/transactions/" <> uuidText created.id <> "/amendment"
          body = encode $ amendBody seed externalAccId (toJSON (uuidText (unDictionaryEntryId seed.seedContactB)))
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Just (unDictionaryEntryId seed.seedContactB)

    it "clears the contact when the amendment sends a null contactId" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "amend-contact-clear@test.com"
      token <- seedToken seed
      externalAccId <- userExternalAccountId seed.seedEnv seed.seedUserId
      let createBody = encode $ incomeBody seed (toJSON (uuidText (unDictionaryEntryId seed.seedContactA)))
      createResp <- httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) createBody
      created <- case eitherDecode (simpleBody createResp) :: Either String TransactionResponse of
        Left err -> fail $ "bad JSON: " <> err
        Right tr -> pure tr

      let path = encodeUtf8 $ "/api/transactions/" <> uuidText created.id <> "/amendment"
          body = encode $ amendBody seed externalAccId (toJSON (Nothing :: Maybe Text))
      resp <- httpRequest seed.seedApp "PUT" path (authHeaders token) body

      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right tr -> tr.contactId `shouldBe` Nothing
