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
    DictionaryData,
    dictionaryEntriesParentFirst,
    dictionaryItems,
    getConfiguration,
  )
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    changeBaseCurrency,
    changeDefaultCurrency,
    expenseCategoryDictKind,
    incomeCategoryDictKind,
    removeDictionaryEntry,
    renameDictionaryEntry,
    seedDefaultConfiguration,
    setDefaultAccount,
    setDefaultSubtypeAccounts,
  )
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreditAccount (..))
import Domain.Configuration.Defaults
  ( DefaultEntry (entryId, entryName, parentId),
    ExpenseDefaults (household, housing),
    defaultExpenseCategories,
    defaultIncomeCategories,
    expense,
  )
import Domain.Configuration.Dictionary (EntryRole (..))
import Domain.Configuration.Projection (ConfigurationDefaults (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountSubtypeKind (..),
    CreatedBy (..),
    Currency (..),
    DictionaryEntryId,
    EntryName,
    defaultCash,
    defaultConfigurationId,
    unAccountId,
    unsafeEntryName,
    unsafeMoney,
    unsafeTransactionId,
  )
import Infrastructure.App (AppEnv (..))
import Infrastructure.Eventium (applyAccountCommand)
import RIO
import qualified RIO.List as List
import Test.Hspec
import Testkit.Fixtures (createAccount)
import Testkit.Helpers (mockAccountId)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

spec :: Spec
spec = describe "ConfigurationService" $ do
  seedDefaultConfigurationSpec
  cloneOnWriteSpec
  changeBaseCurrencySpec
  dictionaryCRUDSpec
  registrationAssignsDefaultConfigSpec
  defaultAccountsSpec

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
          Map.lookup incomeCategoryDictKind config.dictionaries `shouldSatisfy` isJust

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

    it "preserves the nested default category tree through a clone" $ do
      -- Regression: clone-on-write copies dictionary entries by walking the
      -- id-keyed entry map, whose UUID order can place a child before its
      -- parent (e.g. "Household" sorts before its "Housing" group). Copying in
      -- that raw order makes the parent-exists guard reject — and silently drop
      -- — the child. Every seeded default (with its parentId) must survive.
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "clonetree@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId
          -- Any mutation triggers clone-on-write off the System default.
          cloneResult <- runRIO env $ changeDefaultCurrency userId EUR
          cloneResult `shouldSatisfy` isRight

          maybeUser <- runDbIn env (getUser userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found after clone"
            Just userData -> do
              userData.configurationId `shouldNotBe` defaultConfigurationId
              maybeConfig <- runDbIn env (getConfiguration userData.configurationId)
              case maybeConfig of
                Nothing -> expectationFailure "Cloned config not found"
                Just config -> do
                  let expenseDict = Map.lookup expenseCategoryDictKind config.dictionaries
                      incomeDict = Map.lookup incomeCategoryDictKind config.dictionaries
                  case (expenseDict, incomeDict) of
                    (Just eDict, Just iDict) -> do
                      -- The full default forest round-trips: every default
                      -- entry is present with its parentId intact.
                      assertDefaultsCloned eDict defaultExpenseCategories
                      assertDefaultsCloned iDict defaultIncomeCategories
                      -- Focused child-before-parent case ("Household" id sorts
                      -- before its "Housing" group id under UUID order).
                      Map.lookup expense.housing.entryId (entryIndex eDict)
                        `shouldBe` Just (unsafeEntryName "Housing", GroupRole, Nothing)
                      Map.lookup expense.household.entryId (entryIndex eDict)
                        `shouldBe` Just (unsafeEntryName "Household", ItemRole, Just expense.housing.entryId)
                    _ -> expectationFailure "Cloned config missing category dictionaries"

-- | An id-keyed index of a dictionary tree's nodes: name, role, parent id.
-- Rebuilds the flat view the assertions below need from the materialised tree.
entryIndex :: DictionaryData -> Map DictionaryEntryId (EntryName, EntryRole, Maybe DictionaryEntryId)
entryIndex dict =
  Map.fromList
    [ (eid, (nm, role, parent))
    | (eid, nm, role, parent) <- dictionaryEntriesParentFirst dict
    ]

-- | Assert every default entry survived a clone into @dict@ with its parent
-- link intact.
assertDefaultsCloned :: DictionaryData -> [DefaultEntry] -> Expectation
assertDefaultsCloned dict = mapM_ check
  where
    check de = case Map.lookup de.entryId (entryIndex dict) of
      Nothing ->
        expectationFailure $ "cloned dictionary is missing default entry: " <> show de.entryName
      Just (_, _, clonedParent) ->
        clonedParent `shouldBe` de.parentId

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
          result <- runRIO env $ addDictionaryEntry userId incomeCategoryDictKind (unsafeEntryName "Bonus") ItemRole Nothing
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
                  let incomeDict = Map.lookup incomeCategoryDictKind config.dictionaries
                  case incomeDict of
                    Nothing -> expectationFailure "Income dictionary not found"
                    Just dict ->
                      map snd (dictionaryItems dict) `shouldSatisfy` elem (unsafeEntryName "Bonus")

    it "renames an existing entry" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "dictrename@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Add a new entry first (this triggers clone)
          addResult <- runRIO env $ addDictionaryEntry userId incomeCategoryDictKind (unsafeEntryName "Temp") ItemRole Nothing
          case addResult of
            Left err -> expectationFailure $ "Add failed: " <> show err
            Right entryId -> do
              -- Rename it
              renameResult <- runRIO env $ renameDictionaryEntry userId incomeCategoryDictKind entryId (unsafeEntryName "Renamed")
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
                      let incomeDict = Map.lookup incomeCategoryDictKind config.dictionaries
                      case incomeDict of
                        Nothing -> expectationFailure "Income dictionary not found"
                        Just dict ->
                          lookup entryId (dictionaryItems dict) `shouldBe` Just (unsafeEntryName "Renamed")

    it "removes an entry from a dictionary" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration

      regResult <- runRIO env $ register "dictremove@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let userId = authResult.userId

          -- Add two entries (triggering clone on first)
          addResult1 <- runRIO env $ addDictionaryEntry userId incomeCategoryDictKind (unsafeEntryName "ToKeep") ItemRole Nothing
          addResult1 `shouldSatisfy` isRight

          addResult2 <- runRIO env $ addDictionaryEntry userId incomeCategoryDictKind (unsafeEntryName "ToRemove") ItemRole Nothing
          case addResult2 of
            Left err -> expectationFailure $ "Add failed: " <> show err
            Right entryId -> do
              -- Remove the second entry
              removeResult <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictKind entryId
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
                      let incomeDict = Map.lookup incomeCategoryDictKind config.dictionaries
                      case incomeDict of
                        Nothing -> expectationFailure "Income dictionary not found"
                        Just dict ->
                          Map.lookup entryId (entryIndex dict) `shouldBe` Nothing

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
                  let incomeDict = Map.lookup incomeCategoryDictKind config.dictionaries
                  case incomeDict of
                    Nothing -> expectationFailure "Income dictionary not found"
                    Just dict -> do
                      -- The cloned config has defaultIncomeCategory set (from seed).
                      -- Removal is rejected for any entry that is a global default OR when
                      -- it is the last entry. We remove all non-default entries, then verify
                      -- the global-default entry also cannot be removed.
                      let ConfigurationDefaults {incomeCategory = bankingDefaultId} = config.defaults
                          idx = entryIndex dict
                          allEntries = Map.keys idx
                          -- Children must be removed before their parent groups
                          -- (a non-empty group rejects removal), so order the
                          -- removals deepest-first. Assumes the acyclic invariant;
                          -- the fuel bound (entry count) fails safe on a corrupt
                          -- cycle instead of looping forever.
                          entryCount = Map.size idx
                          depthOf = go entryCount (0 :: Int)
                          go 0 acc _ = acc + entryCount
                          go fuel acc eid = case Map.lookup eid idx >>= (\(_, _, p) -> p) of
                            Just parent -> go (fuel - 1) (acc + 1) parent
                            Nothing -> acc
                          nonDefaultEntries =
                            List.sortOn (negate . depthOf)
                              $ filter (\eid -> Just eid /= bankingDefaultId) allEntries
                      -- Remove all non-default entries (all should succeed)
                      forM_ nonDefaultEntries $ \eid -> do
                        res <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictKind eid
                        res `shouldSatisfy` isRight

                      -- Now try to remove the banking-default (or the last remaining) entry - should fail
                      let lastResult = case bankingDefaultId of
                            Just bid -> runRIO env $ removeDictionaryEntry userId incomeCategoryDictKind bid
                            Nothing ->
                              -- Fallback: try whichever entry remains
                              case filter (`notElem` nonDefaultEntries) allEntries of
                                (eid : _) -> runRIO env $ removeDictionaryEntry userId incomeCategoryDictKind eid
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

-- -----------------------------------------------------------------------------
-- Default accounts (global + per-subtype) with ownership validation
-- -----------------------------------------------------------------------------

defaultAccountsSpec :: Spec
defaultAccountsSpec =
  describe "default accounts" $ do
    it "rejects a default account the user does not own" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "defacct-reject@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          let bogus = mockAccountId (UUID.fromWords 9 9 9 9)
          result <- runRIO env $ setDefaultAccount authResult.userId bogus
          case result of
            Left (ValidationErr _) -> pure ()
            other -> expectationFailure $ "Expected ValidationErr, got: " <> show other

    it "sets an owned global default account and reflects it in the read model" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "defacct-ok@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          aid <- createAccount env authResult.userId "Wallet" defaultCash UAH 0
          result <- runRIO env $ setDefaultAccount authResult.userId aid
          result `shouldSatisfy` isRight
          maybeUser <- runDbIn env (getUser authResult.userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              maybeCfg <- runDbIn env (getConfiguration userData.configurationId)
              case maybeCfg of
                Nothing -> expectationFailure "Config not found"
                Just cfg -> do
                  let ConfigurationDefaults {account = mAcc} = cfg.defaults
                  mAcc `shouldBe` Just aid

    it "sets an owned per-subtype default account map and reflects it" $ do
      env <- createTestAppEnv
      runRIO env seedDefaultConfiguration
      regResult <- runRIO env $ register "defacct-sub@test.com" "password123"
      case regResult of
        Left err -> expectationFailure $ "Registration failed: " <> show err
        Right authResult -> do
          aid <- createAccount env authResult.userId "Cash" defaultCash UAH 0
          let m = Map.singleton CashKind aid
          result <- runRIO env $ setDefaultSubtypeAccounts authResult.userId m
          result `shouldSatisfy` isRight
          maybeUser <- runDbIn env (getUser authResult.userId)
          case maybeUser of
            Nothing -> expectationFailure "User not found"
            Just userData -> do
              maybeCfg <- runDbIn env (getConfiguration userData.configurationId)
              case maybeCfg of
                Nothing -> expectationFailure "Config not found"
                Just cfg -> do
                  let ConfigurationDefaults {subtypeAccounts = subs} = cfg.defaults
                  subs `shouldBe` m
