{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBankSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Domain.Banking.Types (unBankProviderId)
import Infrastructure.Banking.PrivatBank (descriptor)
import Infrastructure.Banking.PrivatBank.Internal (parsePrivatBankCsv)
import Infrastructure.Banking.Provider
import RIO
import qualified RIO.Map as Map
import Test.Hspec

-- | The committed real-world PrivatBank export: 1 title preamble line, 1
-- header line, then 103 data rows.
loadFixture :: IO BS.ByteString
loadFixture = BS.readFile "test/fixtures/privatbank-sample.csv"

-- | Build a minimal, ad-hoc PrivatBank-shaped CSV (preamble + header +
-- caller-supplied data rows) so structural/row-isolation cases don't depend
-- on the shape of the large fixture. Every line, including the last, ends
-- with a terminator: cassava's incremental header parser needs one to
-- recognize a header-only (zero data row) input as complete.
mkCsv :: [Text] -> BS.ByteString
mkCsv dataRows =
  encodeUtf8
    $ T.concat
    $ map
      (<> "\r\n")
      ( [ "Історія операцій за період 11.04.2026 - 11.07.2026,,,,,,,,,",
          header
        ]
          <> dataRows
      )
  where
    header =
      T.intercalate
        ","
        [ "Дата",
          "Категорія",
          "Картка",
          "Опис операції",
          "Сума в валюті картки",
          "Валюта картки",
          "Сума в валюті транзакції",
          "Валюта транзакції",
          "Залишок на кінець періоду",
          "Валюта залишку"
        ]

goodRow :: Text
goodRow =
  T.intercalate
    ","
    [ "10.07.2026 03:30:50",
      "Платежі за реквізитами",
      "0000 **** **** 0000",
      "Опис",
      "-281",
      "UAH",
      "281",
      "UAH",
      "87654.32",
      "UAH"
    ]

badDateRow :: Text
badDateRow =
  T.intercalate
    ","
    [ "not-a-date",
      "Категорія",
      "0000 **** **** 0000",
      "Опис",
      "-100",
      "UAH",
      "100",
      "UAH",
      "1000.00",
      "UAH"
    ]

spec :: Spec
spec = describe "Infrastructure.Banking.PrivatBank" $ do
  describe "parsePrivatBankCsv on the real fixture" $ do
    it "parses exactly 103 rows, all successful" $ do
      bytes <- loadFixture
      case parsePrivatBankCsv bytes of
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)
        Right results -> do
          length results `shouldBe` 103
          all isRight results `shouldBe` True

    it "classifies a known negative-amount row as an expense" $ do
      bytes <- loadFixture
      case parsePrivatBankCsv bytes of
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)
        Right results -> case results of
          (Right tx : _) -> do
            tx.amount `shouldBe` (-281)
            defaultClassify tx `shouldBe` ClassifiedExpense
          _ -> expectationFailure "expected the first row to be a successfully parsed transaction"

    it "classifies a known positive Зарахування row as income" $ do
      bytes <- loadFixture
      case parsePrivatBankCsv bytes of
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)
        Right results -> case drop 12 results of
          (Right tx : _) -> do
            tx.amount `shouldBe` 40000
            defaultClassify tx `shouldBe` ClassifiedIncome
            tx.categoryHint `shouldBe` Just "Зарахування"
          _ -> expectationFailure "expected row 13 to be a successfully parsed transaction"

    it "reports currencyCode 980 for a UAH row" $ do
      bytes <- loadFixture
      case parsePrivatBankCsv bytes of
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)
        Right results -> case results of
          (Right tx : _) -> tx.currencyCode `shouldBe` 980
          _ -> expectationFailure "expected the first row to be a successfully parsed transaction"

    it "is deterministic: parsing the same bytes twice yields identical externalIds" $ do
      bytes <- loadFixture
      let externalIds parsed = [tx.externalId | Right tx <- parsed]
      case (parsePrivatBankCsv bytes, parsePrivatBankCsv bytes) of
        (Right r1, Right r2) -> externalIds r1 `shouldBe` externalIds r2
        _ -> expectationFailure "expected both parses to succeed"

  describe "parsePrivatBankCsv on ad-hoc CSVs" $ do
    it "returns Right [] for a header-only input (no data rows)" $ do
      parsePrivatBankCsv (mkCsv []) `shouldBe` Right []

    it "isolates a single corrupted-date row without failing the whole file" $ do
      case parsePrivatBankCsv (mkCsv [badDateRow, goodRow]) of
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)
        Right results -> do
          length results `shouldBe` 2
          case results of
            [Left _rowErr, Right _tx] -> pure ()
            other -> expectationFailure ("expected [Left _, Right _], got: " <> show (map isRight other))

    it "returns Left ParseError when a required header column is missing/renamed" $ do
      let badHeader =
            T.intercalate
              "\r\n"
              [ "Історія операцій за період 11.04.2026 - 11.07.2026,,,,,,,,,",
                T.intercalate
                  ","
                  [ "Дата",
                    "Категорія",
                    "Картка",
                    "Опис операції",
                    "СумаНеТаКолонка", -- renamed: was "Сума в валюті картки"
                    "Валюта картки",
                    "Сума в валюті транзакції",
                    "Валюта транзакції",
                    "Залишок на кінець періоду",
                    "Валюта залишку"
                  ],
                goodRow
              ]
          bytes = encodeUtf8 badHeader
      case parsePrivatBankCsv bytes of
        Left (ParseError _msg) -> pure ()
        Right _ -> expectationFailure "expected a structural ParseError for the renamed column"

  describe "descriptor" $ do
    it "has the privatbank id and display name" $ do
      unBankProviderId descriptor.providerId `shouldBe` "privatbank"
      descriptor.displayName `shouldBe` "PrivatBank"

    it "supports file import (CSV) and not the pull transport" $ do
      isNothing descriptor.pull `shouldBe` True
      case descriptor.fileImport of
        Nothing -> expectationFailure "expected fileImport to be present"
        Just cap -> Map.keys cap.parsers `shouldBe` [StatementCsv]
