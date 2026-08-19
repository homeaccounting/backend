---
status: draft
date: 2026-08-18
---

# Bank-provider scoping by country (p13n P2)

Second phase of the personalization epic `homeaccounting/tracker#48`, issue
`#47`. Builds directly on the country/language **signal foundation** shipped in
P1 (`homeaccounting/backend#164`,
`docs/specs/2026-08-11-p13n-country-language-signal-design.md`), which added the
per-user, server-persisted `country` field to user configuration. P1 established
the signal; **P2 is the first surface that consumes it** — curating the
bank-provider list a user sees by where they bank.

Spans two repos: the Haskell backend (`homeaccounting/backend`, this repo) and
the web client (`homeaccounting/monorepo`, `../monorepo`). **This spec covers the
backend only.** Web work (country-aware provider list, "show providers from other
countries" affordance) lands against the API surface defined here.

## Where this sits

The country signal is already stored (P1). Nothing consumes it yet. P2 wires the
first consumer: the "connect a bank" / "import statement" provider list. Today
that list (`GET /api/users/me/configuration/banking/providers`) returns every
provider in the registry regardless of the caller — a US user sees the UA-only
PrivatBank and monobank. P2 annotates each provider with its country coverage and
a per-user "is this in my country" flag so the client can curate the default view.

Out of scope (already delivered by P1): deriving default currency/language from
country. Out of scope entirely (unchanged): the compile-time provider selection
mechanism (Cabal flags + CPP in `Infrastructure.Banking.Providers`) stays as-is;
P2's runtime country annotation is orthogonal to which providers are compiled in.

## Core principle: soft default, not a lock

Country is a **soft scoping default, not a hard gate.** The backend annotates;
the client curates. There is deliberately **no country gate on the
connect/import path** — the existing `providerEnabled` config flag and the
`mkBankProviderId` registry-membership check remain the only real gates.

This is a conscious reinterpretation of issue `#47`'s line *"reject out-of-country
providers server-side ... so a UA-only provider can't be connected by a US user
via a crafted request."* Country is **not a security boundary**; it is a
curation hint. The epic's own governing principle overrides the literal wording:

> *Personalization defaults, never locks. Every personalized default (provider
> list, currency, ordering) must remain user-overridable. Curate the common case;
> don't hide the long tail behind a hard constraint.*

### Why this resolves the multi-country user

A legitimate multi-country user — e.g. someone who moved from Ukraine to Germany
and still holds **both** PrivatBank (UA) and a German bank — is the case that a
hard gate would break. Under the soft-default model this needs **no extra data
modeling**:

- The user's `country` stays a **single** value (localization also needs one
  primary country for its language/currency defaults; a set would fight that).
- "I also bank in country X" is handled by the client's **"show providers from
  other countries"** affordance, not by storing a set of countries. The full
  annotated list is already in hand (see the annotate model below), so revealing
  out-of-country providers is a pure presentation choice with no second request.
- Connecting an out-of-country provider **just works** because there is no
  country gate on connect. YAGNI: we do not introduce a per-user multi-country
  signal.

Multi-country is *also* modeled on the provider side (a provider may serve several
countries) — see `ProviderCoverage` below.

## Provider coverage model

`BankProviderDescriptor` (`Infrastructure.Banking.Provider`) gains a coverage
field:

```haskell
-- Infrastructure.Banking.Provider
data ProviderCoverage
  = GlobalCoverage                 -- country-agnostic (e.g. a generic file importer)
  | RegionalCoverage (Set Country) -- serves exactly these countries

data BankProviderDescriptor = BankProviderDescriptor
  { providerId     :: !BankProviderId
  , displayName    :: !Text
  , coverage       :: !ProviderCoverage   -- NEW
  , interpretation :: TransactionInterpretation
  , pull           :: !(Maybe (BankProviderCredential -> PullCapability))
  , fileImport     :: !(Maybe FileImportCapability)
  }
```

An **explicit sum** is chosen over a bare `Set Country` with "empty = global"
because the empty-set convention is a footgun: a developer who forgets to tag a
new regional provider would silently make it global (shown to everyone) — the
exact opposite of curation. The sum forces every provider to declare its coverage
and makes the two cases self-documenting. `Country` is reused from
`Domain.Localization.Country` (the P1 newtype); `Set Country` needs an `Ord`
instance on `Country` (add if not already derived).

Coverage is **compiled-in provider metadata**, not deployment config — PrivatBank
*is* a Ukrainian provider; that is an intrinsic property, not a self-hoster
choice. It is not placed in `BankingConfig` alongside `providerEnabled` (YAGNI).

### Membership predicate

```haskell
-- Pure helper in Infrastructure.Banking.Provider
providerInCountry :: Maybe Country -> ProviderCoverage -> Bool
providerInCountry _        GlobalCoverage        = True
providerInCountry mUserCty (RegionalCoverage cs) =
  maybe True (`Set.member` cs) mUserCty
```

- `GlobalCoverage` → always in-country.
- `RegionalCoverage cs` with `country = Just c` → `c ∈ cs`.
- `RegionalCoverage cs` with `country = Nothing` → **True (show everything)**. With
  no country signal there is nothing to curate against, and hiding is the one
  thing the epic principle forbids. Globals are in-country regardless.

Matching is on the **real stored ISO code**. P1 deliberately stores the concrete
ISO code (`DE`, `FR`, …) even for users on the shared "EU" preset profile,
precisely so P2 can scope per-country: a German user (`country = Just DE`) matches
a euro-area regional provider tagged `RegionalCoverage {DE}`.

### Current provider tags

All three providers compiled in today are Ukrainian:

| Provider                     | Coverage                  |
| ---------------------------- | ------------------------- |
| monobank                     | `RegionalCoverage {UA}`   |
| PrivatBank (personal)        | `RegionalCoverage {UA}`   |
| PrivatBank (business)        | `RegionalCoverage {UA}`   |

There are no `GlobalCoverage` providers yet; a future country-agnostic file
importer would be the first.

## API change (additive)

`BankProviderDTO` (`Web.API.ConfigurationAPI`) gains two fields:

```haskell
data BankProviderDTO = BankProviderDTO
  { id            :: Text
  , displayName   :: Text
  , supportsPull  :: Bool
  , supportsFile  :: Bool
  , countries     :: [Text]   -- NEW: ISO alpha-2 codes; [] = global (no restriction)
  , inUserCountry :: Bool     -- NEW: computed against the caller's stored country
  }
```

- `countries` carries the coverage for labeling ("PrivatBank — Ukraine"); an
  empty list means `GlobalCoverage`. The client keys **presentation** off
  `inUserCountry`, not off `countries`, so the "empty = global" shape here is
  harmless (it is a display hint, not a gate).
- `inUserCountry` is the ready-made curation signal: the client shows
  `inUserCountry = true` providers by default and reveals the rest behind an
  "other countries" affordance — with **no second round-trip**.

### Handler

`listProvidersHandler` currently ignores the authenticated user and returns the
whole registry. It changes to:

1. Load the caller's configuration (`ConfigService.getConfigurationForUser uid`)
   and read `country :: Maybe Country`. This returns
   `Either DomainError ConfigurationData`; the `Left` branch is surfaced via
   `throwDomainError` (following the existing `loadConnection` pattern in the
   same module), not silently dropped.
2. Map each descriptor to a DTO, computing `inUserCountry` via
   `providerInCountry country d.coverage` and projecting `coverage` to
   `countries`.

`toBankProviderDTO` gains a `Maybe Country` argument for the computation; the
country is loaded **once** and threaded into the map over `Map.elems reg` (e.g.
`map (toBankProviderDTO country) …`), never re-fetched per descriptor. The
endpoint stays outside `requireBankingEnabled` (unchanged) — it is names +
capabilities + coverage, needed by the account-creation UI regardless of whether
banking sync is globally on.

**Annotate, not filter.** The endpoint returns the *full* enabled registry
annotated, rather than filtering server-side with a `?scope=all` opt-in. Since
scoping is soft (not a security boundary), there is no reason to make the server
the gatekeeper; one call returns everything the client needs to render both the
default and expanded views, and it keeps the wire contract client-driven.

## Change semantics & graceful degradation

- **User changes country.** Already-connected accounts and ongoing sync are
  untouched — there is no country gate anywhere on the connect/sync path, so
  nothing can break. Only the *default list curation* on the connect surface
  shifts. (Falls out for free from the soft-default model.)
- **No in-country providers.** A user whose country has no matching provider
  (e.g. any non-UA user today, since all three providers are UA) receives the
  full list with every `inUserCountry = false`. The client shows an empty
  in-country section plus the "show all" affordance; never a crash or an empty
  broken screen. Graceful by construction — no special-casing needed in the
  backend.

## Backward compatibility

No stored-event shape changes. `ProviderCoverage` is compiled-in infrastructure,
never persisted. The `country` configuration field was already added (with its
upcaster) in P1. The `BankProviderDTO` change is an **additive API change** — new
fields on a response DTO, no client breakage, no upcaster, no DB recreate.
`accountingSchemaRegistry` is unaffected.

## Testing

- **Pure / unit — `providerInCountry` truth table:**
  - `GlobalCoverage` → `True` for any country, including `Nothing`.
  - `RegionalCoverage {UA}` → `True` for `Just UA`, `False` for `Just US`.
  - `RegionalCoverage {UA}` → `True` for `Nothing` (show-everything).
  - Multi-country `RegionalCoverage {UA, PL}` → `True` for both `Just UA` and
    `Just PL`, `False` for `Just US`.
- **DTO projection — `toBankProviderDTO`:** sets `inUserCountry` and `countries`
  correctly for in-country / out-of-country / global / `Nothing`-country cases.
- **Integration — `GET …/banking/providers`:** the response reflects the caller's
  stored country: a UA user sees monobank + PrivatBank with `inUserCountry = true`;
  a US user sees all three with `inUserCountry = false`; a country-`Nothing` user
  sees all three with `inUserCountry = true`.
- Reuse existing Testkit fixtures (user registration + configuration with a
  country) rather than defining new setup helpers; add a generic helper to
  `Testkit` only if a country-configured user fixture is missing and generic.

## Deferred / follow-ups

- **Collapse compile-time provider selection to runtime-only** (remove the Cabal
  provider flags + CPP in `Infrastructure.Banking.Providers`, compile all
  providers in, gate purely at runtime). Considered during P2 brainstorming and
  deliberately **left as-is** — a distinct infra refactor with its own blast
  radius, to be specced separately if pursued for open-source readiness.
- **Per-user multi-country signal.** Not needed under the soft-default model;
  revisit only if the "show other countries" affordance proves insufficient in
  practice.
