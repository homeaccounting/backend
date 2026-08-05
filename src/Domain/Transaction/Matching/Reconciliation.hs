{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.Matching.Reconciliation
-- Description : Decide whether a just-imported bank leg is the SAME movement a
--               user already recorded manually — and, over a candidate set,
--               whether that match is unambiguous.
--
-- Unlike 'Domain.Transaction.Matching.Transfer' (opposite-direction legs of one
-- transfer), reconciliation matches a leg against a same-side manual entry:
-- same magnitude, currency, within window. Direction/account/leg-side are
-- enforced by the candidate SELECTION (the read-model query), exactly as
-- 'Application.Services.BankImport.TransferPairing' enforces "different local
-- accounts" outside the pure matcher; here the pure layer owns the
-- magnitude/currency/window predicate and the unique-vs-ambiguous decision.
module Domain.Transaction.Matching.Reconciliation
  ( ReconciliationOutcome (..),
    isReconciliationMatch,
    reconcile,
  )
where

import Data.Time (NominalDiffTime)
import Domain.Transaction.Matching.Leg (Leg, sameMovement)
import RIO

-- | Outcome of reconciling an imported leg against a candidate set.
data ReconciliationOutcome a
  = -- | No candidate matched — import as a fresh transaction.
    NoMatch
  | -- | Exactly one candidate matched — reconcile onto it.
    UniqueMatch a
  | -- | Two or more candidates matched — skip (never guess a merge). Carries
    -- the matched candidate keys for logging/diagnostics.
    Ambiguous [a]
  deriving (Show, Eq)

-- | Whether an imported leg and a candidate manual leg are the same movement.
-- Same-side by construction (candidate selection guarantees the correct leg on
-- the correct account), so this is exactly 'sameMovement'.
isReconciliationMatch :: (Eq c) => NominalDiffTime -> Leg c -> Leg c -> Bool
isReconciliationMatch = sameMovement

-- | Reconcile @imported@ against @candidates@ (keyed by @a@): none → 'NoMatch';
-- exactly one → 'UniqueMatch'; two or more → 'Ambiguous'.
reconcile ::
  (Eq c) =>
  NominalDiffTime ->
  Leg c ->
  [(a, Leg c)] ->
  ReconciliationOutcome a
reconcile window imported candidates =
  case [key | (key, cand) <- candidates, isReconciliationMatch window imported cand] of
    [] -> NoMatch
    [only] -> UniqueMatch only
    matched -> Ambiguous matched
