---
status: draft
date: 2026-08-06
---

# Provider contact: one universal name-agnostic contact map (mirror of #51)

## Problem

Import resolves a transaction's contact by **matching the bank description text
against contact-dictionary names** — a two-tier exact-then-longest-substring match
(`resolveContact` / `matchContact`,
`src/Application/Services/BankImportService.hs:633,655`). Coupling matching to the
display name is wrong on two axes:

- **Names are provider-dependent.** The same merchant appears differently per bank:
  Monobank reports `MagazinREMONTI`, PrivatBank `Магазин РЕМОНТІ`. A contact named
  one way can never match statements from the other bank.
- **Users rename contacts.** The moment a user shortens/translates/nicknames a
  contact, description matching stops working — the resolver is matching against a
  name the user deliberately changed.

Net effect: fuzzy name matching is fragile, silently drops matches, and gets worse
the more the user curates their contact list.

This is the same defect #51 fixed for **categories** ("guess from text" → "providers
emit a name-agnostic signal persisted verbatim, resolved by one user-editable map").
This spec applies the identical foundation to **contacts**.

## Precedent — #51 (provider category-signal), and how contacts differ

#51 replaced MCC/label guessing with a single sum type `BankProviderCategory`
(`ByMcc | ByLabel`), persisted verbatim on `ImportInfo.category`, resolved by one
per-user `Map BankProviderCategory CategoryId`
(`docs/specs/2026-08-05-provider-category-signal-design.md`). We mirror its type,
naming, map, command/event, read-model table, persistence paths, and DTO surface.

Three deliberate differences from #51, each justified below:

1. **Single shape, so a newtype not a sum.** Categories arrive in two shapes (a
   numeric MCC or a provider label), which is the only reason `BankProviderCategory`
   is a sum. A contact arrives in exactly **one** shape — a token — so the faithful
   projection of the same pattern is a validated **newtype**
   (`newtype BankProviderContact = BankProviderContact Text`), with a plain-string
   JSON value (no `{kind,value}` tag — there is only one kind).
2. **Universal keyspace, not provider-scoped.** The map is **many-to-one** (many
   provider tokens → one user contact), so token collisions never break the logic:
   two colliding tokens simply both point at the same contact — which is what the
   map is *for*. This is exactly how #51's `ByLabel` keys already behave, so contacts
   inherit the same universal keyspace. (A provider-scoped key would only change an
   outcome in the rare case of the *same raw string, from two providers, meaning two
   different real counterparties*; the many-to-one model absorbs everything else. We
   keep the door open to add scoping later — cheap under the alpha DB-recreate
   policy — but do not build it now. See "What is NOT built".)
3. **No defaults, no seed, and name-matching is kept as a fallback.** Unlike
   categories there are **no universal contact defaults** — there is nothing
   standardizable to seed (the analog of MCC does not exist for counterparties). The
   map therefore starts **empty** and is 100% user-curated (consistent with the
   standing "imports never auto-create dictionary entries" rule). Because an empty
   map would otherwise regress every unmapped transaction to `NoContactMatch`, the
   existing description-name matching is **retained as a per-transaction fallback**
   rather than removed (this is a deliberate deviation from #54's checklist item
   "remove `matchContact`"; see §4).

## Design principle

**One type, one map, layered resolution.** The provider emits a name-agnostic
counterparty token, persisted verbatim on `ImportInfo`. Resolution first consults a
single user-editable `Map BankProviderContact ContactId`; on a miss it falls back to
the existing name matching; failing both it leaves the transaction contactless
(MATCH-ONLY — never auto-creates a contact).

## Design

### 1. The `BankProviderContact` type (domain)

Because it is persisted on the domain `ImportInfo`, it lives in
`src/Domain/Core/Types.hs`, beside `ImportInfo` and `BankProviderCategory`:

```haskell
-- | The name-agnostic token a provider reports to identify a transaction's
-- counterparty: the merchant/counterparty descriptor as the provider reports it
-- (@MagazinREMONTI@, @Магазин РЕМОНТІ@), or a more stable identifier (merchant id /
-- counterparty IBAN / EDRPOU) where a provider exposes one. Persisted verbatim; the
-- key of the user contact map. Universal keyspace — collisions are absorbed by the
-- many-to-one map, exactly as 'BankProviderCategory' @ByLabel@ keys are.
newtype BankProviderContact = BankProviderContact Text
  deriving (Eq, Ord, Show)   -- Ord is the map-key instance
```

Per project conventions (no exported constructors/selectors):

- Smart constructor `mkBankProviderContact :: Text -> Maybe BankProviderContact` —
  trims and rejects blank (mirrors `mkByLabel`); `unsafeBankProviderContact` for
  known-good literals (tests, wiring); accessor
  `bankProviderContactText :: BankProviderContact -> Text`.
- LiquidHaskell refinement mirroring the smart constructor's non-blank predicate,
  and exported measures/predicates, per the LH conventions in `CLAUDE.md`.
- Key form: `renderBankProviderContactKey` / `parseBankProviderContactKey`. Because
  there is a single case, the key **is** the trimmed token — no `label:`/`mcc:`
  prefix (that prefix existed only to disambiguate the category *sum*).
  `parseBankProviderContactKey` re-validates non-blank (drops blanks, like the
  category parser drops unparseable keys).
- JSON: **value** form is a plain string (`"Магазин РЕМОНТІ"`) via
  `ToJSON`/`FromJSON` over the trimmed token; **key** form via
  `ToJSONKey = toJSONKeyText renderBankProviderContactKey` and
  `FromJSONKey = FromJSONKeyTextParser (parseBankProviderContactKey …)` for
  serializing the map.

No `Domain.Banking.Types` import is needed — the type is universal (no
`BankProviderId`), so it stays purely in `Domain.Core.Types`.

### 2. The user-editable contact map (mirrors `bankProviderExpenseCategoryMap`)

```haskell
-- BankingConfiguration (Domain/Configuration/Projection.hs)
bankProviderContactMap :: !(Map BankProviderContact ContactId)   -- ContactId = DictionaryEntryId
```

- `emptyBankingConfiguration` seeds it to `Map.empty` (no defaults — §3).
- **Command** `SetBankProviderContactMap { mapping :: Map BankProviderContact ContactId }`
  (`Domain/Configuration/Commands.hs`), mirror of `SetBankProviderExpenseCategoryMap`.
- **Event** `BankProviderContactMapSet { mapping :: Map BankProviderContact ContactId }`
  (`Domain/Configuration/Events.hs`), mirror of `BankProviderExpenseCategoryMapSet`.
- **Command handler** (`Domain/Configuration/CommandHandler.hs`) validates every map
  value exists in the **contact** dictionary (`requireEntryIn contactsDictKind`)
  before emitting the event; adds the delete-guard pair
  (`isInBankProviderContactMap` guard + `EntryIsInBankProviderContactMap` error) so a
  contact still referenced by the map cannot be deleted — the same safety the
  category map has (`isInBankProviderExpenseCategoryMap` /
  `EntryIsInBankProviderExpenseCategoryMap`).
- **Projection** replaces the whole map on the event (**set-semantics**, matching
  #51): `config {banking = config.banking {bankProviderContactMap = evt.mapping}}`.
  Per-entry add/re-point/remove is an additive endpoint left for later (see "What is
  NOT built").

### 3. No defaults, no seed

Unlike #51 there is **no `CategoryDefaults` analog, no per-provider `labelContacts`
binding, and no new `TransactionInterpretation` field**. `ConfigurationService`
seeds nothing for contacts; a fresh (and cloned) config starts with an **empty**
`bankProviderContactMap`. This is a genuine simplification over #51.

### 4. Resolution (layered ladder; name matching kept as fallback)

`resolveContact` gains the `BankingConfiguration` and the incoming
`Maybe BankProviderContact` signal, keeps the description, and resolves in order
(Income/Expense only; Transfer/Adjustment → `NoContactMatch`, unchanged):

1. **Map hit** — a signal is present, `Map.lookup sig banking.bankProviderContactMap`
   hits, and the hit still exists in the contact dictionary → `MatchedByMap cid`.
2. **Name-match fallback** — otherwise run the existing exact-then-longest-substring
   `matchContact` against the description → `MatchedByName cid` on a unique match.
3. Neither → `NoContactMatch` (MATCH-ONLY preserved; raw description stays the memo;
   no contact is ever auto-created).

`ContactResolution` grows the map-vs-name distinction — the existing single matched
case `MatchedExisting !ContactId` (`BankImportService.hs:618`) is **renamed** to
`MatchedByName` and a new `MatchedByMap` is added:

```haskell
data ContactResolution
  = MatchedByMap !ContactId    -- resolved via bankProviderContactMap
  | MatchedByName !ContactId   -- resolved via description name matching (fallback)
  | NoContactMatch
```

The command call site (`BankImportService.hs:1034`, today
`MatchedExisting cid -> Just cid; NoContactMatch -> Nothing`) must now map **both**
matched constructors to `Just cid`.

Note this stays a **pure `ContactResolution`** — unlike `resolveCategory`, which
returns `Either DomainError (CategoryId, CategoryResolution)`, contact resolution has
no direction-default and thus no error path, so no `Either`/id-tuple. This is
intentional parity with the current code, not a missed mirror.

`matchContact` and `normalizeName` are **retained** (deviation from #54's "remove
`matchContact`", justified in "Precedent" above). `logContactResolution`
(`BankImportService.hs:683`) is re-rendered to show which path fired
(`resolution=MapHit|NameMatch|NoMatch`) and the token (`contact=<token>` / `none`),
mirroring `logCategoryResolution`.

Both the command-threaded resolved `contactId` (from tracker#41,
`BankImportService.hs:1032`) and the fallback continue to work; the map hit simply
takes priority when present.

### 5. Persistence (event-shape change, both paths, faithful)

The raw signal is stored **verbatim**; the *resolved* `contactId` keeps flowing to
the posting command exactly as today.

- `ImportInfo` (`Domain/Core/Types.hs:1561`) gains `contact` alongside `category`:

  ```haskell
  data ImportInfo = ImportInfo
    { externalTransactionIds :: NonEmpty ExternalTransactionId,
      category :: Maybe BankProviderCategory,
      contact :: Maybe BankProviderContact          -- new
    }
  ```

  with an `importInfoContact` accessor (the bare field name `contact` is ambiguous
  under `DuplicateRecordFields`, exactly like `importInfoCategory`). Constructed from
  `bankTx.contact` in `commitMatchingCurrencyImport` (`BankImportService.hs:1025`).
- **Reconcile path (net-new plumbing).** Contacts are resolved on direct import only
  today; the reconcile event carries no contact. For full #51 parity we add contact
  carriage:
  - `ReconcileTransactionImport` command (`Domain/Transaction/Commands.hs:522`) gains
    `contact :: Maybe BankProviderContact`.
  - `TransactionImportReconciled` event (`Domain/Transaction/Events.hs:428`) gains
    `contact :: Maybe BankProviderContact`.
  - `attemptReconcile` (`BankImportService.hs:906`) forwards `tx.contact` through
    `reconcileTransactionImport` (`TransactionService.hs:583`); the transfer-pair
    caller passes `Nothing` (as it does for `category`).

### 6. `BankTransaction` + providers

`BankTransaction` (`Infrastructure/Banking/Provider.hs:60`) gains
`contact :: !(Maybe BankProviderContact)`. Providers populate it from the most stable
counterparty token they expose, via `mkBankProviderContact` (blank → `Nothing`):

- **PrivatBank** (`PrivatBank/Internal.hs`): the counterparty/merchant descriptor
  column from the CSV row. Own-card transfers (already self-labeled
  `На свою картку *NNNN`) are transfer-classified and resolve to `NoContactMatch`
  regardless.
- **Monobank** (`Monobank/Internal.hs`): the counterparty string the statement
  provides (merchant description), `Nothing` when absent.

Exact source columns are pinned in the implementation plan against each provider's
`Internal.hs`. **No `TransactionInterpretation` change** (there is no seed to feed —
§3).

### 7. DTO / API surface

Two breaking DTO changes, requiring a matching web-client update (`../monorepo`,
tracked in #54's web scope):

- **Transaction DTO** gains `bankProviderContact :: Maybe BankProviderContact`,
  surfaced as a plain string (or `null`) by reusing the domain `ToJSON`
  (`Web/Types.hs`, beside `bankProviderCategory`). Backed by a new
  `TransactionData.providerContact` and a transaction read-model column
  `bankProviderContact Text Maybe`
  (`Application/ReadModels/Transaction.hs`), populated from
  `ImportInfo`/`TransactionImportReconciled` via `renderBankProviderContactKey` and
  read back via `parseBankProviderContactKey` — mirroring
  `bankProviderCategory`. This lets the client show an unmapped token and offer "map
  this token to a contact".
- **Banking-config DTO** gains `contactMap :: Map Text UUID` nested under `banking`
  (short name alongside `expenseCategoryMap`, `Web/API/ConfigurationAPI.hs`). Encode
  via `renderBankProviderContactKey`; the update request decodes/validates each key
  via `parseBankProviderContactKey`, then `ConfigurationService` issues
  `SetBankProviderContactMap`.

### 8. Read-model table (Configuration)

New entity in the existing `persistLowerCase` quasi-quote
(`Application/ReadModels/Configuration.hs:227`), mirroring
`ConfigBankProviderExpenseCategoryEntity`:

```
ConfigBankProviderContactEntity sql=configuration_bank_provider_contacts
    configId ConfigurationId
    bankProviderContact Text
    contactId DictionaryEntryId
    UniqueConfigBankProviderContact configId bankProviderContact
```

- Added to `resetConfiguration`.
- The `BankProviderContactMapSet` event branch deletes all rows for the config then
  re-inserts one per entry, keyed by `renderBankProviderContactKey`.
- Reconstructed on load via `Map.fromList` parsing keys with
  `parseBankProviderContactKey` (unparseable/blank keys dropped).
- Auto-migrated by `migrateConfiguration` (run in `initialize`) — no separate SQL
  migration file.

## Backward compatibility & migration

This alters stored-event shape (`ImportInfo.contact`,
`TransactionImportReconciled.contact`, new `BankProviderContactMapSet`), the
Configuration read-model table, and the DTO — **not** backward compatible. Per the
standing alpha policy (beta-testers only; disposable data), take the **documented
one-time DB-recreate exception** rather than shipping upcasters — folding into #51's
reset if landed together:

- `accountingSchemaRegistry` stays empty (no upcasters); the registry/codec seam is
  retained so the first post-launch shape change re-activates upcast-on-read.
- Record the exception in `CLAUDE.md`'s recorded-exception note (extend #51's) and in
  the deployment runbook (fold into #51's reset).

## What is NOT built (and the additive door)

- **Provider-scoped keys.** The key is universal now; adding `BankProviderId` scoping
  later is a key-shape change, cheap under the alpha DB-recreate policy. Only needed
  for the rare "same raw string, two providers, two different real counterparties"
  case.
- **Per-entry map config.** Whole-map replace now (matches #51); an incremental
  add/re-point/remove endpoint for large contact maps is an additive follow-up.
- **Auto-suggesting a contact for an unmapped token** (name-similarity hint in the
  UI) — later. The backend surfaces the raw token; the client decides.
- **Non-UA providers** — with #53's provider expansion.

## Testing (TDD; mirrors #51)

- **Schema/round-trip** (`Infrastructure.Eventium.SchemaSpec`): committed stored-JSON
  fixtures for the new `ImportInfo`-with-contact,
  `TransactionImportReconciled`-with-contact, and `BankProviderContactMapSet` shapes
  decode → re-encode → round-trip; `BankProviderContact` value **and** key JSON
  round-trip.
- **Resolution** (`BankImportServiceSpec`): map hit resolves via
  `bankProviderContactMap`; unmapped/absent signal falls back to name matching;
  name-match miss → `NoContactMatch`; not-in-dict map value falls back; Income/Expense
  gating (Transfer/Adjustment → `NoContactMatch`). Explicitly assert the fallback
  ladder order (map beats name).
- **Config** (`ConfigurationService` / `CommandHandler`): `SetBankProviderContactMap`
  validates values in the contact dictionary; delete-guard rejects removing a
  referenced contact; fresh config's map is empty.
- **Provider population** (`PrivatBankSpec`, `MonobankSpec`): a counterparty row
  yields `Just (BankProviderContact …)`; blank → `Nothing`; own-card transfer stays
  contactless.
- **Domain** (`Domain.Core.TypesSpec`): `mkBankProviderContact` trims/rejects blank;
  value + key round-trip properties.
- **DTO** (`Web.TypesSpec`, `ConfigurationBankingAPISpec`): transaction
  `bankProviderContact` encodes a token and `null`; banking `contactMap` encode/decode
  round-trips and validates keys.
- **Fixture churn:** adding `contact` to `ImportInfo` and `BankTransaction` breaks
  every `ImportInfo`/`BankTransaction` literal — `Testkit/BankingHelpers.hs`,
  `Integration/BankImportWorkflowSpec.hs`, `BankImportServiceSpec.hs`,
  `PrivatBankSpec.hs`, `MonobankSpec.hs`, and the read-model/schema specs.
- TDD: red before green.

## Layering check

- `BankProviderContact` is a **domain** type (`Domain.Core.Types`), no
  provider/native-language literals, no `Domain.Banking.Types` dependency.
- No new Infrastructure defaults module (no seed).
- `resolveContact` reads only the `BankingConfiguration` it already receives plus the
  transaction's signal/description — no provider dependency, no threading.
- Command/event/read-model changes are confined to the Configuration and Transaction
  bounded contexts and the Web layer, matching #51's edges exactly.
