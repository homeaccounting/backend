# Record Transactions Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-transaction prompt intent (`create_transaction` / envelope `"transaction"`) with one `record_transactions` intent whose payload is a list of 1..N transactions, committing each independently (commit-good / report-bad, no dedup).

**Architecture:** Generalize the existing `Application.Services.Prompt.Transaction.*` modules in place. The per-element `TransactionIntent` type and the pure `resolveIntent` are reused unchanged; a thin list wrapper (intent name, list parser, guide) is added, and the handler loops over elements collecting `recorded` / `failed`. The generic envelope + exhaustive-dispatch machinery is retained as the extensibility seam. HTTP returns `kind:"transactions"`; Telegram replies with a full confirmation block per recorded transaction plus a failures note.

**Tech Stack:** Haskell (GHC 9.10), RIO prelude, Servant, Aeson, Hspec, event-sourced via Eventium (in-memory store in tests). Build/test through `just` inside `nix develop`.

**Spec:** `docs/specs/2026-07-11-record-transactions-prompt-design.md`

**Conventions to honor (from CLAUDE.md + memory):**
- `NoImplicitPrelude` (RIO), `NoFieldSelectors`, `OverloadedRecordDot`, `DuplicateRecordFields`, `StrictData`.
- `-fci` enforces `-Werror` over **lib + exe + test** — `just build` = `cabal build all -fci`, which **compiles the test suite too**. A renamed constructor therefore breaks the build unless every consumer *including test modules* is updated in the same commit. Warm `.o` cache can mask `-Werror`; a clean check is `just rebuild`.
- Unused imports are `-Werror` failures (`-Wunused-imports`). When a symbol stops being used, prune its import.
- Full `cabal test all` needs a manual `eventium_test` Postgres DB (28 env failures otherwise are not regressions). Prefer running the specific specs touched.
- ormolu formatting is mandatory; it splits `<$>`/`.:` operator chains onto their own lines — do not fight it. Run `just format` before each commit.
- No issue/ticket numbers in test `describe`/`it` titles — behaviour names only.
- Follow each file's existing export style. CLAUDE.md says never export data constructors — but `Web.API.PromptAPI` already exports `PromptRequest (..)` "for testing"; extending that precedent to the response DTO is acceptable with a one-line rationale comment.

**How to run the touched specs** (pure + in-memory specs run without the `eventium_test` DB):
```bash
just build
cabal test all --test-option='--match' --test-option="/Prompt/"
cabal test all --test-option='--match' --test-option="/Web.API.PromptAPI/"
cabal test all --test-option='--match' --test-option="/Integration.TransactionPrompt/"
```

**Verified facts (checked against the codebase during planning + review):**
- `renderDomainError :: DomainError -> Text` is exported from `Domain.Core.Errors` and already imported+used in `Telegram/Commands.hs`. Use it for failed-row reasons. Do **not** use `tshow` (emits constructor syntax) or invent a renderer.
- `initiateIncome/Expense/Transfer` argument orders in the current `Handler.dispatch` are correct and reused verbatim.
- `constLlmClient` / `queueLlmClient` / `withLlmClient` exist in `Testkit.Llm` and are used as the plan shows.
- `just build` compiles `test/Integration/TransactionPromptIntegrationSpec.hs` (an `other-module` of `backend-test`), so it must be kept compiling within the switch task.

---

## File Structure

| File | Change | Responsibility after change |
|---|---|---|
| `src/Application/Services/Prompt/Transaction/Intent.hs` | Modify | Per-element `TransactionIntent` (unchanged type) + `record_transactions` intent name, list parser, schema, guide |
| `src/Application/Services/Prompt/Types.hs` | Modify | `PromptIntent = RecordTransactionsIntent [TransactionIntent]`; `PromptResult = TransactionsRecorded {recorded, failed}`; decode dispatch |
| `src/Application/Services/Prompt/Transaction/Handler.hs` | Modify | `runRecordTransactions`: per-element resolve+commit, collect `recorded`/`failed` |
| `src/Application/Services/Prompt/Transaction/Resolve.hs` | Unchanged | Pure per-transaction resolver (reused as-is) |
| `src/Application/Services/PromptService.hs` | Modify | Router: dispatch the list; empty-list handling |
| `src/Web/API/PromptAPI.hs` | Modify | `kind:"transactions"` response DTO with `recorded`/`failed` |
| `src/Telegram/Commands.hs` | Modify | Reply: confirmation block per recorded + failures note |
| `test/Application/Services/Prompt/Transaction/IntentSpec.hs` | Modify | List-parse + renamed guide tests |
| `test/Application/Services/Prompt/BuilderSpec.hs` | Modify | Renamed guide reference + `record_transactions` intent name |
| `test/Application/Services/Prompt/TypesSpec.hs` | Modify | Envelope → `RecordTransactionsIntent` |
| `test/Web/API/PromptAPISpec.hs` | Modify | Response serialization (`kind:"transactions"`) |
| `test/Integration/TransactionPromptIntegrationSpec.hs` | Modify | Existing cases → list envelope; then new single/split/mixed/partial/empty cases |

---

## Task 1: The full `record_transactions` switch (single green commit)

The `PromptIntent` constructor, the intent-name **value**, and `PromptResult` all cascade across five library modules **and** five test modules. Because `just build` compiles the test suite under `-fci`, they must all land together to stay green. This is one cohesive commit; the sub-steps below give TDD order (tests first, then implement each module until the whole tree — lib + tests — compiles and the existing behaviours pass under the new shapes).

**Files:** all rows in the table above except the *new* integration scenarios (Task 2).

- [ ] **Step 1: Update the unit tests to the new API (they will fail to compile / fail at runtime — that is the red state)**

`IntentSpec.hs` — imports: add `decodeRecordTransactions`, rename `transactionGuide` → `recordTransactionsGuide` (keep `decodeTransactionIntent`, still exercising the element parser). Add a `describe "decodeRecordTransactions"` block:
```haskell
  describe "decodeRecordTransactions" $ do
    it "decodes a single-element transactions list" $ do
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}]}"
      case decodeRecordTransactions j of
        Right [ti] -> do
          ti.kind `shouldBe` ExpenseKind
          map (.amount) ti.allocations `shouldBe` ["123"]
        other -> expectationFailure ("expected one transaction, got: " <> show other)
    it "decodes a split-payment (one transaction, two allocations)" $ do
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"20\",\"category\":\"Food\",\"comment\":null},{\"amount\":\"15\",\"category\":\"Food\",\"comment\":null}]}]}"
      case decodeRecordTransactions j of
        Right [ti] -> map (.amount) ti.allocations `shouldBe` ["20", "15"]
        other -> expectationFailure ("expected one transaction, got: " <> show other)
    it "decodes a mixed multi-transaction list (distinct kinds/accounts)" $ do
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"income\",\"targetAccount\":\"Bank\",\"amount\":null,\"allocations\":[{\"amount\":\"5000\",\"category\":\"Salary\",\"comment\":null}]},{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"45\",\"category\":null,\"comment\":\"coffee\"}]},{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"120\",\"category\":null,\"comment\":\"taxi\"}]}]}"
      case decodeRecordTransactions j of
        Right tis -> do
          length tis `shouldBe` 3
          map (.kind) tis `shouldBe` [IncomeKind, ExpenseKind, ExpenseKind]
        other -> expectationFailure ("expected three transactions, got: " <> show other)
    it "rejects a payload missing the transactions array" $
      decodeRecordTransactions "{\"intent\":\"record_transactions\"}" `shouldSatisfy` isLeft
    it "rejects a transactions element with a bad payload (no kind)" $
      decodeRecordTransactions "{\"transactions\":[{\"sourceAccount\":\"Cash\"}]}" `shouldSatisfy` isLeft
    it "rejects non-JSON" $
      decodeRecordTransactions "oops" `shouldSatisfy` isLeft
```
Replace the `describe "transactionGuide"` block with a `describe "recordTransactionsGuide"` block asserting: embeds `"Cash"`, embeds `"Food"`, mentions `"language"` (lowercased), contains `"record_transactions"`, and states the split-vs-distinct rule (`"allocation"` lowercased ∈ guide and `"transactions"` ∈ guide).

`BuilderSpec.hs` — rename the guide import+use `transactionGuide` → `recordTransactionsGuide`, and update the local `intentNames = ["transaction"]` → `["record_transactions"]`.

`TypesSpec.hs` — the well-formed case becomes the list envelope + new constructor; keep unknown/missing/non-JSON; retarget the bad-payload case:
```haskell
    it "decodes a well-formed record_transactions envelope" $ do
      let bs = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}]}"
      case decodePromptIntent bs of
        Right (RecordTransactionsIntent [ti]) -> do
          ti.kind `shouldBe` ExpenseKind
          map (.amount) ti.allocations `shouldBe` ["123"]
        other -> expectationFailure ("expected RecordTransactionsIntent, got: " <> show other)
    ...
    it "treats a record_transactions payload with a bad element as malformed" $
      decodePromptIntent "{\"intent\":\"record_transactions\",\"transactions\":[{\"sourceAccount\":\"Cash\"}]}" `shouldSatisfy` isMalformed
    it "treats a record_transactions payload without the transactions array as malformed" $
      decodePromptIntent "{\"intent\":\"record_transactions\"}" `shouldSatisfy` isMalformed
```

`PromptAPISpec.hs` — add a `describe "PromptResponse (ToJSON)"` block. To avoid constructing a heavy `TransactionResponse`, assert on substrings of the encoded response with zero recorded + one failed row (imports: add `encode` from `Data.Aeson`, `PromptResponse (..)` from `Web.API.PromptAPI`, and `toStrict`/`decodeUtf8` as needed — or keep it as a `BL`-level `isInfixOf`):
```haskell
  describe "PromptResponse (ToJSON)" $
    it "emits kind \"transactions\" with recorded and failed arrays" $ do
      let resp = TransactionsResult {recorded = [], failed = [(4, "sourceAccount: no account matches 'foo'")]}
          j = encode resp
          has s = s `BL.isInfixOf` j
      (has "\"kind\":\"transactions\"" && has "\"recorded\":[]" && has "\"failed\":" && has "\"row\":4") `shouldBe` True
```
(Use `import qualified RIO.ByteString.Lazy as BL` and `import Data.Aeson (encode, ...)`; `encode` yields a lazy `ByteString`, so `BL.isInfixOf` matches the literals directly.)

`TransactionPromptIntegrationSpec.hs` — update imports (`PromptResult (..)` → `TransactionsRecorded`; add `RecordedTransaction (..)`, `FailedRow (..)`), add the `soleRecorded` helper, and convert **every existing case**:
```haskell
-- | The single committed transaction from a one-element, no-failure result.
soleRecorded :: PromptResult -> Either String TransactionData
soleRecorded (TransactionsRecorded [r] []) = Right r.tx
soleRecorded other = Left ("expected exactly one recorded transaction, got: " <> show other)
```
For each happy-path case: wrap its stub JSON in `{"intent":"record_transactions","transactions":[ <old object, intent field removed> ]}` and replace `Right (TransactionCreated _ _ td) -> …` with `case soleRecorded result of Right td -> …; Left msg -> expectationFailure msg`. The one case asserting on `interp` (`"Cash" isInfixOf interp`) matches `TransactionsRecorded [r] []` and reads `r.interpretation`. Error cases (unknown-intent, feature-disabled, empty-text, retry-exhausted, transport-fail) keep their assertions; the retry-recover case wraps its recovered JSON in the list envelope, and its two-item queue becomes `["not json", <list envelope>]`.

- [ ] **Step 2: Run to confirm the red state**

```bash
just build
```
Expected: FAIL (new symbols not in scope; `PromptResult`/`PromptIntent` mismatch).

- [ ] **Step 3: Implement `Intent.hs`**

1. Exports: rename `transactionIntentName` → `recordTransactionsIntentName`, `transactionSchema` → `recordTransactionsSchema`, `transactionGuide` → `recordTransactionsGuide`; add `parseRecordTransactionsFields`, `decodeRecordTransactions`. Keep `parseTransactionFields`, `decodeTransactionIntent`, `TransactionIntent (..)`, `IntentKind (..)`, `IntentAllocation (..)`, `PromptContext (..)`.
2. `recordTransactionsIntentName :: Text = "record_transactions"`.
3. `TransactionIntent`, `IntentKind`, `IntentAllocation`, `parseKind`, `parseAllocation`, `parseTransactionFields`, `decodeTransactionIntent` — **unchanged**.
4. Add the list parser + standalone decoder:
```haskell
-- | Parse the @record_transactions@ payload: a required @transactions@ array,
-- each element the existing per-transaction shape ('parseTransactionFields').
-- The generic router calls this after reading the envelope @intent@ field.
parseRecordTransactionsFields :: Object -> Parser [TransactionIntent]
parseRecordTransactionsFields o =
  o .: "transactions" >>= traverse (withObject "TransactionIntent" parseTransactionFields)

-- | Standalone convenience decoder for tests and isolated reuse.
decodeRecordTransactions :: BL.ByteString -> Either Text [TransactionIntent]
decodeRecordTransactions bs = case Aeson.eitherDecode bs of
  Left e -> Left ("intent: invalid JSON: " <> T.pack e)
  Right v -> first T.pack (parseEither (withObject "RecordTransactions" parseRecordTransactionsFields) v)
```
5. `recordTransactionsSchema`: wrap the existing per-element object schema (drop the element-level `intent` const) inside `{ intent: const record_transactions, transactions: array of <element> }`. Best-effort only (production requests `json_object`).
6. `recordTransactionsGuide`: keep the per-transaction field descriptions + multilingual instruction, frame the top-level shape as `{"intent":"record_transactions","transactions":[ <transaction>, ... ]}`, and state the rule — **separate list elements = distinct transactions** (own kind/account/date); **allocations = split one payment across categories**. Include four examples wrapped in the envelope: `cash 123 food` (1), `ATB: milk 20, bread 15` (1 tx / 2 allocs), `salary 5000 to bank, coffee 45 cash, taxi 120 cash` (3), Ukrainian `готівка 123 їжа` (1). End with "Output only JSON."
7. Fix the two production call sites (also part of this commit):
   - `Types.hs`: change the `Intent` import to `TransactionIntent`, `recordTransactionsIntentName`, `parseRecordTransactionsFields` **only** — drop `transactionIntentName` and `parseTransactionFields` (the latter is no longer used here, and since it stays exported from `Intent.hs` an unused import would be a `-Werror` failure). `dispatchName` matches the new name and builds `RecordTransactionsIntent` (see Step 4).
   - `PromptService.hs`: import `recordTransactionsIntentName`, `recordTransactionsGuide`; `baseMsgs = buildMessages today [recordTransactionsIntentName] [recordTransactionsGuide pctx] userText`.

- [ ] **Step 4: Implement `Types.hs`**

```haskell
data PromptIntent = RecordTransactionsIntent [TransactionIntent]
  deriving (Show, Eq)
```
```haskell
    dispatchName name o
      | name == recordTransactionsIntentName =
          case parsePayload parseRecordTransactionsFields o of
            Left err -> Left (MalformedResponse err)
            Right tis -> Right (RecordTransactionsIntent tis)
      | otherwise = Left (UnknownIntent name)
```
Replace the result types + export them (`PromptResult (..)`, `RecordedTransaction (..)`, `FailedRow (..)`):
```haskell
data PromptResult = TransactionsRecorded
  { recorded :: ![RecordedTransaction],
    failed :: ![FailedRow]
  }
  deriving (Show, Eq)

data RecordedTransaction = RecordedTransaction
  { interpretation :: !Text,
    txId :: !TransactionId,
    tx :: !TransactionData
  }
  deriving (Show, Eq)

data FailedRow = FailedRow
  { row :: !Int,
    reason :: !Text
  }
  deriving (Show, Eq)
```

- [ ] **Step 5: Implement `Handler.hs`**

Rename `runCreateTransaction` → `runRecordTransactions`; fold over the 1-based-indexed list, reusing `dispatch`:
```haskell
runRecordTransactions ::
  UserId -> ResolveContext -> Text -> [TransactionIntent] -> AppM (Either DomainError PromptResult)
runRecordTransactions uid rctx userText tis = do
  outcomes <- traverse (uncurry runOne) (zip [1 ..] tis)
  pure (Right (TransactionsRecorded {recorded = rights outcomes, failed = lefts outcomes}))
  where
    runOne :: Int -> TransactionIntent -> AppM (Either FailedRow RecordedTransaction)
    runOne rowNum ti =
      case resolveIntent rctx userText ti of
        Left (ResolveError f m) -> pure (Left (FailedRow {row = rowNum, reason = f <> ": " <> m}))
        Right (resolved, interp) -> do
          committed <- dispatch resolved
          case committed of
            Left e -> pure (Left (FailedRow {row = rowNum, reason = renderDomainError e}))
            Right (tid, tdata) ->
              pure (Right (RecordedTransaction {interpretation = interp, txId = tid, tx = tdata}))
    dispatch = \case
      ResolvedIncome target total allocs labels desc date ->
        TransactionService.initiateIncome uid target total allocs labels desc date Nothing
      ResolvedExpense source total allocs labels desc date ->
        TransactionService.initiateExpense uid source total allocs labels desc date Nothing
      ResolvedTransfer source dest amount labels desc date ->
        TransactionService.initiateTransfer uid source dest amount labels desc Nothing date Nothing
```
Import changes (all `-Werror`-relevant):
- **Remove** `mkValidationError` from the `Domain.Core.Errors` import (no longer used here — it moved to the router). Keep `DomainError (..)`.
- **Add** `renderDomainError` to the `Domain.Core.Errors` import.
- **Add** `RecordedTransaction (..)`, `FailedRow (..)` to the `Prompt.Types` import (alongside `PromptResult (..)`, `ResolveError (..)`).
- Add `import Data.Either (lefts, rights)` (do not rely on a RIO re-export; matches existing repo practice, e.g. `Application/ReadModels/Account.hs`'s `import Data.Either (fromRight)`). Both are used, so no unused-import warning.
Update the module `Description` header (no longer "@create_transaction@ intent"; now "the @record_transactions@ intent").

- [ ] **Step 6: Implement `PromptService.hs` (dispatch + empty-list handling)**

Dispatch the list, and treat an empty `transactions` like a malformed body on the first attempt, then a friendly 400 after the retry:
```haskell
          dispatch pintent = case pintent of
            RecordTransactionsIntent tis ->
              ExceptT (fmap (first PromptDomainError) (Txn.runRecordTransactions uid rctx userText tis))
          emptyErr =
            PromptDomainError
              (ValidationErr (mkValidationError "transactions" "couldn't identify a transaction in that text" userText))
          unknownErr n =
            PromptDomainError
              (ValidationErr (mkValidationError "intent" ("Unsupported request: " <> n) userText))
      resp1 <- ExceptT (fmap (first (const (PromptUpstreamError "LLM request failed"))) (callOnce baseMsgs))
      case decodePromptIntent (toLBS resp1.content) of
        Right (RecordTransactionsIntent (_ : _)) `matches` ... -> dispatch ...   -- see note
        ...
```
Concretely, keep the existing two-attempt structure but branch on emptiness. Replace the first `case` with:
```haskell
      case decodePromptIntent (toLBS resp1.content) of
        Right (RecordTransactionsIntent tis)
          | not (null tis) -> dispatch (RecordTransactionsIntent tis)
        Left (UnknownIntent n) -> throwError (unknownErr n)
        _ -> do
          -- malformed OR empty list: retry once with a JSON-only nudge
          let retryMsgs = baseMsgs ++ [LlmMessage User "Return ONLY a single valid JSON object matching the schema."]
          resp2 <- ExceptT (fmap (first (const (PromptUpstreamError "LLM request failed"))) (callOnce retryMsgs))
          case decodePromptIntent (toLBS resp2.content) of
            Right (RecordTransactionsIntent tis) | not (null tis) -> dispatch (RecordTransactionsIntent tis)
            Right (RecordTransactionsIntent _) -> throwError emptyErr        -- empty after retry → 400
            Left (UnknownIntent n) -> throwError (unknownErr n)
            Left _ -> throwError (PromptUpstreamError "LLM returned unparseable output")
```
Keep the existing empty-text guard and feature-gate/context/`callOnce` scaffolding. Update imports (`PromptIntent (..)` now gives `RecordTransactionsIntent`; `Txn.runRecordTransactions`). `mkValidationError` is already imported here.

- [ ] **Step 7: Implement `Web/API/PromptAPI.hs`**

```haskell
-- Exported for testing (mirrors PromptRequest); the response DTO is otherwise
-- internal to this module.
data PromptResponse = TransactionsResult
  { recorded :: [TransactionResponse],
    failed :: [(Int, Text)]
  }
  deriving (Show, Eq, Generic)

instance ToJSON PromptResponse where
  toJSON r =
    object
      [ "kind" .= ("transactions" :: Text),
        "recorded" .= r.recorded,
        "failed" .= map failedRow r.failed
      ]
    where
      failedRow (rw, rs) = object ["row" .= rw, "reason" .= rs]
```
```haskell
promptHandler user req = do
  result <- PromptService.handlePrompt user.userId req.account req.text
  case result of
    Right (TransactionsRecorded recorded failed) ->
      pure
        ( TransactionsResult
            { recorded = [fromTransactionData r.txId r.tx | r <- recorded],
              failed = [(f.row, f.reason) | f <- failed]
            }
        )
    Left (PromptDomainError de) -> throwDomainError de
    Left PromptFeatureDisabled -> throwIO (err503 {errBody = "LLM feature disabled"})
    Left (PromptUpstreamError _) -> throwIO (err502 {errBody = "LLM upstream error"})
```
Export `PromptResponse (..)`. Import `RecordedTransaction (..)`, `FailedRow (..)` from `Prompt.Types` (for the dot-access sites to have their record types in scope). If `r.txId`/`r.tx`/`f.row`/`f.reason` dot-access fails to resolve (the `HasField`+`DuplicateRecordFields` gotcha), destructure via the constructor in the comprehension instead. Try dot-access first.

- [ ] **Step 8: Implement `Telegram/Commands.hs`**

Replace the success branch of `handlePromptText`:
```haskell
        Right (TransactionsRecorded recorded failed) -> do
          forM_ recorded $ \r -> replyRecordedTransaction telegramId chatId r.tx
          unless (null failed)
            $ sendMsg chatId
            $ "\9888\65039 Couldn't record:\n"
            <> T.unlines [" \8226 row " <> tshow f.row <> ": " <> f.reason | f <- failed]
```
Keep the `PromptDomainError`/`FeatureDisabled`/`UpstreamError` branches unchanged. `renderDomainError` is already imported. Update the `Prompt.Types` import so `TransactionsRecorded` (and, if needed for dot-access scope, `RecordedTransaction (..)`, `FailedRow (..)`) are visible. Same dot-access fallback note.

- [ ] **Step 9: Format, build, run the full prompt/web suites (green checkpoint)**

```bash
just format
just build
cabal test all --test-option='--match' --test-option="/Prompt/"
cabal test all --test-option='--match' --test-option="/Web.API.PromptAPI/"
cabal test all --test-option='--match' --test-option="/Integration.TransactionPrompt/"
```
Expected: build green (lib + tests); all matched specs PASS.

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "feat(prompt): record one or more transactions per prompt (record_transactions)"
```

---

## Task 2: New integration scenarios — mixed / split / partial / empty

Additive `it` blocks on the now-green tree (they compile and pass on top of Task 1). Reuses `soleRecorded` added in Task 1.

**Files:**
- Test: `test/Integration/TransactionPromptIntegrationSpec.hs`

- [ ] **Step 1: Add the failing scenarios**

```haskell
  it "records three distinct transactions from one capture (income + two expenses)" $ do
    h <- setupHarness "prompt-multi@example.com"
    let json = "{\"intent\":\"record_transactions\",\"transactions\":[\
               \{\"kind\":\"income\",\"targetAccount\":\"Cash\",\"allocations\":[{\"amount\":\"5000\",\"category\":\"Salary\",\"comment\":null}]},\
               \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"45\",\"category\":null,\"comment\":\"coffee\"}]},\
               \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"120\",\"category\":null,\"comment\":\"taxi\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "salary 5000 to cash, coffee 45 cash, taxi 120 cash")
    case result of
      Right (TransactionsRecorded recorded failed) -> do
        length recorded `shouldBe` 3
        failed `shouldBe` []
      other -> expectationFailure ("expected three recorded, got: " <> show other)

  it "splits one payment across categories as a single transaction with two allocations" $ do
    h <- setupHarness "prompt-split@example.com"
    let json = "{\"intent\":\"record_transactions\",\"transactions\":[\
               \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[\
               \{\"amount\":\"20\",\"category\":\"Food\",\"comment\":\"milk\"},\
               \{\"amount\":\"15\",\"category\":\"Food\",\"comment\":\"bread\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "milk 20, bread 15 cash")
    case soleRecorded result of
      Right td -> case allocationsOf td.transactionType of
        Just allocs -> length allocs.expenses `shouldBe` 2
        Nothing -> expectationFailure "expected expense allocations"
      Left msg -> expectationFailure msg

  it "commits the good transactions and reports the bad one (partial failure)" $ do
    h <- setupHarness "prompt-partial@example.com"
    let json = "{\"intent\":\"record_transactions\",\"transactions\":[\
               \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"10\",\"category\":\"Food\",\"comment\":null}]},\
               \{\"kind\":\"expense\",\"sourceAccount\":\"Nope\",\"allocations\":[{\"amount\":\"20\",\"category\":\"Food\",\"comment\":null}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 10 food; nope 20 food")
    case result of
      Right (TransactionsRecorded recorded failed) -> do
        length recorded `shouldBe` 1
        map (.row) failed `shouldBe` [2]
      other -> expectationFailure ("expected one recorded + one failed, got: " <> show other)

  it "returns a domain error when the model identifies no transaction (empty list after retry)" $ do
    h <- setupHarness "prompt-empty-list@example.com"
    client <- queueLlmClient
      [ "{\"intent\":\"record_transactions\",\"transactions\":[]}",
        "{\"intent\":\"record_transactions\",\"transactions\":[]}" ]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "hello there")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)
```
(`map (.row) failed` needs `FailedRow (..)` imported — done in Task 1.)

- [ ] **Step 2: Format, build, run**

```bash
just format
just build
cabal test all --test-option='--match' --test-option="/Integration.TransactionPrompt/"
```
Expected: build green; all cases (existing + new) PASS.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "test(prompt): integration coverage for record_transactions (single/split/mixed/partial/empty)"
```

---

## Task 3: Full verification + docs + review

- [ ] **Step 1: Clean rebuild to defeat the warm-cache `-Werror` mask**

```bash
just rebuild
```
Expected: green (no warnings-as-errors across lib + exe + test).

- [ ] **Step 2: Lint**

```bash
just lint
```
Expected: no new hints. (No hlint suppressions without documented rationale.)

- [ ] **Step 3: Drive the change end-to-end (verify skill)**

Invoke the `verify` (or `run`) skill to exercise `POST /api/prompt` against a running server with a stub/real LLM: confirm a single capture returns `kind:"transactions"` with one `recorded`; a mixed capture returns multiple `recorded`; a bad account yields a `failed` row while the good ones commit. Observe the actual response body, not just tests.

- [ ] **Step 4: Flip the spec status and commit**

Set `status: completed` in `docs/specs/2026-07-11-record-transactions-prompt-design.md`.
```bash
git add -A && git commit -m "docs(prompt): mark record_transactions spec completed"
```

- [ ] **Step 5: Request code review + open PR**

Use superpowers:requesting-code-review before opening the PR. Open the PR against `master` with a Conventional-Commits title, e.g. `feat(prompt): record one or more transactions per prompt (tracker#39)`.

---

## Notes / risks

- **Type + string cascade (why Task 1 is one commit):** `PromptIntent`, the intent-name *value*, and `PromptResult` are referenced by five library modules **and** five test modules; `just build` compiles the tests under `-fci`, so a partial rename is a red build. They land together in Task 1. Task 2's new scenarios are purely additive on the green tree.
- **`-Werror` unused-import trap:** removing `mkValidationError` from `Handler.hs`'s imports is mandatory (it becomes unused there) — otherwise `just build` fails.
- **`renderDomainError`** (`Domain.Core.Errors`, already used in Telegram) is the failed-row reason renderer. Do not use `tshow`.
- **`HasField` + `DuplicateRecordFields` gotcha** (memory): `r.tx`/`r.txId`/`f.row`/`f.reason` dot-access may not resolve if field names collide within a module component. Fallback: destructure via the constructor. Try dot-access first (record types are statically known at every site, so this is low-risk).
- **No dedup, no `skipped`:** do not reintroduce any dedup key — free-text capture is one-shot (spec §Out of scope).
- **Web client** is updated separately for `kind:"transaction"` → `kind:"transactions"`; no back-compat shim here (memory: no back-compat phase).
