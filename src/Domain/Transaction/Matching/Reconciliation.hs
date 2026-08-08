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
--
-- __Extension point (deliberately not built yet).__ The matching rule is
-- currently fixed: 'isReconciliationMatch' = 'sameMovement' (exact
-- magnitude+currency, windowed time), with all per-call variation living in the
-- candidate-selection query and the effectful @attemptReconcile@ closure
-- (@Application.Services.BankImportService@). If a provider ever needs a
-- different reconciliation rule, a per-provider @ReconciliationMatcher@ seam
-- would slot in HERE — parameterizing the leg projection and/or the
-- magnitude/window tolerance, and threaded into @attemptReconcile@ like the
-- provider 'Infrastructure.Banking.Provider.TransferMatcher' is threaded into
-- @pairInternalTransfers@. It is intentionally NOT defined now: reconciliation
-- has a different shape from the boolean pairwise 'TransferMatcher' (it decides
-- over a candidate SET with an unambiguity guard, see 'ReconciliationOutcome'),
-- so the right interface is unknown absent a concrete requirement, and 'reconcile'
-- is already polymorphic in the currency token + parameterized on the window —
-- adding the rule is a small, local change when a real need appears. Design the
-- seam against that need, not speculatively. See the tracker#46 Phase-2 spec
-- (@docs/specs/2026-08-07-composable-transfer-matchers-fx-conversion-design.md@).
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
