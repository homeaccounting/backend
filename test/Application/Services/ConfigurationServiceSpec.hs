{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ConfigurationServiceSpec
-- Description : Unit tests for banking defaults seeding and cloning in ConfigurationService
--
-- Verifies that:
--   - seedDefaultConfiguration emits the three SetBanking* events so the
--     system configuration has populated banking defaults.
--   - cloneConfiguration carries all three banking fields forward from the
--     source, so clone-on-write does not silently drop banking state.
module Application.Services.ConfigurationServiceSpec (spec) where

import Application.ReadModels.Configuration (ConfigurationData (..), getConfiguration)
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addBankConnection,
    changeDefaultCurrency,
    getDecryptedConnectionToken,
    seedDefaultConfiguration,
    setBankConnectionAccountMap,
  )
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import Domain.Banking.Types (BankProvider (..), unsafeBankConnectionId)
import Domain.Configuration.CommandHandler (ConfigurationCommand (..))
import Domain.Configuration.Commands (AddBankConnection (..))
import Domain.Configuration.Defaults
  ( DefaultEntry (entryId),
    ExpenseDefaults (other),
    IncomeDefaults (other),
    defaultMccExpenseCategoryMap,
    expense,
    income,
  )
import Domain.Configuration.Projection
  ( BankConnection (..),
    BankingConfiguration (..),
  )
import Domain.Core.Types
  ( CreatedBy (..),
    Currency (..),
    defaultConfigurationId,
    unConfigurationId,
    unsafeAccountId,
  )
import Infrastructure.App
  ( AppEnv (..),
    HasEventStore (..),
    bankingKeyRingL,
  )
import Infrastructure.Crypto.SecretBox (decryptSecret, encryptSecret)
import Infrastructure.Eventium (applyConfigurationCommand)
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

spec :: Spec
spec = describe "ConfigurationService banking" $ do
  seedBankingDefaultsSpec
  cloneBankingDefaultsSpec
  addBankConnectionSpec
  setBankConnectionAccountMapSpec

-- -----------------------------------------------------------------------------
-- seedDefaultConfiguration populates banking defaults
-- -----------------------------------------------------------------------------

seedBankingDefaultsSpec :: Spec
seedBankingDefaultsSpec =
  describe "seedDefaultConfiguration" $ do
    it "populates banking defaults after seeding dictionaries" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      maybeConfig <- getConfiguration env.configurationReadModel defaultConfigurationId
      case maybeConfig of
        Nothing -> expectationFailure "Default configuration not found in read model"
        Just cfg -> do
          cfg.defaultIncomeCategory
            `shouldBe` Just income.other.entryId
          cfg.defaultExpenseCategory
            `shouldBe` Just expense.other.entryId
          cfg.banking.mccExpenseCategoryMap
            `shouldBe` defaultMccExpenseCategoryMap

-- -----------------------------------------------------------------------------
-- cloneConfiguration carries banking fields from source
-- -----------------------------------------------------------------------------

cloneBankingDefaultsSpec :: Spec
cloneBankingDefaultsSpec =
  describe "cloneConfiguration" $ do
    it "carries banking fields from source when clone-on-write is triggered" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      -- Register a user and trigger clone-on-write
      regResult <- runRIO env $ register "bankclone@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Any configuration mutation triggers clone-on-write for a System-owned config
          result <- runRIO env $ changeDefaultCurrency userId EUR
          result `shouldSatisfy` isRight

          -- The user now has a cloned configuration
          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found after clone"
            Just userData -> do
              userData.configurationId `shouldNotBe` defaultConfigurationId

              maybeClonedCfg <- getConfiguration env.configurationReadModel userData.configurationId
              case maybeClonedCfg of
                Nothing -> expectationFailure "Cloned configuration not found in read model"
                Just clonedCfg -> do
                  -- Banking defaults must have been carried over from the source
                  clonedCfg.defaultIncomeCategory
                    `shouldBe` Just income.other.entryId
                  clonedCfg.defaultExpenseCategory
                    `shouldBe` Just expense.other.entryId
                  clonedCfg.banking.mccExpenseCategoryMap
                    `shouldBe` defaultMccExpenseCategoryMap

                  -- Confirm it is a ClonedBy config (not System)
                  case clonedCfg.createdBy of
                    ClonedBy ownerId _ -> ownerId `shouldBe` userId
                    other -> expectationFailure $ "Expected ClonedBy, got: " <> show other

    it "carries bank connections forward on clone-on-write" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      -- Add a connection directly onto the System default config so that the
      -- next user's first mutation clones a source that already has a
      -- connection — exercising copyBanking's connection clone.
      ring <- runRIO env (view bankingKeyRingL)
      enc <- encryptSecret ring "u_defaulttoken"
      let connUuid = UUID.fromWords 1 2 3 4
          connId = unsafeBankConnectionId connUuid
          addConnCmd =
            AddBankConnectionConfigurationCommand
              AddBankConnection
                { connectionId = connId,
                  provider = Monobank,
                  name = "Seeded",
                  encryptedToken = enc,
                  tokenHint = "oken",
                  enabled = True
                }
      _ <-
        runRIO env $ do
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL
          liftIO $ applyConfigurationCommand writer reader id (unConfigurationId defaultConfigurationId) addConnCmd

      -- New user clones the default (which now has a connection) on first write.
      regResult <- runRIO env $ register "bankcloneconn@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          changeRes <- runRIO env $ changeDefaultCurrency userId GBP
          changeRes `shouldSatisfy` isRight

          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found after clone"
            Just userData -> do
              userData.configurationId `shouldNotBe` defaultConfigurationId
              maybeCfg <- getConfiguration env.configurationReadModel userData.configurationId
              case maybeCfg of
                Nothing -> expectationFailure "Cloned configuration not found"
                Just cfg ->
                  case Map.lookup connId cfg.banking.connections of
                    Nothing -> expectationFailure "Connection dropped by clone-on-write"
                    Just conn -> do
                      conn.name `shouldBe` "Seeded"
                      conn.enabled `shouldBe` True
                      conn.tokenHint `shouldBe` "oken"
                      decryptSecret ring conn.encryptedToken `shouldBe` Right "u_defaulttoken"

-- -----------------------------------------------------------------------------
-- addBankConnection encrypts the token and stores connection metadata
-- -----------------------------------------------------------------------------

addBankConnectionSpec :: Spec
addBankConnectionSpec =
  describe "addBankConnection" $ do
    it "stores an enabled connection with a token hint and encrypted token" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "addconn@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          let plaintext = "u_supersecrettoken1234"
          addResult <- runRIO env $ addBankConnection userId Monobank "My monobank" plaintext True
          connId <- case addResult of
            Left err -> do
              expectationFailure $ "addBankConnection failed: " <> show err
              error "unreachable"
            Right cid -> pure cid

          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              maybeCfg <- getConfiguration env.configurationReadModel userData.configurationId
              case maybeCfg of
                Nothing -> expectationFailure "Configuration not found"
                Just cfg ->
                  case Map.lookup connId cfg.banking.connections of
                    Nothing -> expectationFailure "Added connection not present in config"
                    Just conn -> do
                      conn.name `shouldBe` "My monobank"
                      conn.provider `shouldBe` Monobank
                      conn.enabled `shouldBe` True
                      conn.tokenHint `shouldBe` "1234"
                      conn.accountMap `shouldBe` Map.empty
                      -- The stored token is ciphertext that round-trips.
                      ring <- runRIO env (view bankingKeyRingL)
                      decryptSecret ring conn.encryptedToken `shouldBe` Right plaintext

    it "exposes the plaintext token via getDecryptedConnectionToken" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "getconn@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId Monobank "C" "u_roundtrip" True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              tokResult <- runRIO env $ getDecryptedConnectionToken userId connId
              tokResult `shouldBe` Right "u_roundtrip"

-- -----------------------------------------------------------------------------
-- setBankConnectionAccountMap validates account ownership
-- -----------------------------------------------------------------------------

setBankConnectionAccountMapSpec :: Spec
setBankConnectionAccountMapSpec =
  describe "setBankConnectionAccountMap" $ do
    it "rejects a map targeting an account the user does not own" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "mapreject@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId Monobank "C" "u_tok" True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              foreignUuid <- UUIDv4.nextRandom
              let foreignAcc = unsafeAccountId foreignUuid
              result <-
                runRIO env
                  $ setBankConnectionAccountMap userId connId (Map.singleton "ext-1" foreignAcc)
              result `shouldSatisfy` isLeft

    it "accepts and persists a map targeting an owned account" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "mapok@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId Monobank "C" "u_tok" True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              maybeUser <- runDbIn env (getUser userId)
              ownedAcc <- case maybeUser of
                Nothing -> do
                  expectationFailure "User not found"
                  error "unreachable"
                Just ud -> pure ud.externalAccountId
              result <-
                runRIO env
                  $ setBankConnectionAccountMap userId connId (Map.singleton "ext-1" ownedAcc)
              result `shouldSatisfy` isRight

              maybeUser2 <- runDbIn env (getUser userId)
              case maybeUser2 of
                Nothing -> expectationFailure "User not found after map"
                Just ud -> do
                  maybeCfg <- getConfiguration env.configurationReadModel ud.configurationId
                  case maybeCfg of
                    Nothing -> expectationFailure "Configuration not found"
                    Just cfg ->
                      case Map.lookup connId cfg.banking.connections of
                        Nothing -> expectationFailure "Connection not found"
                        Just conn -> conn.accountMap `shouldBe` Map.singleton "ext-1" ownedAcc
