{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankingAPISpec
-- Description : Unit / HTTP tests for the banking API handler
--
-- Covers Phase 1 hardening of POST /api/banking/resync:
--
--   * The endpoint returns 404 when the banking feature flag is disabled.
--     The default test 'AppEnv' already ships with @banking.enabled = False@,
--     which makes this the "disabled" case without additional setup.
--
--   * 'buildBankLink' matches bank accounts to local accounts by IBAN, and
--     honours the caller's role:
--       - single match: returns that one pair.
--       - multi match:  picks the first deterministically and emits a warning.
--       - no match:     raises 'BankingError'.
--       - Viewer-only:  is excluded so read-only shares are never written to.
module Web.API.BankingAPISpec (spec) where

import Application.ReadModels.Account (AccountData (..))
import qualified Control.Exception as E
import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountAccess (..),
    AccountRole (..),
    AccountSubtype (..),
    AccountType (..),
    BankAccountProperties (..),
    Money,
    defaultBankAccountProperties,
  )
import qualified Domain.Core.Types as Core
import Infrastructure.App (runAppM)
import qualified Infrastructure.Banking.Provider as Banking
import Network.HTTP.Types (status404)
import Network.Wai.Test (SResponse (..))
import RIO
import Servant.Server (ServerError (..))
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkApp, mkAppBankingEnabled)
import Testkit.Auth (generateTestToken)
import Testkit.Helpers
  ( mockAccountId,
    mockMoneyWith,
    mockUserId,
  )
import Testkit.HspecWai (jsonAuthHeaders)
import Testkit.InMemoryEventStore (createTestAppEnv)
import Web.API.BankingAPI (buildBankLink)
import Web.Types (ErrorResponse (..))

-- -----------------------------------------------------------------------------
-- Common fixtures
-- -----------------------------------------------------------------------------

-- | Bank account fetched from the provider, carrying a sample IBAN.
sampleBankAccount :: Text -> Banking.BankAccount
sampleBankAccount iban =
  Banking.BankAccount
    { Banking.externalId = "ext-" <> iban,
      Banking.accountNumber = iban,
      Banking.currencyCode = 980,
      Banking.cardMasks = [],
      Banking.balance = 0
    }

-- | Construct a local AccountData whose IBAN equals the given text.
mkLocalBankAccount :: Core.UserId -> Text -> AccountData
mkLocalBankAccount owner iban =
  AccountData
    { name = "Bank " <> iban,
      balance = zeroMoney,
      createdBy = owner,
      accountType =
        Regular
          ( BankAccount
              defaultBankAccountProperties
                { accountNumber = Just iban
                }
          ),
      accessList = [AccountAccess {userId = owner, role = Owner}],
      overdraftLimit = Nothing,
      hasTransactions = False,
      version = 1
    }

zeroMoney :: Money
zeroMoney = mockMoneyWith Core.USD 0

-- | Convenience: an arbitrary but stable UserId for fixture building.
fixtureUserId :: Core.UserId
fixtureUserId = mockUserId (UUID.fromWords 1 0 0 0)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  buildBankLinkSpec
  featureFlagSpec

-- -----------------------------------------------------------------------------
-- buildBankLink unit tests
-- -----------------------------------------------------------------------------

buildBankLinkSpec :: Spec
buildBankLinkSpec = describe "buildBankLink" $ do
  it "returns a single (external, local) pair when exactly one IBAN matches" $ do
    env <- createTestAppEnv
    let iban = "UA001"
        localAccId = mockAccountId (UUID.fromWords 100 0 0 1)
        localAccs =
          [(localAccId, mkLocalBankAccount fixtureUserId iban, Owner)]
        bank = [sampleBankAccount iban]
    result <- runAppM env (buildBankLink bank localAccs)
    result `shouldBe` [("ext-" <> iban, localAccId)]

  it "picks the first candidate (and logs a warning) when an IBAN matches multiple local accounts" $ do
    env <- createTestAppEnv
    let iban = "UA002"
        firstId = mockAccountId (UUID.fromWords 200 0 0 1)
        secondId = mockAccountId (UUID.fromWords 200 0 0 2)
        localAccs =
          [ (firstId, mkLocalBankAccount fixtureUserId iban, Owner),
            (secondId, mkLocalBankAccount fixtureUserId iban, Editor)
          ]
        bank = [sampleBankAccount iban]
    result <- runAppM env (buildBankLink bank localAccs)
    -- The implementation is documented to pick the first candidate
    -- deterministically. The warning goes to the log function — we do not
    -- assert on log contents here (the test env logs to stderr), but we do
    -- assert that the picked pair is the first candidate.
    result `shouldBe` [("ext-" <> iban, firstId)]

  it "raises BankingError (a 400 ServerError) when no bank account matches" $ do
    env <- createTestAppEnv
    let localAccs =
          [ ( mockAccountId (UUID.fromWords 300 0 0 1),
              mkLocalBankAccount fixtureUserId "UA-LOCAL",
              Owner
            )
          ]
        bank = [sampleBankAccount "UA-REMOTE"]
    outcome <- E.try (runAppM env (buildBankLink bank localAccs))
    case outcome of
      Left (se :: ServerError) ->
        errHTTPCode se `shouldBe` 400
      Right _ ->
        expectationFailure "expected BankingError but got a successful mapping"

  it "filters out Viewer-shared accounts (they are not writable)" $ do
    env <- createTestAppEnv
    let iban = "UA003"
        viewerShared = mockAccountId (UUID.fromWords 400 0 0 1)
        localAccs =
          [(viewerShared, mkLocalBankAccount fixtureUserId iban, Viewer)]
        bank = [sampleBankAccount iban]
    outcome <- E.try (runAppM env (buildBankLink bank localAccs))
    case outcome of
      Left (se :: ServerError) ->
        errHTTPCode se `shouldBe` 400
      Right rs ->
        expectationFailure
          $ "expected Viewer-shared accounts to be ignored, got: "
          <> show rs

-- -----------------------------------------------------------------------------
-- Feature-flag HTTP test
-- -----------------------------------------------------------------------------

featureFlagSpec :: Spec
featureFlagSpec = do
  describe "POST /api/banking/resync (feature flag disabled)"
    $ with mkApp
    $ it "returns a 404 JSON envelope when banking.enabled is false"
    $ do
      token <- liftIO generateTestToken
      let headers = ("X-Banking-Token", "dummy-monobank-token") : jsonAuthHeaders token
      resp <- request "POST" "/api/banking/resync" headers sampleBody
      liftIO $ do
        simpleStatus resp `shouldBe` status404
        -- Response goes through Web.ErrorMapping, so the body must be a
        -- proper JSON envelope (not Servant's default empty body) and
        -- the code/details must identify the disabled feature so the
        -- test fails loudly if the mapping regresses to a different
        -- 404 variant.
        LBS.null (simpleBody resp) `shouldBe` False
        case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
          Left err -> expectationFailure $ "404 body is not an ErrorResponse: " <> err
          Right env -> do
            env.code `shouldBe` "FEATURE_DISABLED"
            env.details `shouldBe` Just (Map.singleton "feature" "banking")

  describe "POST /api/banking/resync (feature flag enabled)"
    $ with mkAppBankingEnabled
    $ it "crosses the feature-flag gate when banking + monobank are enabled"
    $ do
      token <- liftIO generateTestToken
      let headers = ("X-Banking-Token", "dummy-monobank-token") : jsonAuthHeaders token
      resp <- request "POST" "/api/banking/resync" headers sampleBody
      -- The downstream Monobank call points at 127.0.0.1:1 and will
      -- fail with some 4xx/5xx. We don't care about the exact code,
      -- only that the gate did NOT short-circuit to 404. This guards
      -- against accidentally inverting the `unless` predicate in the
      -- handler.
      liftIO $ simpleStatus resp `shouldNotBe` status404
  where
    fromDay :: UTCTime
    fromDay = UTCTime (fromGregorian 2026 4 1) 0
    toDay :: UTCTime
    toDay = UTCTime (fromGregorian 2026 4 10) (secondsToDiffTime 0)
    sampleBody =
      encode
        $ object
          [ "from" .= fromDay,
            "to" .= toDay
          ]
