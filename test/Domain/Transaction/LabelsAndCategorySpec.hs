{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.LabelsAndCategorySpec
-- Description : SetTransactionLabels / ChangeTransactionCategory command-handler rules.
module Domain.Transaction.LabelsAndCategorySpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types (TransferType (..), unsafeDictionaryEntryId, unsafeTransactionId)
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    TransactionError (..),
    handleTransactionCommand,
  )
import Domain.Transaction.Commands
  ( ChangeTransactionCategory (..),
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

completedIncome :: Transaction
completedIncome =
  transactionDefault
    & #status
    .~ Completed
    & #transferType
    .~ Income (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0))

completedExpense :: Transaction
completedExpense =
  transactionDefault
    & #status
    .~ Completed
    & #transferType
    .~ Expense (unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0))

completedTransfer :: Transaction
completedTransfer =
  transactionDefault
    & #status
    .~ Completed
    & #transferType
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

    it "rejected on Pending with CannotEditLabelsInCurrentState" $ do
      let cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = txId,
                  labels = Set.empty
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditLabelsInCurrentState

    it "rejected on Failed with CannotEditLabelsInCurrentState" $ do
      let failed = completedIncome & #status .~ Failed "nope"
          cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = txId,
                  labels = Set.empty
                }
      handleTransactionCommand failed cmd `shouldBe` Left CannotEditLabelsInCurrentState

  describe "ChangeTransactionCategory" $ do
    it "accepted on Income and emits TransactionCategoryChanged" $ do
      let newId = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)
          cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = txId,
                  newCategory = newId
                }
      handleTransactionCommand completedIncome cmd `shouldSatisfy` isRight

    it "accepted on Expense" $ do
      let newId = unsafeDictionaryEntryId (UUID.fromWords 5 0 0 0)
          cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = txId,
                  newCategory = newId
                }
      handleTransactionCommand completedExpense cmd `shouldSatisfy` isRight

    it "rejected on internal Transfer with CannotChangeCategoryOnUncategorizedTransaction" $ do
      let cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = txId,
                  newCategory = unsafeDictionaryEntryId (UUID.fromWords 6 0 0 0)
                }
      handleTransactionCommand completedTransfer cmd
        `shouldBe` Left CannotChangeCategoryOnUncategorizedTransaction

    it "rejected in Pending state with CannotEditLabelsInCurrentState" $ do
      let cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = txId,
                  newCategory = unsafeDictionaryEntryId (UUID.fromWords 7 0 0 0)
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditLabelsInCurrentState
  where
    txId = unsafeTransactionId (UUID.fromWords 100 0 0 0)
