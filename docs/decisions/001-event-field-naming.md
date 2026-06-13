# 001 - Event field naming convention

## Status
Accepted

## Context
Field names on domain events, commands, and saga state had drifted into three
overlapping conventions for the same two recurring roles:

- **Actor** (who caused the fact): most Account events and `TransactionPostingInitiated`
  use a bare `by :: UserId`, but the Transaction amendment/cancellation flow uses
  verb-prefixed `amendedBy` / `cancelledBy`, and `ConfigurationCreated` uses
  `createdBy :: CreatedBy`.
- **Business time** (when the fact is effective): bare `at` in most places,
  `newAt` on `TransactionDateChanged`, and the domain-value field `closedThrough`
  on `BooksClosedThroughSet`.

The verb-prefixed actor names are redundant with the event/command type name,
which already carries the verb, and the inconsistency makes it harder to handle
"the actor" generically across events.

The event payload (not envelope metadata) is the deliberate home for these facts:
the `MetadataEnricher` envelope is currently a no-op (`id` is passed at every call
site), so actor and business time live in the payload as first-class domain facts.

## Decision
Establish the following naming rules for domain events, commands, and saga state.

1. **Actor → bare `by :: UserId`.** The single user who caused the event/command.
   The type name already carries the verb, so the field never repeats it.
   Renames `amendedBy` / `cancelledBy` → `by`.
2. **Provenance richer than a `UserId` keeps a domain name + domain type.**
   `ConfigurationCreated.createdBy :: CreatedBy` stays — it models
   `System | ClonedBy UserId ConfigurationId`, not a plain actor. Bare `by` is
   reserved for the case where the answer is exactly one `UserId`.
3. **Business time → `at`** (the instant/date the fact is effective, not the
   recording time). Unchanged.
4. **`*Changed` amendment events keep the `new<Field>` family** (`newAt`,
   `newName`, `newDescription`, `newAllocations`). The `new` prefix carries real
   meaning (the post-change value), unlike a redundant verb prefix.
5. **Domain-value dates that are the event's subject keep semantic names.**
   `BooksClosedThroughSet.closedThrough` stays — it is the cutoff value being set,
   not "when this happened."

### Out of scope (deliberately not changed)
- The `at :: Day` (ExchangeRate) vs `at :: UTCTime` (elsewhere) type split is
  intentional: rates are per-day, transactions per-instant.
- Actor-coverage gaps (most Configuration events and all User events carry no
  actor) are an audit-trail question, not a naming one.

## Consequences
- The actor field is uniform (`by :: UserId`) across Account and Transaction
  events, commands, and saga state; generic audit/projection handling is simpler.
- Event JSON keys change (`amendedBy`/`cancelledBy` → `by`). Acceptable: the
  project is pre-release with no backward-compatibility obligation for stored
  events or DTOs.
- New events/commands now have an unambiguous rule to follow for the actor and
  business-time roles.
