# 004 - Provider-synthesized external ids are pinned idempotency keys

## Status
Accepted

## Context

Bank-import deduplication keys on `ExternalTransactionId`: every imported
transaction records one row per external id in `imported_transactions` (unique on
the id), and `isImported` is the only thing standing between a re-synced
statement and a duplicate transaction.

Most providers hand us a bank-issued identifier. Monobank supplies the API's
`id`; the PrivatBank **business** export supplies `Референс`. Both are stable by
construction.

The PrivatBank **retail** export (Privat24 `Історія операцій`) has no reference
column, so `Infrastructure.Banking.PrivatBank.Internal.externalIdText`
*synthesizes* one from the row's date, card-currency amount, and running balance.

Commit `38968e9` (2026-08-17, PR #166, tracker#57) changed that derivation in
place, wrapping the amount and balance in `canonicalDecimal` so that a CSV and an
XLSX export of the same row would agree:

```diff
 externalIdText raw =
-  "privatbank:" <> raw.rawDate <> ":" <> raw.rawAmount <> ":" <> raw.rawBalance
+  "privatbank:" <> raw.rawDate <> ":" <> canonicalDecimal raw.rawAmount <> ":" <> canonicalDecimal raw.rawBalance
```

It achieved that goal. It also silently gave every already-imported row a second
identity. For one real row, the key was

```
privatbank:06.08.2026 11:09:20:-1221.17:-19593.46              before 2026-08-17
privatbank:06.08.2026 11:09:20:(-122117) % 100:(-979673) % 50   after
```

so `isImported` missed and the row imported a second time. That is the defect
reported as backend#3. Rows imported before 2026-08-17 and re-imported after it
duplicate; anything wholly on one side of that commit is unaffected, which is why
it presented intermittently.

Two real exports of overlapping periods (01.08–15.08 and 01.08–15.09) were keyed
under current code and diffed: 9/9 and 10/10 keys byte-identical, including a
double-conversion FX row whose amount might plausibly have been restated at
settlement. Per-row running balances reconcile across rows in both files.
**The statement data is stable and the chosen fields are sound; only our
interpretation of them moved.** The defect is version drift in a derivation, not
volatility in the source — which is why no amount of care in choosing *which
fields* to hash would have prevented it.

This is the same failure mode `CLAUDE.md` already bans for stored-event
`FromJSON`: compatibility that is invisible and unenforced, so a later
"simplification" deletes it with no compile error and no failing test, and it
detonates only in production against old rows.

## Decision

1. **A provider-synthesized external id is an idempotency key**, and its
   derivation is a stored-data contract — not an implementation detail of the
   parser that happens to produce it.

2. **The format has one owner.** `Infrastructure.Banking.ExternalId` holds both
   the construction and the repair of synthesized ids, so the two cannot drift
   apart. It is provider-aware but not provider-specific: the dedup projection
   must interpret historical PrivatBank ids regardless of runtime configuration.
   The module owns the format contract for all synthesized keys, making it the
   single source of truth for both generation and normalization.

3. **The derivation is pinned by a golden test.** Committed
   (statement row → exact id string) pairs live in the test suite. Changing the
   derivation fails that test. This is the enforcement `38968e9` lacked, and it
   is the substance of this ADR — the rest is consequence.

4. **A derivation that must change ships a normalizer**, applied where stored
   ids are read, never by rewriting the log. For this change,
   `normalizePrivatBankRetailId` re-canonicalizes the trailing amount and
   balance fields: identity for ids without the `privatbank:` prefix, and
   idempotent on already-canonical input (`canonicalDecimal` falls back to its
   argument for the `N % D` spelling, which `parseSignedDecimal` rejects).

5. **The dedup read model normalizes on apply**, so legacy ids project to the
   current key. Delivery is therefore one `REBUILD_READ_MODELS=bankimport`
   startup (`Application.ReadModels.Persist`): no event mutation, no event-store
   recreate, and correct again after any future rebuild.

A useful side effect of (4): because `canonicalDecimal` is value-based rather
than spelling-based, normalization also unifies the CSV/XLSX spellings that
motivated `38968e9` in the first place — a legacy `-149` and a current `-149.0`
both land on `(-149) % 1`. Pre-`38968e9` imports were CSV-only (XLSX support
arrived in that same commit), so this is exactly the population that needs it.

### Out of scope (deliberately not changed)

- **The derivation itself.** Date + amount + running balance is stable, and the
  balance genuinely disambiguates repeated same-amount rows — verified against
  real exports. It stays as is.
- **The duplicate transactions already created.** Removing them is a manual
  operation; this change stops new ones.

## Consequences

- Deduplication now survives a change to a synthesized derivation, and the
  normalizer is the documented seam for making one — mirroring upcast-on-read
  for stored event shapes.
- A recurrence is caught by a failing test at development time rather than by a
  user finding duplicates in production.
- Rebuild-safe: because normalization happens on apply rather than as a one-off
  table migration, replaying the log yields canonical keys.
- The normalizer prefix-matches `privatbank:`, which is stringly typed. Mitigated
  by tests asserting that Monobank ids and business `Референс` ids pass through
  unchanged.
- Only legacy spellings that `parseSignedDecimal` can parse are unified. A
  historical key whose numbers were NBSP-grouped or comma-decimal would stay
  un-normalized, and therefore un-deduplicated.
- One extra deployment step for this release, and a permanent one whenever a
  synthesized derivation changes.
