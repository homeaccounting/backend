# Standardized Validation Pattern Guide

## Overview

This guide describes our standardized validation pattern for domain types with LiquidHaskell refinements. This approach:

1. Aligns runtime validation with compile-time refinements
2. Improves LiquidHaskell's ability to verify code correctness
3. Separates validation logic from error message creation
4. Ensures consistent validation across the codebase
5. Makes validation logic explicit and easier to maintain

## The Pattern

Our standard validation pattern consists of:

1. **Validation Error Enumeration**: Define possible validation errors as an enum
2. **Centralized Validation Function**: Returns Maybe ErrorEnum
3. **Error Message Creation Function**: Creates detailed error messages
4. **Smart Constructor with Case Expression**: Clear flow from validation to result

### Validation Error Enumeration

```haskell
data TypeValidationError =
  FirstInvariantViolation |    -- ^ First invariant not satisfied
  SecondInvariantViolation |   -- ^ Second invariant not satisfied
  ThirdInvariantViolation      -- ^ Third invariant not satisfied
```

### Centralized Validation Function

```haskell
validateType :: Input -> Maybe TypeValidationError
validateType input =
  if not (firstInvariant input) then Just FirstInvariantViolation
  else if not (secondInvariant input) then Just SecondInvariantViolation
  else if not (thirdInvariant input) then Just ThirdInvariantViolation
  else Nothing
```

### Error Message Creation Function

```haskell
createTypeError :: Input -> TypeValidationError -> AppError
createTypeError input err =
  let 
    (msg, details) = case err of
      FirstInvariantViolation -> 
        ("First invariant violated", Map.singleton "input" (show input))
      SecondInvariantViolation -> 
        ("Second invariant violated", Map.singleton "input" (show input))
      ThirdInvariantViolation -> 
        ("Third invariant violated", Map.singleton "input" (show input))
  in
    mkAppError msg "mkType" details
```

### Smart Constructor with Case Expression

```haskell
mkType :: Input -> Either AppError Type
mkType input = 
  case validateType input of
    Just err -> Left $ createTypeError input err
    Nothing -> Right $ Type input
```

## Why This Pattern Works Better with LiquidHaskell

1. **Flow Transparency**: LiquidHaskell can more easily track the logic flow through explicit case expressions
2. **Validation Mirroring**: Validation checks mirror refinement structure exactly
3. **Error Separation**: Separating validation from error creation simplifies verification
4. **Case Expression Clarity**: Case expressions make branches explicit and easier to analyze
5. **Consistent Ordering**: Validation checks in the same order as refinement predicates

## Example Implementation from our Codebase

```haskell
-- | Enumeration of possible validation errors
data Decimal8ValidationError = 
  Decimal8Negative |     -- ^ Value is negative, violating non-negative constraint
  Decimal8WrongPrecision -- ^ Value doesn't have exactly 8 decimal places

-- | Centralized validation function
validateDecimal8 :: Decimal -> Maybe Decimal8ValidationError
validateDecimal8 d =
  if not (isNonNegative d) then Just Decimal8Negative
  else if not (hasDecimals 8 d) then Just Decimal8WrongPrecision
  else Nothing

-- | Error message creation function
createDecimal8Error :: Decimal -> Decimal8ValidationError -> AppError
createDecimal8Error d err =
  let 
    (msg, ctx) = case err of
      Decimal8Negative -> 
        ("Invalid decimal value: Must be non-negative.", "mkDecimal8")
      Decimal8WrongPrecision -> 
        ("Invalid decimal precision: Incorrect number of decimal places.", "mkDecimal8")
  in
    mkAppError msg ctx (Map.singleton "value" (mkNonEmptyText (T.pack (show d))))

-- | Smart constructor with case expression
mkDecimal8 :: Decimal -> Either AppError Decimal8
mkDecimal8 d = 
  case validateDecimal8 d of
    Just err -> Left $ createDecimal8Error d err
    Nothing -> Right $ Decimal8 d
```

## Advanced Validation Patterns for Mission-Critical Applications

For mission-critical applications, we extend our base pattern with the following enhancements to improve robustness, maintainability, and diagnostic capabilities.

### Error Accumulation Pattern

The base pattern returns the first validation error encountered. For mission-critical systems, we often need to collect all validation errors to provide comprehensive feedback.

```haskell
-- | Error accumulation validation using Validation from either package
import qualified Data.Either.Validation as V

-- | Validation function returning accumulated errors
validateTypeAccum :: Input -> V.Validation [TypeValidationError] Type
validateTypeAccum input =
  let
    checks = [
      V.fromEither $ if firstInvariant input 
                     then Right () 
                     else Left FirstInvariantViolation,
      V.fromEither $ if secondInvariant input 
                     then Right () 
                     else Left SecondInvariantViolation,
      V.fromEither $ if thirdInvariant input 
                     then Right () 
                     else Left ThirdInvariantViolation
    ]
  in
    case partitionEithers $ map V.toEither checks of
      ([], _) -> V.Success (Type input)
      (errs, _) -> V.Failure errs

-- | Smart constructor with error accumulation
mkTypeAccum :: Input -> Either AppError Type
mkTypeAccum input =
  case validateTypeAccum input of
    V.Failure errs -> Left $ createTypeErrors input errs
    V.Success t -> Right t

-- | Create error message for multiple errors
createTypeErrors :: Input -> [TypeValidationError] -> AppError
createTypeErrors input errs =
  let
    combinedMsg = "Multiple validation errors: " <> 
                  T.intercalate ", " (map errorToMsg errs)
    details = Map.singleton "input" (show input)
               `Map.union` Map.singleton "errors" (show errs)
  in
    mkAppError combinedMsg "mkTypeAccum" details
```

When to use error accumulation:
- For user-facing input validation where all errors should be reported
- For complex data structures with multiple validation rules
- When diagnostics need to be comprehensive rather than fail-fast

### Validation Composition Pattern

For complex types composed of other refined types, we need a way to compose validations:

```haskell
-- | Composite type with multiple validated components
data CompositeType = CompositeType {
  field1 :: Type1,
  field2 :: Type2,
  -- ^ These fields have their own refinements and validations
  relation :: Relation
  -- ^ This represents invariants between fields
}

-- | Error types that handle component-level and relation-level errors
data CompositeValidationError =
  Field1Error Type1ValidationError |
  Field2Error Type2ValidationError |
  RelationError RelationValidationError

-- | Composed validation function 
validateComposite :: Input1 -> Input2 -> Maybe CompositeValidationError
validateComposite i1 i2 = 
  -- First validate individual fields
  case validateType1 i1 of
    Just err -> Just (Field1Error err)
    Nothing -> case validateType2 i2 of
      Just err -> Just (Field2Error err)
      Nothing -> 
        -- Then validate relationships between fields
        case checkRelation i1 i2 of
          Just err -> Just (RelationError err)
          Nothing -> Nothing

-- | Applicative composition for collecting all errors
validateCompositeAccum :: Input1 -> Input2 -> V.Validation [CompositeValidationError] CompositeType
validateCompositeAccum i1 i2 =
  CompositeType
    <$> validateType1Accum i1 `mapValidationError` Field1Error
    <*> validateType2Accum i2 `mapValidationError` Field2Error
    <*> validateRelation i1 i2 `mapValidationError` RelationError

-- Helper function to map error types
mapValidationError :: V.Validation [e1] a -> (e1 -> e2) -> V.Validation [e2] a
```

Best practices for validation composition:
- Validate components individually first
- Validate relationships between components after individual validation
- Maintain clear error type hierarchies that preserve component structure
- Use applicative validation for error accumulation across components

### Enhanced Error Context Pattern

Mission-critical systems need rich, contextualized error information for diagnosis and auditing:

```haskell
-- | Enhanced error context
data ValidationContext = ValidationContext {
  sourceLocation :: CallStack,
  validationTime :: UTCTime,
  validationID   :: UUID,
  inputContext   :: Map Text Text,
  systemContext  :: Map Text Text
}

-- | Create validation context
mkValidationContext :: Map Text Text -> IO ValidationContext
mkValidationContext inputCtx = do
  now <- getCurrentTime
  uuid <- randomUUID
  return $ ValidationContext callStack now uuid inputCtx systemEnv

-- | Enhanced error creation
createEnhancedError :: ValidationContext -> Input -> TypeValidationError -> AppError
createEnhancedError ctx input err =
  let
    (msg, details) = case err of
      FirstInvariantViolation -> 
        ("First invariant violated", baseDetails)
      -- more cases...
    
    baseDetails = Map.fromList [
        ("input", show input),
        ("validation_id", show $ validationID ctx),
        ("timestamp", formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" $ validationTime ctx)
      ] 
      `Map.union` inputContext ctx
      `Map.union` systemContext ctx
  in
    mkAppError msg (prettyCallStack $ sourceLocation ctx) details

-- | Smart constructor with enhanced context
mkTypeWithContext :: Input -> IO (Either AppError Type)
mkTypeWithContext input = do
  ctx <- mkValidationContext (Map.singleton "input_type" "MyType")
  return $ case validateType input of
    Just err -> Left $ createEnhancedError ctx input err
    Nothing -> Right $ Type input
```

When to use enhanced context:
- For all validations in mission-critical systems
- When traceability requirements are high
- For validations that may need forensic analysis later
- When complex input processing spans multiple system components

### API Contract Documentation Pattern

Connect validation to formal API documentation to ensure consistency between validation rules and API contracts:

```haskell
-- | OpenAPI schema generator that uses validation rules
generateTypeSchema :: OpenAPI.Schema
generateTypeSchema = 
  OpenAPI.object
    & OpenAPI.title ?~ "Type"
    & OpenAPI.properties ?~
        OpenAPI.fromList [
          ("field1", OpenAPI.string
            & OpenAPI.description ?~ "First field - must satisfy first invariant"
            & OpenAPI.pattern ?~ firstInvariantPattern),
          -- more fields...
        ]
    & OpenAPI.required .~ ["field1", "field2"]

-- | Document validation errors in API schema
generateTypeErrorSchema :: OpenAPI.Schema
generateTypeErrorSchema =
  OpenAPI.object
    & OpenAPI.title ?~ "TypeValidationError"
    & OpenAPI.oneOf ?~ 
        [ firstInvariantErrorSchema
        , secondInvariantErrorSchema
        -- more error schemas...
        ]

-- | Generate OpenAPI validation from Haskell validation function
validateTypeToOpenAPI :: Text -> OpenAPI.Schema
validateTypeToOpenAPI functionName =
  let
    checks = getValidationChecks validateType
  in
    OpenAPI.object
      & OpenAPI.title ?~ functionName
      & OpenAPI.properties ?~ 
          OpenAPI.fromList (map checkToProperty checks)
```

Best practices for validation API documentation:
- Generate API schemas directly from validation code when possible
- Document all validation errors in API documentation
- Ensure validation rules in code match API contract specifications
- Version validation rules alongside API versions
- Link refinement types to API schema constraints

### Testing Strategy for Validation

Thorough testing of validation logic is essential for mission-critical systems:

```haskell
-- | Property: validation rejects invalid inputs
prop_validateRejectsInvalid :: Property
prop_validateRejectsInvalid = property $ do
  -- Generate invalid inputs for each invariant
  input <- forAll genInvalidInput
  -- Validation should reject
  validateType input /== Nothing

-- | Property: validation accepts valid inputs
prop_validateAcceptsValid :: Property
prop_validateAcceptsValid = property $ do
  -- Generate valid inputs satisfying all invariants
  input <- forAll genValidInput
  -- Validation should accept
  validateType input === Nothing
  
-- | Property: validation aligns with refinements
prop_validationMatchesRefinement :: Property
prop_validationMatchesRefinement = property $ do
  input <- forAll genInput
  -- Validation should accept exactly when refinements are satisfied
  let validationAccepts = isNothing (validateType input)
  let refinementsSatisfied = 
        firstInvariant input && 
        secondInvariant input && 
        thirdInvariant input
  validationAccepts === refinementsSatisfied

-- | Property: LiquidHaskell refinement implies validation success
prop_refinementImpliesValidation :: Type -> Property
prop_refinementImpliesValidation t =
  -- If t exists, it must have passed LiquidHaskell refinements
  -- So extracting and revalidating should succeed
  validateType (unwrap t) === Nothing
```

Test coverage requirements for mission-critical validation:
- 100% branch coverage of validation logic
- Property tests for each invariant
- Generators for both valid and invalid inputs
- Tests for edge cases and boundary conditions
- Tests for validation-refinement alignment
- Tests for error message correctness and clarity

### Performance Considerations for Validation

For performance-critical code paths, consider these validation optimizations:

```haskell
-- | Lazy validation for large data structures
validateLargeStructure :: LargeInput -> Maybe ValidationError
validateLargeStructure input =
  let
    -- Check lightweight invariants first
    structuralCheck = checkStructure input
    -- Only perform expensive checks if needed
    contentCheck = if isNothing structuralCheck
                   then checkContent input
                   else Nothing
  in
    structuralCheck <|> contentCheck

-- | Cached validation for frequently validated values
cachedValidate :: (Hashable a, Eq a) => a -> StateT (HashMap a (Maybe ValidationError)) IO (Maybe ValidationError)
cachedValidate input = do
  cache <- get
  case HM.lookup input cache of
    Just result -> return result
    Nothing -> do
      let result = validateType input
      modify (HM.insert input result)
      return result

-- | Parallel validation for independent checks
validateParallel :: ComplexInput -> IO (Maybe ValidationError)
validateParallel input = do
  let checks = [check1 input, check2 input, check3 input]
  results <- mapConcurrently id checks
  return $ listToMaybe $ catMaybes results
```

Performance optimization guidelines:
- Profile validation performance in your application
- Optimize the most frequently used validators
- Consider lazy validation for large data structures
- Use caching for repetitive validation of the same values
- Perform independent validations in parallel for complex types
- Structure validations to fail fast on common error cases
- Consider the tradeoff between validation thoroughness and performance

## Why This Documentation Matters

1. **Compile-Time vs. Runtime Verification**: In our system, we use LiquidHaskell to verify properties at compile-time, but we need runtime validation for error messages.

2. **Consistency Across Codebase**: By documenting and following this pattern, we ensure consistent validation approaches across the entire codebase.

3. **LiquidHaskell Verification Success**: This pattern has proven successful in helping LiquidHaskell verify our code without needing to resort to `assume` directives.

4. **Alignment with Refinement-Driven Development**: This validation pattern works hand-in-hand with our RDD approach.

5. **Mission-Critical Quality**: For systems where correctness is non-negotiable, comprehensive validation with proper error reporting is essential.

6. **Diagnostic Capability**: Structured, consistent validation provides the foundation for system-wide diagnostics and monitoring.

## When Implementing New Types

When implementing a new type with refinements:

1. Follow the RDD workflow (see `liquidhaskell-guide.md`)
2. Define validation error enumeration with descriptive constructors
3. Implement centralized validation using this pattern
4. Keep validation logic aligned with refinements
5. Use case expressions for smart constructors
6. Document compile-time vs. runtime verification
7. Decide if you need error accumulation based on use case
8. Implement appropriate testing strategy
9. Document validation rules in API contracts
10. Consider performance implications for your specific use case

## Common Pitfalls to Avoid

1. **Mixing Validation and Error Creation**: Keep these separate for better LiquidHaskell verification
2. **Direct If-Then-Else in Smart Constructors**: Use case expressions on the result of validation function instead
3. **Inconsistent Order of Validation Checks**: Keep the same order as refinements
4. **Returning Error Messages Directly**: Use error enums for classification and separate error message creation
5. **Reporting Only First Error**: In complex validation scenarios, consider collecting all errors
6. **Duplicating Validation Logic**: Reuse validation across related types
7. **Insufficient Testing**: Ensure all validation paths are thoroughly tested
8. **Missing API Documentation**: Document validation rules in API contracts
9. **Validation Performance Issues**: Consider performance in frequently used validators
10. **Poor Error Messages**: Ensure error messages provide actionable information

By following this standardized validation pattern, we improve code quality, verification success, and maintainability across our codebase. These patterns are essential for building mission-critical Haskell applications that require high assurance of correctness. 