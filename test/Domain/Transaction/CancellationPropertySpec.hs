{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.CancellationPropertySpec
-- Description : Property-based tests for the cancellation command handler and projection.
--
-- Verifies the invariants from the cancellation design spec:
--
--   * The command handler is pure and deterministic: applying the same command
--     to the same state always produces the same result.
--   * Once a transaction reaches the 'Cancelled' terminal state, no event
--     handler transitions away from it (status monotonicity).
--   * The @cancellationInProgress@ flag is @True@ after
--     'TransactionCancellationInitiated' and @False@ (with status 'Cancelled')
--     after 'TransactionCancellationCompleted' (bracket invariant).
module Domain.Transaction.CancellationPropertySpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    ExchangeRate,
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    unsafeAccountId,
    unsafeDictionaryEntryId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    handleTransactionCommand,
  )
import Domain.Transaction.Commands
  ( CancelTransaction (..),
    CompleteTransactionCancellation (..),
  )
import Domain.Transaction.Events
  ( TransactionAmendmentCompleted (..),
    TransactionAmendmentFailed (..),
    TransactionAmendmentInitiated (..),
    TransactionCancellationCompleted (..),
    TransactionCancellationInitiated (..),
    TransactionPostingCompleted (..),
    TransactionPostingFailed (..),
    TransactionPostingInitiated (..),
  )
import Domain.Transaction.Projection
  ( Transaction,
    TransactionEvent (..),
    TransactionStatus (..),
    transactionDefault,
    transactionProjection,
  )
import Eventium (Projection (..), latestProjection)
import Optics ((&), (.~), (^.))
import RIO hiding ((&), (.~), (^.))
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.Generators ()
import Testkit.Helpers (singletonIncome)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

txId :: TransactionId
txId = unsafeTransactionId (UUID.fromWords 55 0 0 0)

cancelledByU :: UserId
cancelledByU = unsafeUserId (UUID.fromWords 7 0 0 0)

-- Fixed seed posting facts used to build a known-completed transaction via
-- the projection fold.  Must be non-nil so the smart constructors accept them.
seedSrc :: AccountId
seedSrc = unsafeAccountId (UUID.fromWords 11 0 0 0)

seedTgt :: AccountId
seedTgt = unsafeAccountId (UUID.fromWords 12 0 0 0)

seedSrcAmt :: Money
seedSrcAmt = unsafeMoney USD 100

seedTgtAmt :: Money
seedTgtAmt = unsafeMoney USD 100

seedTransactionType :: TransactionType
seedTransactionType = singletonIncome (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)) seedTgtAmt

seedBy :: UserId
seedBy = unsafeUserId (UUID.fromWords 2 0 0 0)

-- | A completed transaction with both saga flags False — the valid base state
-- for issuing a 'CancelTransaction' command.
--
-- Built directly by record update so it can be used as a simple, readable
-- fixture.  'completedViaProjection' provides an alternative construction path
-- for the path-independence property.
completedBase :: Transaction
completedBase =
  transactionDefault
    & #status
    .~ Completed
    & #amendmentInProgress
    .~ False
    & #cancellationInProgress
    .~ False

-- | A completed transaction built by folding 'TransactionPostingInitiated' +
-- 'TransactionPostingCompleted' through the projection — matching 'completedBase' in
-- the fields the cancellation handler actually inspects (status, both flags).
-- Used to verify that the handler result is path-independent.
completedViaProjection :: Transaction
completedViaProjection =
  latestProjection
    transactionProjection
    [ TransactionPostingInitiatedTransactionEvent
        TransactionPostingInitiated
          { sourceAccountId = seedSrc,
            targetAccountId = seedTgt,
            sourceAmount = seedSrcAmt,
            targetAmount = seedTgtAmt,
            exchangeRate = Nothing,
            description = "seed",
            by = seedBy,
            at = transactionDefault ^. #at,
            transactionType = seedTransactionType,
            importInfo = Nothing,
            labels = Set.empty
          },
      TransactionPostingCompletedTransactionEvent TransactionPostingCompleted
    ]

-- | Apply a list of events on top of an existing 'Transaction' state.
--
-- We keep this helper (rather than always using 'latestProjection' from a
-- seed) because several properties need to start from 'completedBase' — a
-- state built via record-update rather than from the projection's default
-- seed.  'latestProjection' always folds from 'projectionSeed', so it cannot
-- represent an arbitrary mid-stream base.  The helper is a thin wrapper
-- around the projection's step function and carries no additional logic.
applyEventsTo :: Transaction -> [TransactionEvent] -> Transaction
applyEventsTo = foldl' step
  where
    -- Pattern-match on the Projection constructor to extract the event handler.
    step tx evt = let Projection _ handler = transactionProjection in handler tx evt

-- | The two cancellation events used in multiple properties below.
initiatedEvt :: TransactionEvent
initiatedEvt =
  TransactionCancellationInitiatedTransactionEvent
    TransactionCancellationInitiated
      { transactionId = txId,
        by = cancelledByU
      }

completedEvt :: TransactionEvent
completedEvt =
  TransactionCancellationCompletedTransactionEvent
    TransactionCancellationCompleted
      { transactionId = txId,
        by = cancelledByU
      }

-- | A transaction that has reached the 'Cancelled' terminal state.
cancelledTx :: Transaction
cancelledTx = applyEventsTo completedBase [initiatedEvt, completedEvt]

-- -----------------------------------------------------------------------------
-- Generators
-- -----------------------------------------------------------------------------

-- | Generator for a 'CancelTransaction' command using an arbitrary user.
genCancelTransaction :: Gen TransactionCommand
genCancelTransaction = do
  uid <- arbitrary :: Gen UserId
  pure
    $ CancelTransactionTransactionCommand
      CancelTransaction
        { transactionId = txId,
          by = uid
        }

-- | Generator for a 'CompleteTransactionCancellation' command using an arbitrary user.
genCompleteTransactionCancellation :: Gen TransactionCommand
genCompleteTransactionCancellation = do
  uid <- arbitrary :: Gen UserId
  pure
    $ CompleteTransactionCancellationTransactionCommand
      CompleteTransactionCancellation
        { transactionId = txId,
          by = uid
        }

-- | Generator for either cancellation command.
genAnyCancellationCommand :: Gen TransactionCommand
genAnyCancellationCommand =
  oneof
    [ genCancelTransaction,
      genCompleteTransactionCancellation
    ]

-- | Newtype wrapper for either cancellation command.
newtype AnyCancellationCommand = AnyCancellationCommand {unCmd :: TransactionCommand}

instance Show AnyCancellationCommand where
  show (AnyCancellationCommand cmd) = case cmd of
    CancelTransactionTransactionCommand _ -> "AnyCancellationCommand{CancelTransaction}"
    CompleteTransactionCancellationTransactionCommand _ -> "AnyCancellationCommand{CompleteTransactionCancellation}"
    _ -> "AnyCancellationCommand{other}"

instance Arbitrary AnyCancellationCommand where
  arbitrary = AnyCancellationCommand <$> genAnyCancellationCommand

-- | Generator for a 'TransactionAmendmentInitiated' event with arbitrary
-- posting fields, so we exercise the full range of projection arms in the
-- monotonicity property.
genAmendmentInitiatedEvt :: Gen TransactionEvent
genAmendmentInitiatedEvt = do
  newSrc <- arbitrary :: Gen AccountId
  newTgt <- arbitrary :: Gen AccountId
  newSrcAmt <- arbitrary :: Gen Money
  newTgtAmt <- arbitrary :: Gen Money
  newRate <- oneof [pure Nothing, Just <$> (arbitrary :: Gen ExchangeRate)]
  uid <- arbitrary :: Gen UserId
  pure
    $ TransactionAmendmentInitiatedTransactionEvent
      TransactionAmendmentInitiated
        { transactionId = txId,
          newSourceAccountId = newSrc,
          newTargetAccountId = newTgt,
          newSourceAmount = newSrcAmt,
          newTargetAmount = newTgtAmt,
          newExchangeRate = newRate,
          newTransactionType = Transfer,
          by = uid
        }

-- | Generator for a 'TransactionAmendmentCompleted' event with arbitrary
-- posting fields, mirroring 'genAmendmentInitiatedEvt'.
genAmendmentCompletedEvt :: Gen TransactionEvent
genAmendmentCompletedEvt = do
  newSrc <- arbitrary :: Gen AccountId
  newTgt <- arbitrary :: Gen AccountId
  newSrcAmt <- arbitrary :: Gen Money
  newTgtAmt <- arbitrary :: Gen Money
  newRate <- oneof [pure Nothing, Just <$> (arbitrary :: Gen ExchangeRate)]
  uid <- arbitrary :: Gen UserId
  pure
    $ TransactionAmendmentCompletedTransactionEvent
      TransactionAmendmentCompleted
        { transactionId = txId,
          newSourceAccountId = newSrc,
          newTargetAccountId = newTgt,
          newSourceAmount = newSrcAmt,
          newTargetAmount = newTgtAmt,
          newExchangeRate = newRate,
          newTransactionType = seedTransactionType,
          by = uid
        }

-- | Newtype wrapper for 'TransactionEvent'.  Covers all projection arms that
-- could conceivably be applied after a transaction is cancelled (cancellation
-- events, amendment events, and the completion / failure events).
newtype AnyTransactionEvent = AnyTransactionEvent {unEvt :: TransactionEvent}
  deriving (Show)

instance Arbitrary AnyTransactionEvent where
  arbitrary =
    AnyTransactionEvent
      <$> oneof
        [ pure initiatedEvt,
          pure completedEvt,
          -- Amendment saga events — exercise the amendment projection arms.
          genAmendmentInitiatedEvt,
          genAmendmentCompletedEvt,
          pure (TransactionAmendmentFailedTransactionEvent (TransactionAmendmentFailed "reason")),
          -- Core transfer events.
          pure (TransactionPostingCompletedTransactionEvent TransactionPostingCompleted),
          pure (TransactionPostingFailedTransactionEvent (TransactionPostingFailed "reason"))
        ]

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Transaction cancellation handler and projection" $ do
  prop "handler result depends only on state, not on construction path"
    $ \(cmd :: AnyCancellationCommand) ->
      -- Two transactions that agree on the fields the cancellation handler
      -- inspects (status = Completed, both saga flags False) must produce the
      -- same handler result regardless of how they were constructed.
      --   tx1 — built via record-update (direct fixture)
      --   tx2 — built by folding TransactionPostingInitiated + TransactionPostingCompleted through
      --          the projection
      -- If the handler ever accidentally branches on a field it should ignore
      -- (e.g. description, at, initiatedBy), QuickCheck will find a counter-
      -- example because tx1 and tx2 differ in those irrelevant fields.
      let result1 = handleTransactionCommand completedBase cmd.unCmd
          result2 = handleTransactionCommand completedViaProjection cmd.unCmd
       in result1 === result2

  prop "status monotonicity: Cancelled is a terminal state — no event escapes it"
    $ \(wrappedEvt :: AnyTransactionEvent) ->
      -- After reaching the Cancelled state, applying any further event must
      -- leave the status unchanged.
      let afterOneMore = applyEventsTo cancelledTx [wrappedEvt.unEvt]
       in (afterOneMore ^. #status) === Cancelled

  prop "cancellationInProgress bracket: True after Initiated, False+Cancelled after Completed"
    $ \(uid :: UserId) (tid :: TransactionId) ->
      -- The bracket invariant must hold for *any* user / transaction identity,
      -- not just the hard-coded fixture values.
      let initiatedE =
            TransactionCancellationInitiatedTransactionEvent
              TransactionCancellationInitiated
                { transactionId = tid,
                  by = uid
                }
          completedE =
            TransactionCancellationCompletedTransactionEvent
              TransactionCancellationCompleted
                { transactionId = tid,
                  by = uid
                }
          afterInit = applyEventsTo completedBase [initiatedE]
          afterFull = applyEventsTo completedBase [initiatedE, completedE]
       in conjoin
            [ (afterInit ^. #cancellationInProgress) === True,
              (afterFull ^. #cancellationInProgress) === False,
              (afterFull ^. #status) === Cancelled
            ]
