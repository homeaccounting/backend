{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.CommandHandlerPropertySpec
-- Description : Property-based tests for Transaction command handler
--
-- This module tests mathematical properties and invariants of the Transaction
-- aggregate command handler using QuickCheck.
--
-- Test Coverage:
--   - Determinism: Same input produces same output
--   - State machine: Valid transitions only
--   - Idempotency: Multiple commands don't change terminal states
--   - Validation: Business rules enforcement
module Domain.Transaction.CommandHandlerPropertySpec (spec) where

import Data.List.NonEmpty (nonEmpty)
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (UTCTime (..), fromGregorian)
import Domain.Core.Types
import Domain.Transaction
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding (fromMaybe, (^.))
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators (genLabelSet)
import Testkit.Helpers
import Prelude (read)

-- | Fixed business time used for test fixtures.
mockTime :: UTCTime
mockTime = UTCTime (fromGregorian 2026 4 1) 0

spec :: Spec
spec = do
  determinismSpec
  stateMachineSpec
  validationSpec
  allocationsSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get transaction state
applyEvents :: [TransactionEvent] -> Transaction
applyEvents = latestProjection transactionProjection

-- | Test user ID for initiating transfers
testUserId :: UserId
testUserId = mockUserId (read "11111111-1111-1111-1111-111111111111")

-- | Create a pending transaction
createPendingTransaction :: AccountId -> AccountId -> Money -> Transaction
createPendingTransaction fromId toId amt =
  applyEvents
    [ TransactionPostingInitiatedTransactionEvent
        $ TransactionPostingInitiated
          { sourceAccountId = fromId,
            targetAccountId = toId,
            sourceAmount = amt,
            targetAmount = amt,
            exchangeRate = Nothing,
            description = "Test transfer",
            by = testUserId,
            at = mockTime,
            transactionType = Transfer,
            externalTransactionId = Nothing,
            labels = Set.empty
          }
    ]

-- -----------------------------------------------------------------------------
-- Determinism Properties
-- -----------------------------------------------------------------------------

determinismSpec :: Spec
determinismSpec = describe "Determinism Properties" $ do
  describe "When handling commands" $ do
    it "Then InitiateTransaction produces same events"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) ->
        fromId /= toId && unMoney amt > 0 ==>
          let transaction = applyEvents []
              command = InitiateTransactionTransactionCommand $ InitiateTransaction fromId toId amt amt Nothing rsn testUserId mockTime Transfer Nothing Set.empty
              events1 = handleTransactionCommand transaction command
              events2 = handleTransactionCommand transaction command
           in events1 === events2

    it "Then InitiateTransaction preserves labels and externalTransactionId"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) (extRaw :: Text) ->
        fromId /= toId && unMoney amt > 0 && not (T.null extRaw) ==>
          forAll genLabelSet
            $ \labels ->
              let transaction = applyEvents []
                  extTxId = unsafeExternalTransactionId extRaw
                  command = InitiateTransactionTransactionCommand $ InitiateTransaction fromId toId amt amt Nothing rsn testUserId mockTime Transfer (Just extTxId) labels
               in case handleTransactionCommand transaction command of
                    Right (TransactionPostingInitiatedTransactionEvent initiated : _) ->
                      initiated.labels === labels
                        .&&. initiated.externalTransactionId === Just extTxId
                    Right _ -> counterexample "Expected TransactionPostingInitiated event first" False
                    Left e -> counterexample ("Expected Right, got: " ++ show e) False

    it "Then CompleteTransactionPosting produces same events"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              command = CompleteTransactionPostingTransactionCommand CompleteTransactionPosting
              events1 = handleTransactionCommand transaction command
              events2 = handleTransactionCommand transaction command
           in events1 === events2

    it "Then FailTransactionPosting produces same events"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              command = FailTransactionPostingTransactionCommand $ FailTransactionPosting rsn
              events1 = handleTransactionCommand transaction command
              events2 = handleTransactionCommand transaction command
           in events1 === events2

-- -----------------------------------------------------------------------------
-- State Machine Properties
-- -----------------------------------------------------------------------------

stateMachineSpec :: Spec
stateMachineSpec = describe "State Machine Properties" $ do
  describe "Terminal state immutability" $ do
    it "Then Completed transaction ignores all commands"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let initialEvents =
                [ TransactionPostingInitiatedTransactionEvent $ TransactionPostingInitiated fromId toId amt amt Nothing "Test" testUserId mockTime Transfer Nothing Set.empty,
                  TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
                ]
              transaction = applyEvents initialEvents

              -- Try to complete again
              result1 = handleTransactionCommand transaction (CompleteTransactionPostingTransactionCommand CompleteTransactionPosting)

              -- Try to fail
              result2 = handleTransactionCommand transaction (FailTransactionPostingTransactionCommand $ FailTransactionPosting "Too late")
           in isLeft result1 .&&. isLeft result2

    it "Then Failed transaction ignores all commands"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let initialEvents =
                [ TransactionPostingInitiatedTransactionEvent $ TransactionPostingInitiated fromId toId amt amt Nothing "Test" testUserId mockTime Transfer Nothing Set.empty,
                  TransactionPostingFailedTransactionEvent $ TransactionPostingFailed "Error"
                ]
              transaction = applyEvents initialEvents

              -- Try to complete
              result1 = handleTransactionCommand transaction (CompleteTransactionPostingTransactionCommand CompleteTransactionPosting)

              -- Try to fail again
              result2 = handleTransactionCommand transaction (FailTransactionPostingTransactionCommand $ FailTransactionPosting "Another error")
           in isLeft result1 .&&. isLeft result2

  describe "Valid transitions" $ do
    it "Then Pending can transition to Completed"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              result = handleTransactionCommand transaction (CompleteTransactionPostingTransactionCommand CompleteTransactionPosting)
           in case result of
                Right [TransactionPostingCompletedTransactionEvent _] -> property True
                _ -> property False

    it "Then Pending can transition to Failed"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) (rsn :: Text) ->
        fromId /= toId ==>
          let transaction = createPendingTransaction fromId toId amt
              result = handleTransactionCommand transaction (FailTransactionPostingTransactionCommand $ FailTransactionPosting rsn)
           in case result of
                Right [TransactionPostingFailedTransactionEvent _] -> property True
                _ -> property False

  describe "Status tracking" $ do
    it "Then new transaction starts in default state"
      $ property
      $ \(_ :: ()) ->
        let transaction = applyEvents []
         in transaction ^. #status === Pending
              .&&. unMoney (transaction ^. #sourceAmount) === 0

    it "Then initiated transaction is Pending"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId && unMoney amt > 0 ==>
          let transaction = createPendingTransaction fromId toId amt
           in transaction ^. #status === Pending

-- -----------------------------------------------------------------------------
-- Validation Properties
-- -----------------------------------------------------------------------------

validationSpec :: Spec
validationSpec = describe "Validation Properties" $ do
  describe "InitiateTransaction validation" $ do
    it "Then rejects same source and target"
      $ property
      $ \(accountId :: AccountId) (amt :: Money) ->
        unMoney amt > 0 ==>
          let transaction = applyEvents []
              command = InitiateTransactionTransactionCommand $ InitiateTransaction accountId accountId amt amt Nothing "Self-transfer" testUserId mockTime Transfer Nothing Set.empty
              result = handleTransactionCommand transaction command
           in isLeft result

    it "Then rejects zero amount"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) ->
        fromId /= toId ==>
          let transaction = applyEvents []
              command = InitiateTransactionTransactionCommand $ InitiateTransaction fromId toId (mockMoney 0) (mockMoney 0) Nothing "Zero" testUserId mockTime Transfer Nothing Set.empty
              result = handleTransactionCommand transaction command
           in isLeft result

    it "Then accepts valid transfer"
      $ property
      $ \(fromId :: AccountId) (toId :: AccountId) (amt :: Money) ->
        fromId /= toId && unMoney amt > 0 ==>
          let transaction = applyEvents []
              command = InitiateTransactionTransactionCommand $ InitiateTransaction fromId toId amt amt Nothing "Valid" testUserId mockTime Transfer Nothing Set.empty
              result = handleTransactionCommand transaction command
           in case result of
                Right [TransactionPostingInitiatedTransactionEvent _] -> property True
                _ -> property False

  describe "Double initialization prevention" $ do
    it "Then ignores second InitiateTransaction"
      $ property
      $ \(fromId1 :: AccountId)
         (toId1 :: AccountId)
         (amount1 :: Money)
         (fromId2 :: AccountId)
         (toId2 :: AccountId)
         (amount2 :: Money) ->
          fromId1 /= toId1 && fromId2 /= toId2 ==>
            let transaction = createPendingTransaction fromId1 toId1 amount1
                command = InitiateTransactionTransactionCommand $ InitiateTransaction fromId2 toId2 amount2 amount2 Nothing "Second" testUserId mockTime Transfer Nothing Set.empty
                result = handleTransactionCommand transaction command
             in isLeft result

-- -----------------------------------------------------------------------------
-- Allocation Invariant Properties
-- -----------------------------------------------------------------------------

-- | Build a Completed transaction whose 'transactionType' is the supplied
-- 'TransactionType'. The source/target amounts are derived from the type's
-- categorised total when defined (so the existing allocations sum equals
-- the categorised side), and from a default mock amount otherwise.
completedTxWithType :: AccountId -> AccountId -> TransactionType -> Transaction
completedTxWithType fromId toId tt =
  let amt = case allocationsOf tt >>= (nonEmpty . allAllocations) of
        Just xs@(first :| _) ->
          Money (sum [a.amount.amount | a <- toList xs]) (moneyCurrency first.amount)
        Nothing -> mockMoney 100
   in applyEvents
        [ TransactionPostingInitiatedTransactionEvent
            $ TransactionPostingInitiated
              { sourceAccountId = fromId,
                targetAccountId = toId,
                sourceAmount = amt,
                targetAmount = amt,
                exchangeRate = Nothing,
                description = "Test",
                by = testUserId,
                at = mockTime,
                transactionType = tt,
                externalTransactionId = Nothing,
                labels = Set.empty
              },
          TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
        ]

-- | A 'TransactionType' that is Income or Expense (i.e. has allocations).
newtype CategorisedTransactionType = CategorisedTransactionType {unCategorised :: TransactionType}
  deriving (Show)

instance Arbitrary CategorisedTransactionType where
  arbitrary =
    CategorisedTransactionType
      <$> ( arbitrary
              `suchThat` (\tt -> kindOf tt == IncomeKind || kindOf tt == ExpenseKind)
          )

-- | A 'TransactionType' that is uncategorised (Transfer or Adjustment).
newtype UncategorisedTransactionType = UncategorisedTransactionType {unUncategorised :: TransactionType}
  deriving (Show)

instance Arbitrary UncategorisedTransactionType where
  arbitrary = UncategorisedTransactionType <$> elements [Transfer, Adjustment]

allocationsSpec :: Spec
allocationsSpec = describe "Allocation invariants" $ do
  describe "SetTransactionAllocations" $ do
    it "rejects when issued against an uncategorised transaction"
      $ property
      $ \(fromId :: AccountId)
         (toId :: AccountId)
         (UncategorisedTransactionType existingType)
         (CategorisedTransactionType newType) ->
          fromId /= toId ==>
            let tx = completedTxWithType fromId toId existingType
                txId = mockTransactionId (read "11111111-1111-1111-1111-111111111111")
                newAllocs = case allocationsOf newType of
                  Just xs -> xs
                  Nothing -> error "CategorisedTransactionType invariant violated"
                cmd = SetTransactionAllocations txId newAllocs
                result = handleTransactionCommand tx (SetTransactionAllocationsTransactionCommand cmd)
             in result === Left CannotSetAllocationsOnUncategorisedTransaction

-- The earlier "kind preservation" property was removed in the allocations
-- tightening (2026-05-30): 'SetTransactionAllocations' now carries only
-- a 'NonEmpty Allocation', so the surrounding kind is structurally
-- preserved by the command shape — there is no incoming kind that could
-- mismatch the existing one.
--
-- Kind-preservation and sum-against-new-amount tests for 'AmendTransaction'
-- were removed in the earlier @newTransactionType@ rollback: 'AmendTransaction'
-- no longer carries allocations. Kind preservation is structurally
-- enforced by 'AccountType' invariants at the service layer, and
-- proportional rescaling of allocations on categorised-amount change is
-- exercised by the projection tests.
