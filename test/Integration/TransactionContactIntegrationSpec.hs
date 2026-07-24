{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionContactIntegrationSpec
-- Description : End-to-end contact lifecycle for transactions.
--
-- Walks the full contact lifecycle through the service layer with
-- in-memory event stores and the transfer process manager enabled,
-- mirroring 'Integration.TransactionLabelsIntegrationSpec':
--
-- 1.  Create an income and an expense, each tagged with a distinct
--     contact; verify the read model surfaces @contactId@ for both.
-- 2.  Change the income's contact via 'setTransactionContact'; verify
--     the read model reflects the new contact, and that setting
--     'Nothing' clears it.
-- 3.  Amend the income transaction while carrying a new contact;
--     verify the read model reflects the amended contact once the
--     amendment saga completes and projects.
-- 4.  Attempt to remove a contact still referenced by a transaction
--     → 'ContactInUse'; after the transaction no longer references it,
--     removal succeeds.
--
-- Driving through the service layer (rather than HTTP) keeps the
-- integration focused on the cross-aggregate flow — the contacts
-- dictionary lives on the Configuration aggregate, the in-use guard on
-- the ConfigurationService, and the transaction's contact on the
-- Transaction read model.
module Integration.TransactionContactIntegrationSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TxRM
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    contactsDictKind,
    expenseCategoryDictKind,
    incomeCategoryDictKind,
    removeDictionaryEntry,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Set as Set
import Domain.Configuration.Dictionary (EntryRole (ItemRole))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    DictionaryEntryId,
    TransactionId,
    UserId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Commands (InitiateTransactionAmendment (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (createDefaultAccount, firstDictionaryEntry, registerUser)
import Testkit.Helpers (expenseSingletonAllocation, singletonAllocation)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

data Harness = Harness
  { harnessEnv :: !AppEnv,
    harnessUser :: !UserId,
    harnessAccount :: !AccountId,
    harnessIncomeCategory :: !DictionaryEntryId,
    harnessExpenseCategory :: !DictionaryEntryId
  }

setupHarness :: Text -> IO Harness
setupHarness email = do
  env <- createTestAppEnvWithProcessManager
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  accId <- createDefaultAccount env uid "Wallet"
  incomeCategoryId <- firstDictionaryEntry env uid incomeCategoryDictKind
  expenseCategoryId <- firstDictionaryEntry env uid expenseCategoryDictKind
  pure
    Harness
      { harnessEnv = env,
        harnessUser = uid,
        harnessAccount = accId,
        harnessIncomeCategory = incomeCategoryId,
        harnessExpenseCategory = expenseCategoryId
      }

addContact :: Harness -> Text -> IO DictionaryEntryId
addContact h name = do
  res <- runAppM h.harnessEnv $ addDictionaryEntry h.harnessUser contactsDictKind (unsafeEntryName name) ItemRole Nothing
  unwrap ("addDictionaryEntry " <> show name) res

seedIncome :: Harness -> Maybe DictionaryEntryId -> IO TransactionId
seedIncome h contact = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateIncome
        h.harnessUser
        h.harnessAccount
        (unsafeMoney Core.USD 25)
        (singletonAllocation h.harnessIncomeCategory (unsafeMoney Core.USD 25))
        Set.empty
        "Paycheck"
        Nothing
        Nothing
        contact
  case res of
    Left err -> fail $ "initiateIncome failed: " <> show err
    Right (txId, _) -> pure txId

seedExpense :: Harness -> Maybe DictionaryEntryId -> IO TransactionId
seedExpense h contact = do
  res <-
    runAppM h.harnessEnv
      $ TransactionService.initiateExpense
        h.harnessUser
        h.harnessAccount
        (unsafeMoney Core.USD 25)
        (expenseSingletonAllocation h.harnessExpenseCategory (unsafeMoney Core.USD 25))
        Set.empty
        "Groceries"
        Nothing
        Nothing
        contact
  case res of
    Left err -> fail $ "initiateExpense failed: " <> show err
    Right (txId, _) -> pure txId

getTransaction :: Harness -> TransactionId -> IO TransactionData
getTransaction h txId = do
  mTd <- runDbIn h.harnessEnv (TxRM.getTransaction txId)
  case mTd of
    Nothing -> fail $ "transaction not found: " <> show txId
    Just td -> pure td

getTransactionContact :: Harness -> TransactionId -> IO (Maybe DictionaryEntryId)
getTransactionContact h txId = (.contactId) <$> getTransaction h txId

setContact :: Harness -> TransactionId -> Maybe DictionaryEntryId -> IO ()
setContact h txId contact = do
  res <- runAppM h.harnessEnv $ TransactionService.setTransactionContact h.harnessUser txId contact
  case res of
    Left err -> fail $ "setTransactionContact failed: " <> show err
    Right _ -> pure ()

-- | Amend a transaction's contact only, keeping its accounts / amounts /
-- allocations exactly as they currently stand in the read model.
amendContact :: Harness -> TransactionId -> Maybe DictionaryEntryId -> IO ()
amendContact h txId contact = do
  td <- getTransaction h txId
  let amend =
        InitiateTransactionAmendment
          { transactionId = txId,
            newSourceAccountId = td.sourceAccountId,
            newTargetAccountId = td.targetAccountId,
            newSourceAmount = td.sourceAmount,
            newTargetAmount = td.targetAmount,
            newExchangeRate = td.exchangeRate,
            newAllocations = Just (singletonAllocation h.harnessIncomeCategory td.targetAmount),
            newTransactionType = td.transactionType,
            contactId = contact,
            by = h.harnessUser
          }
  res <- runAppM h.harnessEnv $ TransactionService.amendTransaction h.harnessUser txId amend
  case res of
    Left err -> fail $ "amendTransaction failed: " <> show err
    Right _ -> pure ()

unwrap :: String -> Either DomainError a -> IO a
unwrap ctx = \case
  Left err -> fail $ ctx <> " failed: " <> show err
  Right v -> pure v

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / TransactionContact" $ do
  it "walks the full contact lifecycle end-to-end" $ do
    h <- setupHarness "contact-lifecycle@test.com"

    -- Step 1: create an income and an expense, each with a distinct
    -- contact; the read model should surface each one.
    alice <- addContact h "Alice"
    bob <- addContact h "Bob"
    incomeTx <- seedIncome h (Just alice)
    expenseTx <- seedExpense h (Just bob)
    getTransactionContact h incomeTx >>= (`shouldBe` Just alice)
    getTransactionContact h expenseTx >>= (`shouldBe` Just bob)

    -- Step 2: change the income's contact via setTransactionContact;
    -- then clear it.
    setContact h incomeTx (Just bob)
    getTransactionContact h incomeTx >>= (`shouldBe` Just bob)
    setContact h incomeTx Nothing
    getTransactionContact h incomeTx >>= (`shouldBe` Nothing)

    -- Step 3: amend the income transaction while carrying a new
    -- contact; once the amendment saga completes and projects, the
    -- read model should reflect it.
    amendContact h incomeTx (Just alice)
    getTransactionContact h incomeTx >>= (`shouldBe` Just alice)

    -- Step 4: removing "alice" must fail while the income transaction
    -- still references her.
    deleteBlocked <-
      runAppM h.harnessEnv
        $ removeDictionaryEntry h.harnessUser contactsDictKind alice
    case deleteBlocked of
      Left (ContactInUse _ n) -> n `shouldBe` 1
      other -> expectationFailure $ "expected ContactInUse 1, got: " <> show other

    -- Once the income no longer references "alice" (cleared), the
    -- delete succeeds.
    setContact h incomeTx Nothing
    deleteAllowed <-
      runAppM h.harnessEnv
        $ removeDictionaryEntry h.harnessUser contactsDictKind alice
    deleteAllowed `shouldSatisfy` isRight
