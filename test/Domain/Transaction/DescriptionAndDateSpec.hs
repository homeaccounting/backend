{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.DescriptionAndDateSpec
-- Description : ChangeTransactionDescription / ChangeTransactionDate command-handler
--               and projection fold rules.
module Domain.Transaction.DescriptionAndDateSpec (spec) where

import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( Allocation (..),
    Currency (..),
    TransactionId,
    TransactionType (..),
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
  ( ChangeTransactionDate (..),
    ChangeTransactionDescription (..),
  )
import Domain.Transaction.Events
  ( TransactionDateChanged (..),
    TransactionDescriptionChanged (..),
    TransactionPostingCompleted (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Projection
  ( Transaction,
    TransactionEvent (..),
    TransactionStatus (..),
    transactionDefault,
    transactionProjection,
  )
import Eventium (latestProjection)
import Optics ((&), (.~), (^.))
import RIO hiding ((&), (.~), (^.))
import Test.Hspec

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

txId :: TransactionId
txId = unsafeTransactionId (UUID.fromWords 100 0 0 0)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

t1 :: UTCTime
t1 = UTCTime (fromGregorian 2026 3 15) (secondsToDiffTime 3600)

t2 :: UTCTime
t2 = UTCTime (fromGregorian 2026 5 20) (secondsToDiffTime 7200)

completedIncome :: Transaction
completedIncome =
  transactionDefault
    & #status
    .~ Completed
    & #transactionType
    .~ Income (mkIncomeAllocations (Allocation (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)) (unsafeMoney USD 100) Nothing :| []))
    & #description
    .~ "Original"
    & #at
    .~ t1

pendingIncome :: Transaction
pendingIncome = completedIncome & #status .~ Pending

failedIncome :: Transaction
failedIncome = completedIncome & #status .~ Failed "nope"

-- | Default 'TransactionPostingInitiated' event shape; callers override specific fields
-- via record update.
mkInitiated :: TransactionPostingInitiated
mkInitiated =
  TransactionPostingInitiated
    { sourceAccountId = transactionDefault ^. #sourceAccountId,
      targetAccountId = transactionDefault ^. #targetAccountId,
      sourceAmount = transactionDefault ^. #sourceAmount,
      targetAmount = transactionDefault ^. #targetAmount,
      exchangeRate = Nothing,
      description = "",
      by = transactionDefault ^. #initiatedBy,
      at = t0,
      transactionType = Income (mkIncomeAllocations (Allocation (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)) (unsafeMoney USD 100) Nothing :| [])),
      externalTransactionId = Nothing,
      labels = Set.empty
    }

completedEvent :: TransactionEvent
completedEvent = TransactionPostingCompletedTransactionEvent TransactionPostingCompleted

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "ChangeTransactionDescription" $ do
    it "accepted in Completed state and emits TransactionDescriptionChanged" $ do
      let cmd =
            ChangeTransactionDescriptionTransactionCommand
              ChangeTransactionDescription
                { transactionId = txId,
                  newDescription = "Updated"
                }
      handleTransactionCommand completedIncome cmd `shouldSatisfy` isRight

    it "projection's description updates after the event is folded" $ do
      let evts =
            [ TransactionPostingInitiatedTransactionEvent mkInitiated {description = "Original"},
              completedEvent,
              TransactionDescriptionChangedTransactionEvent
                TransactionDescriptionChanged
                  { transactionId = txId,
                    newDescription = "Updated"
                  }
            ]
          projected = latestProjection transactionProjection evts
      projected ^. #description `shouldBe` "Updated"

    it "rejected on Pending with CannotEditUncompletedTransaction" $ do
      let cmd =
            ChangeTransactionDescriptionTransactionCommand
              ChangeTransactionDescription
                { transactionId = txId,
                  newDescription = "Updated"
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected on Failed with CannotEditUncompletedTransaction" $ do
      let cmd =
            ChangeTransactionDescriptionTransactionCommand
              ChangeTransactionDescription
                { transactionId = txId,
                  newDescription = "Updated"
                }
      handleTransactionCommand failedIncome cmd `shouldBe` Left CannotEditUncompletedTransaction

  describe "ChangeTransactionDate" $ do
    it "accepted in Completed state and emits TransactionDateChanged" $ do
      let cmd =
            ChangeTransactionDateTransactionCommand
              ChangeTransactionDate
                { transactionId = txId,
                  newAt = t2
                }
      handleTransactionCommand completedIncome cmd `shouldSatisfy` isRight

    it "projection's at updates after the event is folded" $ do
      let evts =
            [ TransactionPostingInitiatedTransactionEvent mkInitiated {at = t1},
              completedEvent,
              TransactionDateChangedTransactionEvent
                TransactionDateChanged
                  { transactionId = txId,
                    newAt = t2
                  }
            ]
          projected = latestProjection transactionProjection evts
      projected ^. #at `shouldBe` t2

    it "rejected on Pending with CannotEditUncompletedTransaction" $ do
      let cmd =
            ChangeTransactionDateTransactionCommand
              ChangeTransactionDate
                { transactionId = txId,
                  newAt = t2
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditUncompletedTransaction

    it "rejected on Failed with CannotEditUncompletedTransaction" $ do
      let cmd =
            ChangeTransactionDateTransactionCommand
              ChangeTransactionDate
                { transactionId = txId,
                  newAt = t2
                }
      handleTransactionCommand failedIncome cmd `shouldBe` Left CannotEditUncompletedTransaction

  describe "TransactionPostingInitiated.at -> projection.at" $ do
    it "projection's at is set from TransactionPostingInitiated.at" $ do
      let evts = [TransactionPostingInitiatedTransactionEvent mkInitiated {at = t1}]
          projected = latestProjection transactionProjection evts
      projected ^. #at `shouldBe` t1
