---
status: draft
---

# Pluggable Exchange Rate Providers

**Date:** 2026-03-18

## Problem

The exchange rate system is hardcoded to ECB (European Central Bank). We need to support multiple providers (starting with NBU — National Bank of Ukraine) with only one active at a time, selected via config. The design should allow future composition (e.g., merged results from multiple providers).

## Design

### Core Abstraction

A `RateProvider` record-of-functions serves as the provider interface:

```haskell
-- Infrastructure/ExchangeRate/Provider.hs
data RateProvider = RateProvider
  { providerName :: Text
  , fetchRates :: IO (Either Text ExchangeRateMap)
  }
```

`fetchRates` uses bare `IO` rather than a polymorphic `m` because providers perform real network I/O (HTTP requests) and the cache already operates in `IO`. A polymorphic constraint would add complexity with no practical benefit here.

Each provider exports a value of this type. The cache holds a `RateProvider` and delegates fetching to it.

### Cache Changes

`ExchangeRateCache` gains a `RateProvider` field:

```haskell
data ExchangeRateCache = ExchangeRateCache
  { provider :: RateProvider
  , cacheRef :: IORef (Maybe (UTCTime, ExchangeRateMap))
  }
```

`Provider.hs` exports `ExchangeRateCache` opaquely (no constructors or field selectors) — only `newExchangeRateCache`, `getCachedRate`, and `refreshCache` are exported. This fixes the current code which exports `ExchangeRateCache (..)` contrary to CLAUDE.md guidelines.

`newExchangeRateCache` takes a `RateProvider` argument. `getCachedRate` and `refreshCache` call `provider.fetchRates` instead of `fetchEcbRates` directly. The `HasExchangeRateCache` typeclass and all downstream consumers remain unchanged.

Cache refresh uses UTC midnight as the day boundary for all providers. This corrects the existing module doc comment which says "midnight CET" while the code already uses `utctDay` (UTC). Both ECB and NBU update once daily; the slight timezone offset is irrelevant for a home accounting app.

### Module Structure

```
src/Infrastructure/ExchangeRate/
  Provider.hs     -- RateProvider record, ExchangeRateCache (opaque), getCachedRate, refreshCache, deriveCrossRates
  ECB.hs          -- ecbProvider :: RateProvider
  NBU.hs          -- nbuProvider :: RateProvider
```

The existing `src/Infrastructure/ExchangeRate.hs` is removed. All imports across the codebase are updated to the new module paths, including:
- `Application.Services.TransactionService` — imports `getCachedRate` from `Infrastructure.ExchangeRate.Provider`
- `Infrastructure.App` — imports `ExchangeRateCache` from `Infrastructure.ExchangeRate.Provider`. `HasExchangeRateCache` stays defined in `Infrastructure.App` (consistent with all other `Has*` typeclasses there)
- `app/Main.hs` — imports `newExchangeRateCache`, `refreshCache` from `Infrastructure.ExchangeRate.Provider`, and `ecbProvider`/`nbuProvider` from their respective modules
- `test/Infrastructure/ExchangeRateIntegrationSpec.hs` — imports from `Infrastructure.ExchangeRate.ECB`
- `test/Application/Services/TransactionServiceSpec.hs` — currently uses `ExchangeRateCache(..)` constructor; must switch to `newExchangeRateCache mockProvider` since the export is now opaque
- `test/Testkit/InMemoryEventStore.hs` — imports `newExchangeRateCache` from `Infrastructure.ExchangeRate.Provider`; also must update its `AppConfig` record constructions (two sites) to include the new `exchangeRate` field, and import `ExchangeRateConfig` from `Infrastructure.Config`

`Provider.hs` also exports `ExchangeRateMap`, `getRate`, and `RateProvider` — these are used by tests and `TransactionService`.

### Shared Cross-Rate Derivation

Both ECB (EUR-based) and NBU (UAH-based) need to derive a full cross-rate matrix from their base currency. This logic is extracted into a shared pure function in `Provider.hs`:

```haskell
deriveCrossRates :: Currency -> Map Currency Rational -> ExchangeRateMap
```

Given a base currency and a map of `Currency -> Rational` rates relative to that base, it produces pairs for all currencies present in the input map plus the base currency. It does **not** hardcode a list of supported currencies — the output is determined by the input map keys. This means if a provider doesn't return a particular currency, that currency's pairs are simply absent from the map.

This is an intentional change from the current `buildRateMap` which takes `[(Currency, Rational)]` — `Map` prevents duplicate entries and is a better fit.

### ECB Provider

Extracted from the current `ExchangeRate.hs`. `fetchEcbRates` becomes module-internal. The module exports only:

```haskell
ecbProvider :: RateProvider
```

Rate source: `https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml` (XML, EUR-based).

### NBU Provider

New module. Same pattern as ECB:

- Fetches `https://bank.gov.ua/NBUStatService/v1/statdirectory/exchange?json`
- Parses JSON array, filters for supported currencies (USD, EUR, GBP — UAH is implicit base)
- Calls `deriveCrossRates UAH rateMap` to produce full matrix
- Exports `nbuProvider :: RateProvider`

JSON response shape (per entry):

```json
{ "r030": 840, "txt": "...", "rate": 41.2345, "cc": "USD", "exchangedate": "18.03.2026" }
```

**Missing currencies:** If NBU does not return a rate for a supported currency (e.g., GBP is absent from the response), that currency's pairs are simply missing from the `ExchangeRateMap`. Downstream, `getCachedRate` returns `Left "NBU: no rate for GBP/UAH"` for those pairs. This is the same behavior as any rate lookup failure — the caller already handles `ExchangeRateUnavailable`. No special handling needed.

Dependencies: uses existing `http-client` / `http-client-tls`; JSON parsing via `aeson` (already a dependency).

### Configuration

New YAML config section using snake_case to match existing conventions (`event_store`, `process_managers`, `poll_interval_ms`):

```yaml
exchange_rate:
  provider: ecb  # or "nbu"
```

New config type:

```haskell
data ExchangeRateConfig = ExchangeRateConfig
  { provider :: Text
  }
```

`AppConfig` gains an `exchangeRate :: ExchangeRateConfig` field. The hand-written `FromJSON AppConfig` instance must be updated to parse the `exchange_rate` key:

```haskell
<*> v .: "exchange_rate"
```

A `FromJSON ExchangeRateConfig` instance parses the nested object.

Config file defaults:
- `local.yaml` / `test.yaml`: `provider: ecb`
- `prod.yaml`: `provider: ${EXCHANGE_RATE_PROVIDER:-ecb}`

### Wiring (Main.hs)

```haskell
let rateProvider = case config.exchangeRate.provider of
      "nbu" -> nbuProvider
      "ecb" -> ecbProvider
      unknown -> error $ "Unknown exchange rate provider: " <> T.unpack unknown
```

Invalid provider names cause a startup error rather than silently defaulting to ECB. A typo like `provider: ebc` should fail loud, not produce wrong rates.

`validateConfig` gains a check:

```haskell
let providerValue = config.exchangeRate.provider
when (providerValue `notElem` ["ecb", "nbu"]) $
  Left $ "Invalid exchange rate provider: " <> providerValue <> " (must be \"ecb\" or \"nbu\")"
```

Best-effort startup initialization preserved — app starts even if provider is unreachable.

### Error Handling

No new error types. Existing `ExchangeRateUnavailable Text` covers all providers. Each provider's `fetchRates` includes the provider name in error messages (e.g., `"NBU: failed to parse response"`, `"ECB: HTTP request failed"`).

### Testing

**Property tests (deriveCrossRates):**
- Given N base rates, produces correct number of pairs: (N+1) * N (all permutations of N+1 currencies excluding identity)
- Transitivity: `rate(A,B) * rate(B,C) ~ rate(A,C)`
- Inverse: `rate(A,B) * rate(B,A) ~ 1`

**Unit tests (NBU parsing):**
- Parse sample JSON payload, verify correct rate extraction
- Handle malformed JSON gracefully
- Handle missing currencies (response without GBP) — produces partial map

**Integration tests:**
- `NBUIntegrationSpec.hs` — fetch real rates, verify supported pairs exist, pending if network unavailable (same pattern as existing ECB integration test)
- Existing ECB integration test: updated import path from `Infrastructure.ExchangeRate` to `Infrastructure.ExchangeRate.ECB`, logic unchanged

**Cache tests:**
- `mockProvider :: ExchangeRateMap -> RateProvider` returns a fixed map
- Tests cache refresh logic (UTC midnight boundary) without network calls

**No logic changes needed** to TransactionService, TransferManager, or web layer tests — they interact through `HasExchangeRateCache` and are provider-agnostic. Import paths may change if they reference `Infrastructure.ExchangeRate` directly.

## Future: Merged Providers

The record-of-functions design naturally supports future composition. Two examples:

**Fallback** (use secondary when primary fails):

```haskell
fallbackProvider :: RateProvider -> RateProvider -> RateProvider
fallbackProvider primary secondary = RateProvider
  { providerName = primary.providerName <> "/" <> secondary.providerName
  , fetchRates = do
      result <- primary.fetchRates
      case result of
        Right rates -> pure (Right rates)
        Left _ -> secondary.fetchRates
  }
```

**Merge** (combine rate maps from both, primary wins on overlap):

```haskell
mergedProvider :: RateProvider -> RateProvider -> RateProvider
mergedProvider a b = RateProvider
  { providerName = a.providerName <> "+" <> b.providerName
  , fetchRates = do
      ratesA <- a.fetchRates
      ratesB <- b.fetchRates
      pure $ Map.union <$> ratesA <*> ratesB
  }
```

Both are out of scope for the current implementation but the design accommodates them without changes.
