# Provider Counterparty Category + Income Categorization — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Categorize bank imports that carry no MCC/label — income on every provider, and MCC-less expenses (PrivatBank business) — by the counterparty token, and let income be categorized at all.

**Architecture:** Add a third `BankProviderCategory` variant `ByCounterparty Text` (a backward-compatible superset of the tagged sum). Add a per-kind **income** category map (command/event/projection field/read-model table/DTO/service setter) as an additive sibling of the existing **expense** map — the expense side stays byte-for-byte unchanged, mirroring the `SetDefault{Income,Expense}Category` convention. Invert `resolveCategory`'s expense-only branch so each direction consults its own map. Providers emit `ByCounterparty` where they have no merchant signal. Ships **fully additive: no upcaster, no DB recreate.**

**Tech Stack:** Haskell (GHC 9.10, RIO prelude), CQRS/Event-Sourcing via eventium, Servant, persistent (PostgreSQL read models), Hspec/QuickCheck. Spec: `docs/specs/2026-08-08-provider-counterparty-category-design.md`.

**Branch:** `feat/counterparty-category-signal` (already checked out).

**Build/test commands** (inside `nix develop`):
- Build: `just build` (hpack + `cabal build -fci`)
- Full test: `just test`
- Focused test: `cabal test all --test-option='--match' --test-option="/PATTERN/"`
- Definitive `-Werror` check before final commit: `just rebuild`

---

## File Structure

Backend only (`homeaccounting/backend`). The web client (`../monorepo`) is a **separate plan** in that repo (add `incomeCategoryMap` DTO field + a second editor instance). Files touched here:

| File | Responsibility | Change |
|------|----------------|--------|
| `src/Domain/Core/Types.hs` | `BankProviderCategory` type + helpers/JSON | Add `ByCounterparty`, extend fold (3-arg), key/value JSON |
| `src/Domain/Configuration/Commands.hs` | Configuration commands | Add `SetBankProviderIncomeCategoryMap` |
| `src/Domain/Configuration/Events.hs` | Configuration events | Add `BankProviderIncomeCategoryMapSet` |
| `src/Domain/Configuration/CommandHandler.hs` | Command validation → events | Add income set-case + income removal-guard |
| `src/Domain/Configuration/Projection.hs` | `BankingConfiguration` state | Add `bankProviderIncomeCategoryMap` field + apply |
| `src/Domain/Configuration/Errors.hs` (wherever `EntryIsInBankProviderExpenseCategoryMap` is defined) | Config error enum | Add `EntryIsInBankProviderIncomeCategoryMap` (additive constructor) |
| `src/Application/ReadModels/Configuration.hs` | Persistent read model | Add income table + handler case + `loadBanking` + `copyBanking`? (no — copy is in service) |
| `src/Application/Services/ConfigurationService.hs` | Config service API | Add `setBankProviderIncomeCategoryMap` setter + `copyBanking` income clone |
| `src/Application/Services/BankImportService.hs` | Import category resolution | Invert `resolveCategory` to per-direction map |
| `src/Web/API/ConfigurationAPI.hs` | Banking DTO + handler | Add `incomeCategoryMap` field + income block |
| `src/Infrastructure/Banking/PrivatBankBusiness/Internal.hs` | PB business provider | `category = ByCounterparty <EDRPOU>` |
| `src/Infrastructure/Banking/Monobank/Internal.hs` | Monobank provider | income → `ByCounterparty <token>` |
| `test/fixtures/events/*.json` | Stored-event fixtures | Add income + counterparty fixtures |
| `test/**` | Specs | Per task, TDD |

**Income map is NOT seeded** (an EDRPOU/IBAN is user-specific; income has no universal defaults), so — unlike expense — there is no `CategoryDefaults` / seeding change. `emptyBankingConfiguration` initializes it to `Map.empty`.

**⚠️ `-fci` exhaustiveness constraint (drives task ordering):** `handleConfigurationCommand` (`CommandHandler.hs`) and `handleConfigurationEvent` (`Projection.hs`) are **exhaustive with no catch-all**, and the build runs `-Wall -Werror` under `-fci`. The moment a command/event is added to the TH lists (`configurationCommands`/`configurationEvents`), both sums gain a constructor and both handlers become non-exhaustive → **build fails**. Therefore the command record, event record, command-handler case, and projection case **must all land in one task/commit** (Task 2) — you cannot commit a compiling build in between. (The read-model handler *does* have a `_ -> pure ()` catch-all, so it compiles without its case — but that means a forgotten case silently drops the event; its own test in Task 3 is the only guard.)

---

## Task 1: `ByCounterparty` variant on `BankProviderCategory`

**Files:**
- Modify: `src/Domain/Core/Types.hs` (type + helpers/instances ~740-832; export list ~75-81; add `mkByCounterparty`)
- Modify: `test/Domain/Core/TypesSpec.hs` (new cases + the existing 2-arg fold test ~283-285)

Adding a constructor is a **backward-compatible superset** of the tagged sum — old `mcc`/`label` payloads stay valid. The 2-arg fold `bankProviderCategory` becomes 3-arg; **all** its callers (src *and* test) must be updated.

- [ ] **Step 1: Write failing tests** in `test/Domain/Core/TypesSpec.hs` (mirror the existing `BankProviderCategory` describe block):

```haskell
  describe "BankProviderCategory ByCounterparty" $ do
    it "mkByCounterparty trims and rejects blank" $ do
      renderBankProviderCategoryKey <$> mkByCounterparty "  12345678 "
        `shouldBe` Just "counterparty:12345678"
      mkByCounterparty "   " `shouldBe` Nothing

    it "key form round-trips (including a token containing a colon)" $ do
      let Just pc = mkByCounterparty "UA:1234"
      parseBankProviderCategoryKey (renderBankProviderCategoryKey pc) `shouldBe` Just pc

    it "value JSON round-trips" $ do
      let Just pc = mkByCounterparty "12345678"
      Aeson.decode (Aeson.encode pc) `shouldBe` Just pc

    it "value JSON is the tagged counterparty object" $ do
      let Just pc = mkByCounterparty "12345678"
      Aeson.encode pc `shouldBe` "{\"kind\":\"counterparty\",\"value\":\"12345678\"}"
```

- [ ] **Step 2: Run to verify failure** — `cabal test all --test-option='--match' --test-option="/BankProviderCategory ByCounterparty/"` → FAIL (`mkByCounterparty` not in scope).

- [ ] **Step 3: Implement** in `src/Domain/Core/Types.hs`:
  - Add the constructor: `| ByCounterparty Text  -- universal counterparty token (EDRPOU / IBAN / stable descriptor)`.
  - Add smart constructor (mirrors `mkByLabel`):

```haskell
-- | Smart constructor for a counterparty-token 'BankProviderCategory'. Trims and
-- rejects blank. The token is the same universal counterparty signal used for
-- contact resolution (an EDRPOU/IBAN); it is persisted verbatim.
mkByCounterparty :: Text -> Maybe BankProviderCategory
mkByCounterparty t
  | T.null trimmed = Nothing
  | otherwise = Just (ByCounterparty trimmed)
  where
    trimmed = T.strip t
```

  - Extend the fold to 3-arg and update its body + internal callers:

```haskell
bankProviderCategory :: (MCC -> a) -> (Text -> a) -> (Text -> a) -> BankProviderCategory -> a
bankProviderCategory onMcc _ _ (ByMcc m) = onMcc m
bankProviderCategory _ onLabel _ (ByLabel t) = onLabel t
bankProviderCategory _ _ onCounterparty (ByCounterparty t) = onCounterparty t

bankProviderCategoryMcc :: BankProviderCategory -> Maybe MCC
bankProviderCategoryMcc = bankProviderCategory Just (const Nothing) (const Nothing)

renderBankProviderCategoryKey :: BankProviderCategory -> Text
renderBankProviderCategoryKey =
  bankProviderCategory
    (\m -> "mcc:" <> renderMcc m)
    ("label:" <>)
    ("counterparty:" <>)
```

  - Add the `counterparty` case to `parseBankProviderCategoryKey` (`"counterparty" -> mkByCounterparty suffix`), to `ToJSON` (third fold arg `(\t -> object ["kind" .= ("counterparty" :: Text), "value" .= t])`), and to `FromJSON` (`"counterparty" -> maybe (fail "...blank") pure (mkByCounterparty value)`).
  - Add `mkByCounterparty,` to the export list (after `mkByLabel,`).

- [ ] **Step 4: Update ALL fold callers (src + test).** Run `rg 'bankProviderCategory ' src test`. Update every 2-arg call to 3-arg. Known sites: `bankProviderCategoryMcc`, `renderBankProviderCategoryKey` (above), and **`test/Domain/Core/TypesSpec.hs:283-285`** ("bankProviderCategory folds over both cases") — extend it to pass a third function and add a `ByCounterparty` assertion. Then `just build` → compiles.

- [ ] **Step 5: Run tests** — `cabal test all --test-option='--match' --test-option="/BankProviderCategory/"` → PASS (new cases + the updated fold test + existing mcc/label cases).

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Core/Types.hs test/Domain/Core/TypesSpec.hs
git commit -m "feat(domain): add ByCounterparty variant to BankProviderCategory"
```

---

## Task 2: Income command + event + handler + projection (ATOMIC — one commit)

**Files:**
- Modify: `src/Domain/Configuration/Commands.hs` (record after `SetBankProviderExpenseCategoryMap` ~221; `configurationCommands` list ~75-97; `deriveJSON` ~353; export ~29)
- Modify: `src/Domain/Configuration/Events.hs` (record after `BankProviderExpenseCategoryMapSet` ~208; `configurationEvents` list ~82-104; `deriveJSON` ~309; export ~36)
- Modify: `src/Domain/Configuration/CommandHandler.hs` (set-case beside ~446-453)
- Modify: `src/Domain/Configuration/Projection.hs` (`BankingConfiguration` ~98; `emptyBankingConfiguration` ~133-139; apply ~347; event import)
- Create: `test/fixtures/events/bank-provider-income-category-map-set.json`
- Modify: `test/Infrastructure/Eventium/SchemaSpec.hs`, `test/Domain/Configuration/CommandHandlerSpec.hs`, `test/Domain/Configuration/ProjectionSpec.hs`

**These four production changes must land together** (see the exhaustiveness note above) — adding the TH-list entries without the handler/projection cases breaks the `-fci` build. The wrapper sum constructors (`SetBankProviderIncomeCategoryMapConfigurationCommand`, `BankProviderIncomeCategoryMapSetConfigurationEvent`) and the wire tag `"BankProviderIncomeCategoryMapSet"` are TH-generated — no manual sum edit, and existing tags are untouched.

- [ ] **Step 1: Write failing tests** across the three specs:
  - `SchemaSpec.hs` (mirror expense fixture test ~181-191): a new-income round-trip **and** confirm an existing expense/reconciled fixture still decodes (backward-compat):

```haskell
    it "BankProviderIncomeCategoryMapSet round-trips from a stored fixture" $ do
      fixture <- BS.readFile "test/fixtures/events/bank-provider-income-category-map-set.json"
      case Aeson.eitherDecodeStrict fixture :: Either String AccountingEvent of
        Left err -> expectationFailure err
        Right ev -> Aeson.eitherDecodeStrict (BL.toStrict (Aeson.encode ev)) `shouldBe` Right ev
```

  - `CommandHandlerSpec.hs` (mirror expense ~1048-1087): emits `BankProviderIncomeCategoryMapSet` when values are income-dict entries; **rejects** a value that is an EXPENSE category (wrong dictionary); accepts empty map. Add income test fixtures beside the expense ones.
  - `ProjectionSpec.hs` (mirror expense ~505-516): applying `BankProviderIncomeCategoryMapSetConfigurationEvent` sets `banking.bankProviderIncomeCategoryMap` and leaves `bankProviderExpenseCategoryMap` untouched.

- [ ] **Step 2: Create the fixture** `test/fixtures/events/bank-provider-income-category-map-set.json` (a `counterparty:` key proves the new variant persists):

```json
{
  "tag": "BankProviderIncomeCategoryMapSet",
  "contents": {
    "mapping": {
      "counterparty:12345678": "00000000-0000-0003-0000-000000000000"
    }
  }
}
```

- [ ] **Step 3: Run to verify failure** — the three specs FAIL (types/handlers/fields absent).

- [ ] **Step 4: Implement all four (mirror expense verbatim, Income for Expense, income semantics):**
  - `Commands.hs`: `data SetBankProviderIncomeCategoryMap = SetBankProviderIncomeCategoryMap { mapping :: Map BankProviderCategory CategoryId } deriving (Show, Eq)`; add `''SetBankProviderIncomeCategoryMap` to `configurationCommands`; add `deriveJSON defaultOptions ''SetBankProviderIncomeCategoryMap`; add `SetBankProviderIncomeCategoryMap (..)` to exports.
  - `Events.hs`: `data BankProviderIncomeCategoryMapSet = BankProviderIncomeCategoryMapSet { mapping :: Map BankProviderCategory CategoryId } deriving (Show, Eq)`; add `''BankProviderIncomeCategoryMapSet` to `configurationEvents`; add `deriveJSON defaultOptions ''BankProviderIncomeCategoryMapSet`; add to exports.
  - `CommandHandler.hs` set-case (mirror ~446-453, swap dict kind):

```haskell
handleConfigurationCommand config (SetBankProviderIncomeCategoryMapConfigurationCommand SetBankProviderIncomeCategoryMap {..}) = do
  mapM_ (\cid -> requireEntryIn incomeCategoryDictKind cid config) (Map.elems mapping)
  Right [BankProviderIncomeCategoryMapSetConfigurationEvent BankProviderIncomeCategoryMapSet {mapping = mapping}]
```

  - `Projection.hs`: add field `bankProviderIncomeCategoryMap :: !(Map BankProviderCategory CategoryId),` to `BankingConfiguration`; add `bankProviderIncomeCategoryMap = Map.empty,` to `emptyBankingConfiguration`; add apply case `handleConfigurationEvent config (BankProviderIncomeCategoryMapSetConfigurationEvent evt) = config {banking = config.banking {bankProviderIncomeCategoryMap = evt.mapping}}`; import the new event.

- [ ] **Step 5: Build + run** — `just build` → compiles (exhaustiveness satisfied). Run the three specs (`/BankProviderIncomeCategoryMapSet/`, `/SchemaSpec/`, income CommandHandler/Projection cases) → PASS. Confirm existing expense/contact SchemaSpec fixtures still decode.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Configuration/{Commands,Events,CommandHandler,Projection}.hs \
        test/fixtures/events/bank-provider-income-category-map-set.json \
        test/Infrastructure/Eventium/SchemaSpec.hs \
        test/Domain/Configuration/{CommandHandlerSpec,ProjectionSpec}.hs
git commit -m "feat(config): add per-kind income bank-provider category map (command/event/handler/projection)"
```

---

## Task 3: Persistent read model

**Files:**
- Modify: `src/Application/ReadModels/Configuration.hs` (entity ~259-263; handler ~403-407; `loadBanking` ~542-586)
- Test: the configuration read-model / integration spec covering the expense map

**⚠️** The event handler has a `_ -> pure ()` catch-all (~463): if the income case is omitted the build still passes but the event is **silently dropped**. The test in Step 1 is the only guard — do not skip it.

- [ ] **Step 1: Write failing test**: after applying `BankProviderIncomeCategoryMapSet`, `loadBanking` returns the entry in `bankProviderIncomeCategoryMap`. (Add to the spec that already exercises the expense-map read model.)
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement** (mirror the expense entity/handler/loader):
  - New persistent entity (new table — additive DDL):

```
ConfigBankProviderIncomeCategoryEntity sql=configuration_bank_provider_income_categories
    configId ConfigurationId
    bankProviderCategory Text
    categoryId DictionaryEntryId
    UniqueConfigBankProviderIncomeCategory configId bankProviderCategory
    deriving Show Eq
```

  - Handler case (mirror ~403-407):

```haskell
          BankProviderIncomeCategoryMapSetEvent evt ->
            whenConfig configId ver $ do
              deleteWhere [ConfigBankProviderIncomeCategoryEntityConfigId ==. configId]
              forM_ (Map.toList evt.mapping) $ \(pc, cat) ->
                insert_ (ConfigBankProviderIncomeCategoryEntity configId (renderBankProviderCategoryKey pc) cat)
```

  - In `loadBanking`: `selectList` the income rows and populate `bankProviderIncomeCategoryMap` (mirror the expense list-comprehension with `parseBankProviderCategoryKey`).
- [ ] **Step 4: Run → PASS.** (New table auto-created in fresh test DB; deploy = additive new-table migration.)
- [ ] **Step 5: Commit** — `feat(config): persist bank-provider income category map read model`

---

## Task 4: `resolveCategory` — per-direction map (income now categorized)

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (`resolveCategory` ~627-658; doc ~607-626)
- Test: `test/Application/Services/BankImportServiceSpec.hs`

Behavioral core: delete the `ClassifiedIncome -> Nothing` short-circuit; each direction consults its own map.

- [ ] **Step 1: Write failing tests** (mirror the expense `resolveCategory (unit)` block ~472-505; add an `mkCfgIncome` helper with `defaults = emptyConfigurationDefaults {incomeCategory = Just …}` and an `incomeDict` helper keyed by `incomeCategoryDictKind`):

```haskell
    it "resolves an income counterparty hit via the income map" $ do
      let Just pc = mkByCounterparty "12345678"
          bankingCfg = emptyBankingConfiguration {bankProviderIncomeCategoryMap = Map.singleton pc salaryIncomeItem}
          cfg = mkCfgIncome (incomeDict [salaryIncomeItem, otherIncomeItem]) bankingCfg otherIncomeItem
      resolveCategory bankingCfg cfg ClassifiedIncome (Just pc) `shouldBe` Right (salaryIncomeItem, MapHit pc)

    it "resolves the same counterparty independently per direction" $ do
      let Just pc = mkByCounterparty "12345678"
          bankingCfg = emptyBankingConfiguration
            { bankProviderIncomeCategoryMap = Map.singleton pc salaryIncomeItem
            , bankProviderExpenseCategoryMap = Map.singleton pc rentExpenseItem }
      resolveCategory bankingCfg (mkCfgIncome (incomeDict [salaryIncomeItem]) bankingCfg otherIncomeItem) ClassifiedIncome (Just pc)
        `shouldBe` Right (salaryIncomeItem, MapHit pc)
      resolveCategory bankingCfg (mkCfg (expenseDict [rentExpenseItem]) bankingCfg otherItem) ClassifiedExpense (Just pc)
        `shouldBe` Right (rentExpenseItem, MapHit pc)

    it "income with no mapping falls back to the income default" $ do
      let cfg = mkCfgIncome (incomeDict [otherIncomeItem]) emptyBankingConfiguration otherIncomeItem
      resolveCategory emptyBankingConfiguration cfg ClassifiedIncome Nothing
        `shouldBe` Right (otherIncomeItem, DefaultFallback Nothing)

    it "income map hit absent from the dictionary falls back to the income default (staleness)" $ do
      let Just pc = mkByCounterparty "12345678"
          bogus = unsafeDictionaryEntryId UUID.nil
          bankingCfg = emptyBankingConfiguration {bankProviderIncomeCategoryMap = Map.singleton pc bogus}
          cfg = mkCfgIncome (incomeDict [otherIncomeItem]) bankingCfg otherIncomeItem
      resolveCategory bankingCfg cfg ClassifiedIncome (Just pc)
        `shouldBe` Right (otherIncomeItem, DefaultFallback (Just pc))
```

- [ ] **Step 2: Run → FAIL** (income still short-circuits to the default; `MapHit` assertions fail).
- [ ] **Step 3: Implement** — replace the `let ...` body so the map is selected by direction and both directions consult it:

```haskell
resolveCategory banking cfg direction maybeCategory =
  let ConfigurationDefaults {incomeCategory = mIncomeDefault, expenseCategory = mExpenseDefault} = cfg.defaults
      (dictKind, deflt, directionMap) = case direction of
        ClassifiedIncome -> (incomeCategoryDictKind, mIncomeDefault, banking.bankProviderIncomeCategoryMap)
        ClassifiedExpense -> (expenseCategoryDictKind, mExpenseDefault, banking.bankProviderExpenseCategoryMap)
      dictItemIds = maybe Set.empty dictionaryItemIds (Map.lookup dictKind cfg.dictionaries)
      -- Rung 1: the provider signal (MCC / label / counterparty) mapped in the
      -- direction's category map. A future description-keyword matcher slots in
      -- as an additional rung between here and the default fallback.
      mapHit = maybeCategory >>= \pc -> (pc,) <$> Map.lookup pc directionMap
      existsInDict eid = Set.member eid dictItemIds
   in case mapHit of
        Just (pc, eid) | existsInDict eid -> Right (eid, MapHit pc)
        _ -> case deflt of
          Just eid -> Right (eid, DefaultFallback maybeCategory)
          Nothing -> Left $ BankingError $ "No banking " <> directionName direction <> " category configured"
  where
    directionName ClassifiedIncome = "income"
    directionName ClassifiedExpense = "expense"
```
  Update the doc comment (~607-626): drop the "expense-only" invariant; describe the per-direction ladder. `logCategoryResolution` needs no change (already direction-aware).
- [ ] **Step 4: Run → PASS.** Re-run the existing expense `resolveCategory` tests — must pass unchanged.
- [ ] **Step 5: Commit** — `feat(import): resolve income categories via per-direction provider map`

---

## Task 5: ConfigurationService income setter + clone parity

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs` (setter beside ~408-418; `copyBanking` ~1055)
- Test: `test/Application/Services/ConfigurationServiceSpec.hs`

No seeding (income starts empty). But `copyBanking` (config clone) copies the expense + contact maps; add the income map for parity (harmless today since the template's income map is empty, but prevents a silent gap once users populate it).

- [ ] **Step 1: Write failing test**: `setBankProviderIncomeCategoryMap` persists a map; reloading returns it in `banking.bankProviderIncomeCategoryMap`. (Mirror the expense setter spec.)
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement:**
  - Setter (mirror ~408-418):

```haskell
setBankProviderIncomeCategoryMap :: UserId -> Map BankProviderCategory CategoryId -> AppM (Either DomainError ())
setBankProviderIncomeCategoryMap userId mapping = runExceptT $ do
  lift $ logInfo $ "Setting banking provider income-category map for user " <> displayShow userId
  configId <- ExceptT (ensureClonedConfiguration userId)
  runConfigurationCmd
    translateConfigurationError
    (unConfigurationId configId)
    (SetBankProviderIncomeCategoryMapConfigurationCommand SetBankProviderIncomeCategoryMap {mapping = mapping})
  lift $ logInfo "Banking provider income-category map set successfully"
```
    Export it.
  - In `copyBanking` (~1055): add an income block mirroring the expense clone (`unless (Map.null src.bankProviderIncomeCategoryMap) $ … SetBankProviderIncomeCategoryMapConfigurationCommand …`).
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `feat(config): add setBankProviderIncomeCategoryMap setter + clone parity`

---

## Task 6: Web DTO + handler

**Files:**
- Modify: `src/Web/API/ConfigurationAPI.hs` (`BankingConfigurationDTO` ~312-318; `toBankingDTO` ~388-395; `UpdateBankingRequest` ~563-567; `updateBankingHandler` ~716-753)
- Test: the Web/handler spec for banking config; `test/Web/TypesSpec.hs:124` (existing `bankProviderCategory` JSON block)

Additive: existing `expenseCategoryMap` field/behavior unchanged.

- [ ] **Step 1: Write failing tests**:
  - `PUT /configuration/banking` with an `incomeCategoryMap` (a `counterparty:...` key → income category UUID) round-trips into the returned `BankingConfigurationDTO.incomeCategoryMap`.
  - In `test/Web/TypesSpec.hs` (~124, existing `bankProviderCategory` block): the DTO **encodes the `counterparty` kind** — `toJSON (mkByCounterparty "12345678")` is `{"kind":"counterparty","value":"12345678"}` (and decodes back).
- [ ] **Step 2: Run → FAIL** (field/JSON missing).
- [ ] **Step 3: Implement:**
  - Add `incomeCategoryMap :: Map Text UUID` to `BankingConfigurationDTO` (Generic JSON picks it up).
  - `toBankingDTO`: `incomeCategoryMap = Map.mapKeys renderBankProviderCategoryKey (Map.map unDictionaryEntryId b.bankProviderIncomeCategoryMap),`
  - Add `incomeCategoryMap :: Maybe (Map Text UUID)` to `UpdateBankingRequest`.
  - `updateBankingHandler`: add a `forM_ req.incomeCategoryMap` block mirroring the expense block (validate keys via `parseBankProviderCategoryKey`, call `ConfigService.setBankProviderIncomeCategoryMap`).
- [ ] **Step 4: Run → PASS.** (The transaction import-info DTO at `Web/Types.hs:686` needs no change — it serializes `ByCounterparty` via the type instance; the TypesSpec assertion above covers it.)
- [ ] **Step 5: Commit** — `feat(web): expose incomeCategoryMap in banking configuration API`

---

## Task 7: Provider signals

**Files:**
- Modify: `src/Infrastructure/Banking/PrivatBankBusiness/Internal.hs` (~81, `category` field)
- Modify: `src/Infrastructure/Banking/Monobank/Internal.hs` (~118-121, `category` field)
- Test: `test/Infrastructure/Banking/PrivatBankBusinessSpec.hs`, `test/Infrastructure/Banking/MonobankSpec.hs`

- [ ] **Step 1: Write failing tests:**
  - PrivatBank business: a row with EDRPOU `"12345678"` → `category == mkByCounterparty "12345678"`; blank EDRPOU → `category == Nothing`.
  - Monobank: income row (`stmtMcc == 0`) → `category == mkByCounterparty <stmtDescription>`; expense row (`stmtMcc /= 0`) → still `mkByMcc <$> ...`.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement:**
  - PrivatBankBusiness `validateRow`: `category = mkByCounterparty (fromMaybe "" (col "ЄДРПОУ")),` (reuses the exact EDRPOU token feeding `contact`).
  - Monobank:

```haskell
                category =
                  if ms.stmtMcc == 0
                    then mkByCounterparty ms.stmtDescription
                    else mkByMcc <$> either (const Nothing) Just (mkMcc (fromIntegral ms.stmtMcc)),
```
  **Caveat (spec):** Monobank's counterparty token is `stmtDescription` (free text, the same token #54 uses for contacts), not a stable EDRPOU/IBAN — coarser than PB business's EDRPOU. Note in the PR; a better Monobank identifier is out of scope.
- [ ] **Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `feat(banking): emit ByCounterparty category for MCC-less rows (PB business, Monobank income)`

---

## Task 8: Income removal-guard parity

**Files:**
- Modify: `src/Domain/Configuration/CommandHandler.hs` (`RemoveDictionaryEntry` guard ~371, beside the expense/contact guards)
- Modify: the config error enum module (wherever `EntryIsInBankProviderExpenseCategoryMap` is defined) — add an additive constructor
- Test: `test/Domain/Configuration/CommandHandlerSpec.hs`

Parity with the expense guard: an income category referenced by the income map must not be silently removed. Additive (new error constructor). Without it, removal is *mitigated* (resolveCategory's staleness check falls through to default) but not *prevented*.

- [ ] **Step 1: Write failing test**: `RemoveDictionaryEntry` of an income category that is a value in the income map is rejected with the new error; removing an unreferenced income category still succeeds.
- [ ] **Step 2: Run → FAIL.**
- [ ] **Step 3: Implement**: add `EntryIsInBankProviderIncomeCategoryMap` to the config error enum; add `isInBankProviderIncomeCategoryMap` guard in the `RemoveDictionaryEntry` handler, mirroring the expense guard at ~371 (and the contact guard at ~372) against `bankProviderIncomeCategoryMap`.
- [ ] **Step 4: Run → PASS** (existing expense/contact removal-guard tests unaffected).
- [ ] **Step 5: Commit** — `feat(config): guard income-mapped categories against removal (parity)`

---

## Task 9: End-to-end verification + gate

- [ ] **Step 1:** Add/extend an import integration test (mirror `.../BankImportWorkflowSpec.hs`): configure an income map (`counterparty:<edrpou>` → income category via `setBankProviderIncomeCategoryMap`), import a PrivatBank-business **income** row with that EDRPOU, assert the transaction's allocation lands in the mapped **income** category (not the income default). Second case: no mapping → income default.
- [ ] **Step 2:** Full suite — `just test`. Green (an absent `eventium_test` DB gives ~28 pre-existing env failures, not a regression).
- [ ] **Step 3:** Definitive `-Werror` check — `just rebuild` → clean.
- [ ] **Step 4:** Flip `docs/specs/2026-08-08-provider-counterparty-category-design.md` frontmatter `status: draft` → `completed`. Confirm no `CLAUDE.md` backcompat entry is needed (additive — no recreate/upcaster).
- [ ] **Step 5: Commit** — `test(import): end-to-end counterparty income categorization` (+ spec status bump).

---

## Notes for the implementer

- **DRY mirror:** Tasks 2–6, 8 are structural copies of the existing expense slice with `Income`↔`Expense` substituted and `incomeCategoryDictKind` for `expenseCategoryDictKind`. Read the expense definition at each cited line before writing the income one.
- **Additivity is load-bearing:** never rename or reshape the expense command/event/table/field — the no-recreate property depends on the expense stored event staying byte-identical. If tempted to "unify" expense+income, stop: that's an explicitly rejected design (spec §"Why per-kind").
- **Ordering is forced by `-fci`:** Task 2 is atomic because the config command/event handlers are exhaustive with no catch-all. The read-model handler *does* have a catch-all — so Task 3's test is the only thing catching a dropped event.
- **TDD discipline:** @superpowers:test-driven-development — red before green on every task.
- **Layering:** `BankProviderCategory` is `Domain.Core`; no provider/native-language data leaks into it. `resolveCategory` reads only the `BankingConfiguration` it already receives.
