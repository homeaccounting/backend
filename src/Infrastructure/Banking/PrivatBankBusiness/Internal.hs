{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | __Not a public API.__ Pure parsing for the PrivatBank business statement
-- __XLSX__ export (the default Автоклієнт format). Depend on
-- 'Infrastructure.Banking.PrivatBankBusiness' from production code.
--
-- One statement file spans several of the business's accounts and currencies:
-- each row carries its own @Ваш рахунок@ (account IBAN) and @Валюта@, so the
-- 'BankTransaction.externalAccountId' is taken per row rather than assumed
-- constant. Amounts are read verbatim from the cell string and kept as an exact
-- 'Rational' — no numeric round-trip.
module Infrastructure.Banking.PrivatBankBusiness.Internal
  ( parsePrivatBankBusinessXlsx,
    validateRow,
    fxSignal,
  )
where

import qualified Data.Text as T
import Data.Time (Day, TimeOfDay, UTCTime (..), timeOfDayToTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (currencyNumericCode, mkBankProviderContact, mkExternalTransactionId, parseCurrency)
import Infrastructure.Banking.Provider
import Infrastructure.Banking.Statement (assembleNumber, isNumericToken, parseSignedDecimal, stripTrailingComma)
import Infrastructure.Banking.Xlsx (xlsxStatementParser)
import RIO

-- | Parse a PrivatBank business XLSX statement export.
--
-- The sheet opens with a short human-readable preamble; the tabular header is
-- located as the first row carrying both the @Референс@ and @Сума@ columns
-- (a whole-file 'ParseError' if no such row exists). Each subsequent non-empty
-- row is validated independently by 'validateRow', so one malformed row becomes
-- a 'RowError' without failing the file. Columns are addressed by their
-- (Cyrillic) header name, tolerating column reordering.
parsePrivatBankBusinessXlsx :: StatementParser
parsePrivatBankBusinessXlsx =
  xlsxStatementParser "PrivatBank business XLSX" isHeaderRow validateRow
  where
    isHeaderRow cells = "Референс" `elem` cells && "Сума" `elem` cells

-- | Validate + convert one statement row into a 'BankTransaction'. @col@ looks
-- a value up by header name (a column absent from the header, or a row too
-- short, yields 'Nothing'); @rowNumber@ is the 1-based position among the data
-- rows, used to identify the row in a 'RowError'. A missing required column, or
-- an unparsable date/time/amount/currency/reference, is a per-row 'RowError'.
validateRow :: (Text -> Maybe Text) -> Int -> Either RowError BankTransaction
validateRow col rowNumber =
  case col "Референс" of
    Nothing -> rowErr "missing column: Референс"
    Just refText -> case mkExternalTransactionId refText of
      Left err -> rowErr ("invalid external id: " <> err)
      Right extId -> case col "Ваш рахунок" of
        Nothing -> rowErr "missing column: Ваш рахунок"
        Just accText -> case (col "Дата проводки", col "Час проводки") of
          (Just dateText, Just timeText) -> case combineDateTime dateText timeText of
            Nothing -> rowErr ("invalid date/time: " <> dateText <> " " <> timeText)
            Just utcTime -> case col "Сума" of
              Nothing -> rowErr "missing column: Сума"
              -- OOXML numeric cells are invariant: a '.'-decimal with no
              -- thousands grouping, so — unlike the old CSV path — there is
              -- deliberately no space-stripping before parsing.
              Just amountText -> case parseSignedDecimal amountText of
                Nothing -> rowErr ("invalid amount: " <> amountText)
                Just amt -> case col "Валюта" of
                  Nothing -> rowErr "missing column: Валюта"
                  Just currText -> case fmap currencyNumericCode (parseCurrency currText) of
                    Left err -> rowErr ("invalid currency: " <> err)
                    Right currCode ->
                      Right
                        BankTransaction
                          { externalId = extId,
                            externalAccountId = unsafeExternalAccountId accText,
                            time = utcTime,
                            amount = amt,
                            currencyCode = currCode,
                            description = describe (col "Назва контрагента") (col "Призначення платежу"),
                            hold = False,
                            category = Nothing,
                            contact = mkBankProviderContact (fromMaybe "" (col "ЄДРПОУ")),
                            originalAmount = Nothing,
                            notes = Nothing
                          }
          _ -> rowErr "missing column: Дата проводки / Час проводки"
  where
    rowErr = Left . RowError rowNumber

-- | Recognise a PrivatBank-business currency-conversion leg and extract the
-- conversion amount stated before a currency code, shared by both legs. Gated on
-- a currency-sale counterparty marker in the transaction @description@ — the
-- word @"Продаж"@ immediately followed by any recognised currency code
-- (@"Продаж UAH"@ / @"Продаж USD"@ / @"Продаж EUR"@).
--
-- The conversion amount is read ROBUSTLY: the description mentions a currency
-- code more than once (the bare @Продаж <CUR>@ marker has NO preceding number),
-- so rather than "the number before the first currency code", we scan for any
-- recognised currency code and take the maximal contiguous run of preceding
-- numeric-looking tokens, join it, drop grouping spaces/NBSP and a trailing
-- comma, then parse it (see 'assembleNumber'). Returns the first such amount;
-- 'Nothing' when no marker or no qualifying number is present. Pure + total.
--
-- Real Автоклієнт exports observed use contiguous amounts (≤4 digits sampled,
-- e.g. @918.99@, @1000.00@); the run-join handles a space/NBSP-grouped
-- @10 000.00@ defensively, since larger amounts are unverified — a naive
-- single-token scan would take @"000.00"@ and silently parse it to @0@.
fxSignal :: FxSignal
fxSignal tx
  | not isConversion = Nothing
  | otherwise = FxLeg <$> conversionAmount
  where
    desc = tx.description
    ws = T.words desc
    -- The sale marker: the word "Продаж" immediately followed by any currency
    -- code (e.g. "Продаж UAH" / "Продаж USD" / "Продаж EUR").
    isConversion = any isSaleMarker (zip ws (drop 1 ws))
    isSaleMarker (a, b) = a == "Продаж" && isCurrencyToken b
    conversionAmount = asum (scan [] ws)
    -- Accumulate a run of consecutive numeric-looking tokens; on reaching a
    -- currency code, emit the assembled preceding run and reset. A currency code
    -- with an empty run (e.g. the @Продаж USD@ marker) yields 'Nothing', which
    -- 'asum' skips in favour of a later qualifying amount.
    scan _ [] = []
    scan run (t : ts)
      | isCurrencyToken t =
          parseSignedDecimal (assembleNumber run) : scan [] ts
      | isNumericToken t = scan (run <> [t]) ts
      | otherwise = scan [] ts

-- | Does a token parse to any recognised currency code (ignoring a trailing
-- comma)? Used both to detect the @Продаж <CUR>@ sale marker and to bound the
-- preceding numeric run when extracting the conversion amount.
isCurrencyToken :: Text -> Bool
isCurrencyToken t = isRight (parseCurrency (stripTrailingComma t))

-- | Combine a @%d.%m.%Y@ date cell and a @%H:%M:%S@ time cell into one
-- 'UTCTime' (the statement times are already in the account's local wall
-- clock; no zone conversion is applied). 'Nothing' if either cell is unparsable.
combineDateTime :: Text -> Text -> Maybe UTCTime
combineDateTime dateText timeText = do
  day <- parseTimeM True defaultTimeLocale "%d.%m.%Y" (T.unpack dateText) :: Maybe Day
  tod <- parseTimeM True defaultTimeLocale "%H:%M:%S" (T.unpack timeText) :: Maybe TimeOfDay
  pure (UTCTime day (timeOfDayToTime tod))

-- | Ledger memo: counterparty name + purpose (joined when both present, either
-- one alone otherwise). A missing column is treated as blank.
describe :: Maybe Text -> Maybe Text -> Text
describe mName mPurpose
  | T.null name = purpose
  | T.null purpose = name
  | otherwise = name <> " — " <> purpose
  where
    name = T.strip (fromMaybe "" mName)
    purpose = T.strip (fromMaybe "" mPurpose)
