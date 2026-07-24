{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionServiceContactSpec
-- Description : Contact validation and edit operations in TransactionService.
--
-- Covers the contact surface on the transaction-service layer:
--
--  * 'validateContact' / 'guardNoContactOnTransfer' — the shared
--    validation primitives, mirroring 'validateLabels' for a single
--    optional id.
--  * create endpoints ('initiateIncome' / 'initiateExpense') validate
--    and record the user-supplied contact.
--  * 'setTransactionContact' enforces access, kind, and dictionary
--    membership before dispatching.
--  * 'amendTransaction' validates the amended contact and rejects one
--    on a Transfer/Adjustment-kind amendment.
--
-- The read model does not yet surface 'contactId' (a later task), so
-- these specs assert the recorded contact by reading it back off the
-- raw event stream.
module Application.Services.TransactionServiceContactSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    contactsDictKind,
    seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( amendTransaction,
    guardNoContactOnTransfer,
    initiateExpense,
    initiateIncome,
    initiateTransfer,
    setTransactionContact,
    validateContact,
  )
import qualified Data.Set as Set
import qualified Data.UUID.V4 as UUID
import Domain.Configuration.Dictionary (EntryRole (ItemRole))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( DictionaryEntryId,
    TransactionId,
    TransactionKind (..),
    unTransactionId,
    unsafeDictionaryEntryId,
    unsafeEntryName,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Models
  ( AccountingEvent (..),
    TransactionAmendmentCompleted (..),
    TransactionContactSet (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Commands (InitiateTransactionAmendment (..))
import Eventium (EventStoreReader (..), StreamEvent (..), allEvents)
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createDefaultAccount,
    expenseAllocs,
    incomeAllocs,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
  )

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

-- | A fully-provisioned user (via 'setupMetadataFixture': registered,
-- configuration seeded + cloned, income/expense categories, one Regular
-- account) plus two contact-dictionary entries.
data Fixture = Fixture
  { base :: !MetadataFixture,
    contactA :: !DictionaryEntryId,
    contactB :: !DictionaryEntryId
  }

setupFixture :: AppEnv -> Text -> IO Fixture
setupFixture env email = do
  runAppM env seedDefaultConfiguration
  base <- setupMetadataFixture env email
  addedContactA <-
    expectEntry "addDictionaryEntry contactA"
      =<< runAppM env (addDictionaryEntry base.userId contactsDictKind (unsafeEntryName "Alice") ItemRole Nothing)
  addedContactB <-
    expectEntry "addDictionaryEntry contactB"
      =<< runAppM env (addDictionaryEntry base.userId contactsDictKind (unsafeEntryName "Bob") ItemRole Nothing)
  pure Fixture {base = base, contactA = addedContactA, contactB = addedContactB}

expectEntry ::
  String ->
  Either DomainError DictionaryEntryId ->
  IO DictionaryEntryId
expectEntry ctx = \case
  Left err -> fail $ ctx <> " failed: " <> show err
  Right eid -> pure eid

-- | Every event recorded on a transaction's stream, oldest first.
streamEvents :: AppEnv -> TransactionId -> IO [AccountingEvent]
streamEvents env txId = do
  let EventStoreReader readRange = env.eventStoreReader
  events <- readRange (allEvents (unTransactionId txId))
  pure (map (.payload) events)

-- | The contact recorded by the 'TransactionPostingInitiated' event on a
-- stream (there is always exactly one — creation is a single event).
postingInitiatedContact :: [AccountingEvent] -> Maybe (Maybe DictionaryEntryId)
postingInitiatedContact evts =
  listToMaybe
    [c | TransactionPostingInitiatedEvent TransactionPostingInitiated {contactId = c} <- evts]

-- | The contact recorded by the most-recent 'TransactionContactSet' event
-- on a stream.
lastContactSet :: [AccountingEvent] -> Maybe (Maybe DictionaryEntryId)
lastContactSet evts =
  listToMaybe
    ( reverse
        [c | TransactionContactSetEvent TransactionContactSet {contactId = c} <- evts]
    )

-- | The contact recorded by the most-recent 'TransactionAmendmentCompleted'
-- event on a stream.
lastAmendmentContact :: [AccountingEvent] -> Maybe (Maybe DictionaryEntryId)
lastAmendmentContact evts =
  listToMaybe
    ( reverse
        [c | TransactionAmendmentCompletedEvent TransactionAmendmentCompleted {contactId = c} <- evts]
    )

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService / contacts" $ do
  describe "validateContact" $ do
    it "accepts Nothing without touching the dictionary" $ do
      env <- createTestAppEnv
      fx <- setupFixture env "validate-contact-nothing@test.com"
      result <- runAppM env (validateContact fx.base.userId Nothing)
      result `shouldBe` Right ()

    it "accepts a known assignable contact id" $ do
      env <- createTestAppEnv
      fx <- setupFixture env "validate-contact-known@test.com"
      result <- runAppM env (validateContact fx.base.userId (Just fx.contactA))
      result `shouldBe` Right ()

    it "rejects an unknown contact id with ContactNotFound" $ do
      env <- createTestAppEnv
      fx <- setupFixture env "validate-contact-unknown@test.com"
      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom
      result <- runAppM env (validateContact fx.base.userId (Just alien))
      case result of
        Left (ContactNotFound _) -> pure ()
        other -> expectationFailure $ "expected ContactNotFound, got: " <> show other

  describe "guardNoContactOnTransfer" $ do
    it "allows no contact on a transfer" $ do
      env <- createTestAppEnv
      result <- runAppM env (guardNoContactOnTransfer TransferKind Nothing)
      result `shouldBe` Right ()

    it "allows a contact on an income transaction" $ do
      env <- createTestAppEnv
      fx <- setupFixture env "guard-income@test.com"
      result <- runAppM env (guardNoContactOnTransfer IncomeKind (Just fx.contactA))
      result `shouldBe` Right ()

    it "rejects a contact on a transfer with ContactNotAllowedOnTransfer" $ do
      env <- createTestAppEnv
      fx <- setupFixture env "guard-transfer@test.com"
      result <- runAppM env (guardNoContactOnTransfer TransferKind (Just fx.contactA))
      result `shouldBe` Left ContactNotAllowedOnTransfer

    it "rejects a contact on an adjustment with ContactNotAllowedOnTransfer" $ do
      env <- createTestAppEnv
      fx <- setupFixture env "guard-adjustment@test.com"
      result <- runAppM env (guardNoContactOnTransfer AdjustmentKind (Just fx.contactA))
      result `shouldBe` Left ContactNotAllowedOnTransfer

  describe "initiateIncome contact validation" $ do
    it "attaches a valid contact to the new transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "income-contact-ok@test.com"

      result <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 100)
            (incomeAllocs fx.base (unsafeMoney Core.USD 100))
            Set.empty
            "Paycheck"
            Nothing
            Nothing
            (Just fx.contactA)
      case result of
        Right (txId, _) -> do
          evts <- streamEvents env txId
          postingInitiatedContact evts `shouldBe` Just (Just fx.contactA)
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects an unknown contact id before dispatching" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "income-contact-bad@test.com"
      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom

      result <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 50)
            (incomeAllocs fx.base (unsafeMoney Core.USD 50))
            Set.empty
            "Paycheck"
            Nothing
            Nothing
            (Just alien)
      case result of
        Left (ContactNotFound _) -> pure ()
        other -> expectationFailure $ "expected ContactNotFound, got: " <> show other

  describe "initiateExpense contact validation" $ do
    it "attaches a valid contact to the new transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "expense-contact-ok@test.com"

      result <-
        runAppM env
          $ initiateExpense
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 40)
            (expenseAllocs fx.base (unsafeMoney Core.USD 40))
            Set.empty
            "Groceries"
            Nothing
            Nothing
            (Just fx.contactB)
      case result of
        Right (txId, _) -> do
          evts <- streamEvents env txId
          postingInitiatedContact evts `shouldBe` Just (Just fx.contactB)
        Left err -> expectationFailure $ "expected Right, got: " <> show err

  describe "setTransactionContact" $ do
    it "sets the contact on a Completed income transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-contact-ok@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 25)
            (incomeAllocs fx.base (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      result <- runAppM env $ setTransactionContact fx.base.userId txId (Just fx.contactA)
      case result of
        Right _ -> do
          evts <- streamEvents env txId
          lastContactSet evts `shouldBe` Just (Just fx.contactA)
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "clears the contact when given Nothing" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-contact-clear@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 25)
            (incomeAllocs fx.base (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
            Nothing
            (Just fx.contactA)
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      result <- runAppM env $ setTransactionContact fx.base.userId txId Nothing
      case result of
        Right _ -> do
          evts <- streamEvents env txId
          lastContactSet evts `shouldBe` Just Nothing
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects an unknown contact id before dispatching" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-contact-unknown@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 25)
            (incomeAllocs fx.base (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom
      result <- runAppM env $ setTransactionContact fx.base.userId txId (Just alien)
      case result of
        Left (ContactNotFound _) -> pure ()
        other -> expectationFailure $ "expected ContactNotFound, got: " <> show other

    it "rejects setting a contact on a transfer transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "set-contact-transfer@test.com"
      otherAccId <- createDefaultAccount env fx.base.userId "Other"

      create <-
        runAppM env
          $ initiateTransfer
            fx.base.userId
            fx.base.regularAccountId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Move funds"
            Nothing
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      result <- runAppM env $ setTransactionContact fx.base.userId txId (Just fx.contactA)
      case result of
        Left ContactNotAllowedOnTransfer -> pure ()
        other -> expectationFailure $ "expected ContactNotAllowedOnTransfer, got: " <> show other

  describe "amendTransaction contact validation" $ do
    it "records a valid contact when amending an income transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "amend-contact-ok@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 25)
            (incomeAllocs fx.base (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, seedTd) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      -- Also bump the amount so the payload is not an identity amend (the
      -- identity short-circuit compares accounts/amounts/rate/kind only —
      -- it has no way to see the prior contact since the read model does
      -- not yet surface contactId).
      let amend =
            InitiateTransactionAmendment
              { transactionId = txId,
                newSourceAccountId = seedTd.sourceAccountId,
                newTargetAccountId = seedTd.targetAccountId,
                newSourceAmount = seedTd.sourceAmount,
                newTargetAmount = unsafeMoney Core.USD 30,
                newExchangeRate = Nothing,
                newAllocations = Just (incomeAllocs fx.base (unsafeMoney Core.USD 30)),
                newTransactionType = seedTd.transactionType, -- placeholder; overwritten by service
                contactId = Just fx.contactA,
                by = fx.base.userId
              }
      result <- runAppM env $ amendTransaction fx.base.userId txId amend
      case result of
        Right _ -> do
          evts <- streamEvents env txId
          lastAmendmentContact evts `shouldBe` Just (Just fx.contactA)
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects an unknown contact id when amending" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "amend-contact-unknown@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 25)
            (incomeAllocs fx.base (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, seedTd) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      alien <- unsafeDictionaryEntryId <$> UUID.nextRandom
      let amend =
            InitiateTransactionAmendment
              { transactionId = txId,
                newSourceAccountId = seedTd.sourceAccountId,
                newTargetAccountId = seedTd.targetAccountId,
                newSourceAmount = seedTd.sourceAmount,
                newTargetAmount = seedTd.targetAmount,
                newExchangeRate = Nothing,
                newAllocations = Just (incomeAllocs fx.base (unsafeMoney Core.USD 25)),
                newTransactionType = seedTd.transactionType,
                contactId = Just alien,
                by = fx.base.userId
              }
      result <- runAppM env $ amendTransaction fx.base.userId txId amend
      case result of
        Left (ContactNotFound _) -> pure ()
        other -> expectationFailure $ "expected ContactNotFound, got: " <> show other

    it "does not short-circuit an amendment that changes only the contact" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "amend-contact-only@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.base.userId
            fx.base.regularAccountId
            (unsafeMoney Core.USD 25)
            (incomeAllocs fx.base (unsafeMoney Core.USD 25))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, seedTd) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      -- Same accounts/amounts/rate/kind as the seeded transaction — only the
      -- contact differs. The read model now surfaces contactId, so
      -- isIdentityAmend must not treat this as a no-op amendment.
      let amend =
            InitiateTransactionAmendment
              { transactionId = txId,
                newSourceAccountId = seedTd.sourceAccountId,
                newTargetAccountId = seedTd.targetAccountId,
                newSourceAmount = seedTd.sourceAmount,
                newTargetAmount = seedTd.targetAmount,
                newExchangeRate = seedTd.exchangeRate,
                newAllocations = Just (incomeAllocs fx.base (unsafeMoney Core.USD 25)),
                newTransactionType = seedTd.transactionType,
                contactId = Just fx.contactA,
                by = fx.base.userId
              }
      result <- runAppM env $ amendTransaction fx.base.userId txId amend
      case result of
        Right _ -> do
          evts <- streamEvents env txId
          lastAmendmentContact evts `shouldBe` Just (Just fx.contactA)
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects a contact when amending into a transfer kind" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupFixture env "amend-contact-transfer@test.com"
      otherAccId <- createDefaultAccount env fx.base.userId "Other"

      create <-
        runAppM env
          $ initiateTransfer
            fx.base.userId
            fx.base.regularAccountId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Move funds"
            Nothing
            Nothing
            Nothing
      (txId, seedTd) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      let amend =
            InitiateTransactionAmendment
              { transactionId = txId,
                newSourceAccountId = seedTd.sourceAccountId,
                newTargetAccountId = seedTd.targetAccountId,
                newSourceAmount = seedTd.sourceAmount,
                newTargetAmount = unsafeMoney Core.USD 15,
                newExchangeRate = Nothing,
                newAllocations = Nothing,
                newTransactionType = seedTd.transactionType,
                contactId = Just fx.contactA,
                by = fx.base.userId
              }
      result <- runAppM env $ amendTransaction fx.base.userId txId amend
      case result of
        Left ContactNotAllowedOnTransfer -> pure ()
        other -> expectationFailure $ "expected ContactNotAllowedOnTransfer, got: " <> show other
