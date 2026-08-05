{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.Matching.Leg
-- Description : The shared "are these the same money movement?" kernel.
--
-- A movement leg is an absolute magnitude in some currency at a time. Two legs
-- are the "same movement" when magnitude and currency are equal and their times
-- are within a window. Parameterised over the currency token @c@ because bank
-- legs and domain legs are never compared cross-side (each call site matches
-- like-with-like). Both 'Domain.Transaction.Matching.Transfer' and
-- 'Domain.Transaction.Matching.Reconciliation' stand on this.
module Domain.Transaction.Matching.Leg
  ( Leg (..),
    sameMovement,
  )
where

import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import RIO

-- | A normalised movement leg. @magnitude@ is the absolute amount in major
-- units; @currency@ is any 'Eq' token consistent within a call site; @time@ is
-- when it occurred.
data Leg c = Leg
  { magnitude :: Rational,
    currency :: c,
    time :: UTCTime
  }
  deriving (Show, Eq)

-- | Equal magnitude, equal currency, and within @window@ of each other.
-- Symmetric in its two leg arguments.
sameMovement :: (Eq c) => NominalDiffTime -> Leg c -> Leg c -> Bool
sameMovement window a b =
  a.magnitude
    == b.magnitude
    && a.currency
    == b.currency
    && abs (diffUTCTime a.time b.time)
    <= window
