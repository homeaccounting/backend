{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankImportFileAPISpec
-- Description : HTTP tests for the connection-scoped statement-file endpoints
--
-- Covers the two file-upload endpoints for a stored connection:
-- @POST /api/banking/connections/:id/import/file@ (statement import, the
-- counterpart to the pull @POST .../import@) and
-- @POST /api/banking/connections/:id/external-accounts/from-file@ (account
-- discovery, the counterpart to the pull @GET .../external-accounts@; see
-- 'Web.API.BankingAPISpec'). Unlike every other banking spec, the
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
import Domain.Core.Types (AccountId, Currency (..), TransactionType (Transfer), mkAccountId)
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
    stubFileOnlyDescriptor,
  )
import Testkit.Helpers (mockExchangeRate)
import Testkit.HspecWai (IdResponse (..), bearerHeader, createAccountWith, jsonAuthHeaders, registerAndGetToken)
import Testkit.InMemoryEventStore (runDbIn)
import Web.Types (ErrorResponse (..), SyncVersionResponse (..))

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

-- | Fixed multipart boundary used to frame the single uploaded file part.
multipartBoundary :: BS.ByteString
multipartBoundary = "----BankImportFileBoundary"

-- | Frame a list of file parts as an RFC-2046 @multipart/form-data@ body:
-- each @(fieldName, fileName, bytes)@ entry becomes one file part, and the
-- whole is closed by the terminating @--boundary--@ delimiter. Mirrors what a
-- browser produces for a (possibly multi-file) upload, matching the
-- endpoint's 'Servant.Multipart.MultipartForm' expectation.
multipartBodyParts :: [(Text, Text, BS.ByteString)] -> BSL.ByteString
multipartBodyParts parts =
  BSL.fromChunks (concatMap partChunks parts <> [closingDelimiter])
  where
    partChunks (fieldName, fileName, bytes) =
      [ "--",
        multipartBoundary,
        "\r\n",
        "Content-Disposition: form-data; name=\"",
        encodeUtf8 fieldName,
        "\"; filename=\"",
        encodeUtf8 fileName,
        "\"\r\n",
        "Content-Type: application/octet-stream\r\n\r\n",
        bytes,
        "\r\n"
      ]
    closingDelimiter = "--" <> multipartBoundary <> "--\r\n"

-- | A @multipart/form-data@ body carrying a single non-file input field and
-- NO file part — used to exercise the handler's zero-file-parts branch.
multipartBodyNoFile :: BSL.ByteString
multipartBodyNoFile =
  BSL.fromChunks
    [ "--",
      multipartBoundary,
      "\r\n",
      "Content-Disposition: form-data; name=\"note\"\r\n\r\n",
      "no file here",
      "\r\n--",
      multipartBoundary,
      "--\r\n"
    ]

-- | Upload statement bytes to a connection's file-import endpoint as a
-- single-file @multipart/form-data@ request — the single-file case of
-- 'uploadStatements'.
uploadStatement :: Text -> Text -> Text -> BS.ByteString -> WaiSession st SResponse
uploadStatement tok connId format bytes =
  uploadStatements tok connId format [("file", "statement", bytes)]

-- | Upload several statement files to a connection's file-import endpoint in a
-- single multi-file @multipart/form-data@ request. Each entry is a
-- @(fieldName, fileName, bytes)@ file part.
uploadStatements :: Text -> Text -> Text -> [(Text, Text, BS.ByteString)] -> WaiSession st SResponse
uploadStatements tok connId format parts =
  request
    "POST"
    (importFilePath connId format)
    [ bearerHeader tok,
      (hContentType, "multipart/form-data; boundary=" <> multipartBoundary)
    ]
    (multipartBodyParts parts)

-- | Like 'uploadStatement', but POSTs a multipart body with zero file parts.
uploadNoFile :: Text -> Text -> Text -> WaiSession st SResponse
uploadNoFile tok connId format =
  request
    "POST"
    (importFilePath connId format)
    [ bearerHeader tok,
      (hContentType, "multipart/form-data; boundary=" <> multipartBoundary)
    ]
    multipartBodyNoFile

-- | @POST .../external-accounts/from-file?format=<format>@ path — the
-- account-discovery counterpart of 'importFilePath'.
discoverFilePath :: Text -> Text -> ByteString
discoverFilePath connId format =
  encodeUtf8 ("/api/banking/connections/" <> connId <> "/external-accounts/from-file?format=" <> format)

-- | POST one or more statement files to a connection's file-discovery endpoint
-- (single multi-file @multipart/form-data@ request), reusing 'multipartBodyParts'.
discoverAccounts :: Text -> Text -> Text -> [(Text, Text, BS.ByteString)] -> WaiSession st SResponse
discoverAccounts tok connId format parts =
  request
    "POST"
    (discoverFilePath connId format)
    [ bearerHeader tok,
      (hContentType, "multipart/form-data; boundary=" <> multipartBoundary)
    ]
    (multipartBodyParts parts)

-- | Decode a file-discovery response body into a list of external-account
-- objects (aeson 'KeyMap.KeyMap's).
asObjectArray :: SResponse -> IO [KeyMap.KeyMap Value]
asObjectArray resp =
  case eitherDecode (simpleBody resp) :: Either String Value of
    Right (Array rows) -> pure [o | Object o <- toList rows]
    other -> throwString $ "expected a JSON array of objects, got: " <> show other

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
-- connection — the single-entry case of 'setAccountMapMany'.
setAccountMap :: Text -> Text -> Text -> Text -> WaiSession st ()
setAccountMap tok connId extId accId = setAccountMapMany tok connId [(extId, accId)]

-- | Set several @externalId -> local account@ entries in one PUT (the PUT
-- replaces the whole map), so a connection can map multiple cards to distinct
-- local accounts.
setAccountMapMany :: Text -> Text -> [(Text, Text)] -> WaiSession st ()
setAccountMapMany tok connId entries = do
  let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/accounts")
      body = encode $ object ["accountMap" .= object [Key.fromText extId .= accId | (extId, accId) <- entries]]
  r <- request "PUT" path (jsonAuthHeaders tok) body
  liftIO $ simpleStatus r `shouldBe` status204

-- | Resolve a local-account id (UUID text) into a domain 'AccountId', for
-- querying the transaction read model.
resolveAccountId :: Text -> IO AccountId
resolveAccountId accId = do
  uuid <- maybe (throwString "invalid account id") pure (UUID.fromText accId)
  either (throwString . T.unpack) pure (mkAccountId uuid)

-- | GET \/api\/sync\/version for the caller, decoded to its Word64 counter —
-- used to prove a bank import bumps the importer's "data changed" signal
-- (tracker#45), mirroring 'Web.API.SyncAPIIntegrationSpec.bumpsAfterWriteSpec'.
getSyncVersion :: Text -> WaiSession st Word64
getSyncVersion tok = do
  resp <- request "GET" "/api/sync/version" [bearerHeader tok] ""
  case eitherDecode (simpleBody resp) :: Either String SyncVersionResponse of
    Left err -> liftIO $ throwString $ "getSyncVersion: " <> err
    Right r -> pure r.version

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

-- | A plain (non-transfer) PrivatBank expense row on an arbitrary @card@, with
-- a caller-chosen signed @amount@ and @balance@. The synthetic external id is
-- @date:amount:balance@ (card-independent), so distinct amounts keep two rows
-- from colliding under dedup. Mirrors 'goodRow' but parametric on card.
cardRow :: Text -> Text -> Text -> Text
cardRow card amount balance =
  T.intercalate
    ","
    [ "10.07.2026 03:30:50",
      "Платежі за реквізитами",
      card,
      "Опис",
      amount,
      "UAH",
      T.dropWhile (== '-') amount,
      "UAH",
      balance,
      "UAH"
    ]

-- Two card masks with distinct last-4 digits, so the PrivatBank self-transfer
-- matcher can tell them apart (it keys on the last-4 named in the description).
transferCardA, transferCardB :: Text
transferCardA = "1111 **** **** 1111"
transferCardB = "2222 **** **** 2222"

-- | A PrivatBank-shaped self-transfer row on @card@ whose description names the
-- counterpart card by its last-4 (@На свою картку@ / @Зі своєї картки@), so the
-- 'PrivatBank.privatBankTransferMatcher' pairs it with the opposite leg.
transferRow :: Text -> Text -> Text -> Text -> Text
transferRow card desc amount balance =
  T.intercalate
    ","
    [ "10.07.2026 03:30:50",
      "Перекази",
      card,
      desc,
      amount,
      "UAH",
      amount,
      "UAH",
      balance,
      "UAH"
    ]

-- | Debit leg (money out of card A), naming card B's last-4.
transferDebitRow :: Text
transferDebitRow = transferRow transferCardA "На свою картку *2222" "-500" "1500.00"

-- | Credit leg (money into card B), naming card A's last-4, equal magnitude.
transferCreditRow :: Text
transferCreditRow = transferRow transferCardB "Зі своєї картки *1111" "500" "2500.00"

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
  dataVersionBumpSpec
  scopedRoutingSpec
  multiFileTransferSpec
  sameBatchDuplicateSpec
  idempotentReuploadSpec
  rowErrorSpec
  noFilePartSpec
  unsupportedFormatSpec
  notFoundSpec
  disabledSpec
  discoverAccountsSpec
  discoverAccountsUnsupportedFormatSpec

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

-- | Bank import is the HEADLINE case for the "data changed" signal
-- (tracker#45): the importing user never touches the ordinary
-- account\/transaction HTTP write handlers, so this is the one entry point the
-- signal's other tests don't cover. Mirrors 'singleAccountImportSpec'\'s setup
-- (real PrivatBank fixture, single mapped account, 103 rows) and additionally
-- reads @GET \/api\/sync\/version@ for the importing user immediately before
-- and after the upload — asserting strictly-greater (not an exact delta),
-- since a single import of N transactions may bump the counter by any amount
-- >= 1.
dataVersionBumpSpec :: Spec
dataVersionBumpSpec =
  describe "POST /api/banking/connections/:id/import/file (data-version signal)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "strictly bumps the importer's sync data-version counter"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      bytes <- liftIO loadFixtureBytes
      before <- getSyncVersion tok
      resp <- uploadStatement tok connId "csv" bytes
      after <- getSyncVersion tok
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        o <- asObject resp
        case accountRow o fixtureCard of
          Nothing -> expectationFailure $ "expected an account row for " <> T.unpack fixtureCard
          Just row -> KeyMap.lookup "importedCount" row `shouldBe` Just (Number 103)
        (before, after) `shouldSatisfy` (\(b, a) -> a > b)

-- | A single-entry accountMap routes each card by its REAL external id, not
-- everything-to-the-one-account. Uploading a file with rows for the mapped
-- card A and an UNMAPPED card B must import card A's row into account A and
-- leave card B's row unresolved (never routed to A). This pins the retirement
-- of the old single-account "route every card to the one target" sentinel.
scopedRoutingSpec :: Spec
scopedRoutingSpec =
  describe "POST /api/banking/connections/:id/import/file (single-entry map routes by real id)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "imports the mapped card's row and leaves an unmapped card's row unresolved"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accA <- createAccountWith tok "Card A" "UAH"
      connId <- addPrivatConnection tok "Privat"
      -- Only card A is mapped; card B is deliberately absent from the map.
      setAccountMap tok connId transferCardA accA
      let bytes =
            mkCsv
              [ cardRow transferCardA "-281" "87654.32",
                cardRow transferCardB "-99" "12345.67"
              ]
      resp <- uploadStatement tok connId "csv" bytes
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        o <- asObject resp
        -- Card A's row routed to account A.
        case accountRow o transferCardA of
          Nothing -> expectationFailure $ "expected an account row for " <> T.unpack transferCardA
          Just row -> do
            KeyMap.lookup "localAccountId" row `shouldBe` Just (String accA)
            KeyMap.lookup "importedCount" row `shouldBe` Just (Number 1)
        -- Card B is unmapped: it is NOT routed to A (no account row for it) and
        -- its mask surfaces in 'unresolved'.
        accountRow o transferCardB `shouldBe` Nothing
        case KeyMap.lookup "unresolved" o of
          Just (Array rows) -> [t | String t <- toList rows] `shouldBe` [transferCardB]
          other -> expectationFailure $ "expected unresolved array, got: " <> show other
        -- Exactly one transaction landed (card A's); card B's did not book.
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 1

-- | A two-file upload whose files carry the two legs of one internal transfer
-- (file 1: card A's debit, file 2: card B's matching credit) must collapse
-- into a SINGLE 'Transfer' A->B. This only works if BOTH files feed one
-- 'importMany' batch — the whole point of concatenating every uploaded file.
-- With the map carrying two cards mapped to two distinct accounts, routing
-- hits the multi-account branch (route by real mask), so the pairing engine
-- sees both legs and pairs them.
multiFileTransferSpec :: Spec
multiFileTransferSpec =
  describe "POST /api/banking/connections/:id/import/file (transfer across two files)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "pairs a transfer whose legs arrive in separate files into one Transfer"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accA <- createAccountWith tok "Card A" "UAH"
      accB <- createAccountWith tok "Card B" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMapMany tok connId [(transferCardA, accA), (transferCardB, accB)]
      let file1 = mkCsv [transferDebitRow]
          file2 = mkCsv [transferCreditRow]
      resp <-
        uploadStatements
          tok
          connId
          "csv"
          [ ("file", "cardA.csv", file1),
            ("file", "cardB.csv", file2)
          ]
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        -- Exactly ONE transaction was created across the two files: the two
        -- legs collapsed into a single Transfer rather than double-booking an
        -- income + an expense.
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 1
        -- ... and that one transaction is a Transfer from account A (debit
        -- leg) to account B (credit leg).
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
          other -> expectationFailure $ "expected exactly one transfer row, got " <> show (length other)

-- | Multi-file import makes it easy to upload overlapping statements, so the
-- SAME transaction row can appear in two files of a single batch. The
-- composite external id (date + amount + balance) collides, so it must be
-- imported exactly ONCE (dedup within the batch), not double-booked — the
-- second occurrence is skipped as already-imported.
sameBatchDuplicateSpec :: Spec
sameBatchDuplicateSpec =
  describe "POST /api/banking/connections/:id/import/file (duplicate row across files)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "imports a row appearing in two files of one batch only once (dedup)"
    $ do
      controls <- getState
      liftIO $ seedRate controls
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      -- The identical single row in both files (same date/amount/balance ->
      -- same synthetic external id).
      let dup = mkCsv [goodRow]
      resp <-
        uploadStatements
          tok
          connId
          "csv"
          [ ("file", "first.csv", dup),
            ("file", "second.csv", dup)
          ]
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        o <- asObject resp
        case accountRow o fixtureCard of
          Nothing -> expectationFailure $ "expected an account row for " <> T.unpack fixtureCard
          Just row -> do
            KeyMap.lookup "importedCount" row `shouldBe` Just (Number 1)
            case KeyMap.lookup "skipped" row of
              Just (Array skips) -> length skips `shouldBe` 1
              other -> expectationFailure ("expected a 'skipped' array, got " <> show other)
        -- Only one transaction landed in the event store: the duplicate was
        -- deduplicated within the single batch rather than double-booked.
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 1

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

-- | A multipart upload that carries no file part (only a plain input field)
-- is rejected with 422 STATEMENT_PARSE_ERROR — there is nothing to parse.
noFilePartSpec :: Spec
noFilePartSpec =
  describe "POST /api/banking/connections/:id/import/file (no file part)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "returns 422 STATEMENT_PARSE_ERROR when the multipart body has no file"
    $ do
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      resp <- uploadNoFile tok connId "csv"
      liftIO $ do
        simpleStatus resp `shouldBe` status422
        e <- decodeError resp
        e.code `shouldBe` "STATEMENT_PARSE_ERROR"

-- | A format the provider does not support is rejected with 422
-- @UNSUPPORTED_STATEMENT_FORMAT@. Backed by 'stubFileOnlyDescriptor', which
-- registers only a 'Infrastructure.Banking.Provider.StatementCsv' parser, so
-- @?format=xlsx@ is unsupported. (The real PrivatBank descriptor now supports
-- both CSV and XLSX, so it can no longer exercise this path.)
unsupportedFormatSpec :: Spec
unsupportedFormatSpec =
  describe "POST /api/banking/connections/:id/import/file (unsupported format)"
    $ withState (mkAppBankingEnabledSeededWithFileProvider stubFileOnlyDescriptor)
    $ it "returns 422 for ?format=xlsx"
    $ do
      tok <- registerAndGetToken
      accId <- createAccountWith tok "PrivatCard" "UAH"
      connId <- addPrivatConnection tok "Privat"
      setAccountMap tok connId fixtureCard accId
      bytes <- liftIO loadFixtureBytes
      resp <- uploadStatement tok connId "xlsx" bytes
      liftIO $ do
        simpleStatus resp `shouldBe` status422
        e <- decodeError resp
        e.code `shouldBe` "UNSUPPORTED_STATEMENT_FORMAT"

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

-- | Uploading a two-card statement to the discovery endpoint returns exactly
-- the DISTINCT external accounts the file mentions — one per card, deduplicated
-- across the several rows each card has — with the right currency, and never
-- writes anything. This is the file analog of the pull external-accounts list.
discoverAccountsSpec :: Spec
discoverAccountsSpec =
  describe "POST /api/banking/connections/:id/external-accounts/from-file (discovery)"
    $ withState mkAppBankingEnabledSeededWithFileProviderPrivatBank
    $ it "lists each distinct card once with its currency, no duplicates"
    $ do
      controls <- getState
      tok <- registerAndGetToken
      connId <- addPrivatConnection tok "Privat"
      -- Two cards, multiple rows each (distinct amounts so they don't collide).
      let bytes =
            mkCsv
              [ cardRow transferCardA "-281" "87654.32",
                cardRow transferCardA "-99" "1000.00",
                cardRow transferCardB "-55" "2000.00",
                cardRow transferCardB "-77" "3000.00"
              ]
      resp <- discoverAccounts tok connId "csv" [("file", "statement.csv", bytes)]
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        rows <- asObjectArray resp
        -- Exactly two accounts, deduplicated despite four rows.
        length rows `shouldBe` 2
        let externalIds = [t | Just (String t) <- map (KeyMap.lookup "externalId") rows]
        Set.fromList externalIds `shouldBe` Set.fromList [transferCardA, transferCardB]
        -- No duplicates in the listing.
        length externalIds `shouldBe` 2
        -- Every account carries the parsed currency and the mask doubles as the
        -- masked PAN; discovery has no IBAN/balance.
        forM_ rows $ \row -> do
          KeyMap.lookup "currency" row `shouldBe` Just (String "UAH")
          KeyMap.lookup "iban" row `shouldBe` Just (String "")
          KeyMap.lookup "balance" row `shouldBe` Just (Number 0)
          case KeyMap.lookup "externalId" row of
            Just (String extId) -> KeyMap.lookup "maskedPan" row `shouldBe` Just (String extId)
            other -> expectationFailure $ "expected an externalId string, got: " <> show other
        -- Discovery is read-only: nothing was booked.
        txCount <- runDbIn controls.stubEnv TransactionRM.countTransactions
        txCount `shouldBe` 0

-- | An unsupported format is rejected with 422 @UNSUPPORTED_STATEMENT_FORMAT@
-- on the discovery endpoint too. Backed by 'stubFileOnlyDescriptor' (CSV-only),
-- exactly like the import endpoint's 'unsupportedFormatSpec' — the real
-- PrivatBank descriptor now registers both CSV and XLSX parsers, so it can no
-- longer exercise the unsupported path.
discoverAccountsUnsupportedFormatSpec :: Spec
discoverAccountsUnsupportedFormatSpec =
  describe "POST /api/banking/connections/:id/external-accounts/from-file (unsupported format)"
    $ withState (mkAppBankingEnabledSeededWithFileProvider stubFileOnlyDescriptor)
    $ it "returns 422 for ?format=xlsx"
    $ do
      tok <- registerAndGetToken
      connId <- addPrivatConnection tok "Privat"
      bytes <- liftIO loadFixtureBytes
      resp <- discoverAccounts tok connId "xlsx" [("file", "statement.csv", bytes)]
      liftIO $ do
        simpleStatus resp `shouldBe` status422
        e <- decodeError resp
        e.code `shouldBe` "UNSUPPORTED_STATEMENT_FORMAT"

-- | 'mkAppBankingEnabledSeededWithFileProvider' specialised to the REAL
-- 'PrivatBank.descriptor' (still keyed @"privatbank"@), so the committed CSV
-- fixture is actually parsed rather than served by the trivial
-- always-empty stub.
mkAppBankingEnabledSeededWithFileProviderPrivatBank :: IO (StubControls, Application)
mkAppBankingEnabledSeededWithFileProviderPrivatBank =
  mkAppBankingEnabledSeededWithFileProvider PrivatBank.descriptor
