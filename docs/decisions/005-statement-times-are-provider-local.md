# 005 - Statement wall-clock times are provider-local, converted at the parser boundary

## Status
Accepted

## Context

`Domain.Transaction` stores a transaction's business date as a `UTCTime`, and
every consumer — reporting day buckets, the reconciliation window, transfer
pairing, the books-closed cutoff — treats it as a real instant.

Bank providers disagree about what their timestamps mean. Monobank's API returns
POSIX seconds, which are unambiguous. A downloaded statement file carries a
formatted wall clock with no offset and no zone marker: PrivatBank writes Kyiv
local time in both the retail (`Історія операцій`) and business (Автоклієнт)
exports.

Both PrivatBank parsers read that wall clock straight into a `UTCTime` with no
conversion — `PrivatBank/Internal.hs:147`, and
`PrivatBankBusiness/Internal.hs`'s `combineDateTime`, whose haddock documents the
behaviour as intentional ("the statement times are already in the account's local
wall clock; no zone conversion is applied"). No timezone concept existed anywhere
in `src/`.

Every PrivatBank-imported transaction is therefore stored 2–3h late. Verified
against real statements: the files say `06.08.2026 11:09:20` and
`04.08.2026 14:02:50`, and the application shows those transactions at `14:09`
and `17:02`. Beyond the offset itself, a late-evening transaction lands on the
wrong calendar day, which silently misstates daily and monthly reports.

Ukraine observes EET/EEST, so a fixed offset is wrong for half of every year, and
a hand-rolled last-Sunday-of-March/October rule would go stale without warning if
the DST regime changes.

## Decision

1. **A statement file's wall clock is provider-local, and the provider's parser
   is responsible for converting it to UTC.** A parser that emits a `UTCTime`
   built from unconverted local text is a defect, not a deferred concern.

2. **Conversion uses the IANA database, not an offset or a hand-written rule.**
   `tz` + `tzdata` provide `tzByLabel`, which is pure, so `StatementParser` stays
   pure and no configuration surface is added. The shared helper
   `localToUtcIn :: TZLabel -> LocalTime -> UTCTime` lives in the flag-free
   `Infrastructure.Banking.Statement`, alongside the other format-neutral
   helpers.

3. **The zone is a property of the provider**, named once for that provider
   rather than spelled at each parser. PrivatBank's retail and business exports
   are parsed by two modules sitting behind two different Cabal flags, so the
   constant lives in the flag-free `Infrastructure.Banking.PrivatBankZone`
   (`privatBankZone`) and both parsers read it — a copied literal could
   silently disagree. Note the label spelling: `tz 0.1.3.6` predates the
   `Europe/Kyiv` rename, so the constructor is still `Europe__Kiev`, recorded
   in one place. Monobank needs no conversion and gets none.

4. **A provider's zone is not user-configurable.** PrivatBank is a Ukrainian bank
   issuing statements in Kyiv time; that is a fact about the format, not a user
   preference. A future provider in another market declares its own zone. Should
   a provider ever issue statements in the *account holder's* zone rather than
   its own, that is when a configuration surface earns its place.

5. **Synthesized external ids keep consuming the raw date text**, never the
   converted instant, so changing the conversion cannot shift an idempotency key
   (see [004](./004-synthesized-external-ids-are-pinned-idempotency-keys.md)).
   The golden test there pins this.

### Out of scope (deliberately not changed)

- **Correcting timestamps already stored.** Shifting them would rewrite posted
  financial facts across the whole history and needs its own actor/audit story.
  Existing PrivatBank transactions stay 2–3h late; new imports are correct.

## Consequences

- Imported PrivatBank transactions land on the right instant and the right
  calendar day, in both halves of the year.
- Two new dependencies. Verified by an isolated spike on GHC 9.10.3 under the
  project's pinned `index-state`: `tz-0.1.3.6` and `tzdata-0.2.20260708.0`
  compile, and DST resolves per date — `2026-08-06 11:09:20` local → `08:09:20Z`
  (+3, EEST) and `2026-01-15 11:09:20` local → `09:09:20Z` (+2, EET).
  `tzdata` embeds the Olson database, so it needs periodic bumping like any
  vendored data set.
- Adding a statement-file provider now carries an explicit question — *what zone
  is this file's clock in?* — rather than an implicit wrong answer.
- Stored history is inconsistent: PrivatBank transactions imported before this
  change remain 2–3h late, so a date range spanning the release mixes both.
