{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TransactionAPISpec
-- Description : HTTP-level tests for GET /api/transactions, DELETE /api/transactions/:id
--
-- Exercises endpoints through the full Servant stack.
--
-- Seeded happy-path coverage (ordering, date filtering) is already provided
-- end-to-end by TransactionListSpec and TransactionListPropertySpec; this
-- file focuses on the HTTP envelope — status codes, validation wiring, and
-- the "hide existence" semantics for forbidden accountIds.
--
-- DELETE /api/transactions/:id cases:
--   204  happy path: Completed tx, valid JWT, caller is Editor
--   401  no Authorization header
--   400  caller has no access (AccountError → 400)
--   400  caller has Viewer (read-only) role (AccountError → 400)
--   409  TX date ≤ books-closed-through cutoff (CannotEditClosedPeriod → 409)
--   404  unknown UUID (transaction not found)
--   409  already-cancelled transaction
--   400  malformed UUID in path (Servant Capture parse failure → 400)
--
-- NOTE on "amend-in-progress" (409 conflict): the synchronous in-memory
-- event bus completes both the amendment and cancellation sagas atomically
-- within a single 'runAppM' call.  There is no way to engineer the transient
-- in-flight state at the HTTP layer in tests.  This case is tested at the
-- pure handler level in 'Domain.Transaction.CancellationCommandHandlerSpec'.
--
-- GET /api/transactions ?status cases (absent = all statuses):
--   (no param)            cancelled/failed txs PRESENT (behaviour flip)
--   ?status=cancelled     only cancelled, carries status = "Cancelled"
--   ?status=failed        only failed, carries status = "Failed"
--   ?status=completed     cancelled/failed absent
--   ?status=bogus         400 (unknown token)
--
-- GET /api/transactions pagination cases:
--   ?limit=&offset=       slice the result; totalCount = all matches; echoed
--   ?limit=0              400 (out of range)
module Web.API.TransactionAPISpec (spec) where

import qualified Application.Services.AccountService as AccountService
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Application.Services.TransactionService as TransactionService
import Data.Aeson (eitherDecode)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID4
import Domain.Core.Types
  ( TransactionId,
    UserId,
    unAccountId,
    unTransactionId,
    unUserId,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (runAppM)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Network.HTTP.Types (status200, status204, status400, status401, status404, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified RIO.List as List
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkApp)
import Testkit.Auth (generateTestToken)
import Testkit.Fixtures
  ( MetadataFixture (..),
    createDefaultAccount,
    registerUser,
    setupMetadataFixture,
  )
import Testkit.HspecWai (bearerHeader, getJSONAuth)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    seedTransfer,
    uuidText,
  )
import Web.Server (buildApplication)
import Web.Types
  ( ErrorResponse (..),
    TransactionListResponse (..),
    TransactionResponse (..),
    ValidationErrorResponse (..),
  )

-- -----------------------------------------------------------------------------
-- GET /api/transactions (original tests, kept as-is)
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
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
              body.limit `shouldBe` 50
              body.offset `shouldBe` 0

      it "returns 400 when dateFrom > dateTo" $ do
        token <- liftIO generateTestToken
        resp <-
          request
            "GET"
            "/api/transactions?dateFrom=2026-04-18T00:00:00Z&dateTo=2026-04-10T00:00:00Z"
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
              Map.lookup "date" env.fieldErrors
                `shouldBe` Just "from must be <= to"

      it "returns 400 when accountId is not a UUID" $ do
        token <- liftIO generateTestToken
        resp <- getJSONAuth "/api/transactions?accountId=not-a-uuid" token
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 400 for an unknown status token" $ do
        token <- liftIO generateTestToken
        resp <- request "GET" "/api/transactions?status=bogus" [bearerHeader token] ""
        liftIO $ simpleStatus resp `shouldBe` status400

      it "returns 400 for limit=0" $ do
        token <- liftIO generateTestToken
        resp <- request "GET" "/api/transactions?limit=0" [bearerHeader token] ""
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

  -- ---------------------------------------------------------------------------
  -- DELETE /api/transactions/:id
  -- ---------------------------------------------------------------------------

  describe "DELETE /api/transactions/:id" $ do
    it "returns 204 No Content for a completed transfer the caller owns" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "delete-happy@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed
      let path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      resp <- httpRequest seed.seedApp "DELETE" path (authHeaders token) ""
      simpleStatus resp `shouldBe` status204

    it "returns 401 when Authorization header is missing" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "delete-noauth@test.com"
      txId <- seedTransfer seed
      let path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      resp <- httpRequest seed.seedApp "DELETE" path [] ""
      simpleStatus resp `shouldBe` status401

    it "returns 400 when caller has no access to the transaction's accounts" $ do
      -- Seed the transaction under owner's account, then attempt DELETE as outsider.
      seed <- mkSeed createTestAppEnvWithProcessManager "delete-noaccess-owner@test.com"
      txId <- seedTransfer seed
      -- Register a second, unrelated user
      outsiderId <- registerUser seed.seedEnv "delete-noaccess-outsider@test.com"
      outsiderToken <- mintToken outsiderId "delete-noaccess-outsider@test.com"
      let path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      resp <- httpRequest seed.seedApp "DELETE" path (authHeaders outsiderToken) ""
      -- AccountError → 400 (not 403) per Web.ErrorMapping
      simpleStatus resp `shouldBe` status400
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "ACCOUNT_ERROR"

    it "returns 400 when caller has Viewer (read-only) role on the account" $ do
      -- Owner seeds a transfer; a viewer-role user attempts the DELETE.
      env <- createTestAppEnvWithProcessManager
      runAppM env ConfigurationService.seedDefaultConfiguration
      ownerId <- registerUser env "delete-viewer-owner@test.com"
      viewerId <- registerUser env "delete-viewer-viewer@test.com"
      accId <- createDefaultAccount env ownerId "Wallet"
      -- Share with Viewer role
      shareRes <-
        runAppM env
          $ AccountService.shareAccount
            ownerId
            (unAccountId accId)
            (unUserId viewerId)
            "viewer"
      case shareRes of
        Left err -> expectationFailure $ "shareAccount failed: " <> show err
        Right () -> pure ()
      -- Initiate a transfer so there is a transaction to cancel
      otherAccId <- createDefaultAccount env ownerId "Other"
      txRes <-
        runAppM env
          $ TransactionService.initiateTransfer
            ownerId
            accId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Test"
            Nothing
            Nothing
            Nothing
      txId <- case txRes of
        Left err -> expectationFailure ("initiateTransfer failed: " <> show err) >> undefined
        Right (tid, _) -> pure tid
      viewerToken <- mintToken viewerId "delete-viewer-viewer@test.com"
      let app = buildApplication env
          path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      resp <- httpRequest app "DELETE" path (authHeaders viewerToken) ""
      -- Viewer has no editor access → AccountError → 400
      simpleStatus resp `shouldBe` status400
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "ACCOUNT_ERROR"

    it "returns 409 when TX date is in a closed accounting period" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "delete-books-owner@test.com"
      src <- createDefaultAccount env fx.userId "Src"
      tgt <- createDefaultAccount env fx.userId "Tgt"
      -- Backdated transfer
      let txDate = utc 2026 3 15
      txRes <-
        runAppM env
          $ TransactionService.initiateTransfer
            fx.userId
            src
            tgt
            (unsafeMoney Core.USD 50)
            Set.empty
            "Backdated"
            Nothing
            (Just txDate)
            Nothing
      txId <- case txRes of
        Left err -> expectationFailure ("initiateTransfer failed: " <> show err) >> undefined
        Right (tid, _) -> pure tid
      -- Close books past the TX date
      _ <- runAppM env (ConfigurationService.closeBooksThrough fx.userId (utc 2026 3 31))
      ownerToken <- mintToken fx.userId "delete-books-owner@test.com"
      let app = buildApplication env
          path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      resp <- httpRequest app "DELETE" path (authHeaders ownerToken) ""
      -- CannotEditClosedPeriod → 409
      simpleStatus resp `shouldBe` status409
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "CANNOT_EDIT_CLOSED_PERIOD"

    it "returns 404 for an unknown transaction UUID" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "delete-404@test.com"
      token <- seedToken seed
      unknown <- UUID4.nextRandom
      let path = encodeUtf8 $ "/api/transactions/" <> uuidText unknown
      resp <- httpRequest seed.seedApp "DELETE" path (authHeaders token) ""
      simpleStatus resp `shouldBe` status404

    it "returns 409 TRANSACTION_ALREADY_CANCELLED when cancelling twice" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "delete-double-cancel@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed
      -- First cancellation via the service layer to put it into Cancelled state
      _ <- runAppM seed.seedEnv (TransactionService.cancelTransaction seed.seedUserId txId)
      -- Second cancellation via HTTP — must be rejected
      let path = encodeUtf8 $ "/api/transactions/" <> uuidText (unTransactionId txId)
      resp <- httpRequest seed.seedApp "DELETE" path (authHeaders token) ""
      simpleStatus resp `shouldBe` status409
      case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right er -> er.code `shouldBe` "TRANSACTION_ALREADY_CANCELLED"

    it "returns 400 for a malformed (non-UUID) path segment" $ do
      -- Servant Capture "id" UUID fails to parse → 400
      seed <- mkSeed createTestAppEnvWithProcessManager "delete-malformed@test.com"
      token <- seedToken seed
      let path = "/api/transactions/not-a-uuid"
      resp <- httpRequest seed.seedApp "DELETE" path (authHeaders token) ""
      -- Servant returns 400 for path capture parse failures by default
      simpleStatus resp `shouldBe` status400

  -- ---------------------------------------------------------------------------
  -- GET /api/transactions ?status  (IN-filter; absent = all statuses)
  -- ---------------------------------------------------------------------------

  describe "GET /api/transactions ?status" $ do
    let acctPath seed extra =
          encodeUtf8
            $ "/api/transactions?accountId="
            <> uuidText (unAccountId seed.seedAccount)
            <> extra
        decodeBody resp f =
          case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
            Left err -> expectationFailure $ "bad JSON: " <> err
            Right body -> f body

    it "includes cancelled transactions by default (no status param)" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "status-default-cancelled@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed
      _ <- runAppM seed.seedEnv (TransactionService.cancelTransaction seed.seedUserId txId)
      resp <- httpRequest seed.seedApp "GET" (acctPath seed "") (authHeaders token) ""
      simpleStatus resp `shouldBe` status200
      decodeBody resp $ \body ->
        map (.id) body.transactions `shouldContain` [unTransactionId txId]

    it "status=cancelled returns the cancelled tx with status Cancelled" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "status-cancelled@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed
      _ <- runAppM seed.seedEnv (TransactionService.cancelTransaction seed.seedUserId txId)
      resp <- httpRequest seed.seedApp "GET" (acctPath seed "&status=cancelled") (authHeaders token) ""
      simpleStatus resp `shouldBe` status200
      decodeBody resp $ \body -> do
        map (.id) body.transactions `shouldContain` [unTransactionId txId]
        case List.find (\t -> t.id == unTransactionId txId) body.transactions of
          Nothing -> expectationFailure "cancelled tx not found"
          Just t -> t.status `shouldBe` "Cancelled"

    it "status=completed excludes a cancelled tx" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "status-completed-excl@test.com"
      token <- seedToken seed
      txId <- seedTransfer seed
      _ <- runAppM seed.seedEnv (TransactionService.cancelTransaction seed.seedUserId txId)
      resp <- httpRequest seed.seedApp "GET" (acctPath seed "&status=completed") (authHeaders token) ""
      simpleStatus resp `shouldBe` status200
      decodeBody resp $ \body ->
        map (.id) body.transactions `shouldNotContain` [unTransactionId txId]

    it "status=failed returns the failed tx with status Failed" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "status-failed@test.com"
      token <- seedToken seed
      txId <- seedFailedTransfer seed
      resp <- httpRequest seed.seedApp "GET" (acctPath seed "&status=failed") (authHeaders token) ""
      simpleStatus resp `shouldBe` status200
      decodeBody resp $ \body -> do
        map (.id) body.transactions `shouldContain` [unTransactionId txId]
        case List.find (\t -> t.id == unTransactionId txId) body.transactions of
          Nothing -> expectationFailure "failed tx not found"
          Just t -> t.status `shouldBe` "Failed"

  -- ---------------------------------------------------------------------------
  -- GET /api/transactions pagination
  -- ---------------------------------------------------------------------------

  describe "GET /api/transactions pagination" $ do
    it "slices by limit/offset; totalCount is the full match count; echoes limit/offset" $ do
      seed <- mkSeed createTestAppEnvWithProcessManager "pagination-slice@test.com"
      token <- seedToken seed
      _ <- seedTransfer seed
      _ <- seedTransfer seed
      _ <- seedTransfer seed
      let path =
            encodeUtf8
              $ "/api/transactions?accountId="
              <> uuidText (unAccountId seed.seedAccount)
              <> "&limit=2&offset=0"
      resp <- httpRequest seed.seedApp "GET" path (authHeaders token) ""
      simpleStatus resp `shouldBe` status200
      case eitherDecode (simpleBody resp) :: Either String TransactionListResponse of
        Left err -> expectationFailure $ "bad JSON: " <> err
        Right body -> do
          length body.transactions `shouldBe` 2
          body.totalCount `shouldBe` 3
          body.limit `shouldBe` 2
          body.offset `shouldBe` 0

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Seed a transfer that fails to post (Insufficient Funds) and lands in the
-- Failed state. The seed account starts at 5000 USD with no overdraft, so a
-- transfer larger than that emits TransactionPostingFailed via the synchronous
-- in-memory process manager, leaving the transaction in the read model as
-- status = Failed.
seedFailedTransfer :: Seed -> IO TransactionId
seedFailedTransfer seed = do
  other <- createDefaultAccount seed.seedEnv seed.seedUserId "Failed-Other"
  res <-
    runAppM seed.seedEnv
      $ TransactionService.initiateTransfer
        seed.seedUserId
        seed.seedAccount
        other
        (unsafeMoney Core.USD 999999)
        Set.empty
        "Seed failed transfer"
        Nothing
        Nothing
        Nothing
  case res of
    Left err -> fail $ "seedFailedTransfer failed: " <> show err
    Right (txId, _) -> pure txId

-- | Mint a JWT signed for an existing user.
mintToken :: UserId -> Text -> IO Text
mintToken uid email = do
  res <- generateToken defaultJWTConfig uid email
  case res of
    Left err -> fail $ "mintToken failed: " <> show err
    Right tok -> pure tok
