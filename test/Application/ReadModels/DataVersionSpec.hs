{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.DataVersionSpec
-- Description : Unit tests for the pure event -> 'EventScope' classifier.
--
-- Covers the representative shapes 'classifyEvent' must distinguish: a plain
-- account lifecycle event (stream-key-only), 'AccountAccessRevoked' (which
-- additionally surfaces the revoked user), a two-account transaction posting
-- event, a transaction field edit that only carries a 'TransactionId', and a
-- pure saga/system signal that carries no standalone user-visible change.
module Application.ReadModels.DataVersionSpec (spec) where

import Application.ReadModels.DataVersion
  ( EventScope (..),
    classifyEvent,
    emptyScope,
  )
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountAccessRevoked (..),
    AccountRenamed (..),
  )
import Domain.Core.Types
  ( AccountId,
    RelationKind (Refund),
    TransactionId,
    TransactionType (Transfer),
    UserId,
    mkTransactionIdSafe,
  )
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events
  ( TransactionAmendmentInitiated (..),
    TransactionDescriptionChanged (..),
    TransactionMergeInitiated (..),
    TransactionPostingCompleted (..),
    TransactionPostingInitiated (..),
    TransactionRelationAdded (..),
  )
import RIO
import Test.Hspec
import Testkit.Helpers
  ( fixtureTime,
    mockAccountId,
    mockMoney,
    mockTransactionId,
    mockUserId,
  )

acctA, acctB, acctC, acctD :: AccountId
acctA = mockAccountId (UUID.fromWords 1 0 0 0)
acctB = mockAccountId (UUID.fromWords 2 0 0 0)
acctC = mockAccountId (UUID.fromWords 4 0 0 0)
acctD = mockAccountId (UUID.fromWords 5 0 0 0)

userA, userB :: UserId
userA = mockUserId (UUID.fromWords 0xa 0 0 0)
userB = mockUserId (UUID.fromWords 0xb 0 0 0)

txA :: TransactionId
txA = mockTransactionId (UUID.fromWords 3 0 0 0)

spec :: Spec
spec = describe "classifyEvent" $ do
  it "maps an account lifecycle event to its stream-key account" $ do
    let streamKey = UUID.fromWords 1 0 0 0
        event = AccountRenamedEvent (AccountRenamed {newName = "Checking", by = userA})
    classifyEvent streamKey event
      `shouldBe` emptyScope {directAccounts = [acctA]}

  it "maps AccountAccessRevoked to the account and the revoked user" $ do
    let streamKey = UUID.fromWords 1 0 0 0
        event = AccountAccessRevokedEvent (AccountAccessRevoked {userId = userB, by = userA})
    classifyEvent streamKey event
      `shouldBe` emptyScope {directAccounts = [acctA], extraUsers = [userB]}

  it "maps TransactionPostingInitiated to both source and target accounts" $ do
    let streamKey = UUID.fromWords 3 0 0 0
        event =
          TransactionPostingInitiatedEvent
            TransactionPostingInitiated
              { sourceAccountId = acctA,
                targetAccountId = acctB,
                sourceAmount = mockMoney 100,
                targetAmount = mockMoney 100,
                exchangeRate = Nothing,
                description = "rent",
                by = userA,
                at = fixtureTime,
                transactionType = Transfer,
                importInfo = Nothing,
                labels = mempty,
                contactId = Nothing
              }
    classifyEvent streamKey event
      `shouldBe` emptyScope {directAccounts = [acctA, acctB]}

  it "maps a transaction field edit to viaTransaction using the payload's transactionId" $ do
    let streamKey = UUID.fromWords 3 0 0 0
        event =
          TransactionDescriptionChangedEvent
            TransactionDescriptionChanged {transactionId = txA, newDescription = "new"}
    classifyEvent streamKey event
      `shouldBe` emptyScope {viaTransaction = Just txA}

  it "maps TransactionAmendmentInitiated to both new-leg accounts" $ do
    let streamKey = UUID.fromWords 3 0 0 0
        event =
          TransactionAmendmentInitiatedEvent
            TransactionAmendmentInitiated
              { transactionId = txA,
                newSourceAccountId = acctC,
                newTargetAccountId = acctD,
                newSourceAmount = mockMoney 100,
                newTargetAmount = mockMoney 100,
                newExchangeRate = Nothing,
                newTransactionType = Transfer,
                contactId = Nothing,
                allowOverdraft = False,
                by = userA
              }
    classifyEvent streamKey event
      `shouldBe` emptyScope {directAccounts = [acctC, acctD]}

  it "maps TransactionMergeInitiated to both new-leg accounts" $ do
    let streamKey = UUID.fromWords 3 0 0 0
        event =
          TransactionMergeInitiatedEvent
            TransactionMergeInitiated
              { newSourceAccountId = acctC,
                newTargetAccountId = acctD,
                newSourceAmount = mockMoney 100,
                newTargetAmount = mockMoney 100,
                newExchangeRate = Nothing,
                newAllocations = Nothing,
                newTransactionType = Transfer,
                contactId = Nothing,
                sourceTransactionIds = [],
                by = userA
              }
    classifyEvent streamKey event
      `shouldBe` emptyScope {directAccounts = [acctC, acctD]}

  it "maps TransactionRelationAdded to the transaction parsed from the stream key, not the payload" $ do
    -- The "from" endpoint is the stream key; 'relatedTransactionId' is the
    -- unrelated "to" endpoint and must NOT be what we signal on.
    let streamKey = UUID.fromWords 7 0 0 0
        event =
          TransactionRelationAddedEvent
            TransactionRelationAdded
              { relatedTransactionId = txA,
                relationKind = Refund
              }
    classifyEvent streamKey event
      `shouldBe` emptyScope {viaTransaction = mkTransactionIdSafe streamKey}

  it "maps a pure saga/system signal to emptyScope" $ do
    let streamKey = UUID.fromWords 3 0 0 0
        event = TransactionPostingCompletedEvent TransactionPostingCompleted
    classifyEvent streamKey event `shouldBe` emptyScope
