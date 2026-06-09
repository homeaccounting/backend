{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.Query
-- Description : Reusable wire-parsing for comma-separated query params.
--
-- 'CommaSep' parses @a,b,c@ into a 'NonEmpty' of any element type that has a
-- 'FromHttpApiData' instance. The orphan 'FromHttpApiData' 'StatusKind' lives
-- here (not in Domain) so the Domain layer takes no web/wire dependency; the
-- orphan warning is silenced by @-fno-warn-orphans@ in the library options.
module Web.Query
  ( CommaSep (..),
  )
where

import qualified Data.List.NonEmpty as NE
import qualified Data.Text as T
import Domain.Transaction.Projection (StatusKind, parseStatusKind)
import RIO
import Servant (FromHttpApiData (..))

-- | A non-empty, comma-separated list of values parsed from one query param.
newtype CommaSep a = CommaSep {values :: NE.NonEmpty a}
  deriving (Show, Eq)

instance (FromHttpApiData a) => FromHttpApiData (CommaSep a) where
  parseQueryParam raw =
    let tokens = map T.strip (T.splitOn "," raw)
     in if any T.null tokens
          then Left "comma-separated list has an empty element"
          else do
            parsed <- traverse parseQueryParam tokens
            case NE.nonEmpty parsed of
              Nothing -> Left "comma-separated list is empty"
              Just ne -> Right (CommaSep ne)

instance FromHttpApiData StatusKind where
  parseQueryParam raw =
    maybe (Left ("unknown status: " <> raw)) Right (parseStatusKind raw)
