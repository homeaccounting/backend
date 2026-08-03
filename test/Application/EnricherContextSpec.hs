{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.EnricherContextSpec
-- Description : Proves the aggregate command runners stamp the ambient
--   'RequestContext' onto persisted event metadata.
--
-- 'Application.Services.Internal.runAccountCmd' (and its User/Transaction/
-- Configuration siblings) derive a 'MetadataEnricher' from
-- @view requestContextL@ rather than taking one as a parameter. This spec
-- sets a non-nil 'RequestContext' on the test 'AppEnv', runs
-- 'AccountService.createAccount' under it, and reads the persisted
-- 'AccountCreated' event straight back out of the event store to assert its
-- metadata carries the correlation id and acting user.
module Application.EnricherContextSpec (spec) where

import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService (changeDefaultCurrency, seedDefaultConfiguration)
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types (AccountType (..), Currency (..), UserId, defaultCash, unAccountId, unConfigurationId)
import Eventium (EventMetadata (..), EventStoreReader (..), StreamEvent (..), allEvents)
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Observability.Context (RequestContext (..), renderUserId)
import RIO
import Test.Hspec
import Testkit.Helpers (fromRight', mockMoney, mockUserId, shouldBeRight)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

testCorrelationId :: UUID.UUID
testCorrelationId = UUID.fromWords 7 7 7 7

testUserUuid :: UUID.UUID
testUserUuid = UUID.fromWords 9 9 9 9

testUserId :: UserId
testUserId = mockUserId testUserUuid

validCreateAccount :: CreateAccount
validCreateAccount =
  CreateAccount
    { name = "Savings",
      initialBalance = mockMoney 1000,
      createdBy = testUserId,
      accountType = Regular defaultCash,
      overdraftLimit = Nothing
    }

spec :: Spec
spec = describe "Request-context metadata enrichment" $ do
  it "stamps correlationId and userId onto the persisted AccountCreated event" $ do
    baseEnv <- createTestAppEnv
    let ctx = RequestContext testCorrelationId (Just testUserId)
        env = baseEnv {requestContext = ctx}

    result <- runAppM env $ createAccount validCreateAccount
    shouldBeRight result
    let (accountId, _account) = fromRight' result

    let EventStoreReader readStream = env.eventStoreReader
    events <- readStream (allEvents (unAccountId accountId))
    let metadatas = [md | StreamEvent _ _ md _payload <- events]
    map (\md -> md.correlationId) metadatas `shouldBe` [Just testCorrelationId]
    map (\md -> Map.lookup "userId" md.custom) metadatas
      `shouldBe` [Just (renderUserId testUserId)]

  it "leaves metadata unenriched when the ambient context is nil" $ do
    env <- createTestAppEnv

    result <- runAppM env $ createAccount validCreateAccount
    shouldBeRight result
    let (accountId, _account) = fromRight' result

    let EventStoreReader readStream = env.eventStoreReader
    events <- readStream (allEvents (unAccountId accountId))
    let metadatas = [md | StreamEvent _ _ md _payload <- events]
    map (\md -> md.correlationId) metadatas `shouldBe` [Just UUID.nil]
    map (\md -> Map.lookup "userId" md.custom) metadatas `shouldBe` [Nothing]

  it "stamps correlationId on events copied by cloneConfiguration's copy path" $ do
    baseEnv <- createTestAppEnv
    let ctx = RequestContext testCorrelationId (Just testUserId)
        env = baseEnv {requestContext = ctx}

    -- Seed the shared default config (which carries dictionary entries), then
    -- register a user and trigger a clone-on-write. The clone re-emits the
    -- default's dictionary entries via 'copyDictionaries' into the new config
    -- stream — the events under test here.
    runAppM env seedDefaultConfiguration
    regResult <- runAppM env $ register "clone-enrich@test.com" "password123"
    let userId = (fromRight' regResult).userId

    result <- runAppM env $ changeDefaultCurrency userId EUR
    shouldBeRight result

    maybeUser <- runDbIn env (getUser userId)
    clonedConfigUuid <- case maybeUser of
      Nothing -> fail "User not found after clone" >> pure UUID.nil
      Just u -> pure (unConfigurationId u.configurationId)

    let EventStoreReader readStream = env.eventStoreReader
    events <- readStream (allEvents clonedConfigUuid)
    let correlationIds = [md.correlationId | StreamEvent _ _ md _payload <- events]
    -- More than just the two run*Cmd events (Create + ChangeDefaultCurrency):
    -- the copied dictionary entries are present, and every event — copy-path
    -- included — carries the ambient correlation id.
    length correlationIds `shouldSatisfy` (> 2)
    correlationIds `shouldSatisfy` all (== Just testCorrelationId)
