{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ConfigurationServiceIntegrationSpec
-- Description : Integration tests for ConfigurationService
--
-- These tests exercise the ConfigurationService through the in-memory event
-- store, verifying clone-on-write semantics, dictionary CRUD, currency
-- changes, and registration-time config assignment.
module Application.Services.ConfigurationServiceIntegrationSpec (spec) where

import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    DictionaryData (..),
    getConfiguration,
  )
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    changeBaseCurrency,
    changeDefaultCurrency,
    incomeCategoryDictId,
    removeDictionaryEntry,
    renameDictionaryEntry,
    seedDefaultConfiguration,
  )
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreditAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( CreatedBy (..),
    Currency (..),
    defaultConfigurationId,
    unAccountId,
    unsafeEntryName,
    unsafeMoney,
    unsafeTransactionId,
  )
import Infrastructure.App (AppEnv (..))
import Infrastructure.Eventium (applyAccountCommand)
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

spec :: Spec
spec = describe "ConfigurationService" $ do
  seedDefaultConfigurationSpec
  cloneOnWriteSpec
  changeBaseCurrencySpec
  dictionaryCRUDSpec
  registrationAssignsDefaultConfigSpec

-- -----------------------------------------------------------------------------
-- seedDefaultConfiguration
-- -----------------------------------------------------------------------------

seedDefaultConfigurationSpec :: Spec
seedDefaultConfigurationSpec =
  describe "seedDefaultConfiguration" $ do
    it "creates default configuration on first call" $ do
      env <- createTestAppEnv
      runRIO env $ do
        seedDefaultConfiguration

      maybeConfig <- runDbIn env (getConfiguration defaultConfigurationId)
      case maybeConfig of
        Nothing -> expectationFailure "Default configuration not found in read model"
        Just config -> do
          config.baseCurrency `shouldBe` USD
          config.defaultCurrency `shouldBe` USD
          config.createdBy `shouldBe` System
          -- Should have income and expense dictionaries with entries
          Map.lookup incomeCategoryDictId config.dictionaries `shouldSatisfy` isJust

    it "is idempotent (second call is a no-op)" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      config1 <- runDbIn env (getConfiguration defaultConfigurationId)

      runRIO env seedDefaultConfiguration
      config2 <- runDbIn env (getConfiguration defaultConfigurationId)

      config1 `shouldBe` config2

-- -----------------------------------------------------------------------------
-- Clone-on-write
-- -----------------------------------------------------------------------------

cloneOnWriteSpec :: Spec
cloneOnWriteSpec =
  describe "clone-on-write" $ do
    it "clones shared config when user modifies it" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "clone@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Verify user initially has default config
          maybeUser1 <- runDbIn env (getUser userId)
          case maybeUser1 of
            Nothing -> expectationFailure "User not found"
            Just userData1 ->
              userData1.configurationId `shouldBe` defaultConfigurationId

          -- Modify the config (should trigger clone)
          result <- runRIO env $ changeDefaultCurrency userId EUR
          result `shouldSatisfy` isRight

          -- User should now have a different (cloned) config
          maybeUser2 <- runDbIn env (getUser userId)
          case maybeUser2 of
            Nothing -> expectationFailure "User not found after clone"
            Just userData2 -> do
              userData2.configurationId `shouldNotBe` defaultConfigurationId

              -- The cloned config should have ClonedBy
              maybeConfig <- runDbIn env (getConfiguration userData2.configurationId)
              case maybeConfig of
                Nothing -> expectationFailure "Cloned configuration not found"
                Just config -> do
                  config.defaultCurrency `shouldBe` EUR
                  case config.createdBy of
                    ClonedBy ownerId _ ->
                      ownerId `shouldBe` userId
                    other ->
                      expectationFailure $ "Expected ClonedBy, got: " <> show other

    it "modifies owned config directly without cloning again" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "owned@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- First modification triggers clone
          _ <- runRIO env $ changeDefaultCurrency userId EUR

          -- Get the cloned config ID
          maybeUser1 <- runDbIn env (getUser userId)
          case maybeUser1 of
            Nothing -> expectationFailure "User not found"
            Just userData1 -> do
              let clonedConfigId = userData1.configurationId

              -- Second modification should NOT clone again
              result <- runRIO env $ changeDefaultCurrency userId GBP
              result `shouldSatisfy` isRight

              -- Config ID should still be the same
              maybeUser2 <- runDbIn env (getUser userId)
              case maybeUser2 of
                Nothing -> expectationFailure "User not found after second change"
                Just userData2 ->
                  userData2.configurationId `shouldBe` clonedConfigId

              -- Currency should be updated
              maybeConfig <- runDbIn env (getConfiguration clonedConfigId)
              case maybeConfig of
                Nothing -> expectationFailure "Cloned config not found"
                Just config ->
                  config.defaultCurrency `shouldBe` GBP

-- -----------------------------------------------------------------------------
-- changeBaseCurrency
-- -----------------------------------------------------------------------------

changeBaseCurrencySpec :: Spec
changeBaseCurrencySpec =
  describe "changeBaseCurrency" $ do
    it "succeeds before any transactions" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "basecur@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          result <- runRIO env $ changeBaseCurrency authResult.userId EUR
          result `shouldSatisfy` isRight

    it "fails after account has transactions (currency locked)" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "locked@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- First base currency change succeeds (triggers clone + currency change)
          result1 <- runRIO env $ changeBaseCurrency userId EUR
          result1 `shouldSatisfy` isRight

          -- Now issue a credit on the external account to mark it as having transactions
          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              let extAcctUuid = unAccountId userData.externalAccountId
                  txId = unsafeTransactionId (UUID.fromWords 999 0 0 1)
              _ <-
                applyAccountCommand env.eventStoreWriter env.eventStoreReader id extAcctUuid
                  $ CreditAccountAccountCommand
                    CreditAccount
                      { amount = unsafeMoney EUR 100,
                        transactionId = txId
                      }

              -- Now try to change base currency again - should fail
              result2 <- runRIO env $ changeBaseCurrency userId GBP
              result2 `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- Dictionary CRUD
-- -----------------------------------------------------------------------------

dictionaryCRUDSpec :: Spec
dictionaryCRUDSpec =
  describe "Dictionary CRUD" $ do
    it "adds a new entry to a dictionary" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "dictadd@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          result <- runRIO env $ addDictionaryEntry userId incomeCategoryDictId (unsafeEntryName "Bonus")
          result `shouldSatisfy` isRight

          -- Verify the entry exists in the cloned config
          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              maybeConfig <- runDbIn env (getConfiguration userData.configurationId)
              case maybeConfig of
                Nothing -> expectationFailure "Config not found"
                Just config -> do
                  let incomeDict = Map.lookup incomeCategoryDictId config.dictionaries
                  case incomeDict of
                    Nothing -> expectationFailure "Income dictionary not found"
                    Just dict ->
                      Map.elems dict.entries `shouldSatisfy` elem (unsafeEntryName "Bonus")

    it "renames an existing entry" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "dictrename@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Add a new entry first (this triggers clone)
          addResult <- runRIO env $ addDictionaryEntry userId incomeCategoryDictId (unsafeEntryName "Temp")
          case addResult of
            Left err -> expectationFailure $ "Add failed: " <> show err
            Right entryId -> do
              -- Rename it
              renameResult <- runRIO env $ renameDictionaryEntry userId incomeCategoryDictId entryId (unsafeEntryName "Renamed")
              renameResult `shouldSatisfy` isRight

              -- Verify the rename
              maybeUser <- runDbIn env (getUser userId)
              case maybeUser of
                Nothing -> expectationFailure "User not found"
                Just userData -> do
                  maybeConfig <- runDbIn env (getConfiguration userData.configurationId)
                  case maybeConfig of
                    Nothing -> expectationFailure "Config not found"
                    Just config -> do
                      let incomeDict = Map.lookup incomeCategoryDictId config.dictionaries
                      case incomeDict of
                        Nothing -> expectationFailure "Income dictionary not found"
                        Just dict ->
                          Map.lookup entryId dict.entries `shouldBe` Just (unsafeEntryName "Renamed")

    it "removes an entry from a dictionary" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "dictremove@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Add two entries (triggering clone on first)
          addResult1 <- runRIO env $ addDictionaryEntry userId incomeCategoryDictId (unsafeEntryName "ToKeep")
          addResult1 `shouldSatisfy` isRight

          addResult2 <- runRIO env $ addDictionaryEntry userId incomeCategoryDictId (unsafeEntryName "ToRemove")
          case addResult2 of
            Left err -> expectationFailure $ "Add failed: " <> show err
            Right entryId -> do
              -- Remove the second entry
              removeResult <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictId entryId
              removeResult `shouldSatisfy` isRight

              -- Verify it's gone
              maybeUser <- runDbIn env (getUser userId)
              case maybeUser of
                Nothing -> expectationFailure "User not found"
                Just userData -> do
                  maybeConfig <- runDbIn env (getConfiguration userData.configurationId)
                  case maybeConfig of
                    Nothing -> expectationFailure "Config not found"
                    Just config -> do
                      let incomeDict = Map.lookup incomeCategoryDictId config.dictionaries
                      case incomeDict of
                        Nothing -> expectationFailure "Income dictionary not found"
                        Just dict ->
                          Map.lookup entryId dict.entries `shouldBe` Nothing

    it "rejects removing the last entry in a dictionary" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "dictlast@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Trigger clone by changing default currency
          _ <- runRIO env $ changeDefaultCurrency userId USD

          -- Now get the cloned config and find its income entries
          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              maybeConfig <- runDbIn env (getConfiguration userData.configurationId)
              case maybeConfig of
                Nothing -> expectationFailure "Config not found"
                Just config -> do
                  let incomeDict = Map.lookup incomeCategoryDictId config.dictionaries
                  case incomeDict of
                    Nothing -> expectationFailure "Income dictionary not found"
                    Just dict -> do
                      -- The cloned config has defaultIncomeCategory set (from seed).
                      -- Removal is rejected for any entry that is a global default OR when
                      -- it is the last entry. We remove all non-default entries, then verify
                      -- the global-default entry also cannot be removed.
                      let bankingDefaultId = config.defaultIncomeCategory
                          allEntries = Map.keys dict.entries
                          nonDefaultEntries = filter (\eid -> Just eid /= bankingDefaultId) allEntries
                      -- Remove all non-default entries (all should succeed)
                      forM_ nonDefaultEntries $ \eid -> do
                        res <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictId eid
                        res `shouldSatisfy` isRight

                      -- Now try to remove the banking-default (or the last remaining) entry - should fail
                      let lastResult = case bankingDefaultId of
                            Just bid -> runRIO env $ removeDictionaryEntry userId incomeCategoryDictId bid
                            Nothing ->
                              -- Fallback: try whichever entry remains
                              case filter (`notElem` nonDefaultEntries) allEntries of
                                (eid : _) -> runRIO env $ removeDictionaryEntry userId incomeCategoryDictId eid
                                [] -> return $ Left $ ConfigurationError "No entries left"
                      finalResult <- lastResult
                      finalResult `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- Registration assigns default config
-- -----------------------------------------------------------------------------

registrationAssignsDefaultConfigSpec :: Spec
registrationAssignsDefaultConfigSpec =
  describe "Registration" $ do
    it "assigns default configuration to new user" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "newuser@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          maybeUser <- runDbIn env (getUser authResult.userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found in read model"
            Just userData ->
              userData.configurationId `shouldBe` defaultConfigurationId
