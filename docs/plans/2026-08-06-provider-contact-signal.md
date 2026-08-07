# Provider Contact Signal — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace description-name-only contact matching with a name-agnostic `BankProviderContact` signal, persisted verbatim and resolved through a single user-editable `bankProviderContactMap`, with the existing name matching kept as a per-transaction fallback.

**Architecture:** `BankProviderContact` is a validated `newtype` over `Text` in `Domain.Core.Types` (universal keyspace; mirrors `BankProviderCategory` but single-shape). Providers emit it on `BankTransaction.contact`; it is persisted verbatim on `ImportInfo.contact` and on the reconcile event. Resolution is a layered ladder — a lookup in the per-user `Map BankProviderContact ContactId`, then the existing `matchContact` name fallback, then `NoContactMatch`. The map is user-editable via a Configuration command/event and a `configuration_bank_provider_contacts` read-model table; it starts empty (no seed).

**Tech Stack:** GHC 9.10, RIO, Servant, eventium (event sourcing), LiquidHaskell, Hspec/QuickCheck, ormolu/hlint. Build/test via `nix develop --command` + `just`.

**Scope:** Backend only (tracker#54 backend). The web client DTO changes (`../monorepo`) are separate. Migration uses the **one-time alpha DB recreate** — no upcasters (`accountingSchemaRegistry` is already empty from #51).

**Reference:** spec `docs/specs/2026-08-06-provider-contact-signal-design.md`. The directly analogous shipped feature is #51 (`docs/specs/2026-08-05-provider-category-signal-design.md`, commit `190dcf0`) — copy its `BankProviderCategory` / `bankProviderExpenseCategoryMap` machinery, adapting for the single-shape/universal/no-seed/fallback differences.

**Conventions for every code task:** follow TDD (write failing test → run it red → implement → run green → commit). Build/test with `nix develop --command bash -c "just build && cabal test all --test-show-details=direct …"`. No exported data constructors/selectors (smart constructors + accessors). Domain types carry LiquidHaskell refinements. Run `just format` + `hlint` before each commit. `just rebuild` for a definitive `-fci`/`-Werror` check. Do **not** put issue/ticket numbers in test titles (behaviour names only).

---

## Task 0: Baseline

**Files:** none (branch `feat/provider-contact-signal` already created off master; spec already committed).

- [ ] **Step 1:** Confirm on branch `feat/provider-contact-signal` and that `docs/specs/2026-08-06-provider-contact-signal-design.md` is committed.
- [ ] **Step 2: Sanity build/test** a clean baseline.

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/BankImport/'"`
Expected: PASS (baseline contact resolution behaviour).

---

## Task 1: `BankProviderContact` newtype (domain)

Foundational — every later task uses it. Lives beside `ImportInfo` / `BankProviderCategory` in `Domain.Core.Types`. Directly mirror `BankProviderCategory` (`src/Domain/Core/Types.hs:733-825`) but single-case: newtype, plain-string value JSON, key form is the trimmed token (no `label:` prefix).

**Files:**
- Modify: `src/Domain/Core/Types.hs` (type + exports, near the `BankProviderCategory` block)
- Test: `test/Domain/Core/TypesSpec.hs`

- [ ] **Step 1: Write failing tests** (mirror the `BankProviderCategory` round-trip tests):

```haskell
describe "BankProviderContact" $ do
  it "trims and rejects a blank token" $ do
    fmap bankProviderContactText (mkBankProviderContact "  Магазин РЕМОНТІ  ")
      `shouldBe` Just "Магазин РЕМОНТІ"
    mkBankProviderContact "   " `shouldBe` Nothing
    mkBankProviderContact "" `shouldBe` Nothing
  it "value JSON round-trips as a plain string" $
    decode (encode (unsafeBankProviderContact "Магазин РЕМОНТІ"))
      `shouldBe` Just (unsafeBankProviderContact "Магазин РЕМОНТІ")
  it "map-key JSON round-trips the token verbatim" $ do
    let m = Map.singleton (unsafeBankProviderContact "IVAN") (unsafeDictionaryEntryId …)
    decode (encode m) `shouldBe` Just m
  it "key render/parse round-trips a token containing a colon" $
    parseBankProviderContactKey (renderBankProviderContactKey (unsafeBankProviderContact "a:b"))
      `shouldBe` Just (unsafeBankProviderContact "a:b")
```

- [ ] **Step 2: Run red.**

Run: `nix develop --command bash -c "cabal test all --test-show-details=direct --test-option='--match' --test-option='/BankProviderContact/'"`
Expected: FAIL (`mkBankProviderContact` etc. undefined).

- [ ] **Step 3: Implement** in `Domain.Core.Types` (mirror the `BankProviderCategory` idioms, incl. the `RIO`/`NoImplicitPrelude` imports `object`, `withText`, `toJSONKeyText`, `FromJSONKeyTextParser` already imported for `BankProviderCategory`):

```haskell
-- | The name-agnostic token a provider reports to identify a transaction's
-- counterparty (a merchant/counterparty descriptor as the provider reports it,
-- e.g. @MagazinREMONTI@ / @Магазин РЕМОНТІ@, or a more stable id such as a
-- counterparty IBAN / EDRPOU where a provider exposes one). Persisted verbatim;
-- the key of the user contact map ('bankProviderContactMap').
--
-- Universal keyspace (not provider-scoped): the map is many-to-one, so token
-- collisions are harmless — colliding tokens simply point at the same contact.
-- JSON value form is the plain trimmed string; the map-key form is the same
-- token verbatim.
newtype BankProviderContact = BankProviderContact Text
  deriving (Eq, Ord, Show)

-- | Smart constructor: trims surrounding whitespace and rejects a blank token.
mkBankProviderContact :: Text -> Maybe BankProviderContact
mkBankProviderContact t
  | T.null trimmed = Nothing
  | otherwise = Just (BankProviderContact trimmed)
  where
    trimmed = T.strip t

-- | Bypass validation. For known-good literals / tests / wiring only.
unsafeBankProviderContact :: Text -> BankProviderContact
unsafeBankProviderContact = BankProviderContact

-- | The underlying token.
bankProviderContactText :: BankProviderContact -> Text
bankProviderContactText (BankProviderContact t) = t

-- | Map-key text form. Single case → the token itself.
renderBankProviderContactKey :: BankProviderContact -> Text
renderBankProviderContactKey = bankProviderContactText

-- | Parse the map-key text form, re-validating non-blank.
parseBankProviderContactKey :: Text -> Maybe BankProviderContact
parseBankProviderContactKey = mkBankProviderContact

instance ToJSON BankProviderContact where
  toJSON = toJSON . bankProviderContactText

instance FromJSON BankProviderContact where
  parseJSON = withText "BankProviderContact" $ \t ->
    maybe (fail "BankProviderContact must not be blank") pure (mkBankProviderContact t)

instance ToJSONKey BankProviderContact where
  toJSONKey = toJSONKeyText renderBankProviderContactKey

instance FromJSONKey BankProviderContact where
  fromJSONKey =
    FromJSONKeyTextParser $ \t ->
      maybe (fail ("Invalid BankProviderContact key: " <> T.unpack t)) pure (parseBankProviderContactKey t)
```

  Add a LiquidHaskell refinement mirroring the non-blank predicate (mirror the LH pattern on `mkByLabel`/other smart ctors in this module; export the measure). Export (no constructor): `BankProviderContact, mkBankProviderContact, unsafeBankProviderContact, bankProviderContactText, renderBankProviderContactKey, parseBankProviderContactKey` in the module export list beside the `BankProviderCategory` exports (`Types.hs:69-81`).

- [ ] **Step 4: Run green.**

Run: `nix develop --command bash -c "cabal test all --test-show-details=direct --test-option='--match' --test-option='/BankProviderContact/'"`
Expected: PASS.

- [ ] **Step 5: format + lint + commit.**

```bash
nix develop --command bash -c "just format && just lint"
git commit -am "feat(core): BankProviderContact newtype with value+key JSON (tracker#54)"
```

---

## Task 2: User contact map — Configuration command / event / projection / delete-guard

Additive and self-contained (compiles green on its own). Mirror the category map exactly (`bankProviderExpenseCategoryMap`), swapping `CategoryId`→`ContactId` and the expense-dictionary validation for the **contact** dictionary. `ContactId = DictionaryEntryId`; the contact dictionary kind is `ConfigurationService.contactsDictKind = ContactKind`.

**Files:**
- Modify: `src/Domain/Configuration/Projection.hs` (`BankingConfiguration` ~L95-98; `emptyBankingConfiguration` ~L127-130; `handleConfigurationEvent` ~L340)
- Modify: `src/Domain/Configuration/Commands.hs` (mirror `SetBankProviderExpenseCategoryMap` ~L217; `deriveJSON` ~L341)
- Modify: `src/Domain/Configuration/Events.hs` (mirror `BankProviderExpenseCategoryMapSet` ~L204; `deriveJSON` ~L297; and the event sum/constructor + tag)
- Modify: `src/Domain/Configuration/CommandHandler.hs` (mirror the category handler ~L438-446; guard `isInBankProviderExpenseCategoryMap` ~L252; add `EntryIsInBankProviderContactMap` as a constructor of the **local `ConfigurationError` type** ~L81 beside `EntryIsInBankProviderExpenseCategoryMap` — it is NOT in `Domain/Core/Errors.hs`; the delete handler references it ~L365). No `translateConfigurationError` change needed — its catch-all `other -> ConfigurationError (…)` already maps new `ConfigurationError` constructors, exactly as the category sibling relies on.
- Test: `test/Domain/Configuration/{ProjectionSpec,CommandHandlerSpec}.hs`

- [ ] **Step 1: Write failing tests** in `CommandHandlerSpec`:
  - `SetBankProviderContactMap` whose every value is in the contact dictionary emits `BankProviderContactMapSet` with that mapping.
  - `SetBankProviderContactMap` with a value **not** in the contact dictionary is rejected (validation error).
  - Deleting a contact dictionary entry still referenced by `bankProviderContactMap` is rejected with `EntryIsInBankProviderContactMap`.
  - `ProjectionSpec`: applying `BankProviderContactMapSet` replaces the whole `bankProviderContactMap` (set-semantics); `emptyBankingConfiguration` has an empty map.

- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement** the mirror:
  - `BankingConfiguration` gains `bankProviderContactMap :: !(Map BankProviderContact ContactId)`; `emptyBankingConfiguration` sets it to `Map.empty`.
  - Command `SetBankProviderContactMap { mapping :: Map BankProviderContact ContactId }`; event `BankProviderContactMapSet { mapping :: Map BankProviderContact ContactId }` (both `deriveJSON defaultOptions`); wire the event into the Configuration event sum + tag exactly like the category event.
  - `handleConfigurationEvent … (BankProviderContactMapSet evt) = config {banking = config.banking {bankProviderContactMap = evt.mapping}}`.
  - Command handler: validate every map value with `requireEntryIn contactsDictKind` (mirror the category handler), then emit; add the `isInBankProviderContactMap` delete-guard + `EntryIsInBankProviderContactMap` error to the dictionary-entry-delete handler beside the existing category guard.
- [ ] **Step 4: Run green.**

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/Configuration/'"`
Expected: PASS.

- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "feat(config): user bankProviderContactMap command/event + delete-guard (tracker#54)"
```

---

## Task 3: Configuration read-model table `configuration_bank_provider_contacts`

Additive; mirror `ConfigBankProviderExpenseCategoryEntity` (`src/Application/ReadModels/Configuration.hs`).

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs` (entity in the `persistLowerCase` quasi-quote ~L253-258; `resetConfiguration` ~L288; event branch ~L390-394; load/reconstruct ~L553-558; module-header table docstring ~L22-49)
- Test: `test/Application/ReadModels/*ConfigurationReadModel*Spec.hs` (or the existing Configuration read-model spec) — integration (needs `eventium_test` DB)

- [ ] **Step 1: Write failing test** (integration): after emitting `BankProviderContactMapSet {mapping}`, loading the configuration read model yields a `bankProviderContactMap` equal to `mapping`; a subsequent `Set` with a different map fully replaces the rows.
- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement**:

```
ConfigBankProviderContactEntity sql=configuration_bank_provider_contacts
    configId ConfigurationId
    bankProviderContact Text
    contactId DictionaryEntryId
    UniqueConfigBankProviderContact configId bankProviderContact
```

  - Add to `resetConfiguration` (delete all rows for the config).
  - Event branch for `BankProviderContactMapSet`: delete all rows for the config, then insert one per entry keyed by `renderBankProviderContactKey pc`.
  - Load path: `Map.fromList` over rows parsing the text key with `parseBankProviderContactKey` (drop unparseable/blank), assembled into `bankProviderContactMap`.
  - Update the module-header table docstring.
  - Migration is automatic (`migrateConfiguration` in `initialize`) — no SQL file.
- [ ] **Step 4: Run green** (needs a running Postgres + `eventium_test` DB; see CLAUDE.md caveat).
- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "feat(config): configuration_bank_provider_contacts read-model table (tracker#54)"
```

---

## Task 4: `BankTransaction.contact` + providers populate it

Adding a field to `BankTransaction` breaks every literal (providers, Testkit, specs). Land the field + provider population + literal fixups together for a green build.

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs` (`BankTransaction` ~L60-81 — add `contact`)
- Modify: `src/Infrastructure/Banking/Monobank/Internal.hs` (build `contact`)
- Modify: `src/Infrastructure/Banking/PrivatBank/Internal.hs` (build `contact` in `validateRow` ~L141, beside `category`)
- Modify: `test/Testkit/BankingHelpers.hs` (shared `BankTransaction` builder — default `contact = Nothing`)
- Test: `test/Infrastructure/Banking/{MonobankSpec,PrivatBankSpec}.hs`

- [ ] **Step 1: Write failing tests:**
  - PrivatBank: a row with a counterparty descriptor yields `tx.contact == mkBankProviderContact "<descriptor>"`; a blank descriptor yields `Nothing`; an own-card transfer row stays a transfer (contact irrelevant / `NoContactMatch` downstream).
  - Monobank: a statement with a counterparty description yields `tx.contact == mkBankProviderContact "<description>"`; absent → `Nothing`.

```haskell
it "carries the PrivatBank counterparty descriptor as a contact signal" $
  case parsePrivatBankCsv (mkCsv [rowWithDescription "Магазин РЕМОНТІ"]) of
    Right [Right tx] -> tx.contact `shouldBe` mkBankProviderContact "Магазин РЕМОНТІ"
    _ -> expectationFailure "expected one parsed row"
```

- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement:**
  - Add `contact :: !(Maybe BankProviderContact)` to `BankTransaction` (with a haddock like the `category` field).
  - **PrivatBank** `validateRow`: `contact = mkBankProviderContact <counterparty/merchant column>` — confirm the exact source column against `PrivatBank/Internal.hs` (the description/merchant field; the same raw text that becomes `description`, or a dedicated counterparty column if present). Own-card transfers are already transfer-classified upstream.
  - **Monobank** `Internal.hs`: `contact = mkBankProviderContact <counterparty description>` (the merchant/description the statement provides), `Nothing` when absent.
  - `Testkit/BankingHelpers.hs`: default `contact = Nothing` in the shared builder; fix any other `BankTransaction` literals the compiler flags (`test/Testkit/Helpers.hs` if it has one, integration specs).
- [ ] **Step 4: Run green.**

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/PrivatBank/' --test-option='--match' --test-option='/Monobank/'"`
Expected: PASS.

- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "feat(banking): BankTransaction carries contact signal; providers populate it (tracker#54)"
```

---

## Task 5: Persist the signal on both paths — `ImportInfo.contact` + reconcile carriage

Adding `contact` to `ImportInfo` breaks its literals; adding it to the reconcile command/event is net-new plumbing (contacts were direct-import-only). Land together for a green build.

**Files:**
- Modify: `src/Domain/Core/Types.hs` (`ImportInfo` ~L1561-1580 — add `contact` + `importInfoContact` accessor)
- Modify: `src/Domain/Transaction/Commands.hs` (`ReconcileTransactionImport` ~L522-525 — add `contact`; `deriveJSON` ~L552)
- Modify: `src/Domain/Transaction/Events.hs` (`TransactionImportReconciled` ~L428-439 — add `contact`; `deriveJSON` ~L465)
- Modify: `src/Domain/Transaction/CommandHandler.hs` (forward `contact` command→event, mirror `category`)
- Modify: `src/Application/Services/TransactionService.hs` (`reconcileTransactionImport` ~L583-598 — thread `contact`)
- Modify: `src/Application/Services/BankImportService.hs` (`ImportInfo` construction in `commitMatchingCurrencyImport` ~L1025-1030; the transfer-pair `ImportInfo` construction — pass `contact = Nothing`, mirror `category`; `attemptReconcile` ~L906 forwards `tx.contact`; caller ~L875 passes `tx.contact`, transfer-pair caller ~L382 passes `Nothing`)
- Test: `test/Domain/Transaction/{EventsSpec,CommandHandlerSpec}.hs`, reconcile spec

- [ ] **Step 1: Write failing tests:** `ReconcileTransactionImport` carrying a `contact` forwards it onto `TransactionImportReconciled`; command/event JSON round-trip includes `contact` for both `Just`/`Nothing`.
- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement:**
  - `ImportInfo` gains `contact :: Maybe BankProviderContact` (after `category`); add accessor:

```haskell
-- | The provider contact signal carried by an import, if the provider supplied one.
importInfoContact :: ImportInfo -> Maybe BankProviderContact
importInfoContact ImportInfo {contact = c} = c
```

  Export `importInfoContact` beside `importInfoCategory`.
  - `commitMatchingCurrencyImport`: `ImportInfo { externalTransactionIds = …, category = bankTx.category, contact = bankTx.contact }`.
  - Transfer-pair `ImportInfo` construction: `contact = Nothing` (mirror `category = Nothing`).
  - `ReconcileTransactionImport` + `TransactionImportReconciled` gain `contact :: Maybe BankProviderContact`; `CommandHandler` forwards it; `reconcileTransactionImport` gains a `contact` parameter threaded onto the command; `attemptReconcile` forwards `tx.contact` (transfer-pair caller `Nothing`).
- [ ] **Step 4: Run green.**

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/Transaction/'"`
Expected: PASS.

- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "feat(import): persist contact signal on ImportInfo and reconcile event (tracker#54)"
```

> **Audit-history parity (no code needed):** `HistoryImportReconciled` wraps the whole `TransactionImportReconciled` value (`TransactionHistoryService.hs:121`), so the added `contact` field auto-carries through the pattern match and derived JSON — the CLAUDE.md audit-history-parity rule is already satisfied, no `toHistoryEntry` change. Confirm with a grep, don't add a mapping.

---

## Task 6: Resolution ladder — map hit → name fallback → NoContactMatch

The behavioural core. `resolveContact` gains the `BankingConfiguration` and the `Maybe BankProviderContact` signal, keeps the description, and layers the map lookup over the retained `matchContact`.

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (`ContactResolution` ~L616-622; `resolveContact` ~L633-638; `matchContact` ~L655-676 — **kept**; `logContactResolution` ~L683-699; the `commitMatchingCurrencyImport` call site ~L975 and the command `contactId` mapping ~L1032-1034)
- Test: `test/Application/Services/BankImportServiceSpec.hs`

- [ ] **Step 1: Write failing tests** in `BankImportServiceSpec`, asserting the ladder order:
  - Signal present AND in `bankProviderContactMap` AND value in contact dictionary → `MatchedByMap cid` (and takes priority even when the description would also name-match a *different* contact).
  - Signal present but unmapped → falls back to `matchContact` on the description (`MatchedByName` when the description matches, else `NoContactMatch`).
  - No signal (`Nothing`) → name-match fallback (proves the empty-map / unmapped path preserves today's behaviour).
  - Map value not in the contact dictionary → falls back to name matching.
  - `TransferKind` / `AdjustmentKind` → `NoContactMatch` regardless of signal.

- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement:**

```haskell
data ContactResolution
  = -- | Resolved via the user's bankProviderContactMap (the provider signal).
    MatchedByMap !ContactId
  | -- | Resolved via description name matching (fallback).
    MatchedByName !ContactId
  | -- | No contact resolved (or does not apply to this transaction's kind).
    NoContactMatch
  deriving (Show, Eq)

-- Income/Expense only; Transfer/Adjustment never get a contact.
resolveContact ::
  BankingConfiguration ->
  ConfigurationData ->
  TransactionKind ->
  Maybe BankProviderContact ->
  Text ->
  ContactResolution
resolveContact banking cfg kind signal description = case kind of
  TransferKind -> NoContactMatch
  AdjustmentKind -> NoContactMatch
  IncomeKind -> resolve
  ExpenseKind -> resolve
  where
    resolve = case mapHit of
      Just cid -> MatchedByMap cid
      Nothing -> case matchContact cfg description of
        MatchedByName cid -> MatchedByName cid
        _ -> NoContactMatch
    -- map hit only when the signal is present, mapped, and still in the dict
    mapHit = do
      sig <- signal
      cid <- Map.lookup sig banking.bankProviderContactMap
      if existsInContactDict cfg cid then Just cid else Nothing
```

  - `matchContact` is **retained**; retype its result to return `MatchedByName`/`NoContactMatch` (it currently returns `MatchedExisting`; rename that constructor usage to `MatchedByName`). `normalizeName` unchanged.
  - Add `existsInContactDict :: ConfigurationData -> ContactId -> Bool` (mirror the category `existsInDict` in-dictionary check against `contactsDictKind`).
  - `logContactResolution`: extend the tag to `MapHit` / `NameMatch` / `NoMatch` and add a `contact=<token>` field (`renderBankProviderContactKey` of the signal, or `none`), mirroring `logCategoryResolution`.
  - Call site (`~L975`): `contactResolution = resolveContact cfg.banking cfg (kindOf transactionType) tx.contact tx.description`.
  - Command `contactId` mapping (`~L1032-1034`): both matched constructors → `Just cid`:

```haskell
contactId = case contactResolution of
  MatchedByMap cid -> Just cid
  MatchedByName cid -> Just cid
  NoContactMatch -> Nothing,
```

- [ ] **Step 4: Run green.**

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/BankImportService/'"`
Expected: PASS.

- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "feat(import): layered contact resolution (map hit → name fallback) (tracker#54)"
```

---

## Task 7: DTO / API surface

Two DTO changes: surface the raw signal on the transaction (so the client can offer "map this token"), and expose the config map for editing. Mirror `bankProviderCategory` / `expenseCategoryMap`.

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs` (persistent column `bankProviderContact Text Maybe` beside `bankProviderCategory` ~L243; posting-initiated consumer ~L333 writes `renderBankProviderContactKey <$> (evt.importInfo >>= importInfoContact)`; reconciled consumer ~L356-365 `(renderBankProviderContactKey <$> evtContact) <|> existing`; `TransactionData.providerContact` ~L170 read back via `parseBankProviderContactKey` ~L430)
- Modify: `src/Web/Types.hs` (`TransactionResponse` gains `bankProviderContact :: Maybe BankProviderContact` beside `bankProviderCategory` ~L681-686; `fromTransactionData` ~L1161 populates it; legacy `fromTransaction` ~L1196 → `Nothing`)
- Modify: `src/Web/API/ConfigurationAPI.hs` (`BankingConfigurationDTO` gains `contactMap :: Map Text UUID` beside `expenseCategoryMap` ~L309; encode via `renderBankProviderContactKey` ~L387; update request `contactMap :: Maybe (Map Text UUID)` ~L559; decode/validate keys via `parseBankProviderContactKey` ~L714-722, then issue `SetBankProviderContactMap`)
- Test: `test/Web/TypesSpec.hs`, `test/Web/API/ConfigurationBankingAPISpec.hs`

- [ ] **Step 1: Write failing tests:**
  - Transaction DTO encodes `bankProviderContact` as a plain string token and as `null`.
  - Banking config DTO `contactMap` encode/decode round-trips; an invalid (blank) key is rejected on decode.
- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement** the mirror (persistent column + `TransactionData.providerContact` + both read-model consumers; `TransactionResponse.bankProviderContact`; config DTO `contactMap` read/write path issuing `SetBankProviderContactMap`).
- [ ] **Step 4: Run green.**

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/Web/'"`
Expected: PASS.

- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "feat(web): surface bankProviderContact DTO + banking contactMap endpoint (tracker#54)"
```

> Client (`../monorepo`) consumes this — out of scope here; coordinate separately (#54 web scope).

---

## Task 8: Schema fixtures + migration docs

No dead-upcaster removal (registry already empty from #51). Add committed stored-JSON fixtures + round-trip tests for the new shapes, and record the migration.

**Files:**
- Create: `test/fixtures/events/transaction-import-reconciled-contact.json`, `test/fixtures/events/bank-provider-contact-map-set.json` (copy the category fixtures' structure)
- Modify: `test/fixtures/events/transaction-posting-initiated-import.json` (add `"contact"` to `importInfo`) and `test/fixtures/events/transaction-import-reconciled*.json` (add `"contact"`)
- Modify: `test/Infrastructure/Eventium/SchemaSpec.hs` (add contact round-trip cases beside the category ones ~L102-168)
- Modify: `CLAUDE.md` (extend the #51 recorded-exception note to cover the contact shapes)
- Modify: `docs/deployment.md` (fold the data reset into #51's note)

- [ ] **Step 1: Write failing round-trip tests** in `SchemaSpec`: a `TransactionPostingInitiated` whose `importInfo.contact = Just (BankProviderContact "Магазин РЕМОНТІ")`; a `TransactionImportReconciled` with a `contact`; a `BankProviderContactMapSet` with token keys — each decodes from its fixture, re-encodes at the current schema, and reads back. Cover `BankProviderContact` value **and** key JSON.
- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement** the fixtures (copyable from prod-row shape) + encodings until green.
- [ ] **Step 4:** Extend `CLAUDE.md`'s recorded-exception paragraph: the contact-signal change (`ImportInfo.contact`, `TransactionImportReconciled.contact`, `BankProviderContactMapSet`, `configuration_bank_provider_contacts`, DTO) shipped via the **same one-time alpha DB-recreate** as #51 (registry stays empty). Add the data-reset note to `docs/deployment.md`.
- [ ] **Step 5: format + lint + commit.**

```bash
git commit -am "chore(events): contact-signal fixtures + recorded DB-recreate exception (tracker#54)"
```

---

## Task 9: Full verification

- [ ] **Step 1:** `nix develop --command bash -c "just rebuild"` (clean `-fci`/`-Werror` build).
- [ ] **Step 2:** `nix develop --command bash -c "cabal test all --test-show-details=direct"` — full suite green (mind the `eventium_test` DB caveat for integration specs — create it if missing).
- [ ] **Step 3:** `nix develop --command bash -c "just check"` (ormolu + hlint) clean.
- [ ] **Step 4:** Use the `verify` skill to drive an import end-to-end: (a) empty map — a PrivatBank/Monobank row whose description name-matches a contact still resolves (fallback preserved); (b) map the row's token to a *different* contact via the config endpoint, re-import, confirm the **map** wins (`MatchedByMap`); (c) confirm the persisted `ImportInfo.contact` and the DTO `bankProviderContact` token surface.
- [ ] **Step 5:** Open the backend PR referencing tracker#54; note the DB-recreate requirement (folded into #51 if landing together) and the client follow-up in the description.

---

## Notes / risks

- **Field-add ripple:** adding `contact` to `BankTransaction` (Task 4) and `ImportInfo` (Task 5) breaks every literal until updated — less disruptive than #51's type rename (field names are unchanged), but `Testkit/BankingHelpers.hs` and integration specs must add `contact = Nothing`. Keep TDD tests as drivers; commit at each green boundary.
- **Keyed-storage watch:** `BankProviderContact` appears as a **map key** (config event JSON + `configuration_bank_provider_contacts` rows) and a **stored column** (transaction read-model), not just a value — always go through `renderBankProviderContactKey`/`parseBankProviderContactKey`, never `Show`. Recreate covers migration, but encodings must be correct.
- **Fallback priority is load-bearing:** the map must beat name matching, and name matching must remain for unmapped/empty — Task 6 Step 1 asserts both explicitly. Do not let the map lookup short-circuit to `NoContactMatch` on a miss (that would silently drop the fallback and regress today's behaviour).
- **Provider source column:** confirm PrivatBank/Monobank actually expose a stable counterparty token distinct from (or equal to) `description`; if a provider only has the free-text description, that *is* the token — fine (name-agnostic w.r.t. the Contact display name is what matters). Pin the exact column in Task 4.
- **No seed, no defaults:** unlike #51 there is no `CategoryDefaults` analog and no `TransactionInterpretation` change — do not add one. The map starts empty by design.
