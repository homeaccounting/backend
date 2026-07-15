---
status: completed
date: 2026-07-14
spec: docs/specs/2026-07-14-batch-import-outcome-consistency-design.md
---

# Batch-import outcome consistency — Implementation Plan

> **Amendment (during implementation).** Task 4/5 below name the prompt
> per-element error `RowError {rowNumber, message}` for parity with bank. On
> review this was changed: a prompt transaction is multi-line (allocations), so a
> file-"row" concept does not fit, and the prompt already calls a transaction's
> list position `index`. The type shipped as a prompt-local
> `newtype TransactionDecodeError = TransactionDecodeError Text` (no `rowNumber` —
> the position is the handler's `zip [0..]` `index`, the single source for both
> good and bad rows). Read every `RowError`/`rowNumber` below as
> `TransactionDecodeError`/positional `index`. See the design doc's amended §B.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align `BankImportService` and the prompt transaction pipeline on parallel per-row vocabulary — an explicit `ImportOutcome`/`SkipReason` for bank, per-element decode tolerance with a typed `RowError` for prompt — and surface bank skip reasons in the import HTTP response.

**Architecture:** Two independent Application-layer services keep their distinct row models (`BankTransaction`, `TransactionIntent`) but adopt parallel shapes: (A) bank's single-transaction result becomes a purpose-built `ImportOutcome = Imported | Skipped SkipReason | Failed DomainError`, replacing an overloaded `Either DomainError (Maybe TransactionId)`; (B) the prompt `transactions` array decodes per-element into `[Either RowError TransactionIntent]`, so one malformed element no longer fails the batch. No shared module; `RowError` is a prompt-local type named for vocabulary parity with bank's.

**Tech Stack:** GHC 9.10, RIO prelude, Servant, Aeson, Hspec. Build/test gated with `-fci` (`-Werror`). Formatter ormolu, linter hlint.

**Conventions for every task:**
- No new modules or dependencies → no `package.yaml`/hpack change.
- After edits: `just format` then `just lint`, then build/test with `-fci`.
- Build: `cabal build all -fci` (or `just build`). Test a suite by match, e.g.
  `cabal test all -fci --test-option='--match' --test-option="/BankImportService/"`.
- Per CLAUDE.md: no data-constructor/field-selector exports except where an
  existing sibling already does so (bank's `RowError (..)` is the precedent the
  new prompt `RowError (..)` follows). No partial functions. `StrictData` is on
  (fields need no manual `!` beyond house style, which uses `!`).
- Commit after each task.

---

## Task 1: Bank — `ImportOutcome` / `SkipReason` types + `renderSkipReason`

Introduce the vocabulary first, with no call-site changes yet, so it compiles in isolation.

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (add types + export)

- [ ] **Step 1: Add the two types and a renderer** near the Result Types section (after the module's existing `import`s, before `AccountImportResult`):

```haskell
-- | Why a bank transaction was intentionally not committed (distinct from a
-- write failure). Each constructor carries the human context that was
-- previously only logged.
data SkipReason
  = AlreadyImported
  | Unmapped
  | UnsupportedCurrency !Text
  | InvalidAmount !Text
  | CurrencyMismatch !Text
  deriving (Show, Eq)

-- | The outcome of attempting to import a single bank transaction.
data ImportOutcome
  = Imported !TransactionId
  | Skipped !SkipReason
  | Failed !DomainError
  deriving (Show, Eq)

-- | Render a skip reason as the user-facing text stored in the result's
-- 'skipped' list (mirrors how 'failed' renders a 'DomainError').
renderSkipReason :: SkipReason -> Text
renderSkipReason = \case
  AlreadyImported -> "already imported"
  Unmapped -> "no local account mapping for this transaction"
  UnsupportedCurrency msg -> "unsupported currency: " <> msg
  InvalidAmount msg -> "invalid amount: " <> msg
  CurrencyMismatch msg -> "currency mismatch: " <> msg
```

Add `{-# LANGUAGE LambdaCase #-}` to the pragma block if not already present.

- [ ] **Step 2: Export the new names** in the module export list:

```haskell
    ImportOutcome (..),
    SkipReason (..),
    renderSkipReason,
```

- [ ] **Step 3: Build** — `cabal build all -fci`. Expected: PASS (types unused, `-Wunused-top-binds` is not in the wall set; if a warning fires, it will be resolved when Task 2/3 use them — acceptable within this task's commit only if build stays green, otherwise proceed straight to Task 2 before committing).
- [ ] **Step 4: Format + lint** — `just format && just lint`. Expected: clean.
- [ ] **Step 5: Commit**

```bash
git add src/Application/Services/BankImportService.hs
git commit -m "refactor(banking): add ImportOutcome/SkipReason vocabulary"
```

---

## Task 2: Bank — thread `ImportOutcome` through the import path

Rewrite the single-transaction functions to return `ImportOutcome`, and the aggregator to fold it. Behavior is preserved exactly; the five former `Right Nothing` sites become precise `Skipped` constructors. This is one cohesive compile-unit change (signatures ripple), so tests are updated in the same task.

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`
  - `importTransaction` (`:411`), `importMatchedTransaction` (`:433`),
    `commitImport` (`:460`), `commitMatchingCurrencyImport` (`:504`)
  - `importMany` (`:226`), `groupAccountResults` (`:250`)
  - `AccountImportResult` (`:98`) — `skipped :: ![Text]`
- Test: `test/Application/Services/BankImportServiceSpec.hs`
- Test: `test/Integration/BankImportWorkflowSpec.hs`

- [ ] **Step 1: Update the existing unit tests to the new shape (RED).** In `BankImportServiceSpec.hs`, replace the `Right (Just _)` / `Right Nothing` / `Left _` assertions on `importTransaction`:
  - "imports hold transactions…" (`:219`): `case result of Imported _ -> pure (); _ -> expectationFailure …`
  - "skips already-imported…" (`:239`): first import `Imported _`; second `result2 \`shouldBe\` Skipped AlreadyImported`.
  - "skips transactions with unmatched account" (`:248`): `result \`shouldBe\` Skipped Unmapped`.
  - expense/income "imports … with correct fields" (`:257`,`:283`): `Imported i <- …` extraction.
  - Add a new case asserting a currency-mismatch skip carries `Skipped (CurrencyMismatch _)` (reuse the cross-currency setup around `:338`, mapping a UAH card to a USD local account).
  - `importMany` cases (`:303`+) use `AccountImportResult` fields; only `.skipped` changes type (see Step 4).
- [ ] **Step 2: Run tests to confirm they fail to compile / fail.** Run:
  `cabal test all -fci --test-option='--match' --test-option="/BankImportService/"`.
  Expected: compile error (constructors not yet used by impl) or assertion failure.
- [ ] **Step 3: Rewrite `importTransaction` (GREEN).** New signature and body:

```haskell
importTransaction :: (BankTransaction -> TransactionClassification) -> UserId -> [(ExternalAccountId, AccountId)] -> BankTransaction -> AppM ImportOutcome
importTransaction classify userId accountLink tx = do
  alreadyImported <- runDb $ isImported tx.externalId
  if alreadyImported
    then do
      logDebug $ "Skipping already-imported transaction: " <> display tx.externalId
      pure (Skipped AlreadyImported)
    else case lookup tx.externalAccountId accountLink of
      Nothing -> do
        logWarn $ "No account mapping for external account: " <> display tx.externalAccountId
        pure (Skipped Unmapped)
      Just localAccId -> importMatchedTransaction classify userId localAccId tx
```

- [ ] **Step 4: Rewrite the remaining single-tx functions.** Map each former exit:
  - `importMatchedTransaction`: user-not-found stays a failure → `pure (Failed (NotFound "User" …))`; unsupported currency → `pure (Skipped (UnsupportedCurrency (renderDomainError err)))`; `mkMoney` failure → `pure (Skipped (InvalidAmount (renderDomainError err)))`; success path delegates to `commitImport` (now returns `AppM ImportOutcome`, see below).
  - `commitImport` / `commitMatchingCurrencyImport`: change the `ExceptT DomainError AppM (Maybe TransactionId)` to build an `ImportOutcome`. Simplest: keep the `ExceptT DomainError AppM (Maybe TransactionId)` internals, then in `importMatchedTransaction` convert: `runExceptT (commitImport …) >>= \case Left e -> pure (Failed e); Right Nothing -> pure (Skipped (CurrencyMismatch msg)); Right (Just tid) -> pure (Imported tid)`. To carry the mismatch message, change `commitImport`'s currency-mismatch branch to `throwE`-free skip: return `Left`/`Right` is awkward for a skip, so instead have `commitImport` return `ExceptT DomainError AppM ImportOutcome` and its currency-mismatch branch `pure (Skipped (CurrencyMismatch <the message it currently logs>))`, its success `pure (Imported txId)`; `importMatchedTransaction` then does `runExceptT (commitImport …) >>= either (pure . Failed) pure`.

  Prefer the second form (commitImport returns `ExceptT DomainError AppM ImportOutcome`) — one conversion point, no `Maybe` overloading survives.
- [ ] **Step 5: Change `AccountImportResult.skipped` to `![Text]`** and update `groupAccountResults` to fold `ImportOutcome`:
  - `Imported tid` → `succeeded = [tid]`
  - `Skipped r` → `skipped = [renderSkipReason r]`
  - `Failed e` → `failed = [renderDomainError e]`
  - `merge` combines `skipped` by `old.skipped ++ new.skipped` (was `+` on Int).
  - Update the two zero-value default rows (`:181`, `:203`) to `skipped = []`.
  - `importMany`'s `importTransaction` call now yields `ImportOutcome` directly; the `Either DomainError (Maybe TransactionId)` triple type in `groupAccountResults` becomes `ImportOutcome`.
- [ ] **Step 6: Update integration assertions.** In `BankImportWorkflowSpec.hs`, any `.skipped` numeric comparison (e.g. `sum (map (.skipped) …)` at `:523`) becomes `sum (map (length . (.skipped)) …)` or a reason-content check.
- [ ] **Step 7: Format + lint + build + test.** `just format && just lint && cabal build all -fci` then the two suites:
  `cabal test all -fci --test-option='--match' --test-option="/BankImportService/"` and `--match "/BankImportWorkflow/"`. Expected: PASS.
- [ ] **Step 8: Commit**

```bash
git add src/Application/Services/BankImportService.hs test/Application/Services/BankImportServiceSpec.hs test/Integration/BankImportWorkflowSpec.hs
git commit -m "refactor(banking): import path returns ImportOutcome; skip reasons in result"
```

---

## Task 3: Bank — surface skip reasons in the HTTP response

**Files:**
- Modify: `src/Web/API/BankingAPI.hs` — `AccountImportSummary` (`:174`), `toImportResponse` (`:536`)
- Test: `test/Web/API/BankImportFileAPISpec.hs`

- [ ] **Step 1: Update the API test (RED).** In `BankImportFileAPISpec.hs`, the assertions `KeyMap.lookup "skippedCount" row == Just (Number 0)` (`:263`) and `Just (Number 103)` (`:308`) become lookups of `"skipped"` expecting a JSON `Array` of the expected length (e.g. `Array` with `length == 0` / `103`). Adjust to assert array length rather than a numeric literal.
- [ ] **Step 2: Run the suite to confirm failure.** Run:
  `cabal test all -fci --test-option='--match' --test-option="/BankImportFileAPI/"`. Expected: FAIL.
- [ ] **Step 3: Change the DTO field.** `AccountImportSummary`: `skippedCount :: !Int` → `skipped :: ![Text]`. Update the field doc comment ("Counts only…") to note skip reasons are now listed.
- [ ] **Step 4: Update `toImportResponse.summarize`** (`:543`): `skipped = acc.skipped` (both `[Text]` now) instead of `skippedCount = acc.skipped`.
- [ ] **Step 5: Format + lint + build + test.** As above; run the file-API suite. Expected: PASS.
- [ ] **Step 6: Commit**

```bash
git add src/Web/API/BankingAPI.hs test/Web/API/BankImportFileAPISpec.hs
git commit -m "feat(banking)!: surface skip reasons in import response (skippedCount -> skipped)"
```

---

## Task 4: Prompt — typed `RowError` + per-element tolerant decode

**Files:**
- Modify: `src/Application/Services/Prompt/Transaction/Intent.hs` — add `RowError`, rewrite `parseRecordTransactionsFields`, `decodeRecordTransactions`
- Modify: `src/Application/Services/Prompt/Types.hs` — `PromptIntent`, `decodePromptIntent` (+ doc), re-export `RowError`
- Test: `test/Application/Services/Prompt/Transaction/IntentSpec.hs`, `test/Application/Services/Prompt/TypesSpec.hs`

- [ ] **Step 1: Write/adjust decoder tests (RED).**
  - `IntentSpec.hs`: `decodeRecordTransactions` now returns `Either Text [Either RowError TransactionIntent]`. Rewrite `:100-116` matches. The case at `:120-122` ("rejects a transactions element with a bad payload") now asserts the element is a recovered `Left RowError` inside a `Right` list — e.g. `Right [Left (RowError 0 _)]` — NOT `isLeft`. Add a mixed case: `[bad, good]` → `Right [Left (RowError 0 _), Right ti]`.
  - `TypesSpec.hs`: `decodePromptIntent` now yields `RecordTransactionsIntent [Either RowError TransactionIntent]`. Rewrite `:30`-style matches. The case at `:47-50` ("bad element as malformed") now expects `Right (RecordTransactionsIntent [Left (RowError 0 _)])`, not `isMalformed`. Add a structural case: `transactions` absent / not an array still → `Left (MalformedResponse _)`.
- [ ] **Step 2: Run to confirm failure.** `cabal test all -fci --test-option='--match' --test-option="/Prompt/"`. Expected: compile error / assertion failure.
- [ ] **Step 3: Add `RowError` to `Intent.hs` (GREEN).**

```haskell
-- | One 'transactions' element that failed to decode. Named 'RowError' and
-- shaped like Infrastructure.Banking.Provider.RowError for vocabulary parity,
-- but a DISTINCT, prompt-local type (prompt is Application-layer; it must not
-- depend on the banking provider). 'rowNumber' is the element's 0-based index.
data RowError = RowError {rowNumber :: !Int, message :: !Text}
  deriving (Show, Eq)
```

Export `RowError (..)` from `Intent.hs` (following bank's `RowError (..)` precedent).

- [ ] **Step 4: Rewrite `parseRecordTransactionsFields`** to recover per element while hard-failing on structural faults:

```haskell
parseRecordTransactionsFields :: Object -> Parser [Either RowError TransactionIntent]
parseRecordTransactionsFields o = do
  els <- o .: "transactions" -- hard-fails if absent or not an array
  pure (zipWith decodeElem [0 ..] els)
  where
    decodeElem i v =
      case parseEither (withObject "TransactionIntent" parseTransactionFields) v of
        Left err -> Left (RowError {rowNumber = i, message = T.pack err})
        Right ti -> Right ti
```

Update `decodeRecordTransactions` accordingly (its `parseEither` wrapper now returns the per-element list; the outer `Either Text` still covers structural failure).

- [ ] **Step 5: Update `Types.hs`.** `PromptIntent`: `RecordTransactionsIntent [Either RowError TransactionIntent]`. In `decodePromptIntent`/`dispatchName`, the `record_transactions` branch wraps the per-element list unchanged. Re-export `RowError (..)` from `Types.hs` for the handler/router. Revise the `PromptDecodeError`/`decodePromptIntent` doc comment (`Types.hs:61-76`) to state that a recognized intent whose *element* payloads fail to parse yields recovered `Left RowError`s (not `MalformedResponse`); only structural faults (invalid JSON, no `intent`, `transactions` absent/non-array) are `MalformedResponse`.
- [ ] **Step 6: Format + lint + build + test.** Run the `/Prompt/` suites. Expected: PASS.
- [ ] **Step 7: Commit**

```bash
git add src/Application/Services/Prompt/Transaction/Intent.hs src/Application/Services/Prompt/Types.hs test/Application/Services/Prompt/Transaction/IntentSpec.hs test/Application/Services/Prompt/TypesSpec.hs
git commit -m "refactor(prompt): per-element tolerant transactions decode with typed RowError"
```

---

## Task 5: Prompt — handler + router over usable rows

**Files:**
- Modify: `src/Application/Services/Prompt/Transaction/Handler.hs` — `runRecordTransactions` (`:134`)
- Modify: `src/Application/Services/PromptService.hs` — dispatch/retry (`:88-116`)
- Test: prompt router/integration specs (`PromptAPISpec`, `TransactionPromptIntegrationSpec`)

- [ ] **Step 1: Write the new behavior tests (RED).** In the integration/router spec:
  - (a) a `transactions` array of `[malformed, good]` records the good one and returns a `FailedTransaction` at index 0 for the bad one (request succeeds, mixed `PromptResult`).
  - (b) a non-empty array whose every element is malformed → after retry, 400 (`ValidationErr` "couldn't identify a transaction").
  - (c) envelope-level junk still 502s after retry (confirm `TransactionPromptIntegrationSpec:239,248` still pass).
- [ ] **Step 2: Run to confirm failure.** `cabal test all -fci --test-option='--match' --test-option="/Prompt/"` (+ integration match). Expected: FAIL.
- [ ] **Step 3: Update `runRecordTransactions` (GREEN).** Signature takes `[Either RowError TransactionIntent]`; `runOne` handles both arms:

```haskell
runRecordTransactions :: UserId -> ResolveContext -> Text -> [Either RowError TransactionIntent] -> AppM (Either DomainError PromptResult)
runRecordTransactions uid rctx userText rows = do
  outcomes <- traverse (uncurry runOne) (zip [0 ..] rows)
  pure (Right (TransactionsRecorded {succeeded = rights outcomes, failed = lefts outcomes}))
  where
    runOne :: Int -> Either RowError TransactionIntent -> AppM (Either FailedTransaction RecordedTransaction)
    runOne idx (Left (RowError _ msg)) =
      pure (Left (FailedTransaction {index = idx, reason = msg}))
    runOne idx (Right ti) =
      case resolveIntent rctx userText ti of
        Left (ResolveError f m) -> pure (Left (FailedTransaction {index = idx, reason = f <> ": " <> m}))
        Right (resolved, interp) -> do
          committed <- dispatch resolved
          case committed of
            Left e -> pure (Left (FailedTransaction {index = idx, reason = renderDomainError e}))
            Right (tid, tdata) -> pure (Right (RecordedTransaction {index = idx, interpretation = interp, txId = tid, tx = tdata}))
    dispatch = …  -- unchanged
```

Destructure `RowError` positionally (`RowError _ msg`), per the `DuplicateRecordFields` gotcha — do not use `err.message`.

- [ ] **Step 4: Update `PromptService.handlePrompt`.** Replace the `not (null tis)` guards with a usable-rows split. Introduce a helper on the decoded list:

```haskell
        usable rows = [ti | Right ti <- rows]
        dispatch rows = ExceptT (fmap (first PromptDomainError) (Txn.runRecordTransactions uid rctx userText rows))
```

  First attempt: `Right (RecordTransactionsIntent rows) | not (null (usable rows)) -> dispatch rows`; `Left (UnknownIntent n) -> throwError (unknownErr n)`; otherwise (envelope malformed, or zero usable) retry once. Retry attempt: `Right (RecordTransactionsIntent rows) | not (null (usable rows)) -> dispatch rows`; `Right (RecordTransactionsIntent _) -> throwError emptyErr` (zero usable, incl. non-empty all-malformed → 400); `Left (UnknownIntent n) -> throwError (unknownErr n)`; `Left _ -> throwError (PromptUpstreamError "LLM returned unparseable output")`.

  Note: `dispatch` passes the WHOLE `rows` (not just `usable`) so malformed elements are still reported as `FailedTransaction`s in the 200 response.
- [ ] **Step 5: Format + lint + build + full test.** `just format && just lint && cabal build all -fci && cabal test all -fci`. Expected: PASS (barring the environmental `eventium_test` DB cases noted in project memory).
- [ ] **Step 6: Commit**

```bash
git add src/Application/Services/Prompt/Transaction/Handler.hs src/Application/Services/PromptService.hs test/…
git commit -m "feat(prompt): tolerate malformed transactions; commit good, report bad"
```

---

## Task 6: Full verification + web-client follow-up note

- [ ] **Step 1: Clean-build gate.** `just rebuild` then `cabal test all -fci` to defeat the warm-cache `-Werror` masking noted in project memory. Expected: green (excluding environmental `eventium_test` failures).
- [ ] **Step 2: Grep for stragglers.** `grep -rn "skippedCount\|Right Nothing\|Maybe TransactionId" src` and confirm no stale references to the removed shapes remain in the touched modules.
- [ ] **Step 3: Record the web-client follow-up.** The `../monorepo` client consumes `AccountImportSummary.skippedCount`; note (issue/PR description) that it must switch to the `skipped: string[]` field. Out of scope for this backend branch.
- [ ] **Step 4: Final commit if any doc/status change** (e.g. flip the spec + this plan frontmatter `status:` to `completed`).
