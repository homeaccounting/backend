# Pluggable Exchange Rate Providers Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hardcoded ECB exchange rate client with a pluggable provider system supporting ECB and NBU, selected via config.

**Architecture:** Record-of-functions `RateProvider` abstraction. `ExchangeRateCache` becomes provider-agnostic. Shared `deriveCrossRates` pure function. Config selects provider at startup.

**Tech Stack:** Haskell, RIO, aeson (NBU JSON), xml-conduit (ECB XML), http-client-tls, Hspec/QuickCheck.

**Spec:** `docs/specs/2026-03-18-pluggable-exchange-rate-providers-design.md`

---

## File Structure

**Create:**
- `src/Infrastructure/ExchangeRate/Provider.hs` — `RateProvider` record, `ExchangeRateCache` (opaque), `deriveCrossRates`, cache functions, `ExchangeRateMap`, `getRate`
- `src/Infrastructure/ExchangeRate/ECB.hs` — `ecbProvider :: RateProvider` (extracted from current `ExchangeRate.hs`)
- `src/Infrastructure/ExchangeRate/NBU.hs` — `nbuProvider :: RateProvider`
- `test/Infrastructure/ExchangeRate/ProviderPropertySpec.hs` — property tests for `deriveCrossRates`
- `test/Infrastructure/ExchangeRate/NBUSpec.hs` — unit tests for NBU JSON parsing
- `test/Infrastructure/ExchangeRate/NBUIntegrationSpec.hs` — integration test for real NBU fetch

**Delete:**
- `src/Infrastructure/ExchangeRate.hs` — replaced by the three new modules

**Modify:**
- `src/Infrastructure/Config.hs` — add `ExchangeRateConfig` type, update `AppConfig`, `FromJSON`, `validateConfig`
- `src/Infrastructure/App.hs` — update import from `Infrastructure.ExchangeRate` to `Infrastructure.ExchangeRate.Provider`
- `app/Main.hs` — import new modules, wire provider from config
- `config/local.yaml`, `config/test.yaml`, `config/prod.yaml` — add `exchange_rate` section
- `src/Application/Services/TransactionService.hs` — update import path
- `test/Testkit/InMemoryEventStore.hs` — update import, add `ExchangeRateConfig` to `AppConfig` constructions
- `test/Application/Services/TransactionServiceSpec.hs` — switch from `ExchangeRateCache(..)` to `newExchangeRateCache` with mock provider
- `test/Infrastructure/ExchangeRateIntegrationSpec.hs` — update imports

---

## Chunk 1: Provider Abstraction, Config, and deriveCrossRates

### Task 1: Create Provider.hs with RateProvider, ExchangeRateCache, and deriveCrossRates

**Files:**
- Create: `src/Infrastructure/ExchangeRate/Provider.hs`

- [ ] **Step 1: Write Provider.hs**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.Provider
-- Description : Exchange rate provider abstraction and cache
--
-- Defines the RateProvider record-of-functions and the provider-agnostic
-- ExchangeRateCache. Providers (ECB, NBU) plug into the cache via RateProvider.
-- Cache refreshes daily on first request after UTC midnight.
module Infrastructure.ExchangeRate.Provider
  ( -- * Provider Abstraction
    RateProvider (..),

    -- * Rate Map
    ExchangeRateMap,
    getRate,

    -- * Cross-Rate Derivation
    deriveCrossRates,

    -- * Cache
    ExchangeRateCache,
    newExchangeRateCache,
    getCachedRate,
    refreshCache,
  )
where

import Data.Time (UTCTime, getCurrentTime, utctDay)
import Domain.Core.Types (Currency, ExchangeRate, mkExchangeRate)
import RIO
import qualified RIO.Map as Map

-- | Exchange rate provider interface.
--
-- Each provider (ECB, NBU, etc.) exports a value of this type.
-- The cache delegates rate fetching to whichever provider is configured.
data RateProvider = RateProvider
  { -- | Human-readable provider name (for error messages)
    providerName :: !Text,
    -- | Fetch current rates from the provider. Uses bare IO because
    -- providers perform real network I/O and the cache operates in IO.
    fetchRates :: IO (Either Text ExchangeRateMap)
  }

-- | Map of (source, target) -> ExchangeRate
type ExchangeRateMap = Map (Currency, Currency) ExchangeRate

-- | Look up a rate for a given currency pair.
getRate :: ExchangeRateMap -> Currency -> Currency -> Maybe ExchangeRate
getRate rates src tgt
  | src == tgt = Nothing
  | otherwise = Map.lookup (src, tgt) rates

-- | Derive full cross-rate matrix from base currency rates.
--
-- Given a base currency and rates relative to it, produces all currency pairs
-- for currencies present in the input map plus the base currency.
-- Does NOT hardcode supported currencies — output is determined by input keys.
deriveCrossRates :: Currency -> Map Currency Rational -> ExchangeRateMap
deriveCrossRates base baseRates =
  let allCurrencies = base : Map.keys baseRates
      pairs = do
        src <- allCurrencies
        tgt <- allCurrencies
        guard (src /= tgt)
        let srcToBase =
              if src == base
                then 1
                else case Map.lookup src baseRates of
                  Just r -> 1 / r
                  Nothing -> 0
        let baseToTgt =
              if tgt == base
                then 1
                else fromMaybe 0 (Map.lookup tgt baseRates)
        let crossRate = srcToBase * baseToTgt
        guard (crossRate > 0)
        case mkExchangeRate src tgt crossRate of
          Right er -> [((src, tgt), er)]
          Left _ -> []
   in Map.fromList pairs

-- | Exchange rate cache with daily refresh.
--
-- Opaque type — use 'newExchangeRateCache', 'getCachedRate', 'refreshCache'.
data ExchangeRateCache = ExchangeRateCache
  { provider :: !RateProvider,
    cacheRef :: !(IORef (Maybe (UTCTime, ExchangeRateMap)))
  }

-- | Create a new empty cache backed by the given provider.
newExchangeRateCache :: RateProvider -> IO ExchangeRateCache
newExchangeRateCache prov = ExchangeRateCache prov <$> newIORef Nothing

-- | Refresh the cache by fetching from the configured provider.
refreshCache :: ExchangeRateCache -> IO (Either Text ())
refreshCache cache = do
  result <- cache.provider.fetchRates
  case result of
    Left err -> pure (Left err)
    Right rates -> do
      now <- getCurrentTime
      writeIORef cache.cacheRef (Just (now, rates))
      pure (Right ())

-- | Get a cached rate. Refreshes if cache is from a previous day (UTC).
getCachedRate :: ExchangeRateCache -> Currency -> Currency -> IO (Either Text ExchangeRate)
getCachedRate cache src tgt
  | src == tgt = pure $ Left "Same currency, no conversion needed"
  | otherwise = do
      cached <- readIORef cache.cacheRef
      now <- getCurrentTime
      let needsRefresh = case cached of
            Nothing -> True
            Just (fetchTime, _) -> utctDay fetchTime /= utctDay now
      when needsRefresh $ void $ refreshCache cache
      cached' <- readIORef cache.cacheRef
      case cached' of
        Nothing -> pure $ Left $ cache.provider.providerName <> ": exchange rates unavailable"
        Just (_, rates) ->
          case getRate rates src tgt of
            Just er -> pure (Right er)
            Nothing ->
              pure $
                Left $
                  cache.provider.providerName
                    <> ": no rate for "
                    <> tshow src
                    <> " -> "
                    <> tshow tgt
```

- [ ] **Step 2: Verify it compiles**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && cabal build lib:accounting 2>&1 | head -30`
Expected: Compiles (Provider.hs is a new independent module)

- [ ] **Step 3: Commit**

```bash
git add src/Infrastructure/ExchangeRate/Provider.hs
git commit -m "feat: add RateProvider abstraction and provider-agnostic cache"
```

### Task 2: Property tests for deriveCrossRates

**Files:**
- Create: `test/Infrastructure/ExchangeRate/ProviderPropertySpec.hs`

- [ ] **Step 1: Write property tests**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.ProviderPropertySpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateSource, exchangeRateTarget, exchangeRateValue)
import Infrastructure.ExchangeRate.Provider (deriveCrossRates, getRate)
import RIO
import qualified RIO.Map as Map
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck

-- | Generate a non-empty subset of non-base currencies with positive rates.
genBaseRates :: Currency -> Gen (Map Currency Rational)
genBaseRates base = do
  let others = filter (/= base) [minBound .. maxBound]
  selected <- sublistOf others `suchThat` (not . null)
  rates <- mapM (\c -> (c,) . toRational <$> (choose (0.01, 1000.0) :: Gen Double)) selected
  pure $ Map.fromList rates

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.Provider" $ do
  describe "deriveCrossRates" $ do
    prop "produces N*(N-1) pairs for N currencies (base + input keys)" $ do
      base <- elements [minBound .. maxBound]
      baseRates <- genBaseRates base
      let result = deriveCrossRates base baseRates
          n = Map.size baseRates + 1 -- input keys + base
          expectedPairs = n * (n - 1)
      pure $ Map.size result === expectedPairs

    prop "inverse rates multiply to ~1" $ do
      base <- elements [minBound .. maxBound]
      baseRates <- genBaseRates base
      let result = deriveCrossRates base baseRates
          allCurrencies = base : Map.keys baseRates
          inversePairs = do
            src <- allCurrencies
            tgt <- allCurrencies
            guard (src /= tgt)
            case (getRate result src tgt, getRate result tgt src) of
              (Just ab, Just ba) -> [(exchangeRateValue ab * exchangeRateValue ba)]
              _ -> []
      pure $
        counterexample "inverse rates should multiply to ~1" $
          all (\product' -> abs (product' - 1) < 1e-6) inversePairs

    prop "transitivity: rate(A,C) ~ rate(A,B) * rate(B,C)" $ do
      base <- elements [minBound .. maxBound]
      baseRates <- genBaseRates base `suchThat` (\m -> Map.size m >= 2)
      let result = deriveCrossRates base baseRates
          allCurrencies = base : Map.keys baseRates
          transitivityChecks = do
            a <- allCurrencies
            b <- allCurrencies
            c <- allCurrencies
            guard (a /= b && b /= c && a /= c)
            case (getRate result a b, getRate result b c, getRate result a c) of
              (Just ab, Just bc, Just ac) ->
                let derived = exchangeRateValue ab * exchangeRateValue bc
                    direct = exchangeRateValue ac
                 in [(abs (derived - direct) / max 1 (abs direct))]
              _ -> []
      pure $
        counterexample "transitivity should hold within tolerance" $
          all (< 1e-6) transitivityChecks
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `cabal test all --test-option='--match' --test-option='/Infrastructure.ExchangeRate.Provider/'`
Expected: 3 properties pass

- [ ] **Step 3: Commit**

```bash
git add test/Infrastructure/ExchangeRate/ProviderPropertySpec.hs
git commit -m "test: add property tests for deriveCrossRates"
```

### Task 3: Add ExchangeRateConfig to Config.hs and update YAML files

**Files:**
- Modify: `src/Infrastructure/Config.hs`
- Modify: `config/local.yaml`
- Modify: `config/test.yaml`
- Modify: `config/prod.yaml`

- [ ] **Step 1: Add ExchangeRateConfig type and update AppConfig**

In `src/Infrastructure/Config.hs`:

1. Add `ExchangeRateConfig (..)` to the module exports (in the "Configuration Types" section).

2. Add the new type after `ProcessManagerConfig`:

```haskell
-- | Exchange rate provider configuration.
data ExchangeRateConfig = ExchangeRateConfig
  { provider :: !Text
  }
  deriving (Show, Eq, Generic)

instance FromJSON ExchangeRateConfig where
  parseJSON = withObject "ExchangeRateConfig" $ \v ->
    ExchangeRateConfig
      <$> v .: "provider"

instance ToJSON ExchangeRateConfig
```

3. Add field to `AppConfig`:

```haskell
data AppConfig = AppConfig
  { server :: !ServerConfig,
    database :: !DatabaseConfig,
    logging :: !LoggingConfig,
    cors :: !CorsConfig,
    eventStore :: !EventStoreConfig,
    processManagers :: !ProcessManagerConfig,
    auth :: !JWTConfig,
    oauth :: !OAuthConfig,
    telegram :: !TelegramConfig,
    exchangeRate :: !ExchangeRateConfig
  }
```

4. Update `FromJSON AppConfig` to add at the end:

```haskell
      <*> v .: "exchange_rate"
```

5. Add validation in `validateConfig` before the final `Right ()`:

```haskell
  -- Validate exchange rate config
  let providerValue = config.exchangeRate.provider
  when (providerValue `notElem` ["ecb", "nbu"]) $
    Left $
      "Invalid exchange rate provider: " <> providerValue <> " (must be \"ecb\" or \"nbu\")"
```

- [ ] **Step 2: Add exchange_rate section to config YAML files**

Append to `config/local.yaml`:

```yaml
# Exchange rate provider
exchange_rate:
  provider: ecb
```

Append to `config/test.yaml`:

```yaml
# Exchange rate provider
exchange_rate:
  provider: ecb
```

Append to `config/prod.yaml`:

```yaml
# Exchange rate provider
exchange_rate:
  provider: ${EXCHANGE_RATE_PROVIDER:-ecb}
```

- [ ] **Step 3: Update test AppConfig constructions in InMemoryEventStore.hs**

In `test/Testkit/InMemoryEventStore.hs`:

1. Add import: `ExchangeRateConfig (..)` to the `Infrastructure.Config` import.

2. Add `exchangeRate` field to both `AppConfig` constructions (around lines 257 and 376):

```haskell
            telegram = testTelegramConfig,
            exchangeRate =
              ExchangeRateConfig
                { provider = "ecb"
                }
```

- [ ] **Step 4: Verify it compiles**

Run: `cabal build 2>&1 | tail -10`
Expected: Compiles successfully

- [ ] **Step 5: Run full test suite**

Run: `cabal test --test-show-details=direct 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 6: Commit**

```bash
git add src/Infrastructure/Config.hs config/local.yaml config/test.yaml config/prod.yaml test/Testkit/InMemoryEventStore.hs
git commit -m "feat: add ExchangeRateConfig to config and YAML files"
```

---

## Chunk 2: Extract ECB Provider, Update All Imports

### Task 4: Create ECB.hs by extracting from ExchangeRate.hs

**Files:**
- Create: `src/Infrastructure/ExchangeRate/ECB.hs`

- [ ] **Step 1: Write ECB.hs**

Extract the ECB-specific code from `src/Infrastructure/ExchangeRate.hs` into `ECB.hs`, using `deriveCrossRates` from Provider and exporting only `ecbProvider`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.ECB
-- Description : ECB (European Central Bank) exchange rate provider
--
-- Fetches daily exchange rates from the ECB XML feed.
-- All ECB rates are EUR-based; cross-rates are derived for all supported pairs.
module Infrastructure.ExchangeRate.ECB
  ( ecbProvider,
    -- exported for integration tests only
    fetchEcbRates,
  )
where

import Data.Maybe (listToMaybe)
import Domain.Core.Types (Currency (..), parseCurrency)
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), deriveCrossRates)
import Network.HTTP.Client (httpLbs, newManager, parseRequest, responseBody)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Text.Read (readMaybe)
import Text.XML (Document, def, parseLBS)
import Text.XML.Cursor (attribute, element, fromDocument, ($//))

-- | ECB exchange rate provider.
ecbProvider :: RateProvider
ecbProvider =
  RateProvider
    { providerName = "ECB",
      fetchRates = fetchEcbRates
    }

-- | Fetch daily rates from ECB XML feed.
fetchEcbRates :: IO (Either Text ExchangeRateMap)
fetchEcbRates = do
  result <- tryAny $ do
    manager <- newManager tlsManagerSettings
    request <- parseRequest ecbUrl
    responseBody <$> httpLbs request manager
  case result of
    Left ex -> pure $ Left $ "ECB: fetch failed: " <> T.pack (show ex)
    Right body ->
      case parseLBS def body of
        Left ex -> pure $ Left $ "ECB: XML parse failed: " <> T.pack (show ex)
        Right doc -> pure $ parseEcbDoc doc
  where
    ecbUrl = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"

-- | Parse ECB XML document into rate map.
parseEcbDoc :: Document -> Either Text ExchangeRateMap
parseEcbDoc doc =
  let cursor = fromDocument doc
      cubes = cursor $// element "{http://www.ecb.int/vocabulary/2002-08-01/eurofxref}Cube"
      eurRates = mapMaybe parseCube cubes
   in if null eurRates
        then Left "ECB: no rates found in response"
        else Right $ deriveCrossRates EUR (Map.fromList eurRates)
  where
    parseCube c = do
      curText <- listToMaybe $ attribute "currency" c
      rateText <- listToMaybe $ attribute "rate" c
      cur <- either (const Nothing) Just $ parseCurrency curText
      (rate :: Double) <- readMaybe (T.unpack rateText)
      guard (rate > 0)
      pure (cur, toRational rate)
```

- [ ] **Step 2: Verify it compiles**

Run: `cabal build lib:accounting 2>&1 | tail -10`
Expected: Compiles (new module, existing `ExchangeRate.hs` still present)

- [ ] **Step 3: Commit**

```bash
git add src/Infrastructure/ExchangeRate/ECB.hs
git commit -m "feat: extract ECB provider into Infrastructure.ExchangeRate.ECB"
```

### Task 5: Delete old ExchangeRate.hs and update all imports

**Files:**
- Delete: `src/Infrastructure/ExchangeRate.hs`
- Modify: `src/Infrastructure/App.hs:117`
- Modify: `src/Application/Services/TransactionService.hs:72`
- Modify: `app/Main.hs:114`
- Modify: `test/Testkit/InMemoryEventStore.hs:79`
- Modify: `test/Application/Services/TransactionServiceSpec.hs:27`
- Modify: `test/Infrastructure/ExchangeRateIntegrationSpec.hs:7`

- [ ] **Step 1: Delete old module**

```bash
rm src/Infrastructure/ExchangeRate.hs
```

- [ ] **Step 2: Update Infrastructure.App import**

Change line 117 of `src/Infrastructure/App.hs`:

```haskell
-- Old:
import Infrastructure.ExchangeRate (ExchangeRateCache)
-- New:
import Infrastructure.ExchangeRate.Provider (ExchangeRateCache)
```

- [ ] **Step 3: Update TransactionService import**

Change line 72 of `src/Application/Services/TransactionService.hs`:

```haskell
-- Old:
import Infrastructure.ExchangeRate (getCachedRate)
-- New:
import Infrastructure.ExchangeRate.Provider (getCachedRate)
```

- [ ] **Step 4: Update Main.hs import and wiring**

Change line 114 of `app/Main.hs`:

```haskell
-- Old:
import Infrastructure.ExchangeRate (newExchangeRateCache, refreshCache)
-- New:
import Infrastructure.ExchangeRate.ECB (ecbProvider)
import Infrastructure.ExchangeRate.Provider (newExchangeRateCache, refreshCache)
```

Update `initializeEnvironment` (around line 304-306) — temporarily wire ECB only (NBU added in Task 9):

```haskell
  -- 6b. Initialize exchange rate cache (best-effort, app starts even if provider is unreachable)
  logInfo "Initializing exchange rate cache..."
  let rateProvider = case config.exchangeRate.provider of
        "ecb" -> ecbProvider
        unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
  exchangeRateCache <- liftIO $ newExchangeRateCache rateProvider
  refreshResult <- liftIO $ refreshCache exchangeRateCache
  case refreshResult of
    Right () -> logInfo $ "Exchange rate cache populated from " <> display (config.exchangeRate.provider)
    Left err -> logWarn $ "Exchange rate cache initialization failed (will retry on first use): " <> display err
```

- [ ] **Step 5: Update InMemoryEventStore.hs import**

Change line 79 of `test/Testkit/InMemoryEventStore.hs`:

```haskell
-- Old:
import Infrastructure.ExchangeRate (newExchangeRateCache)
-- New:
import Infrastructure.ExchangeRate.ECB (ecbProvider)
import Infrastructure.ExchangeRate.Provider (newExchangeRateCache)
```

Update both `newExchangeRateCache` call sites (around lines 266 and 381):

```haskell
-- Old:
exchangeRateCache' <- newExchangeRateCache
-- New:
exchangeRateCache' <- newExchangeRateCache ecbProvider
```

(Same for the second occurrence.)

- [ ] **Step 6: Update TransactionServiceSpec.hs**

Change line 27:

```haskell
-- Old:
import Infrastructure.ExchangeRate (ExchangeRateCache (..), newExchangeRateCache)
-- New:
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), newExchangeRateCache)
```

Update `mkTestExchangeRateCache` (lines 66-72) to use a mock provider instead of writing to `cacheRef` directly:

```haskell
-- | Create a mock provider that returns fixed rates.
mockRateProvider :: ExchangeRateMap -> RateProvider
mockRateProvider rates =
  RateProvider
    { providerName = "Mock",
      fetchRates = pure (Right rates)
    }

-- | Create a test exchange rate cache pre-populated with known rates.
mkTestExchangeRateCache :: [(Currency, Currency, Rational)] -> IO ExchangeRateCache
mkTestExchangeRateCache rates = do
  let rateMap = Map.fromList [((src, tgt), mockExchangeRate src tgt r) | (src, tgt, r) <- rates]
  cache <- newExchangeRateCache (mockRateProvider rateMap)
  -- Force a refresh to populate the cache
  void $ refreshCache cache
  return cache
```

Also add `refreshCache` to the Provider import:

```haskell
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), newExchangeRateCache, refreshCache)
```

And add `ExchangeRateCache` to the import (needed for type signature):

```haskell
import Infrastructure.ExchangeRate.Provider (ExchangeRateCache, ExchangeRateMap, RateProvider (..), newExchangeRateCache, refreshCache)
```

- [ ] **Step 7: Update ExchangeRateIntegrationSpec.hs**

Replace the imports:

```haskell
-- Old:
import Infrastructure.ExchangeRate (fetchEcbRates, getRate)
-- New:
import Infrastructure.ExchangeRate.ECB (fetchEcbRates)
import Infrastructure.ExchangeRate.Provider (getRate)
```

- [ ] **Step 8: Regenerate cabal file and verify build**

Run: `hpack && cabal build 2>&1 | tail -20`
Expected: Compiles (old module gone, all imports updated)

- [ ] **Step 9: Run full test suite**

Run: `cabal test --test-show-details=direct 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor: replace Infrastructure.ExchangeRate with modular Provider/ECB split"
```

---

## Chunk 3: NBU Provider and Final Wiring

### Task 6: NBU provider — tests and implementation

**Files:**
- Create: `test/Infrastructure/ExchangeRate/NBUSpec.hs`
- Create: `src/Infrastructure/ExchangeRate/NBU.hs`

- [ ] **Step 1: Write NBU.hs**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.ExchangeRate.NBU
-- Description : NBU (National Bank of Ukraine) exchange rate provider
--
-- Fetches daily exchange rates from the NBU JSON API.
-- All NBU rates are UAH-based; cross-rates are derived for all supported pairs.
module Infrastructure.ExchangeRate.NBU
  ( nbuProvider,
    -- exported for unit tests
    parseNbuResponse,
  )
where

import Data.Aeson (FromJSON (..), eitherDecode, withObject, (.:))
import Domain.Core.Types (Currency (..), parseCurrency)
import Infrastructure.ExchangeRate.Provider (ExchangeRateMap, RateProvider (..), deriveCrossRates)
import Network.HTTP.Client (httpLbs, newManager, parseRequest, responseBody)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T

-- | NBU exchange rate provider.
nbuProvider :: RateProvider
nbuProvider =
  RateProvider
    { providerName = "NBU",
      fetchRates = fetchNbuRates
    }

-- | Raw NBU rate entry from JSON response.
data NbuRateEntry = NbuRateEntry
  { cc :: !Text,
    rate :: !Double
  }

instance FromJSON NbuRateEntry where
  parseJSON = withObject "NbuRateEntry" $ \v ->
    NbuRateEntry
      <$> v .: "cc"
      <*> v .: "rate"

-- | Fetch daily rates from NBU JSON API.
fetchNbuRates :: IO (Either Text ExchangeRateMap)
fetchNbuRates = do
  result <- tryAny $ do
    manager <- newManager tlsManagerSettings
    request <- parseRequest nbuUrl
    responseBody <$> httpLbs request manager
  case result of
    Left ex -> pure $ Left $ "NBU: fetch failed: " <> T.pack (show ex)
    Right body -> pure $ parseNbuResponse body
  where
    nbuUrl = "https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json"

-- | Parse NBU JSON response into rate map.
--
-- Exposed for unit testing with sample payloads.
parseNbuResponse :: LByteString -> Either Text ExchangeRateMap
parseNbuResponse body =
  case eitherDecode body :: Either String [NbuRateEntry] of
    Left err -> Left $ "NBU: JSON parse failed: " <> T.pack err
    Right entries ->
      let uahRates = mapMaybe toRatePair entries
       in if null uahRates
            then Left "NBU: no supported rates found in response"
            else Right $ deriveCrossRates UAH (Map.fromList uahRates)
  where
    toRatePair :: NbuRateEntry -> Maybe (Currency, Rational)
    toRatePair entry = do
      cur <- either (const Nothing) Just $ parseCurrency entry.cc
      guard (entry.rate > 0)
      guard (cur /= UAH) -- NBU rates are relative to UAH, skip UAH itself
      pure (cur, toRational entry.rate)
```

- [ ] **Step 2: Write unit tests**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.NBUSpec (spec) where

import Infrastructure.ExchangeRate.NBU (parseNbuResponse)
import Infrastructure.ExchangeRate.Provider (getRate)
import Domain.Core.Types (Currency (..), exchangeRateValue)
import RIO
import Test.Hspec

sampleJson :: LByteString
sampleJson =
  "[{\"r030\":840,\"txt\":\"Долар США\",\"rate\":41.2345,\"cc\":\"USD\",\"exchangedate\":\"18.03.2026\"}\
  \,{\"r030\":978,\"txt\":\"Євро\",\"rate\":44.5678,\"cc\":\"EUR\",\"exchangedate\":\"18.03.2026\"}\
  \,{\"r030\":826,\"txt\":\"Фунт стерлінгів\",\"rate\":52.1234,\"cc\":\"GBP\",\"exchangedate\":\"18.03.2026\"}]"

-- | JSON with missing required 'rate' field — aeson will fail to parse the entire array.
missingRateJson :: LByteString
missingRateJson = "[{\"r030\":840,\"txt\":\"USD\",\"cc\":\"USD\"}]"

partialJson :: LByteString
partialJson =
  "[{\"r030\":840,\"txt\":\"Долар США\",\"rate\":41.2345,\"cc\":\"USD\",\"exchangedate\":\"18.03.2026\"}\
  \,{\"r030\":978,\"txt\":\"Євро\",\"rate\":44.5678,\"cc\":\"EUR\",\"exchangedate\":\"18.03.2026\"}]"

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.NBU" $ do
  describe "parseNbuResponse" $ do
    it "parses valid JSON with all supported currencies" $ do
      let result = parseNbuResponse sampleJson
      case result of
        Left err -> expectationFailure $ "Parse failed: " <> show err
        Right rates -> do
          getRate rates USD EUR `shouldSatisfy` isJust
          getRate rates EUR USD `shouldSatisfy` isJust
          getRate rates GBP UAH `shouldSatisfy` isJust
          getRate rates UAH GBP `shouldSatisfy` isJust

    it "returns Left when JSON entry is missing required 'rate' field" $ do
      let result = parseNbuResponse missingRateJson
      -- aeson fails to parse the array because one entry lacks 'rate'
      result `shouldSatisfy` isLeft

    it "produces partial map when GBP is missing" $ do
      let result = parseNbuResponse partialJson
      case result of
        Left err -> expectationFailure $ "Parse failed: " <> show err
        Right rates -> do
          -- USD and EUR pairs should exist
          getRate rates USD EUR `shouldSatisfy` isJust
          getRate rates UAH USD `shouldSatisfy` isJust
          -- GBP pairs should be absent
          getRate rates GBP USD `shouldBe` Nothing
          getRate rates GBP EUR `shouldBe` Nothing

    it "rate values are positive" $ do
      let result = parseNbuResponse sampleJson
      case result of
        Left err -> expectationFailure $ "Parse failed: " <> show err
        Right rates -> do
          case getRate rates USD UAH of
            Just er -> exchangeRateValue er `shouldSatisfy` (> 0)
            Nothing -> expectationFailure "Expected USD/UAH rate"
```

- [ ] **Step 3: Run NBU unit tests**

Run: `cabal test all --test-option='--match' --test-option='/Infrastructure.ExchangeRate.NBU/'`
Expected: All 4 tests pass

- [ ] **Step 4: Commit both together**

```bash
git add src/Infrastructure/ExchangeRate/NBU.hs test/Infrastructure/ExchangeRate/NBUSpec.hs
git commit -m "feat: implement NBU exchange rate provider with unit tests"
```

### Task 7: NBU integration test

**Files:**
- Create: `test/Infrastructure/ExchangeRate/NBUIntegrationSpec.hs`

- [ ] **Step 1: Write integration test**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.NBUIntegrationSpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateSource, exchangeRateTarget, exchangeRateValue)
import Infrastructure.ExchangeRate.NBU (nbuProvider)
import Infrastructure.ExchangeRate.Provider (RateProvider (..), getRate)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.NBU (integration)" $ do
  describe "fetchRates" $ do
    it "fetches rates from NBU and contains USD" $ do
      result <- nbuProvider.fetchRates
      case result of
        Left err -> pendingWith $ "NBU unavailable: " <> show err
        Right rates -> do
          let usdRate = getRate rates UAH USD
          usdRate `shouldSatisfy` isJust

    it "derives cross-rate EUR/USD" $ do
      result <- nbuProvider.fetchRates
      case result of
        Left err -> pendingWith $ "NBU unavailable: " <> show err
        Right rates -> do
          let rate = getRate rates EUR USD
          rate `shouldSatisfy` isJust
          case rate of
            Just er -> do
              exchangeRateSource er `shouldBe` EUR
              exchangeRateTarget er `shouldBe` USD
              exchangeRateValue er `shouldSatisfy` (> 0)
            Nothing -> pure ()
```

- [ ] **Step 2: Run integration test**

Run: `cabal test all --test-option='--match' --test-option='/Infrastructure.ExchangeRate.NBU (integration)/'`
Expected: Pass (or pending if NBU unreachable)

- [ ] **Step 3: Commit**

```bash
git add test/Infrastructure/ExchangeRate/NBUIntegrationSpec.hs
git commit -m "test: add NBU integration test"
```

### Task 8: Cache refresh test with mock provider

**Files:**
- Create: `test/Infrastructure/ExchangeRate/CacheSpec.hs`

- [ ] **Step 1: Write cache tests using mock provider**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.ExchangeRate.CacheSpec (spec) where

import Domain.Core.Types (Currency (..), exchangeRateValue)
import Infrastructure.ExchangeRate.Provider
  ( ExchangeRateMap,
    RateProvider (..),
    deriveCrossRates,
    getCachedRate,
    newExchangeRateCache,
    refreshCache,
  )
import RIO
import qualified RIO.Map as Map
import Test.Hspec

-- | Mock provider returning fixed rates.
mockProvider :: ExchangeRateMap -> RateProvider
mockProvider rates =
  RateProvider
    { providerName = "Mock",
      fetchRates = pure (Right rates)
    }

-- | Mock provider that always fails.
failingProvider :: RateProvider
failingProvider =
  RateProvider
    { providerName = "Failing",
      fetchRates = pure (Left "Failing: intentional error")
    }

-- | Sample rate map: EUR-based with USD and GBP.
sampleRates :: ExchangeRateMap
sampleRates = deriveCrossRates EUR (Map.fromList [(USD, 1.1), (GBP, 0.85)])

spec :: Spec
spec = describe "Infrastructure.ExchangeRate.Provider (cache)" $ do
  describe "getCachedRate" $ do
    it "returns rate after refresh" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      void $ refreshCache cache
      result <- getCachedRate cache EUR USD
      case result of
        Right er -> exchangeRateValue er `shouldSatisfy` (> 0)
        Left err -> expectationFailure $ "Expected Right, got: " <> show err

    it "auto-refreshes on first call when cache is empty" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      -- No manual refresh — getCachedRate should trigger it
      result <- getCachedRate cache EUR USD
      case result of
        Right er -> exchangeRateValue er `shouldSatisfy` (> 0)
        Left err -> expectationFailure $ "Expected Right, got: " <> show err

    it "returns Left for same currency" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      result <- getCachedRate cache EUR EUR
      result `shouldSatisfy` isLeft

    it "returns Left when provider fails and cache is empty" $ do
      cache <- newExchangeRateCache failingProvider
      result <- getCachedRate cache EUR USD
      result `shouldSatisfy` isLeft

    it "includes provider name in error messages" $ do
      cache <- newExchangeRateCache failingProvider
      result <- getCachedRate cache EUR USD
      case result of
        Left err -> err `shouldSatisfy` ("Failing" `isInfixOf`)
        Right _ -> expectationFailure "Expected Left"

  describe "refreshCache" $ do
    it "returns Right on success" $ do
      cache <- newExchangeRateCache (mockProvider sampleRates)
      result <- refreshCache cache
      result `shouldBe` Right ()

    it "returns Left on provider failure" $ do
      cache <- newExchangeRateCache failingProvider
      result <- refreshCache cache
      result `shouldSatisfy` isLeft
```

- [ ] **Step 2: Run cache tests**

Run: `cabal test all --test-option='--match' --test-option='/Infrastructure.ExchangeRate.Provider (cache)/'`
Expected: All tests pass

- [ ] **Step 3: Commit**

```bash
git add test/Infrastructure/ExchangeRate/CacheSpec.hs
git commit -m "test: add cache tests with mock provider"
```

### Task 9: Wire NBU into Main.hs

**Files:**
- Modify: `app/Main.hs`

- [ ] **Step 1: Add NBU import and full provider wiring**

Add import:

```haskell
import Infrastructure.ExchangeRate.NBU (nbuProvider)
```

Update the provider selection (replacing the temporary ECB-only version from Task 5):

```haskell
  let rateProvider = case config.exchangeRate.provider of
        "nbu" -> nbuProvider
        "ecb" -> ecbProvider
        unknown -> throwString $ "Unknown exchange rate provider: " <> T.unpack unknown
```

- [ ] **Step 2: Verify build**

Run: `cabal build 2>&1 | tail -10`
Expected: Compiles

- [ ] **Step 3: Run full test suite**

Run: `cabal test --test-show-details=direct 2>&1 | tail -30`
Expected: All tests pass

- [ ] **Step 4: Run formatter and linter**

Run: `just check`
Expected: Clean

- [ ] **Step 5: Commit**

```bash
git add app/Main.hs
git commit -m "feat: wire NBU provider into Main.hs startup"
```

### Task 10: Final verification

- [ ] **Step 1: Full build from clean**

Run: `just rebuild`
Expected: Success

- [ ] **Step 2: Full test suite**

Run: `just test`
Expected: All tests pass

- [ ] **Step 3: Format and lint**

Run: `just check`
Expected: Clean

- [ ] **Step 4: Verify with NBU config (smoke test)**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && CONFIG_FILE=config/test.yaml cabal run accounting 2>&1 | head -20` (after temporarily setting `provider: nbu` in test.yaml, then reverting)
Expected: App starts, logs "Exchange rate cache populated from nbu" or retries on failure
