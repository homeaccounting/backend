# LiquidHaskell and Refinement-Driven Development Guide

## Introduction

This guide provides a practical introduction to LiquidHaskell (LH) and Refinement-Driven Development (RDD) for our project. It's designed to help developers new to both Haskell and LiquidHaskell understand how to implement type-level guarantees through refinement types.

## What is LiquidHaskell?

LiquidHaskell is a program verifier for Haskell that adds **refinement types** to standard Haskell. A refinement type is a standard type augmented with a logical predicate that constrains the set of values described by the type.

For example, a standard `Int` in Haskell can hold any integer. With LiquidHaskell, we can define:
```haskell
{-@ type PositiveInt = {v:Int | v > 0} @-}
```

This creates a refinement type `PositiveInt` that only allows positive integers. LiquidHaskell will verify at compile-time that any value claimed to be a `PositiveInt` truly is positive.

## Why Use LiquidHaskell?

1. **Catch Errors at Compile-Time**: Find logical errors before your code runs
2. **Express Complex Invariants**: Capture business rules directly in the type system
3. **Self-Documenting Code**: Types document what values are valid
4. **Reduced Testing Burden**: Fewer runtime tests needed for properties verified at compile-time
5. **Formal Verification**: Mathematical guarantees of correctness

## Refinement-Driven Development (RDD)

Refinement-Driven Development is our approach to implementing domain types with LiquidHaskell. It prioritizes defining refinement types before implementation.

### RDD Workflow

1. **Define Refinement Types**: Start by defining your type with all desired invariants
2. **Add Refined Function Signatures**: Specify precise input/output requirements
3. **Implement Measures**: Create the predicate functions needed by refinements
4. **Implement Validation Logic**: Write validation that aligns with refinements
5. **Verify with LiquidHaskell**: Compile to verify all refinements are satisfied
6. **Optimize Runtime Code**: Refine runtime validation once verification succeeds

### When is RDD Complete?

The RDD portion of work for a type is complete when:

1. **All Domain Invariants Are Captured**: Every business rule is expressed as a refinement
2. **Compile-Time Verification Works**: LiquidHaskell verifies without `assume` directives
3. **No False Positives/Negatives**: Refinements precisely define valid values
4. **Smart Constructor Alignment**: Runtime validation matches the refinements
5. **Documentation Completeness**: All refinements are clearly documented

## Setting Up LiquidHaskell

### Project Configuration

1. **Add to package.yaml or .cabal file**:
   ```yaml
   dependencies:
     - liquidhaskell
   ```

2. **Enable in module**:
   ```haskell
   {-# LANGUAGE Safe #-}
   {-# OPTIONS_GHC -fplugin=LiquidHaskell #-}
   ```

### Basic Syntax

```haskell
-- Define a measure (property of a data type)
{-@ measure isValid :: Text -> Bool @-}
isValid :: Text -> Bool
isValid t = -- implementation

-- Refine a type
{-@ data MyType = MyType {value :: {v:Text | isValid v}} @-}
newtype MyType = MyType { value :: Text }

-- Refine a function
{-@ myFunction :: {v:Text | isValid v} -> MyType @-}
myFunction :: Text -> MyType
```

## LiquidHaskell 0.9.10+ Important Changes

LiquidHaskell has evolved significantly in versions 0.9.10 and above. Understanding these changes is crucial for working effectively with the tool.

### Measures vs. Reflections

In our codebase with LiquidHaskell 0.9.10.1.2, we've established a successful pattern for using `measure` and `reflect`:

1. **Measure**:
   - Use for boolean predicates (functions returning Bool)
   - Ideal for property checks and validation functions
   - Works regardless of pattern matching in our LiquidHaskell version

   ```haskell
   {-@ measure isNonNegative :: Decimal -> Bool @-}
   isNonNegative :: Decimal -> Bool
   isNonNegative d = d >= 0
   
   {-@ measure hasDecimals :: Int -> Decimal -> Bool @-}
   hasDecimals :: Int -> Decimal -> Bool
   hasDecimals n d = fromIntegral (decimalPlaces d) == n
   ```

2. **Reflect**:
   - Use for value-computing functions
   - Functions that transform data or compute quantities
   - Especially useful for functions referenced in refinements that don't just return boolean values

   ```haskell
   {-@ reflect textLength @-}
   textLength :: Text -> Int
   textLength = Text.length
   ```

This consistent pattern has proven effective in our project and avoids many potential issues with the LiquidHaskell sort system.

### Understanding the Sort System

In LiquidHaskell, a "sort" refers to a classification of types in the logical system, not to sorting a list. The sort system distinguishes between:

1. **Logical sorts used by the SMT solver**:
   - `bool` - Logical boolean expressions
   - `int` - Integer numbers in logic
   - `real` - Real numbers in logic

2. **Haskell runtime types**:
   - `Bool` - Runtime boolean values
   - `Int` - Runtime integer values
   - etc.

When LiquidHaskell reports a "sort error," it means there's a mismatch between these logical categories. This is particularly common with boolean values in refinements.

### Boolean Refinements and Sort Errors

One of the most common issues in LiquidHaskell 0.9.10+ is with boolean refinements:

```
Sort Error in Refinement: {v:Bool | v == isNonEmpty t}
Expressions isNonEmpty t should have bool sort, but has GHC.Types.Bool
```

This occurs because LiquidHaskell's logical system (`bool` sort) and Haskell's runtime type (`Bool`) are kept more strictly separated in newer versions.

### When to Use Predicates vs. Inline Expressions

If you encounter sort errors, try these approaches:

#### When to Use Predicates Directly:

1. **In Function Preconditions and Postconditions**:
   ```haskell
   {-@ someFunction :: t:Text -> {v:Bool | v <=> isNonEmpty t} @-}
   ```

2. **In Haskell Code (Runtime Logic)**:
   ```haskell
   validate t = if isNonEmpty t then Just (NonEmptyText t) else Nothing
   ```

3. **When Creating Custom Refinement Types**:
   ```haskell
   {-@ type NEText = {t:Text | isNonEmpty t} @-}
   ```

#### When to Inline Expressions:

If you encounter sort errors when using predicates in refinements, try inlining the implementation:

```haskell
-- If this causes sort errors:
{-@ data NonEmptyText = NonEmptyText { 
    unNonEmpty :: {t:Text | isNonEmpty t} 
  } @-}

-- Try inlining the implementation instead:
{-@ data NonEmptyText = NonEmptyText { 
    unNonEmpty :: {t:Text | not (Text.null t)} 
  } @-}
```

### Best Practice Pattern for Our Codebase

The pattern that works well with our LiquidHaskell 0.9.10.1.2 version:

```haskell
-- Define boolean predicates with measure
{-@ measure isNonEmpty :: Text -> Bool @-}
isNonEmpty :: Text -> Bool
isNonEmpty t = not (Text.null t)

-- Define value computations with reflect
{-@ reflect textLength @-}
textLength :: Text -> Int
textLength = Text.length

-- Use inlined implementation in data type refinements if needed to avoid sort errors
{-@ data NonEmptyText = NonEmptyText { 
    unNonEmpty :: {t:Text | not (Text.null t)} 
  } @-}

-- Use predicate in runtime code (for clarity)
mkNonEmptyText t = 
  if isNonEmpty t 
  then Just (NonEmptyText t) 
  else Nothing
```

This approach gives you the best of both worlds: clear, reusable predicates for your Haskell code, and reliable, compatible refinements for LiquidHaskell verification.

## Implementing a Type with LiquidHaskell

### Phase 1: Initial Setup

Start with basic LiquidHaskell configuration and simple refinements:

```haskell
{-# LANGUAGE Safe #-}
{-# OPTIONS_GHC -fplugin=LiquidHaskell #-}

-- Define a measure for boolean property
{-@ measure isNonEmpty :: Text -> Bool @-}
isNonEmpty :: Text -> Bool
isNonEmpty t = not (Text.null t)

-- Define a reflect function for value computation
{-@ reflect textLength @-}
textLength :: Text -> Int
textLength = Text.length

-- Simple refinement: non-empty text
{-@ data ProductId = ProductId {unProductId :: {t:Text | textLength t > 0}} @-}
newtype ProductId = ProductId { unProductId :: Text }
```

### Phase 2: Add Measures and Predicates

Define all the measures and reflected functions needed for your invariants:

```haskell
-- Use measure for boolean predicates
{-@ measure hasHyphen :: Text -> Bool @-}
hasHyphen :: Text -> Bool
hasHyphen t = "-" `Text.isInfixOf` t

{-@ measure isAllUppercase :: Text -> Bool @-}
isAllUppercase :: Text -> Bool
isAllUppercase t = Text.all isUpper t

-- Use pattern matching with measure too
{-@ measure hasPrefix :: Text -> Text -> Bool @-}
hasPrefix :: Text -> Text -> Bool
hasPrefix "" _ = True
hasPrefix _ "" = False
hasPrefix (x:xs) (y:ys) = x == y && hasPrefix xs ys
```

### Phase 3: Enhance Type Refinements

Add all invariants to your type definition, using direct expressions when needed:

```haskell
{-@ data ProductId = ProductId {
    unProductId :: {t:Text | textLength t >= 5 && 
                             Text.isInfixOf "-" t && 
                             Text.all isUpper t}
    } @-}
```

Note how we inlined `Text.isInfixOf "-" t` instead of using `hasHyphen t` to avoid potential sort errors.

### Phase 4: Implement Smart Constructor

Create a smart constructor with validation matching your refinements:

```haskell
{-@ mkProductId :: t:Text -> Either Error ProductId @-}
mkProductId :: Text -> Either Error ProductId
mkProductId t =
    -- Validate in the same order as refinements
    if textLength t < 5
        then Left $ mkLengthError t
    else if not (hasHyphen t)
        then Left $ mkFormatError t
    else if not (isAllUppercase t)
        then Left $ mkCaseError t
    else
        Right $ ProductId t
```

### Phase 5: Remove Assumptions

Initially, you might need to use `assume` to get things working:

```haskell
{-@ assume mkProductId :: t:Text -> Either Error {v:ProductId | unProductId v == t} @-}
```

Later, remove the `assume` by structuring validation to match refinements:

```haskell
-- Step-by-step validation helps LiquidHaskell understand the flow
let validFormat = Text.isInfixOf "-" t  -- Use direct expression in validation too
    validCase = Text.all isUpper t
in if not validFormat
   then Left $ mkFormatError t
   else if not validCase
   then Left $ mkCaseError t
   else Right $ ProductId t
```

### Phase 6: Optimize Runtime Validation

Once verification succeeds, optimize runtime code:

```haskell
-- Centralize validation logic
validateProductId :: Text -> Maybe ValidationErrorType
validateProductId t =
    if not (hasHyphen t) then Just FormatError  -- Can use predicates in runtime code
    else if not (isAllUppercase t) then Just CaseError
    else Nothing

-- Streamlined smart constructor
mkProductId :: Text -> Either Error ProductId
mkProductId t =
    case validateProductId t of
        Just errorType -> Left $ createError t errorType
        Nothing -> Right $ ProductId t
```

### Phase 7: Test Optimization

Remove tests for properties already verified by LiquidHaskell:

```haskell
-- REMOVE: Already guaranteed by LiquidHaskell
it "accepts valid product IDs" $ do
  mkProductId "BTC-USD" `shouldBe` Right (ProductId "BTC-USD")

-- KEEP: Tests error messages (not verified by LiquidHaskell)
it "returns proper error for invalid format" $ do
  let result = mkProductId "BTCUSD"
  errorMessageShouldContain result "hyphen"
```

## Common Patterns

### Predicate Definition Pattern

For LiquidHaskell 0.9.10+, choose the right annotation based on implementation:

```haskell
-- For pattern-matching functions:
{-@ measure hasProperty :: InputType -> Bool @-}
hasProperty :: InputType -> Bool
hasProperty (Constructor _) = True
hasProperty _ = False

-- For non-pattern-matching functions:
{-@ reflect hasProperty :: InputType -> Bool @-}
hasProperty :: InputType -> Bool
hasProperty input = someOtherFunction input
```

### Multi-Predicate Refinement Pattern

When dealing with complex refinements that might cause sort errors:

```haskell
-- Instead of using predicates directly:
{-@ data MyType = MyType {
    field :: {v:Type | predicate1 v && predicate2 v && predicate3 v}
    } @-}

-- Consider inlining when needed to avoid sort errors:
{-@ data MyType = MyType {
    field :: {v:Type | implementation_of_predicate1 && implementation_of_predicate2}
    } @-}
```

### Let-Binding for LiquidHaskell Pattern

```haskell
let condition1Valid = checkCondition1 input
    condition2Valid = checkCondition2 input
in if not condition1Valid
   then Left error1
   else if not condition2Valid
   then Left error2
   else Right $ Constructor input
```

### Error Type Enumeration Pattern

```haskell
data ValidationErrorType 
    = FormatError      -- ^ Format issues
    | ContentError     -- ^ Content issues
    | DomainError      -- ^ Domain rule violations

validateInput :: Input -> Maybe ValidationErrorType
validateInput input = -- implementation
```

## Common Pitfalls

1. **Sort System Mismatches**: Boolean expressions in refinements may cause sort errors in LH 0.9.10+. Try inlining the implementation directly when this happens.

2. **Measure vs. Reflect Confusion**: Remember that in LH 0.9.10+, `measure` requires pattern matching while `reflect` is for general functions.

3. **Measure Implementation Doesn't Match Type**: Ensure runtime code exactly matches refinements.

4. **Complex Logic in Predicates**: LiquidHaskell works best with simple, composable predicates.

5. **Missing Step-by-Step Validation**: Use let-bindings to help LiquidHaskell track state.

6. **Incorrect Function Refinements**: Pay attention to refinements on both inputs and outputs.

7. **Assuming Constraints Hold**: Avoid assuming what must be proven.

8. **Bang Patterns in Refinements**: LiquidHaskell doesn't support bang patterns (`!`) in refinements as they are a runtime concept, not a compile-time concept. Keep bang patterns in the actual data declarations only.

## Bang Patterns and LiquidHaskell

Bang patterns are a runtime strictness annotation in Haskell, but they are not supported in LiquidHaskell refinements. This is a common source of errors when starting with LiquidHaskell.

### The Problem

```haskell
-- This will cause an error in LiquidHaskell
{-@ data MyType = MyType { field :: !Text } @-}
```

LiquidHaskell will reject this with an error like:
```
Cannot parse specification: unexpected "!Text" expecting btP
```

### The Solution

The correct approach is to separate the concerns:
1. Keep your LiquidHaskell refinement free of bang patterns
2. Maintain bang patterns in the actual data declaration

```haskell
-- Refinement without bangs
{-@ data MyType = MyType { field :: Text } @-}

-- Actual declaration with bangs
data MyType = MyType { field :: !Text }
```

For fields with additional refinements:

```haskell
-- Refinement without bangs, but with other constraints
{-@ data MyType = MyType { field :: {v:Text | not (Text.null v)} } @-}

-- Actual declaration with bangs
data MyType = MyType { field :: !Text }
```

### Why This Works

LiquidHaskell operates at compile-time to verify logical properties, while bang patterns affect runtime evaluation strategy. These two concerns are orthogonal:

- **Refinement types**: Verify logical properties at compile-time
- **Bang patterns**: Control evaluation strictness at runtime

By keeping them separate, you get the best of both worlds.

## Handling Record Field Relationships

One of the most challenging aspects of LiquidHaskell refinements is defining relationships between record fields. This is particularly true in LiquidHaskell 0.9.10+ where these relationships often trigger sort system errors.

### The Problem with Field Relationships

Consider a price candle data structure where we want to enforce that the high price is always greater than or equal to the low price:

```haskell
-- May cause sort errors in LiquidHaskell 0.9.10+
{-@ data ProductCandle = ProductCandle
  { low :: Decimal2,
    high :: {h:Decimal2 | h >= low},
    open :: Decimal2,
    close :: Decimal2
  } @-}
```

This seemingly simple relationship between `high` and `low` can trigger sort system errors:

```
Sort Error in Refinement: {h:Decimal | h >= low}
Invalid Relation h >= low with operand types Decimal and func(...)
```

The error occurs because LiquidHaskell's sort system is having trouble with the relationship between record fields.

### A Systematic Approach

To overcome these challenges, follow this systematic approach:

1. **Start with basic type refinements** - Begin without any inter-field relationships:

   ```haskell
   {-@ data ProductCandle = ProductCandle
     { low :: Decimal2,    -- No refinements yet
       high :: Decimal2,   -- No refinements yet
       open :: Decimal2,
       close :: Decimal2
     } @-}
   ```

2. **Add a single relationship** - After verifying the basic structure works, add a single relationship:

   ```haskell
   {-@ data ProductCandle = ProductCandle
     { low :: Decimal2,
       high :: {h:Decimal2 | h >= low},   -- Just one relationship
       open :: Decimal2,
       close :: Decimal2
     } @-}
   ```

3. **Try different approaches if sort errors occur**:

   a. **Use reflect functions** (often easier for runtime validation):
   ```haskell
   {-@ reflect highGEQlow @-}
   highGEQlow :: Decimal2 -> Decimal2 -> Bool
   highGEQlow h l = h >= l

   {-@ data ProductCandle = ProductCandle
     { low :: Decimal2,
       high :: {h:Decimal2 | highGEQlow h low},  -- Using a reflected function
       open :: Decimal2,
       close :: Decimal2
     } @-}
   ```

   b. **Use direct expressions** (often better for sort system):
   ```haskell
   {-@ data ProductCandle = ProductCandle
     { low :: Decimal2,
       high :: {h:Decimal2 | h >= low},  -- Direct expression
       open :: Decimal2,
       close :: Decimal2
     } @-}
   ```

4. **Incrementally add more relationships** - After each successful verification, add more relationships:

   ```haskell
   {-@ data ProductCandle = ProductCandle
     { low :: Decimal2,
       high :: {h:Decimal2 | h >= low && h >= open && h >= close},  -- Multiple relationships
       open :: Decimal2,
       close :: Decimal2
     } @-}
   ```

### Best Sequence for Adding Field Refinements

When working with complex data types that have multiple relationships between fields, follow this sequence:

1. **Individual field types** - Start with just the basic types
2. **Single-field constraints** - Add constraints that apply to a single field (e.g., non-negative values)
3. **Simple inter-field relationships** - Add basic relationships (e.g., `field1 > field2`)
4. **Complex relationships** - Finally add complex relationships involving multiple fields

For example:

```haskell
-- Step 1: Start with basic types
{-@ data Point = Point
  { x :: Double,
    y :: Double,
    z :: Double
  } @-}

-- Step 2: Add single-field constraints
{-@ data Point = Point
  { x :: {v:Double | v >= 0},  -- Non-negative
    y :: {v:Double | v >= 0},  -- Non-negative
    z :: Double
  } @-}

-- Step 3: Add simple relationships
{-@ data Point = Point
  { x :: {v:Double | v >= 0},
    y :: {v:Double | v >= 0},
    z :: {v:Double | v >= x}  -- Simple relationship
  } @-}

-- Step 4: Add complex relationships
{-@ data Point = Point
  { x :: {v:Double | v >= 0},
    y :: {v:Double | v >= 0},
    z :: {v:Double | v >= x && v >= y && v <= x + y}  -- Complex relationship
  } @-}
```

Always compile and verify after each step, which makes it easier to identify which specific refinement is causing problems.

### When All Else Fails

If you've tried all approaches and still encounter sort errors:

1. **Use `assume` temporarily** - This lets you bypass verification temporarily:
   ```haskell
   {-@ assume mkProductCandle :: UTCTime -> Decimal2 -> Decimal2 -> Decimal2 -> Decimal2 -> Decimal8 -> ProductCandle @-}
   ```

2. **Move relational logic to the smart constructor** - Verify at runtime what you can't verify at compile-time:
   ```haskell
   -- No field relationship in the type
   {-@ data ProductCandle = ProductCandle
     { low :: Decimal2,
       high :: Decimal2,
       -- ...
     } @-}

   -- Enforce relationship in constructor
   mkProductCandle :: UTCTime -> Decimal2 -> Decimal2 -> Decimal2 -> Decimal2 -> Decimal8 -> Either AppError ProductCandle
   mkProductCandle timestamp low high open close volume =
     if not (high >= low)
       then Left $ mkAppError "High must be >= low" "mkProductCandle" details
       else Right $ ProductCandle timestamp low high open close volume
   ```

3. **Document why** - Always document when you had to fall back to runtime validation:
   ```haskell
   -- | Note: Field relationship (high >= low) enforced at runtime
   -- | due to LiquidHaskell sort system limitations with record fields
   ```

By following these strategies, you can maximize what you verify at compile-time while gracefully falling back to runtime validation when necessary.

## Next Steps

1. Review the `ProductId` implementation in our codebase for a complete example

2. Start applying RDD to other domain types, beginning with `FixedDecimal`

3. Explore more advanced LiquidHaskell features as you become comfortable

## Exporting Predicates

### Why Export LiquidHaskell Predicates?

An important best practice in our codebase is to export all LiquidHaskell measures and predicates in the module's export list. This has several benefits:

1. **Reuse in Other Modules**: Other modules can use your predicates in their own refinements
2. **Consistent Verification**: Ensures the same validation logic is used everywhere
3. **Documentation**: Makes the guarantees of your type explicit
4. **Composition**: Enables building more complex refinements based on simpler ones
5. **Avoids Linter Warnings**: Eliminates "Defined but not used" warnings for measure predicates
6. **Code Quality**: Maintains explicit API boundaries and usage patterns

### Export Pattern

Follow this pattern for exporting measures and predicates:

```haskell
module Domain.TypeName
  ( -- * Core Type
    TypeName(..)
    -- * Smart Constructor
  , mkTypeName
    -- * LiquidHaskell Predicates (exported for other refinements)
  , hasProperty1
  , hasProperty2
  , isValidFormat
  ) where
```

This pattern is used throughout our codebase, including in the `ProductId` module.

### Export All Predicates, Even if Only Used Internally

Even when a measure or predicate is currently only used within your module, still export it to:
1. Future-proof your API for potential reuse
2. Eliminate "Defined but not used" linter warnings 
3. Make the module's verification guarantees explicit

For example, even a simple predicate like this should be exported:

```haskell
-- In HttpClient.hs
{-@ measure isPositiveInt :: Int -> Bool @-}
isPositiveInt :: Int -> Bool
isPositiveInt n = n > 0

-- Must be included in the export list:
module Components.CoinbaseConnector.OutboundPorts.HttpClient
  ( -- other exports...
    
    -- * LiquidHaskell Predicates (exported for other refinements)
    isPositiveInt
  ) where
```

### When to Use Another Module's Predicates

Consider using another module's predicates when:

1. You need to define a type that includes or extends another refined type
2. You want to enforce the same validation logic across related types
3. You need to verify that inputs meet the requirements of another module's type before using its constructor

This approach is similar to Design by Contract in languages like Eiffel, where preconditions are made explicitly available to callers.

## Resources

- [LiquidHaskell User Guide](https://ucsd-progsys.github.io/liquidhaskell-tutorial/)
- [Refinement Types For Haskell](https://goto.ucsd.edu/~rjhala/liquid/haskell/blog/blog/2013/01/01/refinement-types-101.lhs/)
- [Our ProductId Implementation](docs/workflows/liquidhaskell.md)

## Making Validation LiquidHaskell-Friendly

One of the key challenges in using LiquidHaskell effectively is structuring your validation code so that LiquidHaskell can verify properties without requiring `assume` directives. This section provides a structured approach based on experience with our codebase.

### Step-by-Step Approach

#### 1. Establish Clear Flow Transparency

LiquidHaskell needs to "see" how validation flows from predicates to type construction:

```haskell
-- GOOD: Clear flow with explicit branching
case validateInput input of
    Just errorType -> 
        -- Invalid input: generate appropriate error message
        Left $ createError input errorType
    Nothing -> 
        -- Valid input: create Constructor
        -- At this point, LiquidHaskell knows all invariants are satisfied
        Right $ Constructor input

-- BAD: Flow is harder for LH to follow
if isValid input
    then Right $ Constructor input
    else Left $ createError input
```

The pattern matching with `case` and explicit enumeration of paths helps LiquidHaskell track the logical flow.

#### 2. Structure Validation Functions to Mirror Refinements Exactly

Ensure validation predicates precisely match the refinements:

```haskell
-- In type definition
{-@ data MyType = MyType { value :: {v:Text | not (Text.null v) && Text.length v > 3} } @-}

-- In validation function (notice the exact match)
validateMyType input =
    if Text.null input then Just EmptyError
    else if Text.length input <= 3 then Just LengthError
    else Nothing
```

This mirroring creates a logical connection that LiquidHaskell can follow.

#### 3. Use Centralized Validation with Clear Return Types

Always use a distinct validation function separate from error handling:

```haskell
-- Validation only - no error creation
validateInput :: Input -> Maybe ErrorType

-- Error creation separate from validation
createError :: Input -> ErrorType -> AppError

-- Smart constructor combines them
mkType input =
    case validateInput input of
        Just errorType -> Left $ createError input errorType
        Nothing -> Right $ Constructor input
```

This separation helps LiquidHaskell understand that validation is complete by the time construction happens.

#### 4. Order Validation Checks Consistently

Always check predicates in the same order they appear in refinements:

```haskell
-- In type definition
{-@ data MyType = MyType { value :: {v:Text | not (Text.null v) && Text.length v > 3} } @-}

-- In validation (same order as above)
validateMyType input =
    if Text.null input then Just EmptyError
    else if Text.length input <= 3 then Just LengthError
    else Nothing
```

#### 5. Use Total Functions for Measures and Reflections

Ensure functions are total (defined for all inputs) without partial patterns:

```haskell
-- GOOD: Total function with complete pattern matching
isValid :: Text -> Bool
isValid t = matchesCriteria t

-- BAD: Partial function
isValid :: Text -> Bool
isValid "" = False  -- Incomplete pattern matching
isValid t | hasCriteria t = True
          | otherwise = False
```

#### 6. Establish Clear Type Signatures for All Functions

Provide explicit type signatures for all functions, especially measure and reflect functions:

```haskell
{-@ measure isValid :: Text -> Bool @-}
isValid :: Text -> Bool
isValid t = -- implementation

{-@ reflect textLength @-}
textLength :: Text -> Int
textLength = Text.length
```

#### 7. Document the Verification Strategy

Add comments explaining the verification approach to help maintainers understand:

```haskell
-- | Smart constructor for MyType
-- |
-- | Compile-time verification:
-- | - All invariants verified at compile-time by LiquidHaskell
-- | 
-- | Runtime validation: 
-- | - Only for detailed error messages
```

#### 8. Centralize Error Classification with Enums

Use enumeration types for classifying validation errors:

```haskell
data ValidationErrorType 
    = FormatError
    | LengthError
    | ContentError
```

This makes the validation logic more structured and easier for LiquidHaskell to track.

#### 9. Add Strategic Hints Through Comments

Comments that establish logical flow can help both the programmer and LiquidHaskell:

```haskell
case validateInput input of
    Just errorType -> 
        -- Invalid input: generate appropriate error message
        Left $ createError input errorType
    Nothing -> 
        -- Valid input: create Constructor
        -- At this point, LiquidHaskell knows all invariants are satisfied
        Right $ Constructor input
```

### Complete Template - LiquidHaskell 0.9.10+ Compatible

Here's a complete template for structuring a new type with LiquidHaskell refinements that works with version 0.9.10+:

```haskell
-- Step 1: Define predicates using reflect (for non-pattern matching functions)
{-@ reflect predicate1 @-}
predicate1 :: Input -> Bool
predicate1 input = -- implementation

{-@ reflect predicate2 @-}
predicate2 :: Input -> Bool
predicate2 input = -- implementation

-- Step 2: Define refined type (using inlined expressions if necessary)
{-@ data MyType = MyType { 
    value :: {v:Input | direct_condition_1 v && direct_condition_2 v} 
  } @-}
newtype MyType = MyType { value :: Input }
    deriving stock (Eq, Show)

-- Step 3: Define validation error types
data ValidationErrorType 
    = Predicate1Error -- ^ First predicate failed
    | Predicate2Error -- ^ Second predicate failed

-- Step 4: Centralized validation function
validateMyType :: Input -> Maybe ValidationErrorType
validateMyType input =
    if not (predicate1 input) then 
        Just Predicate1Error
    else if not (predicate2 input) then 
        Just Predicate2Error
    else 
        Nothing

-- Step 5: Error creation function
createError :: Input -> ValidationErrorType -> AppError
createError input errorType = 
    let message = case errorType of
            Predicate1Error -> "First predicate failed"
            Predicate2Error -> "Second predicate failed"
    in AppError message "mkMyType" (errorDetails input) callStack

-- Step 6: Smart constructor with clear flow
{-@ mkMyType :: i:Input -> Either AppError MyType @-}
mkMyType :: Input -> Either AppError MyType
mkMyType input = 
    case validateMyType input of
        Just errorType -> 
            Left $ createError input errorType
        Nothing -> 
            Right $ MyType input
```

By following this structured approach consistently, you can ensure LiquidHaskell can verify your validation logic without `assume` directives, giving you true compile-time guarantees about your data types and their invariants.

### Incremental Verification Strategy

When working with complex types:

1. Start with the most basic refinements
2. Get those verified without `assume`
3. Add one refinement at a time
4. Test verification after each addition

This incremental approach helps identify which specific refinement might be causing verification problems. 

### Working with Boolean Refinements

When defining refinements that involve boolean conditions, especially in LiquidHaskell 0.9.10+:

1. **Try using the predicate function first**:
   ```haskell
   {-@ data MyType = MyType { value :: {v:Text | isNonEmpty v} } @-}
   ```

2. **If you get sort errors, inline the implementation**:
   ```haskell
   {-@ data MyType = MyType { value :: {v:Text | not (Text.null v)} } @-}
   ```

3. **Keep the predicate function for runtime use**:
   ```haskell
   validateMyType input = if not (isNonEmpty input) then Just EmptyError else Nothing
   ```

4. **Document why you're using direct implementation**:
   ```haskell
   -- Using direct implementation to avoid sort errors in LiquidHaskell 0.9.10+
   {-@ data MyType = MyType { value :: {v:Text | not (Text.null v)} } @-}
   ```

This approach gives you the best of both worlds: compile-time verification through LiquidHaskell and clear, maintainable code. 