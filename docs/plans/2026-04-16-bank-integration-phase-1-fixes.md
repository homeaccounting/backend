---
status: draft
---

# Bank Integration Phase 1 Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address critical and important findings from PR #39 review by reducing Phase 1 scope to resync-only, deleting the non-functional webhook surface, and fixing correctness/security issues in the remaining code.

**Architecture:** Three concerns. (1) **Deletion pass** removes the webhook endpoints, `BankLinkState` read model, `BankLink` domain events, and `webhook_secret` config — none of which are functional today. (2) **Hardening pass** fixes cross-currency handling, moves minor-unit scaling into the Monobank adapter, introduces a per-user in-process import lock to close the dedup TOCTOU, makes the Monobank base URL config-injectable, gates the endpoint behind `banking.enabled` + `monobank.enabled`, filters IBAN candidates by role, and moves the Mono token to `Authorization: Bearer`. (3) **Tests pass** closes the reviewer-identified coverage gaps (JSON parsing, backwards-compat, IBAN matching, cross-currency, dedup idempotency).

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Servant + Warp, Eventium event sourcing, Hspec + QuickCheck, LiquidHaskell, ormolu, hlint. Build via `just build`, test via `just test`.

**Spec:** `docs/specs/2026-04-10-bank-integration-design.md` (see top-of-file Phase 1 amendment dated 2026-04-16).

---

## File structure

### Deleted
- `src/Application/ReadModels/BankLinkState.hs`
- `src/Domain/BankLink.hs`
- `src/Domain/BankLink/Events.hs`

### Created
- `test/Web/API/BankingAPISpec.hs` — IBAN matching unit tests (extracted from `BankImportWorkflowSpec` where needed)
- `test/Infrastructure/Banking/MonobankSpec.hs` — JSON parsing + classification (currently classification lives in `BankImportServiceSpec`; split out)
- `test/Domain/Transaction/EventsSpec.hs` (or extend existing) — `TransferInitiated` JSON backwards-compat

### Modified
- `src/Web/API/BankingAPI.hs` — drop webhook routes/handlers; gate resync; Auth header for token; Viewer filter; multi-match log
- `src/Application/Services/BankImportService.hs` — drop `processWebhookTransaction`; cross-currency fix; remove `ClassifiedTransfer` branch; use per-user lock; structured resync result
- `src/Application/ReadModels/BankImportReadModel.hs` — unchanged (already correct)
- `src/Domain/Core/Types.hs` — `ExternalTransactionId` newtype with smart constructor; LH refinement; exports
- `src/Domain/Models.hs` — drop `bankLinkEventEmbedding` and `BankLink` branch from `AccountingEvent`
- `src/Domain/Transaction/Commands.hs`, `src/Domain/Transaction/Events.hs` — update to new `ExternalTransactionId` newtype
- `src/Infrastructure/Banking/Provider.hs` — drop `ClassifiedTransfer`; change `BankTransaction.amount` to `Rational` (major units); update field docs
- `src/Infrastructure/Banking/Monobank.hs` — accept `apiBaseUrl` argument; move `/100` scaling into `toProviderTransaction`; cross-currency `originalAmount` propagation
- `src/Infrastructure/Config.hs` — drop `BankingConfig.webhookSecret`; add `MonobankProviderConfig.apiBaseUrl`
- `src/Infrastructure/App.hs` — drop `bankLinkState` field from `AppEnv` and `HasBankLinkState` class; add `importLocks :: TVar (Set UserId)` and `HasImportLocks` class
- `src/Infrastructure/Eventium.hs` — drop `BankLinkState` wiring
- `app/Main.hs` — drop `BankLinkState` creation; pass `apiBaseUrl` from config; initialize `importLocks`
- `config/local.yaml`, `config/test.yaml`, `config/prod.yaml` — drop `banking.webhook_secret`; add `banking.providers.monobank.api_base_url`
- `test/Testkit/InMemoryEventStore.hs` — update `ServerConfig` / `AppEnv` fixture shape
- `test/Application/Services/BankImportServiceSpec.hs` — update to Rational amounts, new classifier, removed `processWebhookTransaction`
- `test/Integration/BankImportWorkflowSpec.hs` — update fixture shape; add dedup idempotency property

---

## Task 1: Delete webhook endpoints from `BankingAPI`

**Files:**
- Modify: `src/Web/API/BankingAPI.hs`

- [ ] **Step 1: Remove webhook branches from `BankingAPI` type and server**

Delete the two webhook sub-routes from `type BankingAPI` (lines 79-94) leaving only the resync branch. Replace the API type with:

```haskell
type BankingAPI =
  AuthProtect "jwt"
    :> "api"
    :> "banking"
    :> "resync"
    :> ReqBody '[JSON] ResyncRequest
    :> Post '[JSON] ResyncResponse
```

Replace `bankingServer = webhookValidationHandler :<|> webhookEventHandler :<|> resyncHandler` with `bankingServer = resyncHandler`.

Delete the `webhookValidationHandler` and `webhookEventHandler` functions (lines 163-176) and remove them from the module export list (lines 35-36).

Update the module Haddock to reflect that the webhook endpoints are deferred to Phase 2 (matches the spec amendment).

- [ ] **Step 2: Build to verify**

Run: `just build`
Expected: PASS (webhook handlers referenced nothing exported from `BankLinkState` that other modules also reference; build should succeed).

- [ ] **Step 3: Commit**

```bash
git add src/Web/API/BankingAPI.hs
git commit -m "refactor(banking): remove non-functional webhook endpoints

Phase 1 is resync-only per spec amendment 2026-04-16. The webhook
validation/event handlers were stubs with no secret validation, no
payload parsing, and no call to BankImportService. Deleting them
rather than shipping security-dangerous stubs."
```

---

## Task 2: Delete `BankLinkState` read model

**Files:**
- Delete: `src/Application/ReadModels/BankLinkState.hs`
- Modify: `src/Application/Services/BankImportService.hs`, `src/Web/API/BankingAPI.hs`

- [ ] **Step 1: Inline `UserBankLink` / `AccountMapping` into the two call sites**

`BankImportService.importTransaction` uses `findAccountMapping link tx.accountId` and `link.accountMappings`. `BankingAPI.buildBankLink` returns a `UserBankLink`. Neither actually needs a named type any more — both can use a local `[(BankAccountId, AccountId)]` (externalAccountId → local AccountId).

In `src/Application/Services/BankImportService.hs`:
- Drop `Application.ReadModels.BankLinkState` import.
- Change the third parameter of `resync`, `processWebhookTransaction`, `importTransaction` from `UserBankLink` to `[(BankAccountId, AccountId)]` (import `BankAccountId` from `Infrastructure.Banking.Provider`, `AccountId` from `Domain.Core.Types`).
- Replace `link.accountMappings` with the list directly; replace `findAccountMapping link tx.accountId` with `lookup tx.accountId link`.
- Remove `processWebhookTransaction` entirely (it's an alias only used by the deleted webhook handler).

In `src/Web/API/BankingAPI.hs`:
- Drop `Application.ReadModels.BankLinkState` import.
- Change `buildBankLink :: ... -> AppM [(BankAccountId, AccountId)]`; its body is `mapMaybe matchAccount bankAccounts` where `matchAccount` returns `Maybe (BankAccountId, AccountId)`.
- Remove the `webhookSecret`, `bankName`, and synthetic `UserBankLink` construction — these leave with `BankLinkState`.

- [ ] **Step 2: Delete the read model file**

Remove `src/Application/ReadModels/BankLinkState.hs`.

- [ ] **Step 3: Build to verify no other module depends on it**

Run: `just build`
Expected: FAIL initially in `Infrastructure/App.hs` and `Infrastructure/Eventium.hs` (which still reference `BankLinkState`). Those references are removed in Tasks 5–7.

**Integration strategy for Tasks 2–7.** The deletion tasks are interlocked (read model, events, wiring, config all reference each other), so the branch will not build cleanly between Task 2 and Task 7. Pick one of the following patterns up front and stick with it:

1. **Commit-per-task, tolerate a red branch for Tasks 2–7.** Individual commits are smaller and easier to review; CI on this branch will be red until Task 7 lands. This is acceptable for a feature branch but do not merge before Task 7 passes `just build`.
2. **Single combined commit for Tasks 2–7.** Do all six tasks locally, then make one commit with the message of this task. Every revision on the branch builds, at the cost of a larger diff.

From Task 8 onward the branch must build green at every commit.

- [ ] **Step 4: Commit (strategy-dependent)**

Only commit here if you picked pattern 1 above. If you picked pattern 2, skip the commit step in Tasks 2–6 and commit at the end of Task 7 with a single message that summarizes the full deletion.

```bash
git add -A
git commit -m "refactor(banking): inline BankLink mappings, delete BankLinkState

UserBankLink/AccountMapping existed to back the webhook lookup and
persisted link state. Neither is shipping in Phase 1 — resync
rebuilds mappings per call. Replace the abstraction with a plain
[(BankAccountId, AccountId)] list at the two call sites."
```

---

## Task 3: Delete `Domain/BankLink/*` and remove from `AccountingEvent`

**Files:**
- Delete: `src/Domain/BankLink.hs`, `src/Domain/BankLink/Events.hs`
- Modify: `src/Domain/Models.hs`, `package.yaml`, `backend.cabal` (via `hpack`)

- [ ] **Step 1: Remove `BankLink` branch from `AccountingEvent`**

In `src/Domain/Models.hs`, delete:
- The `import Domain.BankLink` and `import Domain.BankLink.Events` lines.
- The `mkSumTypeEmbedding "bankLinkEventEmbedding" ''BankLinkEvent ''AccountingEvent` TH splice.
- The `BankLink` constructor branch from `AccountingEvent` (it was appended as `BankAccountsLinkedEvent` / `BankAccountsUnlinkedEvent` via `ConstructTagName`).

Grep for `BankLink` across `src/` to catch any stragglers. None should remain.

- [ ] **Step 2: Delete the domain modules**

Remove `src/Domain/BankLink.hs` and `src/Domain/BankLink/Events.hs`.

- [ ] **Step 3: Update `package.yaml` exposed modules list**

In `package.yaml`, remove `Domain.BankLink` and `Domain.BankLink.Events` from the `library.exposed-modules` list (if enumerated — if the project uses `source-dirs: src` with automatic discovery, no change is needed).

- [ ] **Step 4: Regenerate cabal file**

Run: `hpack`
Expected: updates `backend.cabal` if `package.yaml` changed. Otherwise no-op.

- [ ] **Step 5: Build**

Run: `just build`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(banking): remove BankLink domain events

BankAccountsLinked / BankAccountsUnlinked were defined but never
emitted — the activation/linking flow is deferred to Phase 2 with
user-configuration integration."
```

---

## Task 4: Remove `webhook_secret` from `BankingConfig`, add `apiBaseUrl` to `MonobankProviderConfig`

**Files:**
- Modify: `src/Infrastructure/Config.hs`, `config/local.yaml`, `config/test.yaml`, `config/prod.yaml`

- [ ] **Step 1: Update `BankingConfig` and `MonobankProviderConfig`**

In `src/Infrastructure/Config.hs`:

Replace the `BankingConfig` record (lines 326–340) with:

```haskell
-- | Banking integration configuration.
data BankingConfig = BankingConfig
  { enabled :: !Bool,
    providers :: !BankingProvidersConfig
  }
  deriving (Show, Eq, Generic)

instance FromJSON BankingConfig where
  parseJSON = withObject "BankingConfig" $ \v ->
    BankingConfig
      <$> v .:? "enabled" .!= False
      <*> v .:? "providers" .!= defaultBankingProviders

instance ToJSON BankingConfig

defaultBankingConfig :: BankingConfig
defaultBankingConfig = BankingConfig False defaultBankingProviders
```

Replace the `MonobankProviderConfig` record (lines 360–369) with:

```haskell
data MonobankProviderConfig = MonobankProviderConfig
  { enabled :: !Bool,
    apiBaseUrl :: !Text
  }
  deriving (Show, Eq, Generic)

instance FromJSON MonobankProviderConfig where
  parseJSON = withObject "MonobankProviderConfig" $ \v ->
    MonobankProviderConfig
      <$> v .:? "enabled" .!= False
      <*> v .:? "api_base_url" .!= "https://api.monobank.ua"

instance ToJSON MonobankProviderConfig
```

Update `defaultBankingProviders` to pass the default URL:

```haskell
defaultBankingProviders :: BankingProvidersConfig
defaultBankingProviders = BankingProvidersConfig (MonobankProviderConfig False "https://api.monobank.ua")
```

- [ ] **Step 2: Update config YAMLs**

In `config/local.yaml`, `config/test.yaml`, `config/prod.yaml`, remove the `banking.webhook_secret` line wherever it appears. Add `api_base_url` under `banking.providers.monobank` in each file. Example for `local.yaml`:

```yaml
banking:
  enabled: true
  providers:
    monobank:
      enabled: false
      api_base_url: "${MONOBANK_API_BASE_URL:-https://api.monobank.ua}"
```

For `test.yaml`, set `api_base_url: "http://localhost:0"` so tests that don't mock the provider fail fast with a clear connection error rather than silently hitting real Mono.

- [ ] **Step 3: Build**

Run: `just build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(banking): drop webhookSecret config, parameterize Mono base URL

webhookSecret only existed to sign webhook URLs; webhooks are deferred
to Phase 2. api_base_url makes integration tests possible against a
mock server without monkey-patching monoApiBase."
```

---

## Task 5: Drop `bankLinkState` from `AppEnv`; add per-user import lock

**Files:**
- Modify: `src/Infrastructure/App.hs`, `src/Infrastructure/Eventium.hs`, `app/Main.hs`, `test/Testkit/InMemoryEventStore.hs`

- [ ] **Step 1: Remove `bankLinkState` from `AppEnv`**

In `src/Infrastructure/App.hs`:
- Delete the `bankLinkState :: TVar BankLinkState` field from `AppEnv`.
- Delete the `HasBankLinkState` class + instance.
- Delete the `bankLinkStateL` lens + its export.
- Remove the `import Application.ReadModels.BankLinkState` line.
- Remove the corresponding parameter from `initializeAppEnv`.

- [ ] **Step 2: Add `importLocks` to `AppEnv`**

Add a new field and capability class:

```haskell
import qualified Data.Set as Set

-- In AppEnv record:
  importLocks :: !(TVar (Set UserId)),

-- New capability class, near the others:
class HasImportLocks env where
  importLocksL :: Lens' env (TVar (Set UserId))

instance HasImportLocks AppEnv where
  importLocksL = lens importLocks (\e v -> e {importLocks = v})
```

Add the corresponding argument to `initializeAppEnv`.

- [ ] **Step 3: Update `Infrastructure/Eventium.hs`**

Remove the `import Application.ReadModels.BankLinkState`. Remove the `BankLinkState` handler from the read-model wiring (the `handleBankLinkStateEvents` call or equivalent). Nothing replaces it — the deletion is total.

- [ ] **Step 4: Update `app/Main.hs`**

Remove `BankLinkState` creation. Add:

```haskell
importLocksVar <- newTVarIO Set.empty
```

Pass `importLocksVar` into `initializeAppEnv`.

- [ ] **Step 5: Update `test/Testkit/InMemoryEventStore.hs`**

The test harness builds a minimal `AppEnv`. Update the two `ServerConfig` / `AppEnv` construction sites (lines ~241 and ~382 per earlier grep) to:
- Remove `BankLinkState` field.
- Add `importLocks = ...` initialized with `newTVarIO Set.empty`.
- Keep `apiBaseUrl = "http://localhost:8080"` (unrelated; just verifying it survives).

- [ ] **Step 6: Build + existing tests**

Run: `just build && just test`
Expected: PASS (no functional tests should fail yet — the lock isn't wired into any service).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(banking): replace bankLinkState with importLocks in AppEnv

BankLinkState is deleted; in its place add a TVar (Set UserId)
that will back the per-user import serialization lock wired in
a subsequent commit."
```

---

## Task 6: Introduce `ExternalTransactionId` newtype + smart constructor

**Files:**
- Modify: `src/Domain/Core/Types.hs`, `src/Infrastructure/Banking/Monobank.hs`, `src/Application/ReadModels/BankImportReadModel.hs`
- Test: `test/Domain/Core/TypesSpec.hs` (extend or create)

**Convention note:** Match the existing `DictionaryEntryId` pattern in `src/Domain/Core/Types.hs:562-583`: newtype, smart constructor returns `Either Text`, companion `unsafeExternalTransactionId` for trusted callers, `unExternalTransactionId` accessor, `FromJSON`/`ToJSON` instances. The module does not use inline LiquidHaskell `{-@ ... @-}` annotations for existing newtypes (grep for `\{-@` in the file before adding any — if none, omit LH here; a follow-up LH pass can add refinements file-wide).

- [ ] **Step 1: Failing tests for `mkExternalTransactionId`**

Add to `test/Domain/Core/TypesSpec.hs` (create if absent; follow the structure of existing specs under `test/Domain/`):

```haskell
describe "ExternalTransactionId" $ do
  it "rejects empty text" $
    mkExternalTransactionId "" `shouldSatisfy` isLeft

  prop "accepts any non-empty text" $ \(NonEmptyList cs) ->
    let txt = T.pack cs
     in case mkExternalTransactionId txt of
          Right eid -> unExternalTransactionId eid == txt
          Left _ -> False

  it "FromJSON rejects empty string" $
    (Aeson.eitherDecode "\"\"" :: Either String ExternalTransactionId) `shouldSatisfy` isLeft

  it "FromJSON accepts non-empty string" $
    (Aeson.eitherDecode "\"tx-123\"" :: Either String ExternalTransactionId) `shouldSatisfy` isRight
```

Run: `cabal test all --test-option='--match' --test-option='/ExternalTransactionId/'`
Expected: FAIL (symbols not defined).

- [ ] **Step 2: Introduce the newtype + smart constructor**

In `src/Domain/Core/Types.hs`, replace `type ExternalTransactionId = Text` (line 946) with:

```haskell
-- | Identifier for a transaction in an external system (e.g., Monobank).
--   Must be non-empty.
newtype ExternalTransactionId = ExternalTransactionId Text
  deriving (Show, Eq, Ord, Generic)

unExternalTransactionId :: ExternalTransactionId -> Text
unExternalTransactionId (ExternalTransactionId t) = t

mkExternalTransactionId :: Text -> Either Text ExternalTransactionId
mkExternalTransactionId t
  | T.null t = Left "ExternalTransactionId must not be empty"
  | otherwise = Right (ExternalTransactionId t)

unsafeExternalTransactionId :: Text -> ExternalTransactionId
unsafeExternalTransactionId = ExternalTransactionId

instance Display ExternalTransactionId where
  display (ExternalTransactionId t) = display t

instance ToJSON ExternalTransactionId where
  toJSON (ExternalTransactionId t) = toJSON t

instance FromJSON ExternalTransactionId where
  parseJSON = withText "ExternalTransactionId" $ \t ->
    case mkExternalTransactionId t of
      Right eid -> pure eid
      Left err -> fail (T.unpack err)
```

Update the module export list: replace the existing `ExternalTransactionId,` export (line 108) with:

```haskell
    ExternalTransactionId,
    mkExternalTransactionId,
    unsafeExternalTransactionId,
    unExternalTransactionId,
```

Do **not** export the `ExternalTransactionId` constructor — smart constructor only (matches `DictionaryEntryId`).

- [ ] **Step 3: Thread newtype through call sites**

- `src/Infrastructure/Banking/Provider.hs`: `BankTransaction.externalId :: !ExternalTransactionId` — no change needed; just recompiles against the new type.
- `src/Infrastructure/Banking/Monobank.hs`: `toProviderTransaction` — wrap `ms.stmtId` with `mkExternalTransactionId`. If it's empty (should not happen per Mono's contract), skip the transaction. Change the return type of `toProviderTransaction` to `Maybe BankTransaction` and flatten with `mapMaybe` in `monoFetchStatements`:
  ```haskell
  Right (stmts :: [MonoStatement]) ->
    return $ Right $ mapMaybe (toProviderTransaction accId) stmts
  ```
- `src/Domain/Transaction/Commands.hs`, `src/Domain/Transaction/Events.hs`: no change — `ExternalTransactionId` is imported the same way, now a newtype. `Maybe ExternalTransactionId` still works.
- `src/Application/ReadModels/BankImportReadModel.hs`: `Map ExternalTransactionId TransactionId` — fine (newtype has `Ord`).

**Backwards-compat note:** Existing `TransferInitiated` events in any production event store either predate the `externalTransactionId` field entirely (decode as `Nothing`) or were emitted by this PR with a non-empty Mono `stmtId`. No legacy event can contain an empty-string external id. Task 14 adds the explicit backwards-compat test for the "field absent → `Nothing`" case.

- [ ] **Step 4: Run test**

Run: `cabal test all --test-option='--match' --test-option='/ExternalTransactionId/'`
Expected: PASS.

- [ ] **Step 5: Build to verify compile-time threading**

Run: `just build`
Expected: PASS.

- [ ] **Step 6: Run all tests**

Run: `just test`
Expected: PASS. Any test that constructed an `ExternalTransactionId` from a string literal (e.g., `"tx-1" :: Text`) now fails to typecheck; fix by using `ExternalTransactionId . T.pack "tx-1"` via a testkit helper, or by calling `mkExternalTransactionId "tx-1"` and pattern matching on `Right`. Add a helper `unsafeExternalTransactionId :: Text -> ExternalTransactionId` to `test/Testkit/Helpers.hs` that `error`s on empty (tests may use it freely).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(domain): make ExternalTransactionId a newtype with validation

Matches CLAUDE.md rule: all domain types in src/ must have LH
refinements and use smart constructors. Previously a bare Text
alias allowed empty strings through the type system."
```

---

## Task 7: Simplify `TransactionClassification` — drop `ClassifiedTransfer`

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs`, `src/Infrastructure/Banking/Monobank.hs`, `src/Application/Services/BankImportService.hs`, `test/Application/Services/BankImportServiceSpec.hs`

**Rationale:** `ClassifiedTransfer` was never materialized as `TransferType.Transfer` — the service fell through to `Income`/`Expense` based on amount sign. Per the amendment, MCC 4829 maps directly to `Expense` (Mono outgoing transfers are negative, incoming are positive — which is already the amount-sign semantics for the `_ ->` branch). Keeping `ClassifiedTransfer` is dead code.

- [ ] **Step 1: Update failing classification test**

In `test/Application/Services/BankImportServiceSpec.hs`, the test for MCC 4829 currently asserts `ClassifiedTransfer`. Change it to assert `ClassifiedExpense Nothing` (with negative amount) and `ClassifiedIncome Nothing` (with positive amount).

Run the specific test file:
```
cabal test all --test-option='--match' --test-option='/monoClassifyTransaction/'
```
Expected: FAIL.

- [ ] **Step 2: Simplify the classifier**

In `src/Infrastructure/Banking/Monobank.hs`, replace `monoClassifyTransaction`:

```haskell
monoClassifyTransaction :: BankTransaction -> TransactionClassification
monoClassifyTransaction tx =
  if tx.amount >= 0
    then ClassifiedIncome Nothing
    else ClassifiedExpense Nothing
```

Note: MCC is no longer consulted because Phase 1 has no category mapping. Leave a `-- Phase 2: MCC → category mapping via UserConfiguration` comment.

- [ ] **Step 3: Drop `ClassifiedTransfer` from the type**

In `src/Infrastructure/Banking/Provider.hs`:

```haskell
data TransactionClassification
  = ClassifiedExpense !(Maybe DictionaryEntryId)
  | ClassifiedIncome !(Maybe DictionaryEntryId)
  deriving (Show, Eq)
```

- [ ] **Step 4: Remove the `ClassifiedTransfer` branch from `importTransaction`**

In `src/Application/Services/BankImportService.hs`, delete the `ClassifiedTransfer -> ...` arm from the case on `classification` (lines ~186–190 in the current file).

- [ ] **Step 5: Run tests**

Run: `cabal test all --test-option='--match' --test-option='/monoClassifyTransaction/'` then `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(banking): drop ClassifiedTransfer from classifier

A one-sided bank statement can't be modeled as a domain Transfer
(no peer account). The service already degenerated it to
Income/Expense by amount sign; inline that directly."
```

---

## Task 8: Monobank adapter — inject `apiBaseUrl` and move minor-unit scaling

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs`, `src/Infrastructure/Banking/Monobank.hs`, `src/Web/API/BankingAPI.hs`, `src/Application/Services/BankImportService.hs`, `test/Application/Services/BankImportServiceSpec.hs`, `test/Integration/BankImportWorkflowSpec.hs`

**Design note for this task.** Monobank's `MonoStatement` JSON reports `currencyCode` (of the *account*) and `operationAmount` (foreign-currency amount in the *transaction's* currency), but it does **not** report the transaction's currency code separately. That means we can detect "this is a foreign-currency transaction" (when `amount /= operationAmount`), but we cannot attach a currency code to the foreign-side amount. Phase 1 therefore reports `originalAmount :: Maybe Rational` on `BankTransaction` — `Just x` iff the transaction was in a different currency than the account, otherwise `Nothing` — and leaves currency-code reconstruction to Phase 2.

- [ ] **Step 1: Final shape of `BankTransaction`**

In `src/Infrastructure/Banking/Provider.hs`, change `BankTransaction` to:

```haskell
data BankTransaction = BankTransaction
  { externalId :: !ExternalTransactionId,
    accountId :: !BankAccountId,
    time :: !UTCTime,
    -- | Account-currency amount in major units (e.g. 12.34 not 1234). Signed.
    amount :: !Rational,
    -- | ISO 4217 numeric code of the account currency.
    currencyCode :: !Int,
    description :: !Text,
    hold :: !Bool,
    mcc :: !(Maybe Int32),
    -- | Major-unit amount in the transaction's original currency, iff the
    -- transaction was in a currency different from the account. Monobank
    -- does not report the original currency code; Phase 1 uses the ratio
    -- `|originalAmount| / |amount|` to derive an exchange rate.
    originalAmount :: !(Maybe Rational),
    notes :: !(Maybe Text),
    categoryHint :: !(Maybe Text)
  }
  deriving (Show, Eq)
```

Note the removal of the `Int64` `amount`; `Rational` is the major-unit representation produced by the adapter.

- [ ] **Step 2: Update `mkMonobankProvider` signature**

Accept `apiBaseUrl` as an argument:

```haskell
mkMonobankProvider :: Text -> Text -> Manager -> BankProvider
mkMonobankProvider apiBaseUrl token manager =
  BankProvider
    { providerName = "monobank",
      fetchAccounts = monoFetchAccounts apiBaseUrl token manager,
      fetchStatements = monoFetchStatements apiBaseUrl token manager,
      registerWebhook = monoRegisterWebhook apiBaseUrl token manager,
      classifyTransaction = monoClassifyTransaction
    }
```

Thread `apiBaseUrl :: Text` through `monoFetchAccounts`, `monoFetchStatements`, `monoRegisterWebhook`, replacing the hardcoded `monoApiBase`. Delete the `monoApiBase` top-level constant. URL construction: `T.unpack apiBaseUrl <> "/personal/client-info"`, etc.

- [ ] **Step 3: Update `toProviderTransaction` — scale amounts, infer originalAmount**

```haskell
toProviderTransaction :: BankAccountId -> MonoStatement -> Maybe BankTransaction
toProviderTransaction accId ms = do
  eid <- either (const Nothing) Just (mkExternalTransactionId ms.stmtId)
  let accountAmount    = fromIntegral ms.stmtAmount          % 100
      operationAmount  = fromIntegral ms.stmtOperationAmount % 100
      maybeOriginal    = if accountAmount == operationAmount
                           then Nothing
                           else Just operationAmount
  pure BankTransaction
    { externalId = eid,
      accountId = accId,
      time = posixSecondsToUTCTime (fromIntegral ms.stmtTime),
      amount = accountAmount,
      currencyCode = ms.stmtCurrencyCode,
      description = ms.stmtDescription,
      hold = ms.stmtHold,
      mcc = if ms.stmtMcc == 0 then Nothing else Just ms.stmtMcc,
      originalAmount = maybeOriginal,
      notes = ms.stmtComment,
      categoryHint = Nothing
    }
```

Requires `import Data.Ratio ((%))`.

- [ ] **Step 4: Update call site in `Web/API/BankingAPI.hs`**

`mkMonobankProvider` now takes 3 arguments. Pull `apiBaseUrl` from config — check `src/Infrastructure/App.hs` for the existing `HasConfig`-style capability (look for how other services read `AppConfig`). If none, add a `configL :: Lens' AppEnv AppConfig`:

```haskell
cfg <- view configL
let apiBaseUrl = cfg.banking.providers.monobank.apiBaseUrl
let provider = mkMonobankProvider apiBaseUrl bankingToken manager
```

(`bankingToken` is the `X-Banking-Token` header value introduced in Task 12; in this task, if Task 12 is not yet done, keep reading `request.token` from the body and update during Task 12.)

- [ ] **Step 5: Update `BankImportServiceSpec` fixtures**

All mock `BankTransaction`s in `test/` that used integer amounts like `amount = 1234` must become `amount = 1234 % 100` (i.e. 12.34). Grep for `BankTransaction {` in `test/` and fix each. Confirm `originalAmount` field is present (previously `Just x :: Maybe Int64`; now `Just x :: Maybe Rational` or `Nothing`).

- [ ] **Step 6: Build + Tests**

Run: `just build && just test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(banking): push minor-unit scaling into Mono adapter

Application layer now receives amounts in major units (Rational).
apiBaseUrl is injected via config. originalAmount is populated
only for cross-currency transactions."
```

---

## Task 9: Cross-currency handling in `importTransaction`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`, `docs/specs/2026-04-10-bank-integration-design.md`
- Test: `test/Application/Services/BankImportServiceSpec.hs`

**Spec reconciliation.** The original spec amendment wording said to "use `originalAmount` + `tx.currencyCode` as source side" and set different currencies on the two Money values. That requires the foreign currency code, which Monobank does not report. Before implementing this task, update the Phase 1 amendment in `docs/specs/2026-04-10-bank-integration-design.md` (the section added in Amendment 2026-04-16) to replace the cross-currency bullet with:

> Cross-currency handling: if `amount == operationAmount` in the Mono statement, `sourceAmount == targetAmount` and `exchangeRate = Nothing` (same currency). If they differ, both `Money` values still use the account currency but `exchangeRate` is set to `|originalAmount| / |amount|`. Reconstructing a true cross-currency `Transfer` requires knowing the foreign currency code, which Monobank's statement API does not report; that reconstruction is deferred to Phase 2 alongside user-configured currency mappings.

Commit the spec update as a separate commit from the code change.

- [ ] **Step 1: Update spec amendment + commit**

Edit the spec file, replace the cross-currency bullet as above. `git add docs/specs/... && git commit -m "docs(banking): clarify Phase 1 cross-currency handling"`.

- [ ] **Step 2: Failing tests — same and different currency**

Add to `test/Application/Services/BankImportServiceSpec.hs`:

```haskell
describe "importTransaction cross-currency" $ do
  it "same currency: exchangeRate is Nothing" $ do
    -- Build a local UAH account; Mono tx with originalAmount = Nothing
    -- (amount == operationAmount at adapter). Expect emitted TransferInitiated
    -- to have exchangeRate = Nothing and sourceAmount == targetAmount.
    env <- setupBankImportFixture ...
    result <- runRIO env $ BankImportService.importTransaction
                            mockProvider userId mapping defaultCategory
                            (mkSameCurrencyBankTx ...)
    -- Assert on the captured InitiateTransfer command via the in-memory store.

  it "different currency: exchangeRate is |originalAmount| / |amount|" $ do
    -- tx.amount = 1000 (UAH), tx.originalAmount = Just 25 (USD-valued).
    -- Expect exchangeRate = Just 40 (as ExchangeRate refinement), sourceAmount
    -- == targetAmount using account currency (UAH).
    ...
```

Use the Testkit helpers introduced in Task 10's preparation (`mockProvider`, `mkSameCurrencyBankTx`, etc.); if they do not yet exist, define them first in `test/Testkit/BankingHelpers.hs` (create the file; follow the structure of existing Testkit modules).

Run: `cabal test all --test-option='--match' --test-option='/cross-currency/'`
Expected: FAIL.

- [ ] **Step 3: Implement the branch**

In `src/Application/Services/BankImportService.hs`, replace the `InitiateTransfer` construction in `importTransaction` with the cross-currency aware version:

```haskell
-- `money :: Money` is already the account-currency amount built earlier in the flow.
-- Derive the exchange rate from the adapter's `originalAmount` inference.
xrate <- case tx.originalAmount of
  Nothing -> pure Nothing  -- same currency
  Just origAmt
    | tx.amount == 0 -> pure Nothing  -- defensive; should not happen for non-hold tx
    | otherwise ->
        let rate = abs origAmt / abs tx.amount
        in case mkExchangeRate rate of
             Right r -> pure (Just r)
             Left err -> do
               logWarn $ "Invalid exchange rate "
                       <> displayShow rate
                       <> " for tx "
                       <> display tx.externalId
                       <> ": "
                       <> display err
               pure Nothing
```

Use `xrate` for `InitiateTransfer.exchangeRate`. Keep `sourceAmount = money` and `targetAmount = money` — both sides retain the account currency because the foreign currency code is not available from Mono's statement API. Add a `-- Phase 2: reconstruct true cross-currency Money when foreign currency mapping is available` comment.

Confirm the signature of `mkExchangeRate` by reading `src/Domain/Core/Types.hs` (search for `mkExchangeRate`) and adjust the pattern match if the return type differs.

- [ ] **Step 4: Run tests**

Run: `cabal test all --test-option='--match' --test-option='/cross-currency/'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "fix(banking): record exchange rate for cross-currency Mono tx

When the Mono statement's operationAmount differs from amount, derive
exchangeRate = |originalAmount| / |amount| and attach to the
TransferInitiated event. Both sides of the emitted Money still use
the account currency because Mono's statement API does not report
the foreign currency code; true cross-currency Money reconstruction
is deferred to Phase 2."
```

---

## Task 10: Per-user import lock

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`, `src/Infrastructure/App.hs` (add `withUserLock` helper)
- Create: `test/Testkit/BankingHelpers.hs` (mock provider + tx builders)
- Test: `test/Integration/BankImportWorkflowSpec.hs` (dedup idempotency property)

- [ ] **Step 1: Create `test/Testkit/BankingHelpers.hs` with a mock provider**

```haskell
module Testkit.BankingHelpers
  ( mkMockProvider,
    mkTestBankAccount,
    mkSameCurrencyBankTx,
    mkForeignCurrencyBankTx,
  )
where

-- A mock BankProvider whose fetchStatements returns a caller-supplied list,
-- fetchAccounts returns a caller-supplied list, registerWebhook is a no-op,
-- and classifyTransaction uses the Monobank rule (amount >= 0 -> Income).
mkMockProvider :: [BankAccount] -> [BankTransaction] -> BankProvider
mkMockProvider accs txs =
  BankProvider
    { providerName = "mock",
      fetchAccounts = pure (Right accs),
      fetchStatements = \_ _ _ -> pure (Right txs),
      registerWebhook = \_ -> pure (Right ()),
      classifyTransaction = \tx ->
        if tx.amount >= 0 then ClassifiedIncome Nothing else ClassifiedExpense Nothing
    }

mkTestBankAccount :: BankAccountId -> Text -> Int -> BankAccount
mkTestBankAccount = ...

mkSameCurrencyBankTx :: ExternalTransactionId -> BankAccountId -> Rational -> BankTransaction
mkSameCurrencyBankTx eid accId amt =
  BankTransaction
    { externalId = eid,
      accountId = accId,
      time = posixSecondsToUTCTime 1700000000,
      amount = amt,
      currencyCode = 980,
      description = "test",
      hold = False,
      mcc = Nothing,
      originalAmount = Nothing,
      notes = Nothing,
      categoryHint = Nothing
    }

mkForeignCurrencyBankTx :: ExternalTransactionId -> BankAccountId -> Rational -> Rational -> BankTransaction
mkForeignCurrencyBankTx eid accId accountAmt foreignAmt =
  (mkSameCurrencyBankTx eid accId accountAmt) { originalAmount = Just foreignAmt }
```

Flesh out `mkTestBankAccount` to match the `BankAccount` record (see `src/Infrastructure/Banking/Provider.hs:45-51`). Add the module to `package.yaml`'s test-suite `other-modules:` if it is enumerated there.

- [ ] **Step 2: Failing property test — concurrent resyncs dedup correctly**

In `test/Integration/BankImportWorkflowSpec.hs`:

```haskell
import qualified Control.Concurrent.Async as Async
import Testkit.BankingHelpers

prop "concurrent resyncs of the same statement produce one transfer per external id" $
  \(txSeeds :: NonEmptyList (Positive Int)) -> ioProperty $ do
    env <- setupInMemoryEnv
    let txs = zipWith (\i (Positive n) -> mkSameCurrencyBankTx
                                              (unsafeExternalTransactionId (T.pack ("tx-" <> show i)))
                                              "acc-1"
                                              (fromIntegral n))
                [0 :: Int ..]
                (getNonEmpty txSeeds)
        provider = mkMockProvider [mkTestBankAccount "acc-1" "UA123" 980] txs
        mapping = [("acc-1", testLocalAccountId env)]
    _ <- Async.concurrently
           (runRIO env $ BankImportService.resync provider testUserId mapping testCategoryId from to)
           (runRIO env $ BankImportService.resync provider testUserId mapping testCategoryId from to)
    rm <- readTVarIO env.bankImportReadModel   -- verify field name: src/Infrastructure/App.hs
    pure $ Map.size rm.importedTransactions === length (nubBy ((==) `on` externalId) txs)
```

Before writing this test, confirm the actual field name of the bank-import read model on `AppEnv` by reading `src/Infrastructure/App.hs`. If the field is not named `bankImportReadModel`, update the test to use the actual name (and/or use `view bankImportReadModelL` instead of `OverloadedRecordDot`).

Run: `cabal test all --test-option='--match' --test-option='/concurrent resyncs/'`
Expected: FAIL (the existing code has a TOCTOU race that produces duplicates under concurrency).

- [ ] **Step 3: Add `withUserLock` helper**

In `src/Infrastructure/App.hs` (or a new `src/Infrastructure/Locks.hs` if preferred):

```haskell
import qualified Data.Set as Set
import UnliftIO (bracket_)

withUserLock ::
  (MonadReader env m, HasImportLocks env, MonadUnliftIO m) =>
  UserId ->
  m a ->
  m a
withUserLock uid action = do
  locksVar <- view importLocksL
  bracket_ (acquire locksVar) (release locksVar) action
  where
    acquire locksVar = atomically $ do
      locks <- readTVar locksVar
      if Set.member uid locks
        then retry
        else writeTVar locksVar (Set.insert uid locks)
    release locksVar = atomically $ modifyTVar' locksVar (Set.delete uid)
```

STM `retry` blocks the caller until a transaction changing `locksVar` commits — so the second caller waits for the first to release.

- [ ] **Step 4: Wrap `resync` in the lock**

In `src/Application/Services/BankImportService.hs`:

```haskell
resync provider userId link defaultCategory fromTime toTime =
  withUserLock userId $ do
    ... -- existing body
```

Only `resync` needs the lock in Phase 1 (webhook entry point is gone; `importTransaction` is only called from within `resync`).

- [ ] **Step 5: Run property test**

Run: `cabal test all --test-option='--match' --test-option='/concurrent resyncs/'`
Expected: PASS.

- [ ] **Step 6: Run full suite**

Run: `just test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "fix(banking): serialize per-user resyncs to close dedup TOCTOU

Between isImported and the TransferInitiated emit, two concurrent
resyncs could both pass the dedup check. A per-user STM lock
in AppEnv.importLocks ensures at most one resync per user is
in flight in-process."
```

---

## Task 11: `resync` — structured per-account result, no short-circuit

**Files:**
- Modify: `src/Application/Services/BankImportService.hs`, `src/Web/API/BankingAPI.hs`
- Test: update existing resync tests

**Context check.** Current `importTransaction` signature (`src/Application/Services/BankImportService.hs:124-130`):

```haskell
importTransaction ::
  BankProvider -> UserId -> UserBankLink -> DictionaryEntryId -> BankTransaction ->
  AppM (Either DomainError (Maybe TransactionId))
```

After Task 2 it will take `[(BankAccountId, AccountId)]` instead of `UserBankLink`; the `Either DomainError (Maybe TransactionId)` return is unchanged. Task 11 preserves that return shape.

- [ ] **Step 1: New result type**

In `src/Application/Services/BankImportService.hs`:

```haskell
import Data.UUID (UUID)

data AccountResyncResult = AccountResyncResult
  { externalAccountId :: !BankAccountId,
    localAccountId :: !AccountId,
    imported :: ![TransactionId],
    skipped :: !Int,
    -- | Human-readable reasons for per-tx failures (and the top-level fetch
    -- failure if present). DomainError is rendered via its display instance
    -- before being stored as Text so the response serializes cleanly.
    failures :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountResyncResult

data ResyncResult = ResyncResult
  { accounts :: ![AccountResyncResult]
  }
  deriving (Show, Eq, Generic)

instance ToJSON ResyncResult
```

Using `[Text]` for failures (rather than `[DomainError]` or `[AppError]`) avoids having to make `DomainError` `ToJSON`-able and keeps the wire contract stable.

- [ ] **Step 2: Rewrite `resync` to collect per-account results**

Replace the current `partitionEithers`-based logic with:

```haskell
resync provider userId link defaultCategory fromTime toTime =
  withUserLock userId $ do
    logInfo $ "Resyncing bank transactions for user " <> displayShow userId
    accountResults <- forM link $ \(extAccId, localAccId) -> do
      fetchResult <- liftIO $ provider.fetchStatements extAccId fromTime toTime
      case fetchResult of
        Left err -> do
          logWarn $ "Failed to fetch statements for "
                    <> display extAccId <> ": " <> display err
          pure AccountResyncResult
            { externalAccountId = extAccId,
              localAccountId = localAccId,
              imported = [],
              skipped = 0,
              failures = [err]
            }
        Right txs -> do
          perTx <- forM txs $ \tx ->
                     importTransaction provider userId link defaultCategory tx
          let (errs, oks) = partitionEithers perTx
              importedIds = catMaybes oks
              skippedCount = length oks - length importedIds
          pure AccountResyncResult
            { externalAccountId = extAccId,
              localAccountId = localAccId,
              imported = importedIds,
              skipped = skippedCount,
              failures = map tshow errs
            }
    pure (ResyncResult accountResults)
```

Return type changes from `AppM (Either DomainError [TransactionId])` to `AppM ResyncResult`. No more per-call short-circuit; individual failures are captured per-account. `tshow` (RIO) is sufficient for rendering `DomainError` to `Text`; if a dedicated `display`-based rendering is preferred, use `utf8BuilderToText . display`.

- [ ] **Step 3: Update handler in `BankingAPI.hs`**

Replace the current `ResyncResponse` shape:

```haskell
data ResyncResponse = ResyncResponse
  { accounts :: ![AccountResyncSummary]
  }
  deriving (Show, Eq, Generic)

data AccountResyncSummary = AccountResyncSummary
  { externalAccountId :: !Text,
    localAccountId :: !Text,     -- serialize as text
    importedCount :: !Int,
    skippedCount :: !Int,
    failureCount :: !Int
  }
  deriving (Show, Eq, Generic)
```

Map `ResyncResult` to `ResyncResponse` in the handler. Always return 200; the body tells the caller which accounts had issues.

- [ ] **Step 4: Update tests**

Update existing BankImportServiceSpec + BankImportWorkflowSpec to match the new return shape.

- [ ] **Step 5: Run tests**

Run: `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix(banking): resync returns per-account result, no short-circuit

Previously a single failed fetchStatements call aborted the entire
resync even when other accounts had already imported successfully.
Resync now returns a structured per-account breakdown and the
HTTP handler reports it verbatim at 200."
```

---

## Task 12: Web layer hardening — feature-flag gate, header token, Viewer filter, multi-match log

**Files:**
- Modify: `src/Web/API/BankingAPI.hs`, `docs/specs/2026-04-10-bank-integration-design.md`
- Test: `test/Web/API/BankingAPISpec.hs` (new)

**Header decision.** Using `Authorization: Bearer <token>` would collide with the JWT-based `AuthProtect "jwt"` auth scheme already applied to this route (JWT looks at `Authorization: Bearer`). Use a dedicated header `X-Banking-Token` instead. Update the spec amendment in `docs/specs/2026-04-10-bank-integration-design.md` to say `X-Banking-Token` rather than `Authorization: Bearer`; include that change in this task's first step.

- [ ] **Step 1: Update spec amendment to reference `X-Banking-Token`**

Edit the spec amendment (section dated 2026-04-16). Replace "via the `Authorization: Bearer <token>` header for the token" with "via the dedicated `X-Banking-Token` header for the token (a separate header to avoid colliding with the JWT Bearer scheme on the same endpoint)". Commit separately:

```bash
git add docs/specs/2026-04-10-bank-integration-design.md
git commit -m "docs(banking): spec amendment uses X-Banking-Token header"
```

- [ ] **Step 2: Feature-flag gate — failing test**

Add to a new `test/Web/API/BankingAPISpec.hs`:

```haskell
it "returns 404 when banking.enabled is false" $ do
  -- setup env with banking.enabled = False
  -- POST /api/banking/resync with any body
  -- expect status 404
  pending
```

- [ ] **Step 3: Implement the gate**

At the top of `resyncHandler`, read config and short-circuit with 404:

```haskell
cfg <- view configL
let bankingCfg = cfg.banking
    monoCfg = bankingCfg.providers.monobank
unless (bankingCfg.enabled && monoCfg.enabled) $
  throwError err404
```

Confirm the exact throw mechanism by reading a neighbouring handler (`grep -rn "throwError err" src/Web/API/`) — in this codebase, handlers typically use `throwError :: ServerError -> AppM a` imported from `Servant.Server`. If a local helper exists (e.g., `Web.ErrorMapping.notFound`), prefer it.

- [ ] **Step 4: Add `X-Banking-Token` header capture**

Update `BankingAPI`:

```haskell
type BankingAPI =
  AuthProtect "jwt"
    :> Header' '[Required, Strict] "X-Banking-Token" Text
    :> "api" :> "banking" :> "resync"
    :> ReqBody '[JSON] ResyncRequest
    :> Post '[JSON] ResyncResponse
```

Drop the `token` field from `ResyncRequest`. Update `resyncHandler`:

```haskell
resyncHandler :: AuthenticatedUser -> Text -> ResyncRequest -> AppM ResyncResponse
resyncHandler user bankingToken request = ...
```

Thread `bankingToken` into `mkMonobankProvider apiBaseUrl bankingToken manager`. Add a Haddock note on the handler explaining why the token uses a distinct header from the JWT bearer.

- [ ] **Step 5: Viewer-role filter + multi-match log**

Inside `buildBankLink` (now producing `[(BankAccountId, AccountId)]`):

```haskell
buildBankLink bankAccounts localAccounts = do
  let writable = filter (\(_, _, role) -> role == Owner || role == Editor) localAccounts
  mappings <- forM bankAccounts $ \bankAcc ->
    let candidates =
          [ (bankAcc.externalId, accId)
          | (accId, accData, _) <- writable
          , matchesAccountNumber bankAcc.accountNumber accData
          ]
    in case candidates of
         [] -> pure Nothing
         [one] -> pure (Just one)
         many@(first : _) -> do
           logWarn $
             "IBAN " <> display bankAcc.accountNumber
               <> " matches multiple local accounts; picking first. Candidates: "
               <> displayShow (map snd many)
           pure (Just first)
  let collected = catMaybes mappings
  when (null collected) $
    throwDomainError $ BankingError "No bank accounts could be matched to local accounts. Ensure your Owner/Editor accounts have matching IBANs."
  pure collected
```

Confirm `Owner` / `Editor` are the correct constructor names by reading `src/Domain/Account/Access.hs` or `src/Domain/Core/Types.hs`. `throwDomainError` is already imported in `src/Web/API/BankingAPI.hs` from `Web.ErrorMapping` — reuse it rather than calling `throwError` directly so the error envelope matches the rest of the API.

- [ ] **Step 6: Add handler tests**

In `test/Web/API/BankingAPISpec.hs`:
- `buildBankLink`: single match returns one pair; multi-match returns first + log; no match returns `BankingError`; Viewer-shared account is filtered out.

- [ ] **Step 7: Run tests + build**

Run: `just test && just build`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "fix(banking): harden resync endpoint

- Gate POST /api/banking/resync behind banking.enabled and
  monobank.enabled; return 404 when disabled.
- Move Monobank token out of JSON body into X-Banking-Token
  header so it does not appear in request-body logs or traces.
- Filter IBAN candidates to accounts where caller has Owner or
  Editor role; Viewer-shared accounts are no longer written to.
- Log a warning (user, IBAN, candidate list) when an IBAN
  matches more than one local account."
```

---

## Task 13: JSON parsing tests for Mono responses

**Files:**
- Create: `test/Infrastructure/Banking/MonobankSpec.hs`

- [ ] **Step 1: Test fixtures + parser tests**

```haskell
module Infrastructure.Banking.MonobankSpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy as BSL
import Infrastructure.Banking.Monobank.Internal  -- may need to expose internal types via a Internal module for tests
import Test.Hspec

spec :: Spec
spec = describe "Monobank JSON" $ do
  it "parses /personal/client-info" $ do
    let body = "{\"accounts\":[{\"id\":\"abc\",\"iban\":\"UA123\",\"currencyCode\":980,\"balance\":10000}]}"
    eitherDecode body `shouldSatisfy` isRight

  it "parses a /personal/statement entry" $ do
    let body = "{\"id\":\"tx1\",\"time\":1700000000,\"description\":\"groceries\",\"mcc\":5411,\"amount\":-12345,\"operationAmount\":-12345,\"currencyCode\":980,\"hold\":false,\"comment\":\"store\"}"
    eitherDecode body `shouldSatisfy` isRight

  it "handles mcc=0 by mapping to Nothing in the adapter" $ do
    ...

  it "handles missing 'comment' field" $ do
    ...
```

If the internal types are not currently exported: add an `Infrastructure.Banking.Monobank.Internal` module that re-exports them for test consumption only.

- [ ] **Step 2: Run**

Run: `just test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test(banking): add Monobank JSON parsing tests"
```

---

## Task 14: `TransferInitiated` backwards-compat JSON test

**Files:**
- Create or extend: `test/Domain/Transaction/EventsSpec.hs`

- [ ] **Step 1: Test that legacy JSON without `externalTransactionId` still parses**

```haskell
it "decodes TransferInitiated without externalTransactionId as Nothing" $ do
  let legacy = "{\"sourceAccountId\":\"...\",...}"  -- real legacy payload, no externalTransactionId
  case eitherDecode legacy of
    Right (evt :: TransferInitiated) -> evt.externalTransactionId `shouldBe` Nothing
    Left err -> expectationFailure err

it "roundtrips TransferInitiated with Just externalTransactionId" $ do
  property $ \evt ->
    eitherDecode (encode (evt :: TransferInitiated)) === Right evt
```

- [ ] **Step 2: Run**

Run: `just test`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "test(banking): verify TransferInitiated JSON backwards-compat

Existing events in the store predate the externalTransactionId
field; re-deriving projections must still decode them."
```

---

## Task 15: Layering invariant — grep assertion

**Files:**
- Create: `scripts/check-layering.sh` (or inline in `justfile`)

- [ ] **Step 1: Add a script that fails if `Infrastructure/Banking` imports from `Application` or `Web`**

```bash
#!/usr/bin/env bash
set -euo pipefail
# Match both `import Application.X` and `import qualified Application.X as Y`.
pattern='^import\s+(qualified\s+)?(Application|Web)\.'
if rg -l "$pattern" src/Infrastructure/Banking/ >/dev/null; then
  echo "Layering violation: Infrastructure/Banking must not import from Application or Web"
  rg "$pattern" src/Infrastructure/Banking/
  exit 1
fi
echo "Layering OK: Infrastructure/Banking has no imports from Application or Web"
```

Add a `just check-layering` recipe, and call it from `just check`.

- [ ] **Step 2: Run**

Run: `just check-layering`
Expected: "Layering OK".

- [ ] **Step 3: Commit**

```bash
git add scripts/check-layering.sh justfile
git commit -m "chore(banking): enforce Infrastructure/Banking layering invariant"
```

---

## Task 16: Final verification

- [ ] **Step 1: Regenerate cabal from package.yaml**

Run: `hpack`
Expected: `backend.cabal` in sync.

- [ ] **Step 2: Full build with warnings-as-errors**

Run: `cabal build -fci`
Expected: PASS with no warnings.

- [ ] **Step 3: Full test suite**

Run: `just test`
Expected: all green.

- [ ] **Step 4: Formatter + linter**

Run: `just check`
Expected: PASS.

- [ ] **Step 5: Layering check**

Run: `just check-layering`
Expected: PASS.

- [ ] **Step 6: Update spec amendment status**

Bump the spec's frontmatter `status:` from `in-progress` to note Phase 1 completion in a brief "status" paragraph at the top of the amendment (or leave at `in-progress` until Phase 2 lands — matches project convention).

- [ ] **Step 7: Commit any remaining changes; ensure working tree clean**

```bash
git status     # clean
git log --oneline master..HEAD   # review full branch history
```

---

## Verification checklist (all must be true before merging)

- [ ] `just build` passes.
- [ ] `just test` passes with no new failures and the dedup-idempotency property holds.
- [ ] `just check` (ormolu + hlint) passes.
- [ ] `just check-layering` passes.
- [ ] `cabal build -fci` passes (−Werror).
- [ ] `grep -r "BankLinkState\|bankLinkState\|BankAccountsLinked\|BankAccountsUnlinked\|webhookSecret" src/ test/ config/` returns only spec/plan references (no code).
- [ ] `grep -r "webhookEventHandler\|webhookValidationHandler" src/` returns nothing.
- [ ] Spec amendment at `docs/specs/2026-04-10-bank-integration-design.md` matches what was actually shipped.
- [ ] PR description updated to reflect resync-only Phase 1 scope.
