{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransferAmendmentIntegrationSpec
-- Description : End-to-end HTTP coverage of the amendment + audit endpoints.
--
-- Drives @PUT \/api\/transactions\/:id\/amendment@ and
-- @GET \/api\/transactions\/:id\/history@ through the full HTTP stack
-- on a per-test seeded in-memory app with the TransferAmendmentManager
-- saga wired in. Covers the core amendment shapes from
-- @docs\/specs\/2026-05-20-transfer-amendment-saga-design.md@ §7.
module Integration.TransferAmendmentIntegrationSpec (spec) where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import qualified Data.Set as Set
import Domain.Core.Types
  ( AccountId,
    TransactionId,
    unAccountId,
    unMoney,
    unTransactionId,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import Network.HTTP.Types (Status, status200, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.Fixtures (createRegularAccount)
import Testkit.Helpers (singletonAllocation)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    uuidText,
  )
import Web.Types (TransactionResponse (..))

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

decodeTx :: SResponse -> IO TransactionResponse
decodeTx resp = case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
  Left err -> fail $ "expected TransactionResponse body, got: " <> err
  Right tr -> pure tr

txPathBy :: TransactionId -> ByteString
txPathBy txId =
  encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)

-- | Seed an Income transaction via the service layer; returns the
-- transaction id and the resulting read-model entry.
seedIncome :: Seed -> AccountId -> Double -> IO (TransactionId, TransactionData)
seedIncome seed accId amount = do
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateIncome
        seed.seedUserId
        accId
        (unsafeMoney Core.USD (toRational amount))
        (singletonAllocation seed.seedCategory (unsafeMoney Core.USD (toRational amount)))
        Set.empty
        "Seed"
        Nothing
  case res of
    Left err -> fail $ "seedIncome failed: " <> show err
    Right r -> pure r

-- | Seed an internal transfer via the service layer.
seedTransfer :: Seed -> AccountId -> AccountId -> Double -> IO (TransactionId, TransactionData)
seedTransfer seed src tgt amount = do
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateInternalTransfer
        seed.seedUserId
        src
        tgt
        (unsafeMoney Core.USD (toRational amount))
        Set.empty
        "Seed transfer"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "seedTransfer failed: " <> show err
    Right r -> pure r

-- | JSON body for the amendment endpoint. 'transferType' / category
-- are intentionally not in the payload — see 'AmendTransactionRequest'.
amendBody ::
  AccountId ->
  AccountId ->
  Double ->
  Double ->
  LByteString
amendBody newSrc newTgt newSrcAmt newTgtAmt =
  encode
    $ object
      [ "sourceAccountId" .= uuidText (unAccountId newSrc),
        "targetAccountId" .= uuidText (unAccountId newTgt),
        "sourceAmount" .= newSrcAmt,
        "sourceCurrency" .= ("USD" :: Text),
        "targetAmount" .= newTgtAmt,
        "targetCurrency" .= ("USD" :: Text),
        "exchangeRate" .= (Nothing :: Maybe Double)
      ]

balanceOf :: AppEnv -> AccountId -> IO Rational
balanceOf env aid = do
  m <- AccountRM.getAccount env.accountReadModel aid
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail "balanceOf: account not found"

shouldHaveStatus :: SResponse -> Status -> IO ()
shouldHaveStatus resp s = simpleStatus resp `shouldBe` s

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransferAmendment" $ do
  it "PUT /:id/amendment — amount-only amend on Income bumps amendmentCount and updates posting facts" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "amend-amount@test.com"
    token <- seedToken seed
    (txId, td) <- seedIncome seed seed.seedAccount 100
    let body = amendBody td.sourceAccountId td.targetAccountId 150 150
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status200
    tr <- decodeTx resp
    tr.amendmentCount `shouldBe` 1
    tr.sourceAmount `shouldBe` 150

  it "PUT /:id/amendment — same-account-pair payload returns 409" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "amend-same@test.com"
    token <- seedToken seed
    (txId, td) <- seedIncome seed seed.seedAccount 100
    let body = amendBody td.targetAccountId td.targetAccountId 50 50
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status409

  it "PUT /:id/amendment — flipping the Income's Regular target to its External source returns 409" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "amend-account-type@test.com"
    token <- seedToken seed
    (txId, td) <- seedIncome seed seed.seedAccount 100
    -- Swap source and target so the new "target" is the External
    -- counterpart (originally the source). Should reject as account-type
    -- change.
    let body = amendBody td.targetAccountId td.sourceAccountId 100 100
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status409

  it "PUT /:id/amendment — source-account swap restores old source and debits new source" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "amend-source-swap@test.com"
    token <- seedToken seed
    walletB <- createRegularAccount seed.seedEnv seed.seedUserId "WalletB"
    walletC <- createRegularAccount seed.seedEnv seed.seedUserId "WalletC"

    (txId, _td) <- seedTransfer seed seed.seedAccount walletB 50
    walletA_Before <- balanceOf seed.seedEnv seed.seedAccount
    walletC_Before <- balanceOf seed.seedEnv walletC

    let body = amendBody walletC walletB 50 50
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status200
    tr <- decodeTx resp
    tr.amendmentCount `shouldBe` 1
    tr.sourceAccountId `shouldBe` unAccountId walletC

    walletA_After <- balanceOf seed.seedEnv seed.seedAccount
    walletC_After <- balanceOf seed.seedEnv walletC
    walletA_After `shouldBe` (walletA_Before + 50)
    walletC_After `shouldBe` (walletC_Before - 50)

  it "GET /:id/history — returns parseable JSON after a successful amend" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "amend-audit@test.com"
    token <- seedToken seed
    (txId, td) <- seedIncome seed seed.seedAccount 100
    let body = amendBody td.sourceAccountId td.targetAccountId 200 200
    putResp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus putResp status200

    histResp <-
      httpRequest seed.seedApp "GET" (txPathBy txId <> "/history") (authHeaders token) ""
    shouldHaveStatus histResp status200
    case eitherDecode (simpleBody histResp) :: Either String Value of
      Right _ -> pure ()
      Left err -> expectationFailure $ "expected JSON body, got: " <> err
