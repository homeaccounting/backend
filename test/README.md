# Accounting Backend - Test Suite

## Overview

This test suite provides comprehensive coverage of the accounting backend using unit tests, property-based tests, and integration tests following formal verification principles.

## Test Structure

```
test/
├── Spec.hs                                      # Test discovery (hspec-discover)
├── README.md                                    # This file
├── TestSupport/                                 # Test utilities
│   ├── Generators.hs                           # QuickCheck generators and Arbitrary instances
│   └── Helpers.hs                              # Mock constructors and test assertions
├── Domain/                                      # Domain layer tests
│   ├── Core/
│   │   ├── TypesSpec.hs                        # Unit tests for Money, AccountId, TransactionId
│   │   └── TypesPropertySpec.hs                # Property tests for core types
│   ├── Account/
│   │   ├── CommandHandlerSpec.hs               # Unit tests for Account aggregate
│   │   └── CommandHandlerPropertySpec.hs       # Property tests for Account commands
│   └── Transaction/
│       ├── CommandHandlerSpec.hs               # Unit tests for Transaction aggregate
│       └── CommandHandlerPropertySpec.hs       # Property tests for Transaction commands
├── Application/                                 # Application layer tests
│   └── ProcessManagers/
│       ├── TransferManagerSpec.hs              # Unit tests for Transfer saga
│       └── TransferManagerPropertySpec.hs      # Property tests for saga invariants
└── Integration/                                 # Integration tests
    └── TransferWorkflowSpec.hs                 # End-to-end workflow tests
```

## Test Categories

### 1. Unit Tests (`*Spec.hs`)

Unit tests verify specific behaviors using the Arrange-Act-Assert (AAA) pattern:

- **Domain.Core.TypesSpec**: Tests smart constructors, validation, and arithmetic operations
- **Domain.Account.CommandHandlerSpec**: Tests account command handling and business rules
- **Domain.Transaction.CommandHandlerSpec**: Tests transaction state machine and validation
- **Application.ProcessManagers.TransferManagerSpec**: Tests saga coordination logic

**Example:**
```haskell
describe "CreateAccount Command" $ do
  context "Given empty account" $ do
    it "Then emits AccountCreated event" $ do
      -- Arrange
      let account = emptyAccount
      let command = CreateAccountAccountCommand $ CreateAccount "Savings" (mockMoney 1000)
      
      -- Act
      let events = handleAccountCommand account command
      
      -- Assert
      length events `shouldBe` 1
```

### 2. Property Tests (`*PropertySpec.hs`)

Property-based tests verify mathematical properties and invariants using QuickCheck:

- **Domain.Core.TypesPropertySpec**: Tests arithmetic laws (commutativity, associativity, identity)
- **Domain.Account.CommandHandlerPropertySpec**: Tests aggregate invariants
- **Domain.Transaction.CommandHandlerPropertySpec**: Tests state machine properties
- **Application.ProcessManagers.TransferManagerPropertySpec**: Tests saga invariants

**Example:**
```haskell
it "Then addition is commutative" $
  property $ \(m1 :: Money) (m2 :: Money) ->
    addMoney m1 m2 === addMoney m2 m1
```

### 3. Integration Tests (`Integration/*Spec.hs`)

Integration tests verify complete workflows through the entire system:

- **Integration.TransferWorkflowSpec**: Tests end-to-end transfer scenarios

**Example:**
```haskell
it "Then maintains balance invariant (total money unchanged)" $ do
  let totalBefore = addMoney sourceBalance targetBalance
  -- Execute transfer
  let totalAfter = addMoney newSourceBalance newTargetBalance
  totalAfter `shouldBe` totalBefore
```

## Running Tests

### Run All Tests

```bash
# With just
just test

# Or directly with cabal
cabal test --test-show-details=direct
```

### Run Specific Test Modules

```bash
# Using hspec pattern matching
cabal test --test-option='--match' --test-option="/Domain.Core.Types/"
```

### Run With Coverage

```bash
just test-coverage

# Or
cabal test --enable-coverage --test-show-details=direct
```

## Test Coverage

### Domain Layer

- ✅ **Money**: Smart constructor validation, arithmetic operations, invariants
- ✅ **AccountId**: UUID validation, non-nil invariant
- ✅ **TransactionId**: UUID validation, non-nil invariant
- ✅ **Account Aggregate**: All commands (Create, Credit, Debit), business rules
- ✅ **Transaction Aggregate**: All commands (Initiate, Complete, Fail), state machine

### Application Layer

- ✅ **Transfer Process Manager**: Saga coordination, command issuance, state tracking
- ✅ **Event Handling**: Debit success, debit rejection, state cleanup

### Integration Tests

- ✅ **Successful Transfers**: Complete workflow with sufficient funds
- ✅ **Failed Transfers**: Insufficient funds handling
- ✅ **Edge Cases**: Exact balances, zero amounts, multiple transfers
- ✅ **Invariants**: Balance conservation, state machine enforcement

## Test Utilities

### Generators (`TestSupport.Generators`)

QuickCheck generators for domain types:

```haskell
genMoney :: Gen Money              -- Valid Money values
genPositiveMoney :: Gen Money      -- Positive Money (> 0)
genAccountId :: Gen AccountId      -- Valid AccountId
genTransactionId :: Gen TransactionId
genNonEmptyText :: Gen Text
```

### Helpers (`TestSupport.Helpers`)

Mock constructors and assertions:

```haskell
mockMoney :: Double -> Money       -- Bypass validation for testing
mockAccountId :: UUID -> AccountId
mockTransactionId :: UUID -> TransactionId

shouldBeRight :: Either a b -> Expectation
shouldBeLeft :: Either a b -> Expectation
shouldSatisfyEither :: Either a b -> (Either a b -> Bool) -> Expectation
```

## Test Principles

### Following Formal Verification Guidelines

All tests follow the principles from `.cursor/rules/formal-verification.mdc`:

1. **Property-Based Testing First**: Mathematical properties verified with QuickCheck
2. **Unit Tests for Specific Cases**: Edge cases and error scenarios
3. **Integration Tests for Workflows**: End-to-end verification
4. **Given-When-Then Pattern**: Clear test structure
5. **Idempotency**: Tests can be run multiple times
6. **Determinism**: Same inputs produce same results

### Verified Properties

#### Money
- Non-negativity: `∀ m. unMoney m >= 0`
- Commutativity: `addMoney m1 m2 = addMoney m2 m1`
- Associativity: `addMoney (addMoney m1 m2) m3 = addMoney m1 (addMoney m2 m3)`
- Identity: `addMoney m 0 = m`

#### Account Aggregate
- Balance non-negativity
- Debit only succeeds with sufficient funds
- Credit always succeeds
- Rejection doesn't modify state

#### Transaction Aggregate
- State machine enforcement
- Only Pending → Completed
- Only Pending → Failed
- Terminal states immutable

#### Process Manager
- Debit before credit ordering
- Failed debit triggers compensation
- Idempotent event processing
- State cleanup after completion

#### System Invariants
- **Conservation**: Total money unchanged by transfers
- **Atomicity**: Either both operations succeed or both fail
- **Consistency**: All invariants maintained
- **Isolation**: Independent transfers don't interfere

## Adding New Tests

### 1. Create Test File

Follow naming conventions:
- `*Spec.hs` for unit tests
- `*PropertySpec.hs` for property tests
- `*IntegrationSpec.hs` for integration tests

### 2. Use Given-When-Then Pattern

```haskell
describe "Feature" $ do
  context "Given [initial state]" $ do
    describe "When [action]" $ do
      it "Then [expected outcome]" $ do
        -- Test implementation
```

### 3. Add Generators

If testing new types, add generators to `TestSupport.Generators`:

```haskell
instance Arbitrary YourType where
  arbitrary = genYourType
```

### 4. Verify Properties

Add property tests to verify invariants:

```haskell
it "Then maintains your invariant" $
  property $ \(input :: YourType) ->
    yourProperty input === expectedResult
```

## Dependencies

The test suite uses:

- **hspec** (2.10+): Test framework and organization
- **hspec-discover** (2.10+): Automatic test discovery
- **QuickCheck** (2.14+): Property-based testing
- **HUnit** (1.6+): Assertion library

## Continuous Integration

Tests should be run:
- On every commit
- Before merging pull requests
- With coverage reporting
- With all warnings enabled

## Known Limitations

1. **No IO Tests**: Pure business logic only, no database integration yet
2. **No API Tests**: No HTTP endpoint testing yet
3. **No Performance Tests**: No benchmarking yet

## Future Enhancements

- [ ] Add Read Model projection tests
- [ ] Add API endpoint tests with servant-client
- [ ] Add database integration tests with PostgreSQL
- [ ] Add performance benchmarks
- [ ] Add mutation testing
- [ ] Add test data builders



