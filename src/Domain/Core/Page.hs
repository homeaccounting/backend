{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Core.Page
-- Description : Offset/limit pagination value object for read-model queries.
--
-- 'mkPage' applies defaults for absent params and validates bounds, rejecting
-- (rather than clamping) out-of-range input so a client bug surfaces as a 400.
module Domain.Core.Page
  ( Page (..),
    mkPage,
    defaultLimit,
    maxLimit,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | A validated page request: @limit@ rows starting at @offset@.
data Page = Page {limit :: Int, offset :: Int}
  deriving (Show, Eq, Generic)

-- | Default page size when @limit@ is omitted.
defaultLimit :: Int
defaultLimit = 50

-- | Hard cap on @limit@.
maxLimit :: Int
maxLimit = 200

-- | Smart constructor. Absent @limit@ -> 'defaultLimit'; absent @offset@ -> 0.
-- Rejects @limit@ outside @1 .. maxLimit@ and negative @offset@.
mkPage :: Maybe Int -> Maybe Int -> Either Text Page
mkPage mLimit mOffset
  | l < 1 = Left ("limit must be >= 1, got " <> tshow l)
  | l > maxLimit = Left ("limit must be <= " <> tshow maxLimit <> ", got " <> tshow l)
  | o < 0 = Left ("offset must be >= 0, got " <> tshow o)
  | otherwise = Right (Page l o)
  where
    l = fromMaybe defaultLimit mLimit
    o = fromMaybe 0 mOffset
    tshow = T.pack . show
