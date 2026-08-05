# Provider Category Signal — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the split MCC-only category handling with one `ProviderCategory = ByMcc MCC | ByLabel Text` signal, persisted verbatim and resolved through a single seeded, user-editable `providerCategoryMap`.

**Architecture:** `ProviderCategory` is a domain sum type on `ImportInfo`; `MCC` becomes a numeric `newtype` over `Int`. Providers emit `ByMcc`/`ByLabel`; the universal MCC defaults + per-provider label defaults are aggregated in `Infrastructure.Banking.CategoryDefaults` and seed a per-user `Map ProviderCategory CategoryId`. `resolveCategory` is a single lookup in that map — no provider-map threading.

**Tech Stack:** GHC 9.10, RIO, Servant, eventium (event sourcing), LiquidHaskell, Hspec/QuickCheck, ormolu/hlint. Build/test via `nix develop --command` + `just`.

**Scope:** Backend only (tracker#51 backend). The web client DTO/key changes (`../monorepo`) and the label-key editor UX (#52) are separate. Migration uses the **one-time alpha DB recreate** — no upcasters for the new shapes.

**Reference:** spec `docs/specs/2026-08-05-provider-category-signal-design.md`.

**Conventions for every code task:** follow TDD (write failing test → run it red → implement → run green → commit). Build/test with `nix develop --command bash -c "just build && cabal test all --test-show-details=direct …"`. No exported data constructors/selectors (smart constructors + accessors). Domain types carry LiquidHaskell refinements. Run `just format` + `hlint` before each commit. `just rebuild` for a definitive `-fci`/`-Werror` check.

---

## Task 0: Branch setup, revert interim approach, commit spec + plan

**Files:**
- Revert: `src/Domain/Configuration/Defaults.hs`, `src/Infrastructure/Banking/PrivatBank/Internal.hs`, `test/Domain/Configuration/DefaultsSpec.hs`, `test/Infrastructure/Banking/PrivatBankSpec.hs`
- Keep: `docs/specs/2026-08-05-provider-category-signal-design.md`, `docs/plans/2026-08-05-provider-category-signal.md`

- [ ] **Step 1:** Confirm on branch `feat/provider-category-signal` (already created off master).
- [ ] **Step 2:** Revert the interim "label-as-MCC" change (it is fully superseded by this plan):

```bash
git checkout -- src/Domain/Configuration/Defaults.hs \
  src/Infrastructure/Banking/PrivatBank/Internal.hs \
  test/Domain/Configuration/DefaultsSpec.hs \
  test/Infrastructure/Banking/PrivatBankSpec.hs
```

- [ ] **Step 3:** Sanity build/test to confirm a clean master baseline.

Run: `nix develop --command bash -c "just build && cabal test all --test-show-details=direct --test-option='--match' --test-option='/PrivatBank/'"`
Expected: PASS (baseline PrivatBank behavior; `mcc = Nothing` for PrivatBank).

- [ ] **Step 4: Commit** the spec + plan.

```bash
git add docs/specs/2026-08-05-provider-category-signal-design.md docs/plans/2026-08-05-provider-category-signal.md
git commit -m "docs(import): spec + plan for provider category-signal foundation (#51)"
```

---

## Task 1: `MCC` becomes a numeric newtype over `Int`

Foundational — later tasks use `mkMcc`/`unsafeMcc`. Today `type MCC = Text` (`src/Domain/Core/Types.hs` ~L655–664, with a doc note about "room for non-numeric keys" — delete that note).

**Files:**
- Modify: `src/Domain/Core/Types.hs` (MCC definition + exports)
- Test: `test/Domain/Core/TypesSpec.hs` (or the existing MCC/types spec; create if none)

- [ ] **Step 1: Write failing tests** for the smart constructor + render:

```haskell
it "mkMcc accepts a 4-digit code and renders zero-padded" $ do
  fmap renderMcc (mkMcc 742) `shouldBe` Right "0742"
  fmap renderMcc (mkMcc 5411) `shouldBe` Right "5411"
it "mkMcc rejects out-of-range codes" $ do
  mkMcc (-1) `shouldSatisfy` isLeft
  mkMcc 10000 `shouldSatisfy` isLeft
it "parseMcc round-trips the zero-padded text form" $
  (parseMcc "0742" >>= \m -> Just (renderMcc m)) `shouldBe` Just "0742"
```

- [ ] **Step 2: Run red.** Expected: FAIL (`mkMcc`/`renderMcc` undefined).
- [ ] **Step 3: Implement** `newtype MCC = MCC Int` with:
  - `{-@ … 0 <= v && v <= 9999 @-}` refinement + measure (mirror existing numeric refinements in this module).
  - `mkMcc :: Int -> Either DomainError MCC` (validation via a centralized `Maybe ErrorEnum` predicate, per the LiquidHaskell smart-constructor pattern used elsewhere in this file).
  - `unsafeMcc :: Int -> MCC` (for known-good literals/tests; mirror `unsafeExternalAccountId`).
  - `renderMcc :: MCC -> Text` (4-digit zero-pad), `parseMcc :: Text -> Maybe MCC` (digits → `mkMcc`), `mccInt :: MCC -> Int`.
  - Export the type (no constructor), `mkMcc`, `unsafeMcc`, `renderMcc`, `parseMcc`, `mccInt`, measures.
  - Remove `type MCC = Text` and its doc note.
- [ ] **Step 4: Run green.** Fix downstream compile errors minimally (there will be MCC-as-Text uses — a full sweep happens in later tasks; for now just make `Types.hs` + this spec compile, using `unsafeMcc`/`renderMcc` at obvious sites the compiler flags).
- [ ] **Step 5: Verify** `nix develop --command bash -c "just build"` — resolve remaining MCC type errors across the tree by converting Text literals to `unsafeMcc n` and string rendering to `renderMcc`. (Expect edits in Monobank parser, defaults, tests — these are also covered by later tasks; do the minimum to compile.)
- [ ] **Step 6: format + lint + commit.**

```bash
git commit -am "refactor(core): MCC becomes validated Int newtype (#51)"
```

---

## Task 2: `ProviderCategory` sum type (domain)

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Test: `test/Domain/Core/TypesSpec.hs`

- [ ] **Step 1: Write failing tests:**

```haskell
it "value JSON round-trips both cases" $ do
  decode (encode (byMcc (unsafeMcc 5411))) `shouldBe` Just (byMcc (unsafeMcc 5411))
  fmap byLabel (mkLabelCat "eating_out") ... -- round-trip ByLabel
it "map-key JSON uses tagged text form" $ do
  -- Map ProviderCategory CategoryId encodes keys as "mcc:0742" / "label:eating_out"
it "mkByLabel rejects empty" $ mkByLabel "" `shouldSatisfy` isNothing
```

- [ ] **Step 2: Run red.**
- [ ] **Step 3: Implement** in `Domain.Core.Types`:
  - `data ProviderCategory = ByMcc MCC | ByLabel Text` with `deriving (Eq, Ord, Show)`.
  - Smart constructors `mkByMcc :: MCC -> ProviderCategory`, `mkByLabel :: Text -> Maybe ProviderCategory` (reject empty/whitespace), a fold `providerCategory :: (MCC -> a) -> (Text -> a) -> ProviderCategory -> a`, accessor `providerCategoryMcc :: ProviderCategory -> Maybe MCC`.
  - LiquidHaskell refinements as needed.
  - **Value JSON** (`ToJSON`/`FromJSON`): tagged object `{ "kind": "mcc"|"label", "value": <string> }` where mcc value is `renderMcc`. Hand-written or `deriveJSON` with the tagged shape (this is a *stored* type — target the current shape only, no historical `.:?`).
  - **Key JSON** (`ToJSONKey`/`FromJSONKey`): `"mcc:" <> renderMcc` / `"label:" <> text`, parsed back symmetrically.
  - Export type (no constructors), smart ctors, fold, accessor, JSON instances.
- [ ] **Step 4: Run green. Step 5: format+lint. Step 6: Commit** `feat(core): ProviderCategory sum type with value+key JSON (#51)`.

---

## Task 3: `BankTransaction.category` + `TransactionInterpretation.labelCategories`

**Files:**
- Modify: `src/Infrastructure/Banking/Provider.hs` (BankTransaction fields ~L59–78; TransactionInterpretation ~L157)
- Test: touched provider specs later; add a Provider-level type test if useful.

- [ ] **Step 1:** Replace `mcc :: !(Maybe MCC)` and `categoryHint :: !(Maybe Text)` on `BankTransaction` with `category :: !(Maybe ProviderCategory)`. Update the accessor/smart-constructor surface accordingly.
- [ ] **Step 2:** Add `labelCategories :: Map Text CategoryId` to `TransactionInterpretation` (with an accessor). Update any interpretation constructors/call sites to pass `Map.empty` by default.
- [ ] **Step 3:** `just build` — expect errors in Monobank/PrivatBank parsers, resolveCategory, ImportInfo construction, tests. These are addressed in Tasks 4–8; get `Provider.hs` compiling and leave the rest for their tasks (or stub minimally). Commit once `Provider.hs` type-checks in isolation is impractical — instead proceed to Task 4/6 and commit the compiling slice there. (Do **not** commit a broken build; if needed, land Tasks 3+4+6 provider/resolve edits together before the first green commit.)

> Note: Tasks 3–6 form one compile unit (the `mcc`→`category` type change ripples). Implement their edits together; commit at the first green build. Keep the TDD tests (Tasks 4/6) as the drivers.

---

## Task 4: Provider conversions (Monobank `ByMcc`, PrivatBank `ByLabel` + label map)

**Files:**
- Modify: `src/Infrastructure/Banking/Monobank/Internal.hs` (~L122)
- Modify: `src/Infrastructure/Banking/PrivatBank/Internal.hs` (validateRow), `src/Infrastructure/Banking/PrivatBank.hs` (descriptor interpretation)
- Test: `test/Infrastructure/Banking/PrivatBankSpec.hs`, `test/Infrastructure/Banking/MonobankSpec.hs`

- [ ] **Step 1 (PrivatBank, red):** test that a mapped label row yields `category = Just (ByLabel "Дім та ремонт")` and a blank category yields `Nothing`:

```haskell
it "carries the PrivatBank category label as ByLabel" $
  case parsePrivatBankCsv (mkCsv [rowWithCategory "Дім та ремонт"]) of
    Right [Right tx] -> tx.category `shouldBe` mkByLabel "Дім та ремонт"
    _ -> expectationFailure "expected one parsed row"
```

- [ ] **Step 2:** Implement PrivatBank `validateRow`: `category = mkByLabel raw.rawCategory` (i.e. `Nothing` when blank); drop `mcc`/`categoryHint`.
- [ ] **Step 3 (PrivatBank label map — a *pure, exported* binding):** In `PrivatBank.hs`, define and **export** `labelCategories :: Map Text CategoryId` from spec §7 (values = `Domain.Configuration.Defaults` `expense.*` entryIds). Set the descriptor's `TransactionInterpretation.labelCategories` from *this same binding*. Add `import Domain.Configuration.Defaults` (new Infra→Domain edge). This binding is the single source of truth reused by `CategoryDefaults` in Task 5 (do **not** source it from the effectful registry).
- [ ] **Step 4 (Monobank):** set `category = fmap ByMcc <parsed mcc>` (parse the payload MCC via `mkMcc`); drop `categoryHint`; `labelCategories = Map.empty`. Update `MonobankSpec` assertions from `.mcc` to `.category`.
- [ ] **Step 5:** Run PrivatBank + Monobank specs green. **Commit** `feat(banking): providers emit ProviderCategory; PrivatBank label map (#51)`.

---

## Task 5: Relocate category defaults to `Infrastructure.Banking.CategoryDefaults`

**Files:**
- Create: `src/Infrastructure/Banking/CategoryDefaults.hs`
- Modify: `src/Domain/Configuration/Defaults.hs` (remove `defaultCategoryMccs`, `defaultMccExpenseCategoryMap`, and the interim `defaultCategoryLabels` if present)
- Modify: `src/Infrastructure/Banking/Providers.hs` / registry (source of registered providers' `labelCategories`)
- Test: `test/Infrastructure/Banking/CategoryDefaultsSpec.hs`; trim `test/Domain/Configuration/DefaultsSpec.hs`

- [ ] **Step 1 (red):** test `defaultProviderCategoryMap`:

```haskell
it "includes universal MCC defaults as ByMcc" $
  Map.lookup (byMcc (unsafeMcc 5411)) defaultProviderCategoryMap `shouldBe` Just expense.groceries.entryId
it "includes each provider's labels as ByLabel" $
  Map.lookup (fromJust (mkByLabel "Дім та ремонт")) defaultProviderCategoryMap `shouldBe` Just expense.household.entryId
```

- [ ] **Step 2:** Move `defaultCategoryMccs` + `defaultMccExpenseCategoryMap` into `CategoryDefaults` (values still reference `Domain.Configuration.Defaults` ids). Define:

```haskell
defaultProviderCategoryMap :: Map ProviderCategory CategoryId
defaultProviderCategoryMap =
  Map.mapKeys ByMcc defaultMccExpenseCategoryMap
    <> Map.mapKeys ByLabel PrivatBank.labelCategories   -- pure static binding (Task 4)
    -- <> Map.mapKeys ByLabel Monzo.labelCategories     -- future (#53)
```

  **Do NOT fold over the runtime registry** — `buildRegistry`/`candidates` (`Providers.hs:28,37`) are effectful (`BankingConfig -> Manager -> …`) and cannot seed a pure top-level value. Import each label-provider's pure `labelCategories` binding directly and union. Acyclic: `CategoryDefaults → PrivatBank → Domain.Configuration.Defaults`.
- [ ] **Step 3:** Delete the moved bindings from `Domain.Configuration.Defaults` and the interim `defaultCategoryLabels`; move/trim the corresponding `DefaultsSpec` assertions into `CategoryDefaultsSpec`. Confirm `Domain.Configuration.Defaults` no longer references MCC.
- [ ] **Step 4:** Run green (new spec + trimmed DefaultsSpec). **Commit** `refactor(banking): move category defaults out of domain into CategoryDefaults (#51)`.

---

## Task 6: Generalize the user category map + resolution + persistence

The `mcc`→`category` ripple and the map generalization land together for a green build.

**Files (this is the full `mcc`→`category` ripple — one compile unit):**

*Domain*
- `src/Domain/Core/Types.hs` — `ImportInfo.mcc` → `category :: Maybe ProviderCategory`; rename/retype the exported accessor `importInfoMcc` (`~L1419`) → `importInfoCategory`.
- `src/Domain/Configuration/Projection.hs` — `mccExpenseCategoryMap` (`~L97`) → `providerCategoryMap :: Map ProviderCategory CategoryId`.
- `src/Domain/Configuration/Commands.hs` (`~L215`) — command `SetBankingMccExpenseCategoryMap` → `SetProviderCategoryMap` (field `mapping :: Map ProviderCategory CategoryId`).
- `src/Domain/Configuration/Events.hs` (`~L36,92,202,295`) — event `BankingMccExpenseCategoryMapSet` → `ProviderCategoryMapSet` (name mirrors the command).
- `src/Domain/Transaction/Events.hs` (`~L428–437`) — `TransactionImportReconciled.mcc :: Maybe MCC` → `category :: Maybe ProviderCategory` (`deriveJSON` current shape only).
- `src/Domain/Transaction/Commands.hs` (`~L519–525`) — `ReconcileTransactionImport.mcc` → `category`.
- `src/Domain/Transaction/CommandHandler.hs` (`~L304`) — forward `category` command→event.

*Application*
- `src/Application/Services/BankImportService.hs` — `resolveCategory` (`~L558`, input → `Maybe ProviderCategory`, single lookup on `banking.providerCategoryMap`); `CategoryResolution` (`~L542`) → `MapHit !ProviderCategory | DefaultFallback !(Maybe ProviderCategory)`; `logCategoryResolution` (`~L688`); reconcile `attemptReconcile` (call `~L855`, def `~L886`) forwards `tx.category`; **both** `ImportInfo` constructions — `commitMatchingCurrencyImport` (`~L1007`) **and** `importTransferPair` (`~L438`, currently `mcc = Nothing` → `category = Nothing`); remove the now-unneeded label-map threading (keep `classify` only where direction is needed).
- `src/Application/Services/ConfigurationService.hs` — seed (`~L874`) from `CategoryDefaults.defaultProviderCategoryMap`; the setter `setBankingMccExpenseCategoryMap` (`~L405`) rename/retype; the config-clone path reading `srcBanking.mccExpenseCategoryMap` (`~L1038`).
- `src/Application/ReadModels/Configuration.hs` — table `configuration_mcc_categories` → `configuration_provider_categories` (decl `~L251`, event→row insert `~L391`, row→map assembly `~L523`).
- `src/Application/ReadModels/Transaction.hs` — `TransactionData.mcc` (`~L167`) → `category :: Maybe ProviderCategory`; **persistent column** `mcc Text Maybe` (`~L240`) → `provider_category Text Maybe` storing the `ProviderCategory` key form (`"mcc:0742"`/`"label:…"`), rebuilt on recreate; posting-initiated consumer (`~L330`, `evt.importInfo >>= importInfoCategory`); reconciled consumer (`~L353`); `fromEntity` mapping (`~L426`).
- `src/Application/Services/TransactionHistoryService.hs` (`~L121,187`) — `HistoryImportReconciled` carries the event, so the audit DTO shape changes with the rename. **Apply the CLAUDE.md audit-history-parity rule** (ensure the reconciled event still maps in `toHistoryEntry`).

*Test*
- `test/Application/Services/BankImportServiceSpec.hs`, `ConfigurationServiceSpec`, `Domain/Transaction/{EventsSpec,CommandHandlerSpec,ReconciliationCommandHandlerSpec,CommandHandlerPropertySpec}.hs`, `Domain/Configuration/{ProjectionSpec,CommandHandlerSpec}.hs`, `Application/ReadModels/PersistentTransactionReadModelSpec.hs`, `TransactionHistoryServiceSpec.hs`.

- [ ] **Step 1 (resolution, red):** in `BankImportServiceSpec`, drive:
  - a `ByMcc` key present in `providerCategoryMap` resolves to its category;
  - a `ByLabel` key present resolves to its category;
  - an unmapped key and income fall back to the direction default;
  - a hit whose category is absent from the user's dictionary falls back.
- [ ] **Step 2:** Generalize `Projection.providerCategoryMap :: Map ProviderCategory CategoryId`; rename command/event to `SetProviderCategoryMap`; rename the read-model table to `configuration_provider_categories`; `ConfigurationService` seeds it from `CategoryDefaults.defaultProviderCategoryMap`.
- [ ] **Step 3:** Rewrite `resolveCategory` to take `Maybe ProviderCategory` and do one lookup in `banking.providerCategoryMap` (expense; income → default; verify-in-dict). Simplify `CategoryResolution` to `MapHit !ProviderCategory | DefaultFallback !(Maybe ProviderCategory)`; update `logCategoryResolution`. Remove the `classify`/`labelCategories` threading — restore the seven functions to carry only what they still need (`classify` stays where direction is needed; the category map comes from the banking config already in scope at the resolve site).
- [ ] **Step 4:** `ImportInfo.category` stores `tx.category` verbatim at `:1009`; the reconcile path (`attemptReconcile` `:855` → `TransactionImportReconciled.category`) forwards `tx.category`; update the read-model consumer at `Transaction.hs:353`.
- [ ] **Step 5:** Update the **two** shared fixtures — `test/Testkit/BankingHelpers.hs:57` **and** `test/Testkit/Helpers.hs:243` — plus every `BankTransaction` literal / `.mcc` / `mccExpenseCategoryMap` reference: `Integration/{BankImportWorkflowSpec,TransferWorkflowSpec,CrossKindAmendmentIntegrationSpec}.hs`, `BankImportServiceSpec.hs`, `ConfigurationServiceSpec`, `Web/API/ConfigurationBankingAPISpec.hs`, `Application/ReadModels/PersistentTransactionReadModelSpec.hs`, `Telegram/FormattingSpec.hs`, and the Domain/Config transaction specs listed above.
- [ ] **Step 6:** Run green (build + affected specs). **Commit** `feat(import): single providerCategoryMap; ImportInfo.category persisted verbatim (#51)`.

---

## Task 7: DTO / API surface

**Files:**
- Modify: `src/Web/Types.hs` (transaction DTO `mcc` ~L683; the two DTO builders mapping `mcc` ~L1155 and ~L1190 → tagged `providerCategory`)
- Modify: `src/Web/API/BankingAPI.hs` + `src/Web/API/ConfigurationAPI.hs` (category-map read/write endpoints → `ProviderCategory` keys)
- Test: `test/Web/…` DTO encoding spec, `test/Web/API/ConfigurationBankingAPISpec.hs`

- [ ] **Step 1 (red):** test the transaction DTO encodes `providerCategory` as `{ "kind": "mcc"|"label", "value": … }` and `null`; the config category-map endpoint encodes/decodes `ProviderCategory` keys (`"mcc:0742"`/`"label:…"`).
- [ ] **Step 2:** Surface the DTO `providerCategory` tagged field (replaces flat `mcc`) in both builders. Update `Web/API/BankingAPI.hs` + `ConfigurationAPI.hs` map endpoints to the `ProviderCategory` key form.
- [ ] **Step 3:** Run green. **Commit** `feat(web): tagged providerCategory DTO + ProviderCategory map keys (#51)`.

> Client (`../monorepo`) consumes this — out of scope here; coordinate separately.

---

## Task 8: Migration — recreate exception, dead-upcaster cleanup, fixtures, docs

**Files:**
- Modify: `CLAUDE.md` (Backward compatibility section)
- Modify: `src/Infrastructure/Eventium/Schema.hs` + upcaster modules; `test/fixtures/events/*`; `test/Infrastructure/Eventium/SchemaSpec.hs`
- Modify: `docs/deployment.md` (runbook note)

- [ ] **Step 1:** **Rewrite** the existing `test/fixtures/events/transaction-import-reconciled.json` (and its `SchemaSpec.hs` expectations at `~L128,140`, currently `mcc = "5411"`) to the new `category` shape (`{ "kind": "mcc", "value": "5411" }`); add a `ByLabel` round-trip case. Add fixtures for `TransactionPostingInitiated` (importInfo with `category`) and `ProviderCategoryMapSet`. Cover `ProviderCategory` **value + key** JSON round-trip. Run red → implement encodings → green.
- [ ] **Step 2:** Remove the now-dead historical upcasters — `amendmentInitiatedV1toV2` and `postingInitiatedV1toV2` (`Schema.hs:75–96`) — and the dead legacy fixture `test/fixtures/events/transaction-posting-initiated-legacy-import.json`, plus their `SchemaSpec` cases. Keep the generic eventium machinery + `SchemaRegistry` wiring. (Do **not** delete `transaction-import-reconciled.json` — that event survives; it was rewritten in Step 1.) Run the schema suite green.
- [ ] **Step 3:** Update `CLAUDE.md` "Backward compatibility (production)" to record the **one-time alpha exception** (DB recreated for this change; standing upcast-on-read rule otherwise intact). Add a data-reset note to `docs/deployment.md`.
- [ ] **Step 4:** **Commit** `chore(events): recreate-DB exception; remove dead upcasters; new-shape fixtures (#51)`.

---

## Task 9: Full verification

- [ ] **Step 1:** `nix develop --command bash -c "just rebuild"` (clean `-fci`/`-Werror` build).
- [ ] **Step 2:** `nix develop --command bash -c "cabal test all --test-show-details=direct"` — full suite green (mind the `eventium_test` DB env caveat for integration specs).
- [ ] **Step 3:** `nix develop --command bash -c "just check"` (ormolu + hlint) clean.
- [ ] **Step 4:** Use the `verify` skill to drive an actual import end-to-end (PrivatBank CSV → transactions categorized via `ByLabel`; a Monobank-style MCC → `ByMcc`), confirming persisted `category` and the DTO shape.
- [ ] **Step 5:** Open the backend PR referencing tracker#51; note the DB-recreate requirement and the client follow-up (#52) in the description.

---

## Notes / risks

- **Compile-ripple:** the `mcc`→`category` change (Tasks 3–7) doesn't cleanly isolate per file; expect to land the provider + resolver + ImportInfo edits together for the first green build. Keep TDD tests as the drivers; commit at each green boundary.
- **`unsafeMcc` scope:** use it only for known-good literals (defaults, tests). All external-payload MCCs go through `mkMcc`.
- **Keyed-storage silent-break watch:** MCC/`ProviderCategory` appear as **map keys** and **stored columns**, not just values — `providerCategoryMap` JSON object keys (config event + `configuration_provider_categories` rows, insert `~L391` / assembly `~L523`) and the persistent transaction column (`~L240`). These must use the `ToJSONKey`/`FromJSONKey` key form (`renderMcc` zero-padded); a plain `Show`/`Text` slip changes wire shape silently. Recreate covers the migration, but the encodings must be correct. Monobank's payload MCC is already numeric (`Monobank/Internal.hs:119` `stmtMcc`) → `mkMcc ms.stmtMcc` is a clean swap.
- **Leading zeros:** MCC `0742` etc. must render zero-padded everywhere text is shown (map keys, DTO); covered by `renderMcc` tests.
- **No user backfill:** existing beta users are re-seeded on recreate; a provider added post-launch won't be in existing maps (documented future work, not built).
