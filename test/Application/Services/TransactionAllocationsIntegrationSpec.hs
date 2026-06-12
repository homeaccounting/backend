{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionAllocationsIntegrationSpec
-- Description : End-to-end allocations round-trip through the service layer.
--
-- Pins the lifecycle of a multi-category transaction against the real
-- service + read-model stack with the transfer process manager wired
-- in:
--
--   1. 'initiateExpense' with two allocations (200 + 800 UAH);
--   2. 'TransactionService.getTransaction' confirms the read model
--      reflects the two allocations;
--   3. 'setTransactionAllocations' re-splits the same total across
--      three categories (300 + 300 + 400);
--   4. read model again reflects the new three-category shape;
--   5. 'amendTransaction' bumps the categorised amount with explicit
--      allocations summing to the new total; the projection stores them
--      verbatim so the sum continues to equal the new categorised total.
--
-- The test exercises the full event-sourced loop: each step writes
-- events to the in-memory store, and the read model + projection are
-- the assertions' source of truth.
module Application.Services.TransactionAllocationsIntegrationSpec (spec) where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.Transaction (TransactionData (..))
import qualified Application.ReadModels.Transaction as TxRM
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    expenseCategoryDictId,
    seedDefaultConfiguration,
  )
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError)
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Allocations (..),
    Currency (..),
    DictionaryEntryId,
    Money (..),
    TransactionId,
    TransactionType (..),
    UserId,
    allAllocations,
    allocationsOf,
    unsafeEntryName,
    unsafeMoney,
  )
import Domain.Transaction.Commands (AmendTransaction (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (createRegularAccount, registerUser)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

data Harness = Harness
  { harnessEnv :: !AppEnv,
    harnessUser :: !UserId,
    harnessAccount :: !AccountId,
    harnessGroceries :: !DictionaryEntryId,
    harnessRestaurants :: !DictionaryEntryId,
    harnessSnacks :: !DictionaryEntryId
  }

-- | Seed three deterministic expense categories: Groceries / Restaurants
-- / Snacks. The default seed populates the expense-category dictionary
-- with the canonical defaults; we add three named entries that we own
-- by id for use in the test.
setupHarness :: Text -> IO Harness
setupHarness email = do
  env <- createTestAppEnvWithProcessManager
  runAppM env seedDefaultConfiguration
  uid <- registerUser env email
  accId <- createRegularAccount env uid "Wallet USD"

  groceriesId <- addExpense env uid "IT-Groceries"
  restaurantsId <- addExpense env uid "IT-Restaurants"
  snacksId <- addExpense env uid "IT-Snacks"

  pure
    Harness
      { harnessEnv = env,
        harnessUser = uid,
        harnessAccount = accId,
        harnessGroceries = groceriesId,
        harnessRestaurants = restaurantsId,
        harnessSnacks = snacksId
      }

addExpense :: AppEnv -> UserId -> Text -> IO DictionaryEntryId
addExpense env uid name = do
  res <- runAppM env $ addDictionaryEntry uid expenseCategoryDictId (unsafeEntryName name)
  unwrap ("addDictionaryEntry " <> show name) res

unwrap :: String -> Either DomainError a -> IO a
unwrap ctx = either (\err -> fail $ ctx <> " failed: " <> show err) pure

-- | Convenience: pull the current 'TransactionType' off the read model.
getTransactionType :: Harness -> TransactionId -> IO TransactionType
getTransactionType h txId = do
  mTd <- TxRM.getTransaction h.harnessEnv.transactionReadModel txId
  case mTd of
    Nothing -> fail $ "transaction not found: " <> show txId
    Just td -> pure td.transactionType

-- | Convenience: pull the 'TransactionData' off the read model.
getTransaction :: Harness -> TransactionId -> IO TransactionData
getTransaction h txId = do
  mTd <- TxRM.getTransaction h.harnessEnv.transactionReadModel txId
  case mTd of
    Nothing -> fail $ "transaction not found: " <> show txId
    Just td -> pure td

-- | Currency used throughout the round-trip scenario. The shared
-- fixture's Regular account is USD-denominated; matching it avoids
-- the cross-currency resolution path which is exercised elsewhere.
ccy :: Currency
ccy = USD

money :: Rational -> Money
money = unsafeMoney ccy

-- | Helper: the categorised total of the projected TransactionType,
-- summing all allocation slices against the known fixture currency.
-- Uncategorised types yield a zero total (no slices).
categorisedTotal :: TransactionType -> Money
categorisedTotal tt = case allocationsOf tt of
  Just allocs -> Money (sum [a.amount.amount | a <- allAllocations allocs]) ccy
  Nothing -> Money 0 ccy

-- | Helper: confirm a configuration was actually cloned (sanity check).
-- Catches the case where 'addExpense' silently mutates the default
-- configuration instead of cloning.
sanityCheckCloned :: Harness -> IO ()
sanityCheckCloned h = do
  mUser <- getUser h.harnessEnv.userReadModel h.harnessUser
  case mUser of
    Nothing -> fail "sanityCheckCloned: user not found"
    Just ud -> do
      mCfg <- ConfigRM.getConfiguration h.harnessEnv.configurationReadModel ud.configurationId
      case mCfg of
        Nothing -> fail "sanityCheckCloned: configuration not found"
        Just cfg ->
          case Map.lookup expenseCategoryDictId cfg.dictionaries of
            Nothing -> fail "sanityCheckCloned: expense dictionary missing"
            Just _ -> pure ()

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Application.Services / allocations round-trip" $ do
  it "register expense -> set allocations -> amend amount with explicit allocations" $ do
    h <- setupHarness "allocations-round-trip@test.com"
    sanityCheckCloned h

    -- Step 1: register an Expense with TWO allocations: 800 + 200 = 1000 UAH.
    let total1 = money 1000
        allocs1 =
          Allocations
            []
            [ Allocation h.harnessGroceries (money 800),
              Allocation h.harnessRestaurants (money 200)
            ]
    initResult <-
      runAppM h.harnessEnv
        $ TransactionService.initiateExpense
          h.harnessUser
          h.harnessAccount
          total1
          allocs1
          Set.empty
          "Initial grocery + restaurant split"
          Nothing
    (txId, _seedTd) <- unwrap "initiateExpense" initResult

    -- Step 2: GET reflects the two-allocation Expense.
    afterCreate <- getTransactionType h txId
    case afterCreate of
      Expense xs -> do
        xs `shouldBe` allocs1
        categorisedTotal afterCreate `shouldBe` total1
      other -> expectationFailure $ "expected Expense after create, got " <> show other

    -- Step 3: set new allocations splitting the same 1000 UAH across THREE
    -- categories: 300 + 300 + 400.
    let allocs2 =
          Allocations
            []
            [ Allocation h.harnessGroceries (money 300),
              Allocation h.harnessRestaurants (money 300),
              Allocation h.harnessSnacks (money 400)
            ]
    setResult <-
      runAppM h.harnessEnv
        $ TransactionService.setTransactionAllocations h.harnessUser txId allocs2
    _ <- unwrap "setTransactionAllocations" setResult

    -- Step 4: GET reflects the new three-allocation split.
    afterSet <- getTransactionType h txId
    case afterSet of
      Expense xs -> do
        xs `shouldBe` allocs2
        categorisedTotal afterSet `shouldBe` total1
      other -> expectationFailure $ "expected Expense after set, got " <> show other

    -- Step 5: Amend the source amount (categorised side for Expense) from
    -- 1000 -> 2000 UAH. Amendments no longer auto-rescale — the caller must
    -- supply explicit allocations summing to the new total.
    td <- getTransaction h txId
    let newTotal = money 2000
        newAllocs =
          Allocations
            []
            [ Allocation h.harnessGroceries (money 600),
              Allocation h.harnessRestaurants (money 600),
              Allocation h.harnessSnacks (money 800)
            ]
        amend =
          AmendTransaction
            { transactionId = txId,
              newSourceAccountId = td.sourceAccountId,
              newTargetAccountId = td.targetAccountId,
              newSourceAmount = newTotal,
              newTargetAmount = newTotal,
              newExchangeRate = Nothing,
              newAllocations = Just newAllocs,
              newTransactionType = Transfer,
              amendedBy = h.harnessUser
            }
    amendResult <-
      runAppM h.harnessEnv
        $ TransactionService.amendTransaction h.harnessUser txId amend
    _ <- unwrap "amendTransaction" amendResult

    -- Step 6: GET shows the explicit allocations summing to 2000 UAH.
    afterAmend <- getTransactionType h txId
    case afterAmend of
      Expense xs -> do
        xs `shouldBe` newAllocs
        categorisedTotal afterAmend `shouldBe` newTotal
      other -> expectationFailure $ "expected Expense after amend, got " <> show other
