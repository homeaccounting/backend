{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.XlsxSpec (spec) where

import qualified Codec.Archive.Zip as Zip
import qualified Data.ByteString.Lazy as BSL
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.Vector as V
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (unsafeExternalTransactionId)
import Infrastructure.Banking.Provider (BankTransaction (..), ParseError (..), RowError (..))
import Infrastructure.Banking.Xlsx
  ( colRefIndex,
    parseSharedStrings,
    parseSheetRows,
    readXlsxSheet,
    xlsxStatementParser,
  )
import RIO
import Test.Hspec
import Testkit.Xlsx (buildXlsx, ns)

-- | Any valid 'BankTransaction'; its fields are never asserted in these tests.
stubTx :: Text -> BankTransaction
stubTx v =
  BankTransaction
    { externalId = unsafeExternalTransactionId v,
      externalAccountId = unsafeExternalAccountId "acc",
      time = UTCTime (fromGregorian 2026 1 1) 0,
      amount = 0,
      currencyCode = 980,
      description = v,
      hold = False,
      category = Nothing,
      contact = Nothing,
      originalAmount = Nothing,
      notes = Nothing
    }

spec :: Spec
spec = do
  describe "colRefIndex" $ do
    it "decodes single letters to 0-based indices" $ do
      colRefIndex "A1" `shouldBe` 0
      colRefIndex "G10" `shouldBe` 6
    it "decodes multi-letter refs bijectively (AA = 26)"
      $ colRefIndex "AA5"
      `shouldBe` 26

  describe "parseSharedStrings" $ do
    it "reads namespaced <sst><si><t> entries in order" $ do
      let bs = encodeUtf8 ("<sst " <> ns <> "><si><t>Сума</t></si><si><t>Валюта</t></si></sst>")
      parseSharedStrings bs `shouldBe` V.fromList ["Сума", "Валюта"]
    it "concatenates multiple <t> runs within one rich-text <si>" $ do
      let bs = encodeUtf8 ("<sst " <> ns <> "><si><r><t>Сум</t></r><r><t>а</t></r></si></sst>")
      parseSharedStrings bs `shouldBe` V.fromList ["Сума"]

  describe "parseSheetRows" $ do
    it "pads an omitted middle cell and keeps a numeric cell verbatim" $ do
      -- A and C present, B omitted entirely; D is a bare numeric cell (no t).
      let shared = V.fromList ["alpha", "gamma"]
          sheet =
            encodeUtf8
              $ "<worksheet "
              <> ns
              <> "><sheetData><row r=\"10\">"
              <> "<c r=\"A10\" t=\"s\"><v>0</v></c>"
              <> "<c r=\"C10\" t=\"s\"><v>1</v></c>"
              <> "<c r=\"D10\"><v>41051.28</v></c>"
              <> "</row></sheetData></worksheet>"
      parseSheetRows shared sheet `shouldBe` [["alpha", "", "gamma", "41051.28"]]
    it "positions a cell that omits its r by the running column cursor" $ do
      -- The middle cell has no r attribute; it must land in the slot after A.
      let shared = V.fromList ["x", "y"]
          sheet =
            encodeUtf8
              $ "<worksheet "
              <> ns
              <> "><sheetData><row r=\"5\">"
              <> "<c r=\"A5\" t=\"s\"><v>0</v></c>"
              <> "<c t=\"s\"><v>1</v></c>"
              <> "<c r=\"C5\"><v>3.14</v></c>"
              <> "</row></sheetData></worksheet>"
      parseSheetRows shared sheet `shouldBe` [["x", "y", "3.14"]]
    it "yields the empty string for a shared-string index out of range" $ do
      let shared = V.fromList ["only"]
          sheet =
            encodeUtf8
              $ "<worksheet "
              <> ns
              <> "><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>9</v></c></row></sheetData></worksheet>"
      parseSheetRows shared sheet `shouldBe` [[""]]
    it "reads an inline-string cell (t=inlineStr)" $ do
      let sheet =
            encodeUtf8
              $ "<worksheet "
              <> ns
              <> "><sheetData><row r=\"1\">"
              <> "<c r=\"A1\" t=\"inlineStr\"><is><t>hello</t></is></c>"
              <> "</row></sheetData></worksheet>"
      parseSheetRows V.empty sheet `shouldBe` [["hello"]]

  describe "readXlsxSheet" $ do
    it "round-trips synthetic .xlsx bytes, padding an omitted middle cell"
      $ readXlsxSheet (buildXlsx [["a", "b"], ["c", "", "e"]])
      `shouldBe` Right [["a", "b"], ["c", "", "e"]]
    it "fails with ParseError on non-archive bytes"
      $ case readXlsxSheet "not a zip archive" of
        Left (ParseError _) -> pure () :: IO ()
        other -> expectationFailure ("expected ParseError, got " <> show other)
    it "fails with ParseError on an archive lacking any worksheet" $ do
      let noSheet =
            BSL.toStrict
              . Zip.fromArchive
              $ Zip.addEntryToArchive
                (Zip.toEntry "xl/sharedStrings.xml" 0 (BSL.fromStrict (encodeUtf8 ("<sst " <> ns <> "/>"))))
                Zip.emptyArchive
      case readXlsxSheet noSheet of
        Left (ParseError _) -> pure () :: IO ()
        other -> expectationFailure ("expected ParseError, got " <> show other)

  describe "xlsxStatementParser" $ do
    let isHeaderRow cells = "L" `elem` cells
        validate col n
          | even n = Left (RowError n ("even: " <> fromMaybe "" (col "L")))
          | otherwise = Right (stubTx (fromMaybe "" (col "L")))
        parser = xlsxStatementParser "XLSX" isHeaderRow validate
        rows =
          [ ["Statement preamble"],
            ["Account 12345"],
            ["L", "amount"],
            ["r1", "10.00"],
            ["r2", "20.00"]
          ]
    it "detects the header past a preamble and 1-indexes data rows"
      $ case parser (buildXlsx rows) of
        Right [Right _, Left (RowError 2 _)] -> pure () :: IO ()
        other -> expectationFailure ("unexpected: " <> show other)
    it "returns Left ParseError when no row satisfies the header predicate"
      $ case xlsxStatementParser "XLSX" (const False) validate (buildXlsx rows) of
        Left (ParseError _) -> pure () :: IO ()
        other -> expectationFailure ("expected header ParseError, got " <> show other)
    it "propagates a readXlsxSheet failure as ParseError"
      $ case parser "not a zip archive" of
        Left (ParseError _) -> pure () :: IO ()
        other -> expectationFailure ("expected ParseError, got " <> show other)
    it "gives the accessor Nothing for a missing column or a short row" $ do
      -- Header has two columns; the sole data row has only one cell, so "H2"
      -- (present in the header, absent from the row) and "NoSuchCol" (absent
      -- from the header) both resolve to Nothing.
      let isHdr cells = "H1" `elem` cells
          check col _ =
            if isNothing (col "H2") && isNothing (col "NoSuchCol")
              then Right (stubTx "ok")
              else Left (RowError 1 "expected Nothing lookups")
          shortRows = [["H1", "H2"], ["v1"]]
      case xlsxStatementParser "XLSX" isHdr check (buildXlsx shortRows) of
        Right [Right _] -> pure () :: IO ()
        other -> expectationFailure ("unexpected: " <> show other)
