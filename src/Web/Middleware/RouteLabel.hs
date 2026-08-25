{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.Middleware.RouteLabel
-- Description : Bounded-cardinality route label for the HTTP request-duration metric
--
-- The @http_request_duration_seconds@ histogram is labeled per endpoint so the
-- HTTP dashboard can answer "which route is slow/fast". Labeling by the raw
-- request path would be unbounded cardinality — REST paths embed ids
-- (@\/api\/accounts\/\<uuid\>@) — so 'normalizeRoutePath' collapses each dynamic
-- segment to a @:id@ placeholder, yielding the route /template/
-- (@\/api\/accounts\/:id@). The series count is thus bounded by the number of
-- route templates, not requests.
--
-- A second guard bounds it against random 404 probing: only paths whose first
-- segment is a known top-level API collection get a real label; everything else
-- collapses to a single @other@ bucket. The collection set mirrors the
-- @Web.API.*@ modules — extend it when a whole new top-level API group is added.
module Web.Middleware.RouteLabel
  ( routeLabel,
    normalizeRoutePath,
  )
where

import qualified Data.Char as Char
import qualified Data.Text as T
import Network.Wai (Request, pathInfo)
import RIO

-- | The @handler@ label value for a request: the normalized route template of
-- its path (see 'normalizeRoutePath').
routeLabel :: Request -> Text
routeLabel = normalizeRoutePath . pathInfo

-- | Normalize a request's path segments into a bounded route-template label.
--
-- @["api","accounts","<uuid>"]@ becomes @"\/api\/accounts\/:id"@; a path under an
-- unknown top-level collection (or with no @api@ prefix) becomes @"other"@.
normalizeRoutePath :: [Text] -> Text
normalizeRoutePath rawSegments =
  case filter (not . T.null) rawSegments of
    ("api" : collection : rest)
      | collection `elem` knownCollections ->
          "/" <> T.intercalate "/" ("api" : collection : map normalizeSegment rest)
    _ -> "other"

-- | Top-level API collections (the first path segment after @api@), mirroring
-- the @Web.API.*@ modules. Requests outside this set are bucketed into @other@.
knownCollections :: [Text]
knownCollections =
  [ "accounts",
    "transactions",
    "users",
    "auth",
    "banking",
    "reports",
    "sync",
    "prompt",
    "info",
    "telegram"
  ]

-- | Collapse an id-like segment (UUID or all-digits) to @:id@; keep everything
-- else verbatim. Non-id text captures (e.g. an OAuth provider name) are a small
-- bounded set, so they stay as-is.
normalizeSegment :: Text -> Text
normalizeSegment segment
  | isIdLike segment = ":id"
  | otherwise = segment

isIdLike :: Text -> Bool
isIdLike segment = isAllDigits segment || isUuid segment
  where
    isAllDigits t = not (T.null t) && T.all Char.isDigit t
    isUuid t =
      T.length t
        == 36
        && T.count "-" t
        == 4
        && T.all (\c -> Char.isHexDigit c || c == '-') t
