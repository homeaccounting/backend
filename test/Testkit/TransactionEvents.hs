{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.TransactionEvents
-- Description : Shared builders for transaction 'GlobalStreamEvent's.
--
-- The persistent Transaction read-model specs seed by feeding synthesized
-- 'GlobalStreamEvent's through the read model's own apply function. These
-- builders are the single source for those events so the specs don't each carry
-- a copy. Amounts/actor are fixed (the list/filter/isolation specs don't assert
-- on them); the transaction type, labels, and dates are parameters.
module Testkit.TransactionEvents
  ( postingInitiatedGlobal,
    transactionEditGlobal,
  )
where

import Data.Time (UTCTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    ContactId,
    Currency (..),
    LabelId,
    TransactionId,
    TransactionType,
    unTransactionId,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..), TransactionPostingInitiated (..))
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..), emptyMetadata)
import qualified Eventium
import RIO
import Testkit.Helpers (globalEvent, mockUserId)

-- | A 'TransactionPostingInitiated' wrapped as a 'GlobalStreamEvent', with the
-- given type, labels, and optional contact. @businessAt@ is the payload's
-- @at@; @persistedAt@ is the metadata @createdAt@ (they differ for
-- backdated-transaction tests).
postingInitiatedGlobal ::
  TransactionId ->
  AccountId ->
  AccountId ->
  TransactionType ->
  Set LabelId ->
  UTCTime -> -- business at (payload)
  UTCTime -> -- persisted at (metadata createdAt)
  SequenceNumber ->
  Maybe ContactId ->
  GlobalStreamEvent AccountingEvent
postingInitiatedGlobal txId src tgt tt labelSet businessAt persistedAt seqNo contact =
  let inner =
        StreamEvent
          (unTransactionId txId)
          0
          ((emptyMetadata "TransactionPostingInitiated") {Eventium.createdAt = Just persistedAt})
          ( TransactionPostingInitiatedEvent
              TransactionPostingInitiated
                { sourceAccountId = src,
                  targetAccountId = tgt,
                  sourceAmount = unsafeMoney USD 100,
                  targetAmount = unsafeMoney USD 100,
                  exchangeRate = Nothing,
                  description = "seed",
                  by = mockUserId (UUID.fromWords 9 0 0 0),
                  at = businessAt,
                  transactionType = tt,
                  importInfo = Nothing,
                  labels = labelSet,
                  contactId = contact
                }
          )
   in StreamEvent () seqNo (emptyMetadata "TransactionPostingInitiated") inner

-- | A subsequent edit/terminal event (description, date, labels, status,
-- cancellation, …) wrapped as a 'GlobalStreamEvent' targeting @txId@'s stream.
transactionEditGlobal ::
  TransactionId ->
  AccountingEvent ->
  SequenceNumber ->
  GlobalStreamEvent AccountingEvent
transactionEditGlobal txId = globalEvent (unTransactionId txId) 1
