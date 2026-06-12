{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionMetadataEditIntegrationSpec
-- Description : End-to-end HTTP coverage of the description / date edit endpoints.
--
-- Drives the new @PUT \/api\/transactions\/:id\/description@ and
-- @PUT \/api\/transactions\/:id\/date@ endpoints through the full HTTP
-- stack on a per-test seeded in-memory app, then verifies the changes
-- propagate to:
--
--   1. @GET \/api\/transactions\/:id@ — single-transaction read,
--   2. @GET \/api\/transactions@      — list read,
--   3. 'balanceAsOf' on the seeded user's External account — proves the
--      Task 9 leg→TX join is wired end-to-end, i.e. moving the
--      transaction date out of March removes the leg from the
--      March-31 balance.
--
-- See @docs\/plans\/2026-05-20-editable-transaction-metadata.md@ Task 10.
module Integration.TransactionMetadataEditIntegrationSpec (spec) where

import Application.ReadModels.Account (balanceAsOf)
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TxRM
import Application.ReadModels.User (UserData (..), getUser)
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    Money,
    unAccountId,
    unDictionaryEntryId,
    unsafeMoney,
  )
import Infrastructure.App (AppEnv (..))
import Network.HTTP.Types (status200)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    uuidText,
  )
import Web.Types
  ( TransactionListResponse (..),
    TransactionResponse (..),
  )

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Render a 'UTCTime' the way the API's 'TransactionResponse' renders
-- the @date@ field, so we can compare against the JSON body directly.
-- Mirrors 'Web.Types.fromTransactionData' exactly.
isoText :: UTCTime -> Text
isoText t = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" t

decodeTx :: SResponse -> IO TransactionResponse
decodeTx resp = case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
  Left err -> fail $ "expected TransactionResponse body, got: " <> err
  Right tr -> pure tr

decodeList :: SResponse -> IO TransactionListResponse
decodeList resp = case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
  Left err -> fail $ "expected TransactionListResponse body, got: " <> err
  Right tlr -> pure tlr

-- | Look up the seeded user's External account so balance-as-of can be
-- queried for the leg that an Income transaction debits.
externalAccountIdFor :: Seed -> IO AccountId
externalAccountIdFor seed = do
  mUser <- getUser seed.seedEnv.userReadModel seed.seedUserId
  case mUser of
    Nothing -> fail "externalAccountIdFor: user not found"
    Just ud -> pure ud.externalAccountId

-- | Mirror the snapshot+join 'AccountService.adjustBalance' performs: take
-- a snapshot of the transaction read model and feed a pure @TX → at@
-- lookup into the balance fold. This is what proves Task 9 end-to-end —
-- the @at@ a user edits via @PUT \/:id\/date@ must be the @at@ the
-- balance fold consults.
balanceAt :: AppEnv -> AccountId -> UTCTime -> IO (Maybe Money)
balanceAt env accountId asOf = do
  txnMap <- TxRM.getAllTransactions env.transactionReadModel
  let lookupTxAt txId = (.date) <$> Map.lookup txId txnMap
  balanceAsOf env.eventStoreReader lookupTxAt accountId asOf

-- | Create an Income for the seed at the given date with the given
-- description and return the parsed response.
createIncome :: Seed -> Text -> Text -> UTCTime -> IO TransactionResponse
createIncome seed token description at = do
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
                               "amount" .= (25 :: Double)
                             ]
                         ],
                    "expenses" .= ([] :: [Value])
                  ],
              "description" .= description,
              "date" .= at,
              "labels" .= ([] :: [Text])
            ]
  resp <-
    httpRequest seed.seedApp "POST" "/api/transactions/income" (authHeaders token) body
  simpleStatus resp `shouldBe` status200
  decodeTx resp

-- | Build the @/api/transactions/<uuid>@ path for the given response.
txPathFor :: TransactionResponse -> ByteString
txPathFor tr = encodeUtf8 $ "/api/transactions/" <> uuidText tr.id

-- | Seed an Income transaction dated 2026-03-15 with description
-- "Initial". Returns everything later tests need: the seed, JWT token,
-- the External account id, and the created transaction.
setupInitialIncome :: Text -> IO (Seed, Text, AccountId, TransactionResponse)
setupInitialIncome email = do
  seed <- mkSeed createTestAppEnvWithProcessManager email
  token <- seedToken seed
  external <- externalAccountIdFor seed
  created <- createIncome seed token "Initial" (utc 2026 3 15)
  pure (seed, token, external, created)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransactionMetadataEdit" $ do
  it "PUT /:id/description updates the description and a follow-up GET reflects it" $ do
    (seed, token, _external, created) <- setupInitialIncome "metadata-desc@test.com"
    created.description `shouldBe` "Initial"

    let body = encode $ object ["description" .= ("Edited" :: Text)]
        path = txPathFor created
    putResp <-
      httpRequest seed.seedApp "PUT" (path <> "/description") (authHeaders token) body
    simpleStatus putResp `shouldBe` status200
    putTx <- decodeTx putResp
    putTx.description `shouldBe` "Edited"

    getResp <- httpRequest seed.seedApp "GET" path (authHeaders token) ""
    simpleStatus getResp `shouldBe` status200
    getTx <- decodeTx getResp
    getTx.description `shouldBe` "Edited"

  it "PUT /:id/date updates the business date and a follow-up GET reflects it" $ do
    (seed, token, _external, created) <- setupInitialIncome "metadata-date@test.com"
    let movedAt = utc 2026 4 2
        body = encode $ object ["at" .= movedAt]
        path = txPathFor created
    putResp <-
      httpRequest seed.seedApp "PUT" (path <> "/date") (authHeaders token) body
    simpleStatus putResp `shouldBe` status200
    putTx <- decodeTx putResp
    putTx.date `shouldBe` isoText movedAt

    getResp <- httpRequest seed.seedApp "GET" path (authHeaders token) ""
    simpleStatus getResp `shouldBe` status200
    getTx <- decodeTx getResp
    getTx.date `shouldBe` isoText movedAt

  it "GET /api/transactions list reflects edited description and date" $ do
    (seed, token, _external, created) <- setupInitialIncome "metadata-list@test.com"
    let movedAt = utc 2026 4 2
        path = txPathFor created

    _ <-
      httpRequest
        seed.seedApp
        "PUT"
        (path <> "/description")
        (authHeaders token)
        (encode $ object ["description" .= ("Edited" :: Text)])
    _ <-
      httpRequest
        seed.seedApp
        "PUT"
        (path <> "/date")
        (authHeaders token)
        (encode $ object ["at" .= movedAt])

    listResp <- httpRequest seed.seedApp "GET" "/api/transactions" (authHeaders token) ""
    simpleStatus listResp `shouldBe` status200
    listBody <- decodeList listResp
    listBody.totalCount `shouldBe` 1
    case listBody.transactions of
      [tr] -> do
        tr.id `shouldBe` created.id
        tr.description `shouldBe` "Edited"
        tr.date `shouldBe` isoText movedAt
      other ->
        expectationFailure
          $ "expected exactly one transaction in list, got: "
          <> show (length other)

  it "PUT /:id/date moves the leg out of an earlier balanceAsOf cutoff (Task 9)" $ do
    (seed, token, external, created) <- setupInitialIncome "metadata-balance@test.com"
    let march31 = utc 2026 3 31
        movedAt = utc 2026 4 2

    -- Sanity: before the edit the leg is in March's balance. The Income
    -- debits the External account by 25 USD, so its balance at the end
    -- of March is -25.
    preEditMarch <- balanceAt seed.seedEnv external march31
    preEditMarch `shouldBe` Just (unsafeMoney USD (-25))

    let path = txPathFor created
        body = encode $ object ["at" .= movedAt]
    putResp <-
      httpRequest seed.seedApp "PUT" (path <> "/date") (authHeaders token) body
    simpleStatus putResp `shouldBe` status200

    -- After the edit the leg has been moved into April; the March-31
    -- balance no longer includes it.
    postEditMarch <- balanceAt seed.seedEnv external march31
    postEditMarch `shouldBe` Just (unsafeMoney USD 0)
