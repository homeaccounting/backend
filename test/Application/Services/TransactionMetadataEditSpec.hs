{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionMetadataEditSpec
-- Description : description/date edits and books-close gating in TransactionService.
--
-- Covers the transaction-service surface added with editable metadata:
--
--  * 'changeTransactionDescription' — Editor-access gate, Completed
--    state guard. The description carries no period information, so it
--    is intentionally not subject to the books-close cutoff.
--  * 'changeTransactionDate' — Editor-access gate, Completed state
--    guard, and rejection when either the current TX date or the new
--    target date falls on or before the user's @booksClosedThrough@
--    cutoff.
--  * Books-close gating on the three creation paths
--    ('initiateIncome' / 'initiateExpense' / 'initiateInternalTransfer'):
--    backdated transactions on or before the cutoff are refused with
--    'CannotEditClosedPeriod'.
module Application.Services.TransactionMetadataEditSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.ConfigurationService (closeBooksThrough)
import Application.Services.TransactionService
  ( changeTransactionDate,
    changeTransactionDescription,
    initiateExpense,
    initiateIncome,
    initiateInternalTransfer,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Core.Types (unsafeMoney)
import Infrastructure.App (runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createRegularAccount,
    registerUser,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
  )
import Testkit.Time (utc)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService / metadata edits + books-close gating" $ do
  describe "changeTransactionDescription" $ do
    it "updates the description on a Completed transaction" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "desc-ok@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            fx.incomeCategory
            Set.empty
            "Original"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      result <-
        runAppM env
          $ changeTransactionDescription fx.userId txId "Corrected"
      case result of
        Right td -> td.description `shouldBe` "Corrected"
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "denies edits from a user without Editor+ access on the transaction" $ do
      env <- createTestAppEnvWithProcessManager
      owner <- setupMetadataFixture env "desc-owner@test.com"

      create <-
        runAppM env
          $ initiateIncome
            owner.userId
            owner.regularAccountId
            (unsafeMoney Core.USD 25)
            owner.incomeCategory
            Set.empty
            "Owner only"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      stranger <- registerUser env "desc-stranger@test.com"
      result <-
        runAppM env
          $ changeTransactionDescription stranger txId "Hijack"
      case result of
        Left (AccountError _) -> pure ()
        other -> expectationFailure $ "expected AccountError, got: " <> show other

    it "rejects edits while the transaction is still Pending" $ do
      env <- createTestAppEnv
      fx <- setupMetadataFixture env "desc-pending@test.com"
      otherAccId <- createRegularAccount env fx.userId "Other"

      create <-
        runAppM env
          $ initiateInternalTransfer
            fx.userId
            fx.regularAccountId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Pending"
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateInternalTransfer failed: " <> show err

      result <-
        runAppM env
          $ changeTransactionDescription fx.userId txId "Updated"
      case result of
        Left CannotEditUncompletedTransaction -> pure ()
        other ->
          expectationFailure
            $ "expected CannotEditUncompletedTransaction, got: "
            <> show other

  describe "changeTransactionDate" $ do
    it "updates the date on a Completed transaction when no books-close set" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "date-ok@test.com"

      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            fx.incomeCategory
            Set.empty
            "Seed"
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let newAt = utc 2026 4 15
      result <- runAppM env $ changeTransactionDate fx.userId txId newAt
      case result of
        Right td -> td.date `shouldBe` newAt
        Left err -> expectationFailure $ "expected Right, got: " <> show err

    it "rejects when the new date falls on or before booksClosedThrough" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "date-new-closed@test.com"

      let originalAt = utc 2026 5 10
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            fx.incomeCategory
            Set.empty
            "Seed"
            (Just originalAt)
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cutoff = utc 2026 3 31
      closeResult <- runAppM env (closeBooksThrough fx.userId cutoff)
      case closeResult of
        Right _ -> pure ()
        Left err -> fail $ "closeBooksThrough failed: " <> show err

      let badNewAt = utc 2026 3 15
      result <- runAppM env $ changeTransactionDate fx.userId txId badNewAt
      result
        `shouldBe` Left
          CannotEditClosedPeriod
            { current = cutoff,
              attempted = badNewAt
            }

    it "rejects when the current TX date falls on or before booksClosedThrough" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "date-current-closed@test.com"

      -- TX dated March 15, before books close (March 31).
      let originalAt = utc 2026 3 15
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            fx.incomeCategory
            Set.empty
            "Backdated seed (open period)"
            (Just originalAt)
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cutoff = utc 2026 3 31
      closeResult <- runAppM env (closeBooksThrough fx.userId cutoff)
      case closeResult of
        Right _ -> pure ()
        Left err -> fail $ "closeBooksThrough failed: " <> show err

      -- Target date is in the open period, but the current TX is closed.
      let openNewAt = utc 2026 4 15
      result <- runAppM env $ changeTransactionDate fx.userId txId openNewAt
      result
        `shouldBe` Left
          CannotEditClosedPeriod
            { current = cutoff,
              attempted = originalAt
            }

    it "rejects edits while the transaction is still Pending" $ do
      env <- createTestAppEnv
      fx <- setupMetadataFixture env "date-pending@test.com"
      otherAccId <- createRegularAccount env fx.userId "Other"

      create <-
        runAppM env
          $ initiateInternalTransfer
            fx.userId
            fx.regularAccountId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Pending"
            Nothing
            Nothing
      (txId, _) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateInternalTransfer failed: " <> show err

      let newAt = utc 2026 6 1
      result <- runAppM env $ changeTransactionDate fx.userId txId newAt
      case result of
        Left CannotEditUncompletedTransaction -> pure ()
        other ->
          expectationFailure
            $ "expected CannotEditUncompletedTransaction, got: "
            <> show other

  describe "books-close gating on creation paths" $ do
    it "rejects backdated initiateExpense in a closed period" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "create-expense-closed@test.com"

      let cutoff = utc 2026 3 31
      closeResult <- runAppM env (closeBooksThrough fx.userId cutoff)
      case closeResult of
        Right _ -> pure ()
        Left err -> fail $ "closeBooksThrough failed: " <> show err

      let backdated = utc 2026 3 15
      result <-
        runAppM env
          $ initiateExpense
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 10)
            fx.expenseCategory
            Set.empty
            "Backdated"
            (Just backdated)
      result
        `shouldBe` Left
          CannotEditClosedPeriod
            { current = cutoff,
              attempted = backdated
            }

    it "rejects backdated initiateIncome in a closed period" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "create-income-closed@test.com"

      let cutoff = utc 2026 3 31
      closeResult <- runAppM env (closeBooksThrough fx.userId cutoff)
      case closeResult of
        Right _ -> pure ()
        Left err -> fail $ "closeBooksThrough failed: " <> show err

      let backdated = utc 2026 3 15
      result <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            fx.incomeCategory
            Set.empty
            "Backdated"
            (Just backdated)
      result
        `shouldBe` Left
          CannotEditClosedPeriod
            { current = cutoff,
              attempted = backdated
            }

    it "rejects backdated initiateInternalTransfer in a closed period" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "create-transfer-closed@test.com"
      otherAccId <- createRegularAccount env fx.userId "Other"

      let cutoff = utc 2026 3 31
      closeResult <- runAppM env (closeBooksThrough fx.userId cutoff)
      case closeResult of
        Right _ -> pure ()
        Left err -> fail $ "closeBooksThrough failed: " <> show err

      let backdated = utc 2026 3 15
      result <-
        runAppM env
          $ initiateInternalTransfer
            fx.userId
            fx.regularAccountId
            otherAccId
            (unsafeMoney Core.USD 10)
            Set.empty
            "Backdated"
            Nothing
            (Just backdated)
      result
        `shouldBe` Left
          CannotEditClosedPeriod
            { current = cutoff,
              attempted = backdated
            }
