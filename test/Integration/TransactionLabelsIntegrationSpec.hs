{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionLabelsIntegrationSpec
-- Description : End-to-end labels lifecycle for transactions.
--
-- Walks the full spec §6 "labels" flow through the service layer with
-- in-memory event stores and the transfer process manager enabled:
--
-- 1.  Add two labels (@kids@, @school@) to the user's configuration;
--     verify the read model reports them under the @labels@ dictionary.
-- 2.  Create an expense tagged with @kids@; verify the label is attached
--     to the resulting transaction read-model entry.
-- 3.  Rename @kids@ to @children@; create a second expense tagged with
--     the renamed entry.
-- 4.  Replace the first expense's labels with @{children, school}@;
--     verify the read model picks up the new set.
-- 5.  Attempt to delete @children@ while two transactions reference it
--     → 'LabelInUse' with @usageCount = 2@.
-- 6.  Clear both expenses' label sets; delete @children@ → success.
--
-- Driving through the service layer (rather than HTTP) keeps the
-- integration focused on the cross-aggregate flow — labels dictionary
-- lives on the Configuration aggregate, the in-use guard on the
-- ConfigurationService, and the label set on the Transaction read
-- model.
module Integration.TransactionLabelsIntegrationSpec (spec) where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TxRM
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    expenseCategoryDictId,
    labelsDictId,
    removeDictionaryEntry,
    renameDictionaryEntry,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    DictionaryEntryId,
    TransactionId,
    UserId,
    unEntryName,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import qualified RIO.List as List
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, firstDictionaryEntry, registerUser)
import Testkit.Helpers (expenseSingletonAllocation)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

data Harness = Harness
  { harnessEnv :: !AppEnv,
    harnessUser :: !UserId,
    harnessAccount :: !AccountId,
    harnessExpenseCategory :: !DictionaryEntryId
  }

setupHarness :: Text -> IO Harness
setupHarness email = do
  env <- createTestAppEnvWithProcessManager
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  accId <- createDefaultAccount env uid "Wallet"
  categoryId <- firstDictionaryEntry env uid expenseCategoryDictId
  pure
    Harness
      { harnessEnv = env,
        harnessUser = uid,
        harnessAccount = accId,
        harnessExpenseCategory = categoryId
      }

addLabel :: Harness -> Text -> IO DictionaryEntryId
addLabel h name = do
  res <- runAppM h.harnessEnv $ addDictionaryEntry h.harnessUser labelsDictId (unsafeEntryName name)
  unwrap ("addDictionaryEntry " <> show name) res

userConfigLabelNames :: Harness -> IO [Text]
userConfigLabelNames h = do
  mUser <- runDbIn h.harnessEnv (getUser h.harnessUser)
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- runDbIn h.harnessEnv (ConfigRM.getConfiguration ud.configurationId)
      case mCfg of
        Nothing -> fail "configuration not found"
        Just cfg ->
          case Map.lookup labelsDictId cfg.dictionaries of
            Nothing -> pure []
            Just dict -> pure $ map unEntryName (Map.elems dict.entries)

seedExpense :: Harness -> Set DictionaryEntryId -> IO TransactionId
seedExpense h labels = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateExpense
        h.harnessUser
        h.harnessAccount
        (unsafeMoney Core.USD 25)
        (expenseSingletonAllocation h.harnessExpenseCategory (unsafeMoney Core.USD 25))
        labels
        "Groceries"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "initiateExpense failed: " <> show err
    Right (txId, _) -> pure txId

getTransactionLabels :: Harness -> TransactionId -> IO (Set DictionaryEntryId)
getTransactionLabels h txId = do
  mTd <- runDbIn h.harnessEnv (TxRM.getTransaction txId)
  case mTd of
    Nothing -> fail $ "transaction not found: " <> show txId
    Just td -> pure td.labels

setLabels ::
  Harness ->
  TransactionId ->
  Set DictionaryEntryId ->
  IO ()
setLabels h txId labels = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.setTransactionLabels h.harnessUser txId labels
  case res of
    Left err -> fail $ "setTransactionLabels failed: " <> show err
    Right _ -> pure ()

unwrap :: String -> Either DomainError a -> IO a
unwrap ctx = \case
  Left err -> fail $ ctx <> " failed: " <> show err
  Right v -> pure v

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransactionLabels" $ do
  it "walks the full label lifecycle end-to-end" $ do
    h <- setupHarness "labels-lifecycle@test.com"

    -- Step 1: add two labels, assert the configuration read model reflects them.
    kidsId <- addLabel h "kids"
    schoolId <- addLabel h "school"
    names <- userConfigLabelNames h
    List.sort names `shouldBe` List.sort ["kids", "school"]

    -- Step 2: tag a first expense with {kids}; read-model labels should
    -- contain kids.
    expenseA <- seedExpense h (Set.singleton kidsId)
    labelsA <- getTransactionLabels h expenseA
    labelsA `shouldBe` Set.singleton kidsId

    -- Step 3: rename kids to children; the entry id is stable across a
    -- rename so the first expense now implicitly references "children".
    runAppM
      h.harnessEnv
      ( renameDictionaryEntry
          h.harnessUser
          labelsDictId
          kidsId
          (unsafeEntryName "children")
      )
      >>= unwrap "renameDictionaryEntry"
    namesAfterRename <- userConfigLabelNames h
    List.sort namesAfterRename `shouldBe` List.sort ["children", "school"]

    -- Step 3 (cont): second expense tagged with the same (renamed) id.
    expenseB <- seedExpense h (Set.singleton kidsId)
    labelsB <- getTransactionLabels h expenseB
    labelsB `shouldBe` Set.singleton kidsId

    -- Step 4: re-set the first expense to {children, school}.
    setLabels h expenseA (Set.fromList [kidsId, schoolId])
    labelsAUpdated <- getTransactionLabels h expenseA
    labelsAUpdated `shouldBe` Set.fromList [kidsId, schoolId]

    -- Step 5: deleting children must fail while two transactions still
    -- reference it.
    deleteBlocked <-
      runAppM h.harnessEnv
        $ removeDictionaryEntry h.harnessUser labelsDictId kidsId
    case deleteBlocked of
      Left (LabelInUse _ n) -> n `shouldBe` 2
      other -> expectationFailure $ "expected LabelInUse 2, got: " <> show other

    -- Step 6: clear both expenses, then the delete succeeds.
    setLabels h expenseA Set.empty
    setLabels h expenseB Set.empty
    deleteAllowed <-
      runAppM h.harnessEnv
        $ removeDictionaryEntry h.harnessUser labelsDictId kidsId
    deleteAllowed `shouldSatisfy` isRight
