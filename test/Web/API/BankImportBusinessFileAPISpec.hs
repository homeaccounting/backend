{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankImportBusinessFileAPISpec
-- Description : HTTP tests for PrivatBank-business XLSX statement import
--
-- Drives the connection-scoped statement-file import endpoint
-- (@POST /api/banking/connections/:id/import/file@) end-to-end over HTTP with
-- the REAL 'Infrastructure.Banking.PrivatBankBusiness.descriptor' (registered
-- under @"privatbank-business"@ via
-- 'Testkit.AppEnv.mkAppBankingEnabledSeededWithFileProvider'), so synthetic
-- Автоклієнт XLSX bytes are parsed and interpreted end-to-end.
--
-- The business descriptor OR-composes the same-currency matcher with the FX
-- conversion matcher, so this spec pins the two transfer-pairing outcomes:
--
--   * a CROSS-currency conversion pair (a USD debit + a UAH credit that both
--     restate the same conversion amount) collapses into ONE cross-currency
--     'Transfer' with per-leg amounts and the implied 'ExchangeRate';
--   * a SAME-currency internal transfer still collapses into ONE 'Transfer'
--     with equal source/target amounts and a 'Nothing' rate (regression).
--
-- Runs on the IN-MEMORY event store (no @eventium_test@ DB). The harness does
-- not wire the transfer process manager, so a transfer is initiated (and
-- recorded in the read model at initiation, carrying its source/target amounts
-- and rate) but not posted — exactly like 'Web.API.BankImportFileAPISpec'.
module Web.API.BankImportBusinessFileAPISpec (spec) where

import qualified Application.ReadModels.Transaction as TransactionRM
import Data.Aeson
  ( eitherDecode,
    encode,
    object,
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Ratio ((%))
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Domain.Core.Page (mkPage)
import Domain.Core.Types
  ( AccountId,
    Currency (..),
    TransactionType (Transfer),
    exchangeRateSource,
    exchangeRateTarget,
    exchangeRateValue,
    mkAccountId,
    moneyCurrency,
    unMoney,
  )
import qualified Infrastructure.Banking.PrivatBankBusiness as PrivatBankBusiness
import Network.HTTP.Types (hContentType, status200, status204)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..), simpleBody, simpleStatus)
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv
  ( StubControls (..),
    mkAppBankingEnabledSeededWithFileProvider,
  )
import Testkit.HspecWai (IdResponse (..), bearerHeader, createAccountWith, jsonAuthHeaders, registerAndGetToken)
import Testkit.InMemoryEventStore (runDbIn)
import Testkit.Xlsx (buildXlsx)

-- -----------------------------------------------------------------------------
-- Multipart upload helpers (mirrors 'Web.API.BankImportFileAPISpec')
-- -----------------------------------------------------------------------------

-- | @POST .../import/file?format=<format>@ path for a connection.
importFilePath :: Text -> Text -> ByteString
importFilePath connId format =
  encodeUtf8 ("/api/banking/connections/" <> connId <> "/import/file?format=" <> format)

-- | Fixed multipart boundary used to frame the single uploaded file part.
multipartBoundary :: BS.ByteString
multipartBoundary = "----BankImportBusinessFileBoundary"

-- | Frame a single file part as an RFC-2046 @multipart/form-data@ body.
multipartBody :: BS.ByteString -> BSL.ByteString
multipartBody bytes =
  BSL.fromChunks
    [ "--",
      multipartBoundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"file\"; filename=\"statement.xlsx\"\r\n",
      "Content-Type: application/octet-stream\r\n\r\n",
      bytes,
      "\r\n--",
      multipartBoundary,
      "--\r\n"
    ]

-- | Upload statement bytes to a connection's file-import endpoint.
uploadStatement :: Text -> Text -> Text -> BS.ByteString -> WaiSession st SResponse
uploadStatement tok connId format bytes =
  request
    "POST"
    (importFilePath connId format)
    [ bearerHeader tok,
      (hContentType, "multipart/form-data; boundary=" <> multipartBoundary)
    ]
    (multipartBody bytes)

-- | Add a token-less @"privatbank-business"@ connection over HTTP and return
-- its @id@ (UUID text).
addBusinessConnection :: Text -> Text -> WaiSession st Text
addBusinessConnection tok name = do
  let body =
        encode
          $ object
            [ "provider" .= ("privatbank-business" :: Text),
              "name" .= name,
              "enabled" .= True
            ]
  resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
  case eitherDecode (simpleBody resp) :: Either String IdResponse of
    Left err -> liftIO $ throwString $ "addBusinessConnection: " <> err
    Right r -> pure r.id

-- | Set several @externalId -> local account@ entries in one PUT (the PUT
-- replaces the whole map).
setAccountMapMany :: Text -> Text -> [(Text, Text)] -> WaiSession st ()
setAccountMapMany tok connId entries = do
  let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/accounts")
      body = encode $ object ["accountMap" .= object [Key.fromText extId .= accId | (extId, accId) <- entries]]
  r <- request "PUT" path (jsonAuthHeaders tok) body
  liftIO $ simpleStatus r `shouldBe` status204

-- | Resolve a local-account id (UUID text) into a domain 'AccountId'.
resolveAccountId :: Text -> IO AccountId
resolveAccountId accId = do
  uuid <- maybe (throwString "invalid account id") pure (UUID.fromText accId)
  either (throwString . T.unpack) pure (mkAccountId uuid)

-- | 'Money' amounts and 'ExchangeRate' values serialize through 'Double' (see
-- their 'Data.Aeson.ToJSON'/'FromJSON' in 'Domain.Core.Types'), so a value
-- read back from the event store is the nearest 'Double' to the exact decimal.
-- Assertions on queried amounts/rates compare against the same round-trip so
-- they pin the real value rather than an unreachable exact rational.
viaDouble :: Rational -> Rational
viaDouble = toRational . (fromRational :: Rational -> Double)

-- -----------------------------------------------------------------------------
-- Synthetic XLSX fixtures (no real IBANs, names, tax ids, or purposes)
-- -----------------------------------------------------------------------------

-- | The business statement's tabular header, addressed by name in the parser.
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

-- | A data row: reference, account IBAN, signed amount, currency, and the
-- payment purpose (which carries any FX-conversion markers). Date/time and the
-- counterparty name/tax-id columns are fixed/blank for these fixtures.
mkRow :: Text -> Text -> Text -> Text -> Text -> [Text]
mkRow ref acc amount currency purpose =
  [ ref,
    acc,
    "05.08.2026",
    "14:00:00",
    amount,
    currency,
    "",
    "",
    purpose
  ]

-- | Prepend the header (with a short preamble) to the supplied data rows and
-- assemble the namespaced XLSX bytes.
buildBusinessXlsx :: [[Text]] -> ByteString
buildBusinessXlsx dataRows =
  buildXlsx
    ( [ ["Виписка по рахунках"],
        ["Період: 05.08.2026 - 05.08.2026"],
        header
      ]
        <> dataRows
    )

-- Two synthetic IBAN-shaped external account ids for the cross-currency pair.
crossUsdAcc, crossUahAcc :: Text
crossUsdAcc = "UA00CROSSUSD0000000000000000000"
crossUahAcc = "UA00CROSSUAH0000000000000000000"

-- | A cross-currency conversion pair: a USD debit that restates the conversion
-- amount in @в сумі 918.99, USD@ and a UAH credit that restates it in
-- @продажу 918.99 USD@. 'fxSignal' fires on both (matching the @Продаж USD@ /
-- @Продаж UAH@ markers) with an equal conversion amount, so they pair.
crossCurrencyBytes :: ByteString
crossCurrencyBytes =
  buildBusinessXlsx
    [ mkRow "REF-CC-USD" crossUsdAcc "-918.99" "USD" "Продаж USD клієнта — Списання коштів в сумі 918.99, USD",
      mkRow "REF-CC-UAH" crossUahAcc "41051.28" "UAH" "Продаж UAH клієнтів — Гривні від продажу 918.99 USD по курсу 44.67"
    ]

-- Two synthetic IBAN-shaped external account ids for the same-currency pair.
sameA, sameB :: Text
sameA = "UA00SAMEAAA0000000000000000000A"
sameB = "UA00SAMEBBB0000000000000000000B"

-- | A same-currency (UAH) internal transfer pair: equal magnitude, opposite
-- direction, ordinary (non-conversion) descriptions so only the same-currency
-- matcher pairs them.
sameCurrencyBytes :: ByteString
sameCurrencyBytes =
  buildBusinessXlsx
    [ mkRow "REF-SC-OUT" sameA "-500.00" "UAH" "Внутрішній переказ",
      mkRow "REF-SC-IN" sameB "500.00" "UAH" "Внутрішній переказ"
    ]

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  crossCurrencySpec
  sameCurrencySpec

-- | A conversion pair (USD debit on account A, UAH credit on account B) posts
-- as ONE cross-currency 'Transfer' with per-leg amounts and the implied rate.
crossCurrencySpec :: Spec
crossCurrencySpec =
  describe "POST /api/banking/connections/:id/import/file (cross-currency conversion)"
    $ withState mkApp
    $ it "posts a currency conversion as one cross-currency Transfer with the implied rate"
    $ do
      controls <- getState
      tok <- registerAndGetToken
      accUsd <- createAccountWith tok "USD account" "USD"
      accUah <- createAccountWith tok "UAH account" "UAH"
      connId <- addBusinessConnection tok "Business"
      setAccountMapMany tok connId [(crossUsdAcc, accUsd), (crossUahAcc, accUah)]
      resp <- uploadStatement tok connId "xlsx" crossCurrencyBytes
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        -- Exactly ONE transaction landed: the two legs collapsed into a single
        -- cross-currency Transfer rather than double-booking income + expense.
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 1
        accountIdUsd <- resolveAccountId accUsd
        accountIdUah <- resolveAccountId accUah
        page <- either (throwString . T.unpack) pure (mkPage Nothing Nothing)
        (total, rows) <-
          runDbIn
            controls.stubEnv
            (TransactionRM.listTransactions (Set.fromList [accountIdUsd, accountIdUah]) TransactionRM.emptyTransactionFilter page)
        total `shouldBe` 1
        case rows of
          [(_, txData)] -> do
            txData.transactionType `shouldBe` Transfer
            -- Debit (USD, negative) leg is the source; credit (UAH) is target.
            txData.sourceAccountId `shouldBe` accountIdUsd
            txData.targetAccountId `shouldBe` accountIdUah
            unMoney txData.sourceAmount `shouldBe` viaDouble (91899 % 100)
            moneyCurrency txData.sourceAmount `shouldBe` USD
            unMoney txData.targetAmount `shouldBe` viaDouble (4105128 % 100)
            moneyCurrency txData.targetAmount `shouldBe` UAH
            -- Implied rate = target magnitude / source magnitude ≈ 44.67.
            fmap exchangeRateValue txData.exchangeRate `shouldBe` Just (viaDouble (4105128 % 91899))
            fmap exchangeRateSource txData.exchangeRate `shouldBe` Just USD
            fmap exchangeRateTarget txData.exchangeRate `shouldBe` Just UAH
          other -> expectationFailure $ "expected exactly one transfer row, got " <> show (length other)

-- | A same-currency internal transfer still posts as ONE 'Transfer' with equal
-- source/target amounts and NO exchange rate (regression on the generalised
-- 'postInternalTransfer').
sameCurrencySpec :: Spec
sameCurrencySpec =
  describe "POST /api/banking/connections/:id/import/file (same-currency internal transfer)"
    $ withState mkApp
    $ it "posts a same-currency internal transfer with equal amounts and no rate"
    $ do
      controls <- getState
      tok <- registerAndGetToken
      accA <- createAccountWith tok "UAH account A" "UAH"
      accB <- createAccountWith tok "UAH account B" "UAH"
      connId <- addBusinessConnection tok "Business"
      setAccountMapMany tok connId [(sameA, accA), (sameB, accB)]
      resp <- uploadStatement tok connId "xlsx" sameCurrencyBytes
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 1
        accountIdA <- resolveAccountId accA
        accountIdB <- resolveAccountId accB
        page <- either (throwString . T.unpack) pure (mkPage Nothing Nothing)
        (total, rows) <-
          runDbIn
            controls.stubEnv
            (TransactionRM.listTransactions (Set.fromList [accountIdA, accountIdB]) TransactionRM.emptyTransactionFilter page)
        total `shouldBe` 1
        case rows of
          [(_, txData)] -> do
            txData.transactionType `shouldBe` Transfer
            txData.sourceAccountId `shouldBe` accountIdA
            txData.targetAccountId `shouldBe` accountIdB
            unMoney txData.sourceAmount `shouldBe` viaDouble (50000 % 100)
            unMoney txData.targetAmount `shouldBe` viaDouble (50000 % 100)
            moneyCurrency txData.sourceAmount `shouldBe` UAH
            moneyCurrency txData.targetAmount `shouldBe` UAH
            txData.exchangeRate `shouldBe` Nothing
          other -> expectationFailure $ "expected exactly one transfer row, got " <> show (length other)

-- | 'mkAppBankingEnabledSeededWithFileProvider' specialised to the REAL
-- 'PrivatBankBusiness.descriptor' (keyed @"privatbank-business"@).
mkApp :: IO (StubControls, Application)
mkApp = mkAppBankingEnabledSeededWithFileProvider PrivatBankBusiness.descriptor
