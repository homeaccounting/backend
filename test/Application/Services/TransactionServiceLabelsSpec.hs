{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionServiceLabelsSpec
-- Description : Label validation and edit operations in TransactionService.
--
-- Covers the new label surface on the transaction-service layer:
--
--  * create endpoints validate the user-supplied label set against the
--    user's @labels@ dictionary;
--  * 'setTransactionLabels' and 'setTransactionAllocations' enforce
--    access, state, and dictionary membership before dispatching the
--    corresponding aggregate command;
--  * aggregate-level rejections (non-Completed state, internal-transfer
--    allocations edit) are translated into the public 'DomainError'
--    surface.
module Application.Services.TransactionServiceLabelsSpec (spec) where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.Transaction (TransactionData (..))
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    incomeCategoryDictId,
    labelsDictId,
    seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( initiateIncome,
    initiateTransfer,
    setTransactionAllocations,
    setTransactionLabels,
  )
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    DictionaryEntryId,
    UserId,
    defaultCash,
    unsafeDictionaryEntryId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Helpers (singletonAllocation, singletonIncome)
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
    runDbIn,
  )

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

-- | A fully-provisioned user: registered, configuration seeded + cloned,
-- one income category, two labels, and one Regular account usable as a
-- transfer endpoint.
data Fixture = Fixture
  { userId :: !UserId,
    regularAccountId :: !AccountId,
    labelA :: !DictionaryEntryId,
    labelB :: !DictionaryEntryId,
    incomeCategory :: !DictionaryEntryId
  }

-- | Register a user against a freshly-seeded env, add two labels and one
-- income category, and create a Regular account. Used by every test
-- that needs a working transaction endpoint.
setupFixture :: AppEnv -> Text -> IO Fixture
setupFixture env email = do
  seedDefault env
  uid <- registerUser env email
  addedLabelA <-
    expectEntry "addDictionaryEntry labelA"
      =<< runAppM env (addDictionaryEntry uid labelsDictId (unsafeEntryName "kids"))
  addedLabelB <-
    expectEntry "addDictionaryEntry labelB"
      =<< runAppM env (addDictionaryEntry uid labelsDictId (unsafeEntryName "school"))
  categoryId <- firstIncomeCategory env uid
  accId <- createDefaultAccount env uid "Wallet"
  pure
    Fixture
      { userId = uid,
        regularAccountId = accId,
        labelA = addedLabelA,
        labelB = addedLabelB,
        incomeCategory = categoryId
      }

seedDefault :: AppEnv -> IO ()
seedDefault env = runAppM env seedDefaultConfiguration

registerUser :: AppEnv -> Text -> IO UserId
registerUser env email = do
  res <- runAppM env $ register email "password123"
  case res of
    Left err -> fail $ "register failed: " <> show err
    Right auth -> pure auth.userId

-- | Look up the first entry id in the user's income-category dictionary.
-- The seeded default populates income-category with at least one entry.
firstIncomeCategory :: AppEnv -> UserId -> IO DictionaryEntryId
firstIncomeCategory env uid = do
  mUser <- runDbIn env (getUser uid)
  case mUser of
    Nothing -> fail "user not found"
    Just ud -> do
      cfg <- fetchCfg env ud
      case dictEntries cfg incomeCategoryDictId of
        (eid : _) -> pure eid
        [] -> fail "income-category dictionary is empty"
  where
    fetchCfg e ud =
      ConfigRM.getConfiguration
        e.configurationReadModel
        ud.configurationId
        >>= maybe (fail "config not found") pure
    dictEntries cfg dictId =
      case Map.lookup dictId cfg.dictionaries of
        Just d -> Map.keys d.entries
        Nothing -> []

createDefaultAccount :: AppEnv -> UserId -> Text -> IO AccountId
createDefaultAccount env uid accName = do
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

expectEntry ::
  String ->
  Either DomainError DictionaryEntryId ->
  IO DictionaryEntryId
expectEntry ctx = \case
  Left err -> fail $ ctx <> " failed: " <> show err
  Right eid -> pure eid

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService / labels" $ do
  describe "initiateIncome label validation" $ do
    it "attaches a valid label set to the new transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "income-label-ok@test.com"

      result <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 100)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 100))
            (Set.fromList [fx.labelA, fx.labelB])
            "Paycheck"
            Nothing
      case result of
        Right (_, td) ->
          td.labels `shouldBe` Set.fromList [fx.labelA, fx.labelB]
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects labels that are not in the user's dictionary" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "income-label-bad@test.com"

      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom
      result <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 50)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 50))
            (Set.singleton alien)
            "Paycheck"
            Nothing
      case result of
        Left (LabelNotFound _) -> pure ()
        other -> expectationFailure $ "expected LabelNotFound, got: " <> show other

  describe "setTransactionLabels" $ do
    it "replaces the label set on a Completed transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-labels-ok@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 25))
            (Set.singleton fx.labelA)
            "Initial"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      result <-
        runAppM env
          $ setTransactionLabels
            fx.userId
            txId
            (Set.singleton fx.labelB)
      case result of
        Right td -> td.labels `shouldBe` Set.singleton fx.labelB
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects edits while the transaction is still Pending" $ do
      -- No process manager wired: the Pending -> Completed saga never
      -- fires, so the transaction stays Pending and the aggregate-level
      -- guard kicks in.
      env <- createTestAppEnv
      fx <- setupFixture env "set-labels-pending@test.com"
      otherAccId <- createDefaultAccount env fx.userId "Other"

      create <-
        runAppM env
          $ initiateTransfer
            fx.userId
            fx.regularAccountId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Pending edit probe"
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      result <-
        runAppM env
          $ setTransactionLabels fx.userId txId (Set.singleton fx.labelA)
      case result of
        Left CannotEditUncompletedTransaction -> pure ()
        other ->
          expectationFailure
            $ "expected CannotEditUncompletedTransaction, got: "
            <> show other

    it "rejects an unknown label id before dispatching" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-labels-unknown@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom
      result <-
        runAppM env
          $ setTransactionLabels fx.userId txId (Set.singleton alien)
      case result of
        Left (LabelNotFound _) -> pure ()
        other -> expectationFailure $ "expected LabelNotFound, got: " <> show other

    it "denies edits from a user without Editor+ access on the transaction" $ do
      env <- createTestAppEnvWithProcessManager
      owner <- setupFixture env "owner@test.com"

      create <-
        runAppM env
          $ initiateIncome
            owner.userId
            owner.regularAccountId
            (unsafeMoney Core.USD 25)
            (singletonAllocation owner.incomeCategory (unsafeMoney Core.USD 25))
            Set.empty
            "Owner only"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      stranger <- registerUser env "stranger@test.com"
      result <-
        runAppM env
          $ setTransactionLabels stranger txId Set.empty
      case result of
        Left (AccountError _) -> pure ()
        other -> expectationFailure $ "expected AccountError, got: " <> show other

  describe "setTransactionAllocations" $ do
    it "updates the category on a Completed Income transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-alloc-income@test.com"

      -- A second income-category entry to switch to.
      bonusCategory <-
        expectEntry "addDictionaryEntry second category"
          =<< runAppM env (addDictionaryEntry fx.userId incomeCategoryDictId (unsafeEntryName "Bonus"))

      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 10)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 10))
            Set.empty
            "Paycheck"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      result <-
        runAppM env
          $ setTransactionAllocations
            fx.userId
            txId
            (singletonAllocation bonusCategory (unsafeMoney Core.USD 10))
      case result of
        Right td -> td.transactionType `shouldBe` singletonIncome bonusCategory (unsafeMoney Core.USD 10)
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "refuses to change the allocations on an internal transfer" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-alloc-internal@test.com"
      accB <- createDefaultAccount env fx.userId "Other"

      create <-
        runAppM env
          $ initiateTransfer
            fx.userId
            fx.regularAccountId
            accB
            (unsafeMoney Core.USD 10)
            Set.empty
            "Move funds"
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      result <-
        runAppM env
          $ setTransactionAllocations
            fx.userId
            txId
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 10))
      case result of
        Left CannotSetAllocationsOnUncategorisedTransaction -> pure ()
        other ->
          expectationFailure
            $ "expected CannotSetAllocationsOnUncategorisedTransaction, got: "
            <> show other

    it "rejects an unknown category id" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-alloc-unknown@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 10)
            (singletonAllocation fx.incomeCategory (unsafeMoney Core.USD 10))
            Set.empty
            "Paycheck"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom
      result <-
        runAppM env
          $ setTransactionAllocations
            fx.userId
            txId
            (singletonAllocation alien (unsafeMoney Core.USD 10))
      case result of
        Left (CategoryNotFound _) -> pure ()
        other -> expectationFailure $ "expected CategoryNotFound, got: " <> show other
