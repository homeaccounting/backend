---
status: draft
date: 2026-08-11
---

# Signal foundation — user country + UI language

**Shared signal foundation** feeding two epics:
`homeaccounting/tracker#48` (Personalization / p13n) and
`homeaccounting/tracker#56` (Localization / i18n). Related issues: `#47` (user
country + provider scoping, under #48), `#35` (user-selectable UI language, under
#56). The country and language signals are owned by neither epic — they are the
per-user, server-persisted substrate both consume. Spans two repos: the Haskell
backend (`homeaccounting/backend`, this repo) and the web client
(`homeaccounting/monorepo`, `../monorepo`). **This spec covers the backend only.**
Web work (i18n runtime, selectors, onboarding step) lands against the API surface
defined here.

## Where this sits

Personalization (#48) *curates what the user sees*; localization (#56) *renders
it in the user's language and regional formats*. Both key off the same two
signals. This spec builds those signals and the preset that ties them together,
and deliberately stops there:

- **P1 (this spec)** — the `country` and `language` signals live in user
  configuration, plus a country → regional-preset application. Pure signal
  plumbing + the preset UX.
- **P2 (separate spec, deferred)** — provider scoping by country: a **scope**
  notion on `BankProviderDescriptor` (e.g. `Global | Regional (Set Country)`),
  the country filter on the available-providers surface, server-side rejection of
  out-of-country providers, the graceful no-provider-for-country path.
  **Global vs. regional:** the filter is *not* "hide everything that doesn't match
  the country." Some providers are **global** (country-agnostic — generic
  file-import, global banks) and must show for every user regardless of country;
  only **regional** providers are scoped to their country set. Globals pass the
  filter unconditionally; a user with `country = Nothing` therefore still sees the
  global providers (this is the graceful no-country path).

Splitting P1/P2 keeps this change to one cohesive unit (the signals + their
defaulting preset) and lets provider scoping land on top without re-touching the
configuration plumbing.

> **Note:** `#40` (usage-desc ordering of categories & labels) is **not** part of
> this epic. It is a generic UX sort derived from usage data, not a per-user
> server-persisted *signal* like country/language, so it is tracked
> independently.

## Problem

Every user today sees the union of all regions' defaults. The app hard-codes
English copy, and base/default currency are the only region-ish signals, chosen
manually at signup. There is no server-persisted notion of *where the user is* or
*what language they read*, so:

- Nothing can scope providers, seed localization, or drive region-appropriate
  defaults — every future personalized surface would have to re-derive region ad
  hoc.
- A user picking a country should not then have to separately hunt for the right
  language and currencies; the region already implies sensible defaults.

## Goals

- Add `country` (ISO 3166-1 alpha-2) and `language` (closed locale set) to user
  configuration, server-persisted so they follow the user across devices.
- On an explicit country selection, apply a **regional preset** that sets
  language, default currency, and (when permitted) base currency in one action.
- Establish these as the single source of truth other features (P2 provider
  scoping, locale-aware backend output) read — never re-derived per feature.
- Do it **backward-compatibly via upcast-on-read**, not a DB recreate.

## Non-goals (deferred)

- Provider scoping by country (P2).
- Locale-aware backend-generated output (emails, Telegram replies) — unlocked by
  the `language` signal but tracked as a `#35` follow-up.
- The web i18n runtime, catalogs, `uk` translation, and selectors/onboarding UI
  (`#35`/`#47`, web repo).
- `#40` usage ordering — out of this epic entirely (see note above).

## Constraints / principles (from `#48`)

- **One source of truth per signal.** Country and language each live once in user
  configuration.
- **Server-authoritative, cross-device.** Mirrors base-currency persistence.
- **Personalization defaults, never locks.** Every preset-applied value stays
  individually user-overridable afterward.
- **No useless default.** Country defaults to *unset*, not a guessed value; no
  preset fires until the user opts in.
- **Backward compatibility.** Stored-shape change ships an upcaster
  (upcast-on-read is the standing policy; DB recreate is the rare escape hatch and
  is **not** used here).

## Design

### Domain value types — `Domain.Localization`

New namespace, parallel to the `Domain.Banking` value-type extraction, keeping
`Domain.Core.Types` lean. Both types have smart constructors and never export
their constructors. The constructors return **`Either Text a`**, matching the
closest peers `parseCurrency` and `mkEntryName` (both `Either Text`) — this plugs
directly into the Web layer's `validateFieldCtx :: Text -> Text -> Either Text a
-> AppM a`, which wraps the `Text` into a field-scoped `ValidationError` at the
boundary (as `changeBaseCurrencyHandler` already does for `parseCurrency`).

- **`Country`** — validated newtype over **ISO 3166-1 alpha-2**. Validation:
  well-formed (two uppercase ASCII letters) **and** membership in the
  **supported-country set** (below). `US`/`UA`/`DE` pass; `ZZ`/`us`/`U`/`USA` are
  rejected. "Valid country" is deliberately **decoupled** from "country we have
  providers for" — the latter is P2's concern. `mkCountry :: Text -> Either Text
  Country`, an `unCountry :: Country -> Text` accessor, and an `unsafeCountry ::
  Text -> Country` for trusted reconstruction (DB reads), mirroring
  `unsafeEntryName`.
  - **Supported-country set (launch scope):** we do **not** build the full
    ~249-entry ISO table now. The supported set is exactly the countries the 3
    presets cover — `US`, `UA`, and the **euro-area** members
    (`AT BE HR CY EE FI FR DE GR IE IT LV LT LU MT NL PT SK SI ES`) — a single
    static `Set Country` literal in `Domain.Localization.Country`, extended as
    coverage grows. This is also the selectable list the picker renders and the
    set `localization-options` returns. `Country` stays a genuine ISO code (not a
    coarse region), so P2 per-country provider scoping (monobank = `UA`
    specifically) is exact.
  - **LiquidHaskell scope (honest, matching precedent):** the closest peers —
    `Currency` (a closed sum) and `EntryName` (a `Text` newtype) — carry **no**
    LiquidHaskell refinement; validation lives entirely in their smart
    constructors + tests. `Country`/`Language` follow that precedent: no LH
    refinement (well-formedness *could* be refined but set membership cannot, and
    matching the peers avoids LH sort-error friction). All validation is in the
    smart constructor and proven by tests.
- **`Language`** — a **closed sum type** `Language = En | Uk`, not an open
  newtype: locales are few and each is a real code change (a new catalog), so an
  exhaustively-matchable type is correct and sets up locale-aware backend output
  later. `En` is the default/fallback. A `parseLanguage :: Text -> Either Text
  Language` / `languageCode :: Language -> Text` pair bridges the wire codes
  (`"en"`, `"uk"` — ISO 639-1; note `uk`, never `ua`).
  - **JSON representation is pinned, not derived.** `Language` nests inside the
    stored `ConfigurationCreated` event, so its instance is part of a stored
    shape. Use a **hand-written single-shape** `ToJSON`/`FromJSON` encoding the
    **lowercase code** (`"en"`/`"uk"`), mirroring the existing `Currency` sum in
    `Domain/Core/Types.hs` (which hand-encodes `"USD"`). **Do not** use
    `deriveJSON defaultOptions` — it would encode the *constructor names*
    (`"En"`/`"Uk"`), which (a) breaks the upcaster below, which injects `"en"`,
    and (b) is the wrong wire contract. The instance still targets exactly one
    shape, so it is CLAUDE-compliant (this is not custom-`FromJSON`-as-migration).
    `Country`'s stored form is the plain alpha-2 code string.

The asymmetry (open `Country` newtype vs. closed `Language` sum) is intentional
and reflects their different cardinalities.

### Country preset — `Domain.Localization.Preset`

Pure country → defaults table. **Three preset profiles for launch — US, EU, UA:**

```haskell
data CountryPreset = CountryPreset
  { language        :: Language
  , baseCurrency    :: Maybe Currency
  , defaultCurrency :: Maybe Currency
  }

presetFor :: Country -> CountryPreset
```

- **US profile** → `CountryPreset En (Just USD) (Just USD)` — for `US`.
- **UA profile** → `CountryPreset Uk (Just UAH) (Just UAH)` — for `UA`.
- **EU profile** → `CountryPreset En (Just EUR) (Just EUR)` — for **every
  euro-area country** in the supported set (`AT BE HR CY EE FI FR DE GR IE IT LV
  LT LU MT NL PT SK SI ES`). Language is `En` because only `en`/`uk` catalogs
  exist; the currency is `EUR`.
- **Fallback** → `CountryPreset En Nothing Nothing`: language set, currencies
  **left untouched** (never force a wrong currency). Only reachable if the
  supported set is later widened ahead of the preset table.

Note the many-to-one shape: `EU` is a *profile*, not a country — the ~20
euro-area ISO codes all map to it, but each user's stored `country` remains their
real ISO code (e.g. `DE`), so P2 provider scoping stays per-country. `presetFor`
is total. The euro-area membership list lives beside the supported-country set in
`Domain.Localization.Country` (single source).

### Events & commands (Configuration aggregate)

- **`ConfigurationCreated` gains** `language :: Language` and `country :: Maybe
  Country`. The command handler defaults them (`En` / `Nothing`) at creation, so
  **registration is untouched** — no new signup inputs, no country threaded
  through the creation payload.
- **New events** `LanguageChanged { language }`, `CountryChanged { country }`.
- **New commands** `ChangeLanguage { language }`, `ChangeCountry { country }`.
- **Actor field:** none. Country/language edits are in-place config field edits,
  not whole-aggregate lifecycle actions, so they carry **no `by`** — consistent
  with `ChangeBaseCurrency`/`DefaultCurrencyChanged` and the actor-field policy.
- **Creation guard:** the `ChangeLanguage` / `ChangeCountry` handlers must reject
  when the aggregate is not yet created (`not config.isCreated →
  ConfigurationNotCreated`), matching every other mutating handler.
- **Aggregate record:** the in-memory `Configuration` aggregate need **not** gain
  `language`/`country` fields — no handler reads current language/country to
  decide anything (the base-currency editability input is external, see below).
  Only `ConfigurationCreated` (for the read-model projection) and the read-model
  entity carry them. Leave the aggregate record unchanged.

Register both new events in `configurationEvents` and both commands in
`configurationCommands` (Template Haskell lists). Add `deriveJSON defaultOptions`
for the two **event/command** types (their own fields are `Country`/`Language`,
whose *value* instances are the pinned hand-written ones above — `deriveJSON` on
the wrapper composes with them correctly).

### How the preset applies — a config bundle + a cross-aggregate base-currency leg

**Overwrite semantics — wholesale apply (decision A).** On an explicit country
change the preset overwrites language and currencies. This matches the "pick a
country → get it all set" UX, needs no per-field "explicitly set" bookkeeping,
and honors "defaults, never locks" because every field stays individually
overridable afterward. At onboarding (first pick, nothing set yet) this is the
only sensible behavior anyway; wholesale-apply and fill-only-unset differ only on
a *later* country change, which is rare.

**Two legs, because base currency spans two aggregates.** Crucially,
`changeBaseCurrency` in the service is **not** a single config event — it also
issues `ChangeAccountCurrency` against the user's **External account**, which
anchors the reporting/base currency. So the base-currency change touches *both*
the Account and Configuration aggregates and **cannot** be emitted from a
Configuration-only `ChangeCountry` handler without the account currency drifting
out of sync. The preset therefore applies in two legs:

- **Leg 1 — the Configuration bundle (atomic, one append).** `ChangeCountry {
  country }`'s handler computes the pure preset (`presetFor country`) and emits,
  in one `[ConfigurationEvent]` list:

  ```
  CountryChanged { country }
  LanguageChanged { language = preset.language }
  DefaultCurrencyChanged { defaultCurrency = c }   -- only when preset.defaultCurrency = Just c
  ```

  These are all Configuration-aggregate events, so the list is appended
  atomically. Reusing `LanguageChanged`/`DefaultCurrencyChanged` means the only
  genuinely new event types are `CountryChanged` and `LanguageChanged`. The
  command carries **only** `country` — no `applyBaseCurrency` — because base
  currency is not a Configuration-only fact (see leg 2). `presetFor` is pure and
  lives in the domain, so the handler computes the preset itself; nothing impure
  crosses into the aggregate.

- **Leg 2 — the base-currency leg (service-orchestrated, cross-aggregate).**
  `ConfigurationService.changeCountry`, after issuing the leg-1 command, applies
  base currency **only when it is editable and the preset specifies one**, by
  **reusing the existing `changeBaseCurrency` flow** (which updates the External
  account currency *and* emits `BaseCurrencyChanged`):

  ```
  changeCountry userId country = do
    let preset = presetFor country
    editable <- baseCurrencyEditable userId
    _ <- runConfigurationCmd ... (ChangeCountry { country })      -- leg 1
    when (editable) $
      forM_ preset.baseCurrency $ \c -> changeBaseCurrency userId c   -- leg 2
  ```

  Atomicity boundary: leg 1 is atomic; leg 2 is a separate cross-aggregate step —
  the **same** non-atomicity `changeBaseCurrency` already has today (it does
  account-then-config), not a regression. When base currency is *not* editable
  (External account has transactions), leg 2 is skipped and base currency is left
  as-is; country/language/default-currency still apply, and the web explains why
  base currency was unchanged.

**`baseCurrencyEditable` — Application-layer helper (layering fix from review).**
The editability logic today lives in
`Web.API.ConfigurationAPI.computeBaseCurrencyEditable`, which `Application.*`
**must not** import (Web is above Application). Its logic is Application-available
(`getUserExternalAccountId` in `Application.Services.Internal` +
`getAccount`/`.hasTransactions` on the account read model), so introduce
`ConfigurationService.baseCurrencyEditable :: UserId -> AppM Bool` holding the
exact current logic (no External account or no transactions → editable), and
refactor the Web handler to delegate to it (removing the duplicate) so there is
one source of truth. It is a *move*, not a reuse.

`ChangeLanguage` is the standalone override path: it emits a single
`LanguageChanged` and never touches currency.

### Upcaster (backward compatibility)

`ConfigurationCreated` is the only changed stored shape. It becomes **v2**; a
single-hop **v1→v2 upcaster** is registered in `accountingSchemaRegistry`
(`Infrastructure.Eventium.Schema`), which is currently `emptyRegistry`. Per
`CLAUDE.md`, this is the **first live entry** in that registry and re-activates
the upcast-on-read seam with no other wiring changes.

The upcaster transforms the `contents` object of the `{tag, contents}` envelope:
a v1 `ConfigurationCreated` lacking the new fields gets `language: "en"` injected
(the lowercase code — which is exactly why `Language`'s JSON instance must encode
the code, not the constructor name). `country: null` injection is technically
optional — `deriveJSON defaultOptions` decodes an absent `Maybe` field as
`Nothing` — but the upcaster injects it explicitly for a self-describing v2 shape.
No other event type is touched.

Register the single hop keyed by `EventTypeName` for `ConfigurationCreated`;
eventium's `currentVersion = 1 + (number of registered hops)` makes it v2, and
legacy pre-envelope rows decode as `schemaVersion = 1`, so the one hop covers all
existing rows. Prefer the existing combinators (`atKey "contents"` +
`addFieldIfAbsent`) over a bespoke `Value` rewrite.

### Config creation paths (from review)

Two paths create a configuration; both must handle the new fields deliberately:

- **Registration** (`AuthService` → `CreateConfiguration`): `CreateConfiguration`
  gains **no** language/country inputs; the handler emits `ConfigurationCreated`
  with `language = En`, `country = Nothing`. Registration is untouched.
- **Clone** (`ConfigurationService.cloneConfiguration`, used when provisioning
  from a shared/template config): it currently copies currencies, dictionaries,
  defaults, and banking but has **no** language/country step, so cloning a config
  that had them set would silently reset them to `En`/`Nothing`. Make an explicit
  decision, matching how `booksClosedThrough` is handled: **propagate**
  `language`/`country` from the source config into the clone (recommended), or
  document the reset. Do not leave it implicit.

### Read model / projection

`Application.ReadModels.Configuration` — the persistent `configurations` read
model (`ConfigurationEntity`, `mkMigrate "migrateConfiguration"`):

- Add columns `language Language` and `country Country Maybe` to
  `ConfigurationEntity` (a Persistent `PersistField`/`PersistFieldSql` instance
  is needed for both `Language` and `Country`, following the existing `Currency`
  orphan-instance pattern in `Infrastructure.Database.Orphans`).
- Seed both from `ConfigurationCreated` (`language`, `country`).
- Handle `LanguageChanged` (set `language`) and `CountryChanged` (set `country`)
  in the projection fold, each bumping `configurationEntityVersion`.
- **Migration mechanics (from review):** `country Country Maybe` is a clean
  additive nullable column. `language Language` is **NOT NULL**, and
  `runMigrationSilent` (the read-model `initialize` path) cannot add a NOT NULL
  column to a populated table *without a default*. Resolution: declare the column
  with a SQL default — `language Language default='en'` — so
  `ALTER TABLE ADD COLUMN ... NOT NULL DEFAULT 'en'` backfills existing rows with
  the correct fallback (`en`) and the migration stays purely additive on a
  populated DB (no ops step). New rows are set by the projection; the default only
  ever backfills pre-feature rows, for which `en` is exactly right. (Fallback if
  persistent's custom-type default DDL misbehaves: a read-model reset + replay — a
  derived-data rebuild, **not** an event-log recreate, cheap in pre-launch alpha.)

### Web API — `Web.API.ConfigurationAPI`

- **`ConfigurationResponse` gains** `language :: Text` (always present; `"en"`
  when unset) and `country :: Maybe Text` (the alpha-2 code, `null` when unset).
- **`PUT /api/users/me/configuration/language`** — body `{ language: string }`,
  validated via `parseLanguage`; `DomainError` validation error on an unsupported
  code, mirroring the base-currency handler. Emits `ChangeLanguage`.
- **`PUT /api/users/me/configuration/country`** — body `{ country: string }`,
  validated via `mkCountry`. Applies the preset (service orchestration above).
- **`GET /api/users/me/configuration/localization-options`** — returns the
  supported locales (code + native label) and the selectable country list, so the
  backend is the **single registry the web reads** (the `#48` "one source of
  truth" constraint) rather than the web hardcoding a parallel list. This is the
  one addition beyond bare field plumbing; it is what the web country/language
  pickers render from.

Request DTOs use the smart-constructor-in-`FromJSON`/handler-validation pattern
already used for currency (external inbound data → validate, not migrate).

### Onboarding / the "no useless default" story

Country defaults to `Nothing`; **no preset fires until the user explicitly picks
a country.** A fresh configuration is therefore a fully functional, honest state:
`language = En` (fallback), currencies as chosen at signup, `country = Nothing`.

The onboarding country prompt is **optional, not a gate** (honoring "defaults,
never locks"):

- If the user never picks a country: language stays `En`, currencies stay as
  chosen at signup, and P2 provider scoping hits its graceful "no country → show
  country-agnostic / file-import providers" fallback. Nothing breaks.
- The backend is **agnostic to *when* the web prompts.** Picking a country is
  just a `PUT .../country` call. The web may ask it as a dedicated onboarding
  step, or right after signup for a "country-first" flow (replacing the manual
  currency question — at that point transactions = 0, so base currency is
  editable and the preset fully applies). Same endpoint either way; registration
  and `ConfigurationCreated` stay untouched.

## Dictionaries and the language signal (scope boundary)

The `language` signal localizes **UI chrome only**, never stored user content.
User-facing text splits into two disjoint sets:

- **UI chrome** — buttons, menu labels, headers, validation messages, empty
  states. App-authored static strings, routed through the i18n catalog
  (`en`/`uk`). This is what `language` drives; the catalog runtime is `#35` web
  work. P1 only persists the preference.
- **User content** — dictionary entry names (categories, labels, contacts,
  account names) and transaction descriptions. Free text the user authored,
  stored on the backend, shown **verbatim in whatever language the user wrote
  it**. Switching the UI language **never** rewrites it (a `uk` user's
  "Продукти" stays "Продукти" under an English UI, and vice versa) — exactly
  like an OS not translating folder names. Dictionary names are *data passed
  through*, not translation keys; the "no inline user-facing strings" i18n rule
  applies to chrome only.

So "dictionaries stored on the backend" and "localized UI" do not conflict —
they operate on disjoint text.

The **only** place language ever touches dictionary *content* is
region-appropriate **starter-content seeding** (a default category set / MCC map
in the chosen language). This is **explicitly `#48` future scope, not P1**, and
even when built it is **seed-once, not live-translate**: starter entries are
seeded once at the country/onboarding step and thereafter are ordinary editable
user data. They are never re-translated on a later language change — doing so
would silently clobber the user's own edits and violate the single-source-of-
truth + no-auto-modify rules. A later language switch leaves existing dictionary
entries untouched.

## Testing

- **Domain (property + unit):** `mkCountry` accepts supported-set members (`US`,
  `UA`, and a euro-area code like `DE`), rejects malformed (`us`/`U`/`USA`) and
  unsupported (`ZZ`, and a currently-out-of-scope real code) with the right
  `errorContext`; `parseLanguage` round-trips `En`/`Uk` and rejects others;
  `presetFor` returns `USD` for `US`, `UAH`/`Uk` for `UA`, `EUR`/`En` for a
  euro-area country, and the `En`/`Nothing`/`Nothing` fallback for an
  out-of-supported-set code (unit-level, since the API can't reach it at launch).
  Property: `parseLanguage . languageCode == Right`; every supported country has a
  non-fallback preset.
- **Schema (upcast-on-read):** commit a v1 fixture
  `test/fixtures/events/configuration-created-v1.json` (old shape, no
  `language`/`country`); a `SchemaSpec` case loads → decodes → asserts `language
  = En`, `country = Nothing` → re-encodes at v2 → decodes again (round-trip
  stable). Add the type-derived-tag pin for `CountryChanged`/`LanguageChanged`
  matching the existing pattern.
- **Command handler (unit, leg 1):** `ChangeCountry UA` emits exactly
  `CountryChanged UA` + `LanguageChanged Uk` + `DefaultCurrencyChanged UAH` (no
  `BaseCurrencyChanged` — that is leg 2, the service's job); a euro-area country
  emits `CountryChanged` + `LanguageChanged En` + `DefaultCurrencyChanged EUR`; a
  country whose preset has `defaultCurrency = Nothing` emits `CountryChanged` +
  `LanguageChanged` only; `not isCreated → Left ConfigurationNotCreated`.
  `ChangeLanguage` emits a lone `LanguageChanged`.
- **Service (integration, leg 2):** `changeCountry` for `UA` on a fresh user
  (External account has no transactions) applies base currency `UAH` — the
  External account currency *and* the config both become `UAH`; for a user whose
  External account already has transactions, base currency is left unchanged while
  country/language/default-currency still apply.
- **Integration / API:** config round-trip surfaces `language`/`country`; `PUT
  .../language` and `.../country` persist and reflect in `ConfigurationResponse`;
  validation rejection on bad codes; `PUT .../country` for `UA` on a fresh user
  applies the full preset; for a user with transactions leaves base currency
  unchanged; `localization-options` returns the expected sets.

## Backward compatibility summary

- **Event log:** one stored-shape change (`ConfigurationCreated` v1→v2), migrated
  by a registered upcaster — **no DB recreate**. Re-activates
  `accountingSchemaRegistry`.
- **Read model:** additive columns, rebuildable from events.
- **API:** additive — new fields on `ConfigurationResponse`, new endpoints;
  existing clients unaffected.

## Open questions

- **Native labels source** for `localization-options` country entries (English
  name vs. endonym) — minor; can default to English names initially. Only the
  supported set (US + UA + euro-area) needs names, so this is a small static map.

_Resolved:_ coverage story — the supported/selectable set for launch is exactly
the 3 presets' countries (US, UA, euro-area); no full ISO table. Since every
supported country has a preset, the `presetFor` fallback is unreachable via the
API at launch and exists only for forward safety.
