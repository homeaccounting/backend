{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.CrossKindAmendmentIntegrationSpec
-- Description : Additional E2E coverage for cross-kind transaction amendments.
--
-- Covers three flows not exercised by Task 4's smoke tests in
-- 'Integration.TransactionAmendmentIntegrationSpec':
--
--   1. Income → Expense (endpoint swap) with supplied expense allocations.
--   2. Preservation of @externalTransactionId@ across a cross-kind amendment
--      (critical for the Monobank reclassification use case).
--   3. @amendmentCount@ invariant and audit-trail completeness after one
--      cross-kind amendment.
--
-- OUT OF SCOPE (follow-up): Monobank resync E2E (re-import skip via
-- @isImported@) requires full bank-import scaffolding and is documented as a
-- follow-up in @docs\/specs\/2026-06-02-cross-kind-amendment-design.md@.
module Integration.CrossKindAmendmentIntegrationSpec (spec) where

import Application.ReadModels.BankImportReadModel (isImported)
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Set as Set
import Data.Time (getCurrentTime)
import Domain.Core.Types
  ( AccountId,
    TransactionId,
    mkIncome,
    unAccountId,
    unDictionaryEntryId,
    unTransactionId,
    ImportInfo (..),
    unsafeExternalTransactionId,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Commands (InitiateTransaction (..))
import Infrastructure.App (runAppM)
import Network.HTTP.Types (Status, status200)
import Network.Wai.Test (SResponse (..), simpleBody, simpleStatus)
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, userExternalAccountId)
import Testkit.Helpers (singletonAllocation)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.TransactionEditFixture
  ( Seed (..),
    addExpenseCategory,
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    uuidText,
  )
import Web.Types (TransactionResponse (..))

-- -----------------------------------------------------------------------------
-- Helpers (local; mirror the pattern in TransactionAmendmentIntegrationSpec)
-- -----------------------------------------------------------------------------

decodeTx :: SResponse -> IO TransactionResponse
decodeTx resp =
  case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
    Left err -> fail $ "expected TransactionResponse body, got: " <> err
    Right tr -> pure tr

txPathBy :: TransactionId -> ByteString
txPathBy txId =
  encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)

shouldHaveStatus :: SResponse -> Status -> IO ()
shouldHaveStatus resp s = simpleStatus resp `shouldBe` s

-- | Seed an Income transaction (External → accId) via the service layer.
seedIncome :: Seed -> AccountId -> Double -> IO (TransactionId, ())
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
        Nothing
  case res of
    Left err -> fail $ "seedIncome failed: " <> show err
    Right (txId, _) -> pure (txId, ())

-- | Seed an Income transaction that carries an @externalTransactionId@.
-- Uses 'TransactionService.initiateTransaction' directly so the field is set.
seedIncomeWithExtId ::
  Seed ->
  AccountId ->
  Double ->
  Text ->
  IO TransactionId
seedIncomeWithExtId seed accId amount extId = do
  now <- getCurrentTime
  externalAccId <- userExternalAccountId seed.seedEnv seed.seedUserId
  let amt = unsafeMoney Core.USD (toRational amount)
      allocs = singletonAllocation seed.seedCategory amt
      tt = case mkIncome amt allocs of
        Left err -> error ("seedIncomeWithExtId: mkIncome failed: " <> show err)
        Right v -> v
      cmd =
        InitiateTransaction
          { sourceAccountId = externalAccId,
            targetAccountId = accId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Seed with extId",
            initiatedBy = seed.seedUserId,
            at = now,
            transactionType = tt,
            importInfo = Just ImportInfo {externalTransactionId = unsafeExternalTransactionId extId, mcc = Nothing},
            labels = Set.empty,
            relation = Nothing
          }
  res <- runAppM seed.seedEnv $ TransactionService.initiateTransaction cmd
  case res of
    Left err -> fail $ "seedIncomeWithExtId failed: " <> show err
    Right (txId, _) -> pure txId

-- | Build the JSON body for the amendment endpoint.
-- 'newAllocations' is included only when the pair is @Just allocs@.
amendBodyWithAllocations ::
  AccountId ->
  AccountId ->
  Double ->
  Maybe Value ->
  LBS.ByteString
amendBodyWithAllocations newSrc newTgt newAmt mAllocs =
  encode
    $ object
      [ "sourceAccountId" .= uuidText (unAccountId newSrc),
        "targetAccountId" .= uuidText (unAccountId newTgt),
        "sourceAmount" .= newAmt,
        "sourceCurrency" .= ("USD" :: Text),
        "targetAmount" .= newAmt,
        "targetCurrency" .= ("USD" :: Text),
        "exchangeRate" .= (Nothing :: Maybe Double),
        "newAllocations" .= mAllocs
      ]

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / CrossKindAmendment" $ do
  -- -------------------------------------------------------------------------
  -- Case 1: Income → Expense (endpoint swap) with supplied expense allocations
  -- -------------------------------------------------------------------------
  it "Income → Expense (endpoint swap) with supplied expense allocations" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "cross-kind-inc-to-exp@test.com"
    token <- seedToken seed
    -- The default seedCategory is an income category. Add a separate expense one.
    -- Use a unique name to avoid collision with default configuration entries.
    catRent <- addExpenseCategory seed "CrossKindTestExpense"
    -- Seed Income (External → seedAccount, 100 USD).
    (txId, _) <- seedIncome seed seed.seedAccount 100
    -- Resolve the user's External account (income source).
    externalAccId <- userExternalAccountId seed.seedEnv seed.seedUserId
    -- Amendment: swap to Expense (seedAccount → External).
    -- Regular → External = ExpenseKind.
    let allocJson =
          object
            [ "incomes" .= ([] :: [Value]),
              "expenses"
                .= [ object
                       [ "categoryId" .= uuidText (unDictionaryEntryId catRent),
                         "amount"
                           .= object
                             [ "amount" .= (100 :: Double),
                               "currency" .= ("USD" :: Text)
                             ]
                       ]
                   ]
            ]
        body =
          amendBodyWithAllocations
            seed.seedAccount
            externalAccId
            100
            (Just allocJson)
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status200
    tr <- decodeTx resp
    tr.transactionType `shouldBe` "expense"

  -- -------------------------------------------------------------------------
  -- Case 2: externalTransactionId is preserved across a cross-kind amendment
  -- -------------------------------------------------------------------------
  it "cross-kind amendment preserves externalTransactionId in the bank-import index" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "cross-kind-extid@test.com"
    token <- seedToken seed
    walletB <- createDefaultAccount seed.seedEnv seed.seedUserId "WalletB"
    let extIdText = "mono-xyz-123"
    -- Seed Income with externalTransactionId set.
    txId <- seedIncomeWithExtId seed seed.seedAccount 100 extIdText
    -- Verify the external ID is indexed before amendment.
    let extId = unsafeExternalTransactionId extIdText
    importedBefore <- runDbIn seed.seedEnv $ isImported extId
    importedBefore `shouldBe` True
    -- Amend: Income (External → seedAccount) → Transfer (seedAccount → walletB).
    let body =
          amendBodyWithAllocations
            seed.seedAccount
            walletB
            100
            Nothing
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status200
    tr <- decodeTx resp
    tr.transactionType `shouldBe` "transfer"
    -- The externalTransactionId index must still map to this transaction.
    importedAfter <- runDbIn seed.seedEnv $ isImported extId
    importedAfter `shouldBe` True

  -- -------------------------------------------------------------------------
  -- Case 3: amendmentCount invariant + audit trail after one cross-kind amend
  -- -------------------------------------------------------------------------
  it "cross-kind amendment bumps amendmentCount to 1 and history has all key events" $ do
    seed <- mkSeed createTestAppEnvWithProcessManager "cross-kind-audit@test.com"
    token <- seedToken seed
    walletB <- createDefaultAccount seed.seedEnv seed.seedUserId "WalletB"
    -- Seed Income (External → seedAccount, 100 USD).
    (txId, _) <- seedIncome seed seed.seedAccount 100
    -- Amend: Income → Transfer (seedAccount → walletB).
    let body =
          amendBodyWithAllocations
            seed.seedAccount
            walletB
            100
            Nothing
    resp <-
      httpRequest seed.seedApp "PUT" (txPathBy txId <> "/amendment") (authHeaders token) body
    shouldHaveStatus resp status200
    tr <- decodeTx resp
    -- amendmentCount must be exactly 1 after the first amendment.
    tr.amendmentCount `shouldBe` 1
    -- The audit history must contain at minimum the three key event types.
    histResp <-
      httpRequest seed.seedApp "GET" (txPathBy txId <> "/history") (authHeaders token) ""
    shouldHaveStatus histResp status200
    case eitherDecode (simpleBody histResp) :: Either String Value of
      Left err -> fail $ "expected JSON history body, got: " <> err
      Right _ -> pure ()
    -- Decode the body as UTF-8 text and check for the three key event tags.
    -- Using decodeUtf8Lenient on the raw bytes is the established pattern in
    -- this codebase — Show on a lazy ByteString varies by bytestring version.
    let rawHistory = decodeUtf8Lenient (LBS.toStrict (simpleBody histResp))
    rawHistory `shouldSatisfy` ("HistoryPostingInitiated" `T.isInfixOf`)
    rawHistory `shouldSatisfy` ("HistoryAmendmentInitiated" `T.isInfixOf`)
    rawHistory `shouldSatisfy` ("HistoryAmendmentCompleted" `T.isInfixOf`)
