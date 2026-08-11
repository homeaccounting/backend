{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.Xlsx
-- Description : Provider-agnostic XLSX statement-parsing helpers
--
-- Reusable groundwork for XLSX-based bank providers, symmetric to
-- 'Infrastructure.Banking.Csv'. A raw-cell sheet reader (zip-archive +
-- xml-conduit) that keeps every cell as its exact string — no numeric
-- round-trip — plus a generic 'xlsxStatementParser' driver. Provider modules
-- supply only a header predicate and a per-row validator; column access is
-- by (Cyrillic) header name.
--
-- Note on OOXML: real @.xlsx@ worksheet/shared-string XML declares the default
-- namespace @http:\/\/schemas.openxmlformats.org\/spreadsheetml\/2006\/main@, so
-- @\<row\>@\/@\<c\>@\/@\<v\>@\/@\<sst\>@\/@\<si\>@\/@\<t\>@ are all namespaced.
-- Every element match here is by local name via 'laxElement' so it matches the
-- real (namespaced) files. Not a public API surface.
module Infrastructure.Banking.Xlsx
  ( parseSharedStrings,
    parseSheetRows,
    readXlsxSheet,
    xlsxStatementParser,
    colRefIndex,
  )
where

import qualified Codec.Archive.Zip as Zip
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Vector as V
import Infrastructure.Banking.Provider (BankTransaction, ParseError (..), RowError, StatementParser)
import RIO
import RIO.Char (isAlpha, ord, toUpper)
import qualified RIO.List as L
import Safe (atMay)
import Text.XML (def, parseLBS)
import Text.XML.Cursor (attribute, child, content, descendant, fromDocument, laxElement)

-- | Parse an @xl\/sharedStrings.xml@ part into the shared-string table, in
-- document order (index @i@ is the @\<si\>@ at position @i@). Rich-text runs
-- (@\<si\>\<r\>\<t\>…@) are concatenated. A malformed part yields an empty
-- table rather than aborting — a text cell then resolves to @""@.
parseSharedStrings :: ByteString -> Vector Text
parseSharedStrings bs =
  case parseLBS def (BSL.fromStrict bs) of
    Left _ -> V.empty
    Right doc ->
      V.fromList [siText si | si <- descendant (fromDocument doc) >>= laxElement "si"]
  where
    siText si = T.concat [txt | t <- descendant si >>= laxElement "t", txt <- child t >>= content]

-- | Parse a worksheet part into rows of cell strings, in sheet order. Each
-- @\<c\>@ is placed at a 0-based column index: from its @r@ reference
-- ('colRefIndex') when present, otherwise one past the previous cell (OOXML
-- makes @r@ optional, letting sibling order imply position). Gaps left by
-- OOXML's omission of empty cells are padded with @""@ so downstream
-- by-position/by-header lookups stay aligned. A shared-string cell (@t=\"s\"@)
-- is resolved through the table; every other cell keeps its @\<v\>@ (or inline
-- @\<is\>\<t\>@) text verbatim.
parseSheetRows :: Vector Text -> ByteString -> [[Text]]
parseSheetRows sharedStrings bs =
  case parseLBS def (BSL.fromStrict bs) of
    Left _ -> []
    Right doc ->
      [rowCells row | row <- descendant (fromDocument doc) >>= laxElement "row"]
  where
    rowCells row = assembleRow (indexCells 0 (child row >>= laxElement "c"))
    -- Walk a row's cells left-to-right with a running column cursor so that a
    -- cell missing @r@ falls one slot past its predecessor.
    indexCells _ [] = []
    indexCells next (c : cs) =
      let idx = maybe next colRefIndex (listToMaybe (attribute "r" c))
       in (idx, cellValue c) : indexCells (idx + 1) cs
    cellValue c =
      case listToMaybe (attribute "t" c) of
        Just "s" ->
          case readMaybe (T.unpack (localText "v" c)) of
            Just i -> fromMaybe "" (sharedStrings V.!? i)
            Nothing -> ""
        Just "inlineStr" -> localText "t" c
        _ -> localText "v" c
    localText name c =
      T.concat [txt | e <- descendant c >>= laxElement name, txt <- child e >>= content]

-- | Fill a sparse @(index, value)@ list into a dense row, padding gaps with
-- @""@ up to the largest index. An empty cell list yields an empty row.
assembleRow :: [(Int, Text)] -> [Text]
assembleRow [] = []
assembleRow indexed =
  let m = Map.fromList indexed
      maxIdx = foldl' max 0 (map fst indexed)
   in [Map.findWithDefault "" i m | i <- [0 .. maxIdx]]

-- | Decode a cell reference's leading column letters (e.g. @"AA"@ from
-- @"AA12"@) to a 0-based column index. Bijective base-26 (A=1, …, Z=26, AA=27)
-- accumulated then decremented, so @"A" → 0@, @"G" → 6@, @"AA" → 26@. A
-- letter-less ref (malformed) clamps to @0@ rather than a negative index.
colRefIndex :: Text -> Int
colRefIndex ref =
  let letters = T.takeWhile isAlpha ref
   in max 0 (T.foldl' (\acc ch -> acc * 26 + (ord (toUpper ch) - ord 'A' + 1)) 0 letters - 1)

-- | Read an @.xlsx@ blob into worksheet rows. Opens the archive with the total
-- 'Zip.toArchiveOrFail' (never the partial 'Zip.toArchive'), reads the first
-- @xl\/worksheets\/sheet*.xml@ and the optional @xl\/sharedStrings.xml@. A
-- non-archive blob or a missing worksheet is a whole-file 'ParseError'. When
-- several worksheets are present the first by filename sort is used (statement
-- exports are single-sheet). The input is strict; zip-archive and xml-conduit
-- are lazy, hence the 'BSL.fromStrict'\/'BSL.toStrict' conversions.
readXlsxSheet :: ByteString -> Either ParseError [[Text]]
readXlsxSheet bs =
  case Zip.toArchiveOrFail (BSL.fromStrict bs) of
    Left err -> Left (ParseError ("XLSX: invalid archive: " <> T.pack err))
    Right archive ->
      case firstSheetEntry archive of
        Nothing -> Left (ParseError "XLSX: no worksheet found in archive")
        Just sheetEntry ->
          let sharedStrings =
                case Zip.findEntryByPath "xl/sharedStrings.xml" archive of
                  Just e -> parseSharedStrings (BSL.toStrict (Zip.fromEntry e))
                  Nothing -> V.empty
              sheetBytes = BSL.toStrict (Zip.fromEntry sheetEntry)
           in Right (parseSheetRows sharedStrings sheetBytes)
  where
    firstSheetEntry archive =
      case L.sort (filter isSheetPath (Zip.filesInArchive archive)) of
        (p : _) -> Zip.findEntryByPath p archive
        [] -> Nothing
    isSheetPath p =
      "xl/worksheets/sheet" `L.isPrefixOf` p && ".xml" `L.isSuffixOf` p

-- | Build a 'StatementParser' from a label, a header-row predicate, and a
-- 1-indexed per-row validator /factory/. Reads the sheet ('readXlsxSheet'),
-- locates the first row satisfying the predicate as the header (whole-file
-- 'ParseError' if none), maps header names to column indices (a duplicated
-- header name resolves to its last column), and runs the validator over each
-- subsequent non-empty row.
--
-- The validator is a factory applied once to the __preamble__ — the rows before
-- the header — so a format can derive file-level context (e.g. the account IBAN
-- or currency stated once above the table) and close over it before validating
-- rows. The resulting per-row validator receives a total by-name column accessor
-- (name absent from the header, or row too short, → 'Nothing') and the 1-based
-- data-row number. All indexing is via 'Map' + 'Safe.atMay'; no partial lookup.
xlsxStatementParser ::
  Text ->
  ([Text] -> Bool) ->
  ([[Text]] -> (Text -> Maybe Text) -> Int -> Either RowError BankTransaction) ->
  StatementParser
xlsxStatementParser label isHeaderRow validate bs =
  case readXlsxSheet bs of
    Left e -> Left e
    Right rows ->
      case break isHeaderRow rows of
        (preamble, header : dataRows) ->
          let hdr = Map.fromList (zip header [0 ..])
              col row name = Map.lookup name hdr >>= atMay row
              validateRow = validate preamble
           in Right
                [ validateRow (col row) n
                | (n, row) <- zip [1 ..] dataRows,
                  not (all T.null row)
                ]
        (_, []) -> Left (ParseError (label <> ": header row not found"))
