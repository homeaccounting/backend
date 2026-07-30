{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionMergeAPISpec
-- Description : HTTP-level tests for POST /api/transactions/:id/merge (tracker#30).
--
-- Exercises the merge endpoint: the request DTO ('MergeTransactionRequest'),
-- the 200 happy path (the response is the refreshed target with the combined
-- amount) — including when the amend transiently overdraws the account, a
-- guard the merge-originated amend is designed to bypass — and the
-- validation / conflict status mapping (400 empty list, 404 missing target,
-- 422 incompatibility, 409 non-Completed / closed period).
--
-- Uses the shared in-memory HTTP fixture ('Testkit.TransactionEditFixture');
-- like the sibling relations spec it runs entirely on the STM/SQLite in-memory
-- stores and needs no Postgres.
module Web.API.TransactionMergeAPISpec (spec) where

import Application.Services.ConfigurationService (closeBooksThrough)
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    TransactionId,
    defaultCash,
    unTransactionId,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv, runAppM)
import Network.HTTP.Types (status200, status400, status404, status409, status422)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.Fixtures (createAccount)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedExpense,
    seedExpenseFull,
    seedIncomeTransaction,
    seedToken,
    uuidText,
  )
import Web.Types (TransactionResponse (..))

-- -----------------------------------------------------------------------------
-- Merge-endpoint helpers
-- -----------------------------------------------------------------------------

-- | Merge request body naming the source ids.
mergeBody :: [TransactionId] -> LByteString
mergeBody sources =
  encode
    $ object ["sourceTransactionIds" .= [uuidText (unTransactionId s) | s <- sources]]

-- | POST /api/transactions/:target/merge with the given body.
postMerge :: Seed -> Text -> TransactionId -> LByteString -> IO SResponse
postMerge seed token target =
  httpRequest
    seed.seedApp
    "POST"
    (encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId target) <> "/merge")
    (authHeaders token)

-- | POST /api/transactions/<raw>/merge for an arbitrary raw path segment.
postMergeRaw :: Seed -> Text -> Text -> LByteString -> IO SResponse
postMergeRaw seed token rawTarget =
  httpRequest
    seed.seedApp
    "POST"
    (encodeUtf8 $ "/api/transactions/" <> rawTarget <> "/merge")
    (authHeaders token)

lowAccount :: AppEnv -> Seed -> Rational -> IO AccountId
lowAccount env seed = createAccount env seed.seedUserId "Low" defaultCash Core.USD

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "POST /api/transactions/:id/merge" $ do
  it "returns 200 and the refreshed target with the combined amount" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-ok@test.com"
    token <- seedToken seed
    targetId <- seedExpense seed 40
    sourceId <- seedExpense seed 40

    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status200
    case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
      Left err -> expectationFailure $ "bad JSON: " <> err
      Right tr -> do
        tr.id `shouldBe` unTransactionId targetId
        tr.sourceAmount `shouldBe` 80

  it "returns 400 for an empty source list" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-empty@test.com"
    token <- seedToken seed
    targetId <- seedExpense seed 40
    resp <- postMerge seed token targetId (mergeBody [])
    simpleStatus resp `shouldBe` status400

  it "returns 404 when the target does not exist" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-missing@test.com"
    token <- seedToken seed
    sourceId <- seedExpense seed 40
    let missing = UUID.fromWords 0xDEAD 0xBEEF 0 2
    resp <- postMergeRaw seed token (UUID.toText missing) (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status404

  it "returns 422 for incompatible kinds (income source into an expense target)" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-kinds@test.com"
    token <- seedToken seed
    targetId <- seedExpense seed 40
    sourceId <- seedIncomeTransaction seed mempty
    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status422

  it "returns 422 for a source on a different account" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-acct@test.com"
    token <- seedToken seed
    targetId <- seedExpense seed 40
    other <- createAccount seed.seedEnv seed.seedUserId "Wallet2" defaultCash Core.USD 5000
    sourceId <- seedExpenseFull seed other 30 Nothing Nothing
    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status422

  it "returns 422 for conflicting contacts" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-contacts@test.com"
    token <- seedToken seed
    targetId <- seedExpenseFull seed seed.seedAccount 40 (Just seed.seedContactA) Nothing
    sourceId <- seedExpenseFull seed seed.seedAccount 40 (Just seed.seedContactB) Nothing
    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status422

  it "returns 422 for a self-merge (source == target)" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-self@test.com"
    token <- seedToken seed
    targetId <- seedExpense seed 40
    resp <- postMerge seed token targetId (mergeBody [targetId])
    simpleStatus resp `shouldBe` status422

  it "returns 409 when a source is not Completed (already cancelled)" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-cancelled@test.com"
    token <- seedToken seed
    targetId <- seedExpense seed 40
    sourceId <- seedExpense seed 40
    cancelRes <- runAppM seed.seedEnv (TransactionService.cancelTransaction seed.seedUserId sourceId)
    case cancelRes of
      Left _ -> fail "cancel source failed"
      Right _ -> pure ()
    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status409

  it "returns 409 when the merge touches a closed period" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-closed@test.com"
    token <- seedToken seed
    targetId <- seedExpenseFull seed seed.seedAccount 40 Nothing (Just (utc 2026 3 10))
    sourceId <- seedExpense seed 40
    _ <- runAppM seed.seedEnv (closeBooksThrough seed.seedUserId (utc 2026 3 31))
    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status409

  it "returns 200 when the amend transiently overdraws the account (guard bypassed)" $ do
    -- The merge-originated amend sets allowOverdraft = True specifically so
    -- this transient double-debit (target amended up before the source's
    -- own debit is reversed by its cancel) doesn't fail the merge.
    seed <- mkSeed createTestAppEnvWithProcessManager "merge-http-funds@test.com"
    token <- seedToken seed
    low <- lowAccount seed.seedEnv seed 100
    targetId <- seedExpenseFull seed low 40 Nothing Nothing
    sourceId <- seedExpenseFull seed low 40 Nothing Nothing
    resp <- postMerge seed token targetId (mergeBody [sourceId])
    simpleStatus resp `shouldBe` status200
