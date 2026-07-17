{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ConfigurationServiceInUseSpec
-- Description : The service-layer in-use guard on removeDictionaryEntry.
--
-- Verifies that ConfigurationService.removeDictionaryEntry refuses to
-- delete a dictionary entry that any transaction still references —
-- either via the labels set or via the categorised TransactionType.
--
-- Also verifies the regression: cancelled transactions must NOT count as
-- "in use", so deletion succeeds when the only referencing transaction has
-- been cancelled (Task 9 / Task 16 of the cancel-transaction feature).
module Application.Services.ConfigurationServiceInUseSpec (spec) where

import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    DictionaryData (..),
    getConfiguration,
  )
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    expenseCategoryDictId,
    incomeCategoryDictId,
    labelsDictId,
    removeDictionaryEntry,
    seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( cancelTransaction,
    initiateTransfer,
  )
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( DictionaryEntryId,
    TransactionType (..),
    UserId,
    unsafeAccountId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.CommandHandler (TransactionCommand (..))
import Domain.Transaction.Commands (InitiateTransaction (..))
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Eventium (applyTransactionCommand)
import RIO
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount)
import Testkit.Helpers (singletonExpense, singletonIncome)
import Testkit.InMemoryEventStore (createTestAppEnv, createTestAppEnvWithProcessManager, runDbIn)

-- -----------------------------------------------------------------------------
-- Harness helpers
-- -----------------------------------------------------------------------------

-- | Register a user against a seeded environment and return the user id.
registerUser :: AppEnv -> Text -> IO UserId
registerUser env email = do
  res <- runRIO env $ register email "password123"
  case res of
    Left err -> fail $ "register failed: " <> show err
    Right auth -> pure auth.userId

-- | Look up one category id belonging to the given dictionary for the user.
firstEntryId :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
firstEntryId env userId dictName = do
  mUser <- runDbIn env (getUser userId)
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- runDbIn env (getConfiguration ud.configurationId)
      case mCfg of
        Nothing -> fail "configuration not found"
        Just cfg ->
          case Map.lookup (toDictId dictName) cfg.dictionaries of
            Nothing -> fail $ "dictionary " <> show dictName <> " not found"
            Just dict ->
              case Map.keys dict.entries of
                [] -> fail $ "dictionary " <> show dictName <> " is empty"
                (eid : _) -> pure eid
  where
    toDictId "income-category" = incomeCategoryDictId
    toDictId "expense-category" = expenseCategoryDictId
    toDictId "labels" = labelsDictId
    toDictId other = error $ "unknown dict: " <> show other

-- | Write a TransactionPostingInitiated event through the in-memory event store.
-- Uses fresh random UUIDs for source / target accounts — the in-use
-- check only needs the category / labels to be visible on the read
-- model, not for the accounts to be real.
seedTransaction ::
  AppEnv ->
  UserId ->
  TransactionType ->
  Set DictionaryEntryId ->
  IO ()
seedTransaction env userId tt labels = do
  txUuid <- UUID.nextRandom
  srcUuid <- UUID.nextRandom
  tgtUuid <- UUID.nextRandom
  let cmd =
        InitiateTransactionTransactionCommand
          InitiateTransaction
            { sourceAccountId = unsafeAccountId srcUuid,
              targetAccountId = unsafeAccountId tgtUuid,
              sourceAmount = unsafeMoney Core.USD 100,
              targetAmount = unsafeMoney Core.USD 100,
              exchangeRate = Nothing,
              description = "seed for in-use check",
              initiatedBy = userId,
              at = UTCTime (fromGregorian 2026 4 1) 0,
              transactionType = tt,
              importInfo = Nothing,
              labels = labels,
              relation = Nothing
            }
  res <- applyTransactionCommand env.eventStoreWriter env.eventStoreReader id txUuid cmd
  case res of
    Left err -> fail $ "applyTransactionCommand failed: " <> show err
    Right _ -> pure ()

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "ConfigurationService / in-use deletion guard" $ do
  it "refuses to delete a category still referenced by an Income transaction" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "inuse-cat-income@test.com"

    -- Trigger clone-on-write by adding any entry; the user then owns the config.
    _ <- runRIO env $ addDictionaryEntry userId incomeCategoryDictId (unsafeEntryName "Spark")

    categoryId <- firstEntryId env userId "income-category"
    seedTransaction env userId (singletonIncome categoryId (unsafeMoney Core.USD 100)) Set.empty

    result <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictId categoryId
    case result of
      Left (CategoryInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected CategoryInUse, got: " <> show other

  it "refuses to delete a label still referenced by a transaction" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "inuse-label@test.com"

    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictId (unsafeEntryName "kids")
    labelId <- case addLabel of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    -- Two transactions using the same label.
    categoryId <- firstEntryId env userId "expense-category"
    seedTransaction env userId (singletonExpense categoryId (unsafeMoney Core.USD 100)) (Set.singleton labelId)
    seedTransaction env userId (singletonExpense categoryId (unsafeMoney Core.USD 100)) (Set.singleton labelId)

    result <- runRIO env $ removeDictionaryEntry userId labelsDictId labelId
    case result of
      Left (LabelInUse _ n) -> n `shouldBe` 2
      other -> expectationFailure $ "expected LabelInUse with count 2, got: " <> show other

  it "allows deleting an unreferenced label" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "unused-label@test.com"

    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictId (unsafeEntryName "solo")
    labelId <- case addLabel of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    result <- runRIO env $ removeDictionaryEntry userId labelsDictId labelId
    result `shouldSatisfy` isRight

  -- \| An Adjustment carries no category, so it must never contribute to the
  -- category in-use count. This locks the report-exclusion contract for
  -- 'TransactionType = Adjustment' end-to-end: the in-use guard powers
  -- category-deletion enforcement, which is the same code path any future
  -- income/expense aggregator would walk through.
  it "Adjustment transactions do not count towards CategoryInUse" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "inuse-cat-adjustment@test.com"

    -- Clone-on-write the configuration so the user owns it.
    _ <- runRIO env $ addDictionaryEntry userId incomeCategoryDictId (unsafeEntryName "Spark")

    categoryId <- firstEntryId env userId "income-category"
    -- One real Income reference + several Adjustments that should be invisible
    -- to the category in-use scan.
    seedTransaction env userId (singletonIncome categoryId (unsafeMoney Core.USD 100)) Set.empty
    seedTransaction env userId Adjustment Set.empty
    seedTransaction env userId Adjustment Set.empty
    seedTransaction env userId Adjustment Set.empty

    result <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictId categoryId
    case result of
      Left (CategoryInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected CategoryInUse with count 1, got: " <> show other

  -- Regression: Task 9 added 'td.status /= Cancelled' to
  -- 'findReferencingTransactions'. This test verifies that a label referenced
  -- only by a cancelled transaction is treated as unused and can be deleted.
  it "allows deleting a label referenced only by a cancelled transaction" $ do
    -- Full saga pipeline required: TransactionPostingManager + TransactionCancellationManager
    -- must run synchronously so the Cancelled status is reflected in the read
    -- model before we attempt deletion.
    env <- createTestAppEnvWithProcessManager
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "cancelled-label-deletion@test.com"

    -- Add a label to the user's dictionary (clone-on-write).
    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictId (unsafeEntryName "holiday")
    labelId <- case addLabel of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    -- Two accounts are required to initiate an internal transfer.
    src <- createDefaultAccount env userId "Source"
    tgt <- createDefaultAccount env userId "Target"

    -- Initiate a transfer that carries the label, then cancel it.
    txResult <-
      runAppM env
        $ initiateTransfer
          userId
          src
          tgt
          (unsafeMoney Core.USD 50)
          (Set.singleton labelId)
          "holiday spending"
          Nothing
          Nothing
          Nothing
    (txId, _td) <- case txResult of
      Left err -> fail $ "initiateTransfer failed: " <> show err
      Right r -> pure r

    cancelResult <- runAppM env $ cancelTransaction userId txId
    case cancelResult of
      Left err -> fail $ "cancelTransaction failed: " <> show err
      Right _ -> pure ()

    -- The label must now be deletable because the only referencing transaction
    -- has been cancelled.
    result <- runRIO env $ removeDictionaryEntry userId labelsDictId labelId
    result `shouldSatisfy` isRight
