{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.LabelsAndCategorySpec
-- Description : SetTransactionLabels / SetTransactionAllocations command-handler rules.
module Domain.Transaction.LabelsAndCategorySpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( Allocation (..),
    Allocations,
    Currency (..),
    DictionaryEntryId,
    TransactionType (..),
    mkExpenseAllocations,
    mkIncomeAllocations,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    TransactionError (..),
    handleTransactionCommand,
  )
import Domain.Transaction.Commands
  ( SetTransactionAllocations (..),
    SetTransactionContact (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Projection
  ( Transaction,
    TransactionStatus (..),
    transactionDefault,
  )
import Optics ((&), (.~))
import RIO hiding ((&), (.~))
import Test.Hspec

incomeCat, expenseCat :: DictionaryEntryId
incomeCat = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
expenseCat = unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0)

-- | Length-1 allocation for an Income, totalling 100 USD.
incomeAllocs :: Allocations
incomeAllocs = mkIncomeAllocations (Allocation incomeCat (unsafeMoney USD 100) Nothing :| [])

-- | Length-1 allocation for an Expense, totalling 100 USD.
expenseAllocs :: Allocations
expenseAllocs = mkExpenseAllocations (Allocation expenseCat (unsafeMoney USD 100) Nothing :| [])

completedIncome :: Transaction
completedIncome =
  transactionDefault
    & #status
    .~ Completed
    & #targetAmount
    .~ unsafeMoney USD 100
    & #transactionType
    .~ Income incomeAllocs

completedExpense :: Transaction
completedExpense =
  transactionDefault
    & #status
    .~ Completed
    & #sourceAmount
    .~ unsafeMoney USD 100
    & #transactionType
    .~ Expense expenseAllocs

completedTransfer :: Transaction
completedTransfer =
  transactionDefault
    & #status
    .~ Completed
    & #transactionType
    .~ Transfer

pendingIncome :: Transaction
pendingIncome = completedIncome & #status .~ Pending

spec :: Spec
spec = do
  describe "SetTransactionLabels" $ do
    it "accepted in Completed state and emits TransactionLabelsSet" $ do
      let cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = txId,
                  labels = Set.fromList [unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0)]
                }
      handleTransactionCommand completedTransfer cmd `shouldSatisfy` isRight

    it "rejected on Pending with CannotEditUncompletedTransaction" $ do
      let cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = txId,
                  labels = Set.empty
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected on Failed with CannotEditUncompletedTransaction" $ do
      let failed = completedIncome & #status .~ Failed "nope"
          cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = txId,
                  labels = Set.empty
                }
      handleTransactionCommand failed cmd `shouldBe` Left CannotEditUncompletedTransaction

  describe "SetTransactionContact" $ do
    it "accepted in Completed state and emits TransactionContactSet" $ do
      let cmd =
            SetTransactionContactTransactionCommand
              SetTransactionContact
                { transactionId = txId,
                  contactId = Just (unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0))
                }
      handleTransactionCommand completedTransfer cmd `shouldSatisfy` isRight

    it "rejected on Pending with CannotEditUncompletedTransaction" $ do
      let cmd =
            SetTransactionContactTransactionCommand
              SetTransactionContact
                { transactionId = txId,
                  contactId = Nothing
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected on Failed with CannotEditUncompletedTransaction" $ do
      let failed = completedIncome & #status .~ Failed "nope"
          cmd =
            SetTransactionContactTransactionCommand
              SetTransactionContact
                { transactionId = txId,
                  contactId = Nothing
                }
      handleTransactionCommand failed cmd `shouldBe` Left CannotEditUncompletedTransaction

  describe "SetTransactionAllocations" $ do
    it "accepted on Income with same kind + matching sum" $ do
      let newCat = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)
          newAllocs = mkIncomeAllocations (Allocation newCat (unsafeMoney USD 100) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = txId,
                  newAllocations = newAllocs
                }
      handleTransactionCommand completedIncome cmd `shouldSatisfy` isRight

    it "accepted on Expense with same kind + matching sum" $ do
      let newCat = unsafeDictionaryEntryId (UUID.fromWords 5 0 0 0)
          newAllocs = mkExpenseAllocations (Allocation newCat (unsafeMoney USD 100) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = txId,
                  newAllocations = newAllocs
                }
      handleTransactionCommand completedExpense cmd `shouldSatisfy` isRight

    it "rejected on internal Transfer with CannotSetAllocationsOnUncategorisedTransaction" $ do
      let newCat = unsafeDictionaryEntryId (UUID.fromWords 6 0 0 0)
          newAllocs = mkIncomeAllocations (Allocation newCat (unsafeMoney USD 100) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = txId,
                  newAllocations = newAllocs
                }
      handleTransactionCommand completedTransfer cmd
        `shouldBe` Left CannotSetAllocationsOnUncategorisedTransaction

    it "rejected when allocations do not sum to the existing categorised total" $ do
      let newCat = unsafeDictionaryEntryId (UUID.fromWords 8 0 0 0)
          newAllocs = mkIncomeAllocations (Allocation newCat (unsafeMoney USD 50) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = txId,
                  newAllocations = newAllocs
                }
      handleTransactionCommand completedIncome cmd
        `shouldBe` Left AllocationsDoNotSumToTotal

    it "rejected in Pending state with CannotEditUncompletedTransaction" $ do
      let newCat = unsafeDictionaryEntryId (UUID.fromWords 9 0 0 0)
          newAllocs = mkIncomeAllocations (Allocation newCat (unsafeMoney USD 100) Nothing :| [])
          cmd =
            SetTransactionAllocationsTransactionCommand
              SetTransactionAllocations
                { transactionId = txId,
                  newAllocations = newAllocs
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditUncompletedTransaction
  where
    txId = unsafeTransactionId (UUID.fromWords 100 0 0 0)
