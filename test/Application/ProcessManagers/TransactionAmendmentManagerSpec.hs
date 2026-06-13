{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ProcessManagers.TransactionAmendmentManagerSpec
-- Description : Unit tests for the TransactionAmendmentManager saga.
--
-- Covers each row of spec §4.2's diff table plus the failure path:
--
--   * Amount-only, source/target larger ('LegDebitNewSource' +
--     'LegCreditNewTarget')
--   * Amount-only, source/target smaller ('LegReverseOldSource' +
--     'LegReverseOldTarget')
--   * Target-account swap (Reverse-old-target + Credit-new-target)
--   * Source-account swap (Debit-new-source + Reverse-old-source)
--   * Both accounts swap (full 4-leg ordering)
--   * Failure path: new-source debit rejection → 'FailTransactionAmendment'
module Application.ProcessManagers.TransactionAmendmentManagerSpec (spec) where

import Application.ProcessManagers.TransactionAmendmentManager
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Account.Commands
  ( CreditAccount (..),
    DebitAccount (..),
    ReverseAccountCredit (..),
    ReverseAccountDebit (..),
  )
import Domain.Account.Events
  ( AccountDebited (..),
  )
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    Money,
    TransactionId,
    TransactionType (..),
    UserId,
    unAccountId,
    unsafeAccountId,
    unsafeMoney,
    unsafeTransactionId,
    unsafeUserId,
  )
import Domain.Models
  ( AccountingCommand (..),
    AccountingEvent (..),
  )
import Domain.Transaction.Commands (FailTransactionAmendment (..))
import Domain.Transaction.Events (TransactionAmendmentInitiated (..), TransactionPostingInitiated (..))
import Eventium (ProcessManagerEffect (..), RejectionReason (..), StreamEvent (..), VersionedStreamEvent, emptyMetadata)
import Optics ((^.))
import RIO hiding (view, (^.))
import Test.Hspec
import Testkit.Helpers (mockDictionaryEntryId, singletonIncome)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

empty_ :: TransactionAmendmentManager
empty_ = TransactionAmendmentManager Map.empty Map.empty

sampleAt :: UTCTime
sampleAt = UTCTime (fromGregorian 2026 4 1) 0

txUuid :: UUID.UUID
txUuid = UUID.fromWords 1 0 0 1

txId :: TransactionId
txId = unsafeTransactionId txUuid

oldSrcUuid, oldTgtUuid, newSrcUuid, newTgtUuid :: UUID.UUID
oldSrcUuid = UUID.fromWords 10 0 0 1
oldTgtUuid = UUID.fromWords 20 0 0 1
newSrcUuid = UUID.fromWords 11 0 0 1
newTgtUuid = UUID.fromWords 21 0 0 1

oldSrc, oldTgt, newSrc, newTgt :: AccountId
oldSrc = unsafeAccountId oldSrcUuid
oldTgt = unsafeAccountId oldTgtUuid
newSrc = unsafeAccountId newSrcUuid
newTgt = unsafeAccountId newTgtUuid

userId_ :: UserId
userId_ = unsafeUserId (UUID.fromWords 4 0 0 4)

m :: Rational -> Money
m = unsafeMoney USD

-- | TransactionPostingInitiated seed event for a 100 USD same-currency transfer
-- from 'oldSrc' to 'oldTgt'.
seedInitiated :: VersionedStreamEvent AccountingEvent
seedInitiated =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransactionPostingInitiatedEvent
        TransactionPostingInitiated
          { sourceAccountId = oldSrc,
            targetAccountId = oldTgt,
            sourceAmount = m 100,
            targetAmount = m 100,
            exchangeRate = Nothing,
            description = "seed",
            by = userId_,
            at = sampleAt,
            transactionType = Transfer,
            externalTransactionId = Nothing,
            labels = Set.empty
          }
    )

-- | Category UUID used in 'seedIncomeInitiated'.
incomeCatUuid :: UUID.UUID
incomeCatUuid = UUID.fromWords 99 0 0 1

-- | TransactionPostingInitiated seed event for a 100 USD Income transaction
-- from 'oldSrc' (External) to 'oldTgt' (Regular).
seedIncomeInitiated :: VersionedStreamEvent AccountingEvent
seedIncomeInitiated =
  StreamEvent
    txUuid
    0
    (emptyMetadata "")
    ( TransactionPostingInitiatedEvent
        TransactionPostingInitiated
          { sourceAccountId = oldSrc,
            targetAccountId = oldTgt,
            sourceAmount = m 100,
            targetAmount = m 100,
            exchangeRate = Nothing,
            description = "income-seed",
            by = userId_,
            at = sampleAt,
            transactionType = singletonIncome (mockDictionaryEntryId incomeCatUuid) (m 100),
            externalTransactionId = Nothing,
            labels = Set.empty
          }
    )

mkAmendInitiated :: AccountId -> AccountId -> Money -> Money -> VersionedStreamEvent AccountingEvent
mkAmendInitiated newSrcA newTgtA newSrcAmt newTgtAmt =
  StreamEvent
    txUuid
    1
    (emptyMetadata "")
    ( TransactionAmendmentInitiatedEvent
        TransactionAmendmentInitiated
          { transactionId = txId,
            newSourceAccountId = newSrcA,
            newTargetAccountId = newTgtA,
            newSourceAmount = newSrcAmt,
            newTargetAmount = newTgtAmt,
            newExchangeRate = Nothing,
            newTransactionType = Transfer,
            by = userId_
          }
    )

-- | Like 'mkAmendInitiated' but allows specifying the post-amendment
-- 'TransactionType', for cross-kind amendment tests.
mkAmendInitiatedKind :: AccountId -> AccountId -> Money -> Money -> TransactionType -> VersionedStreamEvent AccountingEvent
mkAmendInitiatedKind newSrcA newTgtA newSrcAmt newTgtAmt kind =
  StreamEvent
    txUuid
    1
    (emptyMetadata "")
    ( TransactionAmendmentInitiatedEvent
        TransactionAmendmentInitiated
          { transactionId = txId,
            newSourceAccountId = newSrcA,
            newTargetAccountId = newTgtA,
            newSourceAmount = newSrcAmt,
            newTargetAmount = newTgtAmt,
            newExchangeRate = Nothing,
            newTransactionType = kind,
            by = userId_
          }
    )

-- | Unwrap 'AccountId' to its raw UUID.
acctUuid :: AccountId -> UUID.UUID
acctUuid = unAccountId

mkAccountDebited :: AccountId -> Money -> VersionedStreamEvent AccountingEvent
mkAccountDebited acct amt =
  StreamEvent
    (acctUuid acct)
    1
    (emptyMetadata "")
    ( AccountDebitedEvent
        AccountDebited {amount = amt, transactionId = txId}
    )

-- | Run the projection through the given events from the seed state.
runProjection :: [VersionedStreamEvent AccountingEvent] -> TransactionAmendmentManager
runProjection = foldl' handleTransactionAmendmentEvent empty_

spec :: Spec
spec = describe "TransactionAmendmentManager (Saga)" $ do
  describe "initial state"
    $ it "starts with empty maps"
    $ do
      Map.null (empty_ ^. #amendments) `shouldBe` True
      Map.null (empty_ ^. #currentPostings) `shouldBe` True

  describe "TransactionPostingInitiated tracking"
    $ it "records the current postings snapshot"
    $ do
      let st = runProjection [seedInitiated]
      Map.size (st ^. #currentPostings) `shouldBe` 1

  describe "Amount-only, source/target larger"
    $ it "issues LegDebitNewSource (fallible) only; the rest fire on AccountDebited"
    $ do
      let amend = mkAmendInitiated oldSrc oldTgt (m 150) (m 150)
          st = runProjection [seedInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation acctUuid_ (DebitAccountCommand debit) _ _] -> do
          acctUuid_ `shouldBe` acctUuid oldSrc
          debit.amount `shouldBe` m 50 -- delta
          debit.transactionId `shouldBe` txId
        _ -> expectationFailure "Expected IssueCommandWithCompensation(DebitAccount Δ)"

      -- After AccountDebited fires the rest: credit Δ on target + complete.
      let debited = mkAccountDebited oldSrc (m 50)
          st2 = handleTransactionAmendmentEvent st debited
          rest = reactToTransactionAmendmentEvent st2 debited
      length rest `shouldBe` 2
      case rest of
        [IssueCommand tgtUuid (CreditAccountCommand credit) _, IssueCommand txTarget (CompleteTransactionAmendmentCommand _) _] -> do
          tgtUuid `shouldBe` acctUuid oldTgt
          credit.amount `shouldBe` m 50
          txTarget `shouldBe` txUuid
        _ -> expectationFailure "Expected [CreditAccount Δ, CompleteTransactionAmendment]"

  describe "Amount-only, source/target smaller"
    $ it "issues ReverseAccountDebit + ReverseAccountCredit + Complete immediately"
    $ do
      let amend = mkAmendInitiated oldSrc oldTgt (m 60) (m 60)
          st = runProjection [seedInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      length effects `shouldBe` 3
      case effects of
        [ IssueCommand a1 (ReverseAccountCreditCommand rc) _,
          IssueCommand a2 (ReverseAccountDebitCommand rd) _,
          IssueCommand txT (CompleteTransactionAmendmentCommand _) _
          ] -> do
            a1 `shouldBe` acctUuid oldTgt
            rc.amount `shouldBe` m 40 -- target delta
            a2 `shouldBe` acctUuid oldSrc
            rd.amount `shouldBe` m 40 -- source delta
            txT `shouldBe` txUuid
        _ -> expectationFailure "Expected [ReverseCredit Δ, ReverseDebit Δ, Complete]"

  describe "Target account swap (source unchanged, amounts unchanged)"
    $ it "issues ReverseOldTarget + CreditNewTarget + Complete immediately"
    $ do
      let amend = mkAmendInitiated oldSrc newTgt (m 100) (m 100)
          st = runProjection [seedInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      length effects `shouldBe` 3
      case effects of
        [ IssueCommand a1 (ReverseAccountCreditCommand rc) _,
          IssueCommand a2 (CreditAccountCommand cr) _,
          IssueCommand _ (CompleteTransactionAmendmentCommand _) _
          ] -> do
            a1 `shouldBe` acctUuid oldTgt
            rc.amount `shouldBe` m 100
            a2 `shouldBe` acctUuid newTgt
            cr.amount `shouldBe` m 100
        _ -> expectationFailure "Expected [ReverseCredit old, Credit new, Complete]"

  describe "Source account swap (target unchanged, amounts unchanged)"
    $ it "issues DebitNewSource (fallible) → ReverseOldSource → Complete"
    $ do
      let amend = mkAmendInitiated newSrc oldTgt (m 100) (m 100)
          st = runProjection [seedInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation au (DebitAccountCommand d) _ _] -> do
          au `shouldBe` acctUuid newSrc
          d.amount `shouldBe` m 100
        _ -> expectationFailure "Expected DebitNewSource (fallible) only"

      let debited = mkAccountDebited newSrc (m 100)
          st2 = handleTransactionAmendmentEvent st debited
          rest = reactToTransactionAmendmentEvent st2 debited
      length rest `shouldBe` 2
      case rest of
        [IssueCommand a (ReverseAccountDebitCommand rd) _, IssueCommand _ (CompleteTransactionAmendmentCommand _) _] -> do
          a `shouldBe` acctUuid oldSrc
          rd.amount `shouldBe` m 100
        _ -> expectationFailure "Expected [ReverseDebit old, Complete]"

  describe "Both accounts swap (full 4-leg)"
    $ it "issues DebitNewSource → on debit success: ReverseOldTarget, ReverseOldSource, CreditNewTarget, Complete"
    $ do
      let amend = mkAmendInitiated newSrc newTgt (m 100) (m 100)
          st = runProjection [seedInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      length effects `shouldBe` 1

      let debited = mkAccountDebited newSrc (m 100)
          st2 = handleTransactionAmendmentEvent st debited
          rest = reactToTransactionAmendmentEvent st2 debited
      length rest `shouldBe` 4
      case rest of
        [ IssueCommand a1 (ReverseAccountCreditCommand rc) _,
          IssueCommand a2 (ReverseAccountDebitCommand rd) _,
          IssueCommand a3 (CreditAccountCommand cr) _,
          IssueCommand _ (CompleteTransactionAmendmentCommand _) _
          ] -> do
            a1 `shouldBe` acctUuid oldTgt
            rc.amount `shouldBe` m 100
            a2 `shouldBe` acctUuid oldSrc
            rd.amount `shouldBe` m 100
            a3 `shouldBe` acctUuid newTgt
            cr.amount `shouldBe` m 100
        _ -> expectationFailure "Expected 4-leg ordering"

  describe "Failure path"
    $ it "compensation on new-source debit rejection issues FailTransactionAmendment"
    $ do
      let amend = mkAmendInitiated newSrc oldTgt (m 100) (m 100)
          st = runProjection [seedInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      case effects of
        [IssueCommandWithCompensation _ _ _ onFail] -> do
          let comp = onFail (RejectionReason "Insufficient funds")
          length comp `shouldBe` 1
          case comp of
            [IssueCommand txT (FailTransactionAmendmentCommand (FailTransactionAmendment r)) _] -> do
              txT `shouldBe` txUuid
              r `shouldBe` "Insufficient funds"
            _ -> expectationFailure "Expected one FailTransactionAmendment effect"
        _ -> expectationFailure "Expected IssueCommandWithCompensation"

  describe "Cross-kind amendment: Income → Transfer (source endpoint swap)"
    $ it "diffAmendmentLegs is account-type-agnostic: External→Regular source swap produces DebitNewSource + ReverseOldSource"
    $ do
      -- Income posting: oldSrc (External) → oldTgt (Regular), 100 USD.
      -- Amendment: swap source to newSrc (Regular), kind becomes Transfer.
      -- Expected: DebitNewSource(newSrc) fallible leg + ReverseOldSource(oldSrc) non-fallible tail.
      let amend = mkAmendInitiatedKind newSrc oldTgt (m 100) (m 100) Transfer
          st = runProjection [seedIncomeInitiated, amend]
          effects = reactToTransactionAmendmentEvent st amend
      length effects `shouldBe` 1
      case effects of
        [IssueCommandWithCompensation au (DebitAccountCommand d) _ _] -> do
          au `shouldBe` acctUuid newSrc
          d.amount `shouldBe` m 100
          d.transactionId `shouldBe` txId
        _ -> expectationFailure "Expected IssueCommandWithCompensation(DebitNewSource newSrc)"

      -- After AccountDebited fires: ReverseOldSource(oldSrc) + Complete.
      let debited = mkAccountDebited newSrc (m 100)
          st2 = handleTransactionAmendmentEvent st debited
          rest = reactToTransactionAmendmentEvent st2 debited
      length rest `shouldBe` 2
      case rest of
        [IssueCommand a (ReverseAccountDebitCommand rd) _, IssueCommand _ (CompleteTransactionAmendmentCommand _) _] -> do
          a `shouldBe` acctUuid oldSrc
          rd.amount `shouldBe` m 100
        _ -> expectationFailure "Expected [ReverseDebit oldSrc, CompleteTransactionAmendment]"
