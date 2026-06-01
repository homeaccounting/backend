{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.AllocationsSpec
-- Description : Worked examples for the allocations invariants.
--
-- The property-based coverage of 'mkIncome' / 'mkExpense' lives in
-- 'Domain.Core.TransferTypePropertySpec'. This spec pins specific
-- worked examples drawn from the spec to make the invariants concrete
-- and the failure modes legible:
--
--  * 200 + 800 UAH grocery split sums to 1000 (smart constructor accepts).
--  * Length-1 allocation totalling the full amount (the legacy
--    single-category shape) is still accepted.
--  * Sum mismatch is rejected with a 'allocations' ValidationErr.
--  * Currency mismatch is rejected with a 'currency' ValidationErr.
--  * Allocations applied to a Transfer aggregate are rejected by the
--    pure command handler with
--    'CannotSetAllocationsOnUncategorisedTransaction'.
module Domain.Transaction.AllocationsSpec (spec) where

import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
  ( Allocation (..),
    Currency (..),
    DictionaryEntryId,
    TransferType (..),
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
  )
import qualified Domain.Core.Types as Core (mkExpense, mkIncome)
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    handleTransactionCommand,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands (SetTransactionAllocations (..))
import Domain.Transaction.Projection
  ( Transaction,
    TransactionStatus (..),
    transactionDefault,
  )
import Optics ((&), (.~))
import RIO hiding ((&), (.~))
import Test.Hspec

-- | Two grocery categories used by the 200 + 800 worked example.
groceryStaples, groceryTreats :: DictionaryEntryId
groceryStaples = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
groceryTreats = unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0)

-- | A length-1 income with the full categorised total assigned to one
-- category — the legacy single-category shape.
soloSalary :: DictionaryEntryId
soloSalary = unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0)

-- | A completed internal-transfer fixture used to exercise the
-- "allocations on Transfer" rejection path.
completedTransfer :: Transaction
completedTransfer =
  transactionDefault
    & #status
    .~ Completed
    & #transferType
    .~ Transfer

spec :: Spec
spec = describe "Allocations / worked examples" $ do
  describe "mkIncome / mkExpense" $ do
    it "accepts a 200 + 800 UAH grocery split summing to 1000 UAH" $ do
      let total = unsafeMoney UAH 1000
          allocs =
            Allocation groceryStaples (unsafeMoney UAH 800)
              :| [Allocation groceryTreats (unsafeMoney UAH 200)]
      case Core.mkExpense total allocs of
        Right (Expense _) -> pure ()
        Right other ->
          expectationFailure $ "expected Right (Expense …), got " <> show other
        Left err ->
          expectationFailure $ "expected Right, got Left: " <> show err

    it "accepts the degenerate length-1 allocation equal to the total" $ do
      let total = unsafeMoney USD 50
          allocs = Allocation soloSalary (unsafeMoney USD 50) :| []
      case Core.mkIncome total allocs of
        Right (Income _) -> pure ()
        Right other ->
          expectationFailure $ "expected Right (Income …), got " <> show other
        Left err ->
          expectationFailure $ "expected Right, got Left: " <> show err

    it "rejects a sum mismatch with a 'allocations' ValidationErr" $ do
      let total = unsafeMoney UAH 1000
          allocs =
            -- 800 + 100 = 900 ≠ 1000
            Allocation groceryStaples (unsafeMoney UAH 800)
              :| [Allocation groceryTreats (unsafeMoney UAH 100)]
      case Core.mkExpense total allocs of
        Left (ValidationErr ve) ->
          ve.validationField `shouldBe` "allocations"
        other ->
          expectationFailure $ "expected ValidationErr allocations, got " <> show other

    it "rejects a currency mismatch with a 'currency' ValidationErr" $ do
      let total = unsafeMoney UAH 1000
          allocs =
            -- categorised side is UAH but one allocation is USD
            Allocation groceryStaples (unsafeMoney UAH 500)
              :| [Allocation groceryTreats (unsafeMoney USD 500)]
      case Core.mkExpense total allocs of
        Left (ValidationErr ve) ->
          ve.validationField `shouldBe` "currency"
        other ->
          expectationFailure $ "expected ValidationErr currency, got " <> show other

  describe "SetTransactionAllocations on a Transfer" $ do
    it "is rejected with CannotSetAllocationsOnUncategorisedTransaction" $ do
      let allocs = Allocation groceryStaples (unsafeMoney UAH 10) :| []
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = unsafeTransactionId (UUID.fromWords 100 0 0 0),
                  newAllocations = allocs
                }
      handleTransactionCommand completedTransfer cmd
        `shouldBe` Left TxCh.CannotSetAllocationsOnUncategorisedTransaction
