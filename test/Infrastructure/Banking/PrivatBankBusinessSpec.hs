{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBankBusinessSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Ratio ((%))
import Data.Time (TimeOfDay (..), UTCTime (..), addUTCTime, fromGregorian, timeOfDayToTime)
import Domain.Banking.Types (unBankProviderId, unsafeExternalAccountId)
import Domain.Core.Types (mkBankProviderContact, unExternalTransactionId, unsafeExternalTransactionId)
import Infrastructure.Banking.PrivatBankBusiness (descriptor)
import Infrastructure.Banking.PrivatBankBusiness.Internal (fxSignal, parsePrivatBankBusinessXlsx)
import Infrastructure.Banking.Provider
import RIO
import Test.Hspec
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Xlsx (buildXlsx)

-- | The business statement's tabular header, addressed by name in the parser.
-- Column order here is arbitrary — the parser tolerates reordering.
header :: [Text]
header =
  [ "Референс",
    "Ваш рахунок",
    "Дата проводки",
    "Час проводки",
    "Сума",
    "Валюта",
    "ЄДРПОУ",
    "Назва контрагента",
    "Призначення платежу"
  ]

-- All values below are synthetic — no real names, IBANs, or tax ids.

-- | A UAH credit on account M1 with an exact decimal amount and a tax id.
uahRow :: [Text]
uahRow =
  [ "REF-UAH-1",
    "UA-ACC-1",
    "05.08.2026",
    "13:45:30",
    "41051.28",
    "UAH",
    "12345678",
    "ACME LLC",
    "Payment for services"
  ]

-- | A USD debit on account M2 (multi-account, mixed currency), blank tax id.
usdRow :: [Text]
usdRow =
  [ "REF-USD-1",
    "UA-ACC-2",
    "05.08.2026",
    "14:00:00",
    "-918.99",
    "USD",
    "",
    "BETA INC",
    "FX purchase"
  ]

-- | A row whose reference is blank — a per-row 'RowError' (no synthesis).
blankRefRow :: [Text]
blankRefRow =
  [ "",
    "UA-ACC-1",
    "05.08.2026",
    "15:00:00",
    "100.00",
    "UAH",
    "12345678",
    "ACME LLC",
    "Missing reference"
  ]

-- | A row with an unparsable amount — a per-row 'RowError'.
badAmountRow :: [Text]
badAmountRow =
  [ "REF-BAD-1",
    "UA-ACC-1",
    "05.08.2026",
    "16:00:00",
    "not-a-number",
    "UAH",
    "12345678",
    "ACME LLC",
    "Bad amount"
  ]

-- | Header preceded by a short preamble, then the four data rows.
statementBytes :: ByteString
statementBytes =
  buildXlsx
    [ ["Виписка по рахунках"],
      ["Період: 05.08.2026 - 05.08.2026"],
      header,
      uahRow,
      usdRow,
      blankRefRow,
      badAmountRow
    ]

spec :: Spec
spec = describe "Infrastructure.Banking.PrivatBankBusiness" $ do
  describe "parsePrivatBankBusinessXlsx" $ do
    it "parses the statement into one result per data row"
      $ case parsePrivatBankBusinessXlsx statementBytes of
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)
        Right results -> do
          length results `shouldBe` 4
          length (rights results) `shouldBe` 2

    it "maps the UAH row exactly (amount, currency, time, account, contact)"
      $ case parsePrivatBankBusinessXlsx statementBytes of
        Right (Right tx : _) -> do
          tx.amount `shouldBe` (4105128 % 100)
          tx.currencyCode `shouldBe` 980
          tx.time `shouldBe` UTCTime (fromGregorian 2026 8 5) (timeOfDayToTime (TimeOfDay 13 45 30))
          tx.externalAccountId `shouldBe` unsafeExternalAccountId "UA-ACC-1"
          tx.contact `shouldBe` mkBankProviderContact "12345678"
          tx.category `shouldBe` Nothing
          unExternalTransactionId tx.externalId `shouldBe` "REF-UAH-1"
          tx.description `shouldBe` "ACME LLC — Payment for services"
        other -> expectationFailure ("expected the UAH row to parse, got: " <> show (fmap (map isRight) other))

    it "maps the USD row on its own account and leaves a blank tax id empty"
      $ case parsePrivatBankBusinessXlsx statementBytes of
        Right (_ : Right tx : _) -> do
          tx.amount `shouldBe` ((-91899) % 100)
          tx.currencyCode `shouldBe` 840
          tx.externalAccountId `shouldBe` unsafeExternalAccountId "UA-ACC-2"
          tx.contact `shouldBe` Nothing
          unExternalTransactionId tx.externalId `shouldBe` "REF-USD-1"
        other -> expectationFailure ("expected the USD row to parse, got: " <> show (fmap (map isRight) other))

    it "isolates a blank-reference row as a RowError"
      $ case parsePrivatBankBusinessXlsx statementBytes of
        Right results -> case drop 2 results of
          (Left (RowError n _) : _) -> n `shouldBe` 3
          _ -> expectationFailure "expected the third data row to be a RowError"
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)

    it "isolates a malformed-amount row as a RowError"
      $ case parsePrivatBankBusinessXlsx statementBytes of
        Right results -> case drop 3 results of
          (Left (RowError n _) : _) -> n `shouldBe` 4
          _ -> expectationFailure "expected the fourth data row to be a RowError"
        Left err -> expectationFailure ("expected Right, got ParseError: " <> show err)

    it "isolates a row as a RowError when a required column is absent from the header"
      -- The header is detected (Референс + Сума present) but omits Валюта, a
      -- required column 'isHeaderRow' does not guarantee — the affected data row
      -- must fail per-row rather than crash or be dropped.
      $ let headerNoCurrency = filter (/= "Валюта") header
            dataNoCurrency = ["REF-NOCUR-1", "UA-ACC-1", "05.08.2026", "13:45:30", "41051.28", "12345678", "ACME LLC", "Payment"]
            bytes = buildXlsx [headerNoCurrency, dataNoCurrency]
         in case parsePrivatBankBusinessXlsx bytes of
              Right (Left (RowError n _) : _) -> n `shouldBe` 1
              other -> expectationFailure ("expected a RowError for the missing-column row, got: " <> show (fmap (map isRight) other))

    it "returns a whole-file ParseError when no header row is present"
      $ case parsePrivatBankBusinessXlsx (buildXlsx [["just"], ["a"], ["preamble"]]) of
        Left (ParseError _) -> pure ()
        other -> expectationFailure ("expected a header ParseError, got: " <> show (fmap (map isRight) other))

  describe "descriptor"
    $ it "advertises a file-import-only PrivatBank business provider (XLSX)"
    $ do
      unBankProviderId descriptor.providerId `shouldBe` "privatbank-business"
      providerSupportsFile descriptor `shouldBe` True
      providerSupportsPull descriptor `shouldBe` False
      case descriptor.fileImport of
        Just cap -> Map.keys cap.parsers `shouldBe` [StatementXlsx]
        Nothing -> expectationFailure "expected a file-import capability"

  describe "fxSignal" $ do
    it "reads the conversion amount from a UAH-proceeds conversion leg"
      $ fxSignal (fxTx uahProceedsDesc 41051.28 980 t0)
      `shouldBe` Just (FxLeg (91899 % 100))

    it "reads the conversion amount from a USD-sale conversion leg (ignoring the marker's bare currency code)"
      $ fxSignal (fxTx usdSaleDesc (-918.99) 840 t0)
      `shouldBe` Just (FxLeg (91899 % 100))

    it "returns Nothing for an ordinary, non-conversion row"
      $ fxSignal (fxTx "ACME LLC — Payment for services" 41051.28 980 t0)
      `shouldBe` Nothing

    it "reconstructs a space-grouped thousands amount (10 000.00) rather than collapsing to 0"
      $ fxSignal (fxTx "Продаж USD клієнта — Списання коштів … в сумі 10 000.00, USD, …" (-10000.00) 840 t0)
      `shouldBe` Just (FxLeg (1000000 % 100))

    it "reconstructs an NBSP-grouped thousands amount (10\160\&000.00) rather than collapsing to 0"
      $ fxSignal (fxTx "Продаж UAH клієнтів — Гривні від продажу 10\160\&000.00 USD по курсу 44.67" 446700.00 980 t0)
      `shouldBe` Just (FxLeg (1000000 % 100))

    it "reads the conversion amount from a EUR-sale conversion leg (any recognised currency, not just USD)"
      $ fxSignal (fxTx "Продаж EUR клієнта — Списання … в сумі 500.00, EUR, …" (-500.00) 978 t0)
      `shouldBe` Just (FxLeg (500 % 1))

  describe "fxTransferMatcher" $ do
    let matcher = (fxTransferMatcher fxSignal defaultFxPairingWindow).matchesTransfer
        usdLeg = fxTx usdSaleDesc (-918.99) 840 t0
        uahLeg = fxTx uahProceedsDesc 41051.28 980 t0

    it "pairs opposite-direction, cross-currency legs with the same conversion amount within the window"
      $ matcher usdLeg uahLeg
      `shouldBe` True

    it "is symmetric in its two legs for a valid pair"
      $ matcher usdLeg uahLeg
      `shouldBe` matcher uahLeg usdLeg

    it "rejects legs in the same currency"
      $ matcher usdLeg (uahLeg {currencyCode = 840})
      `shouldBe` False

    it "rejects legs in the same direction"
      $ matcher usdLeg (uahLeg {amount = -41051.28})
      `shouldBe` False

    it "rejects legs whose conversion amounts differ"
      $ matcher usdLeg (fxTx "Продаж UAH клієнтів — Гривні від продажу 1000.00 USD по курсу 44.67" 44570.00 980 t0)
      `shouldBe` False

    it "does not false-pair two distinct round-thousand conversions"
      $ let tenK = fxTx "Продаж USD клієнта — Списання коштів … в сумі 10 000.00, USD, …" (-10000.00) 840 t0
            fiveK = fxTx "Продаж UAH клієнтів — Гривні від продажу 5 000.00 USD по курсу 44.67" 223350.00 980 t0
         in matcher tenK fiveK `shouldBe` False

    it "rejects legs outside the pairing window"
      $ matcher usdLeg (uahLeg {time = addUTCTime 90000 t0})
      `shouldBe` False

    it "pairs legs exactly the pairing window apart (inclusive boundary)"
      $ matcher usdLeg (uahLeg {time = addUTCTime defaultFxPairingWindow t0})
      `shouldBe` True

    it "rejects legs just over the pairing window"
      $ matcher usdLeg (uahLeg {time = addUTCTime (defaultFxPairingWindow + 1) t0})
      `shouldBe` False

    it "rejects a pair when one leg carries no FX signal"
      $ matcher usdLeg (uahLeg {description = "ACME LLC — Payment for services"})
      `shouldBe` False
  where
    t0 = UTCTime (fromGregorian 2026 8 5) (timeOfDayToTime (TimeOfDay 14 0 0))
    uahProceedsDesc = "Продаж UAH клієнтів — Гривні від продажу 918.99 USD по курсу 44.67"
    usdSaleDesc = "Продаж USD клієнта — Списання коштів … в сумі 918.99, USD, …"
    fxTx :: Text -> Rational -> Int -> UTCTime -> BankTransaction
    fxTx desc amt cur t =
      (mkSameCurrencyBankTx (unsafeExternalTransactionId "fx") (unsafeExternalAccountId "acc") amt)
        { description = desc,
          currencyCode = cur,
          time = t
        }
