{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.BankImport.TransferPairing
-- Description : Pure detection of internal transfers between two linked accounts.
--
-- When a user links two of their own accounts and imports from both, an
-- internal transfer appears on BOTH statements — a debit on one account and a
-- credit on the other. This engine pairs those two legs so the import sink can
-- post a single 'Transfer' instead of a double-booked income + expense.
--
-- The "same movement?" decision is delegated to a provider-supplied
-- 'TransferMatcher' (default: a heuristic). This engine owns the
-- provider-independent invariants: legs must resolve to DIFFERENT LOCAL
-- accounts, pairing is one-to-one, and collisions resolve deterministically.
module Application.Services.BankImport.TransferPairing
  ( InternalTransfer,
    debitLocalAccount,
    creditLocalAccount,
    debitLeg,
    creditLeg,
    pairInternalTransfers,
  )
where

import Domain.Banking.Types (ExternalAccountId)
import Domain.Core.Types (AccountId)
import Infrastructure.Banking.Provider (BankTransaction (..), TransferMatcher (..))
import RIO
import RIO.List (sortBy)

data InternalTransfer = InternalTransfer
  { debitLocalAccount' :: AccountId,
    creditLocalAccount' :: AccountId,
    debitLeg' :: BankTransaction,
    creditLeg' :: BankTransaction
  }
  deriving (Show, Eq)

debitLocalAccount :: InternalTransfer -> AccountId
debitLocalAccount t = t.debitLocalAccount'

creditLocalAccount :: InternalTransfer -> AccountId
creditLocalAccount t = t.creditLocalAccount'

debitLeg :: InternalTransfer -> BankTransaction
debitLeg t = t.debitLeg'

creditLeg :: InternalTransfer -> BankTransaction
creditLeg t = t.creditLeg'

pairInternalTransfers ::
  TransferMatcher ->
  [(ExternalAccountId, AccountId, BankTransaction)] ->
  ([InternalTransfer], [(ExternalAccountId, AccountId, BankTransaction)])
pairInternalTransfers (TransferMatcher matches) entries =
  go (sortByStable entries) [] []
  where
    sortByStable = sortBy (comparing (\(_, _, tx) -> (tx.time, tx.externalId)))

    go [] pairs leftover = (reverse pairs, reverse leftover)
    go (e : rest) pairs leftover =
      case findPartner e rest of
        Just (partner, rest') -> go rest' (mkTransfer e partner : pairs) leftover
        Nothing -> go rest pairs (e : leftover)

    findPartner e = pick []
      where
        pick _ [] = Nothing
        pick seen (c : cs)
          | isPair e c = Just (c, reverse seen <> cs)
          | otherwise = pick (c : seen) cs

    -- Engine invariant: legs must resolve to DIFFERENT LOCAL accounts (one
    -- local account can own multiple cards). Everything else is the matcher.
    isPair (_, localX, a) (_, localY, b) = localX /= localY && matches a b

    -- Precondition: the 'TransferMatcher' has already guaranteed opposite
    -- signs (all built-in matchers enforce @signum a /= signum b@); orientation
    -- keys on amount sign.
    mkTransfer (_, localX, txX) (_, localY, txY) =
      let ((dl, dtx), (cl, ctx)) =
            if txX.amount < 0
              then ((localX, txX), (localY, txY))
              else ((localY, txY), (localX, txX))
       in InternalTransfer
            { debitLocalAccount' = dl,
              creditLocalAccount' = cl,
              debitLeg' = dtx,
              creditLeg' = ctx
            }
