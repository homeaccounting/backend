---
status: draft
---

# Rename AccountCategory/AccountType to AccountKind/AccountSubtype

## Summary

Rename `AccountCategory` → `AccountKind` and `AccountType` → `AccountSubtype` throughout the codebase. Rename all corresponding record fields (`accountCategory` → `kind`, `accountType` → `subtype`). Simplify JSON serialization by removing all backwards-compatibility aliases. This is a breaking change to both the API and stored event format.

## Motivation

"Category" and "Type" are near-synonyms that don't convey their hierarchical relationship. `AccountKind` (coarse behavioral classification) and `AccountSubtype` (finer classification within Regular) are more domain-accurate and self-documenting — "subtype" immediately signals it's a refinement of "kind."

## Changes

### Type Renames

| Before | After |
|--------|-------|
| `AccountCategory` | `AccountKind` |
| `AccountType` | `AccountSubtype` |

### Field Renames

All record fields across domain types, events, commands, projections, read models, and DTOs:

| Before | After |
|--------|-------|
| `accountCategory` | `kind` |
| `accountType` | `subtype` |

### JSON Serialization (breaking)

**`AccountKind`** — remove all legacy aliases (`"ExternalAccount"`, `"RegularAccount"`, `"Internal"`). Clean format only:

```json
"External"

{"tag": "Regular", "subtype": {"tag": "Cash", ...}}
```

**`AccountSubtype`** — standard `Generic` derived encoding (unchanged shape, just the type name changes).

### Affected Layers

- **Domain**: `Types.hs`, `Commands.hs`, `Events.hs`, `CommandHandler.hs`, `Projection.hs`, `Errors.hs`
- **Application**: `AccountService.hs`, `ReadModels/Account.hs`, `TransferManager.hs`
- **Web**: `Types.hs` (DTOs, conversion functions), `AccountAPI.hs`
- **Infrastructure**: `Json.hs` (if any custom instances)
- **Telegram**: `Commands.hs`
- **Tests**: all specs and testkit helpers
- **Docs**: update account-types-design.md to reflect new names

### Migration

This is a breaking change. Existing events in the event store that use the old field names (`accountCategory`, `accountType`) and old tag values (`"ExternalAccount"`, `"Internal"`, etc.) will not deserialize under the new format. A data migration or event versioning strategy is needed.

## Non-Goals

- No changes to business logic, validation, or behavior
- No changes to the set of account subtypes (Cash, BankAccount, EWallet, Asset, Loan)
- No changes to the AccountKind constructors (Regular, External)
