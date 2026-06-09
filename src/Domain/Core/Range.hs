{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Core.Range
-- Description : Reusable inclusive range value object for query filters.
--
-- A 'Range' carries optional lower/upper bounds. 'mkRange' validates that a
-- fully-bounded range is non-empty (@from <= to@) and collapses the
-- "no bounds" case to 'Nothing' so an absent filter carries no constraint.
module Domain.Core.Range
  ( Range (..),
    mkRange,
    within,
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Inclusive range with independently-optional bounds.
data Range a = Range {from :: Maybe a, to :: Maybe a}
  deriving (Show, Eq, Generic)

-- | Smart constructor. 'Right' 'Nothing' when both bounds are absent (no
-- constraint); 'Left' when both are present and @from > to@.
mkRange :: (Ord a) => Maybe a -> Maybe a -> Either Text (Maybe (Range a))
mkRange Nothing Nothing = Right Nothing
mkRange mf mt = case (mf, mt) of
  (Just f, Just t) | f > t -> Left "from must be <= to"
  _ -> Right (Just (Range mf mt))

-- | Inclusive membership test against both bounds.
within :: (Ord a) => Range a -> a -> Bool
within (Range mf mt) x = maybe True (<= x) mf && maybe True (x <=) mt
