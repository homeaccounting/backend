---
status: draft
title: Backend localization — Telegram output + localized starter dictionaries
epic: tracker#56 (Localization), Slice C
supersedes: none
---

# Backend Localization Design

## Context

Epic **tracker#56** (Localization) renders the app in the user's **language** and
regional conventions across the web client and backend-generated output. The
work sits on a **shared country/language signal foundation** already merged in
`backend#164`:

- `Domain.Localization.Language` — closed sum `En | Uk`, ISO-639-1 wire codes
  (`en`/`uk`), persisted as part of the user's Configuration.
- `PUT /api/users/me/configuration/language` (supported-locale validated),
  `language` in `ConfigurationResponse`, and the supported-languages list — all
  landed.

The **web** client landed **Slices A + B** in `homeaccounting/web` PR #94:
the i18n runtime and country-driven date/number/currency formatting. That PR
explicitly leaves **Slice C — locale-aware backend-generated output** to the
backend.

This document specifies the **backend side of tracker#56 = Slice C**.

### What "backend-generated output" is in this codebase

There is **no email subsystem** (verified: no mail/notification module exists).
The only backend-generated, user-facing output is the **Telegram bot**. So
Slice C on the backend is **Telegram output localization**.

Separately, this design addresses a gap the epic files under region-appropriate
**starter-content seeding**: the default category dictionaries seeded to users
are English-only. Because the language signal now exists server-side, we can seed
them in the user's locale. This is included here as **Slice B** (naming reused
locally; unrelated to web PR #94's "Slice B").

## Goals

1. **Slice A** — every user-facing string the Telegram bot emits is rendered in
   the user's persisted UI language (`en`/`uk`), English as fallback, extensible
   to new locales by adding one catalog + one registry entry.
2. **Slice B** — a user's **untouched default categories** render in their
   **current locale**; anything the user creates or renames is shown **verbatim
   forever** (translate-until-touched semantics).

## Non-goals

- Localizing **stored user content** (custom category/label/contact names,
  transaction descriptions) — always shown verbatim. Slice B touches *only*
  app-authored default entries the user has not edited.
- Locale-aware **numeric/date formatting** in Telegram output (see §A.5 — kept as
  today's international default; a bounded, optional follow-up).
- Any **stored-event shape change**, upcaster, or event-store DB recreate — this
  entire design is additive at the storage layer.
- A new HTTP onboarding endpoint (see §B.3 — `changeCountry`/`changeLanguage` are
  the existing seams; web PR #93 requires no backend change).

---

## Localization foundation (shared, area-agnostic)

The translation catalog is **not** Telegram-specific. It is a reusable
localization foundation under the existing `Domain.Localization` namespace, and
Telegram is merely its **first *area***. Slice B's default-category names are a
**second area**, and future backend-generated surfaces (emails if they ever
exist, natural-language prompt replies, scheduled-report text, …) become
additional areas by the same recipe — with **no change to existing areas**.

### F.1 Two catalog shapes, one foundation

Two translation shapes cover every area; both hang off the single `Language`
signal and a single English-fallback rule:

1. **Closed message catalogs** (fixed, app-authored set of messages — e.g. the
   Telegram bot copy). Modeled as a **record-per-language** whose fields are the
   messages (function-typed where they interpolate). Totality is
   compiler-enforced: an omitted field is `-Wmissing-fields`, an error under the
   `-fci`/`-Werror` gate — so a locale is provably complete, no missing keys.
2. **Open key→text catalogs** (dynamic or data-driven keyset — e.g. default
   category names keyed by canonical name). Modeled as per-locale override tables
   over a **total English base**, resolved with fallback.

### F.2 The reusable primitive

`Domain.Localization` gains one small, area-agnostic module —
**`Domain.Localization.Catalog`** — providing the fallback resolver every
key-based area reuses, and documenting the record-per-language convention for
closed catalogs. It contains **no area content** (so `Domain.Localization` never
depends on Telegram/Web — layering preserved):

```haskell
-- Domain.Localization.Catalog

-- | Resolve a key with English fallback: a per-locale override table layered
--   over a total English base that can never fail. The one piece of logic every
--   key-based area catalog shares, factored out so no area reimplements it.
resolve
  :: (Language -> k -> Maybe Text)  -- ^ per-locale overrides (uk, …); En may be empty
  -> (k -> Text)                    -- ^ total English base (identity/base names)
  -> Language -> k -> Text
resolve overrides base lang k = fromMaybe (base k) (overrides lang k)
```

Closed (record) catalogs don't need `resolve` — the record *is* total per locale;
the shared rule there is the `catalog :: Language -> <Record>` dispatch
convention and the `-Werror` completeness guarantee.

### F.3 Where each area lives (layering)

| Area | Shape | Module | Layer |
|------|-------|--------|-------|
| Telegram bot output (Slice A) | closed record | `Telegram.I18n` | Telegram adapter (imports Domain) |
| Default category names (Slice B) | open key→text | `Domain.Localization.CategoryCatalog` | Domain (app-authored reference data) |
| *future: emails, NL replies, …* | either | *its own module* | its own layer |

Each area owns its catalog in the layer that owns the surface; all share
`Domain.Localization.{Language, Catalog}`. This is the concrete meaning of
"extensible with other areas": **adding an area = one new catalog module using
the foundation; adding a locale = extend `Language`, then fill each area's
per-language value (the compiler enumerates exactly what's missing).**

### F.4 Purity & layering — translation is not IO

The catalogs are **static values compiled into the binary** (a `TelegramStrings`
record per locale; `Map Text Text` override tables), exactly like web PR #94's
statically-imported catalogs. `resolve`, `telegramStrings`, and `localizedCategoryName`
are **total, pure** `… -> Text` functions — no file, DB, or network access. So:

- `Domain.Localization.Catalog` belongs in **Domain because it is pure** and
  imports only `Text`/`Map`/`Maybe` over the `Language` value type that already
  lives there. It is *not* an external-world adapter, so Infrastructure would be
  the wrong layer (it would imply an effect that does not exist).
- The **only IO** is resolving the user's language *signal* (`getConfiguration`
  reading persisted `language`), which already lives in the Application/Telegram
  layers — on the correct side of the boundary. The catalog receives a `Language`
  and returns `Text`.
- **Compile-time completeness is the reason to keep it static** (see §A.2): a
  missing message is a build error under `-fci`/`-Werror`. Runtime-loaded catalogs
  (external `.po`/JSON/DB, an IO/Infrastructure concern) would trade that
  guarantee for translator-editable-without-deploy — explicitly **not** chosen for
  `en`/`uk` in a typed, `-Werror` codebase that mirrors web's compiled approach.

### F.5 Naming standard (applies to every area)

So catalogs read consistently across areas (no per-area invention — the top-level
Telegram type is `TelegramStrings`, **not** `BotStrings`):

- **Closed message catalog** (fixed, app-authored message set for area *X*):
  - Type: **`<Area>Strings`** — e.g. `TelegramStrings` (later `EmailStrings`).
  - Per-locale dispatch: **`<area>Strings :: Language -> <Area>Strings`** — e.g.
    `telegramStrings`.
  - Feature sub-records inside stay module-scoped: `CommonStrings`,
    `AccountStrings`, … (concrete record types, so `OverloadedRecordDot` resolves
    dot-access even where field names repeat across sub-records).
  - Module: **`<Area>.I18n`** — e.g. `Telegram.I18n`.
- **Open key→text catalog** (data-driven keyset):
  - Function: **`localized<Noun> :: Language -> <Key> -> Text`** — e.g.
    `localizedCategoryName` — built on `resolve`.
  - Module: **`Domain.Localization.<Noun>Catalog`** — e.g.
    `Domain.Localization.CategoryCatalog`.

Mnemonic: **`…Strings`** is a bundle of fixed messages; **`localized…`** is a
function that localizes a value. Every new area picks one of the two shapes and
follows the corresponding names.

**Locale-file layout.** The JSON catalogs (see §A.2 / §B.5 — embedded at compile
time via `Data.Embed`) live under `locales/<area>/<locale>/<namespace>.json`, so
every area is labelled and uniform: `locales/telegram/{en,uk}/{common,accounts,…}.json`
and `locales/categories/{en,uk}/default.json` (a single-namespace area).
Adding an area = a new `locales/<area>/…` tree; adding a locale = a new
`<locale>/` dir under each area.

### F.6 Pluralization

Count-bearing messages need per-locale grammar: English has two plural forms
(`one`/`other`), Ukrainian has three for integers (`one`/`few`/`many` — e.g.
1 транзакція / 2 транзакції / 5 транзакцій), so a flat `{count}` substitution is
grammatically wrong for `uk` the moment a noun follows the count.

`Domain.Localization.Plural` provides this — dependency-free, no i18n library:

- `pluralCategory :: Language -> Int -> PluralCategory` — the CLDR plural category
  for a count (English: `one` iff 1; Ukrainian: the `one`/`few`/`many` integer
  rules).
- `selectPluralTemplate :: Language -> Int -> Map Text Text -> Text -> Maybe Text`
  — resolves the template from a catalog namespace map using **the same
  `<key>_<category>` suffix convention i18next uses** (`foo_one`, `foo_few`,
  `foo_many`, `foo_other`), falling back to `foo_other` then the bare `foo`. So a
  pluralized string is authored in the locale JSON exactly as on the web, and the
  chosen template is then interpolated (`{count}`) as usual.

**Current state:** no shipped string needs plural agreement — the count-bearing
ones avoid it (`"… and {count} more."` has no trailing noun; `"(last 30 days)"`
is a fixed literal). The helper exists so the **first** count-and-noun string is
authored correctly (add `_one/_few/_many/_other` keys + call
`selectPluralTemplate`) rather than with a broken flat template.

**Out of scope (documented gap):** locale-aware **number/date/currency
formatting** for interpolated values (see §A.5) and CLDR plural rules for locales
beyond `en`/`uk` — add a `pluralCategory` clause per new locale. A heavier
`text-icu` (ICU MessageFormat) dependency would cover both generically, but is not
warranted for the current bounded surface.

---

## Slice A — Telegram output localization (first area)

### A.1 Language resolution and threading

The user's language is already reachable inside Telegram handlers: handlers look
up the user (`getUserByTelegramId`) and their `ConfigurationData`
(`getConfiguration`), which now carries `language :: Language`.

**Resolution point.** Resolve the language **once per update**, at the top of
each handler entry (`handleCommand` / `handleMessage` / `handleCallbackQuery` in
`Telegram.Commands`), via a small helper:

```haskell
-- Telegram.Commands
languageForTelegram :: TelegramId -> AppM Language
languageForTelegram telegramId = do
  maybeUser <- runDb (getUserByTelegramId telegramId)
  case maybeUser of
    Nothing -> pure En                       -- pre-signup / unknown → English
    Just (_, userData) -> do
      maybeConfig <- runDb (getConfiguration userData.configurationId)
      pure (maybe En (.language) maybeConfig)  -- missing config → English fallback
```

The resolved `Language` is **threaded as an explicit parameter** through the
handler helpers and into the pure renderers. Rationale: the codebase's stated
preference is narrow, explicit capabilities over widening the monad; language is
a per-message value, not an ambient effect, so a parameter is clearer than a
reader field and keeps the renderers pure and unit-testable.

**Avoid the extra round-trip.** Several helpers (`getCategoryEntries`,
`getDictionaryEntryNames`, `replyRecordedTransaction`) already load the user's
`ConfigurationData` per message. Where a handler already has the config in hand,
read `.language` off it rather than re-fetching; `languageForTelegram` above is
the fallback only for paths that do not otherwise load the config.

For the pre-signup flows (`/start`, `/signup`, unknown-user branches) there is no
persisted language yet — these default to `En`. (A future enhancement could read
Telegram's own `from.language_code`; out of scope here.)

### A.2 The Telegram area catalog

Telegram is a **closed message catalog** (shape 1 in §F.1). Introduce
**`Telegram.I18n`** — a **catalog record per language**, feature-namespaced,
mirroring the web's catalogs. It is an *area* built on the
`Domain.Localization` foundation (§F), not a bespoke mechanism:

```haskell
-- Telegram.I18n
data TelegramStrings = TelegramStrings
  { common       :: CommonStrings
  , accounts     :: AccountStrings
  , transactions :: TransactionStrings
  , prompt       :: PromptStrings
  , errors       :: ErrorStrings
  }

-- Interpolating messages are function-typed fields (type-safe args):
data AccountStrings = AccountStrings
  { enterName        :: Text
  , nameEmpty        :: Text
  , createdSelected  :: Text -> Text -> Text  -- name, currency
  , notFound         :: Text
  , ...
  }

en :: TelegramStrings
uk :: TelegramStrings

telegramStrings :: Language -> TelegramStrings
telegramStrings En = en
telegramStrings Uk = uk
```

**Why a record-per-language (not a message sum type or string keys):**

- **Completeness is compiler-enforced.** A new locale is a new `TelegramStrings`
  value; omitting any field is a `-Wmissing-fields` warning, which is an **error**
  under the project's `-Werror` (`-fci`) gate. So "no missing translations" is
  guaranteed at build time — strictly stronger than the epic's "English is the
  fallback for a missing key" (there are no missing keys).
- **Type-safe interpolation.** Each interpolating message is a function with its
  own argument types; the compiler prevents arity/type mismatches. No positional
  `printf`-style key lookup.
- **Grouped by language + feature**, matching web's model and the "drop in a
  catalog" contract.
- **English fallback** still holds structurally (`En` is a full catalog; any
  future partial locale would be resolved by falling back per-namespace — but the
  `-Werror` completeness check means we never ship a partial locale).

Non-interpolating call sites become `(telegramStrings lang).accounts.enterName`;
interpolating ones `(telegramStrings lang).accounts.createdSelected name curLabel`.

### A.3 Renderers in `Telegram.Formatting`

`Telegram.Formatting` currently hard-codes labels ("Income"/"Expense"/
"Transfer"/"Adjustment"), status markers (`[Pending]`, `[Failed: …]`,
`[Cancelled]`), and field labels ("Labels:", "Rate:", "recorded"). These are
app chrome → localized.

- `formatRecordedTransaction`, `formatTransactionLine`, and the type/status
  helpers gain a `Language` parameter and read labels from `telegramStrings`.
- **Value renderers stay as-is:** `formatMoney` (two decimals), `showCurrency`
  (ISO code), `formatDate` (`YYYY-MM-DD HH:MM`, international) — see §A.5.
- **User content stays verbatim:** category/label names resolved from the user's
  dictionary, account names, and descriptions are never routed through the
  catalog (they are the user's data).

### A.4 The command menu (`setMyCommands`) vs the in-chat `/help`

`botCommands` (`Telegram.Types`) is used in **two** places with **different**
localization stories:

1. **`setMyCommands`** (`Telegram.Api`) registers the command menu Telegram shows
   in its UI. This has **two layers**:
   - **Global baseline (startup):** loop `registerCommands` per supported locale —
     `languageCode = Just "uk"` for `uk`, default (no `language_code`) for `en`.
     Telegram serves these by the **Telegram-client** `language_code`, so alone
     they *cannot* honour our per-user app signal (a user whose Telegram app is
     English keeps the English menu even after choosing Ukrainian in-app).
   - **Per-chat override (the fix):** `registerChatCommands` pushes a
     `BotCommandScopeChat` registration in the user's *app* language. A chat scope
     wins over the client-language default, so the menu follows our signal
     regardless of the user's Telegram locale. `handleCommand` calls
     `syncChatCommandMenu` after resolving `lang`, which pushes the chat-scoped
     menu **only when the chat's language changed** (memoised in
     `BotState.syncedCommandLangs` via the pure `commandMenuNeedsSync`): one API
     call on first contact or a language switch, none otherwise. A web-side
     language change reflects on the user's next bot command. Best-effort — a
     failed push is logged and left un-memoised so the next interaction retries.
2. **In-chat `/help` and `/start`** (`formatCommandList`) render the command list
   *inside a message*, so these use **our** stored signal via `telegramStrings lang`.

`botCommands` therefore becomes locale-parameterized: `botCommands :: Language ->
[(Text, Text)]` (command tokens are stable; only descriptions localize).

### A.5 Formatting (dates/numbers) — deliberately unchanged

Web PR #94 drives *formatting* off **country**, not language, and uses the
**international default** (ISO dates, `1,234.50`) when no country is set. Telegram
output today already matches that international default. To keep this slice
focused and avoid threading a second (country) signal through every renderer,
**numeric/date formatting in Telegram is left unchanged** in this design.
Country-aware Telegram formatting is a clean, bounded follow-up (thread `Country`
alongside `Language`, reuse the same regional rules as web) and is called out as
out of scope here.

### A.6 Scope of strings covered

All user-facing output the bot emits: command replies, prompts ("Enter
amount:"), validation/error messages ("Invalid amount…"), the unknown-command
reply, transaction confirmations and listings, type/status labels, inline-button
labels (`Telegram.Keyboards`), and the command menu + `/help`. Ad-hoc
`sendMsg chatId "literal"` sites in `Telegram.Commands` are migrated to
`telegramStrings`.

---

## Slice B — Localized starter dictionaries (translate-until-touched)

### B.1 The problem and the constraints

The default category tree (`Domain.Configuration.Defaults`) is English-only.
It is seeded once into the System-owned config (`defaultConfigurationId`) at
bootstrap and **copied per-user via copy-on-write** (`cloneConfiguration`) on the
user's first config write. So every user starts with English categories
regardless of locale.

Two couplings forbid naively swapping the seeded names:

1. Each entry's **deterministic UUID is derived from its English name**
   (`mkDeterministicEntryId kind entryName`).
2. `Infrastructure.Banking.CategoryDefaults` (MCC → category for bank imports)
   references those exact IDs.

So the display name must be localizable **without changing the ID**.

### B.2 Semantics: translate-until-touched

- **Untouched default categories render in the user's current locale.** Change
  locale → their names follow.
- **The moment the user renames or creates an entry, it is theirs** — verbatim,
  never auto-changed again.
- **No country/locale set → English defaults** (English is the fallback; a user
  without a country is never left without dictionaries — the English defaults are
  always present via the shared System config).

### B.3 Trigger: country **or** language change

Localization runs on **both** `changeCountry` and `changeLanguage`
(`Application.Services.ConfigurationService`):

- `changeCountry` resolves the target language via `presetFor` and localizes.
- `changeLanguage` localizes to the chosen language directly.

Web onboarding (PR #93) is "no backend change" and defines
`needsOnboarding = country == null`, so **`changeCountry` is already the
onboarding seam** — no new endpoint is required, and the normal onboarding path
(country selected → language cascades) localizes eagerly within that one
operation, before the user sees anything. The renames are a **single append** (see
§B.4), so `changeCountry` is the `ChangeCountry` leg + the base-currency leg + one
batched relocalize append — a small constant number of event-store transactions,
independent of how many defaults change.

### B.4 The ID-anchored untouched-default guard

Localization rewrites the **name** of an entry only if it passes both:

- **(a) ID anchor** — the entry's ID is one of the deterministic default IDs
  (built from `defaultIncomeCategories <> defaultExpenseCategories`). User-created
  entries have random IDs and never qualify.
- **(b) canonical-name match** — the entry's current name equals that default's
  canonical name in **some** supported language, i.e.
  `name ∈ { localizedName l canonical | l <- [minBound..maxBound] }`. A renamed
  default (name no longer any canonical) never qualifies.

All qualifying entries are renamed by a **single** batched command,
**`RenameDictionaryEntries`** (`Domain.Configuration.Commands`), carrying a list of
`RenameDictionaryEntry`. Its command handler emits one `DictionaryEntryRenamed`
event per rename, and `applyCommandHandler` appends them **atomically in one
event-store transaction** — so ~N renames cost **one** append (one transaction +
one synchronous persistent-read-model pass), not N. The events reuse the existing `DictionaryEntryRenamed`
type written to the already-existing name column — this is **materialized
re-translation** (rewrite the stored name), working uniformly for web and Telegram
(both read stored names verbatim) with **no render-time resolver and no
stored-shape change**. (`RenameDictionaryEntries` is a new *command*; commands are
never persisted, so this adds no wire/stored shape and needs no upcaster.)

> **Latency note.** Batching the renames into one append was necessary but not
> sufficient: even a single append of ~37 events was slow (~8 s locally) because
> the process managers were re-projecting the entire global event store on *every*
> event in the write transaction. That was fixed generically in eventium
> (snapshot-cached saga projections) — see
> [ADR 003](../decisions/003-process-manager-snapshot-caching.md). With both in
> place, `changeCountry` is a small constant number of appends, each O(events in
> the write).

**The batch is best-effort at the entry level.** The handler validates each rename
against the aggregate (entry exists; no sibling-name collision) and **drops** any
that fail (`mapMaybe`), emitting events only for the valid ones — so one bad entry
never fails the whole batch, and the whole thing is still a single append. For an
ordinary en↔uk switch the target names differ from every sibling, so nothing is
dropped.

The ID anchor makes the guard safe. The sole theoretical false positive — a user
manually renaming a default to *another supported language's exact canonical name
for that same default* (e.g. renaming "Groceries" to "Продукти" while on English)
— is astronomically unlikely and harmless (it would re-translate on the next
switch).

### B.5 Category-name catalog (second area)

Default category names are an **open key→text catalog** (shape 2 in §F.1) — the
second area on the foundation. Add pure module
**`Domain.Localization.CategoryCatalog`**, built on `Domain.Localization.Catalog`:

```haskell
-- base = the canonical English name itself (total, never fails);
-- overrides = uk (and future locales). Reuses the shared `resolve`.
localizedCategoryName :: Language -> Text -> Text
localizedCategoryName = resolve categoryOverrides id
  where
    categoryOverrides :: Language -> Text -> Maybe Text
    categoryOverrides Uk = ukCategoryNames   -- Map Text Text lookup
    categoryOverrides En = const Nothing     -- base (identity) covers En
```

The canonical English names + IDs stay in `Domain.Configuration.Defaults`
(unchanged; still derive the IDs). The seed/relocalize code in
`ConfigurationService` builds `Map CategoryId CanonicalName` from the existing
default lists and consults `localizedCategoryName` for the target language.
`Domain.Configuration.Defaults` does **not** depend on `Domain.Localization`; the
Application layer composes the two (permitted direction). Ukrainian names for the
~37 default categories are authored in this table (best-effort; native-speaker
review is a follow-up, mirroring web PR #94's `uk` review).

### B.6 Seeding and existing users

- The **System seed** stays English (canonical). Per-user localization happens
  on the user's own (cloned) config via the trigger in §B.3.
- **Existing users are not retro-translated by a migration.** Localization fires
  prospectively on their next `changeCountry`/`changeLanguage`. (In alpha, data
  is disposable anyway.)
- No DB recreate, no upcaster, no stored-shape change.

---

## Testing strategy

Following the project's property-first, TDD approach:

**Slice A**
- **Catalog completeness** — a test asserting every `TelegramStrings` field is
  reachable for every `Language` (the `-Werror`/`-Wmissing-fields` gate already
  enforces construction completeness; this test documents intent and guards the
  `telegramStrings` dispatch).
- **Renderer unit tests** — `formatRecordedTransaction`/`formatTransactionLine`
  for each `Language` × each `TransactionType`/`TransactionStatus`, asserting
  labels localize while **user content (names/descriptions) stays verbatim**.
- **Language resolution** — `languageForTelegram` returns the config language;
  `En` for unknown user / missing config.

**Slice B**
- **Property: ID stability** — `mkDeterministicEntryId` output is unchanged by
  this work (regression guard on the banking-defaults coupling).
- **Guard behavior** (property + unit): untouched default → localized; renamed
  default → untouched; user-created entry → untouched; round-trip en→uk→en
  restores English for untouched defaults.
- **Integration** — new user → `changeCountry UA` → dictionaries are Ukrainian;
  rename one → switch locale → renamed one stays, others follow.
- **No stored-shape assertion** — SchemaSpec unchanged; `accountingSchemaRegistry`
  stays empty (no upcaster added).

## Extensibility contract

**Adding a locale** (e.g. `de`): (1) add `De` to `Domain.Localization.Language` +
its code/parse; (2) add the `de` `TelegramStrings` value (compiler lists every missing
field); (3) add `de` overrides to `CategoryCatalog`; (4) register the `de`
`setMyCommands` menu. No feature-component or handler changes — and the same short
list applies to *every* area that exists at that time.

**Adding an area** (e.g. emails, NL-prompt replies): create one new catalog module
on the `Domain.Localization` foundation (§F) — a record-per-language for a closed
set, or per-locale override tables + `resolve` for an open keyset — and call it
from that surface. **No existing area changes.** This is the "extensible with
other areas" property: areas are additive and independent, unified only by the
shared `Language` signal and English-fallback rule.

## Risks / edge cases

- **Command-menu locale.** The global `setMyCommands` registration follows the
  Telegram *client* language, so it alone ignores our signal. Resolved with a
  per-chat `BotCommandScopeChat` override that follows the user's app language
  (§A.4) — pushed lazily on language change. The remaining edge is a user who
  changes language on the web and then only taps buttons (never types a command):
  their menu updates on the next command, not instantly. Acceptable.
- **Materialized re-translation churn.** Each locale change re-issues rename
  events for untouched defaults. Bounded (~37 entries), acceptable event-log
  cost; only on locale change.
- **Guard false positive (known limitation).** Because "untouched" is inferred by
  matching the current name against *any* supported locale's canonical name (§B.4),
  a user who deliberately renames a default to another locale's exact canonical
  string for that same default — e.g. renames "Groceries" → "Продукти" while on
  English — will have it rewritten to the active locale's name on a later locale
  change (`current ∈ acceptable ∧ current ≠ target → rename`). This is inherent to
  the flag-free translate-until-touched design: a robust fix needs a per-entry
  `touched` bit, which is a **stored-shape change** and would violate the
  no-migration invariant. Accepted as-is — the collision requires typing another
  language's exact default name, the probability rises only as locales are added,
  and the outcome is a recoverable rename (no data loss). Revisit if it ever
  matters in practice.

## Out of scope

- Emails / other backend output (no such subsystem exists).
- Country-aware numeric/date formatting in Telegram (§A.5) — bounded follow-up.
- Native-speaker `uk` review of catalog + category names — follow-up.
- Reading Telegram `from.language_code` for pre-signup (unlinked) flows.
- Consolidating the redundant per-update read-model lookups in the Telegram
  handlers (`languageForTelegram` re-fetches the user+config that
  `getCategoryEntries`/`getDictionaryEntryNames`/`getUserIdForTelegram` also load).
  Pre-existing pattern; a future refactor could resolve `(userId,
  ConfigurationData)` once per update and thread it. Non-blocking.
