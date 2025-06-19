# Idiomatic Error Handling for Mission-Critical Haskell Systems

## Executive Summary

This document outlines our idiomatic Haskell approach to error handling using explicit error types with `Either` and `ExceptT`. This approach improves testability, code coverage analysis, and system robustness while maintaining simplicity and directness.

Our error handling philosophy embraces Haskell's natural approach of making errors explicit in the type system. We maintain the core principle of fail-fast - that errors should be immediately visible and prevent the system from operating in invalid states.

Additionally, we adopt the functional programming principle of **pushing effects to the boundaries** while keeping the core error handling logic pure. This separation enhances testability, composability, and mathematical reasoning about our error handling, and aligns perfectly with our hexagonal architecture design principles of maintaining a pure domain core with effects isolated to the boundaries.

As outlined in our [application-composition.md](application-composition.md) document (see section 6 on Simplified Effect Management), we use a single application monad (`AppM`) directly across all components, which simplifies our error handling approach while maintaining all mathematical properties and architectural boundaries.

This document provides comprehensive background, technical architecture, design rationale, and best practices for implementing idiomatic error handling throughout our codebase.

## Table of Contents

1. [Background and Context](#background-and-context)
2. [Goals and Principles](#goals-and-principles)
3. [Technical Architecture](#technical-architecture)
4. [Architectural Alignment](#architectural-alignment)
5. [Design Decisions](#design-decisions)
6. [Analysis and Reasoning](#analysis-and-reasoning)
7. [Guidance and Best Practices](#guidance-and-best-practices)
8. [Advanced Error Handling Patterns](#advanced-error-handling-patterns)
9. [Resource Safety](#resource-safety)
10. [Error Recovery Strategies](#error-recovery-strategies)
11. [Formal Verification of Error Handling](#formal-verification-of-error-handling)
12. [Error Observability](#error-observability)

## Background and Context

Our mission-critical system uses an idiomatic Haskell approach to error handling through `Either` and `ExceptT`. This approach prioritizes:

1. Explicit error representation in the type system
2. Complete error context display with debugging information
3. Clear boundaries between pure and effectful code
4. No silent failures

This approach offers significant advantages for:

1. **Testing**: All error paths can be tested without process termination
2. **Coverage Analysis**: Code coverage tools can analyze error-handling code
3. **Composability**: Functions that may fail can be easily composed
4. **Purity**: Pure functions remain pure, with effects at boundaries

Our approach represents a balance between Haskell's type-driven approach and practical operational needs:

- Strong static type system to prevent errors at compile time
- Explicit effect tracking through the type system
- Rich error context for debugging and troubleshooting
- Clear separation between pure logic and effectful operations

By examining real-world Haskell systems in mission-critical domains (finance, aerospace, medical), we've identified that this idiomatic Haskell approach to error handling offers superior safety, testability, and maintainability.

## Goals and Principles

### Primary Goals

Our idiomatic Haskell error handling aims to achieve:

1. **Enhanced Safety**: Maintain system safety guarantees by making errors explicit in the type system.

2. **Improved Testability**: Allow comprehensive testing of error paths without process termination, enabling complete code coverage.

3. **Better Composability**: Enable seamless composition of functions that may fail, improving code maintainability and readability.

4. **Runtime Safety**: Preserve core safety principles (immediate visibility of errors, prevention of invalid states).

5. **Simplify Code Coverage**: Allow standard code coverage tools to analyze our entire codebase.

6. **Maintain Simplicity**: Provide a simple, consistent error handling pattern that is easy to learn and apply across the codebase.

7. **Maximize Purity**: Keep core error types and validation logic pure, pushing effects to the boundaries of the application.

### Core Principles

Our error handling approach is guided by these core principles:

#### 1. Type-First Error Handling

Error conditions must be explicitly represented in function signatures using appropriate type constructors:

```haskell
-- INCORRECT: Implicit termination with no error in type signature
mkIdentifier :: MonadIO m => Text -> m Identifier

-- CORRECT: Explicit error handling with errors in type signature
mkIdentifier :: Text -> Either AppError Identifier
```

This makes the possibility of failure visible in the type signature and forces callers to handle the error case.

#### 2. Unified Error Type

Our system uses a single, streamlined error type with rich context:

```haskell
-- Single, unified error type with rich context
data AppError = AppError
  { errorMessage :: !Text              -- Error description
  , errorContext :: !Text              -- Operation context (function name)
  , errorDetails :: !(Map Text Text)   -- Additional debug info
  , errorCallStack :: !CallStack       -- Captured call stack for debugging
  } deriving stock (Show, Generic)
```

#### 3. Unified Error Interface

A single, simple module provides all error handling needs:

```haskell
-- Control.Error provides a unified, simple interface
module Control.Error
  ( -- * Error Types
    AppError(..)
    -- * Error Monad
  , AppM
  , runAppM
    -- * Error Creation 
  , mkAppError
    -- * Re-exports from Control.Monad.Except
  , MonadError(..)  -- includes throwError and catchError
  , withExceptT
  , ExceptT(..)
  , runExceptT
  ) where
```

#### 4. Error Boundaries

Clear error boundaries should be established where errors are translated between layers:

```haskell
-- Domain layer: Domain-specific errors
validateInput :: Input -> Either AppError ValidInput

-- Application layer: Handle errors in monadic context
processInput :: Input -> AppM Result
processInput input = do
  case validateInput input of
    Right validInput -> -- Continue processing...
    Left err -> throwError err
```

#### 5. Preservation of Fail-Fast Benefits

Our approach preserves these key benefits of the fail-fast philosophy:

- **Complete Error Context**: Rich error types with all debugging information
- **No Silent Failures**: Errors must be explicitly handled
- **No Invalid States**: Strong validation prevents invalid states
- **Clear Error Reporting**: Detailed, consistent error messages
- **Immediate Termination**: Errors at the top level still cause program termination

#### 6. Simplicity First

We prioritize simplicity and consistency over complexity:

- Single application monad (`AppM`) for all operations
- Consistent error handling patterns throughout codebase
- Minimal set of helper functions for common patterns
- No complex strategies unless absolutely necessary

#### 7. Pure Core, Effectful Shell

We organize error handling using a layered approach:

- **Pure Core**: Error types and pure validation functions
- **Effectful Shell**: IO operations like logging and program termination

This separation enables maximum reuse, testability, and reasoning about the core error logic.

These principles guide our design and implementation decisions throughout the codebase, maintaining simplicity while embracing Haskell's strengths.

## Technical Architecture

Our error handling architecture uses a structured, type-based approach that makes errors explicit at every level. This section details the technical components of this architecture.

### Modular Organization

We use a single, focused module for error handling:

```haskell
-- In src/Control/Error.hs
module Control.Error
  ( -- * Error Types
    AppError(..)
    -- * Error Monad
  , AppM
  , runAppM
    -- * Error Creation 
  , mkAppError
    -- * Re-exports from Control.Monad.Except
  , MonadError(..)  -- includes throwError and catchError
  , withExceptT
  , ExceptT(..)
  , runExceptT
  ) where
```

This module contains:

1. **Error Types**: A unified `AppError` type with rich context
2. **Monad Definition**: The `AppM` monad for effectful operations
3. **Error Creation**: Functions for creating well-structured errors
4. **Re-exports**: Common error handling functions from `Control.Monad.Except`

### Core Components

#### 1. Unified Error Type

Our system uses a single, comprehensive error type:

```haskell
-- | Single, unified error type with rich context
data AppError = AppError
  { errorMessage :: !Text              -- ^ Error description
  , errorContext :: !Text              -- ^ Operation context (function name)
  , errorDetails :: !(Map Text Text)   -- ^ Additional debug info
  , errorCallStack :: !CallStack       -- ^ Captured call stack for debugging
  } deriving stock (Show, Generic)
```

This provides:
- Clear error messages through `errorMessage`
- Operation context through `errorContext`
- Debugging details through `errorDetails`
- Stack trace information through `errorCallStack`

#### 2. Application Monad

```haskell
-- | Application monad with error handling
type AppM a = ExceptT AppError IO a

-- | Run the application monad
runAppM :: AppM a -> IO (Either AppError a)
runAppM = runExceptT
```

The `AppM` monad:
- Uses `ExceptT` for error handling
- Maintains explicit error types in signatures
- Provides a consistent pattern for effectful operations

#### 3. Error Creation

```haskell
-- | Create a new error with context and automatic callstack capture
mkAppError :: HasCallStack 
           => Text            -- ^ Error message
           -> Text            -- ^ Context (function name)
           -> Map Text Text   -- ^ Error details
           -> AppError
mkAppError msg ctx details = AppError
  { errorMessage = msg
  , errorContext = ctx
  , errorDetails = details
  , errorCallStack = callStack
  } 
```

This function:
- Creates errors with consistent structure
- Automatically captures the call stack
- Records operation context
- Includes debugging details

## Architectural Alignment

This section explains how our error handling approach aligns with our hexagonal architecture by maintaining a pure domain core with effects pushed to the boundaries.

### Hexagonal Architecture and Error Handling

In our hexagonal architecture, we distinguish between:

1. **Domain Layer** (`src/Domain/`): Pure business types and logic 
2. **Component Layer** (`src/Components/`): Domain and Integration components
3. **Infrastructure Layer** (`src/`): Cross-cutting concerns

The error handling approach respects these architectural boundaries and maintains the purity of the domain core.

### Pure vs Effectful Error Handling

Our error handling aligns with hexagonal architecture by separating:

#### Pure Domain Core
- Domain types use pure validation returning `Either AppError a`
- Smart constructors in domain modules are pure
- No monadic operations in domain logic
- Business rules are expressible as pure functions

#### Effectful Boundaries
- Component ports and adapters handle effectful operations
- `AppM` and other monadic types are used at the boundaries
- Error logging and termination happen at application edges

### Component Organization

```
src/
│
├── Domain/ (PURE)
│   ├── Identifier.hs
│   └── ... (other domain types)
│   
├── Components/
│   ├── ComponentName/
│   │   ├── ComponentNameAPI.hs (EFFECTFUL API)
│   │   ├── Config/
│   │   │   └── ComponentNameEnv.hs (PURE)
│   │   ├── OutboundPorts/ (PURE interfaces)
│   │   └── Implementation/
│   │       ├── Adapters/ (EFFECTFUL)
│   │       │   └── ExternalSystemAdapter.hs
│   │       └── Core/ (PURE business logic)
│   │
│   └── ... (other components)
│
└── Control/
    └── Error.hs (cross-cutting concern)
```

### Bridge Between Pure and Effectful Worlds

To bridge between pure domain logic and effectful component operations:

1. **Domain Type Example**:
```haskell
-- In Domain/Identifier.hs (PURE)
module Domain.Identifier
    ( Identifier(..)
    , mkIdentifier  -- Pure smart constructor
    ) where

import Control.Error (AppError(..))
import qualified Data.Map as Map

newtype Identifier = Identifier { unIdentifier :: Text }
    deriving (Show, Eq)

-- PURE smart constructor
mkIdentifier :: Text -> Either AppError Identifier
mkIdentifier id = 
    if isValid id 
    then Right $ Identifier id
    else Left $ AppError
        { errorMessage = "Invalid identifier: " <> id
        , errorContext = "mkIdentifier"
        , errorDetails = Map.singleton "invalid_input" id
        , errorCallStack = callStack
        }
```

2. **Component API Example**:
```haskell
-- In Components/ComponentName/ComponentNameAPI.hs (EFFECTFUL API)
getData :: ResourceId -> UTCTime -> AppM [DataPoint]
getData (ResourceId rid) endTime = do
    -- Validate inputs directly in the monadic context
    currentTime <- liftIO getCurrentTime
    when (endTime > currentTime) $
        throwError $ AppError 
            { errorMessage = "End time cannot be in the future"
            , errorContext = "getData"
            , errorDetails = Map.fromList 
                [ ("end_time", show endTime)
                , ("current_time", show currentTime)
                ]
            , errorCallStack = callStack
            }
    
    -- Access environment components through the AppEnv
    componentEnv <- asks appComponentEnv
    let client = getHttpClient componentEnv
    let config = getHttpConfig componentEnv
    
    -- Continue with effectful operations...
    response <- liftIO $ executeRequest client config "/data" params
    parseDataPoints response
```

### Error Handling Flow in Hexagonal Architecture

The flow of errors in our hexagonal architecture follows these steps:

1. **Domain Layer**: Pure validation with `Either AppError a`
2. **Component Layer**: Handling of domain errors with `throwError`
3. **Application Layer**: Top-level error handling and display

### Summary

This architectural alignment ensures:

1. **Pure Domain Core**: All domain logic remains pure and easily testable
2. **Clean Boundaries**: Effects are isolated to boundary components
3. **Explicit Interfaces**: Error types provide clear contracts between layers
4. **Maximum Testability**: Pure functions can be tested without IO
5. **Rigorous Verification**: Properties can be verified with property-based testing

## Design Decisions

This section outlines the key design decisions made in our error handling architecture, along with their rationale and alternatives considered.

### 1. Either vs. Maybe

**Decision**: Use `Either AppError a` instead of `Maybe a` for pure operations that can fail.

**Rationale**:
- `Either` carries error information in the `Left` constructor
- `Maybe` only indicates failure without context
- Rich error types are essential for debugging and logging

**Alternatives Considered**:
- `Maybe` with separate error reporting: Less explicit, risks errors being ignored
- Custom sum types: Less standardized, requiring custom handling functions

**Example**:
```haskell
-- CORRECT: Either with error type
validateInput :: Input -> Either AppError ValidInput

-- INCORRECT: Maybe with no error context
validateInput :: Input -> Maybe ValidInput
```

### 2. ExceptT for Monadic Composition

**Decision**: Use `ExceptT AppError IO a` unified as `AppM a` for all operations that can fail within a monadic context.

**Rationale**:
- Provides a single, consistent pattern across the codebase
- Enables clean do-notation for sequential operations
- Automatically short-circuits on first error
- Simplifies mental model (one way to handle errors)

**Alternatives Considered**:
- Manual error propagation: More verbose, error-prone
- Multiple monad transformers: More complex, harder to understand
- IO with exceptions: Less explicit, harder to track in types

**Example**:
```haskell
-- Single application monad for consistency
type AppM a = ExceptT AppError IO a

processRequest :: Request -> AppM Response
processRequest request = do
  case validateRequest request of
    Right validRequest -> do
      response <- tryIO (submitRequest validRequest) "API submission failed"
      pure (processResponse response)
    Left err -> throwError err
```

### 3. Single Error Type

**Decision**: Use a single `AppError` record type with rich context fields.

**Rationale**:
- Keeps the error system simple and understandable
- Provides enough specificity for proper error handling
- Maintains good debugging information
- Single consistent pattern across the codebase

**Alternatives Considered**:
- Multi-level error hierarchy: More complex with minimal added benefit
- Sum type with constructors: Less flexibility in error context
- String-based errors: No type safety, harder to handle systematically

**Example**:
```haskell
-- Single error type with rich context
data AppError = AppError
  { errorMessage :: !Text              -- Error description
  , errorContext :: !Text              -- Operation context (function name)
  , errorDetails :: !(Map Text Text)   -- Additional debug info
  , errorCallStack :: !CallStack       -- Captured call stack for debugging
  }
```

### 4. Error Context Preservation

**Decision**: Include source location and debug context with all errors.

**Rationale**:
- Provides essential debugging information
- Enables detailed logging and monitoring
- Supports root cause analysis
- Consistent pattern for all errors

**Alternatives Considered**:
- Minimal error types: Less context for debugging
- Logging at error sites: Risks inconsistent error reporting
- Global error registry: More complex, harder to maintain

**Example**:
```haskell
-- Create errors with context
mkAppError :: HasCallStack 
           => Text            -- ^ Error message
           -> Text            -- ^ Context (function name)
           -> Map Text Text   -- ^ Error details
           -> AppError
```

### 5. Top-Level Error Handling

**Decision**: Handle errors at the application level with consistent display functions.

**Rationale**:
- Ensures consistent error reporting
- Prevents operating in invalid states
- Works well with our single-user, session-based operational model
- Simple pattern that works across the application

**Alternatives Considered**:
- Generic library handler: Less tailored to application needs
- Distributed error handling: More complex, less consistent

**Example**:
```haskell
-- Application-specific error handling
main :: IO ()
main = do
    env <- createAppEnv
    result <- runAppM env app
    case result of
        Right output -> displayResults output
        Left err -> displayError err

-- Standard error display function
displayError :: AppError -> IO ()
displayError err = do
  putTextLn $ "ERROR: " <> errorMessage err
  putTextLn $ "Context: " <> errorContext err
  putTextLn $ "Details: " <> show (errorDetails err)
  -- Optionally display call stack in development
  when isDevelopment $
    putTextLn $ "Stack: " <> show (errorCallStack err)
  exitFailure
```

### 6. Minimalist Helper Functions

**Decision**: Provide a minimal set of helper functions focused on error creation and handling.

**Rationale**:
- Reduces complexity
- Ensures consistent error handling
- Simplifies the mental model (few functions to learn)
- Allows for code that's easy to understand and maintain

**Alternatives Considered**:
- Extensive utility library: More complex, steeper learning curve
- Custom operators: Less readable, harder to understand
- Ad-hoc handling: Less consistent, more duplication

**Example**:
```haskell
-- Minimal but sufficient helper functions
mkAppError :: HasCallStack => Text -> Text -> Map Text Text -> AppError
```

### 7. Consolidated Error Module

**Decision**: Use a single module `Control.Error` for all error handling.

**Rationale**:
- Simplifies imports and module organization
- Creates a single source of truth for error handling
- Easier to understand for developers
- Clear, consistent pattern across the codebase

**Alternatives Considered**:
- Multi-module organization: More complex, harder to navigate
- Component-specific error modules: Risks inconsistency
- More granular separation: Adds complexity with little benefit

**Example**:
```haskell
-- Single, consolidated module
module Control.Error
  ( -- * Error Types
    AppError(..)
    -- * Error Monad
  , AppM
  , runAppM
    -- * Error Creation
  , mkAppError
    -- * Re-exports
  , MonadError(..)
  , withExceptT
  , ExceptT(..)
  , runExceptT
  ) where
```

These design decisions strike a balance between idiomatic Haskell error handling and simplicity, providing a consistent, easy-to-understand pattern that works well for our operational context while maximizing purity and testability.

## Analysis and Reasoning

This section provides a comparative analysis of our error handling approach against alternatives.

### Comparative Analysis

The following table compares key aspects of different error handling approaches:

| Aspect | Our `Either`/`ExceptT` Approach | Classic Exceptions | String-Based Errors |
|--------|----------------------------------|-------------------|---------------------|
| **Error Visibility** | Explicit in function signatures | Implicit, undocumented | Partial, through documentation |
| **Composability** | Excellent - errors compose naturally | Poor - requires catch blocks | Moderate - manual handling |
| **Testing** | Simple - errors are values to inspect | Difficult - requires exception handling | Moderate - string parsing |
| **Code Coverage** | Standard - all code paths analyzable | Challenging - exception paths hard to test | Standard - but less specific |
| **Error Context** | Rich - structured context | Variable - depends on implementation | Limited - text only |
| **Type Safety** | High - errors explicit in types | Low - no type-level tracking | Low - string-based |
| **Error Specificity** | High - structured error type | Moderate - exception hierarchies | Low - text parsing required |
| **Industry Alignment** | High - standard practice in Haskell | Moderate - common in OO languages | Low - generally avoided |
| **Purity** | High - core validation logic remains pure | Low - effectful by nature | Moderate - depends on implementation |
| **Modularity** | High - clear separation of concerns | Low - mixed concerns | Moderate - depends on implementation |

### Safety Analysis

Our approach enhances safety in several ways:

#### 1. Type-Level Safety

Our approach makes errors explicit at the type level:

```haskell
-- Type indicates exactly how this can fail
mkIdentifier :: Text -> Either AppError Identifier
```

This explicit representation of errors offers several safety benefits:

- **Forced Error Handling**: Callers must explicitly handle or propagate errors
- **Compile-Time Checking**: The compiler ensures errors are addressed
- **Error Type Specificity**: The exact nature of possible errors is documented
- **No Silent Failures**: Errors cannot be accidentally ignored

#### 2. Error Propagation Safety

Our approach propagates errors as values:

```haskell
-- Errors propagate as values through the monadic context
processTransaction :: Transaction -> AppM TransactionResult
processTransaction tx = do
  case validateAccount (txAccount tx) of
    Right account -> do
      case validateAmount (txAmount tx) of
        Right amount -> calculateResult account amount
        Left err -> throwError err
    Left err -> throwError err
```

This approach offers superior control over error handling:

- **Error Transformation**: Errors can be enriched or transformed as they propagate
- **Error Context Enrichment**: Additional context can be added as errors propagate
- **Clean Composition**: Complex operations compose naturally
- **Type Safety**: The type system tracks error propagation

#### 3. Testing Safety

Our approach makes testing error paths straightforward:

```haskell
-- Simple to test error conditions
it "should reject invalid identifier" $ do
  case mkIdentifier "invalid/format" of
    Left err -> errorMessage err `shouldContain` "Invalid identifier"
    Right _ -> expectationFailure "Expected validation error"
```

This improves safety through:

- **Complete Test Coverage**: All error paths can be easily tested
- **Error Verification**: Error messages and context can be verified
- **Edge Case Testing**: Unusual error conditions can be simulated
- **Regression Prevention**: Error handling changes are caught by tests

#### 4. Purity Safety

Our approach keeps core validation logic pure:

```haskell
-- Core validation remains pure
validateIdentifier :: Text -> Either AppError Identifier
validateIdentifier text =
  if isValidFormat text
    then Right (Identifier text)
    else Left $ mkAppError "Invalid format" "validateIdentifier" 
           (Map.singleton "value" text)
```

This purity provides several benefits:

- **Reasoning**: Pure functions are easier to reason about mathematically
- **Testing**: Pure functions can be tested without IO context
- **Composability**: Pure validation functions compose easily with other pure code
- **Refactoring**: Pure code can be refactored with fewer side-effect concerns

### Case Studies from Industry

To validate our approach, we analyzed several mission-critical Haskell systems:

#### 1. Financial Systems

Major financial institutions using Haskell consistently use the Either/ExceptT pattern:

```haskell
-- Example adapted from real financial system
validateTransaction :: Transaction -> Either ValidationError ValidTransaction
processPayment :: ValidTransaction -> ExceptT PaymentError IO PaymentResult
```

#### 2. Aerospace Software

Companies like Galois that produce aerospace software in Haskell use similar patterns with additional formal verification:

```haskell
-- Example inspired by aerospace control systems
type Validated a = Either ValidationError a
{-@ measure isValidated @-}
{-@ validateInput :: i:Input -> {o:Validated Output | isValidated o} @-}
```

#### 3. Medical Devices

Medical device software written in Haskell follows similar patterns with strong error typing:

```haskell
-- Example inspired by medical software
data MedicationError = DosageError | InteractionError | TimingError
computeDosage :: Patient -> Medication -> Either MedicationError Dosage
```

Our approach aligns with these mission-critical systems while maintaining simplicity appropriate for our operational context.

## Guidance and Best Practices

This section provides concrete guidance on implementing idiomatic error handling in our codebase. Following these best practices will ensure consistency, maintainability, and safety across our system.

### Module Organization

#### Consolidated Error Module

Use the single `Control.Error` module for all error handling needs:

```haskell
-- Import error handling functions
import Control.Error 
  ( AppError(..)  -- Error type
  , AppM          -- Application monad
  , runAppM       -- Run application monad
  , mkAppError    -- Create errors with context
  , throwError    -- Throw errors in monadic context
  )
```

### Error Type Design

#### Rich Context for All Errors

Always include sufficient context for effective debugging:

```haskell
-- Create an error with rich context
throwError $ AppError 
  "Invalid input value"        -- Message 
  "functionName"               -- Context
  (Map.singleton "input" "0")  -- Details
```

#### Use the mkAppError Helper

Prefer the `mkAppError` helper for consistent error creation:

```haskell
-- Create errors consistently
throwError $ mkAppError 
  "Invalid input value"        -- Message 
  "functionName"               -- Context
  (Map.singleton "input" "0")  -- Details
```

### Function Signatures

#### Pure Validation Functions

For pure validation functions, use `Either AppError`:

```haskell
-- For domain validation
validateEmail :: Text -> Either AppError Email
validateEmail text
  | not (isValidEmailFormat text) = 
      Left $ mkAppError "Email format invalid" "validateEmail" 
             (Map.singleton "email" text)
  | length text > 100 = 
      Left $ mkAppError "Email too long" "validateEmail"
             (Map.fromList [("email", text), ("length", show (length text))])
  | otherwise = 
      Right (Email text)
```

#### IO Operations

For IO operations, use our `AppM` monad:

```haskell
-- For operations that interact with external systems
fetchData :: ResourceId -> AppM ResourceData
fetchData resourceId = do
  -- Use try/catch for IO operations
  result <- liftIO $ try $ sendRequest resourceId
  case result of
    Right response -> 
      case parseResponseData response of
        Right data -> pure data
        Left err -> throwError $ mkAppError 
                      "Failed to parse response data" 
                      "fetchData"
                      (Map.singleton "error" (show err))
    Left (e :: SomeException) -> 
      throwError $ mkAppError 
        "Failed to fetch data" 
        "fetchData"
        (Map.fromList [("resourceId", show resourceId), ("error", show e)])
```

#### Pattern for Effectful Functions

Prefer a consistent pattern for effectful functions:

```haskell
functionThatCanFail :: Input -> AppM Result
functionThatCanFail input = do
  -- 1. Validate inputs
  case validateInput input of
    Right validInput -> do
      -- 2. Perform operations with error handling
      response <- performIO validInput
      -- 3. Process and return results
      pure (processResponse response)
    Left err -> throwError err
```

### Error Handling Patterns

#### Pushing Effects to Boundaries

Keep the core logic pure and push effects to the boundaries:

```haskell
-- Pure core logic
validateResource :: ResourceData -> Either AppError ValidResource
validateResource resource = do
  -- Pure validation chain
  if isValidName (resourceName resource)
    then if isValidQuantity (resourceQuantity resource)
      then Right $ ValidResource (resourceName resource) (resourceQuantity resource)
      else Left $ mkAppError "Invalid quantity" "validateResource" 
             (Map.singleton "quantity" (show (resourceQuantity resource)))
    else Left $ mkAppError "Invalid name" "validateResource"
           (Map.singleton "name" (resourceName resource))

-- Effect boundary - application edge
storeResource :: ResourceData -> AppM StoredResource
storeResource resourceData = do
  case validateResource resourceData of
    Right validResource -> do
      -- IO operation with error handling
      result <- liftIO $ try $ saveToDatabase validResource
      case result of
        Right storedResource -> pure storedResource
        Left (e :: SomeException) -> throwError $ mkAppError
          "Database error" "storeResource" (Map.singleton "error" (show e))
    Left err -> throwError err
```

### Testing Best Practices

#### Testing Pure Functions

Test pure validation functions directly:

```haskell
describe "validateEmail" $ do
  it "accepts valid email addresses" $ do
    case validateEmail "user@example.com" of
      Right email -> unEmail email `shouldBe` "user@example.com"
      Left err -> expectationFailure $ 
        "Expected success but got error: " ++ show (errorMessage err)
  
  it "rejects invalid email formats" $ do
    case validateEmail "not-an-email" of
      Left err -> errorMessage err `shouldContain` "format invalid"
      Right _ -> expectationFailure "Expected validation error"
```

#### Use Testing Utilities

Leverage our testing utilities for consistent assertions:

```haskell
-- Import test utilities
import TestUtils.Error 
  ( shouldValidate
  , shouldRejectWith
  , errorMessageShouldContain
  )

-- Use in tests
it "validates correct input" $ do
  validateEmail "user@example.com" `shouldValidate` Email "user@example.com"

it "rejects invalid input" $ do
  errorMessageShouldContain (validateEmail "invalid") "format invalid"
```

#### Testing Monadic Functions

Create test utilities to make testing `AppM` functions easier:

```haskell
-- Import test utilities
import TestUtils.AppEnv (mkTestEnv)

-- Helper for testing AppM functions
runAppMTest :: AppM a -> IO (Either AppError a)
runAppMTest action = do
    -- Create mock environment
    mockClient <- createMockHttpClient
    let config = defaultTestConfig
    let componentEnv = mkComponentEnv mockClient config
        
    -- Create minimal AppEnv with just what we need
    let appEnv = mkTestEnv componentEnv
    
    -- Run with AppM directly
    runAppM appEnv action

-- Example test
describe "fetchData" $ do
  it "returns data for valid resources" $ do
    result <- runAppMTest $ fetchData validId
    case result of
      Right data -> name data `shouldBe` "Test Resource"
      Left err -> expectationFailure $ 
        "Expected success but got error: " ++ show (errorMessage err)
```

### Application-Level Error Handling

#### Consistent Top-Level Pattern

Use a consistent pattern for top-level error handling:

```haskell
main :: IO ()
main = do
  -- 1. Create environment
  env <- createAppEnv
  
  -- 2. Run application with error handling
  result <- runAppM env app
  
  -- 3. Handle results consistently
  case result of
    Right output -> displayResults output
    Left err -> displayError err

-- Standard error display function
displayError :: AppError -> IO ()
displayError err = do
  putTextLn $ "ERROR: " <> errorMessage err
  putTextLn $ "Context: " <> errorContext err
  putTextLn $ "Details: " <> show (errorDetails err)
  -- Optionally display call stack in development
  when isDevelopment $
    putTextLn $ "Stack: " <> show (errorCallStack err)
  exitFailure
```

By following these simplified guidelines, we maintain a clean, consistent approach to error handling across our codebase while embracing the benefits of idiomatic Haskell error handling. The focus on a small set of core patterns makes the approach easy to learn and apply, while the consolidation into a single module simplifies imports and understanding.

### 2. Using Component Functions from Other Components

When components need to use functionality from other components, they can do so directly through the AppM monad:

```haskell
-- In Component2 using Component1 directly
processResource :: Resource -> AppM ProcessedResource
processResource resource = do
    -- Call Component1 functions directly - no lifting needed
    metadata <- getMetadata resource.id
    
    -- Process resource with metadata
    pure $ calculateProcessedResource resource metadata
```

This direct usage pattern:
1. Simplifies the mental model (no lifting required)
2. Reduces code complexity
3. Maintains all mathematical properties
4. Preserves architectural boundaries through module structure

#### 3. Testing Component Functions

```haskell
-- Test with AppM in ComponentSpec.hs
spec :: Spec
spec = describe "getData" $ do
    it "retrieves data for valid resource" $ do
        -- Create mock environment
        mockClient <- createMockHttpClient
        let config = defaultTestConfig
        let componentEnv = mkComponentEnv mockClient config
        
        -- Create AppEnv with test environment
        let appEnv = mkTestEnv componentEnv
        
        -- Run with AppM directly
        result <- runAppM appEnv $ getData "resource-123" someTime
        
        -- Verify results
        case result of
            Right dataPoints -> length dataPoints `shouldBe` 20
            Left err -> expectationFailure $ "Failed: " ++ show err
```

This approach:
1. Uses a minimal test environment with only required components
2. Directly tests the component API with AppM
3. Maintains the same error handling approach as production code
4. Simplifies test setup with helper functions from TestUtils.AppEnv

## Advanced Error Handling Patterns

For mission-critical systems, our foundational Either/ExceptT approach can be extended with advanced patterns that address specific requirements while maintaining our architectural principles.

### Error Accumulation Pattern

While our default approach fails fast on the first error, some scenarios (particularly input validation) benefit from accumulating multiple errors.

#### Using Validation for Error Accumulation

The `Validation` data type from the `either` package allows for accumulating errors:

```haskell
-- Import the Validation type
import Data.Either.Validation (Validation(..), validationToEither, eitherToValidation)

-- Create a type alias for our validation
type ValidatedResult e a = Validation [e] a

-- Validate a complete form with multiple fields
validateForm :: Form -> ValidatedResult AppError ValidForm
validateForm form =
  -- Applicative composition collects all errors
  ValidForm <$> validateName (formName form)
            <*> validateEmail (formEmail form)
            <*> validateAge (formAge form)
```

#### When to Use Error Accumulation

Error accumulation is best used when:

1. **User Interfaces**: Showing multiple validation errors at once improves UX
2. **Batch Processing**: When validating multiple records in a batch
3. **Complex Validations**: When a single entity has many validation rules

For internal processing or when subsequent steps depend on valid inputs, prefer the default fail-fast approach.

#### Implementation Example

```haskell
-- Domain/Validation.hs (PURE)
module Domain.Validation
  ( ValidatedResult
  , accumulateErrors
  , validateNonEmpty
  , validateEmail
  , validateAge
  , runValidation
  ) where

import Data.Either.Validation (Validation(..), validationToEither)
import Control.Error (AppError, mkAppError)
import qualified Data.Map as Map

-- Type alias for accumulating errors
type ValidatedResult a = Validation [AppError] a

-- Helper to validate a text field is non-empty
validateNonEmpty :: Text -> Text -> ValidatedResult Text
validateNonEmpty fieldName value =
  if Text.null value
  then Failure [mkAppError 
                 (fieldName <> " cannot be empty") 
                 "validateNonEmpty"
                 (Map.singleton fieldName value)]
  else Success value

-- Complete form validation
validateUser :: UserForm -> ValidatedResult User
validateUser form = User
  <$> validateNonEmpty "name" (formName form)
  <*> validateEmail (formEmail form)
  <*> validateAge (formAge form)

-- Convert to our standard Either type
runValidation :: ValidatedResult a -> Either AppError a
runValidation validation = 
  case validationToEither validation of
    Right value -> Right value
    Left errs -> Left $ combineErrors errs

-- Combine multiple errors into one with detailed context
combineErrors :: [AppError] -> AppError
combineErrors errs = 
  mkAppError 
    ("Multiple validation errors (" <> show (length errs) <> ")")
    "validateForm"
    (Map.fromList $ zip 
      (map (\i -> "error_" <> show i) [1..]) 
      (map (show . errorMessage) errs))
```

#### Integration with AppM

When using error accumulation with `AppM`:

```haskell
-- Component function using validation
processForm :: UserForm -> AppM User
processForm form = do
  -- Run validation and convert to Either
  case runValidation $ validateUser form of
    Right validUser -> 
      -- Proceed with valid user
      pure validUser
    Left err -> 
      -- Report accumulated errors
      throwError err
```

### Error Categorization Pattern

While our core `AppError` type has rich context, mission-critical systems benefit from structured error categories.

#### Enhanced AppError with Error Categories

```haskell
-- Control/Error.hs
-- Structured error categories for refined error handling
data ErrorCategory
  = ValidationError  -- Input validation failures
  | ResourceError    -- Resource access failures
  | SecurityError    -- Security violations
  | ExternalError    -- External system failures
  | SystemError      -- Internal system errors
  | BusinessError    -- Business rule violations
  deriving (Show, Eq, Generic)

-- Enhanced AppError with categorization
data AppError = AppError
  { errorMessage :: !Text              -- Error description
  , errorContext :: !Text              -- Operation context
  , errorCategory :: !ErrorCategory    -- Error category
  , errorDetails :: !(Map Text Text)   -- Debug info
  , errorCallStack :: !CallStack       -- Call stack
  } deriving stock (Show, Generic)

-- Enhanced error creation with category
mkAppError :: HasCallStack 
           => Text            -- ^ Error message
           -> Text            -- ^ Context
           -> ErrorCategory   -- ^ Error category
           -> Map Text Text   -- ^ Error details
           -> AppError
mkAppError msg ctx cat details = AppError
  { errorMessage = msg
  , errorContext = ctx
  , errorCategory = cat
  , errorDetails = details
  , errorCallStack = callStack
  }
```

#### Error Category Usage

With categorized errors, handlers can implement different strategies:

```haskell
-- Top-level handler with category-specific behavior
handleResult :: Either AppError Result -> IO ()
handleResult result = case result of
  Right value -> displayResult value
  Left err -> case errorCategory err of
    ValidationError -> 
      -- Show friendly message for validation errors
      displayValidationError err
    SecurityError -> 
      -- Log security errors with priority
      logSecurityEvent err >> displayError err
    ResourceError -> 
      -- Resource errors might allow retries
      handleResourceError err
    _ -> 
      -- Default handling for other errors
      displayError err
```

### Validation Composition Pattern

For complex validations across multiple types, we use a composition pattern:

```haskell
-- Domain/Transaction.hs

-- Validating nested structures
validateTransaction :: Transaction -> Either AppError ValidTransaction
validateTransaction tx = do
  -- Validate each component using monadic composition
  validUser <- validateUser (txUser tx)
  validAccount <- validateAccount (txAccount tx)
  validAmount <- validateAmount (txAmount tx)
  
  -- Business rule validations that span multiple fields
  when (validAmount > getAccountLimit validAccount) $
    Left $ mkAppError 
      "Transaction exceeds account limit" 
      "validateTransaction"
      ValidationError
      (Map.fromList 
        [ ("amount", show (txAmount tx))
        , ("limit", show (getAccountLimit validAccount))
        ])
  
  -- All validations passed
  Right $ ValidTransaction validUser validAccount validAmount
```

### Enhanced Error Context Pattern

For mission-critical systems, enhanced error context improves diagnostics:

```haskell
-- Control/Error.hs

-- Enhanced context for mission-critical systems
data ValidationContext = ValidationContext
  { vcSourceLocation :: !Text         -- Source file/line
  , vcTimestamp :: !UTCTime           -- When error occurred
  , vcRequestId :: !UUID              -- Request identifier
  , vcEntity :: !Text                 -- Entity being validated
  }

-- Creating validation context
withValidationContext :: Entity e => e -> ValidationContext
withValidationContext entity = ValidationContext
  { vcSourceLocation = __LOCATION__   -- Template Haskell
  , vcTimestamp = unsafePerformIO getCurrentTime
  , vcRequestId = getCurrentRequestId
  , vcEntity = entityName entity
  }

-- Using enhanced context
validateWithContext :: Entity e => e -> Either AppError ValidEntity
validateWithContext entity = do
  let context = withValidationContext entity
  if isValid entity
  then Right (ValidEntity entity)
  else Left $ mkAppError
    "Validation failed" 
    "validateWithContext"
    ValidationError
    (Map.fromList
      [ ("source", vcSourceLocation context)
      , ("timestamp", show (vcTimestamp context))
      , ("request_id", show (vcRequestId context))
      , ("entity", vcEntity context)
      ])
```

### API Contract Documentation Pattern

For mission-critical systems interfacing with external systems:

```haskell
-- Components/API/Validation.hs

-- Document validation as part of API contract
{-# ANN validateApiInput ("OpenAPI":
  { "validation": {
      "field": "email",
      "pattern": "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$",
      "description": "Must be a valid email format"
    }
  }
) #-}
validateApiInput :: ApiInput -> Either AppError ValidApiInput
validateApiInput input = do
  -- Implementation matches the documented constraints
  validEmail <- validateEmail (inputEmail input)
  -- Other validations...
  Right $ ValidApiInput { validEmail, ... }
```

## Resource Safety

Mission-critical systems must guarantee resource safety even in the presence of errors.

### Resource Management Pattern

While our basic error handling uses `ExceptT`, proper resource handling requires additional patterns:

```haskell
-- Control/Resource.hs

-- Resource safety with bracket pattern
withResource :: (MonadError AppError m, MonadIO m) 
             => Resource 
             -> (Resource -> m a) 
             -> m a
withResource resource action = do
  -- Catch exceptions during action and convert to AppError
  result <- liftIO $ try $ bracket
    (pure resource)
    (\r -> finalizeResource r)
    (\r -> runExceptT $ action r)
  
  -- Handle nested Either results
  case result of
    Left (e :: SomeException) -> 
      throwError $ mkAppError 
        "Resource operation failed" 
        "withResource" 
        ResourceError
        (Map.singleton "error" (show e))
    Right innerResult -> 
      -- Inner result is from action, propagate directly
      case innerResult of
        Left err -> throwError err
        Right value -> pure value
```

### ResourceT Integration

For complex resource management, integrate with `ResourceT`:

```haskell
-- Control/Resource.hs

-- Resource monad transformer integration
type ResourceAppM a = ResourceT AppM a

-- Run a resource-managed computation
runResourceAppM :: AppEnv -> ResourceAppM a -> IO (Either AppError a)
runResourceAppM env action = runAppM env $ runResourceT action

-- Using multiple resources safely
processWithResources :: File -> Database -> ResourceAppM Result
processWithResources file db = do
  -- Register resource cleanup
  bracket
    (liftIO $ openFile file)
    (\handle -> liftIO $ closeFile handle)
    (\handle -> do
      -- Use file handle
      contents <- liftIO $ readFile handle
      
      -- Register database transaction
      bracket
        (liftIO $ beginTransaction db)
        (\tx -> liftIO $ either rollback commit tx)
        (\tx -> do
          -- Process with both resources
          processData contents db
        )
    )
```

### Static Resource Verification

Using LiquidHaskell to verify resource safety:

```haskell
-- Control/Resource.hs

-- LiquidHaskell refinement for resource state
{-@ data Resource = Resource { isOpen :: Bool } @-}
data Resource = Resource { isOpen :: Bool }

-- Operations must maintain resource invariants
{-@ openResource :: r:Resource -> {s:Resource | isOpen s} @-}
openResource :: Resource -> Resource
openResource r = r { isOpen = True }

{-@ closeResource :: {r:Resource | isOpen r} -> {s:Resource | not (isOpen s)} @-}
closeResource :: Resource -> Resource
closeResource r = r { isOpen = False }

-- Function requiring open resource has precondition
{-@ useResource :: {r:Resource | isOpen r} -> a -> a @-}
useResource :: Resource -> a -> a
useResource r a = a
```

## Error Recovery Strategies

Mission-critical systems need robust recovery strategies beyond simple error reporting.

### Retry Pattern

```haskell
-- Control/Retry.hs

-- Configurable retry policy
data RetryPolicy = RetryPolicy
  { maxRetries :: Int
  , baseDelay :: Int  -- microseconds
  , backoffFactor :: Double
  }

-- Default retry policies
linearRetry :: Int -> Int -> RetryPolicy
linearRetry max delay = RetryPolicy max delay 1.0

exponentialBackoff :: Int -> Int -> RetryPolicy
exponentialBackoff max delay = RetryPolicy max delay 2.0

-- Retry with our AppM
retryWithPolicy :: RetryPolicy -> AppM a -> AppM a
retryWithPolicy policy action = retryLoop 0
  where
    retryLoop attempt = do
      result <- tryError action  -- Returns Either AppError a
      case result of
        Right value -> 
          -- Success
          return value
        Left err ->
          if isRetryable err && attempt < maxRetries policy
          then do
            -- Calculate delay based on policy
            let delay = round $ fromIntegral (baseDelay policy) * 
                        (backoffFactor policy ^ attempt)
            -- Delay and retry
            liftIO $ threadDelay delay
            retryLoop (attempt + 1)
          else
            -- Give up and propagate the error
            throwError err

-- Determine if an error is retryable
isRetryable :: AppError -> Bool
isRetryable err = case errorCategory err of
  ResourceError -> True
  ExternalError -> True
  -- Other categories are not automatically retried
  _ -> False
```

### Circuit Breaker Pattern

For external dependencies, implement circuit breakers:

```haskell
-- Control/CircuitBreaker.hs

-- Circuit breaker states
data CircuitState = Closed | HalfOpen | Open
  deriving (Show, Eq)

-- Circuit breaker configuration
data CircuitBreakerConfig = CircuitBreakerConfig
  { failureThreshold :: Int
  , resetTimeout :: Int  -- milliseconds
  , halfOpenSuccesses :: Int
  }

-- Circuit breaker state
data CircuitBreaker = CircuitBreaker
  { cbConfig :: CircuitBreakerConfig
  , cbState :: IORef CircuitState
  , failureCount :: IORef Int
  , lastFailure :: IORef (Maybe UTCTime)
  }

-- Create a new circuit breaker
newCircuitBreaker :: CircuitBreakerConfig -> IO CircuitBreaker
newCircuitBreaker config = do
  stateRef <- newIORef Closed
  countRef <- newIORef 0
  timeRef <- newIORef Nothing
  return $ CircuitBreaker config stateRef countRef timeRef

-- Execute operation with circuit breaker protection
withCircuitBreaker :: CircuitBreaker -> AppM a -> AppM a
withCircuitBreaker cb action = do
  -- Get current state
  state <- liftIO $ readIORef (cbState cb)
  case state of
    Open -> do
      -- Check if reset timeout has elapsed
      lastFail <- liftIO $ readIORef (lastFailure cb)
      now <- liftIO getCurrentTime
      case lastFail of
        Just time | diffUTCTime now time > 
                    fromIntegral (resetTimeout (cbConfig cb)) / 1000 -> do
          -- Transition to half-open
          liftIO $ writeIORef (cbState cb) HalfOpen
          executeWithBreaker cb action
        _ -> throwError $ mkAppError 
               "Circuit is open" 
               "withCircuitBreaker" 
               SystemError
               Map.empty
    _ -> executeWithBreaker cb action

-- Execute and update circuit state
executeWithBreaker :: CircuitBreaker -> AppM a -> AppM a
executeWithBreaker cb action = do
  result <- tryError action
  case result of
    Right value -> do
      -- Success - handle according to state
      state <- liftIO $ readIORef (cbState cb)
      when (state == HalfOpen) $ do
        -- Increment success counter
        successes <- liftIO $ atomicModifyIORef' (failureCount cb) $ 
                      \c -> (c - 1, c - 1)
        when (successes <= 0) $
          -- Reset to closed
          liftIO $ writeIORef (cbState cb) Closed
      return value
    
    Left err -> do
      -- Failure
      state <- liftIO $ readIORef (cbState cb)
      case state of
        Closed -> do
          -- Increment failure counter
          failures <- liftIO $ atomicModifyIORef' (failureCount cb) $ 
                        \c -> (c + 1, c + 1)
          when (failures >= failureThreshold (cbConfig cb)) $ do
            -- Trip to open
            liftIO $ writeIORef (cbState cb) Open
            now <- liftIO getCurrentTime
            liftIO $ writeIORef (lastFailure cb) (Just now)
        
        HalfOpen -> do
          -- Immediate trip back to open
          liftIO $ writeIORef (cbState cb) Open
          now <- liftIO getCurrentTime
          liftIO $ writeIORef (lastFailure cb) (Just now)
        
        _ -> return ()
      
      -- Propagate error
      throwError err
```

### Fallback Pattern

Provide fallbacks for critical operations:

```haskell
-- Control/Fallback.hs

-- Try multiple operations with fallbacks
withFallback :: AppM a -> AppM a -> AppM a
withFallback primary fallback = do
  result <- tryError primary
  case result of
    Right value -> return value
    Left err -> do
      -- Log fallback attempt
      liftIO $ logWarning $ 
        "Primary operation failed: " <> errorMessage err <>
        ", attempting fallback"
      -- Try fallback
      fallback

-- Try multiple fallbacks in sequence
withFallbacks :: [AppM a] -> AppM a
withFallbacks [] = throwError $ mkAppError 
                     "All fallbacks exhausted" 
                     "withFallbacks" 
                     SystemError
                     Map.empty
withFallbacks (x:xs) = withFallback x (withFallbacks xs)
```

## Formal Verification of Error Handling

For mission-critical applications, error handling should be formally verified.

### LiquidHaskell Refinements

```haskell
-- Domain/Verified.hs

-- Verify that validation never returns invalid states
{-@ measure isValid @-}
{-@ type ValidEntity = {v:Entity | isValid v} @-}

-- Guarantee that validation returns only valid entities
{-@ validateEntity :: e:Entity -> Either AppError {v:Entity | isValid v} @-}
validateEntity :: Entity -> Either AppError Entity
validateEntity e =
  if checkValid e
  then Right e
  else Left $ mkAppError 
          "Invalid entity" 
          "validateEntity" 
          ValidationError
          (Map.singleton "entity" (show e))

-- Verify that smart constructors maintain invariants
{-@ mkValue :: i:Int -> Either AppError {v:Value | getValue v >= 0} @-}
mkValue :: Int -> Either AppError Value
mkValue i =
  if i >= 0
  then Right (Value i)
  else Left $ mkAppError
          "Value must be non-negative" 
          "mkValue" 
          ValidationError
          (Map.singleton "value" (show i))
```

### Property-Based Testing

Test error handling with property-based tests:

```haskell
-- Test/Domain/EntitySpec.hs

-- Property: validation catches all invalid cases
prop_validation_catches_invalid :: Property
prop_validation_catches_invalid = property $ \entity ->
  not (isValid entity) ==> 
    case validateEntity entity of
      Left _ -> True
      Right _ -> False

-- Property: validation preserves valid cases
prop_validation_preserves_valid :: Property
prop_validation_preserves_valid = property $ \entity ->
  isValid entity ==> 
    case validateEntity entity of
      Left _ -> False
      Right v -> v == entity

-- Property: error message contains relevant context
prop_error_includes_context :: Property
prop_error_includes_context = property $ \(Invalid entity) ->
  case validateEntity entity of
    Left err -> 
      T.isInfixOf (entityIdentifier entity) (errorMessage err) &&
      "validateEntity" == errorContext err
    Right _ -> False
```

### Formal State Machine Testing

Verify error handling in state transitions:

```haskell
-- Test/Domain/StateMachineSpec.hs

-- Define a state machine model
data Model = Model
  { inputs :: [Input]
  , state :: SystemState
  , errors :: [AppError]
  }

-- Initialize model
initialModel :: Model
initialModel = Model [] Initial []

-- Define commands
data Command 
  = ProcessValidInput Input
  | ProcessInvalidInput Input
  | ResetSystem
  deriving (Show)

-- Execute commands
runCommand :: Command -> Model -> (Model, Either AppError Result)
runCommand cmd model = case cmd of
  ProcessValidInput input -> 
    let newModel = model { inputs = input : inputs model }
        result = Right $ Result "Success"
    in (newModel, result)
  
  ProcessInvalidInput input ->
    let err = mkAppError "Invalid input" "process" ValidationError Map.empty
        newModel = model { inputs = input : inputs model
                         , errors = err : errors model }
    in (newModel, Left err)
  
  ResetSystem ->
    (model { state = Initial }, Right $ Result "Reset")

-- Property: system maintains consistent state with errors
prop_system_state_consistent :: Property
prop_system_state_consistent = property $ \cmds ->
  let (finalModel, _) = foldl 
        (\(m, _) cmd -> runCommand cmd m) 
        (initialModel, Right $ Result "Start")
        cmds
  in finalModel.inputs == reverse (map getInput $ filter isInputCommand cmds)
  where
    isInputCommand (ProcessValidInput _) = True
    isInputCommand (ProcessInvalidInput _) = True
    isInputCommand _ = False
    
    getInput (ProcessValidInput i) = i
    getInput (ProcessInvalidInput i) = i
    getInput _ = error "Not input command"
```

## Error Observability

Mission-critical systems require comprehensive error observability.

### Structured Logging

```haskell
-- Control/Logging.hs

-- Log error with structured context
logError :: AppError -> IO ()
logError err = do
  let structuredError = object
        [ "message" .= errorMessage err
        , "context" .= errorContext err
        , "category" .= show (errorCategory err)
        , "details" .= errorDetails err
        , "timestamp" .= formatISO8601 <$> getCurrentTime
        , "location" .= formatCallStack (errorCallStack err)
        ]
  logStructured "ERROR" structuredError

-- Log entire error chain
logErrorChain :: AppError -> IO ()
logErrorChain rootErr = do
  -- Log the root error
  logError rootErr
  
  -- Check for cause chain in details
  case Map.lookup "caused_by" (errorDetails rootErr) of
    Just causeText ->
      -- Parse and log the cause if possible
      case readMaybe causeText of
        Just cause -> logErrorChain cause
        Nothing -> return ()
    Nothing -> return ()
```

### Metrics and Alerting

```haskell
-- Control/Metrics.hs

-- Record error metrics
recordErrorMetric :: AppError -> IO ()
recordErrorMetric err = do
  -- Increment error count by category
  incrementCounter 
    ("app.errors.count." <> show (errorCategory err))
  
  -- Record error timing
  case Map.lookup "duration_ms" (errorDetails err) of
    Just durationText -> 
      case readMaybe durationText of
        Just duration -> 
          recordHistogram 
            ("app.errors.duration." <> show (errorCategory err))
            duration
        Nothing -> return ()
    Nothing -> return ()

-- Failure rate circuit breaker integration
monitorFailureRate :: Text -> Double -> IO (IO () -> IO (Either AppError a) -> IO (Either AppError a))
monitorFailureRate operationName threshold = do
  -- Create counters
  successCounter <- createCounter (operationName <> ".success")
  failureCounter <- createCounter (operationName <> ".failure")
  
  -- Create monitoring function
  return $ \recordOperation action -> do
    result <- action
    case result of
      Right _ -> do
        incrementCounter' successCounter 1
        recordOperation
        return result
      Left err -> do
        incrementCounter' failureCounter 1
        
        -- Calculate failure rate
        success <- getCounter successCounter
        failure <- getCounter failureCounter
        let total = success + failure
            rate = if total > 0
                  then fromIntegral failure / fromIntegral total
                  else 0
        
        -- Check threshold
        when (total > 10 && rate > threshold) $
          triggerAlert 
            ("High failure rate for " <> operationName)
            ("Failure rate: " <> show (rate * 100) <> "%")
        
        return result
```

### Correlation Tracking

```haskell
-- Control/Correlation.hs

-- Correlation context for request tracing
data CorrelationContext = CorrelationContext
  { requestId :: !UUID
  , sessionId :: !Text
  , traceId :: !Text
  , spanId :: !Text
  }

-- Thread-local correlation context
correlationContextVar :: TVar (Maybe CorrelationContext)
correlationContextVar = unsafePerformIO $ newTVarIO Nothing

-- Get current correlation context
getCorrelationContext :: IO (Maybe CorrelationContext)
getCorrelationContext = readTVarIO correlationContextVar

-- Set correlation context for current thread
withCorrelationContext :: CorrelationContext -> IO a -> IO a
withCorrelationContext ctx action = do
  oldCtx <- atomically $ do
    old <- readTVar correlationContextVar
    writeTVar correlationContextVar (Just ctx)
    return old
  
  result <- action `finally` atomically (writeTVar correlationContextVar oldCtx)
  return result

-- Enhanced error creation with correlation
mkCorrelatedError :: Text -> Text -> ErrorCategory -> Map Text Text -> IO AppError
mkCorrelatedError msg ctx cat details = do
  -- Get correlation context
  corCtx <- getCorrelationContext
  
  -- Add correlation IDs to error details
  let enhancedDetails = case corCtx of
        Just cc -> Map.union details $ Map.fromList
                    [ ("request_id", show $ requestId cc)
                    , ("trace_id", traceId cc)
                    , ("span_id", spanId cc)
                    ]
        Nothing -> details
  
  -- Create error with enhanced context
  return $ mkAppError msg ctx cat enhancedDetails
```

### Telemetry

```haskell
-- Control/Telemetry.hs

-- Send error telemetry
reportErrorTelemetry :: AppError -> IO ()
reportErrorTelemetry err = do
  -- Get correlation context
  corCtx <- getCorrelationContext
  
  -- Format telemetry payload
  let payload = object
        [ "error" .= object
            [ "message" .= errorMessage err
            , "context" .= errorContext err
            , "category" .= show (errorCategory err)
            , "details" .= errorDetails err
            ]
        , "correlation" .= maybe (object []) correlationToJson corCtx
        , "system" .= object
            [ "timestamp" .= formatISO8601 <$> getCurrentTime
            , "service" .= serviceName
            , "version" .= serviceVersion
            , "environment" .= environment
            ]
        ]
  
  -- Send telemetry asynchronously
  void $ async $ sendTelemetry "error" payload

-- Convert correlation context to JSON
correlationToJson :: CorrelationContext -> Value
correlationToJson ctx = object
  [ "requestId" .= show (requestId ctx)
  , "sessionId" .= sessionId ctx
  , "traceId" .= traceId ctx
  , "spanId" .= spanId ctx
  ]
```
