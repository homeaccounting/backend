{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.ObservabilityIntegrationSpec
-- Description : HTTP-boundary integration tests for request context + metrics
--
-- Exercises 'Web.Middleware.Context.contextMiddleware' and the per-request
-- Servant @Vault@ re-hoist wired into 'Web.Server.buildApplication', plus the
-- Prometheus @\/metrics@ exposure, end-to-end over the built WAI
-- 'Application' — not just the pieces in isolation, which are already
-- covered by 'Infrastructure.Observability.ContextSpec',
-- 'Infrastructure.Observability.MetricsSpec', and
-- 'Application.EnricherContextSpec' (the last of which proves the
-- 'RequestContext' -\> 'MetadataEnricher' link by setting the context
-- directly on a test 'AppEnv', rather than driving it through HTTP).
--
-- Covers:
--
--   * a caller-supplied @X-Correlation-Id@ is echoed back on the response;
--   * an absent one is replaced with a freshly minted, valid UUID;
--   * @GET \/metrics@ returns 200 with both @events_persisted_total@ (once
--     it has an exported sample) and @http_request_duration_seconds@, the
--     latter labeled by the normalized route template (@handler=\"\/api\/info\"@,
--     @handler=\"\/api\/accounts\/:id\"@) — never the raw id-bearing path, so
--     cardinality stays bounded. The in-memory test event store's telemetry is
--     wired as a no-op ('Eventium.silentTelemetry'), so this test bumps the
--     counter directly rather than re-proving the increment-on-persist
--     link — that's 'Infrastructure.Observability.InterpreterSpec''s job;
--   * an authenticated write's persisted event metadata carries the SAME
--     correlation id echoed on the HTTP response, and the acting user's id
--     — proving the full request -\> 'RequestContext' -\> per-request
--     'AppEnv' -\> 'MetadataEnricher' chain wired in 'Web.Server', both when
--     the caller supplies a correlation id and when one is auto-minted.
module Web.ObservabilityIntegrationSpec (spec) where

import Data.Aeson (eitherDecode, encode)
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Core.Types (UserId)
import Eventium (EventMetadata (..), EventStoreReader (..), StreamEvent (..), allEvents)
import Infrastructure.App (AppEnv (..))
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import Infrastructure.Observability.Context (renderUserId)
import Infrastructure.Observability.Metrics (incEventPersisted)
import Network.HTTP.Types (hContentType, status200, status201)
import Network.HTTP.Types.Header (Header)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.Fixtures (registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv)
import Testkit.TransactionEditFixture (authHeaders, httpRequest)
import Web.Server (buildApplication)
import Web.Types (AccountResponse (..), CreateAccountRequest (..))

spec :: Spec
spec = describe "Observability HTTP boundary (request context + /metrics)" $ do
  correlationIdSpec
  metricsEndpointSpec
  authenticatedWriteMetadataSpec

-- -----------------------------------------------------------------------------
-- X-Correlation-Id: echoed when supplied, minted when absent
-- -----------------------------------------------------------------------------

correlationIdSpec :: Spec
correlationIdSpec = describe "X-Correlation-Id response header" $ do
  it "echoes a caller-supplied correlation id back on the response" $ do
    env <- createTestAppEnv
    let app = buildApplication env
        suppliedCid = UUID.fromWords 1 2 3 4
    resp <- httpRequest app "GET" "/api/info" [correlationHeader suppliedCid] ""
    simpleStatus resp `shouldBe` status200
    lookup "X-Correlation-Id" (simpleHeaders resp) `shouldBe` Just (UUID.toASCIIBytes suppliedCid)

  it "mints a fresh, valid correlation id when none is supplied" $ do
    env <- createTestAppEnv
    let app = buildApplication env
    resp <- httpRequest app "GET" "/api/info" [(hContentType, "application/json")] ""
    simpleStatus resp `shouldBe` status200
    case lookup "X-Correlation-Id" (simpleHeaders resp) of
      Nothing -> expectationFailure "expected an X-Correlation-Id response header"
      Just bs -> UUID.fromASCIIBytes bs `shouldSatisfy` isJust

-- -----------------------------------------------------------------------------
-- /metrics
-- -----------------------------------------------------------------------------

metricsEndpointSpec :: Spec
metricsEndpointSpec =
  describe "GET /metrics"
    $ it "returns 200 with events_persisted_total and a per-route, bounded http_request_duration_seconds"
    $ do
      env <- createTestAppEnv
      let app = buildApplication env
      -- The in-memory test event store's telemetry is intentionally a
      -- no-op ('Eventium.silentTelemetry', wired in
      -- 'Testkit.InMemoryEventStore') — the increment-on-persist wiring
      -- itself is already proven by
      -- 'Infrastructure.Observability.InterpreterSpec'. This test's concern
      -- is the HTTP-level @\/metrics@ exposure, so bump the (per-event-type
      -- Prometheus vector) events_persisted_total counter directly, giving
      -- it an exported sample.
      incEventPersisted env.metrics "ObservabilityIntegrationTestEvent"
      -- Bump the HTTP request-duration histogram on two routes: a static one
      -- (labeled verbatim) and an id-bearing one (whose capture must collapse
      -- to @:id@). The account read is unauthenticated — it need not succeed;
      -- the middleware records the histogram regardless of response status.
      void $ httpRequest app "GET" "/api/info" [(hContentType, "application/json")] ""
      void $ httpRequest app "GET" ("/api/accounts/" <> UUID.toASCIIBytes idBearing) [] ""

      resp <- httpRequest app "GET" "/metrics" [] ""
      simpleStatus resp `shouldBe` status200
      let body = BLC.unpack (simpleBody resp)
      body `shouldContain` "events_persisted_total"
      body `shouldContain` "http_request_duration_seconds"
      -- Labeled by the normalized route template, per endpoint.
      body `shouldContain` "handler=\"/api/info\""
      body `shouldContain` "handler=\"/api/accounts/:id\""
      -- Bounded cardinality: ids collapse to @:id@ (the raw uuid never appears
      -- as a label) and the old constant @handler=\"app\"@ is gone.
      body `shouldNotContain` UUID.toString idBearing
      body `shouldNotContain` "handler=\"app\""
  where
    idBearing = UUID.fromWords 5 6 7 8

-- -----------------------------------------------------------------------------
-- Authenticated write -> stored-event metadata parity
-- -----------------------------------------------------------------------------

authenticatedWriteMetadataSpec :: Spec
authenticatedWriteMetadataSpec =
  describe "authenticated POST /api/accounts" $ do
    it "stamps the response's caller-supplied X-Correlation-Id and acting user onto the persisted event" $ do
      env <- createTestAppEnv
      uid <- registerUser env "obs-write@example.com"
      jwt <- mintToken uid "obs-write@example.com"
      let app = buildApplication env
          suppliedCid = UUID.fromWords 9 8 7 6
          headers = authHeaders jwt <> [correlationHeader suppliedCid]
      resp <- httpRequest app "POST" "/api/accounts" headers (encode newAccountRequest)
      simpleStatus resp `shouldBe` status201
      lookup "X-Correlation-Id" (simpleHeaders resp) `shouldBe` Just (UUID.toASCIIBytes suppliedCid)

      accountResp <- decodeAccount resp
      md <- soleEventMetadata env accountResp.id
      md.correlationId `shouldBe` Just suppliedCid
      Map.lookup "userId" md.custom `shouldBe` Just (renderUserId uid)

    it "stamps the auto-minted correlation id (no header supplied) too" $ do
      env <- createTestAppEnv
      uid <- registerUser env "obs-write-automint@example.com"
      jwt <- mintToken uid "obs-write-automint@example.com"
      let app = buildApplication env
      resp <- httpRequest app "POST" "/api/accounts" (authHeaders jwt) (encode newAccountRequest)
      simpleStatus resp `shouldBe` status201

      respCid <- case lookup "X-Correlation-Id" (simpleHeaders resp) >>= UUID.fromASCIIBytes of
        Nothing -> fail "response missing a valid X-Correlation-Id header"
        Just cid -> pure cid

      accountResp <- decodeAccount resp
      md <- soleEventMetadata env accountResp.id
      md.correlationId `shouldBe` Just respCid
      Map.lookup "userId" md.custom `shouldBe` Just (renderUserId uid)

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

newAccountRequest :: CreateAccountRequest
newAccountRequest =
  CreateAccountRequest
    { name = "Observability Test Account",
      initialBalance = 100,
      currency = "USD",
      overdraftLimit = Nothing,
      subtype = Nothing
    }

mintToken :: UserId -> Text -> IO Text
mintToken uid email = do
  res <- generateToken defaultJWTConfig uid email
  case res of
    Left err -> fail $ "mintToken failed: " <> show err
    Right tok -> pure tok

decodeAccount :: SResponse -> IO AccountResponse
decodeAccount resp = case eitherDecode (simpleBody resp) :: Either String AccountResponse of
  Left err -> fail ("AccountResponse decode failed: " <> err)
  Right a -> pure a

-- | Read back the metadata of the (single) event persisted for the given
-- account id. Fails the test if the stream isn't exactly one event — account
-- creation should persist exactly one event.
soleEventMetadata :: AppEnv -> UUID.UUID -> IO EventMetadata
soleEventMetadata env accountUuid = do
  let EventStoreReader readStream = env.eventStoreReader
  events <- readStream (allEvents accountUuid)
  case [md | StreamEvent _ _ md _payload <- events] of
    [md] -> pure md
    mds -> fail ("expected exactly one event for account " <> show accountUuid <> ", got " <> show (length mds))

correlationHeader :: UUID.UUID -> Header
correlationHeader cid = ("X-Correlation-Id", UUID.toASCIIBytes cid)
