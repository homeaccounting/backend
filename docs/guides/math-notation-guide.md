# Mathematical Notation Standards Guide

## Purpose

This guide establishes rigorous mathematical notation standards for all specifications within our project. It aims to ensure clarity, consistency, and precision in the representation of mathematical concepts. The mathematical notation employed within this guide utilizes LaTeX syntax for rendering.  However, the scope of this guide extends beyond simply defining the syntax. It mandates specific notational choices across various mathematical domains and emphasizes the crucial connection between formal mathematical expressions and their intuitive meanings.

Every mathematical expression presented must be accompanied by a corresponding plain English translation that captures its complete meaning while preserving mathematical precision. This dual representation serves several key purposes:

1. Accessibility: Plain English translations make the specifications accessible to a wider audience, including those who may not be deeply familiar with advanced mathematical notation.
2. Clarity and Understanding:  By explicitly stating the meaning of each expression in plain language, we reduce ambiguity and promote a deeper understanding of the underlying concepts.
3. Verification and Validation: The process of translating between formal notation and plain English helps to identify potential errors or inconsistencies in the mathematical formulation. It also facilitates communication and review among team members.
4. Consistency: This guide establishes a single, unified standard for mathematical notation to be used consistently throughout all project specifications, ensuring uniformity and avoiding confusion.
5. Maintainability: Well-documented mathematical expressions, along with their plain English counterparts, make the specifications easier to maintain, update, and extend over time.

In essence, this guide provides a blueprint for representing mathematical ideas within our project in a way that is both formally rigorous and humanly understandable, bridging the gap between abstract mathematical concepts and their concrete implementation.

By adhering to these standards, we aim to create specifications that are not only mathematically sound but also clear, accessible, and maintainable, ultimately contributing to the overall quality and success of our project. While experience with LaTeX is beneficial, this guide provides sufficient examples and explanations to be followed even by those less familiar. For more information on LaTeX syntax, numerous online tutorials and resources are available.

## Core Principles

1. Mathematical notation must be:
   - Precise and unambiguous  
   - Standard categorical/mathematical notation  
   - Recognizable to mathematicians  
   - Consistent across specifications  

2. Each notation block requires:
   - Precise mathematical expression  
   - Plain English translation  
   - Standard notation per this guide  
   - Haskell implementation reference (where applicable)

## Category Theory Notation

### Category Definition

```math
C = (Ob(C), Hom(C), \circ, id)
```

Plain English: A category \(C\) consists of:

- Objects (\(Ob(C)\))
- Morphisms between objects (\(\mathrm{Hom}(C)\))
- A composition operation (\(\circ\))
- Identity morphisms (\(id\))

#### Domain and Codomain Functions

```math
\begin{align*}
\mathrm{dom}: \mathrm{Hom}(C) &\to \mathrm{Ob}(C), \\
\mathrm{cod}: \mathrm{Hom}(C) &\to \mathrm{Ob}(C)
\end{align*}
```

Plain English:  
For each morphism \(f \in \mathrm{Hom}(C)\),  

- \(\mathrm{dom}(f)\) is the object from which \(f\) maps (the domain).  
- \(\mathrm{cod}(f)\) is the object to which \(f\) maps (the codomain).  

### Morphisms

```math
\begin{align*}
f &: A \rightarrow B \text{ (morphism)} \\
g \circ f &: A \rightarrow C \text{ (composition)} \\
id_A &: A \rightarrow A \text{ (identity)}
\end{align*}
```

Plain English:

- \(f\) maps from object \(A\) to \(B\).  
- \(g \circ f\) composes morphisms \(f\) and \(g\).  
- \(id_A\) is the identity morphism on \(A\).  

### Functors

```math
\begin{align*}
F &: C \rightarrow D \text{ (functor)} \\
F(g \circ f) &= F(g) \circ F(f) \text{ (preserves composition)} \\
F(id_A) &= id_{F(A)} \text{ (preserves identity)}
\end{align*}
```

Plain English:

- \(F\) maps category \(C\) to \(D\).  
- \(F\) preserves composition.  
- \(F\) preserves identity morphisms.  

### Natural Transformations

```math
\begin{align*}
\eta &: F \Rightarrow G : C \rightarrow D \text{ (natural transformation)} \\
\eta_B \circ F(f) &= G(f) \circ \eta_A \text{ (naturality square)}
\end{align*}
```

Plain English:

- \(\eta\) is a natural transformation from functor \(F\) to \(G\).  
- The naturality square commutes.  

### Adjoint Functors

```math
\begin{align*}
F &\dashv G : C \rightarrow D \text{ (adjunction)} \\
\mathrm{Hom}_D(F(A),B) &\cong \mathrm{Hom}_C(A,G(B)) \text{ (adjoint correspondence)}
\end{align*}
```

Plain English:

- \(F\) is left adjoint to \(G\).  
- There is a natural bijection between morphisms \(\mathrm{Hom}_D(F(A), B)\) and \(\mathrm{Hom}_C(A, G(B))\).

---

## Type Theory Notation

### Basic Types

```math
\begin{align*}
a &: A \text{ (type declaration)} \\
f &: A \rightarrow B \text{ (function type)} \\
P[A] &\text{ (type parameter)}
\end{align*}
```

Plain English:

- \(a\) has type \(A\).  
- \(f\) is a function from \(A\) to \(B\).  
- \(P\) is parameterized by type \(A\).

Haskell implementation:
```haskell
a :: A                  -- Value a of type A
f :: A -> B             -- Function from A to B
data P a = ...          -- Type P parameterized by type a
```

### Type Operations

```math
\begin{align*}
A \times B &\text{ (product type)} \\
A + B &\text{ (sum type)} \\
A^n &\text{ (repeated product)} \\
\mu X. F(X) &\text{ (recursive type)}
\end{align*}
```

Plain English:

- \(A \times B\) is the product of types \(A\) and \(B\).  
- \(A + B\) is the sum (disjoint union) of \(A\) and \(B\).  
- \(A^n\) denotes \(n\) copies of type \(A\).  
- \(\mu X. F(X)\) defines a recursive type by \(F\).  

Haskell implementation:
```haskell
data Product a b = Product a b          -- A × B as a tuple/record 
data Sum a b = Left a | Right b         -- A + B as Either
type Vector a = (a, a, a, a)            -- A^4 as a fixed-size tuple
data List a = Nil | Cons a (List a)     -- μX.1 + (A × X) as a recursive type
```

### Dependent Types

```math
\begin{align*}
\Pi(x:A). B(x) &\text{ (dependent product)} \\
\Sigma(x:A). B(x) &\text{ (dependent sum)}
\end{align*}
```

Plain English:

- \(\Pi(x : A). B(x)\) is a function type where the result type \(B(x)\) depends on the specific value \(x : A\). This generalizes the simpler function type \(A \rightarrow B\) by letting the codomain vary with each possible \(x\).  
- \(\Sigma(x : A). B(x)\) is a pair type where the second component depends on the specific first component.

Haskell implementation (with refinement types):
```haskell
-- Dependent function (simulated with refinement types)
{-@ dependentF :: x:Int -> {v:Int | v > x} @-}
dependentF :: Int -> Int

-- Dependent pair (simulated with refinement types)
{-@ data DependentPair = DPair { fst :: Int, snd :: {v:Int | v > fst} } @-}
data DependentPair = DPair { fst :: Int, snd :: Int }
```

---

## Set Theory Notation

### Basic Operations

```math
\begin{align*}
x \in A &\text{ (element of)} \\
A \subset B &\text{ (subset)} \\
A \cup B &\text{ (union)} \\
A \cap B &\text{ (intersection)} \\
A \setminus B &\text{ (set difference)}
\end{align*}
```

Plain English:

- \(x\) is an element of set \(A\).  
- \(A\) is a subset of \(B\).  
- \(A \cup B\) is the union of sets \(A\) and \(B\).  
- \(A \cap B\) is the intersection of \(A\) and \(B\).  
- \(A \setminus B\) contains elements in \(A\) not in \(B\).

Haskell implementation:
```haskell
-- Check if x is in set A
elem x setA                 -- x ∈ A

-- Check if A is a subset of B
subset a b = all (`elem` b) a  -- A ⊂ B

-- Union of two sets
union                       -- A ∪ B

-- Intersection of two sets
intersection                -- A ∩ B 

-- Set difference
difference                  -- A \ B
```

### Set Construction

```math
\begin{align*}
\{x \in A \mid P(x)\} &\text{ (set comprehension)} \\
\{f(x) \mid x \in A\} &\text{ (set mapping)} \\
\mathcal{P}(A) &\text{ (power set)}
\end{align*}
```

Plain English:

- \(\{x \in A \mid P(x)\}\) is the set of \(x\) in \(A\) that satisfy predicate \(P\).  
- \(\{f(x) \mid x \in A\}\) is the set of \(f(x)\) for \(x\) in \(A\).  
- \(\mathcal{P}(A)\) is the set of all subsets of \(A\).

Haskell implementation:
```haskell
-- Set comprehension - items in A that satisfy predicate P
filter p setA               -- {x ∈ A | P(x)}

-- Set mapping - apply function f to each element in set A
map f setA                  -- {f(x) | x ∈ A}

-- Power set (all possible subsets)
powerSet :: [a] -> [[a]]    -- P(A)
powerSet [] = [[]]
powerSet (x:xs) = map (x:) ps ++ ps
  where ps = powerSet xs
```

### Algebraic Structures

```math
\begin{align*}
(G,\cdot,e) &\text{ (group)} \\
(R,+,\cdot,0,1) &\text{ (ring)} \\
\mathbb{N, Z, Q, R} &\text{ (number systems)}
\end{align*}
```

Plain English:

- A group \((G, \cdot, e)\) has a binary operation \(\cdot\) and identity element \(e\).  
- A ring \((R, +, \cdot, 0, 1)\) has two operations (\(+\) and \(\cdot\)), plus additive and multiplicative identities.  
- \(\mathbb{N}, \mathbb{Z}, \mathbb{Q}, \mathbb{R}\) denote natural numbers, integers, rationals, and reals, respectively.

Haskell implementation:
```haskell
-- Group typeclass
class Group g where
  op :: g -> g -> g          -- Binary operation (·)
  identity :: g              -- Identity element (e)
  inverse :: g -> g          -- Inverse element
  
-- Ring typeclass
class Group r => Ring r where
  add :: r -> r -> r         -- Addition (+)
  zero :: r                  -- Additive identity (0)
  multiply :: r -> r -> r    -- Multiplication (·)
  one :: r                   -- Multiplicative identity (1)

-- Number systems
type Natural = Word
type Integer = Int
type Rational = Ratio Integer
type Real = Double
```

---

## Logic Notation

### Propositional Logic

```math
\begin{align*}
P \land Q &\text{ (conjunction)} \\
P \lor Q &\text{ (disjunction)} \\
\neg P &\text{ (negation)} \\
P \Rightarrow Q &\text{ (implication)} \\
P \Leftrightarrow Q &\text{ (equivalence)}
\end{align*}
```

Plain English:

- \(P \land Q\) means \(P\) and \(Q\).  
- \(P \lor Q\) means \(P\) or \(Q\).  
- \(\neg P\) means "not \(P\)."  
- \(P \Rightarrow Q\) means "if \(P\) then \(Q\)."  
- \(P \Leftrightarrow Q\) means "\(P\) if and only if \(Q\)."

Haskell implementation:
```haskell
p && q                       -- P ∧ Q (conjunction)
p || q                       -- P ∨ Q (disjunction)
not p                        -- ¬P (negation)
p <= q                       -- P ⇒ Q (implication, often encoded as ≤)
p == q                       -- P ⇔ Q (equivalence)
```

### Predicate Logic

```math
\begin{align*}
\forall x.P(x) &\text{ (universal quantification)} \\
\exists x.P(x) &\text{ (existential quantification)} \\
\exists! x.P(x) &\text{ (unique existence)}
\end{align*}
```

Plain English:

- \(\forall x.P(x)\) means "for all \(x\), \(P(x)\) holds."  
- \(\exists x.P(x)\) means "there exists some \(x\) such that \(P(x)\) holds."  
- \(\exists! x.P(x)\) means "there exists a unique \(x\) such that \(P(x)\) holds."

Haskell implementation:
```haskell
-- Universal quantification: all elements satisfy predicate P
all p xs                     -- ∀x. P(x)

-- Existential quantification: at least one element satisfies P
any p xs                     -- ∃x. P(x)

-- Unique existence: exactly one element satisfies P
uniqueExists :: (a -> Bool) -> [a] -> Bool
uniqueExists p xs = length (filter p xs) == 1  -- ∃!x. P(x)
```

---

## Refinement Type Notation

Refinement types extend base types with logical predicates, allowing precise specifications of constraints and invariants at the type level.

### Basic Refinement Types

```math
\begin{align*}
\{v:T \mid P(v)\} &\text{ (basic refinement type)} \\
x:\{v:T \mid P(v)\} &\text{ (binding with refinement)} \\
\Gamma \vdash e : \{v:T \mid P(v)\} &\text{ (typing judgment)}
\end{align*}
```

Plain English:

- \(\{v:T \mid P(v)\}\) is the set of values \(v\) of type \(T\) such that predicate \(P(v)\) holds.
- \(x:\{v:T \mid P(v)\}\) declares a variable \(x\) with a refined type.
- \(\Gamma \vdash e : \{v:T \mid P(v)\}\) states that expression \(e\) has the refinement type under context \(\Gamma\).

LiquidHaskell implementation:
```haskell
-- Define a refined type for positive integers
{-@ type PositiveInt = {v:Int | v > 0} @-}

-- Function that takes and returns positive integers
{-@ increment :: PositiveInt -> PositiveInt @-}
increment :: Int -> Int
increment x = x + 1

-- Refinement for non-empty lists
{-@ type NonEmptyList a = {xs:[a] | len xs > 0} @-}

-- Function using non-empty list refinement
{-@ head :: NonEmptyList a -> a @-}
head :: [a] -> a
head (x:_) = x
head [] = error "Unreachable due to refinement type"
```

### Relational Refinements

```math
\begin{align*}
\{v:T \mid v \sim f(x)\} &\text{ (relational refinement)} \\
\{v:T \mid v = x + y\} &\text{ (equality refinement)} \\
\{v:T \mid v \geq x\} &\text{ (inequality refinement)}
\end{align*}
```

Plain English:

- \(\{v:T \mid v \sim f(x)\}\) relates the refined value to some function of other values.
- \(\{v:T \mid v = x + y\}\) specifies that the value exactly equals the sum of \(x\) and \(y\).
- \(\{v:T \mid v \geq x\}\) requires the value to be greater than or equal to \(x\).

LiquidHaskell implementation:
```haskell
-- Relational refinement between function inputs and outputs
{-@ add :: x:Int -> y:Int -> {v:Int | v = x + y} @-}
add :: Int -> Int -> Int
add x y = x + y

-- Output must be greater than or equal to input
{-@ increment :: x:Int -> {v:Int | v > x} @-}
increment :: Int -> Int
increment x = x + 1

-- Refined data type with field relationship
{-@ data Range = Range { 
    start :: Int, 
    end :: {v:Int | v >= start} 
  } @-}
data Range = Range { start :: Int, end :: Int }
```

### Measure Functions

```math
\begin{align*}
\mu &: T \rightarrow P \text{ (measure function)} \\
\{v:T \mid \mu(v) = k\} &\text{ (refinement with measure)} \\
\{v:[T] \mid \text{len}(v) > 0\} &\text{ (length measure example)}
\end{align*}
```

Plain English:

- \(\mu\) is a measure function that computes a property of values of type \(T\).
- \(\{v:T \mid \mu(v) = k\}\) refines type \(T\) with measure \(\mu\) constrained to equal \(k\).
- \(\{v:[T] \mid \text{len}(v) > 0\}\) uses the length measure to specify non-empty lists.

LiquidHaskell implementation:
```haskell
-- Define a measure function for checking if a list is sorted
{-@ measure isSorted @-}
{-@ isSorted :: [Int] -> Bool @-}
isSorted :: [Int] -> Bool
isSorted [] = True
isSorted [_] = True
isSorted (x:y:xs) = x <= y && isSorted (y:xs)

-- Use the measure in refinements
{-@ type SortedList = {v:[Int] | isSorted v} @-}

-- Function that maintains the sorted property
{-@ insert :: Int -> SortedList -> SortedList @-}
insert :: Int -> [Int] -> [Int]
insert n [] = [n]
insert n (x:xs)
  | n <= x    = n : x : xs
  | otherwise = x : insert n xs
```

---

## Temporal Logic Notation

Temporal logic extends propositional logic with operators that refer to time, essential for specifying and verifying concurrent and reactive systems.

### Linear Temporal Logic (LTL)

```math
\begin{align*}
\Box P &\text{ (always)} \\
\Diamond P &\text{ (eventually)} \\
P \mathcal{U} Q &\text{ (until)} \\
\circ P &\text{ (next)}
\end{align*}
```

Plain English:

- \(\Box P\) means "\(P\) holds at every future state."
- \(\Diamond P\) means "\(P\) holds at some future state."
- \(P \mathcal{U} Q\) means "\(P\) holds until \(Q\) holds."
- \(\circ P\) means "\(P\) holds at the next state."

Haskell implementation with property testing:
```haskell
-- Temporal safety property (always P)
prop_alwaysSafe :: [State] -> Property
prop_alwaysSafe states = all isSafe states

-- Temporal liveness property (eventually P)
prop_eventuallyDone :: [State] -> Property
prop_eventuallyDone states = any isDone states 

-- Until property (P until Q)
prop_untilProperty :: [State] -> Property
prop_untilProperty [] = property True
prop_untilProperty states = 
  let qStates = dropWhile (not . isQ) states
  in all isP (takeWhile (not . isQ) states) && not (null qStates)

-- Next property (next state satisfies P)
prop_nextProperty :: State -> State -> Property
prop_nextProperty s1 s2 = property $ isP s2
```

### Computation Tree Logic (CTL)

```math
\begin{align*}
\mathbf{A} \Box P &\text{ (invariant: always P on all paths)} \\
\mathbf{E} \Diamond P &\text{ (possibility: eventually P on some path)} \\
\mathbf{A} [P \mathcal{U} Q] &\text{ (inevitability: P until Q on all paths)} \\
\mathbf{E} [P \mathcal{U} Q] &\text{ (potential: P until Q on some path)}
\end{align*}
```

Plain English:

- \(\mathbf{A} \Box P\) means "\(P\) holds at every state on all possible execution paths."
- \(\mathbf{E} \Diamond P\) means "there exists some execution path where \(P\) eventually holds."
- \(\mathbf{A} [P \mathcal{U} Q]\) means "on all paths, \(P\) holds until \(Q\) holds."
- \(\mathbf{E} [P \mathcal{U} Q]\) means "there exists a path where \(P\) holds until \(Q\) holds."

Haskell implementation with stateful properties:
```haskell
-- Invariant on a state machine (all paths always P)
invariant :: (s -> Bool) -> StateMachine s -> Property
invariant p sm = property $ all p (reachableStates sm)

-- Possibility (exists path to a state with P)
possibility :: (s -> Bool) -> StateMachine s -> Property
possibility p sm = property $ any p (reachableStates sm)

-- All paths lead to a state satisfying p (inevitability)
inevitable :: (s -> Bool) -> StateMachine s -> Property
inevitable p sm = property $ 
  all (\path -> any p path) (allPaths sm)
```

---

## Property Specification Notation

Property specifications formalize behavior expectations that can be verified using tools like property testing frameworks.

### Function Properties

```math
\begin{align*}
\forall x, y. f(x, y) &= f(y, x) \text{ (commutativity)} \\
\forall x, y, z. f(x, f(y, z)) &= f(f(x, y), z) \text{ (associativity)} \\
\forall x. f(x, e) &= x \text{ (identity element)} \\
\forall x. f(x, g(x)) &= e \text{ (inverse element)}
\end{align*}
```

Plain English:

- Commutativity: The function gives the same result regardless of argument order.
- Associativity: The function gives the same result regardless of grouping.
- Identity: There exists an element \(e\) such that combining any \(x\) with \(e\) yields \(x\).
- Inverse: For each \(x\), there exists \(g(x)\) such that combining them yields the identity.

QuickCheck implementation:
```haskell
-- Commutativity property
prop_commutative :: Int -> Int -> Bool
prop_commutative x y = f x y == f y x

-- Associativity property
prop_associative :: Int -> Int -> Int -> Bool
prop_associative x y z = f x (f y z) == f (f x y) z

-- Identity element property
prop_identity :: Int -> Bool
prop_identity x = f x identity == x

-- Inverse element property
prop_inverse :: Int -> Bool
prop_inverse x = f x (inverse x) == identity
```

### Data Structure Properties

```math
\begin{align*}
\forall xs, x. x \in \text{insert}(x, xs) &\text{ (insertion)} \\
\forall xs, x. |xs| = |\text{insert}(x, xs)| - 1 &\text{ (size increment)} \\
\forall xs. \text{ordered}(xs) \Rightarrow \forall i < j. xs[i] \leq xs[j] &\text{ (ordering)}
\end{align*}
```

Plain English:

- Insertion: After inserting \(x\) into a collection, \(x\) is a member of that collection.
- Size increment: Inserting an item increases the size by 1.
- Ordering: In an ordered collection, elements at lower indices are less than or equal to elements at higher indices.

QuickCheck implementation:
```haskell
-- Insertion property
prop_insertion :: Int -> [Int] -> Bool
prop_insertion x xs = x `elem` insert x xs

-- Size increment property
prop_size_increment :: Int -> [Int] -> Bool
prop_size_increment x xs = length (insert x xs) == length xs + 1

-- Ordering property
prop_ordering :: Property
prop_ordering = forAll orderedLists $ \xs ->
  and [xs !! i <= xs !! j | i <- [0..length xs-2], j <- [i+1..length xs-1]]
  where orderedLists = listOf arbitrary `suchThat` isSorted
```

### State Machine Properties

```math
\begin{align*}
\forall s, a. \text{isValid}(s) \Rightarrow \text{isValid}(\text{next}(s, a)) &\text{ (invariant preservation)} \\
\forall s, a, s'. s' = \text{next}(s, a) \Rightarrow \text{canReach}(s', \text{target}) &\text{ (reachability)} \\
\forall s. \text{isDeadlock}(s) \Rightarrow \text{False} &\text{ (deadlock freedom)}
\end{align*}
```

Plain English:

- Invariant preservation: Valid states always transition to valid states.
- Reachability: Target states are reachable from any valid state.
- Deadlock freedom: No valid state can lead to deadlock.

Hedgehog implementation:
```haskell
-- Invariant preservation property
prop_invariant_preservation :: Command -> State -> Bool
prop_invariant_preservation cmd state =
  isValid state ==> isValid (runCommand cmd state)

-- Reachability property
prop_reachability :: State -> Property
prop_reachability initialState = property $ do
  commands <- forAll $ Gen.list (Range.linear 1 100) genCommand
  let finalState = foldl (flip runCommand) initialState commands
  assert $ canReach finalState targetState

-- Deadlock freedom property
prop_no_deadlocks :: State -> Bool
prop_no_deadlocks state = not (isDeadlock state)
  where isDeadlock s = isValid s && null (availableCommands s)
```

---

## Resource Reasoning Notation

Resource reasoning formalizes how computational resources (memory, file handles, etc.) are acquired, used, and released.

### Linear and Affine Types

```math
\begin{align*}
A \multimap B &\text{ (linear function type)} \\
A \rightharpoonup B &\text{ (affine function type)} \\
!A &\text{ (unrestricted/replicable type)}
\end{align*}
```

Plain English:

- \(A \multimap B\) is a function that consumes exactly one \(A\) to produce a \(B\).
- \(A \rightharpoonup B\) is a function that consumes at most one \(A\) to produce a \(B\).
- \(!A\) represents a value of type \(A\) that can be used any number of times.

Haskell implementation:
```haskell
-- Linear function (in Linear Haskell)
linearFunction :: a %1-> b

-- Affine function (simulated with Maybe)
type AffineFn a b = a -> Maybe b

-- Unrestricted value (implicit in most Haskell code)
type Unrestricted a = a
```

### Resource Acquisition and Release

```math
\begin{align*}
\text{acquire} &: 1 \multimap \text{Resource} \\
\text{use} &: \text{Resource} \multimap \text{Resource} \\
\text{release} &: \text{Resource} \multimap 1
\end{align*}
```

Plain English:

- \(\text{acquire}\) creates a resource from nothing (unit type 1).
- \(\text{use}\) consumes a resource and produces a potentially modified resource.
- \(\text{release}\) consumes a resource and returns nothing (unit type 1).

Haskell implementation:
```haskell
-- Resource acquisition and release using bracket pattern
withResource :: (Resource -> IO a) -> IO a
withResource action = bracket
  acquire      -- Acquire the resource
  release      -- Release the resource
  action       -- Use the resource

-- Linear types version (Linear Haskell)
useResource :: IO (Resource %1-> IO ())
useResource = do
  resource <- acquire
  -- Use resource linearly
  pure $ \resource -> release resource
```

### Session Types

```math
\begin{align*}
!A.\text{end} &\text{ (send A then end)} \\
?A.\text{end} &\text{ (receive A then end)} \\
!A.!B.\text{end} &\text{ (send A, then send B, then end)} \\
\mu X.!A.X &\text{ (repeatedly send A)}
\end{align*}
```

Plain English:

- \(!A.\text{end}\) describes a protocol that sends a value of type \(A\) and then terminates.
- \(?A.\text{end}\) describes a protocol that receives a value of type \(A\) and then terminates.
- \(!A.!B.\text{end}\) describes a protocol that sends \(A\), then sends \(B\), then terminates.
- \(\mu X.!A.X\) describes a protocol that repeatedly sends values of type \(A\).

Haskell implementation:
```haskell
-- Session types using type-level programming
type SendThenEnd a = Send a End
type ReceiveThenEnd a = Receive a End
type SendTwoThenEnd a b = Send a (Send b End)
type RepeatSend a = Fix (Send a)

-- Implementation with typed channels
sendThenEnd :: Channel (SendThenEnd a) -> a -> IO (Channel End)
sendThenEnd channel value = send channel value

receiveThenEnd :: Channel (ReceiveThenEnd a) -> IO (a, Channel End)
receiveThenEnd channel = receive channel
```

---

## System-Specific Notation

### Value Spaces

```math
\begin{align*}
\text{Quantity} &= \{x \in \mathbb{Q} \mid \text{precision}(x) = 8\} \\
\text{USDAmount} &= \{x \in \mathbb{Q} \mid \text{precision}(x) = 2\}
\end{align*}
```

Plain English:

- `Quantity` is a set of rational numbers with 8 decimal places (e.g., asset amounts).  
- `USDAmount` is a set of rational numbers with 2 decimal places (e.g., USD amounts).

Haskell implementation with LiquidHaskell:
```haskell
-- Quantity type with refinement
{-@ type Quantity = {x:Rational | precision x == 8} @-}
type Quantity = Rational

-- USDAmount type with refinement
{-@ type USDAmount = {x:Rational | precision x == 2} @-}
type USDAmount = Rational

-- Precision measure
{-@ measure precision :: Rational -> Int @-}
precision :: Rational -> Int
precision r = getDecimalPlaces (denominator r)
```

### State Spaces

```math
\begin{align*}
\text{State} &= \text{Portfolio} \times \text{Market} \times \text{Context} \\
\text{Portfolio} &= \{p \mid \text{constraints}(p)\} \\
\text{Error} &= \text{ValidationError} + \text{NetworkError}
\end{align*}
```

Plain English:

- A `State` is defined as the product of `Portfolio`, `Market`, and `Context`.  
- A `Portfolio` is any \(p\) satisfying the relevant allocation constraints.  
- `Error` is a sum type representing either a validation error or a network error.

Haskell implementation:
```haskell
-- State as a product type
data State = State 
  { portfolio :: Portfolio
  , market :: Market
  , context :: Context
  }

-- Portfolio with constraints
{-@ data Portfolio = Portfolio { 
    holdings :: {h:[Holding] | validAllocation h}
  } @-}
data Portfolio = Portfolio { holdings :: [Holding] }

-- Error as a sum type
data Error 
  = ValidationError String
  | NetworkError String
```

---

## Documentation Requirements

1. Format:
   - Use triple backtick with math indicator  
   - Each expression on its own line  
   - Proper spacing around operators  
   - Consistent indentation  

2. Translation:
   - Plain English follows each math block  
   - Captures complete mathematical meaning  
   - Uses precise terminology  
   - Maintains accessibility  

3. Haskell Implementation:
   - Include Haskell code examples where applicable
   - Demonstrate direct mapping to mathematical notation
   - Use idiomatic Haskell patterns
   - Include verification techniques (LiquidHaskell, property testing)

4. Consistency:
   - Follow notation standards exactly  
   - Maintain notation across documents  
   - Verify mathematical correctness  
   - Include all components  

---

## Implementation Note

When implementing this notation:

1. Start with the mathematical expression.  
2. Follow with the plain English translation.  
3. Add Haskell implementation where applicable.
4. Maintain precise correspondence between all three.
5. Cross-reference this guide.  
6. Verify mathematical correctness.
7. Validate Haskell implementation with appropriate verification tools.

---

## Usage Example

Complete example showing proper format with Haskell implementation:

```math
\begin{align*}
C &= (Ob(C), \mathrm{Hom}(C), \circ, id) \\
\mathrm{Ob}(C) &= \{ s \in \text{State} \mid \text{valid}(s) \} \\
\mathrm{Hom}(C) &= \{ f: A \rightarrow B \mid A,B \in \mathrm{Ob}(C) \} \\
\forall f,g &: f \circ g \text{ defined iff } \mathrm{cod}(g) = \mathrm{dom}(f)
\end{align*}
```

Plain English:  
Our system forms a category where:

- Objects (\(\mathrm{Ob}(C)\)) are valid system states.  
- Morphisms (\(\mathrm{Hom}(C)\)) are operations between states.  
- Composition requires matching domains/codomains.  
- Every operation preserves system properties.

Haskell implementation:
```haskell
-- Define the category using typeclasses
class Category c where
  id :: c a a
  (.) :: c b c -> c a b -> c a c

-- Define our state objects
{-@ data State = State { ... } | valid @-}
data State = State { ... }

-- Define our morphisms as state transformers
newtype StateMorphism a b = StateMorphism (a -> b)

-- Implement Category instance
instance Category StateMorphism where
  id = StateMorphism (\x -> x)
  (StateMorphism f) . (StateMorphism g) = StateMorphism (f . g)

-- Verify operations preserve validity
{-@ applyMorphism :: f:StateMorphism a b -> 
                    {s:a | valid s} -> 
                    {t:b | valid t} @-}
applyMorphism (StateMorphism f) s = f s