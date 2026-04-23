{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ConfigurationServiceInUseSpec
-- Description : The service-layer in-use guard on removeDictionaryEntry.
--
-- Verifies that ConfigurationService.removeDictionaryEntry refuses to
-- delete a dictionary entry that any transaction still references —
-- either via the labels set or via the categorised TransferType.
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
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( DictionaryEntryId,
    TransferType (..),
    UserId,
    unsafeAccountId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.CommandHandler (TransactionCommand (..))
import Domain.Transaction.Commands (InitiateTransfer (..))
import Infrastructure.App (AppEnv (..))
import Infrastructure.Eventium (applyTransactionCommand)
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnv)

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
  mUser <- getUser env.userReadModel userId
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- getConfiguration env.configurationReadModel ud.configurationId
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

-- | Write a TransferInitiated event through the in-memory event store.
-- Uses fresh random UUIDs for source / target accounts — the in-use
-- check only needs the category / labels to be visible on the read
-- model, not for the accounts to be real.
seedTransaction ::
  AppEnv ->
  UserId ->
  TransferType ->
  Set DictionaryEntryId ->
  IO ()
seedTransaction env userId tt labels = do
  txUuid <- UUID.nextRandom
  srcUuid <- UUID.nextRandom
  tgtUuid <- UUID.nextRandom
  let cmd =
        InitiateTransferTransactionCommand
          InitiateTransfer
            { sourceAccountId = unsafeAccountId srcUuid,
              targetAccountId = unsafeAccountId tgtUuid,
              sourceAmount = unsafeMoney Core.USD 100,
              targetAmount = unsafeMoney Core.USD 100,
              exchangeRate = Nothing,
              description = "seed for in-use check",
              initiatedBy = userId,
              transferType = tt,
              externalTransactionId = Nothing,
              labels = labels
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
    seedTransaction env userId (Income categoryId) Set.empty

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
    seedTransaction env userId (Expense categoryId) (Set.singleton labelId)
    seedTransaction env userId (Expense categoryId) (Set.singleton labelId)

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
