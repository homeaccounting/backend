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
  ( changeDefaultCurrency,
    seedDefaultConfiguration,
  )
import Domain.Configuration.Defaults
  ( DefaultEntry (entryId),
    ExpenseDefaults (other),
    IncomeDefaults (other),
    defaultMccExpenseCategoryMap,
    expense,
    income,
  )
import Domain.Configuration.Projection (BankingConfiguration (..))
import Domain.Core.Types
  ( CreatedBy (..),
    Currency (..),
    defaultConfigurationId,
  )
import Infrastructure.App (AppEnv (..))
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnv)

spec :: Spec
spec = describe "ConfigurationService banking" $ do
  seedBankingDefaultsSpec
  cloneBankingDefaultsSpec

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
          cfg.banking.defaultIncomeCategory
            `shouldBe` Just income.other.entryId
          cfg.banking.defaultExpenseCategory
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
          maybeUser <- getUser env.userReadModel userId
          case maybeUser of
            Nothing -> expectationFailure "User not found after clone"
            Just userData -> do
              userData.configurationId `shouldNotBe` defaultConfigurationId

              maybeClonedCfg <- getConfiguration env.configurationReadModel userData.configurationId
              case maybeClonedCfg of
                Nothing -> expectationFailure "Cloned configuration not found in read model"
                Just clonedCfg -> do
                  -- Banking defaults must have been carried over from the source
                  clonedCfg.banking.defaultIncomeCategory
                    `shouldBe` Just income.other.entryId
                  clonedCfg.banking.defaultExpenseCategory
                    `shouldBe` Just expense.other.entryId
                  clonedCfg.banking.mccExpenseCategoryMap
                    `shouldBe` defaultMccExpenseCategoryMap

                  -- Confirm it is a ClonedBy config (not System)
                  case clonedCfg.createdBy of
                    ClonedBy ownerId _ -> ownerId `shouldBe` userId
                    other -> expectationFailure $ "Expected ClonedBy, got: " <> show other
