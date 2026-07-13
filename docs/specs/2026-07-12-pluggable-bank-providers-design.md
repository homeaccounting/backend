---
status: draft
date: 2026-07-12
---

# Pluggable bank providers: opaque identity, transport capabilities, build-time selection

## Problem

The banking subsystem hard-codes provider identity into the domain and hard-wires
a single transport into the import path. Two shapes carry the coupling today:

- **`Domain.Banking.Types.BankProvider`** is a closed sum type (`= Monobank`) that is
  **embedded in the event/command schema** — `BankConnectionAdded.provider`,
  `AddBankConnection.provider`, the `BankConnection` projection, etc. Adding a
  provider means editing the domain enum, its JSON, and every exhaustive match.
- **`Infrastructure.Banking.Provider.BankProvider`** is a record-of-functions whose
  fields are entirely pull-API-shaped (`fetchAccounts`, `fetchStatements`,
  `registerWebhook`, `classifyTransaction`). `mkBankProviderFactory` dispatches on
  the enum. `Application.Services.BankImportService.resync` calls `fetchStatements`
  directly, so the import path only knows the API-pull transport.

This blocks two goals:

1. **A stable event/command model.** Every new provider currently churns the domain
   event schema.
2. **Providers a future open-source user can opt out of at build time** — the codebase
   compiles every provider and drags every provider's dependencies unconditionally.

A third, related need surfaced during design: the account **bank name** field
(`Domain.Core.Types.BankAccountProperties.bankName :: Maybe Text`) is free text with no
relationship to the providers we actually support, so users can type "MonoBank" or a
misspelling instead of the canonical provider name.

This spec designs the **foundation** that resolves all three. A follow-up spec
("Spec A", issue #38) adds the first file-import provider (PrivatBank statement
CSV/XLSX) on top of this foundation; it is explicitly **out of scope** here beyond
defining the seam it attaches to.

Project note: there is **no backward-compatibility phase** — event, command, and DTO
shapes may be changed cleanly. No upcasters or coexistence machinery are needed for the
schema changes below.

## Goals

- Make provider identity **opaque to the domain**: adding/removing a provider never
  edits the event or command schema.
- Model **transport as a capability dimension** (pull API vs. file import) so a
  file-import provider slots into the existing abstraction without reshaping it.
- Decouple the import core from any single transport: it consumes `[BankTransaction]`.
- Allow a build to **compile only the providers it wants**, excluding unwanted
  providers' modules and dependencies.
- Expose supported providers over a **read API** so clients can offer a canonical bank
  select on account creation.

## Non-goals

- Implementing any file-import provider or parser (Spec A / issue #38).
- The statement-upload endpoint, `externalId` synthesis, Telegram document routing, and
  the fate of PR homeaccounting/backend#128 (all Spec A).
- Server-side validation/guarding of the account `bankName` value (handled by the
  client select, see §7).
- A generic open-banking / OAuth aggregator (out of scope per #38).
- Changes to the import saga's accounting (double-entry vs. External, per-leg FX).

## Design

### 1. Provider identity — `BankProviderId` (Domain, pure)

Replace the closed `BankProvider` sum type with an opaque newtype:

```haskell
-- Domain.Banking.Types
newtype BankProviderId = BankProviderId Text        -- canonical slug, e.g. "monobank", "privatbank"
  deriving (Eq, Ord)                         -- required as a Map/Set key

unBankProviderId :: BankProviderId -> Text

-- JSON is a BARE string ("monobank"), not the derived single-field wrapper, so
-- events/commands serialize the slug directly. Hand-written instances:
instance ToJSON BankProviderId where toJSON = toJSON . unBankProviderId
instance FromJSON BankProviderId where parseJSON = fmap BankProviderId . parseJSON

-- Validates a candidate id against the set of ids the running app knows about.
-- The known set is supplied by the boundary (from the registry), keeping the
-- domain pure and free of any provider enumeration.
mkBankProviderId :: Set BankProviderId -> Text -> Either DomainError BankProviderId
```

`BankProviderId` is stored verbatim in the banking events/commands
(`BankConnectionAdded.provider`, `AddBankConnection.provider`, the `BankConnection`
projection). **Adding or removing a provider never touches these schemas** — the id is
just text. `mkBankProviderId` is used at the connection-creation boundary — concretely
`Web.API.ConfigurationAPI.addConnectionHandler`, replacing today's hard-coded
`parseBankProvider` (`"monobank" → Monobank`) — so a connection cannot be created for a
provider that is not compiled in / enabled. That handler gains registry access to supply
the known-id set; `bankProviderText` (which renders the sum type to wire text) becomes
`unBankProviderId`.

`Domain.Banking.Types` imports only `Domain.Core.Errors` (for `DomainError`); it must not
import `Domain.Core.Types`, so no import cycle is introduced when other domain modules
reference `BankProviderId`.

### 2. Provider capabilities — `BankProviderDescriptor` (Infrastructure)

Capability records live in Infrastructure (they contain `IO`; the Domain stays pure).
One descriptor per provider, with each transport an optional sub-record — capability
presence is *data*, and callers pattern-match the `Maybe`:

```haskell
-- Infrastructure.Banking.Provider
data BankProviderDescriptor = BankProviderDescriptor
  { providerId  :: !BankProviderId
  , displayName :: !Text                                   -- canonical, user-facing ("Monobank")
  , classify    :: BankTransaction -> TransactionClassification  -- shared; sign-based default
  , pull        :: !(Maybe (PlainToken -> PullCapability))       -- Just for monobank
  , fileImport  :: !(Maybe FileImportCapability)                 -- slot defined now; Spec A fills it
  }

data PullCapability = PullCapability
  { fetchAccounts   :: IO (Either Text [BankAccount])
  , fetchStatements :: BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction])
  , registerWebhook :: Text -> IO (Either Text ())
  }

-- Defined by this spec, UNUSED until Spec A. Documents the seam a file-import
-- provider attaches to.
data FileImportCapability = FileImportCapability
  { supportedFormats :: NonEmpty StatementFormat
  , parseStatement   :: StatementFormat -> ByteString -> Either ParseError [BankTransaction]
  }

data StatementFormat = StatementCsv | StatementXlsx   -- extend as providers need
newtype ParseError = ParseError Text
```

Rationale for **one descriptor with optional capabilities** over separate per-transport
registries: a single source of provider metadata, one id-validation point, and a
provider that grows a second transport is a `Just` flip rather than a second map entry.

`classify` is a descriptor-level field with a shared sign-based default
(`amount < 0 → ClassifiedExpense`, else `ClassifiedIncome`); Monobank and the future
PrivatBank both use the default, so neither needs a custom classifier.

### 3. Registry + build-time pluggability

```haskell
-- Infrastructure.Banking.Registry
type BankProviderRegistry = Map BankProviderId BankProviderDescriptor

registryFromList :: [BankProviderDescriptor] -> BankProviderRegistry
registryBankProviderIds :: BankProviderRegistry -> Set BankProviderId
```

`AppEnv` holds a `BankProviderRegistry` (replacing the current
`bankProviderFactory :: Domain.BankProvider -> PlainToken -> Infra.BankProvider`). The
capability `HasBankProviderRegistry env` provides narrow access.

The registry is **assembled at the composition root** (`app/`), the only place that
names concrete providers — so conditional compilation stays out of the library
entirely:

```haskell
-- app/ (composition root). The single site with conditional compilation.
descriptors :: [BankProviderDescriptor]
descriptors =
  []
#ifdef PROVIDER_MONOBANK
  ++ [ Monobank.descriptor config httpManager ]
#endif
#ifdef PROVIDER_PRIVATBANK        -- Spec A
  ++ [ PrivatBank.descriptor ]
#endif
```

Build-time selection:

- One Cabal flag per provider (e.g. `flag monobank`, `flag privatbank`), **default:
  True** (batteries-included build). Follows the existing `flag(ci)` precedent in
  `package.yaml`.
- In the `library` stanza, a per-provider `when: { condition: flag(x), ... }` block guards
  that provider's `exposed-modules` **and** its `dependencies`, so a disabled provider is
  not compiled and its heavy transitive deps (e.g. an XLSX/CSV parser needed only by
  PrivatBank) never enter the build. This is the literal "don't compile providers you
  don't need."
- In the `executable` stanza, the same flags set `cpp-options: -DPROVIDER_X` (via a
  matching `when: condition: flag(x)`), and `app/` modules using the `#ifdef` add
  `{-# LANGUAGE CPP #-}`. The `when`-blocks handle module/dep inclusion; the
  `cpp-options` are what make the `#ifdef PROVIDER_X` guards resolve.
- The `-fci` (`-Werror`) gate must stay green for representative flag combinations. CI
  builds the default (all-on) configuration; a documented `-f-privatbank` /
  monobank-only build is verified as the representative "trimmed" configuration.

Each provider module exposes a single `descriptor` (or `mkDescriptor config manager`)
value — the module's only public surface for registration.

### 4. Transport-neutral import core

`BankImportService` is refactored so the fallible per-transaction core no longer mentions
`fetchStatements`. The seam is a plain `[BankTransaction]` plus the shared `classify`:

```haskell
-- The neutral core both transports feed. No behaviour change vs. today.
importTransactions
  :: (BankTransaction -> TransactionClassification)
  -> UserId -> [(BankAccountId, AccountId)] -> [BankTransaction] -> AppM ResyncResult

-- importTransaction loses its `BankProvider` parameter, gaining `classify` instead.
importTransaction
  :: (BankTransaction -> TransactionClassification)
  -> UserId -> [(BankAccountId, AccountId)] -> BankTransaction
  -> AppM (Either DomainError (Maybe TransactionId))
```

The pull path becomes a thin adapter that fetches then delegates. Because
`PullCapability` is only obtainable by applying the descriptor's `pull` function to a
`PlainToken`, the token must be resolved *before* `resync`; `resync` therefore takes an
already-built `PullCapability` plus the shared `classify`, not a bare descriptor:

```haskell
resync :: (BankTransaction -> TransactionClassification)   -- descriptor.classify
       -> PullCapability                                   -- descriptor.pull applied to the decrypted token
       -> UserId -> [(BankAccountId, AccountId)]
       -> UTCTime -> UTCTime -> AppM ResyncResult
-- for each account: pull.fetchStatements → collect → importTransactions classify
```

The private helpers currently threading `provider` (`importMatchedTransaction`,
`commitImport`, and the `direction` in `commitMatchingCurrencyImport`) are rethreaded to
carry `classify` instead; this is a mechanical substitution with no behaviour change.

Spec A's file path will be the symmetric adapter: `parseStatement … → importTransactions
descriptor.classify …`, reusing dedup (`BankImportReadModel`), per-leg FX, and category
resolution untouched. This refactor has **no user-visible effect**; correctness is
verified by the existing monobank pull tests staying green — that is the proof the
`[BankTransaction]` seam is genuinely transport-neutral.

`ConfigurationService.getConnectionProvider` is updated to resolve a connection (by
`connection.provider` in the registry) and its decrypted token into a **ready-to-use
`(classify, PullCapability)` pair** — applying `descriptor.pull` to the token internally —
erroring with a `DomainError` when the id is unknown/not-compiled-in or when the resolved
descriptor has no `pull` capability. `resyncHandler` passes that pair to `resync`;
`externalAccountsHandler` calls the pair's `PullCapability.fetchAccounts`. Handlers in
`Web.API.BankingAPI` stay provider-agnostic.

### 5. Config & feature gate

`banking.providers` becomes a **`Map BankProviderId ProviderSettings`** keyed by id, instead
of the current fixed `{ monobank :: MonobankProviderConfig }` record, so the config schema
is as stable as the event schema:

```yaml
banking:
  enabled: true
  providers:
    monobank:
      enabled: true
      api_base_url: "https://api.monobank.ua"   # provider-specific keys parsed per provider
```

- Each provider parses its own settings from the raw object at registry-assembly time in
  `app/` (config → descriptor). Provider-specific keys never appear in a shared record.
- A provider is **available** iff it is compiled-in (a descriptor exists in the registry)
  **and** enabled in config.
- The feature gate generalizes to: `banking.enabled ∧ (≥1 available provider)`. Because
  "available" intersects config-enabled with **compiled-in** providers, the gate can no
  longer be a pure `BankingConfig -> Bool`: `bankingFeatureAvailable` and
  `requireBankingEnabled` (today `view`ing only `appConfig`) take the registry (a
  `HasBankProviderRegistry` constraint), as does the banking-availability field the
  ConfigurationAPI config DTO reports to clients.

### 6. Providers-list read API

Expose the available providers so clients can render a bank select. It lives in
**`Web.API.ConfigurationAPI`**, not `BankingAPI`: it is configuration/catalog metadata
that feeds the connection-creation form (`addConnectionHandler`, which validates the
chosen id via `mkBankProviderId`) and the account bank-name select — a sibling of the
existing `.../configuration/banking/connections` routes, not an operation on a
connection.

```
GET /api/users/me/configuration/banking/providers  ->  [ProviderInfoDTO]

data ProviderInfoDTO = ProviderInfoDTO
  { id           :: Text        -- BankProviderId slug
  , displayName  :: Text        -- canonical name ("Monobank")
  , supportsPull :: Bool        -- descriptor.pull is Just
  , supportsFile :: Bool        -- descriptor.fileImport is Just (false until Spec A)
  }
```

Returns the **available** set (compiled-in ∧ enabled), projected from the registry.
Authenticated; **not** behind the strict banking operational gate (it is only
names/capabilities and is also useful for the account-creation UI, independent of whether
the user syncs) — consistent with ConfigurationAPI's other per-user config reads. The
capability flags let a client show, per provider, whether it can sync via API or via file
upload.

### 7. Account bank field — unchanged model, client-driven canonicalization

`BankAccountProperties.bankName :: Maybe Text` stays **free text** — no sum type, no
Domain change, no server-side validation. Canonicalization is a client concern: the
account-creation form initializes the bank field as a **select populated from
`GET /api/users/me/configuration/banking/providers` (display names), with a free-text
"other" option**. This
gives the user the canonical provider names to pick from (so they don't type "MonoBank"
or a typo) while still allowing an arbitrary bank we don't support. Keeping this out of
the domain avoids fuzzy-match/typo-guard machinery the UX already handles.

## Schema & interface changes (summary)

Because there is no back-compat phase, these are direct replacements (no upcasters):

- **Domain.Banking.Types**: remove `BankProvider` sum type + its JSON; add `BankProviderId`,
  `unBankProviderId`, `mkBankProviderId`.
- **Domain.Configuration.Commands / Events / Projection**: `provider :: BankProvider`
  fields become `provider :: BankProviderId` (JSON becomes a plain string).
- **Infrastructure.Banking.Provider**: replace the `BankProvider` record with
  `BankProviderDescriptor`, `PullCapability`, `FileImportCapability`, `StatementFormat`,
  `ParseError`. `BankAccount`/`BankTransaction`/`TransactionClassification` unchanged.
- **Infrastructure.Banking.Registry** (new): `BankProviderRegistry` + helpers.
- **Infrastructure.Banking.Monobank**: expose `descriptor` (pull = Just, fileImport =
  Nothing); remove `mkBankProviderFactory`.
- **Infrastructure.App / AppEnv**: `bankProviderFactory` → `bankProviderRegistry` +
  `HasBankProviderRegistry`.
- **Infrastructure.Config**: `BankingProvidersConfig` fixed record → `Map BankProviderId
  ProviderSettings`; `bankingFeatureAvailable` (and any `anyProviderEnabled` role) take
  the registry rather than config alone.
- **Application.Services.BankImportService**: `importTransaction`/`importTransactions`
  take `classify` instead of `BankProvider`; `resync` takes `(classify, PullCapability)`;
  private helpers rethreaded from `provider` to `classify`.
- **Application.Services.ConfigurationService**: `getConnectionProvider` resolves to a
  `(classify, PullCapability)` pair via the registry; `addBankConnection`'s
  `Domain.BankProvider` parameter becomes `BankProviderId`.
- **Web.API.ConfigurationAPI**: `parseBankProvider` → `mkBankProviderId (registry ids)`;
  `bankProviderText` → `unBankProviderId`; `addConnectionHandler` gains registry access; the
  connection DTOs carry the provider as a plain slug string; **add**
  `GET .../configuration/banking/providers` + `ProviderInfoDTO` (reads the registry).
- **Web.API.BankingAPI**: handlers read the resolved pull capability via the registry;
  `requireBankingEnabled` takes the registry.
- **package.yaml / backend.cabal**: per-provider Cabal flags + conditional modules/deps.
- **app/Main.hs (+ optional `app/Providers.hs`)**: registry assembly with localized CPP.
- **Domain.Core.Types**: **no change** (`bankName` stays `Maybe Text`).

## Module & layering placement

- `BankProviderId` → `Domain.Banking.Types` (pure; imports only `Domain.Core.Errors`).
- Descriptor/capabilities/registry → `Infrastructure.Banking.*` (may import Domain).
- Registry assembly + CPP → `app/` (composition root, layering-exempt).
- Providers-list API + `mkBankProviderId` boundary → `Web.API.ConfigurationAPI`
  (configuration/catalog surface); operational handlers → `Web.API.BankingAPI` (both may
  import any layer, incl. the registry).

No arrow is reversed: Domain never learns a concrete provider; Infrastructure holds
implementations; only `app/` enumerates them.

## Testing strategy

- **Property (primary)**: `mkBankProviderId` accepts exactly the ids in the supplied known
  set and rejects others; round-trips its text.
- **Unit**: `registryFromList`/lookup; config parsing of `Map BankProviderId ProviderSettings`
  incl. per-provider settings and the enabled flag; feature-gate truth table
  (master off, no providers, ≥1 available).
- **Unit**: sign-based `classify` default (negative → expense, non-negative → income).
- **Regression**: the existing Monobank pull path — `BankImportServiceSpec`,
  `MonobankSpec`, `BankImportWorkflowSpec`, `BankingAPISpec` — pass unchanged after the
  `classify`-seam refactor (the transport-neutrality proof).
- **Unit**: `GET .../configuration/banking/providers` returns the available set with correct
  capability flags.
- **Build**: verify `-fci` green for both the default (all-on) and a monobank-only
  (`-f-privatbank`, once Spec A exists) configuration.
- Reuse `test/Testkit/*` (`BankingHelpers.hs`, `InMemoryEventStore.hs`) rather than new
  ad-hoc fixtures.

## Deferred to Spec A (issue #38) — continuity notes

Spec A adds PrivatBank as the first `fileImport` provider. Foundation facts it will rely
on (confirmed against a real 102-row PrivatBank export):

- The neutral import core (§4) already handles PrivatBank rows unchanged: they are
  **sign-based** (negative = expense; `Зарахування`/positive = income → the shared
  `classify` default) and carry **no MCC**, so category resolution falls to the existing
  default-fallback path with `categoryHint` (the `Категорія` text column) riding through
  untouched.
- `externalId` synthesis (Spec A decision): composite `hash(time · amount · balance)` —
  the CSV's to-the-second timestamp and unique running balance make each row stable and
  re-import-safe.
- The CSV reports currency **alphabetically** ("UAH"); the parser maps it to the ISO
  numeric code the domain expects.
- No foundation change is anticipated — Spec A only fills the `fileImport` slot, adds a
  parser + upload transport, and (per §6) flips `supportsFile` to true.

## Risks & open questions

- **CPP in `app/`**: one localized site; acceptable, but keep it to registry assembly only.
- **Config migration**: existing deployments' `banking.providers.monobank` object must be
  re-read under the new `Map BankProviderId ProviderSettings` shape — trivial since the key is
  already `monobank`; confirm `config/*.yaml` samples are updated.
- **Providers-API gating**: returning provider names to any authenticated user is assumed
  acceptable; confirm no requirement to hide the provider catalog when banking is disabled.
- **Test suite is not build-flag-aware (deferred)**: the `monobank` Cabal flag cleanly
  excludes the provider from `lib:backend`/`exe:backend`, but the test suite
  (`Testkit/InMemoryEventStore`, `Testkit/BankingHelpers`, `MonobankSpec`) imports Monobank
  unconditionally, so a flag-off build is currently **build-verified for lib+exe only** — you
  cannot run `just test` against a monobank-off build. Acceptable while monobank is the sole
  provider; when a second provider lands (Spec A), gate those Testkit/spec references per
  provider (CPP or `package.yaml` `when: condition: flag(...)`) so each configuration is
  testable.
