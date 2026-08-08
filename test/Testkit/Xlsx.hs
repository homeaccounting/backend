{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Test helper: assemble minimal, namespaced @.xlsx@ bytes from rows of cell
-- text, without a spreadsheet writer. Shared by 'Infrastructure.Banking.XlsxSpec'
-- and 'Infrastructure.Banking.PrivatBankBusinessSpec' so both drive the reader
-- with synthetic — never real — data.
module Testkit.Xlsx
  ( buildXlsx,
    ns,
  )
where

import qualified Codec.Archive.Zip as Zip
import qualified Data.ByteString.Lazy as BSL
import Data.Char (chr)
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import RIO
import RIO.Char (isDigit, ord)
import qualified RIO.List as L

-- | The OOXML default namespace every real worksheet/shared-string part
-- declares. The fixtures emit it so the tests exercise the same namespaced XML
-- the real Автоклієнт export produces.
ns :: Text
ns = "xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""

-- | Assemble a minimal namespaced @.xlsx@ from rows of cell text. Non-numeric,
-- non-empty cells become deduplicated shared strings (@t=\"s\"@); bare decimals
-- become numeric @\<v\>@ cells (no @t@); an empty cell is omitted entirely
-- (proving the reader's gap-padding). Both XML parts declare the OOXML default
-- namespace so the fixture matches real files.
buildXlsx :: [[Text]] -> ByteString
buildXlsx rows =
  let strings = L.nub [cell | row <- rows, cell <- row, cell /= "", not (isNumeric cell)]
      strIndex = Map.fromList (zip strings [0 :: Int ..])
      sst = sharedStringsXml strings
      sheet = sheetXml strIndex rows
      archive =
        Zip.addEntryToArchive (Zip.toEntry "xl/worksheets/sheet1.xml" 0 (BSL.fromStrict (encodeUtf8 sheet)))
          $ Zip.addEntryToArchive
            (Zip.toEntry "xl/sharedStrings.xml" 0 (BSL.fromStrict (encodeUtf8 sst)))
            Zip.emptyArchive
   in BSL.toStrict (Zip.fromArchive archive)

sharedStringsXml :: [Text] -> Text
sharedStringsXml strings =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<sst "
    <> ns
    <> ">"
    <> T.concat ["<si><t>" <> escapeXml s <> "</t></si>" | s <- strings]
    <> "</sst>"

sheetXml :: Map Text Int -> [[Text]] -> Text
sheetXml strIndex rows =
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    <> "<worksheet "
    <> ns
    <> "><sheetData>"
    <> T.concat [rowXml n row | (n, row) <- zip [1 :: Int ..] rows]
    <> "</sheetData></worksheet>"
  where
    rowXml n row =
      "<row r=\""
        <> tshow n
        <> "\">"
        <> T.concat [cellXml n j cell | (j, cell) <- zip [0 :: Int ..] row, cell /= ""]
        <> "</row>"
    cellXml n j cell =
      let ref = colLetter j <> tshow n
       in if isNumeric cell
            then "<c r=\"" <> ref <> "\"><v>" <> escapeXml cell <> "</v></c>"
            else
              "<c r=\""
                <> ref
                <> "\" t=\"s\"><v>"
                <> tshow (Map.findWithDefault 0 cell strIndex)
                <> "</v></c>"

-- | Spreadsheet column letter for a 0-based index (fixtures use columns A–Z).
colLetter :: Int -> Text
colLetter j = T.singleton (chr (ord 'A' + j))

-- | A cell is emitted numeric when it is a non-empty bare decimal/integer
-- (digits, an optional leading @-@, at most one @.@).
isNumeric :: Text -> Bool
isNumeric t =
  not (T.null t)
    && T.any isDigit t
    && T.all (\c -> isDigit c || c == '.' || c == '-') t

escapeXml :: Text -> Text
escapeXml = T.replace ">" "&gt;" . T.replace "<" "&lt;" . T.replace "&" "&amp;"
