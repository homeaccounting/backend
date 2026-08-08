{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.Csv
-- Description : Provider-agnostic CSV statement-parsing helpers
--
-- Shared groundwork for the CSV-based bank providers (personal + business
-- PrivatBank): the Cyrillic column-name helper ('csvColumn') and the generic
-- 'csvStatementParser' driver. Provider modules supply only their raw-row type,
-- a byte-prepare step, and a per-row validator. Not a public API surface.
module Infrastructure.Banking.Csv
  ( -- * Column names
    csvColumn,

    -- * Delimiters
    comma,
    semicolon,

    -- * Generic driver
    csvStatementParser,
  )
where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Csv as Csv
import qualified Data.Text as T
import qualified Data.Vector as V
import Infrastructure.Banking.Provider (BankTransaction, ParseError (..), RowError, StatementParser)
import RIO

-- | Column-name lookup key for a (possibly Cyrillic) CSV header. Going through
-- 'Text' then 'encodeUtf8' keeps Unicode codepoints intact: the 'IsString'
-- instance for 'ByteString' truncates each 'Char' to its low byte (Latin-1),
-- corrupting non-ASCII header names. Use this in every 'FromNamedRecord'.
csvColumn :: Text -> BS.ByteString
csvColumn = encodeUtf8

-- | The comma (@,@) field delimiter, for CSV exports that use it.
comma :: Word8
comma = 44

-- | The semicolon (@;@) field delimiter, for CSV exports that use it.
semicolon :: Word8
semicolon = 59

-- | Build a 'StatementParser' from a decodable raw-row type, a field
-- delimiter, a byte-prepare step (transcode and/or drop a preamble line;
-- 'Left' aborts the whole file), and a 1-indexed per-row validator. A
-- structural decode failure becomes a whole-file @Left (ParseError label…)@;
-- otherwise each data row yields one @validate rowNumber@ result.
csvStatementParser ::
  (Csv.FromNamedRecord raw) =>
  Text ->
  Word8 ->
  (ByteString -> Either ParseError ByteString) ->
  (Int -> raw -> Either RowError BankTransaction) ->
  StatementParser
csvStatementParser label delimiter prepare validate bs =
  case prepare bs of
    Left e -> Left e
    Right ready ->
      case Csv.decodeByNameWith opts (BSL.fromStrict ready) of
        Left err -> Left (ParseError (label <> ": " <> T.pack err))
        Right (_header, rows) ->
          Right [validate n row | (n, row) <- zip [1 ..] (V.toList rows)]
  where
    opts = Csv.defaultDecodeOptions {Csv.decDelimiter = delimiter}
