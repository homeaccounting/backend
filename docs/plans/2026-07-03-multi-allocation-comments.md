# Multi-Allocation NL Expenses with Per-Allocation Comments — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `comment :: Maybe Text` field to the `Allocation` domain type, thread it through every allocation-carrying flow (create income/expense, set-allocations, amend, NL prompt), and reshape NL extraction so one prompt yields a per-line list of allocations resolved independently.

**Architecture:** Domain-first. `Allocation` gains `comment`; the generic `ToJSON`/`FromJSON` instances and the manual persistence codecs are updated; web DTOs and the NL intent/resolver are threaded. Because changing the `Allocation` constructor arity and the `mkAllocation` signature cascades across the whole tree, the first task bundles the type change with mechanical `Nothing`-threading at all non-behavioral call sites so the project compiles; later tasks layer behavior + tests.

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Servant, Aeson, Hspec + QuickCheck, LiquidHaskell, Eventium (event sourcing). Build via `just build`, test via `just test`. Spec: `docs/specs/2026-07-03-multi-allocation-comments-design.md`.

**Conventions (from CLAUDE.md / memory):**
- No backward-compat phase — event/DTO shapes may change freely; no upcasters.
- `-fci` (`-Werror`) is enforced over lib+exe+test; warm `.o` cache can mask it — use `just rebuild` for a definitive check before finishing.
- ormolu formats operator chains onto own lines in `NoImplicitPrelude` modules — don't fight it; run `just format`.
- Never export data constructors or field selectors — smart constructors + accessors only.
- `NoFieldSelectors` + `DuplicateRecordFields`: when a field name is shared across records in one module, prefer positional destructure over `x.field` (HasField gotcha). `IntentAllocation.amount` shares `amount` with `TransactionIntent.amount` — verify record-dot resolves; fall back to positional if it doesn't.
- Full `cabal test all` needs a manually-created `eventium_test` Postgres DB; ~28 integration failures without it are environmental, not regressions.

---

## File Structure

**Domain**
- `src/Domain/Core/Types.hs` — `Allocation` type + LH refinement + `mkAllocation` (signature change).

**Persistence**
- `src/Infrastructure/Database/Orphans.hs` — `allocToValue` / `allocParser`.

**Web**
- `src/Web/Types.hs` — `CategoryAmount` (request), `AllocationResponse` (response), `allocationsResponseOf`.
- `src/Web/API/TransactionAPI.hs` — `buildAllocations` / `toAlloc`.

**NL prompting**
- `src/Application/Services/Prompt/Transaction/Intent.hs` — `IntentAllocation`, `TransactionIntent`, parser, schema, guide.
- `src/Application/Services/Prompt/Transaction/Resolve.hs` — per-line resolution, list `buildAllocations`, transfer amount.

**Mechanical `Nothing`-threading call sites (Task 1)**
- `src/Domain/Transaction/Projection.hs` (placeholder alloc)
- `src/Application/Services/BankImportService.hs`
- `src/Telegram/Commands.hs`
- `test/Testkit/Generators.hs`

**Tests**
- `test/Domain/Core/AllocationPropertySpec.hs`
- `test/Domain/Transaction/AllocationsSpec.hs`
- `test/Application/Services/Prompt/Transaction/ResolveSpec.hs`
- `test/Infrastructure/Llm/OpenAICompatSpec.hs` (only if intent-encoding assertions live here; otherwise a new/So existing intent spec)
- `test/Integration/TransactionPromptIntegrationSpec.hs`
- Reporting spec (locate existing `ReportingService` spec).

---

## Task 1: Domain — `Allocation.comment` + `mkAllocation`, compile the tree

**Files:**
- Modify: `src/Domain/Core/Types.hs:1040-1075`
- Modify (mechanical): `src/Domain/Transaction/Projection.hs`, `src/Application/Services/BankImportService.hs`, `src/Telegram/Commands.hs`, `test/Testkit/Generators.hs`
- Test: `test/Domain/Core/AllocationPropertySpec.hs`

- [ ] **Step 1: Write failing tests for `mkAllocation` comment behavior**

Add to `test/Domain/Core/AllocationPropertySpec.hs` (adapt imports/helpers to the file's style):

```haskell
-- a valid comment passes through unchanged
it "preserves a non-blank comment" $ do
  let Right m = mkDefaultMoney 10
      cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
  fmap (.comment) (mkAllocation cid m (Just "огірки розсада"))
    `shouldBe` Right (Just "огірки розсада")

-- blank / whitespace-only normalizes to Nothing
it "normalizes a blank comment to Nothing" $ do
  let Right m = mkDefaultMoney 10
      cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
  fmap (.comment) (mkAllocation cid m (Just "   ")) `shouldBe` Right Nothing
  fmap (.comment) (mkAllocation cid m (Just "")) `shouldBe` Right Nothing

-- Nothing stays Nothing; positivity still enforced
it "keeps Nothing and still rejects non-positive amounts" $ do
  let cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
      Right bad = mkMoney USD (-1)
  fmap (.comment) (mkAllocation cid (unsafeMoney USD 5) Nothing) `shouldBe` Right Nothing
  mkAllocation cid bad Nothing `shouldSatisfy` isLeft
```

- [ ] **Step 2: Run to verify failure**

Run: `cabal test --test-option='--match' --test-option='/Domain.Core.AllocationProperty/'`
Expected: compile error (arity mismatch on `mkAllocation`) — this is the expected "red".

- [ ] **Step 3: Change the domain type + smart constructor**

In `src/Domain/Core/Types.hs`, update the LH block, the data decl, and `mkAllocation`:

```haskell
{-@
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: {m : Money | (amount m) > 0}
  , comment    :: Maybe Text
  }
@-}
data Allocation = Allocation
  { categoryId :: CategoryId,
    amount :: Money,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)
```

```haskell
-- | Smart constructor for an 'Allocation'. Enforces @amount > 0@; the
-- optional comment is trimmed and blank text normalizes to 'Nothing'.
mkAllocation :: CategoryId -> Money -> Maybe Text -> Either DomainError Allocation
mkAllocation cid m mcomment
  | unMoney m > 0 = Right (Allocation cid m (normalizeComment mcomment))
  | otherwise =
      Left . ValidationErr $
        mkValidationError
          "amount"
          "Allocation amount must be positive"
          (T.pack (show (unMoney m)))

-- | Trim a comment; blank / whitespace-only becomes 'Nothing'.
normalizeComment :: Maybe Text -> Maybe Text
normalizeComment mt = do
  t <- mt
  let s = T.strip t
  if T.null s then Nothing else Just s
```

Update the Haddock doctest for `mkAllocation` (the `>>> mkAllocation c m` example) to pass a third arg `Nothing` and reflect the new `Show` output (now includes `comment = Nothing`). If matching the doctest string is fiddly, simplify or drop the doctest result line — do not leave a failing doctest.

Do NOT export the `Allocation` constructor or `normalizeComment` unless the module already exports internal helpers; keep `mkAllocation` / accessors exported as before. (Record dot `.comment` works without exporting a selector under `NoFieldSelectors`.)

- [ ] **Step 4: Thread `Nothing` through mechanical call sites to restore compilation**

Update each non-behavioral `mkAllocation` / `Allocation` constructor call to pass a comment:

- `src/Domain/Transaction/Projection.hs` — placeholder: `mkAllocation (unsafeDictionaryEntryId nil) placeholderUnit Nothing`.
- `src/Application/Services/BankImportService.hs` — the `mkAllocation` call(s) → add `Nothing`.
- `src/Telegram/Commands.hs` — the `mkAllocation` call(s) → add `Nothing`.
- `test/Testkit/Generators.hs`:
  - `Arbitrary Allocation`: `Allocation <$> arbitrary <*> genPositiveMoney <*> genMaybeComment`
    where `genMaybeComment = oneof [pure Nothing, Just <$> elements ["овочі","квіти","яйця","misc"]]`.
  - `partitionMoneyExact`: the two `Allocation c (unsafeMoney ...)` constructions → append `Nothing`.
  - `genTransactionType`: the inline `Allocation ic ...` / `Allocation ec ...` → append `Nothing`.

(Note: the resolver `Resolve.hs` and web `TransactionAPI.hs` also call `mkAllocation` — leave them broken for now ONLY if you can't compile; simplest is to also add `Nothing` there provisionally, then Tasks 3/5 replace them. Prefer: touch them minimally here so the tree compiles, then rework in their own tasks.)

- [ ] **Step 5: Format, run domain tests**

Run: `just format` then `cabal test --test-option='--match' --test-option='/Domain.Core.AllocationProperty/'`
Expected: PASS.

- [ ] **Step 6: Full build to confirm the tree compiles**

Run: `just build`
Expected: builds clean (no `-Werror` failures). If ormolu reformats, re-run `just format`.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(domain): Allocation gains optional comment (#27)"
```

---

## Task 2: Persistence — tolerant `comment` codec in Orphans

**Files:**
- Modify: `src/Infrastructure/Database/Orphans.hs:225-232`
- Test: reuse an existing Orphans/round-trip spec if present; else add a focused unit test near the persistence tests.

- [ ] **Step 1: Write a failing round-trip test**

Assert `allocParser . allocToValue` preserves a comment, and that a legacy object without the `comment` key parses to `comment = Nothing`. Example (adapt to the test module that already imports `allocToValue`/`allocParser`, or test via the public `Allocations` JSON if those are not exported):

```haskell
it "round-trips an allocation comment and tolerates a missing key" $ do
  let Right a = mkAllocation cid (unsafeMoney USD 5) (Just "квіти")
  parseMaybe allocParser (allocToValue a) `shouldBe` Just a
  -- legacy shape without comment
  let legacy = object ["categoryId" .= a.categoryId, "amount" .= moneyToValue a.amount]
  fmap (.comment) (parseMaybe allocParser legacy) `shouldBe` Just Nothing
```

- [ ] **Step 2: Run — expect failure** (`comment` not emitted/parsed yet).

- [ ] **Step 3: Update the codec**

```haskell
allocToValue :: Allocation -> Value
allocToValue (Allocation cid amt cmt) =
  object ["categoryId" .= cid, "amount" .= moneyToValue amt, "comment" .= cmt]

allocParser :: Value -> Parser Allocation
allocParser = withObject "Allocation" $ \o -> do
  cid <- o .: "categoryId"
  amt <- (o .: "amount") >>= moneyParser
  cmt <- o .:? "comment"
  pure (Allocation cid amt cmt)
```

Ensure `(.:?)` is imported in Orphans (it imports from `Data.Aeson`/`Data.Aeson.Types` — add if missing). `comment = Nothing` serializes as JSON `null`; the tolerant parser accepts both `null` and an absent key.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Format + commit**

```bash
just format
git add -A
git commit -m "feat(persistence): allocation comment codec, tolerant of missing key (#27)"
```

---

## Task 3: Web DTOs — request `CategoryAmount.comment`, response echo

**Files:**
- Modify: `src/Web/Types.hs:347-355` (`CategoryAmount`), `:540-548` (`AllocationResponse`), `:1132-1144` (`allocationsResponseOf`)
- Modify: `src/Web/API/TransactionAPI.hs:236-244` (`buildAllocations`/`toAlloc`)
- Test: `test/Web/...` — locate the existing Web DTO / transaction handler spec; if none targets these, add unit assertions in the nearest Web spec.

- [ ] **Step 1: Write failing tests**

Two behaviors: (a) `CategoryAmount.comment` flows into the built `Allocation`; (b) `allocationsResponseOf` echoes the comment.

```haskell
it "threads CategoryAmount.comment into the domain allocation" $ do
  let req = AllocationsRequest [] [CategoryAmount catUuid 12.5 (Just "квіти")]
      Right (_total, allocs) = buildAllocations USD req
  map (.comment) allocs.expenses `shouldBe` [Just "квіти"]

it "echoes allocation comment in the response DTO" $ do
  let Right a = mkAllocation cid (unsafeMoney USD 5) (Just "яйця")
      Right tt = mkExpense (unsafeMoney USD 5) =<< mkAllocations [] [a]  -- adapt to real helper
      resp = allocationsResponseOf tt
  map (.comment) resp.expenses `shouldBe` [Just "яйця"]
```

- [ ] **Step 2: Run — expect failure** (field/arg missing).

- [ ] **Step 3: Add `comment` to the request DTO**

`src/Web/Types.hs`:

```haskell
data CategoryAmount = CategoryAmount
  { category :: UUID,
    amount :: Double,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)
```

Generic `FromJSON` treats the `Maybe` field as optional → old clients omitting `comment` still parse.

- [ ] **Step 4: Thread it in `TransactionAPI.hs`**

```haskell
buildAllocations :: Currency -> AllocationsRequest -> Either DomainError (Money, Allocations)
buildAllocations cur req = do
  incs <- traverse (toAlloc cur) req.incomes
  exps <- traverse (toAlloc cur) req.expenses
  allocs <- mkAllocations incs exps
  let total = Money (sum [a.amount.amount | a <- allAllocations allocs]) cur
  pure (total, allocs)
  where
    toAlloc c ca =
      mkAllocation (unsafeDictionaryEntryId ca.category) (toDomainMoney c ca.amount) ca.comment
```

(If Task 1 left a provisional `Nothing` here, replace it with `ca.comment`.)

- [ ] **Step 5: Add `comment` to the response DTO + echo it**

`src/Web/Types.hs`:

```haskell
data AllocationResponse = AllocationResponse
  { categoryId :: Text,
    amount :: Money,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)
```

```haskell
    toAllocationResponse (Allocation cid amt cmt) =
      AllocationResponse
        { categoryId = T.pack $ UUID.toString $ unDictionaryEntryId cid,
          amount = amt,
          comment = cmt
        }
```

- [ ] **Step 6: Run tests — expect PASS.**

- [ ] **Step 7: Build (set-allocations + amend get comments for free via the generic domain `Allocations` JSON — no code change; note it in the commit body).**

Run: `just build`

- [ ] **Step 8: Format + commit**

```bash
just format
git add -A
git commit -m "feat(web): allocation comments on create requests + response echo (#27)

Set-allocations and amend carry comments for free via the domain
Allocations JSON instance (generic, tolerant of a missing key)."
```

---

## Task 4: NL Intent — `IntentAllocation`, reshaped `TransactionIntent`, parser, schema, guide

**Files:**
- Modify: `src/Application/Services/Prompt/Transaction/Intent.hs`
- Test: `test/Application/Services/Prompt/Transaction/IntentSpec.hs` (already has 7 `decodeTransactionIntent` cases).

- [ ] **Step 1: Write failing decoder tests**

This test uses the **full 5-line issue example** so decoding "each line = one allocation + its comment" is proven end-to-end at the decoder level (not just a 2-line sample):

```haskell
it "decodes the 5-line issue example: each line is one allocation with its comment" $ do
  let js = "{\"intent\":\"transaction\",\"kind\":\"expense\",\"currency\":null,\
           \\"sourceAccount\":null,\"targetAccount\":null,\"description\":null,\"date\":null,\
           \\"allocations\":[\
           \{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"огірки розсада\"},\
           \{\"amount\":\"700\",\"category\":null,\"comment\":\"квіти\"},\
           \{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"яйця\"},\
           \{\"amount\":\"500\",\"category\":\"Food\",\"comment\":\"овочі\"},\
           \{\"amount\":\"160\",\"category\":\"Food\",\"comment\":\"огірки зелень\"}]}"
  case decodeTransactionIntent js of
    Right ti -> do
      ti.kind `shouldBe` ExpenseKind
      length ti.allocations `shouldBe` 5
      map (.amount) ti.allocations `shouldBe` ["200","700","200","500","160"]
      map (.comment) ti.allocations
        `shouldBe` map Just ["огірки розсада","квіти","яйця","овочі","огірки зелень"]
    Left e -> expectationFailure (T.unpack e)

it "decodes a transfer with a top-level amount and no allocations" $ do
  let js = "{\"intent\":\"transaction\",\"kind\":\"transfer\",\"amount\":\"200\",\
           \\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\",\"currency\":null,\
           \\"category\":null,\"description\":null,\"date\":null}"
  case decodeTransactionIntent js of
    Right ti -> do ti.kind `shouldBe` TransferKind; ti.amount `shouldBe` Just "200"
    Left e -> expectationFailure (T.unpack e)
```

- [ ] **Step 2: Run — expect failure.**

- [ ] **Step 3: Add `IntentAllocation` and reshape `TransactionIntent`**

```haskell
-- | One line item the model returns for income/expense: an amount (text,
-- any decimal separator), an optional category name, and the original
-- source line as a free-text comment.
data IntentAllocation = IntentAllocation
  { amount :: !Text,
    category :: !(Maybe Text),
    comment :: !(Maybe Text)
  }
  deriving (Show, Eq)

data TransactionIntent = TransactionIntent
  { kind :: !IntentKind,
    -- | Transfer total. Income/expense derive their total from 'allocations';
    -- this stays 'Nothing' for them.
    amount :: !(Maybe Text),
    -- | Line items for income/expense (empty for transfer).
    allocations :: ![IntentAllocation],
    currency :: !(Maybe Text),
    sourceAccount :: !(Maybe Text),
    targetAccount :: !(Maybe Text),
    description :: !(Maybe Text),
    date :: !(Maybe Text)
  }
  deriving (Show, Eq)
```

Export `IntentAllocation (..)` from the module. Remove the old top-level `category` field (it moves into `IntentAllocation`).

> **HasField watch:** `IntentAllocation.amount` and `TransactionIntent.amount` share the name `amount` in this module. Record dot is type-directed so `ti.amount :: Maybe Text` and `ia.amount :: Text` should each resolve. If GHC complains of ambiguity, destructure positionally in the resolver instead of using `.amount` (see memory: HasField + DuplicateRecordFields gotcha).

- [ ] **Step 4: Update the parser**

```haskell
parseAllocation :: Value -> Parser IntentAllocation
parseAllocation = withObject "IntentAllocation" $ \o ->
  IntentAllocation
    <$> o .: "amount"
    <*> o .:? "category"
    <*> o .:? "comment"

parseTransactionFields :: Object -> Parser TransactionIntent
parseTransactionFields o =
  TransactionIntent
    <$> (o .: "kind" >>= parseKind)
    <*> o .:? "amount"
    <*> (fromMaybe [] <$> (o .:? "allocations" >>= traverse (traverse parseAllocation)))
    <*> o .:? "currency"
    <*> o .:? "sourceAccount"
    <*> o .:? "targetAccount"
    <*> o .:? "description"
    <*> o .:? "date"
```

(Adjust operator layout to what ormolu produces — the module currently splits `<*> o .:? "field"` across lines; run `just format`. The `traverse . traverse` reads `allocations` as an optional array of objects; needs a `[Value] -> Parser [IntentAllocation]`; if the nested traverse is awkward, write an explicit `parseAllocations :: Maybe Value -> Parser [IntentAllocation]` helper.)

- [ ] **Step 5: Update `transactionSchema`**

- `required` → `["intent", "kind"]` (amount no longer globally required).
- Replace the `category` property with an `allocations` array property; keep `amount` as a nullable string (transfer uses it):

```haskell
"allocations"
  .= object
    [ "type" .= ("array" :: Text),
      "items"
        .= object
          [ "type" .= ("object" :: Text),
            "required" .= (["amount"] :: [Text]),
            "properties"
              .= object
                [ "amount" .= strType,
                  "category" .= nullableStr,
                  "comment" .= nullableStr
                ]
          ]
    ]
```

- [ ] **Step 6: Update `transactionGuide`**

Rewrite the keys section + examples so the model emits per-line allocations. Key changes to the text:
- Replace the `amount` / `category` key docs with: `amount` (transfer only), `allocations` (income/expense: array of `{amount, category, comment}`), where `comment` is the **original input line verbatim** and `category` is `null` when nothing fits (system picks the default).
- State: "For a multi-line expense/income, produce ONE allocation per line; put that line's raw text in `comment`; the total is the sum of the amounts (do not output a top-level amount for income/expense)."
- Update the few-shot examples to the new shape, e.g.:

```
'cash 123 food' -> {"intent":"transaction","kind":"expense","sourceAccount":"Cash",
  "allocations":[{"amount":"123","category":"Food","comment":"food"}]}
```

and add the multi-line Ukrainian example from the issue (5 lines → 5 allocations, `category` per line with nulls where unknown, each `comment` the original line).

- [ ] **Step 7: Run intent tests — expect PASS. Then `just build`** (Resolve.hs will now fail to compile against the new intent shape — that's Task 5).

- [ ] **Step 8: Format + commit**

```bash
just format
git add src/Application/Services/Prompt/Transaction/Intent.hs test/...
git commit -m "feat(llm): intent carries a per-line allocations list with comments (#27)"
```

---

## Task 5: NL Resolve — per-line category resolution, list allocations, transfer amount

**Files:**
- Modify: `src/Application/Services/Prompt/Transaction/Resolve.hs`
- Test: `test/Application/Services/Prompt/Transaction/ResolveSpec.hs`

- [ ] **Step 1: Write failing resolver tests**

This is the pure-resolver proof of "multi-line prompt → one allocation per line, each carrying its original text as a comment", using the **full 5-line issue example** (mix of matched categories, a no-match line falling back to the default, and duplicate categories that must NOT merge):

```haskell
it "resolves the 5-line example: one allocation per line, comment = original text, no merge" $ do
  let ti = TransactionIntent ExpenseKind Nothing
             [ IntentAllocation "200" (Just "Food") (Just "огірки розсада")
             , IntentAllocation "700" Nothing       (Just "квіти")           -- no match → default "Other"
             , IntentAllocation "200" (Just "Food") (Just "яйця")            -- duplicate Food
             , IntentAllocation "500" (Just "Food") (Just "овочі")           -- duplicate Food
             , IntentAllocation "160" (Just "Food") (Just "огірки зелень")   -- duplicate Food
             ]
             Nothing (Just "Cash") Nothing Nothing Nothing
  case resolveIntent ctxWithDefaultAndFood "prompt" ti of
    Right (ResolvedExpense _ total allocs _ _ _, _) -> do
      length allocs.expenses `shouldBe` 5         -- one per line, no merge despite 4× Food
      map (.comment) allocs.expenses
        `shouldBe` map Just ["огірки розсада","квіти","яйця","овочі","огірки зелень"]
      -- the no-match line resolved to the default category, the rest to Food
      map (.categoryId) allocs.expenses
        `shouldBe` [foodId, otherId, foodId, foodId, foodId]
      unMoney total `shouldBe` 1760               -- 200+700+200+500+160
    other -> expectationFailure (show other)
```

(`ctxWithDefaultAndFood` extends `sampleCtx` with a "Food" expense category and `defaults.expenseCategory = Just otherId` for an "Other" category; bind `foodId`/`otherId` locally.)

it "still resolves a transfer via the top-level amount" $ do
  let ti = TransactionIntent TransferKind (Just "200") []
             Nothing (Just "Cash") (Just "Card") Nothing Nothing
  resolveIntent ctx "p" ti `shouldSatisfy` isRight

it "errors when an income/expense has no allocations" $ do
  let ti = TransactionIntent ExpenseKind Nothing [] Nothing (Just "Cash") Nothing Nothing Nothing
  resolveIntent ctx "p" ti `shouldSatisfy` isLeft
```

(Reuse/extend the existing `ResolveSpec` context builders; the `ctx` must have a default expense category "Other" and a "Food" category.)

- [ ] **Step 2: Run — expect compile failure / red.**

- [ ] **Step 3: Rework `resolveExpense` / `resolveIncome`**

```haskell
resolveExpense ctx prompt ti = do
  (aid, aname, acur) <- resolveAccount ctx "sourceAccount" ti.sourceAccount
  currency <- resolveCurrency acur ti.currency
  lns <- resolveAllocLines currency ctx.expenseCategories ctx.defaults.expenseCategory ti.allocations
  (money, allocs) <- buildAllocations ExpenseKind currency lns
  mdate <- resolveDate ti.date
  let desc = resolveDescription prompt ti.description
      interp =
        "Expense " <> tshow (unMoney money) <> " " <> tshow currency
          <> " from ‘" <> aname <> "’, " <> tshow (length lns) <> " item(s)"
  Right (ResolvedExpense aid money allocs Set.empty desc mdate, interp)
```

Analogous for `resolveIncome` (target account, income categories/default, `ResolvedIncome`, "to '…'").

- [ ] **Step 4: Add per-line resolution + list `buildAllocations`; fix transfer amount**

```haskell
-- | Resolve each line's category (match → default) into (categoryId, money, comment).
resolveAllocLines ::
  Currency ->
  [(CategoryId, Text)] ->
  Maybe CategoryId ->
  [IntentAllocation] ->
  Either ResolveError [(CategoryId, Money, Maybe Text)]
resolveAllocLines currency cats def =
  traverse $ \ia -> do
    money <- resolveAmount currency ia.amount
    cid <- resolveCategory ia.category cats def
    pure (cid, money, ia.comment)

-- | Build the kind's 'Allocations' from resolved lines and derive the total.
buildAllocations ::
  IntentKind ->
  Currency ->
  [(CategoryId, Money, Maybe Text)] ->
  Either ResolveError (Money, Allocations)
buildAllocations kind currency lns = do
  allocs <- traverse (\(cid, m, cmt) -> first toResolveErr (mkAllocation cid m cmt)) lns
  let (incs, exps) = case kind of
        IncomeKind -> (allocs, [])
        _ -> ([], allocs)
  as <- first toResolveErr (mkAllocations incs exps)   -- rejects the empty-list case
  total <- first (ResolveError "amount") (mkMoney currency (sum [unMoney m | (_, m, _) <- lns]))
  pure (total, as)
  where
    toResolveErr err = ResolveError "allocations" (tshow err)
```

`resolveTransfer`: derive money from the now-`Maybe` top-level amount:

```haskell
  amt <- maybe (Left (ResolveError "amount" "transfer needs an amount")) Right ti.amount
  money <- resolveAmount currency amt
```

Add imports: `unMoney` from `Domain.Core.Types`; keep `mkMoney`. Update the `Intent` import to include `IntentAllocation (..)`. Drop `categoryName` if the new interp no longer uses it (or keep for the single-line summary — YAGNI: remove if unused to avoid a `-Werror` unused-binding).

> If the `ia.amount` / `ti.amount` record-dot collides (HasField gotcha), destructure `IntentAllocation amt cat cmt <- ...` positionally inside `resolveAllocLines` and `ti`'s fields likewise.

- [ ] **Step 5: Run resolver tests — expect PASS.**

- [ ] **Step 6: `just build` — the whole tree should compile now.**

- [ ] **Step 7: Format + commit**

```bash
just format
git add -A
git commit -m "feat(llm): resolve NL allocations line-by-line, preserving comments (#27)"
```

---

## Task 6: Integration + reporting tests (the issue's example)

**Files:**
- Modify: `test/Integration/TransactionPromptIntegrationSpec.hs`
- Modify: `test/Application/Services/ReportingServiceSpec.hs` (and/or its PropertySpec sibling)

- [ ] **Step 1: Add the 5-line Ukrainian integration test (full stack, per-line comment)**

Drive the real POST `/api/prompt` path with a stubbed LLM whose `client.complete` returns the multi-line expense intent for the issue's exact input (the 5 lines `200 огірки розсада` … `160 огірки зелень`), with `allocations` = 5 objects, some `category` null → default, and each `comment` = that line's original text. Follow the existing stubbed-LLM pattern in this spec (it already stubs `client.complete`). Assert on the resulting `TransactionResponse`:

- exactly one expense transaction created;
- `allocations.expenses` has length **5** (no merge, even though ≥4 lines share a category);
- `map (.comment) allocations.expenses` equals the 5 original line texts, in order;
- total (sum of source amounts) = **1760**;
- the prompt names **no account** → the transaction resolves to the configured **default account** (#26); a variant with no default configured returns a 400 validation error.

- [ ] **Step 2: Add a reporting duplicate-category test**

Construct an expense with two allocations on the **same** category; assert `aggregateSpending` sums them into a single map entry (comments ignored, totals correct). This guards the "no accidental merge upstream, correct sums downstream" invariant.

- [ ] **Step 3: Run the targeted suites**

Run:
```
cabal test --test-option='--match' --test-option='/TransactionPrompt/'
cabal test --test-option='--match' --test-option='/Reporting/'
```
Expected: PASS (integration tests need the `eventium_test` DB; if absent, note the environmental skip).

- [ ] **Step 4: Format + commit**

```bash
just format
git add -A
git commit -m "test: multi-allocation NL example + reporting duplicate-category sum (#27)"
```

---

## Task 7: Full verification + PR

- [ ] **Step 1: Definitive clean build (defeats warm `.o` cache masking `-Werror`)**

Run: `just rebuild`
Expected: clean build across lib + exe + test.

- [ ] **Step 2: Full test + lint + format check**

Run: `just check` then `just test`
Expected: green (modulo known environmental `eventium_test` DB integration failures — confirm the count/nature matches the pre-existing baseline, not new failures).

- [ ] **Step 3: LiquidHaskell verification**

Confirm the `Allocation` refinement still verifies (the `amount > 0` predicate is unchanged; `comment` is unconstrained). Run the project's LH verification path (as configured in the build) and confirm no new errors on `Domain.Core.Types`.

- [ ] **Step 4: Manual read-through of the design's Testing checklist**

Cross off each item in the spec's Testing section against the tests written; fill any gap.

- [ ] **Step 5: Push + open PR**

```bash
git push -u origin feat/multi-allocation-comments
gh pr create --base master --title "feat: multi-allocation NL expenses with per-allocation comments (#27)" --body "..."
```
PR body: link issue #27, summarize the domain field, the threaded flows (create/set/amend/NL), the reshaped NL extraction, and the no-backcompat note. Note Telegram/bank-import thread `Nothing` (out of scope).

---

## Notes / Risks

- **Cascade compile:** the `mkAllocation` arity change breaks the tree at once; Task 1 restores compilation with mechanical `Nothing`, later tasks replace provisional edits with real threading. Expect large first-task diffs.
- **HasField gotcha:** shared `amount` field name across `IntentAllocation`/`TransactionIntent` — verify record dot; fall back to positional destructure.
- **Generic vs manual JSON:** domain-typed DTOs (set-allocations, amend) use the *generic* `Allocation` instance (auto-updated, `Maybe` optional); persistence uses the *manual* Orphans codec (Task 2). Both must carry `comment`.
- **`-Werror`:** removing the now-unused top-level `category` handling and any dead helper (`categoryName`) is required to avoid unused-binding/redundant-import failures.
- **ormolu:** operator-chain layout in `NoImplicitPrelude` modules is enforced; always `just format` before committing.
