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
-- Also verifies that a cancelled transaction still counts as "in use" —
-- cancelled transactions remain retrievable via the API and must keep their
-- referenced dictionary entries resolvable — while a failed transaction
-- (which never posted) does not.
module Application.Services.ConfigurationServiceInUseSpec (spec) where

import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    dictionaryItems,
    getConfiguration,
  )
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    contactsDictKind,
    expenseCategoryDictKind,
    incomeCategoryDictKind,
    labelsDictKind,
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
import Domain.Configuration.Dictionary (EntryRole (ItemRole))
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
import Domain.Transaction.Commands (InitiateTransactionPosting (..))
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
              case dictionaryItems dict of
                [] -> fail $ "dictionary " <> show dictName <> " is empty"
                ((eid, _) : _) -> pure eid
  where
    toDictId "income-category" = incomeCategoryDictKind
    toDictId "expense-category" = expenseCategoryDictKind
    toDictId "labels" = labelsDictKind
    toDictId other = error $ "unknown dict: " <> show other

-- | Write a TransactionPostingInitiated event through the in-memory event store.
-- Uses fresh random UUIDs for source / target accounts — the in-use
-- check only needs the category / labels / contact to be visible on the read
-- model, not for the accounts to be real.
seedTransaction ::
  AppEnv ->
  UserId ->
  TransactionType ->
  Set DictionaryEntryId ->
  Maybe DictionaryEntryId ->
  IO ()
seedTransaction env userId tt labels contact = do
  txUuid <- UUID.nextRandom
  srcUuid <- UUID.nextRandom
  tgtUuid <- UUID.nextRandom
  let cmd =
        InitiateTransactionPostingTransactionCommand
          InitiateTransactionPosting
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
              contactId = contact,
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
    _ <- runRIO env $ addDictionaryEntry userId incomeCategoryDictKind (unsafeEntryName "Spark") ItemRole Nothing

    categoryId <- firstEntryId env userId "income-category"
    seedTransaction env userId (singletonIncome categoryId (unsafeMoney Core.USD 100)) Set.empty Nothing

    result <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictKind categoryId
    case result of
      Left (CategoryInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected CategoryInUse, got: " <> show other

  it "refuses to delete a label still referenced by a transaction" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "inuse-label@test.com"

    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictKind (unsafeEntryName "kids") ItemRole Nothing
    labelId <- case addLabel of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    -- Two transactions using the same label.
    categoryId <- firstEntryId env userId "expense-category"
    seedTransaction env userId (singletonExpense categoryId (unsafeMoney Core.USD 100)) (Set.singleton labelId) Nothing
    seedTransaction env userId (singletonExpense categoryId (unsafeMoney Core.USD 100)) (Set.singleton labelId) Nothing

    result <- runRIO env $ removeDictionaryEntry userId labelsDictKind labelId
    case result of
      Left (LabelInUse _ n) -> n `shouldBe` 2
      other -> expectationFailure $ "expected LabelInUse with count 2, got: " <> show other

  it "allows deleting an unreferenced label" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "unused-label@test.com"

    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictKind (unsafeEntryName "solo") ItemRole Nothing
    labelId <- case addLabel of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    result <- runRIO env $ removeDictionaryEntry userId labelsDictKind labelId
    result `shouldSatisfy` isRight

  it "refuses to delete a contact still referenced by an Expense transaction" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "inuse-contact@test.com"

    addContact <- runRIO env $ addDictionaryEntry userId contactsDictKind (unsafeEntryName "Landlord") ItemRole Nothing
    contactId <- case addContact of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    categoryId <- firstEntryId env userId "expense-category"
    seedTransaction env userId (singletonExpense categoryId (unsafeMoney Core.USD 100)) Set.empty (Just contactId)

    result <- runRIO env $ removeDictionaryEntry userId contactsDictKind contactId
    case result of
      Left (ContactInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected ContactInUse, got: " <> show other

  it "allows deleting an unreferenced contact" $ do
    env <- createTestAppEnv
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "unused-contact@test.com"

    addContact <- runRIO env $ addDictionaryEntry userId contactsDictKind (unsafeEntryName "Solo") ItemRole Nothing
    contactId <- case addContact of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    result <- runRIO env $ removeDictionaryEntry userId contactsDictKind contactId
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
    _ <- runRIO env $ addDictionaryEntry userId incomeCategoryDictKind (unsafeEntryName "Spark") ItemRole Nothing

    categoryId <- firstEntryId env userId "income-category"
    -- One real Income reference + several Adjustments that should be invisible
    -- to the category in-use scan.
    seedTransaction env userId (singletonIncome categoryId (unsafeMoney Core.USD 100)) Set.empty Nothing
    seedTransaction env userId Adjustment Set.empty Nothing
    seedTransaction env userId Adjustment Set.empty Nothing
    seedTransaction env userId Adjustment Set.empty Nothing

    result <- runRIO env $ removeDictionaryEntry userId incomeCategoryDictKind categoryId
    case result of
      Left (CategoryInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected CategoryInUse with count 1, got: " <> show other

  -- Cancelled transactions remain retrievable via the API (and their labels /
  -- categories / contacts still resolve on them), so a label referenced only
  -- by a cancelled transaction must still count as in-use.
  it "refuses to delete a label referenced only by a cancelled transaction" $ do
    -- Full saga pipeline required: TransactionPostingManager + TransactionCancellationManager
    -- must run synchronously so the Cancelled status is reflected in the read
    -- model before we attempt deletion.
    env <- createTestAppEnvWithProcessManager
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "cancelled-label-deletion@test.com"

    -- Add a label to the user's dictionary (clone-on-write).
    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictKind (unsafeEntryName "holiday") ItemRole Nothing
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

    -- The label must remain undeletable: the cancelled transaction is still
    -- retrievable via the API and still resolves this label.
    result <- runRIO env $ removeDictionaryEntry userId labelsDictKind labelId
    case result of
      Left (LabelInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected LabelInUse, got: " <> show other

  -- Failed transactions never posted, so a label referenced only by a failed
  -- transaction must not count as in-use.
  it "allows deleting a label referenced only by a failed transaction" $ do
    -- Full saga pipeline required so the balance-guard rejection propagates
    -- to a real Failed status in the read model before we attempt deletion.
    env <- createTestAppEnvWithProcessManager
    runRIO env seedDefaultConfiguration
    userId <- registerUser env "failed-label-deletion@test.com"

    addLabel <- runRIO env $ addDictionaryEntry userId labelsDictKind (unsafeEntryName "doomed") ItemRole Nothing
    labelId <- case addLabel of
      Left err -> fail $ "addDictionaryEntry failed: " <> show err
      Right eid -> pure eid

    -- The seed account has no overdraft configured, so a transfer larger than
    -- its balance is rejected by the balance guard and the saga fails the
    -- transaction.
    src <- createDefaultAccount env userId "Source"
    tgt <- createDefaultAccount env userId "Target"

    txResult <-
      runAppM env
        $ initiateTransfer
          userId
          src
          tgt
          (unsafeMoney Core.USD 999999)
          (Set.singleton labelId)
          "doomed transfer"
          Nothing
          Nothing
          Nothing
    case txResult of
      Left err -> fail $ "initiateTransfer failed: " <> show err
      Right _ -> pure ()

    -- The label must be deletable: the only referencing transaction failed to
    -- post.
    result <- runRIO env $ removeDictionaryEntry userId labelsDictKind labelId
    result `shouldSatisfy` isRight
