{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBankSpec (spec) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Domain.Banking.Types (unBankProviderId)
import Domain.Core.Types (mkBankProviderContact, mkByLabel)
import Infrastructure.Banking.PrivatBank (descriptor)
import Infrastructure.Banking.PrivatBank.Internal (counterpartyToken, parsePrivatBankCsv)
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

-- | A well-formed data row carrying the given category label (column 2).
rowWithCategory :: Text -> Text
rowWithCategory categoryLabel =
  T.intercalate
    ","
    [ "10.07.2026 03:30:50",
      categoryLabel,
      "0000 **** **** 0000",
      "Опис",
      "-281",
      "UAH",
      "281",
      "UAH",
      "87654.32",
      "UAH"
    ]

-- | A well-formed data row carrying the given description (column 4).
rowWithDescription :: Text -> Text
rowWithDescription description =
  T.intercalate
    ","
    [ "10.07.2026 03:30:50",
      "Категорія",
      "0000 **** **** 0000",
      description,
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
            tx.category `shouldBe` mkByLabel "Зарахування"
          _ -> expectationFailure "expected row 13 to be a successfully parsed transaction"

  describe "category label" $ do
    it "carries the PrivatBank category label as ByLabel"
      $ case parsePrivatBankCsv (mkCsv [rowWithCategory "Дім та ремонт"]) of
        Right [Right tx] -> tx.category `shouldBe` mkByLabel "Дім та ремонт"
        _ -> expectationFailure "expected one parsed row"

    it "leaves a blank category as Nothing"
      $ case parsePrivatBankCsv (mkCsv [rowWithCategory ""]) of
        Right [Right tx] -> tx.category `shouldBe` Nothing
        _ -> expectationFailure "expected one parsed row"

  describe "contact" $ do
    it "carries the PrivatBank counterparty descriptor as a contact signal"
      $ case parsePrivatBankCsv (mkCsv [rowWithDescription "Магазин РЕМОНТІ"]) of
        Right [Right tx] -> tx.contact `shouldBe` mkBankProviderContact "Магазин РЕМОНТІ"
        _ -> expectationFailure "expected one parsed row"

    it "leaves a blank descriptor as Nothing"
      $ case parsePrivatBankCsv (mkCsv [rowWithDescription ""]) of
        Right [Right tx] -> tx.contact `shouldBe` Nothing
        _ -> expectationFailure "expected one parsed row"

    it "still carries the self-transfer label as a contact signal (transfer classification happens upstream on description, independent of contact)"
      $ case parsePrivatBankCsv (mkCsv [rowWithDescription "На свою картку *0000"]) of
        Right [Right tx] -> tx.contact `shouldBe` mkBankProviderContact "На свою картку *0000"
        _ -> expectationFailure "expected one parsed row"

    it "strips the volatile comment tail from the contact signal, keeping the counterparty"
      $ case parsePrivatBankCsv (mkCsv [rowWithDescription "ТОВ Приклад. Коментар: платіж за послуги"]) of
        Right [Right tx] -> tx.contact `shouldBe` mkBankProviderContact "ТОВ Приклад"
        _ -> expectationFailure "expected one parsed row"

  -- NB: all descriptions below are synthetic placeholders — never paste real
  -- counterparty names, card numbers, or payment ids from bank exports here.
  describe "counterpartyToken" $ do
    it "strips a '. Коментар:' payment-purpose tail (which varies per transaction), keeping a comma-bearing counterparty"
      $ counterpartyToken "Компанія Приклад, ТОВ. Коментар: оплата за товар від платника"
      `shouldBe` "Компанія Приклад, ТОВ"

    it "strips a ', ID платежу:' per-transaction payment id"
      $ counterpartyToken "acme.ua, ID платежу: 1234567890"
      `shouldBe` "acme.ua"

    it "leaves a plain merchant untouched, including internal dots"
      $ counterpartyToken "acme.ua"
      `shouldBe` "acme.ua"

    it "leaves a trailing initial's dot untouched"
      $ counterpartyToken "Тест Т."
      `shouldBe` "Тест Т."

    it "leaves cosmetic city/double-conversion suffixes intact"
      $ do
        counterpartyToken "ACME MERCHANT, KYIV" `shouldBe` "ACME MERCHANT, KYIV"
        counterpartyToken "Acme Оплата з подвійною конвертацією pb.ua/conv"
          `shouldBe` "Acme Оплата з подвійною конвертацією pb.ua/conv"

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
