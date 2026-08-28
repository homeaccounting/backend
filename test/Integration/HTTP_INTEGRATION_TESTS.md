# HTTP Integration Tests

## Overview

This directory contains HTTP integration tests that verify the entire web stack end-to-end:

- **HTTP Request/Response**: Real HTTP through Warp server
- **Routing**: Servant type-safe routing
- **Middleware**: CORS, logging, error handling
- **JSON Serialization**: Request/response DTO conversion
- **Domain Logic**: Command handlers and event sourcing
- **Process Managers**: Saga coordination (transfers)
- **Read Models**: Query-side projections

## Architecture

### In-Memory Event Store

All tests use **in-memory event stores** from `eventium-memory`:

```haskell
-- Create test environment with in-memory stores
testEnv <- createTestAppEnv
let app = buildApplication testEnv

-- Use in tests via hspec-wai
with (return app) $ do
  post "/api/accounts" payload `shouldRespondWith` 201
```

**Benefits:**
- ✅ **Fast**: No database I/O, pure STM transactions
- ✅ **Isolated**: Each test gets fresh state
- ✅ **Complete**: Full event sourcing behavior (versioning, projections, sagas)
- ✅ **Parallel**: Tests run concurrently without conflicts

### Test Stack

```
┌─────────────────────────────────────┐
│  Test Code (HSpec + hspec-wai)      │
├─────────────────────────────────────┤
│  HTTP Requests (real HTTP)          │
├─────────────────────────────────────┤
│  Warp Server (in-process)           │
├─────────────────────────────────────┤
│  Servant Application                │
│  ├─ Routing                         │
│  ├─ Middleware (CORS, logging, etc) │
│  └─ Handlers (AppM)                 │
├─────────────────────────────────────┤
│  Domain Layer                       │
│  ├─ Command Handlers                │
│  ├─ Event Sourcing                  │
│  └─ Process Managers                │
├─────────────────────────────────────┤
│  In-Memory Event Store (STM)        │
│  ├─ Event storage (TVar EventMap)   │
│  ├─ Event versioning                │
│  └─ Global event stream             │
└─────────────────────────────────────┘
```

## Test Files

### `WebAPISpec.hs`

HTTP integration tests for the REST API:

- **Account API**: Create, retrieve, credit, debit operations
- **Transaction API**: Transfer initiation and status queries
- **End-to-End Workflows**: Complete transfer sagas with process managers

### `TestSupport/InMemoryEventStore.hs`

Infrastructure for in-memory testing:

```haskell
-- Creates complete AppEnv with in-memory components
createTestAppEnv :: IO AppEnv

-- Creates event stores (writer, reader, global reader)
createInMemoryEventStores :: IO InMemoryEventStores

-- STM to IO lifting helpers
liftSTMWriter :: EventStoreWriter STM e -> EventStoreWriter IO e
liftSTMReader :: EventStoreReader STM e -> EventStoreReader IO e
```

## Usage

### Running Tests

```bash
# Run all tests
cabal test

# Run only HTTP integration tests
cabal test --test-options="-m Integration.WebAPISpec"

# Run specific test
cabal test --test-options="-m \"POST /api/accounts\""

# Run with verbose output
cabal test --test-show-details=streaming
```

### Writing New Tests

```haskell
import Test.Hspec
import Test.Hspec.Wai
import TestSupport.InMemoryEventStore

spec :: Spec
spec = describe "My API" $ do
  it "does something" $ do
    -- Create test environment
    env <- liftIO createTestAppEnv
    let app = buildApplication env
    
    -- Run test against the application
    with (return app) $ do
      -- Make HTTP requests
      post "/api/accounts" payload `shouldRespondWith` 201
      
      get "/api/accounts/123" `shouldRespondWith` 200
```

## Testing Patterns

### 1. Basic HTTP Connectivity

Test that the server responds correctly:

```haskell
it "responds to health check" $ do
  env <- liftIO createTestAppEnv
  let app = buildApplication env
  
  with (return app) $
    get "/api/health" `shouldRespondWith` 200
```

### 2. JSON Request/Response

Test JSON serialization and deserialization:

```haskell
it "creates account with JSON" $ do
  env <- liftIO createTestAppEnv
  let app = buildApplication env
  
  with (return app) $ do
    let payload = object
          [ "accountName" .= ("Savings" :: Text)
          , "initialBalance" .= (1000.0 :: Double)
          ]
    
    post "/api/accounts" (encode payload) `shouldRespondWith` 201
```

### 3. End-to-End Workflows

Test complete business workflows:

```haskell
it "completes transfer workflow" $ do
  env <- liftIO createTestAppEnv
  let app = buildApplication env
  
  with (return app) $ do
    -- Create source account
    sourceId <- liftIO UUID.nextRandom
    post ("/api/accounts/" <> UUID.toText sourceId) sourcePayload
    
    -- Create target account
    targetId <- liftIO UUID.nextRandom
    post ("/api/accounts/" <> UUID.toText targetId) targetPayload
    
    -- Create transaction
    post "/api/transactions" transferPayload
    
    -- Verify balances updated
    sourceResp <- get ("/api/accounts/" <> UUID.toText sourceId)
    -- Assert on balances...
```

### 4. Error Handling

Test validation and error responses:

```haskell
it "rejects invalid input" $ do
  env <- liftIO createTestAppEnv
  let app = buildApplication env
  
  with (return app) $ do
    let invalidPayload = object ["accountName" .= ("" :: Text)]
    
    post "/api/accounts" (encode invalidPayload) `shouldRespondWith` 400
```

## Dependencies

### Required Packages

From `package.yaml`:

```yaml
dependencies:
  - eventium-memory >= 0.1.0 && < 0.2.0
  - hspec-wai >= 0.11 && < 0.12
  - wai-extra >= 3.1 && < 3.2
  - http-types >= 0.12 && < 0.13
```

### Test Support Modules

- `Eventium.Store.Memory`: In-memory event store from `eventium-memory`
- `Test.Hspec.Wai`: HTTP testing utilities for Wai applications
- `TestSupport.InMemoryEventStore`: Local test infrastructure

## Advantages Over Unit Tests

1. **Real HTTP Stack**: Tests actual HTTP handling, not mocked
2. **Middleware Testing**: Verifies CORS, logging, error handling
3. **JSON Serialization**: Tests actual request/response DTOs
4. **Routing**: Verifies Servant routes work correctly
5. **End-to-End**: Complete workflows including sagas
6. **Fast**: Still runs in memory, no external dependencies

## Comparison with Production

| Aspect | Integration Tests | Production |
|--------|------------------|------------|
| Event Store | In-memory (STM) | PostgreSQL |
| HTTP Server | In-process Warp | Standalone Warp |
| Database | None (not needed) | PostgreSQL |
| Speed | Milliseconds | Normal |
| Isolation | Per-test | Shared |

**Everything else is identical**: Same handlers, same domain logic, same process managers, same event sourcing.

## Future Enhancements

### 1. Contract Testing

Add tests that verify API contracts:

```haskell
-- Verify response schema matches spec
it "returns valid account schema" $ do
  response <- get "/api/accounts/123"
  validateAgainstSchema accountSchema response
```

### 2. Property-Based HTTP Tests

Use QuickCheck for API property testing:

```haskell
prop "POST then GET returns same data" $ \account -> do
  response1 <- post "/api/accounts" (encode account)
  let accountId = extractId response1
  response2 <- get ("/api/accounts/" <> accountId)
  response1 `shouldMatchProperties` response2
```

### 3. Load Testing

Add tests for concurrent requests:

```haskell
it "handles concurrent transfers" $ do
  -- Run 100 transfers concurrently
  replicateConcurrently_ 100 $ do
    post "/api/transactions" payload
```

### 4. Snapshot Testing

Compare full responses against golden files:

```haskell
it "matches expected response" $ do
  response <- get "/api/accounts"
  response `shouldMatchGoldenFile` "test/golden/accounts-list.json"
```

## Troubleshooting

### Test Failures

**Symptom**: Tests fail with "connection refused"
**Solution**: Check that `buildApplication` creates a valid WAI application

**Symptom**: Tests fail with JSON parse errors
**Solution**: Verify JSON structure matches DTO definitions in `Web.Types`

**Symptom**: Tests fail with 404
**Solution**: Check API routes in `Web.API.*` modules

### Performance Issues

**Symptom**: Tests run slowly
**Solution**: Ensure using in-memory store, not connecting to real database

**Symptom**: Tests fail with timeouts
**Solution**: Check for deadlocks in STM transactions

### Debugging

Enable verbose logging:

```haskell
-- In test setup
logOptions <- logOptionsHandle stderr True  -- Verbose logging
withLogFunc logOptions $ \logFunc -> do
  env <- createTestAppEnv
  ...
```

## References

- **eventium-memory**: [README.md](../../eventium/eventium-memory/README.md)
- **hspec-wai**: [Hackage Documentation](https://hackage.haskell.org/package/hspec-wai)
- **Test Patterns**: [TEST_FILES_CREATED.md](../TEST_FILES_CREATED.md)

## Contributing

When adding new HTTP integration tests:

1. Follow the existing pattern in `WebAPISpec.hs`
2. Use `createTestAppEnv` for test setup
3. Test both success and error cases
4. Include end-to-end workflow tests for complex features
5. Document any new test helpers in this README
