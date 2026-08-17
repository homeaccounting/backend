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
    parsePrivatBankXlsx,
    validateRow,
    counterpartyToken,
  )
where

import qualified Data.ByteString as BS
import qualified Data.Csv as Csv
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Domain.Banking.Import (mkExternalTransactionId)
import Domain.Banking.Signal (mkBankProviderContact, mkByLabel)
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (currencyNumericCode, parseCurrency)
import Infrastructure.Banking.Csv (comma, csvColumn, csvStatementParser)
import Infrastructure.Banking.Provider
import Infrastructure.Banking.Statement (canonicalDecimal, parseSignedDecimal)
import Infrastructure.Banking.Xlsx (xlsxStatementParser)
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
-- Looked up via 'csvColumn' so the non-ASCII codepoints survive the lookup key.
colDate, colCategory, colCard, colDescription, colAmount, colCurrency, colBalance :: BS.ByteString
colDate = csvColumn "Дата"
colCategory = csvColumn "Категорія"
colCard = csvColumn "Картка"
colDescription = csvColumn "Опис операції"
colAmount = csvColumn "Сума в валюті картки"
colCurrency = csvColumn "Валюта картки"
colBalance = csvColumn "Залишок на кінець періоду"

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
parsePrivatBankCsv = csvStatementParser "PrivatBank CSV" comma prepare validateRow
  where
    prepare bs = case dropPreambleLine bs of
      Nothing -> Left (ParseError "PrivatBank CSV: no preamble/header lines found")
      Just rest -> Right rest

-- | Parse a PrivatBank __XLSX__ statement export — the native (default) Privat24
-- export, the same @Історія операцій@ statement as the CSV in an OOXML container.
--
-- The sheet opens with a merged title row; the tabular header is the first row
-- carrying both @Дата@ and @Сума в валюті картки@ (a whole-file 'ParseError' if
-- no such row exists). Each subsequent non-empty row's columns are read by
-- (Cyrillic) header name into the same 'PrivatRawRow' the CSV path decodes, then
-- validated by the shared 'validateRow' — so a statement imported as XLSX or CSV
-- yields identical 'BankTransaction's (including a matching 'externalId', which
-- 'validateRow' derives from the amount/balance's exact value, not their textual
-- spelling). A malformed row becomes a 'RowError' without failing the file.
parsePrivatBankXlsx :: StatementParser
parsePrivatBankXlsx =
  xlsxStatementParser "PrivatBank XLSX" isHeaderRow (\_preamble col rowNumber -> validateRow rowNumber (rowFromColumns col))
  where
    isHeaderRow cells = "Дата" `elem` cells && "Сума в валюті картки" `elem` cells

-- | Assemble a 'PrivatRawRow' from an XLSX by-name column accessor, mirroring the
-- CSV 'Csv.FromNamedRecord' decode field-for-field. A column absent from the
-- header (accessor returns 'Nothing') becomes @""@, which 'validateRow' then
-- rejects per-row exactly as it would an empty CSV cell.
rowFromColumns :: (Text -> Maybe Text) -> PrivatRawRow
rowFromColumns col =
  PrivatRawRow
    { rawDate = get "Дата",
      rawCategory = get "Категорія",
      rawCard = get "Картка",
      rawDescription = get "Опис операції",
      rawAmount = get "Сума в валюті картки",
      rawCurrency = get "Валюта картки",
      rawBalance = get "Залишок на кінець періоду"
    }
  where
    get name = fromMaybe "" (col name)

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
                  contact = mkBankProviderContact (counterpartyToken raw.rawDescription),
                  originalAmount = Nothing,
                  notes = Nothing
                }
  where
    rowErr = Left . RowError rowNumber
    dateFormat = "%d.%m.%Y %H:%M:%S"

-- | Extract the stable counterparty token from a PrivatBank operation
-- description, for use as the provider contact signal. Strips the trailing
-- segments that vary per transaction (so the same counterparty maps to one
-- stable token instead of a new one each time):
--
--   * @". Коментар: …"@ — the free-text payment purpose on bank transfers
--     (carries names, amounts, invoice numbers — different every payment).
--   * @", ID платежу: …"@ — the per-transaction payment id on some card rows.
--
-- Cosmetic-but-stable suffixes (a trailing city, the double-conversion note)
-- are deliberately left intact: they are constant per merchant, so they never
-- defeat the map, and stripping them risks over-truncation. The full raw text
-- is still kept as the transaction 'description' (memo / name-match fallback);
-- only the 'contact' signal is trimmed. A description with no volatile tail is
-- returned unchanged (a plain merchant with an internal dot, or a trailing
-- initial's dot, both survive).
counterpartyToken :: Text -> Text
counterpartyToken =
  T.strip
    . fst
    . T.breakOn ", ID платежу:"
    . fst
    . T.breakOn ". Коментар:"

-- | Deterministic external id composite: the row's date verbatim plus its
-- card-currency amount and running balance in canonical decimal form
-- ('canonicalDecimal'). The running balance makes each row unique even when
-- date+amount repeat (e.g. two identical top-ups). Canonicalising amount and
-- balance by exact value rather than textual spelling makes the id
-- format-independent, so the same statement imported as CSV (@"510"@) or XLSX
-- (@"510.0"@) yields one id and dedups identically; parsing the same file bytes
-- still always yields the same id.
externalIdText :: PrivatRawRow -> Text
externalIdText raw =
  "privatbank:" <> raw.rawDate <> ":" <> canonicalDecimal raw.rawAmount <> ":" <> canonicalDecimal raw.rawBalance
