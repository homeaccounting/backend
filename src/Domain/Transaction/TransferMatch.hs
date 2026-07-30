{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.TransferMatch
-- Description : Pure, provider-independent criterion for "are these two legs the
--               same money movement?" — shared by bank-import internal-transfer
--               detection and the manual income+expense → transfer merge.
--
-- A movement is one debit leg on one account and one credit leg on another, of
-- equal magnitude and currency, close in time. The type is parameterised over the
-- currency representation @c@ (bank legs use the ISO numeric code 'Int'; domain
-- legs use 'Domain.Core.Types.Currency') because the two are never compared
-- cross-side — each call site matches like-with-like.
module Domain.Transaction.TransferMatch
  ( TransferDirection (..),
    TransferLeg (..),
    isTransferMatch,
  )
where

import Data.Time (NominalDiffTime, UTCTime, diffUTCTime)
import RIO

-- | Which side of a movement a leg is: money leaving (debit) or arriving (credit).
data TransferDirection = DebitLeg | CreditLeg
  deriving (Show, Eq)

-- | A normalised transfer leg. @magnitude@ is the absolute amount in major units;
-- @currency@ is any 'Eq' token consistent within a call site; @time@ is when it
-- occurred.
data TransferLeg c = TransferLeg
  { direction :: TransferDirection,
    magnitude :: Rational,
    currency :: c,
    time :: UTCTime
  }
  deriving (Show, Eq)

-- | True when @a@ and @b@ are opposite-direction legs of the same movement:
-- opposite directions, equal magnitude, equal currency, and within @window@ of
-- each other. Symmetric in its two leg arguments.
isTransferMatch :: (Eq c) => NominalDiffTime -> TransferLeg c -> TransferLeg c -> Bool
isTransferMatch window a b =
  a.direction
    /= b.direction
    && a.magnitude
    == b.magnitude
    && a.currency
    == b.currency
    && abs (diffUTCTime a.time b.time)
    <= window
