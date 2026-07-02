{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Data.Text.Match
-- Description : Generic name matching (normalize → exact → unambiguous substring).
--
-- A pure text utility with no domain semantics. Used to resolve a user-supplied
-- (possibly LLM-produced) name to one of a known set of named values.
module Data.Text.Match
  ( MatchResult (..),
    matchByName,
    normalizeName,
  )
where

import RIO
import qualified RIO.Text as T

-- | Result of matching a query against a candidate set.
data MatchResult a = Matched a | Ambiguous [a] | NoMatch
  deriving (Show, Eq)

-- | Normalize for comparison: trim, casefold, collapse internal whitespace.
normalizeName :: Text -> Text
normalizeName = T.unwords . T.words . T.toCaseFold . T.strip

-- | Match @query@ against @candidates@ by a name projection.
--
-- Exact (normalized) match wins. If there is no exact match, an unambiguous
-- substring match is used. Ties yield 'Ambiguous'; nothing yields 'NoMatch'.
-- Cross-lingual mapping is NOT attempted here — callers rely on the LLM to
-- return the canonical name, which then matches exactly.
matchByName :: (a -> Text) -> Text -> [a] -> MatchResult a
matchByName name query candidates
  | T.null q = NoMatch
  | otherwise =
      case exact of
        [x] -> Matched x
        (_ : _) -> Ambiguous exact
        [] -> case subs of
          [x] -> Matched x
          (_ : _) -> Ambiguous subs
          [] -> NoMatch
  where
    q = normalizeName query
    exact = [c | c <- candidates, normalizeName (name c) == q]
    subs = [c | c <- candidates, q `T.isInfixOf` normalizeName (name c)]
