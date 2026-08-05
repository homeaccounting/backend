{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.Matching.Transfer
-- Description : Pure "are these two legs opposite sides of one transfer?" —
--               shared by bank-import internal-transfer detection and the
--               manual income+expense → transfer merge. Rebuilt on
--               'Domain.Transaction.Matching.Leg'.
module Domain.Transaction.Matching.Transfer
  ( TransferDirection (..),
    TransferLeg (..),
    isTransferMatch,
  )
where

import Data.Time (NominalDiffTime, UTCTime)
import Domain.Transaction.Matching.Leg (Leg (..), sameMovement)
import RIO

-- | Which side of a movement a leg is: money leaving (debit) or arriving (credit).
data TransferDirection = DebitLeg | CreditLeg
  deriving (Show, Eq)

-- | A normalised transfer leg. @magnitude@ is the absolute amount in major
-- units; @currency@ is any 'Eq' token consistent within a call site; @time@ is
-- when it occurred.
data TransferLeg c = TransferLeg
  { direction :: TransferDirection,
    magnitude :: Rational,
    currency :: c,
    time :: UTCTime
  }
  deriving (Show, Eq)

-- | True when @a@ and @b@ are opposite-direction legs of the same movement:
-- opposite directions plus 'sameMovement'. Symmetric in its two leg arguments.
isTransferMatch :: (Eq c) => NominalDiffTime -> TransferLeg c -> TransferLeg c -> Bool
isTransferMatch window a b =
  a.direction /= b.direction && sameMovement window (legOf a) (legOf b)
  where
    legOf l = Leg {magnitude = l.magnitude, currency = l.currency, time = l.time}
