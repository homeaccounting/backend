{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankingAPISpec
-- Description : HTTP tests for the connection-scoped pull-import endpoint
--
-- Covers @POST /api/banking/connections/:id/import@ (renamed from @/resync@),
-- which replaced the header-based @POST /api/banking/resync@. The endpoint:
--
--   * is feature-gated: 404 @FEATURE_DISABLED@ when banking is off;
--   * 404s an unknown connection id;
--   * 422 @CONNECTION_DISABLED@ when the connection's @enabled@ flag is false;
--   * routes the import strictly by the connection's persisted
--     @externalId -> local account@ map: an external id present in the map
--     (and backed by the stub provider) is imported, while an external id
--     absent from the map is never fetched (reported as skipped by the
--     import summary — i.e. it produces no per-account row at all).
module Web.API.BankingAPISpec (spec) where

import Application.ReadModels.ExchangeRate (applyExchangeRateEvent)
import Data.Aeson
  ( Value (..),
    eitherDecode,
    encode,
    object,
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime (..), fromGregorian, getCurrentTime, secondsToDiffTime, utctDay)
import qualified Data.UUID as UUID0
import qualified Data.UUID.V4 as UUID
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (Currency (..), unsafeExternalTransactionId)
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Eventium (GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import Infrastructure.Banking.Provider (BankTransaction)
import Network.HTTP.Types (status200, status204, status404, status422)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv
  ( StubControls (..),
    mkApp,
    mkAppBankingEnabledSeeded,
    mkAppBankingEnabledSeededWith,
  )
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Helpers (mockExchangeRate)
import Testkit.HspecWai (IdResponse (..), createAccountWith, jsonAuthHeaders, registerAndGetToken)
import Testkit.InMemoryEventStore (runDbIn)
import Web.Types (ErrorResponse (..))

-- -----------------------------------------------------------------------------
-- Auth + small JSON helpers (mirrors BankConnectionAPISpec)
-- -----------------------------------------------------------------------------

-- | Add a connection over HTTP and return its @id@ (UUID text).
addConnection :: Text -> Text -> Bool -> WaiSession st Text
addConnection tok name enabled = do
  let body =
        encode
          $ object
            [ "provider" .= ("monobank" :: Text),
              "name" .= name,
              "token" .= ("super-secret-token-123" :: Text),
              "enabled" .= enabled
            ]
  resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
  case eitherDecode (simpleBody resp) :: Either String IdResponse of
    Left err -> liftIO $ throwString $ "addConnection: " <> err
    Right r -> pure r.id

-- | Map an external account id to a local account on a connection.
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

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

importPath :: Text -> ByteString
importPath connId = encodeUtf8 ("/api/banking/connections/" <> connId <> "/import")

sampleBody :: LByteString
sampleBody =
  encode
    $ object
      [ "from" .= fromDay,
        "to" .= toDay
      ]
  where
    fromDay :: UTCTime
    fromDay = UTCTime (fromGregorian 2026 4 1) 0
    toDay :: UTCTime
    toDay = UTCTime (fromGregorian 2026 4 10) (secondsToDiffTime 0)

-- | One same-currency statement (UAH) for the stub provider. @extAccId@
-- doubles as the external account id (the stub map key) and the transaction
-- id seed, which only needs to be unique.
sampleTxn :: Text -> BankTransaction
sampleTxn extAccId =
  mkSameCurrencyBankTx
    (unsafeExternalTransactionId ("tx-" <> extAccId))
    (unsafeExternalAccountId extAccId)
    1000

-- | Publish today's USD<->UAH rate into the env's exchange-rate read model
-- (via the stub controls) under the env's configured provider ("ecb"), so
-- the cross-currency import (UAH statement, USD base External account) can
-- resolve. Feeds a synthetic 'ExchangeRatesPublishedEvent' through
-- 'applyExchangeRateEvent' into the persistent read model, as production does.
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
      versionedEvent = StreamEvent UUID0.nil 0 (emptyMetadata mempty) payload
      globalEvent :: GlobalStreamEvent AccountingEvent
      globalEvent = StreamEvent () 0 (emptyMetadata mempty) versionedEvent
  runDbIn controls.stubEnv (applyExchangeRateEvent globalEvent)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  featureGateSpec
  notFoundSpec
  disabledSpec
  routesByAccountMapSpec

-- | Feature off (the default 'mkApp' ships banking.enabled = False): 404
-- FEATURE_DISABLED, hiding the endpoint's existence entirely.
featureGateSpec :: Spec
featureGateSpec =
  describe "POST /api/banking/connections/:id/import (feature disabled)"
    $ with mkApp
    $ it "returns 404 FEATURE_DISABLED when banking is off"
    $ do
      tok <- registerAndGetToken
      connId <- liftIO UUID.nextRandom
      resp <- request "POST" (importPath (T.pack (show connId))) (jsonAuthHeaders tok) sampleBody
      liftIO $ do
        simpleStatus resp `shouldBe` status404
        e <- decodeError resp
        e.code `shouldBe` "FEATURE_DISABLED"
        e.details `shouldBe` Just (Map.singleton "feature" "banking")

-- | Unknown connection id → 404 BANK_CONNECTION_NOT_FOUND.
notFoundSpec :: Spec
notFoundSpec =
  describe "POST /api/banking/connections/:id/import (unknown id)"
    $ with mkAppBankingEnabledSeeded
    $ it "returns 404 when the connection does not exist"
    $ do
      tok <- registerAndGetToken
      connId <- liftIO UUID.nextRandom
      resp <- request "POST" (importPath (T.pack (show connId))) (jsonAuthHeaders tok) sampleBody
      liftIO $ do
        simpleStatus resp `shouldBe` status404
        e <- decodeError resp
        e.code `shouldBe` "BANK_CONNECTION_NOT_FOUND"

-- | A disabled connection → 422 CONNECTION_DISABLED.
disabledSpec :: Spec
disabledSpec =
  describe "POST /api/banking/connections/:id/import (disabled connection)"
    $ with mkAppBankingEnabledSeeded
    $ it "returns 422 CONNECTION_DISABLED when enabled == false"
    $ do
      tok <- registerAndGetToken
      connId <- addConnection tok "Disabled" False
      resp <- request "POST" (importPath connId) (jsonAuthHeaders tok) sampleBody
      liftIO $ do
        simpleStatus resp `shouldBe` status422
        e <- decodeError resp
        e.code `shouldBe` "CONNECTION_DISABLED"

-- | Enabled + mapped: the import is routed strictly by accountMap. The stub
-- serves statements for two external ids, but only one is in the map, so only
-- that one produces a per-account summary row (with a positive import count);
-- the unmapped external id is never fetched.
routesByAccountMapSpec :: Spec
routesByAccountMapSpec =
  describe "POST /api/banking/connections/:id/import (enabled + mapped)"
    $ withState mkAppBankingEnabledSeededWith
    $ it "routes the import by accountMap (mapped imported, unmapped skipped)"
    $ do
      controls <- getState
      -- The auto-created External account is denominated in the base
      -- currency (USD), while the bank statements are UAH; seed a rate so
      -- the cross-currency import can resolve per-leg amounts.
      liftIO $ seedRate controls
      -- Stub serves statements for BOTH external ids ...
      liftIO
        $ writeIORef controls.stubStatements
        $ Map.fromList
          [ ("ext-mapped", [sampleTxn "ext-mapped"]),
            ("ext-unmapped", [sampleTxn "ext-unmapped"])
          ]
      tok <- registerAndGetToken
      accId <- createAccountWith tok "Wallet" "UAH"
      connId <- addConnection tok "Live" True
      -- ... but only "ext-mapped" is in the connection's accountMap.
      setAccountMap tok connId "ext-mapped" accId
      resp <- request "POST" (importPath connId) (jsonAuthHeaders tok) sampleBody
      liftIO $ do
        simpleStatus resp `shouldBe` status200
        o <- asObject resp
        case KeyMap.lookup "accounts" o of
          Just (Array rows) -> do
            let objs = [r | Object r <- toList rows]
                extIds = [i | r <- objs, Just (String i) <- [KeyMap.lookup "externalAccountId" r]]
            -- Only the mapped external id produced a row; the unmapped one was
            -- never fetched.
            extIds `shouldBe` ["ext-mapped"]
            case objs of
              [row] -> do
                KeyMap.lookup "localAccountId" row `shouldBe` Just (String accId)
                KeyMap.lookup "importedCount" row `shouldBe` Just (Number 1)
              _ -> expectationFailure $ "expected exactly one account row, got: " <> show objs
          other -> expectationFailure $ "expected accounts array, got: " <> show other
        -- Lock the 'unresolved' field's wire shape: the pull path always
        -- builds its link from the connection's own mapped accounts, so it
        -- serializes as an empty JSON array (never omitted, never null).
        KeyMap.lookup "unresolved" o `shouldBe` Just (Array mempty)

-- | Decode a JSON object body to an aeson 'KeyMap.KeyMap'.
asObject :: SResponse -> IO (KeyMap.KeyMap Value)
asObject resp =
  case eitherDecode (simpleBody resp) :: Either String Value of
    Right (Object o) -> pure o
    other -> throwString $ "expected JSON object, got: " <> show other
