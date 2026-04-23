{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionCategoryIntegrationSpec
-- Description : End-to-end category-edit flows for transactions.
--
-- Walks the spec §6 "category edit" cases through the service layer
-- with in-memory event stores and the transfer process manager enabled:
--
-- 1.  Create an income categorised as @Salary@; switch the category to
--     a newly-added @Freelance@ entry and verify the read model.
-- 2.  Create an internal transfer; attempt to change its category →
--     'CannotChangeCategoryOnInternalTransfer'.
-- 3.  Create an income and try to switch to a category id that is not
--     in the income-category dictionary → 'CategoryNotFound'.
--
-- Driving through the service layer keeps the integration test focused
-- on the cross-aggregate flow; the HTTP envelope is covered separately
-- by @Web.API.TransactionCategoryAPISpec@.
module Integration.TransactionCategoryIntegrationSpec (spec) where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TxRM
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    incomeCategoryDictId,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID4
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    DictionaryEntryId,
    TransactionId,
    TransferType (..),
    UserId,
    defaultCash,
    unEntryName,
    unsafeDictionaryEntryId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import qualified RIO.List as List
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

data Harness = Harness
  { harnessEnv :: !AppEnv,
    harnessUser :: !UserId,
    harnessAccount :: !AccountId,
    harnessSalaryCategory :: !DictionaryEntryId
  }

setupHarness :: Text -> IO Harness
setupHarness email = do
  env <- createTestAppEnvWithProcessManager
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  accId <- createRegularAccount env uid "Wallet"
  -- Use the first seeded income-category entry as the "starting"
  -- category instead of adding one. Adding a new entry here would
  -- race with any seed-default entry that happens to share the name.
  startingCategory <- firstIncomeCategory env uid
  pure
    Harness
      { harnessEnv = env,
        harnessUser = uid,
        harnessAccount = accId,
        harnessSalaryCategory = startingCategory
      }

firstIncomeCategory :: AppEnv -> UserId -> IO DictionaryEntryId
firstIncomeCategory env uid = do
  mUser <- getUser env.userReadModel uid
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- ConfigRM.getConfiguration env.configurationReadModel ud.configurationId
      case mCfg of
        Nothing -> fail "configuration not found"
        Just cfg ->
          case Map.lookup incomeCategoryDictId cfg.dictionaries of
            Nothing -> fail "income-category dictionary missing"
            Just dict ->
              case Map.keys dict.entries of
                (eid : _) -> pure eid
                [] -> fail "income-category dictionary is empty"

registerUser :: AppEnv -> Text -> IO UserId
registerUser env email = do
  res <- runAppM env $ register email "password123"
  case res of
    Left err -> fail $ "register failed: " <> show err
    Right auth -> pure auth.userId

createRegularAccount :: AppEnv -> UserId -> Text -> IO AccountId
createRegularAccount env uid accName = do
  res <-
    runAppM env
      $ createAccount
      $ CreateAccount
        { name = accName,
          initialBalance = unsafeMoney Core.USD 5000,
          createdBy = uid,
          accountType = Regular defaultCash,
          overdraftLimit = Nothing
        }
  case res of
    Left err -> fail $ "createAccount failed: " <> show err
    Right (aid, _) -> pure aid

seedIncome :: Harness -> DictionaryEntryId -> IO TransactionId
seedIncome h categoryId = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateIncome
        h.harnessUser
        h.harnessAccount
        (unsafeMoney Core.USD 100)
        categoryId
        Set.empty
        "Paycheck"
        Nothing
  case res of
    Left err -> fail $ "initiateIncome failed: " <> show err
    Right (txId, _) -> pure txId

seedInternalTransfer :: Harness -> IO TransactionId
seedInternalTransfer h = do
  other <- createRegularAccount h.harnessEnv h.harnessUser "Other"
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateInternalTransfer
        h.harnessUser
        h.harnessAccount
        other
        (unsafeMoney Core.USD 10)
        Set.empty
        "Move funds"
        Nothing
        Nothing
  case res of
    Left err -> fail $ "initiateInternalTransfer failed: " <> show err
    Right (txId, _) -> pure txId

getTransferType :: Harness -> TransactionId -> IO TransferType
getTransferType h txId = do
  mTd <- TxRM.getTransaction h.harnessEnv.transactionReadModel txId
  case mTd of
    Nothing -> fail $ "transaction not found: " <> show txId
    Just td -> pure td.transferType

incomeCategoryNames :: Harness -> IO [Text]
incomeCategoryNames h = do
  mUser <- getUser h.harnessEnv.userReadModel h.harnessUser
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      mCfg <- ConfigRM.getConfiguration h.harnessEnv.configurationReadModel ud.configurationId
      case mCfg of
        Nothing -> fail "configuration not found"
        Just cfg ->
          case Map.lookup incomeCategoryDictId cfg.dictionaries of
            Nothing -> pure []
            Just dict -> pure $ map unEntryName (Map.elems dict.entries)

unwrap :: String -> Either DomainError a -> IO a
unwrap ctx = \case
  Left err -> fail $ ctx <> " failed: " <> show err
  Right v -> pure v

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransactionCategoryEdit" $ do
  it "switches the category on a Completed Income transaction" $ do
    h <- setupHarness "category-edit-happy@test.com"
    -- Use a deliberately non-default name to avoid colliding with the
    -- seeded default entries.
    newCategoryId <-
      runAppM
        h.harnessEnv
        (addDictionaryEntry h.harnessUser incomeCategoryDictId (unsafeEntryName "Test-Freelance"))
        >>= unwrap "addDictionaryEntry Test-Freelance"
    names <- incomeCategoryNames h
    List.sort (filter (== "Test-Freelance") names) `shouldBe` ["Test-Freelance"]

    txId <- seedIncome h h.harnessSalaryCategory
    initial <- getTransferType h txId
    initial `shouldBe` Income h.harnessSalaryCategory

    result <-
      runAppM h.harnessEnv
        $ TransactionService.changeTransactionCategory h.harnessUser txId newCategoryId
    result `shouldSatisfy` isRight

    updated <- getTransferType h txId
    updated `shouldBe` Income newCategoryId

  it "refuses to change the category on an internal transfer" $ do
    h <- setupHarness "category-edit-internal@test.com"
    txId <- seedInternalTransfer h

    result <-
      runAppM h.harnessEnv
        $ TransactionService.changeTransactionCategory
          h.harnessUser
          txId
          h.harnessSalaryCategory
    case result of
      Left CannotChangeCategoryOnInternalTransfer -> pure ()
      other ->
        expectationFailure
          $ "expected CannotChangeCategoryOnInternalTransfer, got: "
          <> show other

  it "rejects an unknown category id with CategoryNotFound" $ do
    h <- setupHarness "category-edit-unknown@test.com"
    txId <- seedIncome h h.harnessSalaryCategory

    alien <- unsafeDictionaryEntryId <$> UUID4.nextRandom
    result <-
      runAppM h.harnessEnv
        $ TransactionService.changeTransactionCategory h.harnessUser txId alien
    case result of
      Left (CategoryNotFound _) -> pure ()
      other -> expectationFailure $ "expected CategoryNotFound, got: " <> show other
