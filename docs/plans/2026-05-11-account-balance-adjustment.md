# Account Balance Adjustment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add user-facing balance reconciliation via `POST /api/accounts/:id/adjust-balance` (set-to-value with a business date), implemented as a new `TransferType = Adjustment` routed through the existing transfer saga.

**Architecture:** Set-to-value reconciliation. Service computes `delta = targetBalance − balanceAsOf(accountId, at)` and issues `InitiateTransfer` with `transferType = Adjustment` between the user's singleton External account and the target Regular account. No changes to Account aggregate, TransferManager saga, or balance-changing events. Strict overdraft (no bypass).

**Tech Stack:** Haskell GHC 9.10.3, Cabal+Hpack, RIO, Servant, Eventium 0.3.2, Aeson, Hspec, QuickCheck, LiquidHaskell. Project commands via `just`.

**Spec:** `docs/specs/2026-05-11-account-balance-adjustment-design.md`
**Issue:** [#75](https://github.com/homeaccounting/backend/issues/75)
**Branch:** `feat/account-balance-adjustment` (already created)

---

## File Map

**Modify (source):**
- `src/Domain/Core/Types.hs` — add `Adjustment` constructor to `TransferType`. Generic-derived JSON keeps working.
- `src/Application/ReadModels/Account.hs` — add `balanceAsOf` function + export.
- `src/Application/Services/AccountService.hs` — add `adjustAccountBalance` function + export.
- `src/Application/Services/TransactionService.hs` — export `resolveAndInitiate` so AccountService can reuse it (currently internal).
- `src/Web/API/AccountAPI.hs` — add `POST /api/accounts/:id/adjust-balance` route + handler.
- `src/Web/Types.hs` — add `AdjustBalanceRequest` DTO + helper updates for new `TransferType` constructor (`transferTypeToText`, `transferTypeCategoryText`).
- `src/Telegram/Formatting.hs` — extend the `transferType` case match with `Adjustment -> "Adjustment"`.
- `src/Domain/Transaction/CommandHandler.hs` — `ChangeTransactionCategory` rejection: treat `Adjustment` the same as `Transfer` (no category to change).
- `src/Domain/Transaction/Projection.hs` — same pattern in projection's category-change handling.
- `src/Application/ReadModels/Transaction.hs` — same pattern in `applyCategoryChange` and in `byCategory` filter (returns `False` for `Adjustment`).

**Modify (tests):**
- `test/Domain/Core/TypesSpec.hs` — add JSON round-trip test for `TransferType = Adjustment`.
- `test/Application/Services/AccountServiceSpec.hs` — add unit tests for `adjustAccountBalance` orchestration logic.

**Create (tests):**
- `test/Application/ReadModels/AccountSpec.hs` — unit tests for `balanceAsOf` (new file).
- `test/Application/ReadModels/AccountPropertySpec.hs` — property tests for `balanceAsOf` invariants (new file).
- `test/Application/Services/AccountServiceIntegrationSpec.hs` — integration tests covering the full adjust-balance flow (new file).
- `test/Web/API/AccountAPISpec.hs` — HTTP-layer test for the new endpoint (new file if missing; verify on Task 6).

`package.yaml` does not change. Run `hpack` after creating new test modules to refresh `backend.cabal` — `just build` runs `hpack` first.

---

## Task 1: Add `Adjustment` to `TransferType` and surface non-exhaustive matches

**Files:**
- Modify: `src/Domain/Core/Types.hs:910-918`
- Test: `test/Domain/Core/TypesSpec.hs`

- [ ] **Step 1.1: Write JSON round-trip test for `TransferType = Adjustment`**

Append to `test/Domain/Core/TypesSpec.hs` (in an appropriate `describe "TransferType"` block — add the block if it doesn't exist):

```haskell
describe "TransferType JSON" $ do
  it "round-trips Adjustment via Aeson Generic encoding" $ do
    let encoded = Aeson.encode Adjustment
    Aeson.decode encoded `shouldBe` Just Adjustment
  it "encodes Adjustment with a tag-only object (no category)" $
    Aeson.encode Adjustment `shouldBe` "{\"tag\":\"Adjustment\"}"
```

Add `Adjustment` to the import from `Domain.Core.Types` and `Data.Aeson as Aeson` import if missing.

- [ ] **Step 1.2: Run the test to verify it fails**

Run: `cabal test all --test-option='--match' --test-option='/TransferType JSON/' --test-show-details=direct`
Expected: compile error — `Adjustment` data constructor not in scope.

- [ ] **Step 1.3: Add the `Adjustment` constructor**

In `src/Domain/Core/Types.hs:910`:

```haskell
data TransferType
  = Income CategoryId
  | Expense CategoryId
  | Transfer
  | Adjustment
  deriving (Show, Eq, Generic)
```

The Generic-derived `ToJSON` / `FromJSON` instances on lines 916–918 keep working automatically.

- [ ] **Step 1.4: Try to build; resolve all non-exhaustive pattern matches**

Run: `just build`
Expected: warnings (treated as errors with `-Wall` / `-Werror` in CI) for non-exhaustive matches at these sites — update each:

1. `src/Telegram/Formatting.hs:93-96` — add a case:
   ```haskell
   Adjustment -> "Adjustment"
   ```
2. `src/Domain/Transaction/Projection.hs:290-293` (in the `ChangeTransactionCategory` handler) — adjustments have no category, so this code path should not be reachable for them, but to keep the match exhaustive:
   ```haskell
   Adjustment -> Adjustment
   ```
3. `src/Domain/Transaction/CommandHandler.hs:188-189` — reject category changes on adjustments the same way internal transfers are rejected:
   ```haskell
   case transaction ^. #transferType of
     Transfer    -> Left CannotChangeCategoryOnInternalTransfer
     Adjustment  -> Left CannotChangeCategoryOnInternalTransfer
     Income _    -> Right ()
     Expense _   -> Right ()
   ```
   Reuse the existing `CannotChangeCategoryOnInternalTransfer` constructor verbatim. Do NOT add a new error constructor and do NOT rename the existing one — the spec is explicit that no new error tags are introduced.
4. `src/Application/ReadModels/Transaction.hs:317-320` — projection mirror of (2):
   ```haskell
   Adjustment -> Adjustment
   ```
5. `src/Application/ReadModels/Transaction.hs:462-465` — `byCategory` filter:
   ```haskell
   Adjustment -> False
   ```
6. `src/Web/Types.hs:953-955` — `transferTypeToText`:
   ```haskell
   transferTypeToText Adjustment = "adjustment"
   ```
7. `src/Web/Types.hs:959-961` — `transferTypeCategoryText`:
   ```haskell
   transferTypeCategoryText Adjustment = Nothing
   ```

Run `just build` again until it succeeds with no warnings. If `grep -rn "case .* of$\|TransferType ->" src/` surfaces any additional pattern-matching site the compiler missed, handle the same way (`Adjustment` either passes through unchanged in projections, returns `False` in category filters, or is given a short label in formatters).

- [ ] **Step 1.5: Run the JSON round-trip test to verify it passes**

Run: `cabal test all --test-option='--match' --test-option='/TransferType JSON/'`
Expected: PASS.

- [ ] **Step 1.6: Run full test suite to confirm nothing regressed**

Run: `just test`
Expected: all existing tests still pass.

- [ ] **Step 1.7: Commit**

```bash
git add src/Domain/Core/Types.hs src/Telegram/Formatting.hs src/Domain/Transaction/CommandHandler.hs src/Domain/Transaction/Projection.hs src/Application/ReadModels/Transaction.hs src/Web/Types.hs test/Domain/Core/TypesSpec.hs
git commit -m "feat(domain): add Adjustment to TransferType (refs #75)"
```

---

## Task 2: `balanceAsOf` unit tests (Red)

**Files:**
- Create: `test/Application/ReadModels/AccountSpec.hs`

- [ ] **Step 2.1: Write the failing unit test module**

Create `test/Application/ReadModels/AccountSpec.hs`. Pattern after `test/Application/ReadModels/ExchangeRateSpec.hs` for structure (RIO prelude, hspec-discover compatible).

The tests should cover (using fixture event streams against `Testkit/InMemoryEventStore`):

```haskell
module Application.ReadModels.AccountSpec (spec) where

import RIO
import Test.Hspec
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Application.ReadModels.Account as AccountRM
-- plus event imports, money helpers, Testkit imports

spec :: Spec
spec = describe "Application.ReadModels.Account" $ do
  describe "balanceAsOf" $ do
    it "returns Nothing for an unknown account" $ do
      pendingWith "Will be implemented in Task 3"
    it "returns initialBalance when D >= AccountCreated and no debits/credits exist" $ do
      pendingWith "Will be implemented in Task 3"
    it "includes credits with at <= D" $ do
      pendingWith "Will be implemented in Task 3"
    it "subtracts debits with at <= D" $ do
      pendingWith "Will be implemented in Task 3"
    it "excludes credits with at > D" $ do
      pendingWith "Will be implemented in Task 3"
    it "excludes debits with at > D" $ do
      pendingWith "Will be implemented in Task 3"
    it "ignores access/overdraft events for balance purposes" $ do
      pendingWith "Will be implemented in Task 3"
```

(The skeleton uses `pendingWith` so the file builds while the actual cases are filled in alongside the implementation. Each `pendingWith` is replaced with a real assertion in Task 3.)

- [ ] **Step 2.2: Run hpack and rebuild test target**

Run: `just build`
Expected: build succeeds; the new test module is registered. (hpack discovers test files automatically.)

- [ ] **Step 2.3: Run the new spec to verify it appears as pending**

Run: `cabal test all --test-option='--match' --test-option='/Application.ReadModels.Account/' --test-show-details=direct`
Expected: 7 pending tests, all yellow.

- [ ] **Step 2.4: Commit**

```bash
git add test/Application/ReadModels/AccountSpec.hs
git commit -m "test(read-model): scaffold balanceAsOf unit spec (refs #75)"
```

---

## Task 3: Implement `balanceAsOf` (Green)

**Files:**
- Modify: `src/Application/ReadModels/Account.hs`
- Modify: `test/Application/ReadModels/AccountSpec.hs`

- [ ] **Step 3.1: Replace the first pending test with a real failing assertion**

In `test/Application/ReadModels/AccountSpec.hs`, replace the first `pendingWith` ("returns Nothing for an unknown account") with a real test using the in-memory event store from `Testkit/InMemoryEventStore`. Reference `test/Application/ReadModels/TransactionListSpec.hs` for the typical event-store setup pattern.

- [ ] **Step 3.2: Run it; verify it fails because `balanceAsOf` is not defined**

Run: `cabal test all --test-option='--match' --test-option='/balanceAsOf returns Nothing/' --test-show-details=direct`
Expected: build failure (`balanceAsOf` not in scope).

- [ ] **Step 3.3: Implement `balanceAsOf` in `Application.ReadModels.Account`**

Add to the module export list and define:

```haskell
balanceAsOf
  :: (MonadIO m, MonadReader env m, HasEventStore env)
  => AccountId
  -> UTCTime
  -> m (Maybe Money)
balanceAsOf accountId asOf = do
  events <- loadAccountEvents accountId
  pure (foldAccountEventsAsOf asOf events)
```

with helpers:

```haskell
foldAccountEventsAsOf :: UTCTime -> [AccountEvent] -> Maybe Money
foldAccountEventsAsOf _ [] = Nothing
foldAccountEventsAsOf asOf (AccountCreatedEvent c : rest) =
  Just (foldl' (applyAsOf asOf) c.initialBalance rest)
foldAccountEventsAsOf asOf (_ : rest) =
  foldAccountEventsAsOf asOf rest -- skip non-genesis prefix if any

applyAsOf :: UTCTime -> Money -> AccountEvent -> Money
applyAsOf asOf bal evt = case evt of
  AccountDebitedEvent  e | e.at <= asOf -> bal `subtractMoneyUnchecked` e.amount
  AccountCreditedEvent e | e.at <= asOf -> bal `addMoneyUnchecked`      e.amount
  _ -> bal
```

(Adjust naming and money helpers to match what the module currently uses for current-balance computation around lines 270-300 — reuse the same `addMoney`/`subtractMoney` if they suit; otherwise lift the same logic.)

`loadAccountEvents` should follow the same approach the existing read-model uses to read an aggregate stream from eventium. Inspect `src/Application/ReadModels/Account.hs` to find the existing pattern; if there's no per-aggregate load helper, add a small one in this module (do not put it in Infrastructure unless that's the established pattern).

Export `balanceAsOf` from the module.

- [ ] **Step 3.4: Run the first test; verify it passes**

Run: `cabal test all --test-option='--match' --test-option='/balanceAsOf returns Nothing/'`
Expected: PASS.

- [ ] **Step 3.5: One-by-one, fill in each remaining `pendingWith` with a real assertion and run after each**

For each of the six remaining cases ("returns initialBalance…", "includes credits…", "subtracts debits…", "excludes credits with at > D", "excludes debits with at > D", "ignores access/overdraft events"):

a. Replace the `pendingWith` with a real arrange-act-assert against a fixture event stream.
b. Run: `cabal test all --test-option='--match' --test-option='/<case substring>/' --test-show-details=direct`
c. If it fails, adjust the implementation; iterate until green.

Use distinct `UTCTime` constants like `t1, t2, t3` ascending, and choose dates so each test exercises one boundary condition cleanly.

- [ ] **Step 3.6: Run full suite to confirm no regression**

Run: `just test`
Expected: all green.

- [ ] **Step 3.7: Format and lint**

Run: `just check`
Expected: clean.

- [ ] **Step 3.8: Commit**

```bash
git add src/Application/ReadModels/Account.hs test/Application/ReadModels/AccountSpec.hs
git commit -m "feat(read-model): add balanceAsOf temporal balance query (refs #75)"
```

---

## Task 4: `balanceAsOf` property tests

**Files:**
- Create: `test/Application/ReadModels/AccountPropertySpec.hs`

- [ ] **Step 4.1: Write the property spec**

Create the file with three QuickCheck properties (reference `test/Application/ReadModels/TransactionListPropertySpec.hs` for generator patterns and Spec scaffolding):

```haskell
module Application.ReadModels.AccountPropertySpec (spec) where

-- imports: RIO, Test.Hspec, Test.QuickCheck, Testkit.Generators, etc.

spec :: Spec
spec = describe "Application.ReadModels.Account properties" $ do
  prop "balanceAsOf at t=+infty equals the running current balance" $
    \(genAccountEventStream -> events) ->
      ...
  prop "balanceAsOf is monotonic non-decreasing across credit-only suffixes" $
    \(genCreditsOnlyTail -> (eventsUpTo, credits)) ->
      ...
  prop "balanceAsOf direction-of-delta equals signum (X - balanceAsOf t)" $
    \(genAccountState -> state) targetBalance asOf ->
      ...
```

Each property should drive `balanceAsOf` against `Testkit/InMemoryEventStore` and assert the invariant from the spec ("Property" subsection).

- [ ] **Step 4.2: Build and run**

Run: `just build && cabal test all --test-option='--match' --test-option='/Application.ReadModels.Account properties/' --test-show-details=direct`
Expected: PASS (the implementation from Task 3 should already satisfy these).

- [ ] **Step 4.3: Commit**

```bash
git add test/Application/ReadModels/AccountPropertySpec.hs
git commit -m "test(read-model): add balanceAsOf property invariants (refs #75)"
```

---

## Task 5: Expose `resolveAndInitiate` from `TransactionService`

**Files:**
- Modify: `src/Application/Services/TransactionService.hs:25-36`

- [ ] **Step 5.1: Add `resolveAndInitiate` to the module's export list**

Append `resolveAndInitiate,` to the export list at the top of `src/Application/Services/TransactionService.hs`. No code body changes.

- [ ] **Step 5.2: Build**

Run: `just build`
Expected: success.

- [ ] **Step 5.3: Commit**

```bash
git add src/Application/Services/TransactionService.hs
git commit -m "refactor(transaction-service): export resolveAndInitiate (refs #75)"
```

---

## Task 6: `adjustAccountBalance` service — integration test scaffolding (Red)

**Files:**
- Create: `test/Application/Services/AccountServiceIntegrationSpec.hs`

- [ ] **Step 6.1: Create the integration spec skeleton**

Pattern after `test/Application/Services/ConfigurationServiceIntegrationSpec.hs` for the testkit setup (in-memory event store, full app env, etc.).

Test cases (start each as `pendingWith` so the file builds before the implementation lands):

```haskell
describe "AccountService.adjustAccountBalance" $ do
  it "applies a positive delta as External -> Regular and records the Adjustment transaction" $ pendingWith "..."
  it "applies a negative delta within overdraft as Regular -> External" $ pendingWith "..."
  it "backdate: balanceAsOf(D) == targetBalance and future credits ride on top" $ pendingWith "..."
  it "rejects when the account is External" $ pendingWith "..."
  it "rejects when target balance currency does not match account currency" $ pendingWith "..."
  it "rejects when at > now" $ pendingWith "..."
  it "rejects when delta is zero" $ pendingWith "..."
  it "rejects when negative delta would exceed overdraft (saga FailTransfer)" $ pendingWith "..."
  it "rejects when caller has Viewer role" $ pendingWith "..."
  it "handles cross-currency by passing through resolveAndInitiate (USD External, EUR account)" $ pendingWith "..."
```

- [ ] **Step 6.2: Run hpack and build**

Run: `just build && cabal test all --test-option='--match' --test-option='/adjustAccountBalance/' --test-show-details=direct`
Expected: 10 pending tests visible.

- [ ] **Step 6.3: Commit**

```bash
git add test/Application/Services/AccountServiceIntegrationSpec.hs
git commit -m "test(account-service): scaffold adjustAccountBalance integration spec (refs #75)"
```

---

## Task 7: Implement `adjustAccountBalance` (Green)

**Files:**
- Modify: `src/Application/Services/AccountService.hs`
- Modify: `test/Application/Services/AccountServiceIntegrationSpec.hs`

- [ ] **Step 7.1: Replace the first happy-path test with a real assertion**

Fill the "applies a positive delta as External -> Regular…" test:
- Arrange: create user + Regular EUR account with initial balance 100 EUR.
- Act: `AccountService.adjustAccountBalance userId accountId (mkMoney "150" EUR) now "Reconcile"`
- Assert:
  - Right result with a `TransactionId`.
  - `getAccount accountId` returns balance 150 EUR.
  - The resulting transaction has `transferType = Adjustment` and `description = "Reconcile"`.

- [ ] **Step 7.2: Run the test; verify it fails**

Run: `cabal test all --test-option='--match' --test-option='/applies a positive delta/'`
Expected: fails because `adjustAccountBalance` is not defined.

- [ ] **Step 7.3: Implement `adjustAccountBalance`**

In `src/Application/Services/AccountService.hs`:

```haskell
adjustAccountBalance
  :: UserId
  -> AccountId
  -> Money       -- target balance, must be in account's currency
  -> UTCTime     -- business date D
  -> Text        -- reason / description
  -> AppM (Either DomainError (TransactionId, TransactionData))
adjustAccountBalance userId accountId targetBalance asOf reason = runExceptT $ do
  now <- liftIO getCurrentTime
  guardE (asOf <= now) (ValidationErr (mkValidationError "at" "Adjustment date must be in the past or present" (tshow asOf)))

  -- 1. Authorize Editor+
  ExceptT (AuthorizationService.requireEditor userId accountId)

  -- 2. Load account; reject External
  accountRM <- lift (view accountReadModelL)
  account <- liftMaybeM (NotFound "Account" (tshow accountId))
                       (AccountRM.getAccount accountRM accountId)
  guardE (account.accountType /= External)
         (ValidationErr (mkValidationError "accountType" "Cannot adjust an External account" (tshow accountId)))

  -- 3. Currency match
  guardE (moneyCurrency targetBalance == moneyCurrency account.balance)
         (ValidationErr (mkValidationError "currency" "Currency does not match account currency" (tshow (moneyCurrency targetBalance))))

  -- 4. External account lookup
  userRM <- lift (view userReadModelL)
  userData <- liftMaybeM (NotFound "User" (tshow userId)) (UserRM.getUser userRM userId)
  let externalAccId = userData.externalAccountId
  externalAccount <- liftMaybeM (NotFound "Account" (tshow externalAccId))
                                (AccountRM.getAccount accountRM externalAccId)

  -- 5. Compute delta against historical balance
  currentAtD <- liftMaybeM (NotFound "Account" (tshow accountId))
                          =<< lift (AccountRM.balanceAsOf accountId asOf)
  let delta = subtractMoneyUnchecked targetBalance currentAtD

  -- 6. Reject no-op
  guardE (not (moneyIsZero delta))
         (ValidationErr (mkValidationError "targetBalance" "Target balance equals current balance at this date" (tshow targetBalance)))

  -- 7. Direction + amount
  let (sourceAccId, targetAccId, magnitude)
        | moneyIsPositive delta = (externalAccId, accountId, delta)
        | otherwise             = (accountId, externalAccId, negateMoney delta)
      srcCurrency = moneyCurrency (if moneyIsPositive delta then externalAccount.balance else account.balance)
      tgtCurrency = moneyCurrency (if moneyIsPositive delta then account.balance else externalAccount.balance)
      -- user supplies the magnitude in the target account's currency (matches Income/Expense convention)
      userAmountIsSource = not (moneyIsPositive delta)

  -- 8. Cross-currency + saga
  ExceptT
    ( TransactionService.resolveAndInitiate
        (Just asOf) now magnitude srcCurrency tgtCurrency userAmountIsSource Nothing
        $ \date srcAmt tgtAmt rate ->
          InitiateTransfer
            { sourceAccountId = sourceAccId
            , targetAccountId = targetAccId
            , sourceAmount = srcAmt
            , targetAmount = tgtAmt
            , exchangeRate = rate
            , description = reason
            , initiatedBy = userId
            , at = date
            , transferType = Adjustment
            , externalTransactionId = Nothing
            , labels = mempty
            }
    )
```

Notes:
- Reuse `moneyCurrency`, `moneyIsZero`, `moneyIsPositive`, `negateMoney`, `subtractMoneyUnchecked` if they exist under those names; otherwise add the minimal equivalent next to existing money helpers. Do not invent new types.
- **`userAmountIsSource` worked example.** Mirrors `initiateIncome` / `initiateExpense` (lines 230 and 287 of `TransactionService.hs`). The user always supplies the adjustment magnitude *in the regular account's currency* (the account being adjusted). Two cases:
  - **Positive delta** — direction is `External → Regular`, so `sourceAccountId = externalAccId`, `targetAccountId = accountId`, `sourceCurrency = External.currency`, `targetCurrency = account.currency`. The user-supplied magnitude is in `account.currency` = the *target's* currency, so `userAmountIsSource = False`. Example: EUR account, USD External, user wants +50 EUR — `resolveAndInitiate` converts the target amount (50 EUR) into the source amount (`X` USD via inverse ECB rate).
  - **Negative delta** — direction is `Regular → External`, so `sourceAccountId = accountId`, `targetAccountId = externalAccId`, `sourceCurrency = account.currency`, `targetCurrency = External.currency`. The user-supplied magnitude is in `account.currency` = the *source's* currency, so `userAmountIsSource = True`. Example: EUR account, USD External, user wants −30 EUR — `resolveAndInitiate` converts the source amount (30 EUR) into the target amount (`Y` USD via direct ECB rate).
- Concretely: `userAmountIsSource = not (moneyIsPositive delta)`.

Add `adjustAccountBalance` to the module export list.

- [ ] **Step 7.4: Run the happy-path test; iterate until green**

Run: `cabal test all --test-option='--match' --test-option='/applies a positive delta/'`
Expected: PASS.

- [ ] **Step 7.5: Fill in the remaining test cases one-by-one**

For each of the remaining 9 cases:

a. Replace the `pendingWith` with the concrete arrange-act-assert.
b. Run with `--match '/<case substring>/'`.
c. Adjust the implementation only if a real bug surfaces (most should pass once the happy path works).
d. Commit per case if changes were needed (DRY: prefer one commit per logically-related batch).

Special attention on:
- **Backdate test**: confirms `balanceAsOf(D) == targetBalance` post-adjustment and that later-dated credits accumulate on top.
- **Overdraft rejection test**: asserts the resulting transaction is in `Failed` state with the saga's existing insufficient-funds reason; HTTP-layer mapping is verified in Task 8, not here.
- **Cross-currency test**: must seed an exchange rate in the in-memory read model (see how `TransactionServiceSpec` does this for Income/Expense cross-currency).

- [ ] **Step 7.6: `just check && just test`**

Expected: all green; ormolu + hlint clean.

- [ ] **Step 7.7: Commit**

```bash
git add src/Application/Services/AccountService.hs test/Application/Services/AccountServiceIntegrationSpec.hs
git commit -m "feat(account-service): add adjustAccountBalance (refs #75)"
```

---

## Task 8: HTTP endpoint `POST /api/accounts/:id/adjust-balance`

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/AccountAPI.hs`
- Create or modify: `test/Web/API/AccountAPISpec.hs`

- [ ] **Step 8.1: Write the HTTP-layer test first**

In `test/Web/API/AccountAPISpec.hs` (create if absent — pattern after `test/Web/API/TransactionAPISpec.hs` if present, else use Servant's `servantClient` / `wai-test` idiom already used in the project):

```haskell
describe "POST /api/accounts/:id/adjust-balance" $ do
  it "returns 201 with the resulting transaction for a positive adjustment" $ do
    pendingWith "Implement in Step 8.4"
  it "returns 400 when caller has Viewer role" $ pendingWith "..."
  it "returns 404 when account does not exist" $ pendingWith "..."
  it "returns 422 when targetBalance currency does not match" $ pendingWith "..."
  it "returns 422 when at > now" $ pendingWith "..."
  it "returns 422 when delta is zero" $ pendingWith "..."
  it "returns 422 when account is External" $ pendingWith "..."
```

Run: `just build && cabal test all --test-option='--match' --test-option='/adjust-balance/' --test-show-details=direct`
Expected: pending list appears.

- [ ] **Step 8.2: Define the request DTO**

In `src/Web/Types.hs`, alongside the existing `IncomeRequest` / `ExpenseRequest` DTOs (around line 342). **First check what date field name `IncomeRequest` / `ExpenseRequest` already use** (they currently expose a `date :: Maybe UTCTime` field — verify before writing). Match that convention to avoid a name collision with the `at :: UTCTime` field that lives on event payloads (with `OverloadedRecordDot` + `DuplicateRecordFields`, an unqualified `req.at` in the handler can be inferred against the wrong record). Use the existing DTO field name (`date`):

```haskell
data AdjustBalanceRequest = AdjustBalanceRequest
  { targetBalance :: Text   -- decimal string, e.g. "1234.56"
  , currency :: Text         -- ISO code, e.g. "EUR"
  , date :: UTCTime          -- business date (what the spec calls "at")
  , reason :: Text
  } deriving (Generic, Show, Eq)

instance ToJSON AdjustBalanceRequest
instance FromJSON AdjustBalanceRequest
```

Add `AdjustBalanceRequest (..)` to the module export list. In the handler (Step 8.3) pass `req.date` as the `asOf` argument to `adjustAccountBalance` — that function internally treats it as the business date `at`. If `IncomeRequest`/`ExpenseRequest` turn out to use a different field name, match theirs.

- [ ] **Step 8.3: Add the route and handler**

In `src/Web/API/AccountAPI.hs`:

a. Extend `AccountAPI` type with the new route (Servant DSL — pattern after `setOverdraftLimit`):
   ```haskell
   :<|> AuthProtect "jwt"
        :> "api" :> "accounts" :> Capture "id" UUID
        :> "adjust-balance"
        :> ReqBody '[JSON] AdjustBalanceRequest
        :> PostCreated '[JSON] TransactionResponse
   ```

b. Add the handler:
   ```haskell
   adjustBalanceHandler
     :: AuthenticatedUser -> UUID -> AdjustBalanceRequest -> AppM TransactionResponse
   adjustBalanceHandler authUser accountUuid req = do
     accountId <- validateField "id" (mkAccountId accountUuid)
     currency  <- validateField "currency" (parseCurrency req.currency)
     amount    <- validateField "targetBalance" (mkMoney req.targetBalance currency)
     result    <- AccountService.adjustAccountBalance authUser.userId accountId amount req.at req.reason
     case result of
       Right (txId, tx) -> pure (toTransactionResponse txId tx)
       Left err          -> throwDomainError err
   ```

c. Wire it into `accountServer` alongside the other handlers and export it (`adjustBalanceHandler` in the module export list).

- [ ] **Step 8.4: Fill in each HTTP test, one at a time, running after each**

Same iterative loop as Task 7.5: replace `pendingWith` with concrete assertions and run focused tests. Verify error→HTTP mappings match the spec's table (in particular: 400 for Viewer/Editor+ rejection — matches the existing `AccountError` convention; 404 for unknown account; 422 for validation errors).

- [ ] **Step 8.5: `just check && just test`**

Expected: all green; lint+format clean.

- [ ] **Step 8.6: Commit**

```bash
git add src/Web/Types.hs src/Web/API/AccountAPI.hs test/Web/API/AccountAPISpec.hs
git commit -m "feat(api): add POST /api/accounts/:id/adjust-balance (refs #75)"
```

---

## Task 9: Report-exclusion verification

**Files:**
- Modify: `test/Application/ReadModels/TransactionQuerySpec.hs` (or whichever spec exercises `byCategory` / category-filtered queries; verify by running tests after Task 1 already touched `byCategory`)

- [ ] **Step 9.0: Confirm no other aggregator silently absorbs Adjustment rows**

Run an explicit search for any other read-side pattern match that switches on `TransferType`:

```bash
grep -rn "case .*transferType\|transferType of" src/Application/ src/Domain/ src/Web/ 2>/dev/null
```

The compiler's exhaustiveness check is **not** sufficient on its own here — sites like `byCategory` legitimately return `False` for the new constructor (added in Task 1), which silently excludes adjustments from category filters. That's the correct behavior, but it also means any *new* aggregator added after Task 1 wouldn't fail to build either. Verify the list of `TransferType`-matching sites is exactly the seven covered by Task 1 (Telegram formatter, Projection, CommandHandler, ReadModel projection, ReadModel byCategory filter, `transferTypeToText`, `transferTypeCategoryText`). If grep surfaces a site Task 1 missed, treat that as an issue to handle before continuing.

- [ ] **Step 9.1: Add a focused test that emits one Income, one Expense, one Adjustment, then filters by each of the Income and Expense categories**

In `test/Application/ReadModels/TransactionQuerySpec.hs` (or a new `TransactionQueryAdjustmentSpec.hs` if that file is large), add a test asserting:
- A `byCategory <incomeCat>` query returns only the Income.
- A `byCategory <expenseCat>` query returns only the Expense.
- The Adjustment is included by an unfiltered listing.

- [ ] **Step 9.2: Build and run**

Run: `cabal test all --test-option='--match' --test-option='/byCategory/' --test-show-details=direct`
Expected: PASS (Task 1 already handled the filter; this test locks the behavior in).

- [ ] **Step 9.3: Commit**

```bash
git add test/Application/ReadModels/TransactionQuerySpec.hs
git commit -m "test(read-model): assert Adjustment excluded from category filters (refs #75)"
```

---

## Task 10: Final integration check + push

- [ ] **Step 10.1: Full build, lint, test**

```bash
just check
just test
```

Expected: format/lint clean, all tests green.

- [ ] **Step 10.2: Verify CI build flag**

```bash
cabal build -fci
```

Expected: builds with `-Werror`.

- [ ] **Step 10.3: Update the spec frontmatter to `in-progress`**

Edit `docs/specs/2026-05-11-account-balance-adjustment-design.md`: change `status: draft` → `status: in-progress`.

```bash
git add docs/specs/2026-05-11-account-balance-adjustment-design.md
git commit -m "docs(specs): mark balance adjustment spec in-progress"
```

- [ ] **Step 10.4: Push branch and open PR**

Confirm with the user before pushing. On confirmation:

```bash
git push -u origin feat/account-balance-adjustment
gh pr create --title "feat(account): adjust account balance (set-to-value)" --body "$(cat <<'EOF'
## Summary
- Adds POST /api/accounts/:id/adjust-balance — set-to-value reconciliation with backdated semantics.
- New TransferType = Adjustment, routed through the existing transfer saga via the singleton External account.
- New Application.ReadModels.Account.balanceAsOf temporal query.

Closes #75.

## Test plan
- [ ] just test
- [ ] cabal build -fci
- [ ] Manual: POST positive adjustment, verify balance & transaction history.
- [ ] Manual: POST negative adjustment within overdraft.
- [ ] Manual: POST backdated adjustment, verify future credits ride on top.
- [ ] Manual: POST cross-currency adjustment (USD External, EUR account).
EOF
)"
```

- [ ] **Step 10.5: Comment the PR link on issue #75**

```bash
gh issue comment 75 --body "Implementation PR: <PR URL>"
```

---

## Notes for the implementer

- **TDD discipline:** every functional change has a test that was red before it was green. The `pendingWith` scaffolding pattern lets you commit a planned spec early and fill it in iteratively without breaking the build.
- **Commit cadence:** one commit per task minimum; per coherent step inside long tasks is encouraged. Per project memory: push to the remote after each task during PR work — don't batch.
- **No new error constructors.** Every failure mode in the spec reuses an existing `DomainError` variant (`ValidationErr`, `NotFound`, `AuthorizationError`, the saga `InsufficientFunds` path). If you find yourself wanting a new constructor, stop and reread the spec's error table.
- **No saga changes.** If any task feels like it requires touching `TransferManager`, `DebitAccount`, `CreditAccount`, or the balance-changing events, stop — the design says it shouldn't, and that's a load-bearing constraint.
- **Compiler is your guide.** When in doubt about which sites pattern-match `TransferType`, let the warnings drive the list; the spec lists the audited sites but the build is authoritative.
- **Skill references:**
  - @superpowers:test-driven-development for the Red-Green-Refactor cadence inside each task.
  - @superpowers:verification-before-completion before marking any task done.
