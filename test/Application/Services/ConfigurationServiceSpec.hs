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
    getConnectionFileImport,
    getDecryptedConnectionCredential,
    seedDefaultConfiguration,
    setBankConnectionAccountMap,
  )
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUIDv4
import Domain.Banking.Types (ProviderCredential (..), unsafeBankConnectionId, unsafeBankProviderId, unsafeExternalAccountId)
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
    ConfigurationDefaults (..),
  )
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( CreatedBy (..),
    Currency (..),
    defaultConfigurationId,
    unConfigurationId,
    unsafeAccountId,
  )
import Infrastructure.App
  ( AppEnv (..),
    BankingEnv (..),
    HasEventStore (..),
    bankingKeyRingL,
  )
import Infrastructure.Banking.Provider (FileImportCapability (..), StatementFormat (..))
import Infrastructure.Banking.Registry (registryFromList)
import Infrastructure.Crypto.SecretBox (decryptSecret, encryptSecret)
import Infrastructure.Eventium (applyConfigurationCommand)
import RIO
import Test.Hspec
import Testkit.AppEnv (newStubControls, stubFileOnlyDescriptor, stubPullDescriptor)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

spec :: Spec
spec = describe "ConfigurationService banking" $ do
  seedBankingDefaultsSpec
  cloneBankingDefaultsSpec
  addBankConnectionSpec
  setBankConnectionAccountMapSpec
  getConnectionFileImportSpec

-- -----------------------------------------------------------------------------
-- seedDefaultConfiguration populates banking defaults
-- -----------------------------------------------------------------------------

seedBankingDefaultsSpec :: Spec
seedBankingDefaultsSpec =
  describe "seedDefaultConfiguration" $ do
    it "populates banking defaults after seeding dictionaries" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      maybeConfig <- runDbIn env (getConfiguration defaultConfigurationId)
      case maybeConfig of
        Nothing -> expectationFailure "Default configuration not found in read model"
        Just cfg -> do
          let ConfigurationDefaults {incomeCategory = mInc, expenseCategory = mExp} = cfg.defaults
          mInc `shouldBe` Just income.other.entryId
          mExp `shouldBe` Just expense.other.entryId
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

              maybeClonedCfg <- runDbIn env (getConfiguration userData.configurationId)
              case maybeClonedCfg of
                Nothing -> expectationFailure "Cloned configuration not found in read model"
                Just clonedCfg -> do
                  -- Banking defaults must have been carried over from the source
                  let ConfigurationDefaults {incomeCategory = mInc, expenseCategory = mExp} = clonedCfg.defaults
                  mInc `shouldBe` Just income.other.entryId
                  mExp `shouldBe` Just expense.other.entryId
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
                  provider = unsafeBankProviderId "monobank",
                  name = "Seeded",
                  encryptedSecret = Just enc,
                  secretHint = Just "oken",
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
              maybeCfg <- runDbIn env (getConfiguration userData.configurationId)
              case maybeCfg of
                Nothing -> expectationFailure "Cloned configuration not found"
                Just cfg ->
                  case Map.lookup connId cfg.banking.connections of
                    Nothing -> expectationFailure "Connection dropped by clone-on-write"
                    Just conn -> do
                      conn.name `shouldBe` "Seeded"
                      conn.enabled `shouldBe` True
                      conn.secretHint `shouldBe` Just "oken"
                      (decryptSecret ring <$> conn.encryptedSecret) `shouldBe` Just (Right "u_defaulttoken")

-- -----------------------------------------------------------------------------
-- addBankConnection encrypts the credential and stores connection metadata
-- -----------------------------------------------------------------------------

addBankConnectionSpec :: Spec
addBankConnectionSpec =
  describe "addBankConnection" $ do
    it "stores an enabled connection with a secret hint and encrypted secret" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "addconn@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          let plaintext = "u_supersecrettoken1234"
          addResult <- runRIO env $ addBankConnection userId (unsafeBankProviderId "monobank") "My monobank" (Just (StaticSecret plaintext)) True
          connId <- case addResult of
            Left err -> do
              expectationFailure $ "addBankConnection failed: " <> show err
              error "unreachable"
            Right cid -> pure cid

          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              maybeCfg <- runDbIn env (getConfiguration userData.configurationId)
              case maybeCfg of
                Nothing -> expectationFailure "Configuration not found"
                Just cfg ->
                  case Map.lookup connId cfg.banking.connections of
                    Nothing -> expectationFailure "Added connection not present in config"
                    Just conn -> do
                      conn.name `shouldBe` "My monobank"
                      conn.provider `shouldBe` unsafeBankProviderId "monobank"
                      conn.enabled `shouldBe` True
                      conn.secretHint `shouldBe` Just "1234"
                      conn.accountMap `shouldBe` Map.empty
                      -- The stored credential is ciphertext (JSON-encoded) that
                      -- round-trips through decrypt+decode.
                      credResult <- runRIO env $ getDecryptedConnectionCredential userId connId
                      credResult `shouldBe` Right (StaticSecret plaintext)

    it "exposes the stored credential via getDecryptedConnectionCredential" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "getconn@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId (unsafeBankProviderId "monobank") "C" (Just (StaticSecret "u_roundtrip")) True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              credResult <- runRIO env $ getDecryptedConnectionCredential userId connId
              credResult `shouldBe` Right (StaticSecret "u_roundtrip")

    it "returns a BankingError when the decrypted plaintext fails to decode as a credential" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "corrupt-cred@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          ring <- runRIO env (view bankingKeyRingL)
          enc <- encryptSecret ring "not-valid-credential-json"
          let connUuid = UUID.fromWords 9 9 9 9
              connId = unsafeBankConnectionId connUuid
              addCmd =
                AddBankConnectionConfigurationCommand
                  AddBankConnection
                    { connectionId = connId,
                      provider = unsafeBankProviderId "monobank",
                      name = "Corrupt",
                      encryptedSecret = Just enc,
                      secretHint = Just "hint",
                      enabled = True
                    }
          _ <-
            runRIO env $ do
              writer <- view eventStoreWriterL
              reader <- view eventStoreReaderL
              liftIO $ applyConfigurationCommand writer reader id (unConfigurationId defaultConfigurationId) addCmd
          result <- runRIO env $ getDecryptedConnectionCredential userId connId
          case result of
            Left (BankingError _) -> pure ()
            Left otherErr -> expectationFailure $ "expected BankingError, got: " <> show otherErr
            Right _ -> expectationFailure "expected Left BankingError, got Right"

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
          addResult <- runRIO env $ addBankConnection userId (unsafeBankProviderId "monobank") "C" (Just (StaticSecret "u_tok")) True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              foreignUuid <- UUIDv4.nextRandom
              let foreignAcc = unsafeAccountId foreignUuid
              result <-
                runRIO env
                  $ setBankConnectionAccountMap userId connId (Map.singleton (unsafeExternalAccountId "ext-1") foreignAcc)
              result `shouldSatisfy` isLeft

    it "accepts and persists a map targeting an owned account" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "mapok@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId (unsafeBankProviderId "monobank") "C" (Just (StaticSecret "u_tok")) True
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
                  $ setBankConnectionAccountMap userId connId (Map.singleton (unsafeExternalAccountId "ext-1") ownedAcc)
              result `shouldSatisfy` isRight

              maybeUser2 <- runDbIn env (getUser userId)
              case maybeUser2 of
                Nothing -> expectationFailure "User not found after map"
                Just ud -> do
                  maybeCfg <- runDbIn env (getConfiguration ud.configurationId)
                  case maybeCfg of
                    Nothing -> expectationFailure "Configuration not found"
                    Just cfg ->
                      case Map.lookup connId cfg.banking.connections of
                        Nothing -> expectationFailure "Connection not found"
                        Just conn -> conn.accountMap `shouldBe` Map.singleton (unsafeExternalAccountId "ext-1") ownedAcc

-- -----------------------------------------------------------------------------
-- getConnectionFileImport resolves a connection's file-import transport
-- -----------------------------------------------------------------------------

-- | Build a test env whose bank provider registry carries both stub
-- descriptors ('Testkit.AppEnv.stubPullDescriptor' keyed @"monobank"@ and
-- 'Testkit.AppEnv.stubFileOnlyDescriptor' keyed @"privatbank"@), so a single
-- env exercises both transport shapes.
mkFileImportTestEnv :: IO AppEnv
mkFileImportTestEnv = do
  env <- createTestAppEnv
  controls <- newStubControls env
  let reg = registryFromList [stubPullDescriptor controls, stubFileOnlyDescriptor]
  pure env {bankingEnv = env.bankingEnv {bankProviderRegistry = reg}}

getConnectionFileImportSpec :: Spec
getConnectionFileImportSpec =
  describe "getConnectionFileImport" $ do
    it "resolves a file-only provider's connection to its classify+FileImportCapability" $ do
      env <- mkFileImportTestEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "fileimport-ok@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId (unsafeBankProviderId "privatbank") "Privat" Nothing True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              result <- runRIO env $ getConnectionFileImport userId connId
              case result of
                Left err -> expectationFailure $ "getConnectionFileImport failed: " <> show err
                Right (_classify, cap) ->
                  Map.member StatementCsv cap.parsers `shouldBe` True

    it "rejects a pull-only provider's connection with a no-file-transport BankingError" $ do
      env <- mkFileImportTestEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "fileimport-nopull@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          addResult <- runRIO env $ addBankConnection userId (unsafeBankProviderId "monobank") "Mono" Nothing True
          case addResult of
            Left err -> expectationFailure $ "addBankConnection failed: " <> show err
            Right connId -> do
              result <- runRIO env $ getConnectionFileImport userId connId
              case result of
                Left (BankingError _) -> pure ()
                Left otherErr -> expectationFailure $ "expected BankingError, got: " <> show otherErr
                Right _ -> expectationFailure "expected Left BankingError, got Right"

    it "returns BankConnectionNotFound for an unknown connection id" $ do
      env <- mkFileImportTestEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "fileimport-unknown@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          unknownUuid <- UUIDv4.nextRandom
          result <- runRIO env $ getConnectionFileImport userId (unsafeBankConnectionId unknownUuid)
          case result of
            Left BankConnectionNotFound -> pure ()
            Left otherErr -> expectationFailure $ "expected BankConnectionNotFound, got: " <> show otherErr
            Right _ -> expectationFailure "expected Left BankConnectionNotFound, got Right"
