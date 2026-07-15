{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankImportFileAPISpec
-- Description : HTTP tests for the connection-scoped statement-file import endpoint
--
-- Covers @POST /api/banking/connections/:id/import/file@, the file-upload
-- counterpart to @POST /api/banking/connections/:id/import@ (the pull path;
-- see 'Web.API.BankingAPISpec'). Unlike every other banking spec, the
-- registry backing these tests wires in the REAL
-- 'Infrastructure.Banking.PrivatBank.descriptor' (via
-- 'Testkit.AppEnv.mkAppBankingEnabledSeededWithFileProvider') in place of the
-- trivial always-empty 'Testkit.AppEnv.stubFileOnlyDescriptor', so the
-- committed PrivatBank CSV fixture (@test/fixtures/privatbank-sample.csv@,
-- 103 data rows, all on card @0000 **** **** 0000@) is actually parsed
-- end-to-end over HTTP.
module Web.API.BankImportFileAPISpec (spec) where

import Application.ReadModels.ExchangeRate (applyExchangeRateEvent)
import qualified Application.ReadModels.Transaction as TransactionRM
import Data.Aeson
  ( Value (..),
    eitherDecode,
    encode,
    object,
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Text as T
import Data.Time (getCurrentTime, utctDay)
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Core.Page (mkPage)
import Domain.Core.Types (Currency (..), mkAccountId)
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Eventium (GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import qualified Infrastructure.Banking.PrivatBank as PrivatBank
import Network.HTTP.Types (hContentType, status200, status204, status404, status422)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv
  ( StubControls (..),
    mkAppBankingEnabledSeededWithFileProvider,
  )
import Testkit.Helpers (mockExchangeRate)
import Testkit.HspecWai (IdResponse (..), bearerHeader, createAccountWith, jsonAuthHeaders, registerAndGetToken)
import Testkit.InMemoryEventStore (runDbIn)
import Web.Types (ErrorResponse (..))

-- -----------------------------------------------------------------------------
-- Fixtures + small helpers (mirrors BankingAPISpec / BankConnectionAPISpec)
-- -----------------------------------------------------------------------------

-- | The card mask every row of the committed fixture is posted on.
fixtureCard :: Text
fixtureCard = "0000 **** **** 0000"

-- | Load the committed real-world PrivatBank export (1 preamble line, 1
-- header line, 103 data rows — see 'Infrastructure.Banking.PrivatBankSpec').
loadFixtureBytes :: IO BS.ByteString
loadFixtureBytes = BS.readFile "test/fixtures/privatbank-sample.csv"

-- | @POST .../import/file?format=<format>@ path for a connection.
importFilePath :: Text -> Text -> ByteString
importFilePath connId format =
  encodeUtf8 ("/api/banking/connections/" <> connId <> "/import/file?format=" <> format)

-- | Upload raw bytes to a connection's file-import endpoint.
uploadStatement :: Text -> Text -> Text -> BS.ByteString -> WaiSession st SResponse
uploadStatement tok connId format bytes =
  request
    "POST"
    (importFilePath connId format)
    [bearerHeader tok, (hContentType, "application/octet-stream")]
    (BSL.fromStrict bytes)

-- | Add a token-less @"privatbank"@ connection over HTTP and return its
-- @id@ (UUID text) — mirrors 'Web.API.BankConnectionAPISpec.tokenOptionalSpec'.
addPrivatConnection :: Text -> Text -> WaiSession st Text
addPrivatConnection tok name = addPrivatConnectionWith tok name True

-- | Like 'addPrivatConnection', but lets the caller set the @enabled@ flag —
-- mirrors 'Web.API.BankingAPISpec.addConnection'\'s @enabled@ parameter.
addPrivatConnectionWith :: Text -> Text -> Bool -> WaiSession st Text
addPrivatConnectionWith tok name enabled = do
  let body =
        encode
          $ object
            [ "provider" .= ("privatbank" :: Text),
              "name" .= name,
              "enabled" .= enabled
            ]
  resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
  case eitherDecode (simpleBody resp) :: Either String IdResponse of
    Left err -> liftIO $ throwString $ "addPrivatConnection: " <> err
    Right r -> pure r.id

-- | Map an external account id (a card mask) to a local account on a
-- connection.
setAccountMap :: Text -> Text -> Text -> Text -> WaiSession st ()
setAccountMap tok connId extId accId = do
  let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/accounts")
      body = encode $ object ["accountMap" .= object [Key.fromText extId .= accId]]
  r <- request "PUT" path (jsonAuthHeaders tok) body
  liftIO $ simpleStatus r `shouldBe` status204

-- | Decode an error envelope from a response body.
decodeError :: SResponse -> IO ErrorResponse
decodeError resp =
  case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
    Left err -> throwString $ "body is not an ErrorResponse: " <> err
    Right e -> pure e

-- | Decode a JSON object body to an aeson 'KeyMap.KeyMap'.
asObject :: SResponse -> IO (KeyMap.KeyMap Value)
asObject resp =
  case eitherDecode (simpleBody resp) :: Either String Value of
    Right (Object o) -> pure o
    other -> throwString $ "expected JSON object, got: " <> show other

-- | Publish today's USD<->UAH rate into the env's exchange-rate read model,
-- so importing a UAH statement into the caller's (base-currency USD)
-- External account can resolve. Mirrors 'Web.API.BankingAPISpec.seedRate'.
seedRate :: StubControls -> IO ()
seedRate controls = do
  today <- utctDay <$> getCurrentTime
  let rateMap =
        Map.fromList
          [ ((USD, UAH), mockExchangeRate USD UAH 41),
            ((UAH, USD), mockExchangeRate UAH USD (1 / 41))
          ]
      payload =
        ExchangeRatesPublishedEvent
          ExchangeRatesPublished
            { provider = "ecb",
              rates = rateMap,
              at = today
            }
      versionedEvent = StreamEvent UUID.nil 0 (emptyMetadata mempty) payload
      globalEvent :: GlobalStreamEvent AccountingEvent
      globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
  runDbIn controls.stubEnv (applyExchangeRateEvent globalEvent)

-- | Look up an account row from the JSON @accounts@ array by its
-- @externalAccountId@.
accountRow :: KeyMap.KeyMap Value -> Text -> Maybe (KeyMap.KeyMap Value)
accountRow o extId = do
  Array rows <- KeyMap.lookup "accounts" o
  listToMaybe [r | Object r <- toList rows, KeyMap.lookup "externalAccountId" r == Just (String extId)]

-- | A minimal, ad-hoc PrivatBank-shaped CSV (preamble + header + supplied
-- data rows), mirroring 'Infrastructure.Banking.PrivatBankSpec.mkCsv'.
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
      fixtureCard,
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
      fixtureCard,
      "Опис",
      "-100",
      "UAH",
      "100",
      "UAH",
      "1000.00",
      "UAH"
    ]

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  singleAccountImportSpec
  idempotentReuploadSpec
  rowErrorSpec
  unsupportedFormatSpec
  notFoundSpec
  disabledSpec

-- | Uploading the real fixture into a connection whose accountMap has
-- exactly one entry routes every row (all on the same card) to that one
-- local account.
singleAccountImportSpec :: Spec
singleAccountImportSpec =
  describe "POST /api/banking/connections/:id/import/file (single account)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "imports all 103 rows into the one mapped account, unresolved empty"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      bytes <- liftIO loadFixtureBytes
      resp <- uploadStatement tok connId "csv" bytes
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        o <- asObject resp
        KeyMap.lookup "unresolved" o `shouldBe` Just (Array mempty)
        case accountRow o fixtureCard of
          Nothing -> expectationFailure $ "expected an account row for " <> T.unpack fixtureCard
          Just row -> do
            KeyMap.lookup "localAccountId" row `shouldBe` Just (String accId)
            KeyMap.lookup "importedCount" row `shouldBe` Just (Number 103)
            KeyMap.lookup "skipped" row `shouldBe` Just (Array mempty)
            KeyMap.lookup "failureCount" row `shouldBe` Just (Number 0)
        -- The transactions actually landed in the event store: the read
        -- model shows 103 rows, and filtering by the mapped bank account
        -- shows all 103 reference it (i.e. every row was routed to the one
        -- mapped account). Balances are NOT asserted here: this harness does
        -- not wire the transfer process manager, so transfers are initiated
        -- (and recorded) but not posted — the same reason the pull-path HTTP
        -- spec checks counts rather than balances.
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 103
        accUuid <- maybe (throwString "invalid account id") pure (UUID.fromText accId)
        accountId <- either (throwString . T.unpack) pure (mkAccountId accUuid)
        page <- either (throwString . T.unpack) pure (mkPage Nothing Nothing)
        (referencing, _) <-
          runDbIn
            controls.stubEnv
            (TransactionRM.listTransactions (Set.singleton accountId) TransactionRM.emptyTransactionFilter page)
        referencing `shouldBe` 103

-- | Re-uploading the identical bytes is idempotent: every row is already
-- imported (deduplicated via the composite external id), so the second
-- upload imports 0 and skips all 103.
idempotentReuploadSpec :: Spec
idempotentReuploadSpec =
  describe "POST /api/banking/connections/:id/import/file (idempotent re-upload)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "second upload of the same bytes skips all rows (dedup)"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      bytes <- liftIO loadFixtureBytes
      _ <- uploadStatement tok connId "csv" bytes
      resp2 <- uploadStatement tok connId "csv" bytes
      liftIO $ do
        simpleStatus resp2 `shouldBe` status200
        o <- asObject resp2
        case accountRow o fixtureCard of
          Nothing -> expectationFailure $ "expected an account row for " <> T.unpack fixtureCard
          Just row -> do
            KeyMap.lookup "importedCount" row `shouldBe` Just (Number 0)
            case KeyMap.lookup "skipped" row of
              Just (Array skips) -> length skips `shouldBe` 103
              other -> expectationFailure ("expected a 'skipped' array, got " <> show other)
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 103

-- | A hand-built CSV with one good row and one structurally-parseable but
-- semantically-invalid (bad date) row: the good row is imported, and the bad
-- row's message surfaces in 'unresolved' rather than failing the request.
rowErrorSpec :: Spec
rowErrorSpec =
  describe "POST /api/banking/connections/:id/import/file (per-row error)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "imports the good row and surfaces the bad row's message in unresolved"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      let bytes = mkCsv [goodRow, badDateRow]
      resp <- uploadStatement tok connId "csv" bytes
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        o <- asObject resp
        case accountRow o fixtureCard of
          Nothing -> expectationFailure $ "expected an account row for " <> T.unpack fixtureCard
          Just row -> do
            KeyMap.lookup "importedCount" row `shouldBe` Just (Number 1)
            KeyMap.lookup "failureCount" row `shouldBe` Just (Number 0)
        case KeyMap.lookup "unresolved" o of
          Just (Array rows) -> do
            let texts = [t | String t <- toList rows]
            any (\t -> "row 2" `T.isInfixOf` t && "invalid date" `T.isInfixOf` t) texts
              `shouldBe` True
          other -> expectationFailure $ "expected unresolved array, got: " <> show other

-- | @?format=xlsx@ is rejected with 422: the real PrivatBank descriptor has
-- no xlsx parser registered (only 'Infrastructure.Banking.Provider.StatementCsv').
unsupportedFormatSpec :: Spec
unsupportedFormatSpec =
  describe "POST /api/banking/connections/:id/import/file (unsupported format)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "returns 422 for ?format=xlsx"
    $ do
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      bytes <- liftIO loadFixtureBytes
      resp <- uploadStatement tok connId "xlsx" bytes
      liftIO $ simpleStatus resp `shouldBe` status422

-- | An unknown connection id 404s, exactly like the pull endpoint.
notFoundSpec :: Spec
notFoundSpec =
  describe "POST /api/banking/connections/:id/import/file (unknown connection)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "returns 404 BANK_CONNECTION_NOT_FOUND when the connection does not exist"
    $ do
      tok <- registerAndGetToken
      connId <- liftIO UUID.nextRandom
      bytes <- liftIO loadFixtureBytes
      resp <- uploadStatement tok (tshow connId) "csv" bytes
      liftIO $ do
        simpleStatus resp `shouldBe` status404
        e <- decodeError resp
        e.code `shouldBe` "BANK_CONNECTION_NOT_FOUND"

-- | A disabled connection rejects a file upload with 422 CONNECTION_DISABLED,
-- exactly like the pull endpoint's 'Web.API.BankingAPISpec.disabledSpec' —
-- the file transport must be inert on a disabled connection too.
disabledSpec :: Spec
disabledSpec =
  describe "POST /api/banking/connections/:id/import/file (disabled connection)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "returns 422 CONNECTION_DISABLED when enabled == false"
    $ do
      tok <- registerAndGetToken
      connId <- addPrivatConnectionWith tok "Disabled" False
      bytes <- liftIO loadFixtureBytes
      resp <- uploadStatement tok connId "csv" bytes
      liftIO $ do
        simpleStatus resp `shouldBe` status422
        e <- decodeError resp
        e.code `shouldBe` "CONNECTION_DISABLED"

-- | 'mkAppBankingEnabledSeededWithFileProvider' specialised to the REAL
-- 'PrivatBank.descriptor' (still keyed @"privatbank"@), so the committed CSV
-- fixture is actually parsed rather than served by the trivial
-- always-empty stub.
mkAppBankingEnabledSeededWithFileProviderPrivatBank :: IO (StubControls, Application)
mkAppBankingEnabledSeededWithFileProviderPrivatBank =
  mkAppBankingEnabledSeededWithFileProvider PrivatBank.descriptor
