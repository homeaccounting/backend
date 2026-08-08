{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.Statement
-- Description : Format-neutral bank-statement parsing helpers
--
-- Groundwork shared by every statement-file format (CSV, XLSX, …): the
-- exact-decimal parser ('parseSignedDecimal') that turns a bank amount string
-- into a 'Rational' with no floating-point round-trip, plus format-neutral
-- number-token helpers ('isNumericToken', 'assembleNumber', 'stripTrailingComma')
-- for reassembling a grouped decimal out of a run of tokens. Format-specific
-- drivers (e.g. 'Infrastructure.Banking.Csv') build on top of this. Not a public
-- API surface.
module Infrastructure.Banking.Statement
  ( parseSignedDecimal,
    isNumericToken,
    assembleNumber,
    stripTrailingComma,
  )
where

import Data.Ratio ((%))
import qualified Data.Text as T
import RIO
import RIO.Char (isDigit)

-- | Parse a signed exact decimal (e.g. @"-6919.91"@, @"43000"@) to a
-- 'Rational', with no floating-point round-trip.
parseSignedDecimal :: Text -> Maybe Rational
parseSignedDecimal t = case T.stripPrefix "-" t of
  Just rest -> negate <$> parseUnsignedDecimal rest
  Nothing -> parseUnsignedDecimal t

-- | A token that could be part of a (possibly space/NBSP-grouped) decimal
-- amount: digits, a decimal point, a comma, or a grouping space (regular or
-- NBSP, in case 'T.words' kept it inside the token).
isNumericToken :: Text -> Bool
isNumericToken t = not (T.null t) && T.all isNumericChar t
  where
    isNumericChar c = isDigit c || c == '.' || c == ',' || c == ' ' || c == '\160'

-- | Join a contiguous run of numeric tokens into one parseable decimal: drop
-- grouping spaces (regular and NBSP) and a single trailing comma, e.g.
-- @["10", "000.00,"]@ → @"10000.00"@ and @["918.99,"]@ → @"918.99"@.
assembleNumber :: [Text] -> Text
assembleNumber =
  stripTrailingComma . T.filter (\c -> c /= ' ' && c /= '\160') . T.concat

-- | Drop a single trailing comma (e.g. @"918.99,"@ → @"918.99"@) before parsing.
stripTrailingComma :: Text -> Text
stripTrailingComma t = fromMaybe t (T.stripSuffix "," t)

parseUnsignedDecimal :: Text -> Maybe Rational
parseUnsignedDecimal t = case T.splitOn "." t of
  [intPart] -> (% 1) <$> readDigits intPart
  [intPart, fracPart] -> do
    i <- readDigits intPart
    f <- readDigits fracPart
    pure (fromInteger i + (fromInteger f % (10 ^ T.length fracPart)))
  _ -> Nothing

readDigits :: Text -> Maybe Integer
readDigits s
  | not (T.null s) && T.all isDigit s = readMaybe (T.unpack s)
  | otherwise = Nothing
