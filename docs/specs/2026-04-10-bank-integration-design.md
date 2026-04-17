---
status: in-progress
---

# Bank Integration Design

## Amendment 2026-04-16: Phase 1 scope reduction — resync-only

Following code review of PR #39, Phase 1 ships as **resync-only**. The webhook surface, the activation/linking flow, the `BankLinkState` read model, and the `BankAccountsLinked`/`BankAccountsUnlinked` events are removed from this iteration and deferred to Phase 2.

### What Phase 1 delivers
- `BankProvider` record-of-functions abstraction with a Monobank implementation.
- Manual `POST /api/banking/resync` endpoint (authenticated, gated behind `banking.enabled` + `monobank.enabled`) that fetches a user's Mono accounts, matches them to local Bank accounts by IBAN, pulls statements for a requested range, and imports transactions.
- Deduplication via `BankImportReadModel` (indexes `externalTransactionId` from `TransferInitiated` events) combined with a per-user import lock to close the in-process TOCTOU race between the dedup check and event persistence.
- `occurredAt` propagation from Mono's transaction timestamp through to `TransferInitiated`.
- Classification: Mono statements with `amount >= 0` import as `Income`, negative as `Expense`. MCC 4829 (wire transfers) maps to `Expense`; modeling it as a domain `Transfer` is not possible without a peer account and is out of scope.

### What is deferred to Phase 2
- Webhook ingestion endpoints, webhook secret derivation (`HMAC-SHA256(serverSecret, userId)`), payload signature verification, and webhook registration at link time.
- Activation / linking flow with `linkBankAccounts` / `unlinkBankAccounts` service operations emitting `BankAccountsLinked` / `BankAccountsUnlinked` events.
- `BankLinkState` read model and `findUserByWebhookSecret` lookup.
- `UserConfiguration.banking.*` — the per-user home for bank-integration settings. Phase 2 adds:
  - A per-user `enabled :: Bool` toggle so users can turn the integration on/off from their profile without an operator flipping server config. Phase 1 only has the deployment-level global kill switches (`banking.enabled`, `monobank.enabled`) for operator control; per-user opt-in is implicitly tied to presence of a token in the request body.
  - Persistent storage of the Mono token.
  - MCC → `DictionaryEntryId` category mapping.

  The Phase 1 resync endpoint therefore accepts the Mono token and a `defaultCategory` from the caller, via the dedicated `X-Banking-Token` header for the token (a separate header to avoid colliding with the JWT Bearer scheme on the same endpoint) and the JSON body for the default category.

### Phase 1 rationale
The webhook and linking subsystems are coupled to user-configuration work that is not yet complete. Shipping them as stubs was the largest review finding. Deleting that surface now keeps the codebase honest, removes the latent `Show BankingConfig` secret-leak risk, and simplifies the `AppEnv` wiring. Resync works without any persisted link state because `buildBankLink` recomputes the IBAN mapping on each invocation.

### Phase 1 additional fixes (in the same PR as the deletions)
- Move the Mono token out of the JSON request body and into a dedicated `X-Banking-Token` header on `/api/banking/resync` (a separate header to avoid colliding with the JWT Bearer scheme on the same endpoint).
- Gate the endpoint behind `banking.enabled` and `monobank.enabled`; respond `404` when either is disabled.
- Filter IBAN candidates to accounts where the caller has Owner or Editor role (Viewer is excluded).
- When multiple local accounts share an IBAN, pick the first deterministically and `logWarn` with the candidates.
- Cross-currency handling: Phase 1 always emits `exchangeRate = Nothing` on `TransferInitiated`. Monobank's statement API reports only the account currency and the `operationAmount` in the transaction's currency — not the foreign currency code itself. Without a foreign `Currency`, the `ExchangeRate` refinement type (which requires distinct source/target currencies) cannot be constructed. When `amount /= operationAmount`, the adapter still derives and logs the ratio `|originalAmount| / |amount|` at `INFO` level for diagnostic visibility, but the value is not persisted. Capturing exchange rates — including user-configured foreign currency mappings and `ExchangeRate` reconstruction — is deferred to Phase 2.
- Move minor-unit scaling (`/ 100`) from the Application layer into the Monobank adapter so `ProviderTransaction.amount` is already in major units.
- Serialize imports per user via an in-process per-user lock to close the dedup race between `isImported` and the `TransferInitiated` emit.
- Change `resync` to return a structured per-account result rather than aborting on the first failure; the handler returns 200 with the structured breakdown.
- Add a smart constructor and LiquidHaskell refinement for `ExternalTransactionId` (non-empty `Text`).
- Tests: dedup idempotency property, `buildBankLink` IBAN matching (single/multi/none/Viewer-filtered), cross-currency same/different branches, Mono JSON parsing fixtures (incl. `mcc = 0` and unknown `currencyCode`), `TransferInitiated` JSON backwards-compat with and without `externalTransactionId`.

### Config surface changes in Phase 1
- `server.api_base_url` is retained (used by Telegram webhook URL derivation per the original spec).
- `banking.webhook_secret` is removed.
- `monobank.api_base_url` becomes injectable via config (defaults to `https://api.monobank.ua`) so integration tests and staging environments can point at a mock.

### Layering invariant for Phase 1

`Infrastructure/Banking/` must not import from `Application/` or `Web/`. Its only permitted dependencies are `Domain/`, `RIO`, and external libraries. This mirrors the existing `Infrastructure/ExchangeRate/` pattern, where the provider record-of-functions lives in Infrastructure and is consumed directly by Application services. Verified at commit time via a grep assertion in the plan's verification step.

The sections below describe the full intended design including Phase 2 components; where a section is marked as Phase 2 above, treat it as the target end-state that Phase 1 does not yet implement.

## Overview

Bank integration provides automatic transaction import from external banks, starting with Monobank. It is an **import mechanism** — not a business domain — living in infrastructure/application layers. The architecture is pluggable via a record-of-functions pattern (like `RateProvider`), making it straightforward to add new bank providers (PrivatBank, etc.) in the future.

Integration is opt-in: disabled by default, activated per-user via configuration (token entry).

## Decisions

- **Direction**: determined by the sign of `amount` field (positive → Income, negative → Expense)
- **Transaction classification**: delegated to `BankProvider.classifyTransaction` — each provider implements its own logic (Monobank uses MCC codes, other providers may use category names or other signals)
- **Category mapping**: configurable per-provider category mapping in user configuration (`category_mappings` with provider-interpreted keys), with a fallback default category
- **Account matching**: auto-match by `accountNumber` between Mono accounts (IBAN) and app's Bank subtype accounts (`accountNumber` field in `BankAccountProperties`). Users must enter their IBAN in the `accountNumber` field for matching to work.
- **Deduplication**: external transaction ID stored on domain event + indexed in a dedicated read model for fast lookup
- **Sync strategy**: webhook-primary, polling via statement API for manual resync only
- **Historical backfill**: none on link — capture starts from the moment of webhook registration
- **Unmatched accounts**: log warning, discard — user can resync after creating a matching Bank account
- **Hold transactions**: skipped — only finalized transactions are imported
- **Card-to-card beyond MCC 4829**: deferred to a future iteration
- **Scheduled polling fallback**: deferred to a future iteration

## Prerequisites

- **`occurredAt` on Event Metadata**: Eventium 0.2.2 adds `occurredAt :: Maybe UTCTime` to `EventMetadata`, providing a business date separate from the persistence timestamp. Transaction flow support for `occurredAt` will be implemented in a separate PR. This feature assumes both are in place — bank-imported transfers set `occurredAt` to Mono's transaction timestamp.

## Domain Changes

### ISO 4217 Numeric Currency Codes (Domain Core)

Add standard numeric code functions to `Currency` in `Domain/Core/Types.hs`:

```haskell
currencyNumericCode :: Currency -> Int
currencyNumericCode UAH = 980
currencyNumericCode USD = 840
currencyNumericCode EUR = 978
currencyNumericCode GBP = 826

currencyFromNumericCode :: Int -> Either Text Currency
currencyFromNumericCode 980 = Right UAH
currencyFromNumericCode 840 = Right USD
currencyFromNumericCode 978 = Right EUR
currencyFromNumericCode 826 = Right GBP
currencyFromNumericCode code = Left $ "Unsupported currency code: " <> tshow code
```

Pure domain functions. Bank adapters call `currencyFromNumericCode`; transactions with unsupported currency codes are skipped with a warning.

### `externalTransactionId` on Transfer Events

Add an optional external transaction ID to `InitiateTransfer` command and `TransferInitiated` event:

```haskell
-- | Identifier for a transaction in an external system (e.g., Monobank).
type ExternalTransactionId = Text

-- In InitiateTransfer command:
externalTransactionId :: Maybe ExternalTransactionId

-- In TransferInitiated event:
externalTransactionId :: Maybe ExternalTransactionId
```

`Nothing` for user-initiated transfers, `Just "mono_tx_abc123"` for bank-imported ones. This is the deduplication key — the `BankImportReadModel` indexes these to prevent duplicate imports. The field is `Maybe` so existing event deserialization remains backwards compatible (defaults to `Nothing`).

When issuing bank-imported transfers, set `correlationId` in `EventMetadata` to the external transaction ID as well, enabling end-to-end tracing from webhook to saga completion.

### Bank Link Lifecycle Events

New events for tracking bank link state (emitted as part of the accounting event stream):

```haskell
data BankAccountsLinked = BankAccountsLinked
  { userId :: UserId
  , bankName :: Text              -- "monobank"
  , accountMappings :: [AccountMappingData]
  , webhookSecret :: Text
  }

data AccountMappingData = AccountMappingData
  { externalAccountId :: Text
  , accountNumber :: Text           -- IBAN from bank provider
  , accountId :: AccountId
  }

data BankAccountsUnlinked = BankAccountsUnlinked
  { userId :: UserId
  , bankName :: Text
  }
```

These are **application-level events** emitted by `BankImportService` (not tied to any domain aggregate). They exist for operational state reconstruction, not business logic. They enable the `BankLinkState` read model to be rebuilt from the event stream on startup, without calling external APIs.

## Configuration

### App-Level Config

Add `api_base_url` to server config (shared across Telegram webhooks, banking webhooks, etc.):

```yaml
server:
  host: "127.0.0.1"
  port: 8080
  api_base_url: "${API_BASE_URL:-http://localhost:8080}"

banking:
  enabled: true
  providers:
    monobank:
      enabled: true
```

Telegram's `webhook_url` becomes optional override — if `null`, falls back to `{api_base_url}/api/telegram/webhook`. Backwards compatible.

### User-Level Config

Per-user opt-in via the existing `UserConfiguration` system:

- `banking.enabled :: Bool` — opt-in toggle (default: `false`)
- `banking.monobank.token :: Maybe Text` — personal API token
- `banking.monobank.category_mappings :: Map Text DictionaryEntryId` — provider-interpreted category mapping (Monobank uses MCC codes as keys, other providers may use category names)
- `banking.monobank.default_category :: DictionaryEntryId` — fallback when no mapping matches

## Provider Abstraction

### `Infrastructure/Banking/Provider.hs`

Record-of-functions pattern, same as `RateProvider`:

```haskell
-- | Identifier for an external bank account (provider-specific).
type BankAccountId = Text

data BankProvider = BankProvider
  { providerName :: !Text
  , fetchAccounts :: IO (Either Text [BankAccount])
  , fetchStatements :: BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction])
  , registerWebhook :: Text -> IO (Either Text ())
  , classifyTransaction :: BankTransaction -> TransactionClassification
  }

-- | Provider-contributed classification hint. The BankImportService owns the
-- final decision but uses this as a starting point.
data TransactionClassification
  = ClassifiedExpense !(Maybe DictionaryEntryId)  -- suggested category
  | ClassifiedIncome  !(Maybe DictionaryEntryId)
  | ClassifiedTransfer

data BankAccount = BankAccount
  { externalId :: !BankAccountId  -- provider's account ID
  , accountNumber :: !Text        -- IBAN from bank provider
  , currencyCode :: !Int          -- ISO 4217 numeric
  , cardMasks :: ![Text]
  , balance :: !Int64             -- in minor units
  }

data BankTransaction = BankTransaction
  { externalId :: !ExternalTransactionId  -- provider's transaction ID (dedup key)
  , accountId :: !BankAccountId   -- provider's account ID
  , time :: !UTCTime
  , amount :: !Int64              -- signed, minor units (account currency)
  , currencyCode :: !Int          -- ISO 4217 numeric
  , description :: !Text
  , hold :: !Bool
  -- Provider-dependent fields (not all banks expose these):
  , mcc :: !(Maybe Int32)         -- MCC code (card transactions); Nothing if provider doesn't expose it
  , originalAmount :: !(Maybe Int64)  -- original currency amount if different from account currency
  , notes :: !(Maybe Text)        -- user comments if provider separates them from description
  , categoryHint :: !(Maybe Text) -- provider's own categorization (e.g., PrivatBank category name)
  }
```

**Lifecycle**: Unlike `RateProvider` (a long-lived singleton in `AppEnv`), `BankProvider` is **ephemeral** — constructed per-request from the user's token via `mkMonobankProvider`. It is NOT stored in `AppEnv`. The `BankImportService` creates it on demand when processing a webhook or resync request.

### `Infrastructure/Banking/Monobank.hs`

Constructs a `BankProvider` from a token:

```haskell
mkMonobankProvider :: Text -> Manager -> BankProvider
```

Calls Mono REST API:

- `GET /personal/client-info` — fetch accounts (rate limit: once per 60s)
- `GET /personal/statement/{account}/{from}/{to}` — fetch statements (max 31 days)
- `POST /personal/webhook` — register webhook URL

Authentication via `X-Token` header. Amounts in kopiykas (1/100) converted to `Rational` by the adapter (`toRational amount / 100`). Currency codes converted via `currencyFromNumericCode`.

**Monobank `classifyTransaction`** implements MCC-based classification:

- MCC 4829 → `ClassifiedTransfer`
- MCC present + negative amount → `ClassifiedExpense` with category looked up from user's `category_mappings` by MCC code
- MCC present + positive amount → `ClassifiedIncome` with category from mappings
- MCC absent or 0 → `ClassifiedExpense`/`ClassifiedIncome` (by amount sign) with `Nothing` category (falls back to default)

### Monobank Webhook Contract

- **Validation**: Mono sends `GET` to webhook URL on registration; must respond HTTP 200
- **Events**: Mono sends `POST` with payload `{type: "StatementItem", data: {account: "...", statementItem: {..}}}`
- **Timeout**: 5-second response window required
- **Retry**: 60s, then 600s after initial failure
- **Deactivation**: after 3 failed attempts, webhook is disabled

## Bank Import Service

### `Application/Services/BankImportService.hs`

Orchestration layer — receives data from webhook or resync, produces `InitiateTransfer` commands.

**Webhook flow:**

1. Parse webhook payload via `BankProvider`
2. Look up user by webhook route (userId + webhookSecret from URL)
3. Validate webhookSecret against stored secret in `BankLinkState`
4. Check user config: banking enabled + token present
5. Skip if `hold == True` (only import finalized transactions)
6. Check dedup read model: has this `externalTransactionId` been imported?
7. Match `BankTransaction.accountId` to a local `AccountId` via `accountNumber` mapping in `BankLinkState`
8. If no match → log warning, discard
9. Look up user's External account from account read model (created on registration)
10. Convert currency via `currencyFromNumericCode`; skip with warning if unsupported
11. Convert amount from minor units to `Rational` (`toRational amount / 100`)
12. Classify via `BankProvider.classifyTransaction`:
    - `ClassifiedTransfer` → `Transfer` (if counterparty not mapped, fall back to Income/Expense)
    - `ClassifiedIncome category` → `Income` (source = External account, target = matched bank account, use suggested category or default)
    - `ClassifiedExpense category` → `Expense` (source = matched bank account, target = External account, use suggested category or default)
    - Direction (Income vs Expense) is confirmed by the sign of `amount` (positive → Income, negative → Expense)
13. Issue `InitiateTransfer` command with:
    - `occurredAt` set to Mono's transaction timestamp (on event metadata)
    - `externalTransactionId` set to Mono's transaction ID
    - Note: `correlationId` is NOT set — external transaction IDs (e.g., Monobank's opaque strings) are not UUIDs. Tracing uses `externalTransactionId` on the event instead.

**Resync flow** (`POST /api/banking/resync`):

Accepts `{ "from": "2026-04-01T00:00:00Z", "to": "2026-04-14T00:00:00Z" }` — UTC timestamps, max 31-day span.

1. Fetch statements via `BankProvider.fetchStatements` for the requested period
2. Run each through the same pipeline (steps 5–13), skipping already-imported ones

This is the primary flow for testing — no webhook infrastructure needed, just a token and a resync call.

### ClassifiedTransfer Handling

For `ClassifiedTransfer`, both source and target must be known accounts. If the counterparty account isn't mapped in our system, fall back to Income/Expense with the user's External account as counterparty. Each provider decides what constitutes a transfer (Monobank uses MCC 4829; other providers may use different signals).

## Read Models

### Bank Import Dedup — `Application/ReadModels/BankImportReadModel.hs`

Deduplication index, rebuilt from events on startup:

```haskell
data BankImportReadModel = BankImportReadModel
  { importedTransactions :: !(Map ExternalTransactionId TransactionId)
  }
```

Built from `TransferInitiated` events where `externalTransactionId` is `Just`. Fully rebuildable from the event stream.

### Bank Link State — `Application/ReadModels/BankLinkState.hs`

Operational state for active bank links, rebuilt from user configuration events:

```haskell
data BankLinkState = BankLinkState
  { activeLinks :: !(Map UserId UserBankLink)
  }

data UserBankLink = UserBankLink
  { webhookSecret :: !Text
  , accountMappings :: ![AccountMapping]
  , bankName :: !Text              -- "monobank"
  }

data AccountMapping = AccountMapping
  { externalAccountId :: !BankAccountId
  , accountNumber :: !Text        -- IBAN from bank provider
  , accountId :: !AccountId
  }
```

Rebuilt from events on startup. During the linking flow, a `BankAccountsLinked` event is emitted (as part of the accounting event stream) capturing the userId, bank name, account mappings, and webhook secret. On unlinking, a `BankAccountsUnlinked` event is emitted. This ensures `BankLinkState` is fully rebuildable from the event stream without calling external APIs on restart.

The `webhookSecret` is derived deterministically via HMAC-SHA256(serverSecret, userId), base64url-encoded, truncated to 32 characters. This makes it reproducible without storing additional state.

## Error Handling

Banking errors use the existing `DomainError` union (following the pattern of `AccountError Text`, `ConfigurationError Text`, etc.):

```haskell
| BankingError Text
```

Specific error messages conveyed via the `Text` payload:

- Invalid token — token validation failed against provider
- Webhook registration failed — provider rejected webhook registration
- Unsupported currency — transaction currency not supported (logged, skipped)
- Account not matched — no local account matches the external `accountNumber` (logged, skipped)
- Resync failed — statement fetch failed
- Invalid webhook secret — webhook request with wrong secret (rejected)

Non-fatal errors (unsupported currency, unmatched account) are logged and the transaction is skipped — they do not raise `BankingError`. Fatal errors (invalid token, webhook registration failure) are surfaced to the user via `BankingError`.

## Web Layer

### `Web/API/BankingAPI.hs`

**Webhook endpoints** (unauthenticated — called by Mono):

- `GET /api/banking/webhook/{userId}/{webhookSecret}` — Mono validation, returns 200
- `POST /api/banking/webhook/{userId}/{webhookSecret}` — receives statement events

**Webhook security**: a `webhookSecret` is derived deterministically per user (from userId + server-side secret in app config). The secret is part of the URL path — webhook URLs should never be logged. Future hardening (not in v1): rate limiting per userId, IP allowlisting if Mono publishes source IPs, secret rotation.

**Authenticated endpoints:**

- `POST /api/banking/resync` — triggers manual resync, accepts `{ "from": "...", "to": "..." }` (UTC timestamps, max 31-day span)

## Activation Flow

### Linking (on user config save with token)

1. Validate token by calling `GET /personal/client-info`
2. If valid — extract Mono accounts with their account numbers (IBANs)
3. Match against user's Bank accounts by `accountNumber` (`BankAccountProperties.accountNumber`)
4. Derive `webhookSecret` for the user (HMAC-SHA256 of userId with server secret)
5. Emit `BankAccountsLinked` event (captures mappings + webhook secret)
6. Register webhook: `POST /personal/webhook` with URL `{api_base_url}/api/banking/webhook/{userId}/{webhookSecret}`
7. Mono validates via GET → respond 200
8. Active — webhook events start flowing

### Unlinking (token removed from config)

1. Call `registerWebhook ""` to actively deregister the webhook with Mono
2. Emit `BankAccountsUnlinked` event

### Error Cases

- Invalid token → config save fails with `BankingError "Invalid token"` error
- No `accountNumber` matches → link succeeds but logs warning, no imports until user creates a matching Bank account
- Webhook registration fails → log error, user can retry via resync endpoint

### Account Changes After Linking

- User creates a new Bank account with matching `accountNumber` → picked up on next resync or `BankLinkState` refresh
- User deletes a Bank account → unmatched, future webhook events for that IBAN logged and discarded

## Infrastructure Wiring

### AppEnv Changes

- Add banking config fields to `AppEnv`
- Add `HasBankingConfig` capability type class
- Add `BankImportReadModel` (TVar) and `BankLinkState` (TVar) to `AppEnv`
- Add `HasBankImportReadModel` and `HasBankLinkState` capability type classes
- Add shared `Manager` (http-client) to `AppEnv` with `HasHttpManager` capability — passed to `mkMonobankProvider` on each request
- Initialize on startup: load config, create read models, rebuild from events

### Config Changes

- `Infrastructure/Config.hs` — parse `api_base_url` in server config, `banking` section, add `bankingWebhookSecret` server-side secret
- Telegram webhook URL derivation from `api_base_url` (with override support)

## File Structure

```
src/Infrastructure/Banking/
  Provider.hs           -- BankProvider record-of-functions, BankAccount, BankTransaction, BankAccountId
  Monobank.hs           -- Mono API client, mkMonobankProvider

src/Application/Services/
  BankImportService.hs  -- orchestration (webhook handling, resync, matching, MCC mapping, dedup)

src/Application/ReadModels/
  BankImportReadModel.hs  -- dedup index (external tx ID → internal tx ID)
  BankLinkState.hs        -- active bank links, account mappings, webhook secrets

src/Web/API/
  BankingAPI.hs         -- webhook + resync endpoints

src/Domain/Core/
  Types.hs              -- currencyNumericCode, currencyFromNumericCode (additions)
```

## Not In Scope

- Historical backfill on link
- Scheduled polling fallback
- PrivatBank or other providers (architecture supports them)
- Card-to-card detection beyond MCC 4829
- UI for bank integration management
- Webhook rate limiting and IP allowlisting (future hardening)
- Historical exchange rate snapshots (needed for backdated cross-currency transfers; separate PR)
