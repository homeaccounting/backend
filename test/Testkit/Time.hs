{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.Time
-- Description : Shared time helpers for specs.
--
-- A single place for the @utc y m d@ midnight-timestamp constructor that
-- was previously reimplemented in every books-close / metadata-edit
-- spec.
module Testkit.Time
  ( utc,
  )
where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import RIO

-- | Construct a deterministic UTC timestamp at midnight from
-- year\/month\/day.
utc :: Integer -> Int -> Int -> UTCTime
utc y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)
