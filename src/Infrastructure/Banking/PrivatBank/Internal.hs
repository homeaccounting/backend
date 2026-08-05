{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- This module is __not part of the public API__. It declares the internal
-- PrivatBank CSV row shape and the pure parsing/validation helpers so that
-- 'Infrastructure.Banking.PrivatBank' and tests can share them. Production
-- code should depend on 'Infrastructure.Banking.PrivatBank' instead.
module Infrastructure.Banking.PrivatBank.Internal
  ( PrivatRawRow (..),
    parsePrivatBankCsv,
    validateRow,
    parseSignedDecimal,
  )
where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Char (isDigit)
import qualified Data.Csv as Csv
import Data.Ratio ((%))
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import qualified Data.Vector as V
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (currencyNumericCode, mkByLabel, mkExternalTransactionId, parseCurrency)
import Infrastructure.Banking.Provider
import RIO

-- | One data row of a PrivatBank CSV export, decoded field-for-field with no
-- semantic validation — every field is raw 'Text' straight off the CSV. This
-- is the only structure that can trigger a whole-file 'ParseError' (via
-- cassava's 'Csv.FromNamedRecord'): a missing/renamed column makes every
-- row's field lookup fail, which aborts the decode. Semantic validation
-- (dates, amounts, currency, external id) happens per-row afterwards in
-- 'validateRow', so a single corrupted row never fails the whole file.
data PrivatRawRow = PrivatRawRow
  { rawDate :: !Text,
    rawCategory :: !Text,
    rawCard :: !Text,
    rawDescription :: !Text,
    rawAmount :: !Text,
    rawCurrency :: !Text,
    rawBalance :: !Text
  }
  deriving (Show, Eq)

-- | Column names as they appear in a PrivatBank CSV header (Cyrillic, UTF-8).
-- Looked up via 'encodeUtf8'd 'Text' keys rather than @OverloadedStrings@
-- 'ByteString' literals directly: the standard 'IsString' instance for
-- 'ByteString' truncates each 'Char' to its low byte (effectively Latin-1),
-- which would corrupt these non-ASCII column names. Going through 'Text'
-- first keeps the literal's Unicode codepoints intact, and 'encodeUtf8'
-- then produces the exact UTF-8 bytes cassava parsed the header into.
colDate, colCategory, colCard, colDescription, colAmount, colCurrency, colBalance :: BS.ByteString
colDate = encodeUtf8 "Дата"
colCategory = encodeUtf8 "Категорія"
colCard = encodeUtf8 "Картка"
colDescription = encodeUtf8 "Опис операції"
colAmount = encodeUtf8 "Сума в валюті картки"
colCurrency = encodeUtf8 "Валюта картки"
colBalance = encodeUtf8 "Залишок на кінець періоду"

instance Csv.FromNamedRecord PrivatRawRow where
  parseNamedRecord m =
    PrivatRawRow
      <$> m
      Csv..: colDate
      <*> m
      Csv..: colCategory
      <*> m
      Csv..: colCard
      <*> m
      Csv..: colDescription
      <*> m
      Csv..: colAmount
      <*> m
      Csv..: colCurrency
      <*> m
      Csv..: colBalance

-- | Parse a PrivatBank CSV statement export.
--
-- The export's first line is a human-readable title/period preamble, not
-- part of the tabular data — it is dropped before handing the rest to
-- cassava's 'Csv.decodeByName', which reads the (Cyrillic) header row and
-- decodes each subsequent row into a 'PrivatRawRow'. A structural problem
-- (missing/renamed required column, unparsable CSV framing) surfaces here as
-- a whole-file 'Left ParseError'. Otherwise every decoded row is separately
-- validated by 'validateRow', 1-indexed by its position among the data rows.
parsePrivatBankCsv :: StatementParser
parsePrivatBankCsv bs =
  case dropPreambleLine bs of
    Nothing -> Left (ParseError "PrivatBank CSV: no preamble/header lines found")
    Just rest ->
      case Csv.decodeByName (BSL.fromStrict rest) of
        Left err -> Left (ParseError ("PrivatBank CSV: " <> T.pack err))
        Right (_header, rows) ->
          Right
            [ validateRow rowNumber row
            | (rowNumber, row) <- zip [1 ..] (V.toList rows)
            ]

-- | Drop the first line (and its line terminator) of a 'ByteString',
-- treating a bare @\n@ or a @\r\n@ pair as the terminator. 'Nothing' iff the
-- input has no line terminator at all (i.e. no header/data lines follow the
-- would-be preamble).
dropPreambleLine :: ByteString -> Maybe ByteString
dropPreambleLine bs =
  case BS.elemIndex newline bs of
    Nothing -> Nothing
    Just idx -> Just (BS.drop (idx + 1) bs)
  where
    newline = 10 -- '\n'

-- | Validate + convert one decoded 'PrivatRawRow' into a 'BankTransaction'.
-- 'rowNumber' is the 1-based position of this row among the data rows (i.e.
-- excluding the dropped preamble and header lines), used to identify the row
-- in a 'RowError'.
validateRow :: Int -> PrivatRawRow -> Either RowError BankTransaction
validateRow rowNumber raw =
  case parseTimeM True defaultTimeLocale dateFormat (T.unpack raw.rawDate) of
    Nothing -> rowErr ("invalid date: " <> raw.rawDate)
    Just utcTime -> case parseSignedDecimal raw.rawAmount of
      Nothing -> rowErr ("invalid amount: " <> raw.rawAmount)
      Just amt -> case fmap currencyNumericCode (parseCurrency raw.rawCurrency) of
        Left err -> rowErr ("invalid currency: " <> err)
        Right currCode -> case mkExternalTransactionId (externalIdText raw) of
          Left err -> rowErr ("invalid external id: " <> err)
          Right extId ->
            Right
              BankTransaction
                { externalId = extId,
                  externalAccountId = unsafeExternalAccountId raw.rawCard,
                  time = utcTime,
                  amount = amt,
                  currencyCode = currCode,
                  description = raw.rawDescription,
                  hold = False,
                  category = mkByLabel raw.rawCategory,
                  originalAmount = Nothing,
                  notes = Nothing
                }
  where
    rowErr = Left . RowError rowNumber
    dateFormat = "%d.%m.%Y %H:%M:%S"

-- | Deterministic external id composite: raw date, raw card-currency amount,
-- and raw running balance, all taken verbatim off the CSV. The running
-- balance makes each row unique even when date+amount repeat (e.g. two
-- identical top-ups); parsing the same file bytes always yields the same
-- text, and hence the same id.
externalIdText :: PrivatRawRow -> Text
externalIdText raw =
  "privatbank:" <> raw.rawDate <> ":" <> raw.rawAmount <> ":" <> raw.rawBalance

-- | Parse a signed decimal amount (e.g. @"-6919.91"@, @"43000"@) into an
-- exact 'Rational', avoiding any intermediate floating-point representation.
parseSignedDecimal :: Text -> Maybe Rational
parseSignedDecimal t = case T.stripPrefix "-" t of
  Just rest -> negate <$> parseUnsignedDecimal rest
  Nothing -> parseUnsignedDecimal t

-- | Parse an unsigned decimal amount, with or without a fractional part.
parseUnsignedDecimal :: Text -> Maybe Rational
parseUnsignedDecimal t = case T.splitOn "." t of
  [intPart] -> (% 1) <$> readDigits intPart
  [intPart, fracPart] -> do
    i <- readDigits intPart
    f <- readDigits fracPart
    pure (fromInteger i + (fromInteger f % (10 ^ T.length fracPart)))
  _ -> Nothing

-- | Read a non-empty run of decimal digits (per 'isDigit') as an 'Integer'.
-- Total: rejects anything containing a non-digit or the empty string, rather
-- than throwing.
readDigits :: Text -> Maybe Integer
readDigits s
  | not (T.null s) && T.all isDigit s = readMaybe (T.unpack s)
  | otherwise = Nothing
