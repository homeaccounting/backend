---
status: completed
issue: https://github.com/homeaccounting/backend/issues/56
---

# Flatten service functions — less Either-nesting, keep AppM signatures

## Problem

Most service modules under `src/Application/Services/` are written as deeply
nested `case ... of Left / Right` ladders around each
`AppM (Either DomainError a)` step. Representative pyramids reach 6–10 levels
before the happy path runs (e.g. `TransactionService.initiateIncome`,
`AuthService.createUserViaOAuth`, `BankImportService.importTransaction`).

This is a **readability refactor only**. No public signature, `DomainError`
value, HTTP error mapping, aggregate, or test assertion changes.

## Goal

Rewrite every service function body so the happy path reads linearly. Public
types remain `AppM (Either DomainError a)` (or `AppM a` for the few
non-fallible service functions).

Acceptance criteria from the issue:

- Every service function body in `src/Application/Services/` has at most one
  `case` or `if` level on the happy path. Nested `case` is allowed only for
  genuine multi-way branching (e.g. matching on `TransferType`).
- No changes to exported function signatures.
- `just test` stays green with no modifications to test assertions.
- `just check` passes.

## Approach

Tactical local `ExceptT DomainError AppM` inside each public function:

```haskell
publicFn :: ... -> AppM (Either DomainError a)
publicFn args = runExceptT $ do
  ...                       -- linear happy path
  x <- liftMaybeM err1 (lookupX ...)
  guardE (predicate x) err2
  liftEitherWith mapErr =<< lift (smartCtor ...)
  ExceptT (delegate ...)
  ...
```

`runExceptT` lives only at the function boundary; the `ExceptT` does not leak
into the public type. This matches RIO's stated preference of keeping
`RIO env = ReaderT env IO` flat — no `MonadError` baked into the application
monad — and is the standard RIO-compatible workaround for `Either`-ladder
readability.

## Scope

### In scope

Six service modules:

| Module                       | LOC | Pattern depth |
|------------------------------|-----|---------------|
| `TransactionService.hs`      | 679 | up to 5 nested |
| `AuthService.hs`             | 635 | up to 7 nested |
| `ConfigurationService.hs`    | 597 | up to 4 nested |
| `BankImportService.hs`       | 408 | up to 9 nested |
| `AccountService.hs`          | 364 | up to 5 nested |
| `UserService.hs`             | 267 | up to 4 nested |

### Out of scope

- `AuthorizationService.hs` — pure functions, no `Either`-ladder pattern.
- `ExchangeRatePublisher.hs` — already linear.
- Domain layer (`src/Domain/`) — `DomainError`, command handlers, aggregates,
  projections.
- Web layer (`src/Web/`) — handlers, error mapping, DTOs.
- `AppM` / `AppEnv` definition — no `MonadError` constraint added.
- Test refactoring — no spec assertions change.
- Already-linear functions: `listAccountsForUser`, `listTransactions`,
  `getProfile`, the bodies of `seedDefaultConfiguration`'s non-short-circuiting
  loops.
- Unrelated reformatting / drive-bys.

## Helper module: `Application.Services.Internal`

A new co-located helper module (~80 lines), imported only by the six
`Application.Services.*` modules. Exports:

```haskell
-- Lifting into ExceptT
liftMaybe       :: Monad m => e -> Maybe a   -> ExceptT e m a
liftMaybeM      :: Monad m => e -> m (Maybe a) -> ExceptT e m a
liftEitherWith  :: Monad m => (e1 -> e2) -> Either e1 a -> ExceptT e2 m a
guardE          :: Monad m => Bool -> e -> ExceptT e m ()

-- Aggregate command runners (one per aggregate so the canonical "rejected"
-- log line carries the aggregate name, and the CommandHandlerError -> DomainError
-- translation lives in one place).
runAccountCmd        :: ... -> ExceptT DomainError AppM [Event]
runUserCmd           :: ... -> ExceptT DomainError AppM [Event]
runConfigurationCmd  :: ... -> ExceptT DomainError AppM [Event]
runTransactionCmd    :: (CommandHandlerError TransactionError -> DomainError)
                     -> ... -> ExceptT DomainError AppM [Event]
```

Why this shape:

- `liftMaybe` / `liftMaybeM` replace ~30 occurrences of "look up X in read
  model, branch on `Maybe`".
- `liftEitherWith` covers `mkAccountId`, `mkUserId`, smart-constructor
  failures with a custom `DomainError` producer.
- `runXCmd` collapses ~15 inlined triplets of
  `liftIO $ apply...Command` + `logError "X rejected"` + `pure (Left (XError ...))`.
- `runTransactionCmd` takes an explicit translator so
  `TransactionService.translateTransactionError` (which maps
  `CannotEditLabelsInCurrentState` and `CannotChangeCategoryOnInternalTransfer`
  to dedicated `DomainError` constructors) stays local to the service that
  cares about it.
- One runner per aggregate (instead of one polymorphic runner) keeps the call
  site explicit and the `XError` constructor selection mechanical.

### Helper-module tests

`test/Application/Services/InternalSpec.hs` — unit tests for `liftMaybe`,
`liftMaybeM`, `liftEitherWith`, `guardE`. Aggregate runners are covered
transitively by the existing service specs.

## Logging policy

Hybrid: canonical noise consolidated, contextual logs preserved.

### Lines that disappear (replaced by helper-emitted line)

- 15 × `logError "X rejected by domain"` after `apply*Command` failure → emitted
  once inside each `runXCmd` as `logError "<aggregate> command rejected: " <> displayShow err`.
- 10 × `logWarn "X not found"` followed by `Left (NotFound ...)` → **deleted
  outright.** The `liftMaybe`/`liftMaybeM` lifters are polymorphic over
  `Monad m` and carry no logger; threading one in just to emit a debug line
  was rejected during Task 1 review as not worth the API noise. `NotFound`
  is a normal client-error path (user typed a wrong UUID, asked for someone
  else's account); the `DomainError` itself plus the HTTP layer's structured
  error response are sufficient. Operators wanting per-lookup-miss visibility
  should add a request-scoped log middleware, not bake it into the lifter.

### Lines that stay verbatim

- Top-of-function `logInfo` banners (`"Initiating money transfer..."` etc.).
- Success logs (`"Account created"`, `"Configuration cloned successfully: ..."`).
- Domain-meaningful warnings carrying information beyond the error itself
  (`"OAuth provider did not return email"`, `"Cannot unlink last login method"`,
  `"User is not account owner"`).
- `seedDefaultConfiguration`'s per-entry `logWarn` lines (function stays
  outside `ExceptT`).

### Lines that get deleted outright

- `logCrossCurrencyRate` helper and its call site in
  `BankImportService.importTransaction` — stale Phase 1 diagnostic; Phase 2 has
  landed.

### Behaviour invariant

The `Either` shape and `DomainError` payload returned to callers is
byte-identical at every site. Tests assert on `Left` payloads, not on log
output, so `just test` stays green with no test changes.

## Per-service inventory

### `TransactionService.hs`

Public functions rewritten:

- `initiateTransfer`, `initiateIncome`, `initiateExpense`,
  `initiateInternalTransfer`, `getTransaction`, `setTransactionLabels`,
  `changeTransactionCategory`.

Local helpers flattened: `validateLabels`, `categoryExists`,
`ensureEditorAccess`, `dispatchEdit`, `resolveAndInitiate`,
`queryTransactionResult`, `resolveAmounts`. `translateTransactionError` stays
as-is and is passed into `runTransactionCmd`. `listTransactions` is already
linear and untouched.

### `AccountService.hs`

`createAccount`, `getAccount`, `shareAccount`, `revokeAccountAccess`,
`setOverdraftLimit`, `setAccountSubtype`. `listAccountsForUser` already
linear — untouched.

### `AuthService.hs`

`register`, `login`, `initiateOAuth`, `handleOAuthCallback`, `linkOAuth`,
`authenticateTelegram`, `linkTelegram`, `refreshToken`,
`findOrCreateTelegramBotUser`. Local helpers `generateAuthResult`,
`createUserViaOAuth`, `createUserViaTelegram` (the two latter are the deepest
stacks — collapsing those is the largest readability win in this service).

### `ConfigurationService.hs`

`getConfigurationForUser`, `changeBaseCurrency`, `changeDefaultCurrency`,
`addDictionaryEntry`, `renameDictionaryEntry`, `removeDictionaryEntry`,
`setBankingDefaultIncomeCategory`, `setBankingDefaultExpenseCategory`,
`setBankingMccExpenseCategoryMap`. Local helpers `lookupUserConfiguration`,
`ensureClonedConfiguration`, `cloneConfiguration` flattened.

`seedDefaultConfiguration` is a deliberate special case — it intentionally
does not short-circuit on per-entry failures (it logs warning and continues
seeding remaining entries). It stays in `AppM` directly without `ExceptT`;
only its outermost `case` over `getConfiguration` collapses to a top-level
existence check.

### `UserService.hs`

`getProfile`, `changePassword`, `unlinkOAuth`, `unlinkTelegram`.

### `BankImportService.hs`

`importTransaction` (the deepest pyramid in the codebase: nine nested levels).
The `where`-bound helpers `classifyEndpoints` and `buildTransferCmd` stay;
`logCrossCurrencyRate` is deleted. `resync` (the outer driver) already
short-circuits per-account intentionally; only the inner `processAccount` body
is linearized.

## Verification gates

Per-service, after each rewrite:

1. `just build` clean (CI uses `-Werror` via the `-fci` flag).
2. `just test --test-option='--match' --test-option="<ServiceName>"` green.
3. `just check` (ormolu + hlint) clean. No new hlint suppressions per CLAUDE.md.

Final acceptance gate (issue's literal requirements):

- Every service function body has at most one `case` or `if` level on the
  happy path. Surviving nested `case` only for genuine multi-way branching
  (`TransferType`, `OAuthProvider`, `AccountType`, etc.); each survivor
  enumerated in the implementation plan with justification.
- `just test` and `just check` green on the final commit.
- **Strict invariant — exported surfaces:** for each in-scope service module,
  the `module Application.Services.X ( … ) where` export list and the type
  signature of every function it exports are byte-identical to `master`.
  Verified by `git diff master -- src/Application/Services/<X>.hs` showing no
  changes within the export list and no changes to the type signatures
  immediately preceding any exported binding. Internal (non-exported) helper
  functions may change signature freely as part of the rewrite.

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| `ExceptT` short-circuiting changes log-emission order vs. current code | Helpers log at the failure site before `throwE`; we intentionally drop only the canonical "rejected" / "not found" duplicates per Section 4. Domain-meaningful logs stay at their current call sites. |
| `seedDefaultConfiguration` accidentally rewritten with `ExceptT` (would change behaviour) | Explicitly out of scope inside `ExceptT`; flagged in the plan, asserted against in code review. |
| New `transformers` / `mtl` import causes a build break | `transformers >= 0.5 && < 0.7` is already on the cabal path. The helper module imports `Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)` only — these are stable across the entire `0.5.x`–`0.6.x` range. We do not depend on `liftEither` (added in `transformers-0.6.0.0`); `liftMaybe`/`liftEitherWith` build their `ExceptT` values directly via the constructor, so the helper compiles against any version in the bound. No new dependency. |
| Hidden behaviour difference in error-mapping when consolidating runners | Each `runXCmd` mirrors the existing per-call-site mapping exactly: `XError "X rejected by domain"` for the generic case, special translator for `runTransactionCmd`. The implementation plan calls out the existing call sites and the helper's exact return so reviewers can verify. |

## Out-of-scope follow-ups (not in this PR)

- Promoting `MonadError DomainError` into `AppM` itself.
- Generalizing `runXCmd` into a polymorphic `runAggregateCmd` keyed by the
  aggregate type.
- Test reorganization or coverage improvements for service helpers.
