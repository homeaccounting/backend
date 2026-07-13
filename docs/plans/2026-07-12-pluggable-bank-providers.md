# Pluggable Bank Providers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make bank-provider identity opaque to the domain (`BankProviderId` over a closed sum type), model transport as a capability (pull vs. file), drive everything from a registry, and let a build compile only the providers it wants.

**Architecture:** A `BankProviderId` newtype replaces `Domain.Banking.Types.BankProvider` and is stored verbatim in banking events/commands. Infrastructure gains a `BankProviderDescriptor` (metadata + optional `pull`/`fileImport` capabilities + shared `classify`) and a `BankProviderRegistry` (`Map BankProviderId BankProviderDescriptor`) assembled at the composition root and held in `AppEnv`. `BankImportService` is refactored to consume `[BankTransaction]` via `classify`, so the pull path is a thin adapter and Spec A's future file path plugs into the same core. Providers are selected at build time via per-provider Cabal flags.

**Tech Stack:** Haskell (GHC 9.10.3, RIO prelude, `NoImplicitPrelude`, `StrictData`), Servant, aeson, Hspec + hspec-discover, QuickCheck. Build/test via `just build` / `just test` (both pass `-fci`/`-Werror`). Run `nix develop` first. Formatting: `just format` (ormolu); lint: `just lint` (hlint).

**Spec:** `docs/specs/2026-07-12-pluggable-bank-providers-design.md`

**Sub-skills:** @superpowers:test-driven-development, @superpowers:verification-before-completion

**PR boundaries:** Tasks 1–6 form the "opaque provider foundation" PR. Task 7 (Cabal-flag pluggability) is self-contained and may ship as a separate follow-up PR.

**Note on the cutover:** Replacing a compiler-checked sum type is inherently atomic — Task 5 flips the domain field and every consumer in one commit because no smaller slice leaves the build green. Tasks 1–4 build all the new machinery *additively* (old sum type + factory still present and compiling) precisely so the cutover is the only breaking commit. Its verification gate is the full `-fci` build + test suite.

---

## File Structure

**New files**
- `src/Infrastructure/Banking/Registry.hs` — `BankProviderRegistry` type + helpers (`registryFromList`, `lookupProvider`, `registryBankProviderIds`). One responsibility: hold and query the set of available providers.
- `test/Domain/Banking/TypesPropertySpec.hs` — QuickCheck for `mkBankProviderId`.
- `test/Infrastructure/Banking/RegistrySpec.hs` — registry lookup + sign-based `classify` default.
- (Task 6 extends `test/Web/API/ConfigurationBankingAPISpec.hs` — no new spec file.)

**Modified files**
- `src/Domain/Banking/Types.hs` — add `BankProviderId`, `unBankProviderId`, `mkBankProviderId`, JSON instances; **remove** `BankProvider` sum type (Task 5).
- `src/Infrastructure/Banking/Provider.hs` — add `BankProviderDescriptor`, `PullCapability`, `FileImportCapability`, `StatementFormat`, `ParseError`, `defaultClassify`; **remove** old `BankProvider` record (Task 5).
- `src/Infrastructure/Banking/Monobank.hs` — add `descriptor`; **remove** `mkBankProviderFactory` (Task 5).
- `src/Infrastructure/Config.hs` — `BankingProvidersConfig` record → `Map BankProviderId ProviderSettings`; registry-based gate.
- `src/Infrastructure/App.hs` — `AppEnv`/`BankingEnv`: `bankProviderFactory` → `bankProviderRegistry`; `HasBankProviderFactory` → `HasBankProviderRegistry`.
- `src/Domain/Configuration/{Commands,Events,Projection}.hs` — `provider :: BankProvider` → `provider :: BankProviderId`.
- `src/Application/Services/ConfigurationService.hs` — `addBankConnection` param → `BankProviderId`; `getConnectionProvider` → `(classify, PullCapability)` via registry.
- `src/Application/Services/BankImportService.hs` — `importTransaction`/`importTransactions`/`resync` take `classify`/`PullCapability`; private helpers rethreaded.
- `src/Web/API/BankingAPI.hs` — handlers use resolved pull capability; `requireBankingEnabled` takes registry.
- `src/Web/API/ConfigurationAPI.hs` — `parseBankProvider` → `mkBankProviderId`; `bankProviderText` → `unBankProviderId`; `addConnectionHandler` gains registry; add the providers-list endpoint (Task 6).
- `app/Main.hs` — assemble `bankProviderRegistry` from config; Cabal-flag CPP (Task 7).
- `package.yaml` — per-provider Cabal flags + conditional modules/deps + `cpp-options` (Task 7).
- Test support: `test/Testkit/AppEnv.hs`, `test/Testkit/InMemoryEventStore.hs`, and specs referencing `Monobank`/factory — updated in Task 5.

---

### Task 1: `BankProviderId` value type (additive)

**Files:**
- Modify: `src/Domain/Banking/Types.hs`
- Test: `test/Domain/Banking/TypesPropertySpec.hs` (create)

- [ ] **Step 1: Write the failing property test**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Domain.Banking.TypesPropertySpec (spec) where

import qualified Data.Set as Set
import Domain.Banking.Types (mkBankProviderId, unBankProviderId, BankProviderId (..))
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)

spec :: Spec
spec = describe "mkBankProviderId" $ do
  let known = Set.fromList [BankProviderId "monobank", BankProviderId "privatbank"]

  it "accepts an id present in the known set" $
    mkBankProviderId known "monobank" `shouldBe` Right (BankProviderId "monobank")

  it "rejects an id absent from the known set" $
    mkBankProviderId known "revolut" `shouldSatisfy` isLeft

  prop "round-trips text for any accepted id" $ \(t :: Text) ->
    let s = Set.singleton (BankProviderId t)
     in fmap unBankProviderId (mkBankProviderId s t) == Right t
```

Note: this spec constructs `BankProviderId` directly, so Task 1 temporarily exports the constructor for tests. If the codebase forbids constructor export (it does — see CLAUDE.md), instead export a test-only `unsafeBankProviderId` and use it here. Prefer `unsafeBankProviderId`.

- [ ] **Step 2: Run to verify it fails** — `just build` then `cabal test all --test-option='--match' --test-option='/mkBankProviderId/'`. Expected: compile error (symbols undefined).

- [ ] **Step 3: Implement in `Domain/Banking/Types.hs`.** Add to the export list `BankProviderId, unBankProviderId, unsafeBankProviderId, mkBankProviderId` and remove `BankProvider (..)` is deferred to Task 5 (keep it for now). Add:

```haskell
import Data.Set (Set)
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..), mkValidationError)

-- | Opaque, stable identifier for a bank provider (canonical slug).
-- Serialized as a bare string so it never churns the event/command schema.
newtype BankProviderId = BankProviderId Text
  deriving (Show, Eq, Ord, Generic)

unBankProviderId :: BankProviderId -> Text
unBankProviderId (BankProviderId t) = t

-- | Bypass validation. For wiring/tests only.
unsafeBankProviderId :: Text -> BankProviderId
unsafeBankProviderId = BankProviderId

-- | Validate a candidate id against the ids the running app knows about
-- (supplied from the registry at the boundary). Keeps the domain free of any
-- provider enumeration.
mkBankProviderId :: Set BankProviderId -> Text -> Either DomainError BankProviderId
mkBankProviderId known t
  | Set.member (BankProviderId t) known = Right (BankProviderId t)
  | otherwise =
      Left (ValidationErr (mkValidationError "provider" "Unknown or unavailable bank provider" t))

instance ToJSON BankProviderId where
  toJSON = toJSON . unBankProviderId

instance FromJSON BankProviderId where
  parseJSON v = BankProviderId <$> parseJSON v

-- BankProviderId is also a Persistent column (read-model) and a config Map key —
-- add these where needed (Tasks 4/5), not necessarily in this module:
--   * Task 5: PersistField/PersistFieldSql BankProviderId in Infrastructure.Database.Orphans
--             (reuse the existing jsonToPersist/jsonFromPersist helpers; bare-string JSON).
--   * Task 4: ToJSONKey BankProviderId (for the config Map's derived ToJSON).
```

`mkValidationError :: Text -> Text -> Text -> ValidationError` returns a `ValidationError`, so it MUST be wrapped in the `ValidationErr` `DomainError` constructor — exactly the pattern at `ConfigurationService.hs:322`. (Confirm the constructor name `ValidationErr` in `Domain.Core.Errors`.)

- [ ] **Step 4: Run** — `just build && cabal test all --test-option='--match' --test-option='/mkBankProviderId/'`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Domain/Banking/Types.hs test/Domain/Banking/TypesPropertySpec.hs
git commit -m "feat(banking): add opaque BankProviderId value type"
```

---

### Task 2: Capability types + registry (additive)

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs`
- Create: `src/Infrastructure/Banking/Registry.hs`
- Test: `test/Infrastructure/Banking/RegistrySpec.hs` (create)

- [ ] **Step 1: Write the failing test**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Banking.RegistrySpec (spec) where

import qualified Data.Set as Set
import Domain.Banking.Types (unsafeBankProviderId)
import Infrastructure.Banking.Provider
  ( BankProviderDescriptor (..), TransactionClassification (..), defaultClassify )
import Infrastructure.Banking.Registry
  ( registryFromList, lookupProvider, registryBankProviderIds )
import RIO
import Test.Hspec
import Testkit.BankingHelpers (sampleBankTransaction)   -- add if missing (see note)

spec :: Spec
spec = do
  let d = BankProviderDescriptor
            { providerId = unsafeBankProviderId "monobank"
            , displayName = "Monobank"
            , classify = defaultClassify
            , pull = Nothing
            , fileImport = Nothing }
      reg = registryFromList [d]

  describe "registry" $ do
    it "looks a descriptor up by id" $
      (displayName <$> lookupProvider (unsafeBankProviderId "monobank") reg) `shouldBe` Just "Monobank"
    it "misses an unknown id" $
      lookupProvider (unsafeBankProviderId "nope") reg `shouldBe` Nothing
    it "exposes its id set" $
      registryBankProviderIds reg `shouldBe` Set.singleton (unsafeBankProviderId "monobank")

  describe "defaultClassify" $ do
    it "classifies a negative amount as expense" $
      defaultClassify (sampleBankTransaction (-5)) `shouldBe` ClassifiedExpense
    it "classifies a non-negative amount as income" $
      defaultClassify (sampleBankTransaction 5) `shouldBe` ClassifiedIncome
```

Note: reuse or add `sampleBankTransaction :: Rational -> BankTransaction` in `test/Testkit/BankingHelpers.hs` (per CLAUDE.md, reuse Testkit; add there if absent) rather than defining it inline.

- [ ] **Step 2: Run to verify it fails** — compile error (undefined types).

- [ ] **Step 3: Add capability types to `Provider.hs`.** Extend exports with `BankProviderDescriptor (..), PullCapability (..), FileImportCapability (..), StatementFormat (..), ParseError (..), defaultClassify`. Add (keep the existing `BankProvider` record for now):

```haskell
import Domain.Banking.Types (BankProviderId, PlainToken)
import RIO (Ord, NonEmpty)   -- adjust the explicit RIO import list

data BankProviderDescriptor = BankProviderDescriptor
  { providerId  :: !BankProviderId
  , displayName :: !Text
  , classify    :: BankTransaction -> TransactionClassification
  , pull        :: !(Maybe (PlainToken -> PullCapability))
  , fileImport  :: !(Maybe FileImportCapability)
  }

data PullCapability = PullCapability
  { fetchAccounts   :: IO (Either Text [BankAccount])
  , fetchStatements :: BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction])
  , registerWebhook :: Text -> IO (Either Text ())
  }

-- Defined now, UNUSED until Spec A (issue #38). Documents the file-import seam.
data FileImportCapability = FileImportCapability
  { supportedFormats :: !(NonEmpty StatementFormat)
  , parseStatement   :: StatementFormat -> ByteString -> Either ParseError [BankTransaction]
  }

data StatementFormat = StatementCsv | StatementXlsx
  deriving (Show, Eq)

newtype ParseError = ParseError Text
  deriving (Show, Eq)

-- | Shared direction rule: money out (negative) is an expense, otherwise income.
defaultClassify :: BankTransaction -> TransactionClassification
defaultClassify tx
  | tx.amount < 0 = ClassifiedExpense
  | otherwise = ClassifiedIncome
```

`Provider.hs` needs `{-# LANGUAGE OverloadedRecordDot #-}` for `tx.amount`; add it if absent. Note `PlainToken` currently lives in `Domain.Banking.Types` — import it there.

- [ ] **Step 4: Create `src/Infrastructure/Banking/Registry.hs`.**

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Registry
  ( BankProviderRegistry,
    registryFromList,
    lookupProvider,
    registryBankProviderIds,
  )
where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Banking.Types (BankProviderId)
import Infrastructure.Banking.Provider (BankProviderDescriptor (..))
import RIO

-- | The set of providers available to this build+config (compiled-in AND enabled).
type BankProviderRegistry = Map BankProviderId BankProviderDescriptor

registryFromList :: [BankProviderDescriptor] -> BankProviderRegistry
registryFromList = Map.fromList . map (\d -> (d.providerId, d))

lookupProvider :: BankProviderId -> BankProviderRegistry -> Maybe BankProviderDescriptor
lookupProvider = Map.lookup

registryBankProviderIds :: BankProviderRegistry -> Set BankProviderId
registryBankProviderIds = Map.keysSet
```

`Registry.hs` needs `{-# LANGUAGE OverloadedRecordDot #-}` for `d.providerId`.

- [ ] **Step 5: Wire the new spec + run** — `just build && cabal test all --test-option='--match' --test-option='/registry/'` and `/defaultClassify/`. Expected: PASS.
- [ ] **Step 6: Format, lint, commit**

```bash
just format && just lint
git add src/Infrastructure/Banking/Provider.hs src/Infrastructure/Banking/Registry.hs \
        test/Infrastructure/Banking/RegistrySpec.hs test/Testkit/BankingHelpers.hs
git commit -m "feat(banking): add provider descriptor, capabilities, and registry"
```

---

### Task 3: Monobank descriptor (additive)

**Files:**
- Modify: `src/Infrastructure/Banking/Monobank.hs`
- Test: `test/Infrastructure/Banking/MonobankSpec.hs`

- [ ] **Step 1: Add a failing test** asserting the descriptor's shape (append to `MonobankSpec`):

```haskell
describe "descriptor" $ do
  let d = Monobank.descriptor testMonobankConfig testHttpManager   -- reuse existing test wiring
  it "has the monobank id and display name" $ do
    unBankProviderId d.providerId `shouldBe` "monobank"
    d.displayName `shouldBe` "Monobank"
  it "supports the pull transport and not file import" $ do
    isJust d.pull `shouldBe` True
    isNothing d.fileImport `shouldBe` True
```

Reuse the config/manager fixtures already used by `MonobankSpec` (grep the file for how it currently constructs the provider via `mkBankProviderFactory`); the descriptor takes the same inputs.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement `descriptor` in `Monobank.hs`** (keep `mkBankProviderFactory` for now). Export `descriptor`. It reuses the existing internal fetch/classify functions that `mkBankProviderFactory` already builds:

```haskell
descriptor :: AppConfig -> Manager -> BankProviderDescriptor
descriptor config manager =
  BankProviderDescriptor
    { providerId = unsafeBankProviderId "monobank"
    , displayName = "Monobank"
    , classify = defaultClassify           -- monobank uses the shared sign-based rule
    , pull = Just (\token -> PullCapability
        { fetchAccounts   = ...existing monobank fetchAccounts using token+config+manager...
        , fetchStatements = ...existing...
        , registerWebhook = ...existing... })
    , fileImport = Nothing
    }
```

Extract the closures from today's `mkBankProviderFactory` body verbatim; `classify` moves to `defaultClassify` (confirm the current monobank `classifyTransaction` is exactly sign-based — it is; if not, keep a local classifier). Do NOT delete `mkBankProviderFactory` yet.

- [ ] **Step 4: Run** the descriptor tests + the whole `MonobankSpec`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Infrastructure/Banking/Monobank.hs test/Infrastructure/Banking/MonobankSpec.hs
git commit -m "feat(banking): expose monobank as a provider descriptor"
```

---

### Task 4: Config providers map + registry-based gate

> **MERGED INTO TASK 5 (executed together as one atomic commit).** During execution we
> confirmed Task 4 cannot be an independently-green commit: changing the config to a
> `Map BankProviderId ProviderSettings` immediately breaks the `apiBaseUrl` readers
> (`mkBankProviderFactory`, `Monobank.descriptor`) and the `bankingFeatureAvailable`
> consumers (`requireBankingEnabled`, `computeBankingFeatureEnabled`), all of which are
> only rewired in Task 5. Rather than add throwaway transitional accessors, the config
> change is done as the FIRST steps of the Task 5 cutover. The task content below is the
> config spec that Task 5 executes.

**Files:**
- Modify: `src/Infrastructure/Config.hs`
- Test: `test/Infrastructure/ConfigSpec.hs`

Goal: parse `banking.providers` as `Map BankProviderId ProviderSettings`. The registry is assembled in `Main` from *enabled* providers, so "available" downstream means simply "in the registry".

- [ ] **Step 1: Write failing tests** in `ConfigSpec` for the new parser:

```haskell
it "parses banking.providers as a keyed map with per-provider settings" $ do
  cfg <- loadTestConfig   -- reuse existing helper; sample yaml with providers.monobank
  let mono = Map.lookup (unsafeBankProviderId "monobank") cfg.banking.providers
  (providerEnabled <$> mono) `shouldBe` Just True
```

Match the existing `ConfigSpec` loading helper and assertion style.

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement.** Replace `BankingProvidersConfig` and `MonobankProviderConfig` with:

```haskell
data ProviderSettings = ProviderSettings
  { enabled  :: !Bool
  , settings :: !Object   -- raw provider-specific keys (e.g. api_base_url); parsed per provider in Main
  }

instance FromJSON ProviderSettings where
  parseJSON = withObject "ProviderSettings" $ \v ->
    ProviderSettings <$> v .:? "enabled" .!= False <*> pure v

-- in BankingConfig:
--   providers :: !(Map BankProviderId ProviderSettings)
```

`BankingConfig.parseJSON` parses `providers` as `Map Text ProviderSettings` then maps keys through `unsafeBankProviderId` (config keys are trusted). Provide accessor `providerEnabled :: ProviderSettings -> Bool` (or expose `enabled` via a helper given `NoFieldSelectors`).

**JSON instances (required — `AppConfig` derives generic `ToJSON`, which forces `ToJSON BankingConfig` over the Map):** add `instance ToJSONKey BankProviderId` (from `unBankProviderId`) in `Domain.Banking.Types` and `instance ToJSON ProviderSettings` (renders `{ enabled, ... }`; `settings` already holds the whole object incl. `enabled`, so `toJSON = \ps -> Object ps.settings` — via `OverloadedRecordDot`, since `NoFieldSelectors` means there is no bare `settings` selector function). The `FromJSON` side needs no `FromJSONKey` — the parser goes via `Map Text` explicitly. Replace `anyProviderEnabled`; `bankingFeatureAvailable` becomes registry-driven and moves to a form callable with the registry — define:

```haskell
-- master switch only; the "≥1 available provider" half is the registry being non-empty,
-- checked at the call site in Web with HasBankProviderRegistry.
bankingMasterEnabled :: BankingConfig -> Bool
bankingMasterEnabled = (.enabled)
```

(The combined gate `bankingMasterEnabled cfg && not (Map.null registry)` is assembled in `requireBankingEnabled`, Task 5.)

- [ ] **Step 4: Update `config/{local,test,prod}.yaml`** `banking.providers.monobank` to the `{ enabled, api_base_url }` object shape (it is already keyed by `monobank`; confirm each file). Run `ConfigSpec`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Infrastructure/Config.hs test/Infrastructure/ConfigSpec.hs config/local.yaml config/test.yaml config/prod.yaml
git commit -m "refactor(config): key banking providers by id with per-provider settings"
```

---

### Task 5: Cutover — flip to `BankProviderId` + registry, remove sum type & factory (atomic)

**This is the one breaking commit.** All the following change together; the gate is a green full build + full test suite. Work top-down, fixing compile errors the compiler reports until `just build` passes, then `just test`.

**Files (all modified in one commit):**
- `src/Domain/Configuration/Commands.hs`, `Events.hs`, `Projection.hs`
- `src/Application/ReadModels/Configuration.hs` — imports `BankProvider` (~line 78); the Persistent entity `ConfigBankConnectionEntity` has a `provider BankProvider` column (~line 199) → becomes `BankProviderId`.
- `src/Infrastructure/Database/Orphans.hs` — **remove** `instance PersistField/PersistFieldSql BankProvider` (~lines 367–373, import ~line 24); **add** `PersistField BankProviderId`/`PersistFieldSql BankProviderId` (reuse the existing `jsonToPersist`/`jsonFromPersist` helpers — `BankProviderId`'s bare-string JSON round-trips cleanly).
- `src/Application/Services/ConfigurationService.hs`
- `src/Application/Services/BankImportService.hs`
- `src/Web/API/ConfigurationAPI.hs`, `src/Web/API/BankingAPI.hs`
- `src/Infrastructure/App.hs`, `src/Infrastructure/Config.hs` (drop leftover factory refs)
- `src/Infrastructure/Banking/Monobank.hs` (remove `mkBankProviderFactory` **and** `mkMonobankProvider :: ... -> BankProvider`, ~line 47 — both return the removed record)
- `src/Infrastructure/Banking/Provider.hs` (remove old `BankProvider` record; `BankTransaction`/`BankAccount`/`TransactionClassification` stay)
- `src/Domain/Banking/Types.hs` (remove `BankProvider` sum type + its JSON)
- `app/Main.hs`
- Tests: `test/Testkit/AppEnv.hs`, `test/Testkit/InMemoryEventStore.hs`, `test/Testkit/BankingHelpers.hs` (`mkMockProvider :: ... -> BankProvider` returns the removed record → refactor to build a descriptor/registry or drop), `test/Infrastructure/Banking/MonobankSpec.hs` (uses `mkMonobankProvider` ~line 75), `test/Application/Services/{ConfigurationServiceSpec,BankImportServiceSpec}.hs`, `test/Domain/Configuration/{CommandHandlerSpec,ProjectionSpec}.hs`, `test/Integration/{BankImportWorkflowSpec,CrossKindAmendmentIntegrationSpec}.hs`, `test/Web/API/{BankConnectionAPISpec,BankingAPISpec}.hs`

- [ ] **Step 1: Domain field flip.** In `Commands.hs`/`Events.hs`/`Projection.hs`, change every `provider :: BankProvider` to `provider :: BankProviderId` (import from `Domain.Banking.Types`; drop the `BankProvider` import). `deriveJSON`/projection updates follow the field automatically. In `Domain.Banking.Types`, delete the `BankProvider` sum type and its `ToJSON`/`FromJSON`.

- [ ] **Step 1b: Persistence flip.** In `Application/ReadModels/Configuration.hs`, the `ConfigBankConnectionEntity.provider` column becomes `BankProviderId` (swap the import). In `Infrastructure/Database/Orphans.hs`, delete the `PersistField`/`PersistFieldSql BankProvider` instances and add the same two for `BankProviderId` via the existing `jsonToPersist`/`jsonFromPersist` helpers (grep the file for how another newtype-over-JSON column does it, e.g. an existing `PersistField` written through those helpers, and copy the shape).

- [ ] **Step 2: AppEnv registry.** In `Infrastructure/App.hs`: replace `BankingEnv.bankProviderFactory :: Domain.BankProvider -> PlainToken -> BankProvider` with `bankProviderRegistry :: BankProviderRegistry`; rename `HasBankProviderFactory`/`bankProviderFactoryL` → `HasBankProviderRegistry`/`bankProviderRegistryL`. Import `Infrastructure.Banking.Registry`.

- [ ] **Step 3: ConfigurationService.**
  - `addBankConnection :: ... -> BankProviderId -> ...` (was `Domain.BankProvider`).
  - Rewrite `getConnectionProvider` to return a ready pull pair:
    ```haskell
    getConnectionProvider :: UserId -> BankConnectionId
                          -> AppM (Either DomainError (BankTransaction -> TransactionClassification, PullCapability))
    getConnectionProvider userId connId = runExceptT $ do
      conn  <- ...load connection...
      token <- ...decrypt token...
      reg   <- lift (view bankProviderRegistryL)
      desc  <- maybe (throwE (BankingError "provider not available")) pure
                 (lookupProvider conn.provider reg)
      mkPull <- maybe (throwE (BankingError "provider has no pull transport")) pure desc.pull
      pure (desc.classify, mkPull token)
    ```
    Keep the exact `DomainError` constructors the codebase already uses for these cases (grep current `getConnectionProvider`).

- [ ] **Step 4: BankImportService classify seam.**
  - `importTransaction`/`importMatchedTransaction`/`commitImport`: replace the `BankProvider` param with `classify :: BankTransaction -> TransactionClassification`; `provider.classifyTransaction tx` → `classify tx`.
  - Add `importTransactions classify userId accountLink txns` (the flat neutral core) OR keep `resync`'s per-account loop but take `(classify, PullCapability)`:
    ```haskell
    resync :: (BankTransaction -> TransactionClassification) -> PullCapability
           -> UserId -> [(BankAccountId, AccountId)] -> UTCTime -> UTCTime -> AppM ResyncResult
    ```
    `processAccount` now calls `pull.fetchStatements` and `importTransaction classify ...`.

- [ ] **Step 5: Web handlers.**
  - `BankingAPI.resyncHandler`/`externalAccountsHandler`: `getConnectionProvider` now yields `(classify, pull)`; call `resync classify pull ...` and `pull.fetchAccounts`.
  - `requireBankingEnabled :: (HasAppConfig env, HasBankProviderRegistry env) => AppM ()` = `unless (bankingMasterEnabled cfg.banking && not (Map.null reg)) $ throwDomainError (FeatureDisabled "banking")`.
  - `ConfigurationAPI`: `parseBankProvider` → look up the registry ids and call `mkBankProviderId (registryBankProviderIds reg) raw`; `bankProviderText` → `unBankProviderId`; `addConnectionHandler` reads the registry (`view bankProviderRegistryL`) to supply the known set and to reject unavailable providers with the existing validation error path.
  - `ConfigurationAPI.computeBankingFeatureEnabled` (~line 857) currently calls the pure `bankingFeatureAvailable cfg.banking` to populate the ungated `bankingFeatureEnabled` DTO field (read by 3 handlers). It now needs the registry too — same `bankingMasterEnabled cfg.banking && not (Map.null reg)` check (add `HasBankProviderRegistry`).

- [ ] **Step 6: Main assembly.** In `app/Main.hs`, replace the `bankProviderFactory = mkBankProviderFactory ...` wiring with:
    ```haskell
    let enabledDescriptors =
          [ d | d <- allDescriptors config httpManager
              , Just s <- [Map.lookup d.providerId config.banking.providers]
              , s.enabled ]
        registry = registryFromList enabledDescriptors
    -- allDescriptors is the (CPP-free for now) list: [Monobank.descriptor config httpManager]
    ```
    Put `bankProviderRegistry = registry` into `BankingEnv`. (Task 7 replaces `allDescriptors`'s body with CPP.)

- [ ] **Step 7: Test support + specs.** Update `Testkit/AppEnv.hs` and `Testkit/InMemoryEventStore.hs` to build a test registry (`registryFromList [Monobank.descriptor testCfg testMgr]` or a stub descriptor) instead of a factory. In every spec listed above, replace `Monobank` (the constructor) with `unsafeBankProviderId "monobank"` and any factory usage with the descriptor/registry. **Do not** change the behavioural assertions — their staying green is the transport-neutrality proof.

- [ ] **Step 8: Build & test to green.** Run `just build` (fix compile errors reported by the cutover), then `just rebuild` for a definitive `-fci` check, then `just test`.
  - Expected: full suite PASS. Environmental `eventium_test` integration failures (needs a manually-created DB) are pre-existing and acceptable — see project memory; distinguish them from regressions by running the banking specs explicitly:
    `cabal test all --test-option='--match' --test-option='/Banking/'`.

- [ ] **Step 9: Format, lint, commit**

```bash
just format && just lint
git add -A
git commit -m "feat(banking)!: opaque BankProviderId + registry, transport-neutral import core

BREAKING CHANGE: banking events/commands store provider as a string slug; the
BankProvider sum type and mkBankProviderFactory are removed."
```

---

### Task 6: Providers-list API (additive)

Lives in **`ConfigurationAPI`** (configuration/catalog surface), a sibling of the existing
`.../configuration/banking/connections` routes — not `BankingAPI` (operational,
hard-gated). Rationale in spec §6.

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs`
- Test: `test/Web/API/ConfigurationBankingAPISpec.hs` (extend — it already exercises the
  configuration-banking surface)

- [ ] **Step 1: Write the failing test.** Using the existing `ConfigurationBankingAPISpec` harness (grep for how it builds a test app + registry and hits config-banking routes), assert `GET /api/users/me/configuration/banking/providers` returns one entry for a monobank-only registry:

```haskell
it "lists available providers with capability flags" $ do
  resp <- getProviders   -- helper hitting the endpoint with the test app
  resp `shouldBe` [ ProviderInfoDTO { id = "monobank", displayName = "Monobank"
                                    , supportsPull = True, supportsFile = False } ]
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement.** Add to `ConfigurationAPI`:
    ```haskell
    data ProviderInfoDTO = ProviderInfoDTO
      { id :: Text, displayName :: Text, supportsPull :: Bool, supportsFile :: Bool }
      deriving (Show, Eq, Generic)
    instance ToJSON ProviderInfoDTO
    instance FromJSON ProviderInfoDTO
    ```
    Add the route as a sibling of the banking-connections routes:
    `"api" :> "users" :> "me" :> "configuration" :> "banking" :> "providers" :> Get '[JSON] [ProviderInfoDTO]`
    (authenticated; per spec §6 **not** behind the strict banking gate). Handler reads `view bankProviderRegistryL`, maps each descriptor:
    `ProviderInfoDTO (unBankProviderId d.providerId) d.displayName (isJust d.pull) (isJust d.fileImport)`.
    Add the handler to the `ConfigurationAPI` server tuple in matching position (grep where the `configuration/banking/connections` handlers are assembled). `ProviderInfoDTO`'s bare `id` field is safe — `ConfigurationAPI` already has `id :: UUID` DTO fields under `NoFieldSelectors`.

- [ ] **Step 4: Run** — `cabal test all --test-option='--match' --test-option='/lists available providers/'`. Expected: PASS.
- [ ] **Step 5: Format, lint, commit**

```bash
just format && just lint
git add src/Web/API/ConfigurationAPI.hs test/Web/API/ConfigurationBankingAPISpec.hs
git commit -m "feat(banking): list available providers under configuration/banking/providers"
```

---

### Task 7: Build-time provider pluggability (Cabal flags) — optionally a separate PR

**Files:**
- Modify: `package.yaml` (regenerates `backend.cabal` via hpack)
- Modify: `app/Main.hs`

- [ ] **Step 1: Add the flag + conditional wiring to `package.yaml`.**
    ```yaml
    flags:
      monobank:
        description: Compile the Monobank (UA) pull provider
        manual: true
        default: true
    ```
    In the `library` stanza, guard the module + its deps:
    ```yaml
    library:
      when:
        - condition: flag(monobank)
          exposed-modules:
            - Infrastructure.Banking.Monobank
            - Infrastructure.Banking.Monobank.Internal
          # dependencies: [ ... monobank-only deps, if any ... ]
    ```
    In the `executable backend` stanza:
    ```yaml
      when:
        - condition: flag(monobank)
          cpp-options: -DPROVIDER_MONOBANK
    ```

- [ ] **Step 2: CPP-guard the registry assembly in `app/Main.hs`.** Add `{-# LANGUAGE CPP #-}`. Replace `allDescriptors`'s body:
    ```haskell
    allDescriptors :: AppConfig -> Manager -> [BankProviderDescriptor]
    allDescriptors config httpManager =
      []
#ifdef PROVIDER_MONOBANK
      ++ [ Monobank.descriptor config httpManager ]
#endif
    ```
    The `import ...Monobank` must also be CPP-guarded (`#ifdef PROVIDER_MONOBANK`), since the module is absent when the flag is off.

- [ ] **Step 3: Verify the default build** — `just rebuild && just test`. Expected: green (monobank present; registry non-empty).

- [ ] **Step 4: Verify the trimmed build compiles and disables banking** — build with the flag off:
    `cabal build all -f-monobank` (and the exe). Expected: compiles; `allDescriptors` is empty → registry empty → `requireBankingEnabled` yields `FEATURE_DISABLED`. This proves a provider (and its deps/module) can be excluded without breaking the build. Restore the default afterward.

- [ ] **Step 5: Commit**

```bash
just format && just lint
git add package.yaml backend.cabal app/Main.hs
git commit -m "feat(banking): build-time provider selection via Cabal flags"
```

---

## Final Verification

- [ ] `just rebuild` (clean `-fci`/`-Werror` build — the warm-cache caveat means only a clean build is definitive; see project memory).
- [ ] `just test` — banking specs green; note any `eventium_test`-DB environmental failures separately (pre-existing, not regressions).
- [ ] `just check` (format + lint) clean.
- [ ] Manual smoke (optional, @superpowers:verification-before-completion): start the app, `GET /api/users/me/configuration/banking/providers` returns `monobank`; a monobank resync still imports as before.
- [ ] Confirm no remaining references to `Domain.Banking.Types.BankProvider` (the sum type), `mkBankProviderFactory`, or `HasBankProviderFactory`:
      `grep -rn 'mkBankProviderFactory\|HasBankProviderFactory\|BankProvider\b' src app test | grep -v BankProviderId` (expect only `BankProviderDescriptor`/`BankProviderRegistry` hits).
