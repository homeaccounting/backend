{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Data.Url
-- Description : Canonical form of http(s) base URLs.
--
-- A pure URL utility with no domain semantics, built on @network-uri@.
module Data.Url
  ( canonicalBaseUrl,
  )
where

import Network.URI (URI (..), URIAuth (..), parseAbsoluteURI)
import RIO
import RIO.Char (isAlphaNum, isAscii)
import qualified RIO.Text as T

-- | @scheme://host[:port][/path]@: scheme and host lower-cased, the default
-- port dropped, trailing slashes stripped. This is what a WHATWG URL parser
-- (the mobile app's @parseServerUrl@) produces, so both sides agree on the same
-- string. Only http(s); userinfo, query and fragment are refused rather than
-- dropped, and so are hosts a WHATWG parser would rewrite (non-ASCII,
-- percent-encoded).
canonicalBaseUrl :: Text -> Either Text Text
canonicalBaseUrl input = do
  uri <- maybe (invalid "not an absolute URL") Right (parseAbsoluteURI (T.unpack raw))
  let scheme = T.toLower (T.pack uri.uriScheme)
  defaultPort <- case scheme of
    "http:" -> Right 80
    "https:" -> Right 443
    _ -> invalid "scheme must be http or https"
  auth <- maybe (invalid "missing host") Right uri.uriAuthority
  unless (null auth.uriUserInfo) (invalid "has userinfo")
  unless (null uri.uriQuery && null uri.uriFragment) (invalid "has a query or fragment")
  let host = T.toLower (T.pack auth.uriRegName)
  unless (validHost host) (invalid "bad host")
  port <- parsePort (T.pack auth.uriPort)
  let portPart = case port of
        Just p | p /= defaultPort -> ":" <> tshow p
        _ -> ""
  pure (scheme <> "//" <> host <> portPart <> T.dropWhileEnd (== '/') (T.pack uri.uriPath))
  where
    raw = T.strip input
    invalid :: Text -> Either Text a
    invalid why = Left ("invalid URL " <> tshow raw <> ": " <> why)
    -- network-uri has already checked the IPv6 literal's syntax.
    validHost h =
      not (T.null h)
        && ("[" `T.isPrefixOf` h || T.all (\c -> isAscii c && (isAlphaNum c || c == '-' || c == '.')) h)
    parsePort p = case T.stripPrefix ":" p of
      Nothing -> Right Nothing
      Just digits -> case readMaybe (T.unpack digits) :: Maybe Int of
        Just n | n >= 1, n <= 65535 -> Right (Just n)
        _ -> invalid "bad port"
