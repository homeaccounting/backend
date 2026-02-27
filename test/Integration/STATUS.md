# HTTP Integration Testing - Current Status

## ✅ What's Implemented and Working

### 1. **In-Memory Event Store Infrastructure** (`TestSupport/InMemoryEventStore.hs`)
- ✅ STM-based event stores from `eventium-memory`
- ✅ `createInMemoryEventStores()` function
- ✅ Event store lifting from STM to IO
- ✅ All type definitions and utilities

### 2. **Test Configuration**
- ✅ Full `AppConfig` with all required fields
- ✅ `DatabaseConfig` properly structured  
- ✅ Logging, CORS, Event Store, Process Manager configs

### 3. **Documentation**
- ✅ `HTTP_INTEGRATION_TESTS.md` - Complete guide
- ✅ `HTTP_INTEGRATION_IMPLEMENTATION.md` - Implementation details
- ✅ Code is well-documented with examples

### 4. **Web Server Export**
- ✅ `buildApplication` is exported from `Web.Server`
- ✅ Can build WAI applications from `AppEnv`

## ⚠️ Current Limitation

### The ConnectionPool Problem

**Issue**: `AppEnv` has a strict `ConnectionPool` field:

```haskell
data AppEnv = AppEnv
  { ...
    appDbPool :: !ConnectionPool,  -- Strict field!
    ...
  }
```

Because of the strict field (`!`), the value is evaluated immediately when `AppEnv` is constructed. This means we **cannot use `undefined` or `error`** - we need an actual `ConnectionPool` value.

**Impact**: Cannot construct full `AppEnv` in tests without a database connection.

## 🔧 Solutions (Pick One)

### Option 1: Use Database in Tests (Recommended)
Set up a test PostgreSQL database and create a real connection pool:

```haskell
createTestAppEnv :: IO AppEnv
createTestAppEnv = do
  -- Create real pool pointing to test database
  pool <- createPool testDbConfig
  ...
```

**Pros**: Tests real integration, finds database-related bugs
**Cons**: Requires PostgreSQL running, slower tests

### Option 2: Make Field Non-Strict
Change `AppEnv` to make `appDbPool` non-strict:

```haskell
data AppEnv = AppEnv
  { ...
    appDbPool :: ConnectionPool,  -- Remove ! 
    ...
  }
```

**Pros**: Simple, enables in-memory-only tests
**Cons**: Changes production code, might hide bugs

### Option 3: Create Mock ConnectionPool
Implement a mock `ConnectionPool` that doesn't connect anywhere:

```haskell
createMockPool :: IO ConnectionPool
createMockPool = ... -- Complex implementation
```

**Pros**: No database needed, doesn't change production code
**Cons**: Complex to implement correctly

### Option 4: Test Components Separately
Don't construct full `AppEnv`, test components individually:

```haskell
it "event stores work" $ do
  stores <- createInMemoryEventStores
  -- Test event stores directly
```

**Pros**: Simple, works now
**Cons**: Doesn't test full integration

## 📝 Current Test Status

The tests in `Integration/WebAPISpec.hs` currently just verify that the infrastructure compiles. They don't create `AppEnv` or test HTTP requests because of the `ConnectionPool` issue.

To enable full HTTP integration tests:

1. **Choose a solution above** (recommend Option 1 or Option 4)
2. **Add `hspec-wai`** dependency to `package.yaml`
3. **Uncomment the dependencies** in `package.yaml`:
   ```yaml
   - hspec-wai >= 0.11 && < 0.12
   - hspec-wai-json >= 0.11 && < 0.12
   ```
4. **Implement actual HTTP tests** using examples from `HTTP_INTEGRATION_TESTS.md`

## 🎯 Recommendation

For your use case (event-sourced system with in-memory stores), I recommend:

**Option 4 + Partial Option 1**: 
- Test event sourcing components directly (no full `AppEnv`)
- Add optional full-stack tests that require database
- Mark database tests with a flag so they can be skipped

Example:
```haskell
spec :: Spec
spec = do
  -- Always run: component tests
  eventStoreComponentSpec
  
  -- Conditional: full HTTP tests
  when (hasDatabase) $ do
    fullHTTPIntegrationSpec
```

## 📚 Next Steps

1. Review the four options above
2. Choose an approach based on your needs
3. Implement chosen solution
4. Add full HTTP tests using `hspec-wai`
5. Update `WebAPISpec.hs` with actual test cases

All the infrastructure is in place - you just need to solve the `ConnectionPool` issue to enable full `AppEnv` creation!

## 🔗 References

- `test/TestSupport/InMemoryEventStore.hs` - Event store setup
- `test/Integration/HTTP_INTEGRATION_TESTS.md` - Complete guide
- `test/Integration/HTTP_INTEGRATION_IMPLEMENTATION.md` - Implementation details
- `src/Web/Server.hs` - Server and application building
