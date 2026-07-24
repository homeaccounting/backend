{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.AllocationsSpec
-- Description : Worked examples for the allocations invariants.
--
-- The property-based coverage of 'mkIncome' / 'mkExpense' lives in
-- 'Domain.Core.TransactionTypePropertySpec'. This spec pins specific
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
--  * Handler-level contra-income guard: 'InitiateTransaction' carrying an
--    'Expense' with a non-empty income bucket is rejected.
--  * 'SetTransactionAllocations' re-anchors to the transaction's own amount,
--    not the stored allocation sum.
--  * 'SetTransactionAllocations' contra-income guard on a completed Expense.
module Domain.Transaction.AllocationsSpec (spec) where

import qualified Data.Set as Set
import qualified Data.Time as Time
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
  ( Allocation (..),
    Currency (..),
    DictionaryEntryId,
    TransactionType (..),
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import qualified Domain.Core.Types as Core (mkAllocations, mkExpense, mkExpenseAllocations, mkIncome, mkIncomeAllocations, mkMixedAllocations)
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    handleTransactionCommand,
  )
import qualified Domain.Transaction.CommandHandler as TxCh
import Domain.Transaction.Commands
  ( InitiateTransaction (..),
    SetTransactionAllocations (..),
  )
import Domain.Transaction.Events (TransactionAllocationsChanged (..))
import Domain.Transaction.Projection
  ( Transaction,
    TransactionEvent (..),
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

-- | An income-dictionary category used by the two-bucket worked examples.
salaryCat :: DictionaryEntryId
salaryCat = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)

-- | An expense-dictionary category used by the two-bucket worked examples.
rentCat :: DictionaryEntryId
rentCat = unsafeDictionaryEntryId (UUID.fromWords 5 0 0 0)

-- | A completed internal-transfer fixture used to exercise the
-- "allocations on Transfer" rejection path.
completedTransfer :: Transaction
completedTransfer =
  transactionDefault
    & #status
    .~ Completed
    & #transactionType
    .~ Transfer

spec :: Spec
spec = describe "Allocations / worked examples" $ do
  describe "mkIncome / mkExpense" $ do
    it "accepts a 200 + 800 UAH grocery split summing to 1000 UAH" $ do
      let total = unsafeMoney UAH 1000
          allocs =
            Core.mkExpenseAllocations
              (Allocation groceryStaples (unsafeMoney UAH 800) Nothing :| [Allocation groceryTreats (unsafeMoney UAH 200) Nothing])
      case Core.mkExpense total allocs of
        Right (Expense _) -> pure ()
        Right other ->
          expectationFailure $ "expected Right (Expense …), got " <> show other
        Left err ->
          expectationFailure $ "expected Right, got Left: " <> show err

    it "accepts the degenerate length-1 allocation equal to the total" $ do
      let total = unsafeMoney USD 50
          allocs = Core.mkIncomeAllocations (Allocation soloSalary (unsafeMoney USD 50) Nothing :| [])
      case Core.mkIncome total allocs of
        Right (Income _) -> pure ()
        Right other ->
          expectationFailure $ "expected Right (Income …), got " <> show other
        Left err ->
          expectationFailure $ "expected Right, got Left: " <> show err

    it "rejects a sum mismatch with a 'allocations' ValidationErr" $ do
      let total = unsafeMoney UAH 1000
          -- 800 + 100 = 900 ≠ 1000
          allocs =
            Core.mkExpenseAllocations
              (Allocation groceryStaples (unsafeMoney UAH 800) Nothing :| [Allocation groceryTreats (unsafeMoney UAH 100) Nothing])
      case Core.mkExpense total allocs of
        Left (ValidationErr ve) ->
          ve.validationField `shouldBe` "allocations"
        other ->
          expectationFailure $ "expected ValidationErr allocations, got " <> show other

    it "rejects a currency mismatch with a 'currency' ValidationErr" $ do
      let total = unsafeMoney UAH 1000
          -- categorised side is UAH but one allocation is USD
          allocs =
            Core.mkExpenseAllocations
              (Allocation groceryStaples (unsafeMoney UAH 500) Nothing :| [Allocation groceryTreats (unsafeMoney USD 500) Nothing])
      case Core.mkExpense total allocs of
        Left (ValidationErr ve) ->
          ve.validationField `shouldBe` "currency"
        other ->
          expectationFailure $ "expected ValidationErr currency, got " <> show other

  describe "two-bucket allocations" $ do
    it "accepts a standalone refund: Income with empty incomes, $40 in expenses" $ do
      let total = unsafeMoney USD 40
          allocs = Core.mkExpenseAllocations (Allocation rentCat (unsafeMoney USD 40) Nothing :| [])
      case Core.mkIncome total allocs of
        Right (Income _) -> pure ()
        other -> expectationFailure $ "expected Right (Income …), got " <> show other

    it "accepts salary+rent: Income with $5000 incomes and $500 expenses summing to $5500" $ do
      let total = unsafeMoney USD 5500
          allocs =
            Core.mkMixedAllocations
              (Allocation salaryCat (unsafeMoney USD 5000) Nothing :| [])
              (Allocation rentCat (unsafeMoney USD 500) Nothing :| [])
      Core.mkIncome total allocs `shouldSatisfy` isRight

    it "rejects an Expense carrying a non-empty income bucket (contra-income)" $ do
      let total = unsafeMoney USD 500
          allocs =
            Core.mkMixedAllocations
              (Allocation salaryCat (unsafeMoney USD 100) Nothing :| [])
              (Allocation rentCat (unsafeMoney USD 400) Nothing :| [])
      Core.mkExpense total allocs `shouldBe` Left ContraIncomeNotSupported

    it "rejects both-empty allocations with AllocationsEmpty" $ do
      Core.mkAllocations [] [] `shouldBe` Left AllocationsEmpty

    it "rejects a combined sum mismatch" $ do
      let total = unsafeMoney USD 5500
          allocs =
            Core.mkMixedAllocations
              (Allocation salaryCat (unsafeMoney USD 5000) Nothing :| [])
              (Allocation rentCat (unsafeMoney USD 400) Nothing :| []) -- 5400 ≠ 5500
      case Core.mkIncome total allocs of
        Left (ValidationErr ve) -> ve.validationField `shouldBe` "allocations"
        other -> expectationFailure $ "expected sum ValidationErr, got " <> show other

  describe "SetTransactionAllocations on a Transfer" $ do
    it "is rejected with CannotSetAllocationsOnUncategorisedTransaction" $ do
      let allocs = Core.mkExpenseAllocations (Allocation groceryStaples (unsafeMoney UAH 10) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = unsafeTransactionId (UUID.fromWords 100 0 0 0),
                  newAllocations = allocs
                }
      handleTransactionCommand completedTransfer cmd
        `shouldBe` Left TxCh.CannotSetAllocationsOnUncategorisedTransaction

  -- --------------------------------------------------------------------------
  -- Handler-level contra-income guard
  -- --------------------------------------------------------------------------

  describe "handler-level ContraIncomeNotSupported" $ do
    -- Test 1: InitiateTransaction with Expense carrying a non-empty incomes
    -- bucket is rejected at the handler boundary.
    --
    -- WHY it would fail if the rule were removed: the handler arm for
    -- 'InitiateTransaction' would fall through the
    --   "if null allocs.incomes then Right () else Left ContraIncomeNotSupported"
    -- branch without emitting the error, so the test would see a 'Right [...]'
    -- instead of 'Left ContraIncomeNotSupported'.
    it "InitiateTransaction: Expense with non-empty incomes bucket is rejected" $ do
      -- Build the contra-income allocations directly, bypassing mkExpense
      -- (which also rejects them).  The $40 income + $360 expense sum to $400
      -- (the source amount), so the sum check passes first and the
      -- contra-income check fires second.
      let srcAmount = unsafeMoney USD 400
          tgtAmount = unsafeMoney USD 400
          contraBadAllocs =
            Core.mkMixedAllocations
              (Allocation salaryCat (unsafeMoney USD 40) Nothing :| [])
              (Allocation rentCat (unsafeMoney USD 360) Nothing :| [])
          cmd =
            InitiateTransactionTransactionCommand
              InitiateTransaction
                { sourceAccountId = unsafeAccountId (UUID.fromWords 10 0 0 0),
                  targetAccountId = unsafeAccountId (UUID.fromWords 11 0 0 0),
                  sourceAmount = srcAmount,
                  targetAmount = tgtAmount,
                  exchangeRate = Nothing,
                  description = "test expense with contra income",
                  initiatedBy = unsafeUserId (UUID.fromWords 99 0 0 0),
                  at = Time.UTCTime (Time.fromGregorian 2025 1 1) 0,
                  transactionType = Expense contraBadAllocs,
                  importInfo = Nothing,
                  labels = Set.empty,
                  contactId = Nothing,
                  relation = Nothing
                }
      -- transactionDefault has sourceAmount = 0 (uninitialised) so the
      -- handler treats it as "not yet initiated" and proceeds to validation.
      handleTransactionCommand transactionDefault cmd
        `shouldBe` Left TxCh.ContraIncomeNotSupported

    -- Test 3: SetTransactionAllocations on a completed Expense with a
    -- non-empty incomes bucket is rejected.
    --
    -- WHY it would fail if the rule were removed: the handler would skip the
    --   "case transaction.transactionType of Expense _ | not (null newAllocations.incomes) -> Left ContraIncomeNotSupported"
    -- guard and emit 'Right [TransactionAllocationsChanged...]' instead.
    it "SetTransactionAllocations: completed Expense with non-empty incomes bucket is rejected" $ do
      let expenseAmount = unsafeMoney USD 500
          -- Completed Expense fixture: $500 expense with a single expense alloc.
          completedExpense =
            transactionDefault
              & #status
              .~ Completed
              & #sourceAmount
              .~ expenseAmount
              & #transactionType
              .~ Expense (Core.mkExpenseAllocations (Allocation rentCat expenseAmount Nothing :| []))
          -- New allocations have $50 in the income bucket + $450 in expense.
          -- Sum = $500 = sourceAmount, so sum/currency checks pass first.
          contraNewAllocs =
            Core.mkMixedAllocations
              (Allocation salaryCat (unsafeMoney USD 50) Nothing :| [])
              (Allocation rentCat (unsafeMoney USD 450) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = unsafeTransactionId (UUID.fromWords 200 0 0 0),
                  newAllocations = contraNewAllocs
                }
      handleTransactionCommand completedExpense cmd
        `shouldBe` Left TxCh.ContraIncomeNotSupported

  -- --------------------------------------------------------------------------
  -- SetTransactionAllocations anchors to the transaction's own amount
  -- --------------------------------------------------------------------------

  describe "SetTransactionAllocations anchor re-check" $ do
    -- Test 2a: new allocations summing to targetAmount are accepted.
    --
    -- WHY it would fail if the rule were removed / broken: if the handler used
    -- the OLD allocation sum as the anchor instead of targetAmount, this
    -- command would be rejected with AllocationsDoNotSumToTotal (because
    -- oldSum = $300 ≠ new allocation sum = $500 = targetAmount).
    it "Income: new allocations summing to targetAmount are accepted" $ do
      let targetAmt = unsafeMoney USD 500
          -- Old allocations sum to $300, NOT to targetAmount ($500).
          -- This makes the old-sum vs targetAmount distinction meaningful.
          oldAllocs = Core.mkIncomeAllocations (Allocation salaryCat (unsafeMoney USD 300) Nothing :| [])
          completedIncome =
            transactionDefault
              & #status
              .~ Completed
              & #targetAmount
              .~ targetAmt
              & #transactionType
              .~ Income oldAllocs
          -- New allocations sum exactly to targetAmount ($500).
          newAllocs = Core.mkIncomeAllocations (Allocation salaryCat (unsafeMoney USD 500) Nothing :| [])
          txId = unsafeTransactionId (UUID.fromWords 300 0 0 0)
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = txId,
                  newAllocations = newAllocs
                }
          result = handleTransactionCommand completedIncome cmd
      case result of
        Right [TransactionAllocationsChangedTransactionEvent evt] ->
          evt.newAllocations `shouldBe` newAllocs
        Right other ->
          expectationFailure $ "expected Right [TransactionAllocationsChanged], got " <> show other
        Left err ->
          expectationFailure $ "expected Right, got Left: " <> show err

    -- Test 2b: new allocations summing to the OLD allocation total but NOT to
    -- targetAmount are rejected.
    --
    -- WHY it would fail if the rule were removed / broken: if the handler used
    -- oldSum ($300) as the anchor, the $300 new allocation would pass;
    -- only using targetAmount ($500) causes the rejection.
    it "Income: new allocations summing to old allocation total (not targetAmount) are rejected" $ do
      let targetAmt = unsafeMoney USD 500
          -- Old allocations sum to $300.
          oldAllocs = Core.mkIncomeAllocations (Allocation salaryCat (unsafeMoney USD 300) Nothing :| [])
          completedIncome =
            transactionDefault
              & #status
              .~ Completed
              & #targetAmount
              .~ targetAmt
              & #transactionType
              .~ Income oldAllocs
          -- New allocations sum to old alloc total ($300), NOT targetAmount ($500).
          newAllocsOldSum = Core.mkIncomeAllocations (Allocation salaryCat (unsafeMoney USD 300) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = unsafeTransactionId (UUID.fromWords 301 0 0 0),
                  newAllocations = newAllocsOldSum
                }
      handleTransactionCommand completedIncome cmd
        `shouldBe` Left TxCh.AllocationsDoNotSumToTotal
