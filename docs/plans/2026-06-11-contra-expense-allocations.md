# Contra-Expense Allocations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a single transaction carry both income and expense allocations so reimbursements net against expense categories (contra-expense), without negative amounts.

**Architecture:** Turn `Allocations` from `type Allocations = NonEmpty Allocation` into a two-bucket record `{ incomes :: [Allocation], expenses :: [Allocation] }`. The contra effect is derived from bucket + flow direction; amounts stay `> 0`. Amount-changing amendments now carry explicit allocations (proportional rescale deleted). All sum/currency checks anchor to the transaction's `Money` amount. Sagas are untouched (they move only totals).

**Tech Stack:** GHC 9.10.3, RIO prelude, Servant, Eventium event store, Hspec + QuickCheck, LiquidHaskell, ormolu, hlint. Build via `just`/`cabal`.

**Spec:** [`docs/specs/2026-06-11-contra-expense-allocations-design.md`](../specs/2026-06-11-contra-expense-allocations-design.md)

**Branch:** `feat/contra-expense-allocations` (already checked out).

---

## Migration reality (read before starting)

`Allocations` is a type alias used across Domain, Application, Web, and tests. Redefining it as a record breaks compilation everywhere at once. Therefore:

- **Task 1** (errors) is additive and compiles/commits on its own.
- **Task 2** is the coordinated migration: it changes the core type and fixes every consumer to a **green `cabal build -fci` (-Werror)** before committing. New-behavior unit/property tests are authored *first* (step 1) but only run green at the end of the task — this is the most TDD-faithful shape a pervasive type change allows.
- **Tasks 3–5** add further test-first behavior + integration coverage on the now-stable types.
- **Task 6** is the final verification gate (build, full suite, format, lint).

Commit only at the end of each task (green build). Intermediate non-compiling states stay uncommitted on the branch.

## Commands cheat-sheet

```bash
just build                                   # hpack + cabal build
cabal build -fci                             # CI build with -Werror (the gate)
just test                                    # full suite
cabal test all --test-option='--match' --test-option="/PATTERN/"   # subset
just format                                  # ormolu -i
just lint                                    # hlint
```
Run everything inside `nix develop`.

## File map

| File | Change |
|------|--------|
| `src/Domain/Core/Errors.hs` | Add `ContraIncomeNotSupported`, `AllocationsEmpty` to `DomainError` + `toErrorCode` arms |
| `src/Domain/Transaction/CommandHandler.hs` | Add same two to `TransactionError`; rewrite `checkAllocationsAgainst`; contra check in `InitiateTransaction`/`SetTransactionAllocations`; re-anchor set-allocations |
| `src/Application/Services/TransactionService.hs` | Map new errors in `translateTransactionError`; rewrite `synthesiseAmendmentTransactionType` (no rescale); per-bucket `validateAllocationsAgainstDictionary`; update `initiateIncome`/`initiateExpense`; fix imports |
| `src/Web/ErrorMapping.hs` | HTTP mapping for the two new `DomainError`s |
| `src/Domain/Core/Types.hs` | `Allocations` record + `mkAllocations` + `allAllocations`; rewrite `validateAllocations`; update `mkIncome`/`mkExpense` (contra); update `allocationsOf`/`replaceAllocations`; **delete** `rescaleAllocations`/`rescaleTransactionType`/`sumAllocationsUnchecked`/`categorisedAmount`; update exports + LH |
| `src/Web/Types.hs` | Redesign `IncomeRequest`/`ExpenseRequest` to two-bucket allocations; add `AllocationsRequest`/`CategoryAmount`; `transactionTypeAllocationsText` folds both buckets |
| `src/Web/API/TransactionAPI.hs` | Rewrite `incomeHandler`/`expenseHandler` to build a two-bucket `Allocations` from the new DTO |
| `src/Application/ReadModels/Transaction.hs` | `referencesInAllocations` (~line 507) must fold both buckets via `allAllocations` |
| `test/Testkit/Generators.hs` | Two-bucket generators |
| `test/Domain/Transaction/AllocationsSpec.hs` (+ new specs) | New-behavior tests |

All three process managers (`TransactionPostingManager`, `TransactionCancellationManager`, `TransactionAmendmentManager`) need **no change** — verified they consume only `Money` totals / pass `newTransactionType` opaquely. NOTE: line numbers in this plan may have drifted slightly — **locate functions by name (grep), not by the cited line.**

---

### Task 1: Add the two new error constructors (additive, compiles standalone)

**Files:**
- Modify: `src/Domain/Core/Errors.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs:74-95`
- Modify: `src/Application/Services/TransactionService.hs:957-962`
- Modify: `src/Web/ErrorMapping.hs:233-260`

- [ ] **Step 1: Add to `DomainError`**

In `src/Domain/Core/Errors.hs`, after the `AllocationCurrencyMismatch` constructor (~line 99) add:

```haskell
  | -- | A transaction direction carries a category allocation it must not:
    --   an `Expense` (outbound) transaction with a non-empty income bucket
    --   would be contra-income, which is unsupported.
    ContraIncomeNotSupported
  | -- | `mkAllocations` rejected a payload with both buckets empty —
    --   a categorised transaction must carry at least one allocation.
    AllocationsEmpty
```

- [ ] **Step 2: Add `renderDomainError` arms in Errors.hs**

`renderDomainError :: DomainError -> Text` (~line 216) returns human-readable messages. Find the `AllocationsDoNotSumToTotal ->` arm (~line 247) and add, in the same message style:

```haskell
  ContraIncomeNotSupported ->
    "An expense cannot carry income allocations (contra-income is not supported)"
  AllocationsEmpty ->
    "A categorised transaction must carry at least one allocation"
```
(Copy the surrounding arm's exact form. If there is also a separate error-code function, add matching `"CONTRA_INCOME_NOT_SUPPORTED"` / `"ALLOCATIONS_EMPTY"` arms there.)

- [ ] **Step 3: Add to `TransactionError` (handler channel)**

In `src/Domain/Transaction/CommandHandler.hs`, in the `data TransactionError` block (line 74), beside `AllocationCurrencyMismatch` (~line 93) add `ContraIncomeNotSupported` and `AllocationsEmpty` constructors with brief haddock mirroring the existing allocation ones.

- [ ] **Step 4: Map handler→domain in `translateTransactionError`**

In `src/Application/Services/TransactionService.hs` after line 962 add:

```haskell
translateTransactionError (CommandRejected TxCh.ContraIncomeNotSupported) =
  ContraIncomeNotSupported
translateTransactionError (CommandRejected TxCh.AllocationsEmpty) =
  AllocationsEmpty
```

- [ ] **Step 5: HTTP mapping**

In `src/Web/ErrorMapping.hs` near line 233, mirror an existing allocation arm (likely a 422/400 with field error). Add:

```haskell
mapDomainError ContraIncomeNotSupported =
  -- copy the shape of mapDomainError AllocationCurrencyMismatch (422),
  -- code "CONTRA_INCOME_NOT_SUPPORTED", message explaining an expense
  -- cannot carry income allocations.
mapDomainError AllocationsEmpty =
  -- 422, code "ALLOCATIONS_EMPTY", message "at least one allocation required".
```
(Open `mapDomainError AllocationCurrencyMismatch` at line 253 and copy its exact constructor/HTTP-status form.)

- [ ] **Step 6: Build**

Run: `cabal build -fci`
Expected: PASS (new constructors compile; unused-constructor warnings do not exist in GHC, so -Werror is fine).

- [ ] **Step 7: Commit**

```bash
git add src/Domain/Core/Errors.hs src/Domain/Transaction/CommandHandler.hs src/Application/Services/TransactionService.hs src/Web/ErrorMapping.hs
git commit -m "feat(transaction): add ContraIncomeNotSupported and AllocationsEmpty errors"
```

---

### Task 2: Migrate `Allocations` to a two-bucket record (coordinated, ends green)

**Files:**
- Modify: `src/Domain/Core/Types.hs` (type, helpers, exports, LH)
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Modify: `src/Application/Services/TransactionService.hs`
- Modify: `src/Web/Types.hs`
- Modify: `test/Testkit/Generators.hs`
- Test: `test/Domain/Transaction/AllocationsSpec.hs` (extend)

> The build is RED from step 2 until step 12. Do not commit until step 13 is green.

- [ ] **Step 1: Author the new-behavior domain tests first**

> Note: the **existing** tests in `test/Domain/Transaction/AllocationsSpec.hs` (the `:|`/`NonEmpty`-based `mkIncome`/`mkExpense` cases, ~lines 74-99) must be rewritten to the new `mkAllocations [..] [..]` construction as part of this task — Step 14 enumerates them. Here you only *append* the new two-bucket cases.

Append to `test/Domain/Transaction/AllocationsSpec.hs` (allocations are now built with `mkAllocations`; the old `Allocation … :| [..]` form becomes `let Right allocs = mkAllocations [..] [..]`):

```haskell
  describe "two-bucket allocations" $ do
    it "accepts a standalone refund: Income with empty incomes, $40 in expenses" $ do
      let total = unsafeMoney USD 40
          Right allocs = Core.mkAllocations [] [Allocation rentCat (unsafeMoney USD 40)]
      case Core.mkIncome total allocs of
        Right (Income _) -> pure ()
        other -> expectationFailure $ "expected Right (Income …), got " <> show other

    it "accepts salary+rent: Income with $5000 incomes and $500 expenses summing to $5500" $ do
      let total = unsafeMoney USD 5500
          Right allocs =
            Core.mkAllocations
              [Allocation salaryCat (unsafeMoney USD 5000)]
              [Allocation rentCat (unsafeMoney USD 500)]
      Core.mkIncome total allocs `shouldSatisfy` isRight

    it "rejects an Expense carrying a non-empty income bucket (contra-income)" $ do
      let total = unsafeMoney USD 500
          Right allocs =
            Core.mkAllocations
              [Allocation salaryCat (unsafeMoney USD 100)]
              [Allocation rentCat (unsafeMoney USD 400)]
      Core.mkExpense total allocs `shouldBe` Left ContraIncomeNotSupported

    it "rejects both-empty allocations with AllocationsEmpty" $ do
      Core.mkAllocations [] [] `shouldBe` Left AllocationsEmpty

    it "rejects a combined sum mismatch" $ do
      let total = unsafeMoney USD 5500
          Right allocs =
            Core.mkAllocations
              [Allocation salaryCat (unsafeMoney USD 5000)]
              [Allocation rentCat (unsafeMoney USD 400)]   -- 5400 ≠ 5500
      case Core.mkIncome total allocs of
        Left (ValidationErr ve) -> ve.validationField `shouldBe` "allocations"
        other -> expectationFailure $ "expected sum ValidationErr, got " <> show other
```
Add `salaryCat`/`rentCat`/`isRight` helpers near the existing `groceryStaples` fixtures.

- [ ] **Step 2: Redefine `Allocations` + `Allocation` JSON in `Types.hs`**

Replace `type Allocations = NonEmpty Allocation` (line 994) with:

```haskell
-- | The categorised side of a transaction, split into two buckets by the
-- dictionary the categories come from. The contra effect (a reimbursement
-- reducing an expense category) is derived from bucket + flow direction —
-- never a negative amount. Build via 'mkAllocations'.
data Allocations = Allocations
  { incomes :: [Allocation],   -- categories from the income-category dict
    expenses :: [Allocation]   -- categories from the expense-category dict
  }
  deriving (Show, Eq, Generic)

instance ToJSON Allocations

instance FromJSON Allocations

-- | All allocations regardless of bucket — the categorised lines as a flat list.
allAllocations :: Allocations -> [Allocation]
allAllocations a = a.incomes <> a.expenses

-- | Smart constructor. Enforces only the cross-bucket structural invariant
-- (not both empty); per-allocation positivity, currency, and sum-vs-total
-- are checked against an anchor amount by 'validateAllocations' /
-- 'mkIncome' / 'mkExpense'. Kind-agnostic by design — directional rules
-- (no contra-income) live in the constructors/handler.
mkAllocations :: [Allocation] -> [Allocation] -> Either DomainError Allocations
mkAllocations incs exps
  | null incs && null exps = Left AllocationsEmpty
  | otherwise = Right (Allocations incs exps)
```

- [ ] **Step 3: Rewrite `validateAllocations` (anchored, folds both buckets)**

Replace the body (lines 1090-1131) so it uses `allAllocations` and the anchor's currency, with no `NE.head`:

```haskell
validateAllocations :: Money -> Allocations -> Either DomainError ()
validateAllocations expectedTotal a =
  checkNotEmpty *> checkPositive *> checkCurrency *> checkSum
  where
    xs = allAllocations a
    expectedCurrency = expectedTotal.currency

    checkNotEmpty
      | null xs = Left AllocationsEmpty
      | otherwise = Right ()

    checkPositive = case filter (\x -> x.amount.amount <= 0) xs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError "amount" "Allocation amount must be positive" (T.pack (show bad.amount.amount))

    checkCurrency = case filter (\x -> x.amount.currency /= expectedCurrency) xs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError "currency" "All allocations must share the categorised currency" (T.pack (show bad.amount.currency))

    checkSum =
      let s = Money (sum (fmap (\x -> x.amount.amount) xs)) expectedCurrency
       in if s == expectedTotal
            then Right ()
            else Left . ValidationErr $
              mkValidationError "allocations" "Sum of allocations must equal categorised amount" (T.pack (show s.amount))
```

- [ ] **Step 4: Update `mkIncome` / `mkExpense` (contra rule on Expense)**

```haskell
mkIncome :: Money -> Allocations -> Either DomainError TransactionType
mkIncome categorisedTotal a = do
  validateAllocations categorisedTotal a
  pure (Income a)

mkExpense :: Money -> Allocations -> Either DomainError TransactionType
mkExpense categorisedTotal a = do
  validateAllocations categorisedTotal a
  if null a.incomes
    then pure (Expense a)
    else Left ContraIncomeNotSupported
```

- [ ] **Step 5: Keep `allocationsOf`/`replaceAllocations`; delete rescale + sum + categorisedAmount**

`allocationsOf` and `replaceAllocations` keep the same code (they now traffic in the record). **Delete** these definitions entirely: `sumAllocationsUnchecked` (1072-1077), `categorisedAmount` (1056-1061), `rescaleAllocations` (1144-1161), `rescaleTransactionType` (1163-1170), and `allSameCurrency` if it becomes unused (check after step 9). Keep `isCategorised` if present. Also scrub dangling doc references to the deleted functions — the `mkIncome`/`mkExpense` haddock (~lines 1185-1206) mentions `categorisedAmount`; reword it (Step 4 rewrites these anyway).

- [ ] **Step 6: Update the module export list**

In the `-- * Transfer Types` export block: remove `categorisedAmount`, `sumAllocationsUnchecked`, `rescaleAllocations`, `rescaleTransactionType` (and `allSameCurrency` if deleted). Add `mkAllocations`, `allAllocations`. Keep `Allocations` (now the record — export it as `Allocations (..)` so `incomes`/`expenses` field accessors are available with `NoFieldSelectors`/`OverloadedRecordDot`; match how other records in this module are exported).

- [ ] **Step 7: LiquidHaskell**

Leave the per-allocation `{m : Money | (amount m) > 0}` refinement on `Allocation` unchanged. Do **not** add a new refinement for the record now (the not-both-empty invariant is the runtime smart-constructor's job). If LH complains about the deleted `{-@ reflect sumAllocationsUnchecked @-}` pragma, remove that pragma too.

- [ ] **Step 8: Fix `CommandHandler.hs`**

Rewrite `checkAllocationsAgainst` (396-424) to fold `allAllocations` and return `TransactionError`, including a not-empty check:

```haskell
checkAllocationsAgainst :: Money -> Allocations -> Either TransactionError ()
checkAllocationsAgainst expected a =
  checkNotEmpty *> checkCurrency *> checkSum *> checkPositive
  where
    xs = allAllocations a
    expectedCurrency = moneyCurrency expected
    checkNotEmpty = if null xs then Left AllocationsEmpty else Right ()
    checkCurrency = if all (\x -> x.amount.currency == expectedCurrency) xs then Right () else Left AllocationCurrencyMismatch
    checkSum = if Money (sum (fmap (\x -> x.amount.amount) xs)) expectedCurrency == expected then Right () else Left AllocationsDoNotSumToTotal
    checkPositive = if all (\x -> unMoney x.amount > 0) xs then Right () else Left AllocationAmountNotPositive
```

In the `InitiateTransaction` arm (177-212), add the contra check on the Expense branch:

```haskell
                  case transactionType of
                    Income allocs -> checkAllocationsAgainst targetAmount allocs
                    Expense allocs ->
                      checkAllocationsAgainst sourceAmount allocs
                        *> (if null allocs.incomes then Right () else Left ContraIncomeNotSupported)
                    Transfer -> Right ()
                    Adjustment -> Right ()
```

In the `SetTransactionAllocations` arm (250-266), **re-anchor** to the transaction's own amount and preserve the contra rule:

```haskell
        Just _ -> do
          existingTotal <- case transaction.transactionType of
            Income _ -> Right transaction.targetAmount
            Expense _ -> Right transaction.sourceAmount
            _ -> Left CannotSetAllocationsOnUncategorisedTransaction
          checkAllocationsAgainst existingTotal newAllocations
          -- bind the contra guard so it short-circuits in Either
          _ <- case transaction.transactionType of
            Expense _ | not (null newAllocations.incomes) -> Left ContraIncomeNotSupported
            _ -> Right ()
          Right
            [ TransactionAllocationsChangedTransactionEvent
                TransactionAllocationsChanged
                  { transactionId = transactionId, newAllocations = newAllocations }
            ]
```
(Confirm `Transaction` exposes `targetAmount`/`sourceAmount`; the `InitiateTransaction` arm already reads `transaction.sourceAmount`. Note `checkAllocationsAgainst` returns `Either TransactionError` and is used in `do`-notation here — that already short-circuits.)

- [ ] **Step 9: Fix `TransactionService.hs`**

(a) Imports (75-105): remove `rescaleAllocations`, `sumAllocationsUnchecked`; add `mkAllocations` only if used (it isn't here — the web layer builds the record). Keep `mkIncome`, `mkExpense`, `allocationsOf`, `kindOf`, `deriveTransactionKind`.

(b) Make `validateAllocationsAgainstDictionary` per-bucket and kind-agnostic:

```haskell
validateAllocationsAgainstDictionary ::
  UserId -> Allocations -> AppM (Either DomainError ())
validateAllocationsAgainstDictionary userId a = runExceptT $ do
  cfg <- ExceptT (ConfigurationService.getConfigurationForUser userId)
  let incomeKnown = dictionaryEntryIds ConfigurationService.incomeCategoryDictId cfg
      expenseKnown = dictionaryEntryIds ConfigurationService.expenseCategoryDictId cfg
      badIncome = filter (\x -> not (Set.member x.categoryId incomeKnown)) a.incomes
      badExpense = filter (\x -> not (Set.member x.categoryId expenseKnown)) a.expenses
  case badIncome <> badExpense of
    [] -> pure ()
    (bad : _) -> throwE (CategoryNotFound (tshow (unDictionaryEntryId bad.categoryId)))
```
Update its three call sites (`initiateIncome`, `initiateExpense`, `synthesiseAmendmentTransactionType`, `setTransactionAllocations`) to drop the `TransactionKind` argument. `pickCategoryDictForKind` is now unused → delete it (keep `pickCategoryDict` used by `setTransactionAllocations`'s uncategorised guard).

(c) Rewrite `synthesiseAmendmentTransactionType` (778-815) — no rescale; require explicit allocations for categorised kinds, validating via the smart constructors:

```haskell
synthesiseAmendmentTransactionType userId derivedKind _existingTT cmd = runExceptT $
  case (cmd.newAllocations, derivedKind) of
    (Just allocs, IncomeKind) -> do
      ExceptT (validateAllocationsAgainstDictionary userId allocs)
      ExceptT (pure (mkIncome cmd.newTargetAmount allocs))
    (Just allocs, ExpenseKind) -> do
      ExceptT (validateAllocationsAgainstDictionary userId allocs)
      ExceptT (pure (mkExpense cmd.newSourceAmount allocs))
    (Just _, TransferKind) -> throwE AllocationsNotAllowedForTransferKind
    (Just _, AdjustmentKind) -> throwE CannotAmendToAdjustmentKind
    (Nothing, IncomeKind) -> throwE AllocationsRequiredForCategorisedKind
    (Nothing, ExpenseKind) -> throwE AllocationsRequiredForCategorisedKind
    (Nothing, TransferKind) -> pure Transfer
    (Nothing, AdjustmentKind) -> throwE CannotAmendToAdjustmentKind
```
(`mkIncome`/`mkExpense` return `Either DomainError TransactionType`, so `ExceptT (pure …)` threads the validation+construction in one shot. The `_existingTT` parameter is now intentionally unused — keep the leading underscore so `-Werror` stays clean; do not "restore" it.)

(d) `initiateIncome`/`initiateExpense` (237-350): change the `validateAllocationsAgainstDictionary` calls to drop the kind arg; everything else (the `mkIncome`/`mkExpense` calls) is unchanged since those take the `Allocations` record.

- [ ] **Step 10: Redesign create DTOs in `Web/Types.hs`**

Add Double-based web DTOs (consistent with the rest of the create API — the create endpoints use `Double`+`currency`, not domain `Money` JSON), and replace the single `category :: Text` on `IncomeRequest`/`ExpenseRequest` (lines 333-364) with a two-bucket allocations payload:

```haskell
-- | One category slice as sent by the create API (Double-based, like the
-- rest of the create DTOs).
data CategoryAmount = CategoryAmount
  { category :: UUID,
    amount :: Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON CategoryAmount
instance FromJSON CategoryAmount

-- | Two-bucket allocations on a create request. For income both buckets
-- may be populated (the expenses bucket is a reimbursement); for expense
-- the incomes bucket must be empty (enforced downstream by mkExpense →
-- ContraIncomeNotSupported).
data AllocationsRequest = AllocationsRequest
  { incomes :: [CategoryAmount],
    expenses :: [CategoryAmount]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AllocationsRequest
instance FromJSON AllocationsRequest

data IncomeRequest = IncomeRequest
  { accountId :: UUID,
    currency :: Text,
    allocations :: AllocationsRequest,
    description :: Text,
    date :: Maybe UTCTime,
    labels :: Maybe [UUID]
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeRequest
instance FromJSON IncomeRequest

-- ExpenseRequest: identical shape (accountId, currency, allocations,
-- description, date, labels). Drop the old `amount :: Double` and
-- `category :: Text`; the total is the sum of allocation amounts.
```
(Both lose `amount :: Double` — the categorised total is derived as the sum of the allocation slices.)

`transactionTypeAllocationsText` (locate by name, ~line 987): replace `toList allocs` with `allAllocations allocs`:

```haskell
transactionTypeAllocationsText tt = case allocationsOf tt of
  Nothing -> []
  Just allocs ->
    [ T.pack $ UUID.toString $ unDictionaryEntryId a.categoryId | a <- allAllocations allocs ]
```
`transactionTypeCategoryText` is unchanged (head of that list). `SetTransactionAllocationsRequest`/`AmendTransactionRequest` reference domain `Allocations` directly and pick up the new record JSON automatically (left as-is — already two-bucket via the type). Add `allAllocations` to the `Domain.Core.Types` import list.

- [ ] **Step 11: Rewrite create handlers in `Web/API/TransactionAPI.hs`**

`incomeHandler` (lines 235-251) and `expenseHandler` (253-270) currently do `mkAllocation … >>= NE.singleton`. Replace with a builder that maps each `CategoryAmount` to a domain `Allocation` and assembles the two-bucket `Allocations`. Add a shared helper:

```haskell
-- maps the request buckets into a validated domain Allocations + total
buildAllocations :: Currency -> AllocationsRequest -> Either DomainError (Money, Allocations)
buildAllocations cur req = do
  incs <- traverse (toAlloc cur) req.incomes
  exps <- traverse (toAlloc cur) req.expenses
  allocs <- mkAllocations incs exps
  let total = Money (sum [a.amount.amount | a <- allAllocations allocs]) cur
  pure (total, allocs)
  where
    toAlloc c ca = mkAllocation (unsafeDictionaryEntryId ca.category) (toDomainMoney c ca.amount)
```
Then `incomeHandler`:

```haskell
incomeHandler user request = do
  let userId = user.userId
  validateDateNotInFuture request.date
  accountId <- validateField "accountId" $ mkAccountId request.accountId
  cur <- validateField "currency" $ parseCurrency request.currency
  (total, allocations) <- either throwDomainError pure (buildAllocations cur request.allocations)
  labelSet <- validateField "labels" $ parseLabelIds request.labels
  result <- TransactionService.initiateIncome userId accountId total allocations labelSet request.description request.date
  case result of
    Right (txId, transaction) -> pure $ fromTransactionData txId transaction
    Left err -> throwDomainError err
```
`expenseHandler` is identical but calls `initiateExpense` (the empty-incomes / contra rule is enforced by `mkExpense` inside `initiateExpense`). Confirm `parseCategoryId` is no longer needed here (it may still be used elsewhere; only remove the import if unused). Adjust imports (`mkAllocations`, `allAllocations`, `Money`, `unsafeDictionaryEntryId`).

- [ ] **Step 12: Fix `ReadModels/Transaction.hs`**

`referencesInAllocations` (~line 507) folds an `Allocations` value via `NE.toList allocs`. Change to `allAllocations allocs`. Add `allAllocations` to its `Domain.Core.Types` import. Nothing else in this file changes (it stores `TransactionType` opaquely and uses `replaceAllocations`, both unchanged).

- [ ] **Step 13: Fix test generators (`Testkit/Generators.hs`)**

Replace `genAllocationsSummingTo`/`partitionMoneyExact` to return `[Allocation]`, and rebuild `genTransactionType` for two buckets:

```haskell
-- list of positive allocations summing exactly to total (residual on first)
partitionMoneyExact :: Rational -> Currency -> [DictionaryEntryId] -> [Allocation]
partitionMoneyExact _ _ [] = []
partitionMoneyExact totalRat cur (c : cs) =
  let n = 1 + length cs
      slice = totalRat / fromIntegral n
      residual = totalRat - slice * fromIntegral n
   in Allocation c (unsafeMoney cur (slice + residual))
        : fmap (\ci -> Allocation ci (unsafeMoney cur slice)) cs

genAllocationListSummingTo :: Money -> Gen [Allocation]
genAllocationListSummingTo total = do
  n <- choose (1, 4 :: Int)
  cids <- vectorOf n genDictionaryEntryId
  pure (partitionMoneyExact (unMoney total) (moneyCurrency total) cids)

genTransactionType :: Gen TransactionType
genTransactionType =
  oneof [buildIncome, buildExpense, pure Transfer, pure Adjustment]
  where
    buildIncome = do
      total <- genPositiveMoney
      -- optionally carve a contra-expense slice out of the income total
      mixed <- arbitrary
      (incs, exps) <-
        if mixed
          then do
            -- split total into income part + expense (reimbursement) part
            let cur = moneyCurrency total; t = unMoney total
            -- keep both > 0
            incPart <- pure (t * 3 / 4); expPart <- pure (t - t * 3 / 4)
            ic <- genDictionaryEntryId; ec <- genDictionaryEntryId
            pure ([Allocation ic (unsafeMoney cur incPart)], [Allocation ec (unsafeMoney cur expPart)])
          else do
            i <- genAllocationListSummingTo total; pure (i, [])
      case Core.mkAllocations incs exps >>= Core.mkIncome total of
        Right tt -> pure tt
        Left _ -> pure Transfer
    buildExpense = do
      total <- genPositiveMoney
      exps <- genAllocationListSummingTo total
      case Core.mkAllocations [] exps >>= Core.mkExpense total of
        Right tt -> pure tt
        Left _ -> pure Transfer
```
Adjust imports (`Core.mkAllocations`, `allAllocations` if used). Keep the `Arbitrary Allocation` instance.

- [ ] **Step 14: Migrate existing tests that reference removed APIs / old shape**

These are **not** all mechanical — some test functions that no longer exist and must be **deleted or rewritten**, not repaired. Handle each explicitly (locate by grep, lines may have drifted):

| File | Reference | Disposition |
|------|-----------|-------------|
| `test/Domain/Core/TransactionTypePropertySpec.hs` (`genValid`, ~33-39) | `genValid :: Gen (Money, Allocations)` builds a `NonEmpty` via `partitionMoney … (NE.fromList cids)` | **Rewrite** to produce a record-shaped `(Money, Allocations)` (e.g. all slices in the `incomes` bucket, `expenses = []`). This generator feeds every prop in the file. |
| `test/Domain/Core/TransactionTypePropertySpec.hs` (~62-87) | three perturbation props (`rejects … sum ≠ total`, `… currency mismatch`, `… non-positive`) mutate the `NonEmpty` via `NE.uncons`/`NE.:|` | **Rewrite** each to perturb one bucket of the record and assert the same `ValidationErr` field — these are valid behavior tests, not deletions. |
| `test/Domain/Core/TransactionTypePropertySpec.hs` (~94-95) | `categorisedAmount tt === fmap sumAllocationsUnchecked …` | **Delete** this property — it tests removed functions. |
| `test/Domain/Core/TransactionTypePropertySpec.hs` (~103) | `allSameCurrency` describe block | **Delete** if `allSameCurrency` was removed; otherwise update to fold both buckets. |
| `test/Application/Services/TransactionAllocationsIntegrationSpec.hs` (~52, 134-138) | `sumAllocationsUnchecked` in a `categorisedTotal` helper (with a partial `error`) | **Rewrite** the helper to sum `allAllocations` inline against the known currency; drop the partial `error`. |
| `test/Domain/Transaction/AmendmentPropertySpec.hs` (~283-284, also `NE.toList` ~294-300 and `mkIncome`/`mkExpense` ~357-364) | "allocations sum to new amount" under rescale; NonEmpty construction | **Adjust**: amendment no longer rescales — the generator must now supply `newAllocations` (record) summing to the new amount; assert that holds. Rewrite the `NE.` construction sites to `mkAllocations`. |
| `test/Domain/Transaction/CommandHandlerPropertySpec.hs` (~271) | `completedTxWithType` helper uses the **deleted** `categorisedAmount` (`fromMaybe (mockMoney 100) (categorisedAmount tt)`) | **Rewrite** the helper to derive the total by summing `allAllocations` of the type's allocations (via `allocationsOf`) — there is no record-API replacement for `categorisedAmount`. |
| `test/Domain/Transaction/AllocationsSpec.hs` (~74-121) | `:|`/`NonEmpty` `mkIncome`/`mkExpense` cases | **Rewrite** to `mkAllocations [..] [..]` construction (the length-1 case becomes `mkAllocations [a] []` for income / `[]`+`[a]` for expense). |

Then run `cabal build -fci` repeatedly and fix any remaining site (leftover `NE.`/`:|` construction, `rescale*` references, exhaustiveness warnings, other `NE.toList`/`toList` folds over an `Allocations`). Each remaining error is mechanical — match the new record API. Do **not** re-introduce a partial `head` over allocations.

- [ ] **Step 15: Green build + run tests**

Run: `cabal build -fci` → Expected: PASS (no warnings, -Werror clean).
Run: `cabal test all --test-option='--match' --test-option="/Allocations/"` → Expected: PASS (new two-bucket tests green).
Run: `just test` → Expected: PASS (existing suite still green; generator changes keep property tests valid).

- [ ] **Step 16: Format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "feat(transaction): two-bucket Allocations for contra-expense reimbursements

Allocations becomes { incomes, expenses }; reimbursement = Income with a
non-empty expenses bucket. Amounts stay > 0. Amount-changing amendments
now require explicit allocations (rescale deleted). Sum/currency checks
anchor to the transaction amount. Supersedes the rescale mechanism in the
2026-05-30 allocations spec."
```

---

### Task 3: Handler-level contra + set-allocations re-anchoring tests

**Files:**
- Test: `test/Domain/Transaction/AllocationsSpec.hs` (or a `CommandHandlerSpec`)

- [ ] **Step 1: Write failing tests**

Using the existing `completedTransfer`/handler fixtures, add:
- `InitiateTransaction` with `Expense` whose allocations have a non-empty income bucket → `Left ContraIncomeNotSupported`.
- `SetTransactionAllocations` on a completed `Income` whose existing `targetAmount` is the anchor: new allocations summing to `targetAmount` (not to the old allocation sum) → `Right [...AllocationsChanged...]`; a set that sums to the old allocation total but not `targetAmount` → `Left AllocationsDoNotSumToTotal`.
- `SetTransactionAllocations` on a completed `Expense` with a non-empty income bucket → `Left ContraIncomeNotSupported`.

- [ ] **Step 2: Run → expect FAIL** (`cabal test all --test-option='--match' --test-option="/Allocations/"`). If they already pass, the Task 2 implementation covered them — verify the assertions are meaningful, then proceed.

- [ ] **Step 3: Implement** any gap surfaced (should be none if Task 2 step 8 is complete).

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit** `test(transaction): handler contra-income and re-anchored set-allocations`.

---

### Task 4: Amendment requires explicit allocations (service + integration)

**Files:**
- Test: an existing amendment integration spec (`test/.../*AmendmentIntegrationSpec.hs`) — locate with `grep -rln "amendTransaction\|AmendTransaction" test/`

- [ ] **Step 1: Write failing tests**
- Amend an `Income` transaction's `newTargetAmount` with `newAllocations = Just <record summing to new amount>` → succeeds; the `TransactionData.transactionType` reflects the new buckets and `amendmentCount` bumps.
- Amend a categorised transaction's amount with `newAllocations = Nothing` → `Left AllocationsRequiredForCategorisedKind`.
- Amend with `newAllocations` whose combined sum ≠ new amount → `Left AllocationsDoNotSumToTotal`.

- [ ] **Step 2: Run → expect FAIL** (red for the right reason).
- [ ] **Step 3: Implement** any gap (should be covered by Task 2 step 9c; otherwise fix `synthesiseAmendmentTransactionType`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `test(transaction): amendment requires explicit allocations on amount change`.

---

### Task 5: End-to-end contra-expense posting & netting (integration)

**Files:**
- Test: new `test/Application/Services/ContraExpenseIntegrationSpec.hs` (placed alongside the other service-layer `*IntegrationSpec.hs` since it drives the Application service layer; uses the in-memory event store from `Testkit/InMemoryEventStore.hs`)

- [ ] **Step 1: Write failing tests**
- Post a mixed `Income` ($5000 salary + $500 rent reimbursement, target $5500) end-to-end; assert the credited account balance moved by **$5500 only** (posting ignores buckets) and the stored `TransactionData` carries both buckets intact.
- Post that, then post a $500 rent `Expense`; assert per-category netting via the documented contract helper (compute in-test): `expenseNet(Rent) = Σ(expense bucket on Expense) − Σ(expense bucket on Income) = 0`.
- Post a standalone refund (`Income`, empty incomes, $40 expenses) → account balance +$40, `expenseNet(category) = −40` if no prior spend.

- [ ] **Step 2: Run → expect FAIL.**
- [ ] **Step 3: Implement** any gap (expected: none in `src/`; this validates the whole flow).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** `test(transaction): end-to-end contra-expense posting and per-category netting`.

---

### Task 6: Final verification gate

- [ ] **Step 1:** `cabal build -fci` → PASS (no warnings).
- [ ] **Step 2:** `just test` → PASS (full suite).
- [ ] **Step 3:** `just check` (format + lint) → clean; no hlint suppressions added.
- [ ] **Step 4:** Skim the diff for any surviving `rescale`/`sumAllocationsUnchecked`/`NE.head`-over-allocations references: `grep -rn "rescale\|sumAllocationsUnchecked" src/` → expect no hits.
- [ ] **Step 5:** Update `docs/specs/2026-06-11-contra-expense-allocations-design.md` frontmatter `status: draft` → `status: completed`. Commit `docs(transaction): mark contra-expense spec completed`.

---

## Definition of done

- `Allocations` is the two-bucket record; reimbursement = `Income` with a non-empty `expenses` bucket; amounts always `> 0`.
- `mkExpense` rejects non-empty income buckets (`ContraIncomeNotSupported`); `mkAllocations` rejects both-empty (`AllocationsEmpty`).
- Amount-changing amendments require explicit allocations; `rescaleAllocations`/`rescaleTransactionType`/`sumAllocationsUnchecked`/`categorisedAmount` are gone.
- `SetTransactionAllocations` retained, two-bucket, anchored to the transaction amount.
- All sum/currency checks anchor to the transaction `Money`; no partial `head` over allocations.
- Sagas, balances, overdraft logic unchanged.
- `cabal build -fci` clean; full suite green; ormolu + hlint clean.
