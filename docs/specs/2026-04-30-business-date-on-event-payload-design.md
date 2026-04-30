---
status: draft
---

# Business Date on Event Payload (Eventium 0.3.2 migration)

## Summary

Eventium 0.3.2 removed `occurredAt` from `EventMetadata` (the library now treats event metadata as store bookkeeping; domain semantics belong on the payload). Migrate this backend by adding an `at` field to the events and commands whose business model genuinely needs a business time, and remove all uses of `metadata.occurredAt` and `MetadataEnricher`-based occurredAt propagation. The database will be recreated; no on-disk compatibility shim is required.

## Motivation

- The eventium upgrade is a hard compile break (`EventMetadata` no longer has `occurredAt`).
- The current pattern (date threaded via metadata enrichers through the saga) was built around library behaviour that is gone. The replacement, per the library author, is putting business time on payload.
- Several read-paths already depend on a business date (transaction listing, exchange-rate lookups, balance-at-time potential): they must keep working without depending on metadata.

## Naming Convention

Use bare-preposition fields, matching the existing `by :: UserId` convention on domain events.

- Who acted: `by :: UserId` (unchanged)
- When (business time): `at :: UTCTime` for instants, `at :: Day` for day-grained events.

`by` and `at` together read as event narrative ("TransferInitiated **at** T **by** U"). Schema alternatives (`actor`/`date`, compound `transferredAt`/`publishedAt`) were rejected to minimise churn and preserve a uniform field name for grep.

## Scope

### Events that gain `at`

| Event | Type | Source of value |
|---|---|---|
| `Domain.ExchangeRate.Events.ExchangeRatesPublished` | `at :: Day` | `today = utctDay <$> getCurrentTime` in publisher |
| `Domain.Transaction.Events.TransferInitiated` | `at :: UTCTime` | User-supplied transfer date, falling back to `now`; bank-import path uses `tx.time` |
| `Domain.Account.Events.AccountDebited` | `at :: UTCTime` | Carried in via `DebitAccount` command from the saga |
| `Domain.Account.Events.AccountCredited` | `at :: UTCTime` | Carried in via `CreditAccount` command from the saga |

### Commands that gain `at`

| Command | Type |
|---|---|
| `Domain.Account.Commands.DebitAccount` | `at :: UTCTime` |
| `Domain.Account.Commands.CreditAccount` | `at :: UTCTime` |

### Events that do NOT gain `at`

- `TransferCompleted`, `TransferFailed` — saga follow-ups; transaction is dated by `TransferInitiated`. Filter via that.
- `TransactionLabelsSet`, `TransactionCategoryChanged` — user edits to existing transactions, not balance-affecting.
- `AccountCreated`, `AccountAccessGranted`, `AccountAccessRevoked`, `OverdraftLimitSet`, `AccountSubtypeSet`, `AccountCurrencyChanged` — config events; if history-at-time becomes a need, add then.
- All `User`, `Configuration` events — no business-time requirement today.

### Why `AccountDebited`/`AccountCredited` get `at` (and follow-ups don't)

Balance-at-time projections fold debit/credit events; they need the business date inline. Without it, every balance query joins on `transactionId → TransferInitiated.at`. The current saga propagates this date deliberately, and removing the capability would be a regression. `TransferCompleted`/`TransferFailed` carry no balance change, so a balance projection never needs their date.

## Producer Changes

### `Application.Services.ExchangeRatePublisher.publishRates`

- Already computes `today :: Day`.
- Set `at = today` in `ExchangeRatesPublished` payload.
- Remove the `metadataEnrichingEventStoreWriter` indirection if it now serves no purpose; otherwise call it with `id` (no enricher).

### `Application.Services.TransactionService.resolveAndInitiate`

- Replace `enricher` parameter threading with passing `transferDate :: UTCTime` directly into the `InitiateTransfer` command (and into `TransferInitiated.at`).
- `initiateTransfer`'s signature loses the `MetadataEnricher` parameter.
- All sibling helpers (`initiateInternalTransfer`, `initiateIncomeTransfer`, `initiateExpenseTransfer`, etc.) lose the enricher param.

### `Application.Services.BankImportService.commitImport`

- Set `at = tx.time` directly in the `InitiateTransfer` command.
- Drop the local `enricher` definition.

### Account command handlers (`Domain.Account.CommandHandler`)

- `DebitAccount` handler reads `cmd.at`, emits `AccountDebited { …, at = cmd.at }`.
- `CreditAccount` handler reads `cmd.at`, emits `AccountCredited { …, at = cmd.at }`.

## Consumer Changes

### `Application.ReadModels.ExchangeRate.processEvent`

- Read `published.at` (a `Day`) directly instead of `utctDay <$> innerMeta.occurredAt`.
- Drop the "skip when occurredAt missing" branch — projection becomes total.

### `Application.ReadModels.Transaction.processEvent`

- Read `evt.at` from `TransferInitiated` payload.
- Drop the `occurredAt → createdAt → epoch` triple-fallback. The field is required and present.

### `Application.ProcessManagers.TransferManager`

- `TransferData.occurredAt :: Maybe UTCTime` → `at :: UTCTime` (always present).
- `handleTransferEvent` reads `evt.at` from `TransferInitiated` payload, not `metadata.occurredAt`.
- `reactToTransferEvent` populates `DebitAccount.at` / `CreditAccount.at` from `TransferData.at` (no enricher).
- Delete `mkEnricher`, `setOccurredAt` helpers.
- All `IssueCommand` / `IssueCommandWithCompensation` use `id` as the metadata enricher.

### Haddock / inline docs

- Strip mentions of `EventMetadata.occurredAt` from `Domain.ExchangeRate.Events`, `Application.ReadModels.ExchangeRate`, `Application.ReadModels.Transaction`, `Application.Services.ExchangeRatePublisher`, `Application.ProcessManagers.TransferManager`. Replace with references to the payload `at` field.

## Test Changes

- `test/Application/ProcessManagers/TransferManagerSpec.hs`:
  - Drop the `occurredAt Propagation` describe block — saga no longer manipulates metadata.
  - Replace with assertions that `DebitAccount.at` / `CreditAccount.at` equal `TransferInitiated.at` (saga read-and-forward).
  - Remove `withOccurredAt` helper.
- `test/Application/ReadModels/ExchangeRateSpec.hs`:
  - Construct `ExchangeRatesPublished` with `at` field; metadata stays on default.
  - Drop the "skips events whose metadata has no occurredAt" test — unreachable.
- `test/Integration/ExchangeRatePersistenceSpec.hs`:
  - Assert `payload.at` round-trips, not `metadata.occurredAt`.
- `test/Application/Services/ExchangeRatePublisherSpec.hs`:
  - Assert `persisted.payload.at` is today's UTC day.
- `test/Application/ReadModels/TransactionListSpec.hs`, `TransactionListPropertySpec.hs`:
  - Build events with `at` in payload.
- `test/Application/Services/TransactionServiceSpec.hs`:
  - Drop metadata-based occurredAt setup; assert payload `at`.
- `test/Testkit/Generators.hs`, `test/Testkit/Helpers.hs`:
  - If event constructors are wrapped, generate `at` deterministically (e.g. fixed epoch) for property tests.

## Dependency / Build

- `package.yaml`: bump `eventium-core`, `eventium-postgresql`, `eventium-sql-common`, `eventium-memory` from `>= 0.3.1 && < 0.4.0` to `>= 0.3.2 && < 0.4.0`.
- Run `hpack` to regenerate `backend.cabal`.
- `flake.nix` references local eventium packages; ensure local checkout is on the 0.3.2 commit (`483052e`).

## Memory Update

The auto-memory entry `feedback_event_metadata.md` reads:

> No timestamp fields on domain events — event envelope metadata already has occurredAt; don't duplicate on payloads

Replace with the inverse rule: business dates live on event payloads (eventium 0.3.2 removed `occurredAt` from `EventMetadata`); only library-bookkeeping fields (correlationId, causationId, createdAt) remain on metadata.

## Out of Scope

- No backward-compatibility / migration of existing persisted events. The DB will be recreated.
- No date added to `TransferCompleted`, `TransferFailed`, audit/labels/category events.
- No new balance-at-time projection in this change — the data is preserved so a future projection can consume it without joins.
- No unrelated refactoring (TransferManager state machine, exchange-rate fallback logic, etc. left as-is).

## Verification

- `just build` succeeds with `-Werror` (no warnings, no `occurredAt` references left).
- `just test` passes — all spec/property/integration suites green.
- `just check` (ormolu + hlint) clean.
- Manual smoke: start postgres, run server, initiate a backdated transfer, assert it appears in the listing under the backdated `at` and that exchange-rate lookup uses the right day.
