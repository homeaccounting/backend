{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Account.ReversalCommandHandlerSpec
-- Description : Unit tests for the ReverseAccountDebit and ReverseAccountCredit command handlers
--
-- Covers:
--   - ReverseAccountDebit on an existing account emits AccountDebitReversed
--   - ReverseAccountDebit on default (uninitialised) account returns AccountDoesNotExist
--   - ReverseAccountCredit on an account where the reversal would take balance negative
--     is still accepted (no overdraft check); emits AccountCreditReversed
--   - Currency mismatch returns CurrencyMismatch
module Domain.Account.ReversalCommandHandlerSpec (spec) where

import Data.Time (UTCTime)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Domain.Account.CommandHandler
import Domain.Account.Commands (ReverseAccountCredit (..), ReverseAccountDebit (..))
import Domain.Account.Events
  ( AccountCreated (..),
    AccountCreditReversed (..),
    AccountDebitReversed (..),
  )
import Domain.Account.Projection
import Domain.Core.Types
import Eventium (latestProjection)
import RIO hiding ((^.))
import Test.Hspec
import Testkit.Helpers
import Prelude (read)

spec :: Spec
spec = do
  reverseAccountDebitSpec
  reverseAccountCreditSpec
  reversalCurrencyMismatchSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get account state
applyEvents :: [AccountEvent] -> Account
applyEvents = latestProjection accountProjection

-- | A fixed timestamp used across all reversal tests
testTimestamp :: UTCTime
testTimestamp = UTCTime (fromGregorian 2026 5 23) 0

-- | Test user ID for account creation
testOwnerId :: UserId
testOwnerId = mockUserId (read "11111111-1111-1111-1111-111111111111")

-- | Test transaction ID for saga correlation
testTransactionId :: TransactionId
testTransactionId = mockTransactionId (read "44444444-4444-4444-4444-444444444444")

-- | An existing account with a USD balance of 1000
existingAccount :: Account
existingAccount =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated
          { name = "Test Account",
            initialBalance = mockMoney 1000,
            by = testOwnerId,
            accountType = Regular defaultCash,
            overdraftLimit = Just (mockMoney 0)
          }
    ]

-- | An existing account with a USD balance of 0 (no overdraft)
zeroBalanceAccount :: Account
zeroBalanceAccount =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated
          { name = "Zero Account",
            initialBalance = mockMoney 0,
            by = testOwnerId,
            accountType = Regular defaultCash,
            overdraftLimit = Just (mockMoney 0)
          }
    ]

-- -----------------------------------------------------------------------------
-- ReverseAccountDebit Tests
-- -----------------------------------------------------------------------------

reverseAccountDebitSpec :: Spec
reverseAccountDebitSpec = describe "ReverseAccountDebit Command" $ do
  context "Given an existing account with positive balance" $ do
    describe "When issuing ReverseAccountDebit" $ do
      it "Then emits AccountDebitReversed" $ do
        let account = existingAccount
        let command =
              ReverseAccountDebitAccountCommand
                $ ReverseAccountDebit
                  { amount = mockMoney 200,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        case handleAccountCommand account command of
          Right [AccountDebitReversedAccountEvent reversed] -> do
            reversed.amount `shouldBe` mockMoney 200
            reversed.transactionId `shouldBe` testTransactionId
            reversed.at `shouldBe` testTimestamp
          Right events -> expectationFailure $ "Expected single AccountDebitReversed, got: " ++ show events
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given an existing account with zero balance" $ do
    describe "When issuing ReverseAccountDebit (would take balance positive)" $ do
      it "Then still emits AccountDebitReversed (no overdraft check on reversal)" $ do
        let account = zeroBalanceAccount
        let command =
              ReverseAccountDebitAccountCommand
                $ ReverseAccountDebit
                  { amount = mockMoney 100,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        case handleAccountCommand account command of
          Right [AccountDebitReversedAccountEvent _] -> pure ()
          Right events -> expectationFailure $ "Expected single AccountDebitReversed, got: " ++ show events
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given a default (uninitialised) account" $ do
    describe "When issuing ReverseAccountDebit" $ do
      it "Then returns AccountDoesNotExist" $ do
        let account = accountDefault
        let command =
              ReverseAccountDebitAccountCommand
                $ ReverseAccountDebit
                  { amount = mockMoney 100,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        handleAccountCommand account command `shouldBe` Left AccountDoesNotExist

-- -----------------------------------------------------------------------------
-- ReverseAccountCredit Tests
-- -----------------------------------------------------------------------------

reverseAccountCreditSpec :: Spec
reverseAccountCreditSpec = describe "ReverseAccountCredit Command" $ do
  context "Given an account where the reversal would take the balance negative" $ do
    describe "When issuing ReverseAccountCredit" $ do
      it "Then still emits AccountCreditReversed (no overdraft check on reversal)" $ do
        -- Account with zero balance; reversing a credit of 500 would normally
        -- be refused by an overdraft check, but reversal commands bypass it.
        let account = zeroBalanceAccount
        let command =
              ReverseAccountCreditAccountCommand
                $ ReverseAccountCredit
                  { amount = mockMoney 500,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        case handleAccountCommand account command of
          Right [AccountCreditReversedAccountEvent reversed] -> do
            reversed.amount `shouldBe` mockMoney 500
            reversed.transactionId `shouldBe` testTransactionId
            reversed.at `shouldBe` testTimestamp
          Right events -> expectationFailure $ "Expected single AccountCreditReversed, got: " ++ show events
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

  context "Given a default (uninitialised) account" $ do
    describe "When issuing ReverseAccountCredit" $ do
      it "Then returns AccountDoesNotExist" $ do
        let account = accountDefault
        let command =
              ReverseAccountCreditAccountCommand
                $ ReverseAccountCredit
                  { amount = mockMoney 100,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        handleAccountCommand account command `shouldBe` Left AccountDoesNotExist

-- -----------------------------------------------------------------------------
-- Currency Mismatch Tests
-- -----------------------------------------------------------------------------

reversalCurrencyMismatchSpec :: Spec
reversalCurrencyMismatchSpec = describe "CurrencyMismatch on reversal commands" $ do
  context "Given a USD account" $ do
    describe "When reversing a debit with EUR amount" $ do
      it "Then returns CurrencyMismatch" $ do
        let account = existingAccount
        let command =
              ReverseAccountDebitAccountCommand
                $ ReverseAccountDebit
                  { amount = mockMoneyWith EUR 100,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        handleAccountCommand account command `shouldBe` Left CurrencyMismatch

    describe "When reversing a credit with EUR amount" $ do
      it "Then returns CurrencyMismatch" $ do
        let account = existingAccount
        let command =
              ReverseAccountCreditAccountCommand
                $ ReverseAccountCredit
                  { amount = mockMoneyWith EUR 100,
                    transactionId = testTransactionId,
                    at = testTimestamp
                  }
        handleAccountCommand account command `shouldBe` Left CurrencyMismatch
