# Surface original MCC on imported transactions — Implementation Plan

> **STATUS: COMPLETED** (branch `feat/import-mcc-surfacing`). Implemented with one
> deviation from the write-path steps below: per the updated spec, the import-only
> fields are grouped into a new `ImportInfo { externalTransactionId, mcc }` carried
> as `importInfo :: Maybe ImportInfo`, **replacing** the top-level
> `externalTransactionId` on the command/event (rather than adding a sibling `mcc`
> field). The overdraft guard and bank-import dedup now read `importInfo` off the
> event; the aggregate is unchanged. Read-model/DTO still surface a flat `mcc`.
> Full `-fci` build clean; `just test` → 1276 examples, 0 failures. See the spec
> for the authoritative shape.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist the original bank MCC on imported transactions and expose it on `TransactionResponse`, and improve the built-in default MCC→category map (adding five new default expense categories).

**Architecture:** Thread one optional field `mcc :: Maybe MCC` through the Transaction write path (command → event → aggregate → read-model row → DTO), following the existing `externalTransactionId` optional-import-field precedent. MCC is produced only at bank import (`BankImportService.buildTransferCmd`); every other caller passes `Nothing`. Separately, expand `Domain.Configuration.Defaults` with new categories and a comprehensive MCC map.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude, `NoImplicitPrelude`), CQRS/event-sourcing (Eventium), persistent-postgresql read models, Aeson JSON, Hspec/QuickCheck. `MCC = Text` (`Domain.Core.Types`).

**Spec:** `docs/specs/2026-07-17-import-mcc-surfacing-design.md`

---

## Background facts the implementer must know

- `MCC` is a type alias for `Text` (`src/Domain/Core/Types.hs:658`), exported. Use `MCC` in domain/read-model signatures; the DTO field is plain `Maybe Text`.
- The build enforces `-Werror` via the `ci` flag. **Adding a field to a record makes every construction site fail** — record-syntax sites hit `-Wmissing-fields`, positional sites hit an arity error. All sites listed in Task 2 must be updated in the same task or the build is red.
- `TransactionPostingInitiated` has a **hand-written positional `FromJSON`** (`src/Domain/Transaction/Events.hs:339`). Field order in the record and decode order in the parser must stay in lockstep.
- Read-model schema migrations run via `runMigrationSilent migrateTransaction` on read-model init (`src/Application/ReadModels/Transaction.hs:275`). Persistent auto-adds a **nullable** column with no manual SQL; a `Text Maybe` column is a safe, additive migration.
- Follow repo conventions: ormolu formatting (`just format`), no partial functions, `-fci` build gate. Run `nix develop` first so GHC/cabal/just/ormolu are on PATH. See @CLAUDE.md.
- Testkit lives in `test/Testkit/` — reuse `Fixtures.hs`, `Helpers.hs`, `Generators.hs`, `InMemoryEventStore.hs`. Do not re-define import/registration setup helpers.
- Do NOT put issue/ticket numbers in test `describe`/`it` titles (behaviour names only).

---

## File Structure

| File | Change |
| --- | --- |
| `src/Domain/Configuration/Defaults.hs` | Add 5 expense-category fields; expand `defaultMccExpenseCategoryMap`. (Task 1) |
| `src/Domain/Transaction/Commands.hs` | Add `mcc :: Maybe MCC` to `InitiateTransaction`. (Task 2) |
| `src/Domain/Transaction/Events.hs` | Add `mcc :: Maybe MCC` to `TransactionPostingInitiated` + extend hand-written `FromJSON`. (Task 2) |
| `src/Domain/Transaction/CommandHandler.hs` | Carry `mcc` from command into event. (Task 2) |
| `src/Domain/Transaction/Projection.hs` | Add `mcc :: Maybe MCC` to `Transaction` aggregate + fold from event. (Task 2) |
| all other `InitiateTransaction`/event construction sites (src + test) | Add `mcc = Nothing` / positional `Nothing`. (Task 2) |
| `src/Application/ReadModels/Transaction.hs` | New nullable `mcc` column; `TransactionData.mcc`; projection write; `entToData`. (Task 3) |
| `src/Web/Types.hs` | `TransactionResponse.mcc`; populate in `fromTransactionData` + `fromTransaction`. (Task 4) |
| `src/Application/Services/BankImportService.hs` | Set `mcc = bankTx.mcc` in `buildTransferCmd`. (Task 4) |
| Tests under `test/` | Unit + integration coverage. (Tasks 1–5) |

---

## Task 1: New default expense categories + comprehensive MCC map

Independent of all threading work — pure `Defaults.hs` change. Do it first.

**Files:**
- Modify: `src/Domain/Configuration/Defaults.hs`
- Test: **extend** `test/Domain/Configuration/DefaultsSpec.hs` (already exists; top-level describe is `"Domain.Configuration.Defaults"`). It already has a no-dangling-targets test (lines 63–65) and a grocery `5411→food` test (67–69) — do NOT duplicate those.

- [ ] **Step 1: Write the failing tests (extend the existing spec)**

Two required edits to the existing `DefaultsSpec.hs`:

1. **Bump the category count** — line 46 currently asserts `length defaultExpenseCategories \`shouldBe\` 17`; adding 5 makes it **22**:
   ```haskell
       length defaultExpenseCategories `shouldBe` 22
   ```

2. **Extend the import** — add the new accessors to the `ExpenseDefaults(..)` import list (line 11):
   ```haskell
       ExpenseDefaults (food, dining, beauty, pets, electronics, shopping),
   ```

3. **Add new cases** under the existing `describe "defaultMccExpenseCategoryMap"` block (the no-dangling-targets test already there will also catch un-seeded categories):
   ```haskell
       it "maps dining MCCs to the Dining category (split from Food)" $ do
         Map.lookup "5812" defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId
         Map.lookup "5813" defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId
         Map.lookup "5814" defaultMccExpenseCategoryMap `shouldBe` Just expense.dining.entryId

       it "maps sample new-category MCCs to their categories" $ do
         Map.lookup "7230" defaultMccExpenseCategoryMap `shouldBe` Just expense.beauty.entryId
         Map.lookup "5995" defaultMccExpenseCategoryMap `shouldBe` Just expense.pets.entryId
         Map.lookup "5732" defaultMccExpenseCategoryMap `shouldBe` Just expense.electronics.entryId
         Map.lookup "5311" defaultMccExpenseCategoryMap `shouldBe` Just expense.shopping.entryId
   ```
   And under `describe "default category lists"`, extend the existing `elem` checks (line 47–50) to also assert `names \`shouldSatisfy\` elem "Dining"` (and optionally the other four).

- [ ] **Step 2: Run the test to verify it fails**

Run: `nix develop -c just build 2>&1 | tail -20` (expect compile error: `dining`/`beauty`/… not in scope / not exported).

- [ ] **Step 3: Add the five category fields**

In `src/Domain/Configuration/Defaults.hs`:

Extend the `ExpenseDefaults` export (line ~29) to include the new accessors:
```haskell
    ExpenseDefaults (food, dining, transport, utilities, rent, entertainment, fitness, health, education, clothing, insurance, subscriptions, household, travel, gifts, charity, taxesFees, beauty, pets, electronics, shopping, other),
```

Add fields to the `ExpenseDefaults` record (after `food`, before `other`, keep `other` last):
```haskell
data ExpenseDefaults = ExpenseDefaults
  { food :: !DefaultEntry,
    dining :: !DefaultEntry,
    transport :: !DefaultEntry,
    utilities :: !DefaultEntry,
    rent :: !DefaultEntry,
    entertainment :: !DefaultEntry,
    fitness :: !DefaultEntry,
    health :: !DefaultEntry,
    education :: !DefaultEntry,
    clothing :: !DefaultEntry,
    insurance :: !DefaultEntry,
    subscriptions :: !DefaultEntry,
    household :: !DefaultEntry,
    travel :: !DefaultEntry,
    gifts :: !DefaultEntry,
    charity :: !DefaultEntry,
    taxesFees :: !DefaultEntry,
    beauty :: !DefaultEntry,
    pets :: !DefaultEntry,
    electronics :: !DefaultEntry,
    shopping :: !DefaultEntry,
    other :: !DefaultEntry
  }
```

Construct them in the `expense` record (mirror ordering):
```haskell
    { food = mkExpense "Food",
      dining = mkExpense "Dining",
      ...
      taxesFees = mkExpense "Taxes & Fees",
      beauty = mkExpense "Beauty & Personal Care",
      pets = mkExpense "Pets",
      electronics = mkExpense "Electronics",
      shopping = mkExpense "Shopping",
      other = mkExpense "Other"
    }
```

Add them to `defaultExpenseCategories` (order not significant but keep consistent):
```haskell
  [ expense.food,
    expense.dining,
    ...
    expense.taxesFees,
    expense.beauty,
    expense.pets,
    expense.electronics,
    expense.shopping,
    expense.other
  ]
```

- [ ] **Step 4: Replace `defaultMccExpenseCategoryMap` with the comprehensive map**

Replace the body (lines ~193–232) with:

```haskell
defaultMccExpenseCategoryMap :: Map MCC CategoryId
defaultMccExpenseCategoryMap =
  Map.fromList
    [ -- Groceries & food stores
      ("5411", expense.food.entryId), -- Grocery stores, supermarkets
      ("5422", expense.food.entryId), -- Meat provisioners
      ("5451", expense.food.entryId), -- Dairy product stores
      ("5462", expense.food.entryId), -- Bakeries
      ("5499", expense.food.entryId), -- Misc food stores
      -- Dining out
      ("5811", expense.dining.entryId), -- Caterers
      ("5812", expense.dining.entryId), -- Restaurants
      ("5813", expense.dining.entryId), -- Bars, nightclubs
      ("5814", expense.dining.entryId), -- Fast food
      -- Entertainment
      ("5735", expense.entertainment.entryId), -- Record/music stores
      ("7832", expense.entertainment.entryId), -- Movie theaters
      ("7841", expense.entertainment.entryId), -- Video rental
      ("7922", expense.entertainment.entryId), -- Theatrical, concerts
      ("7929", expense.entertainment.entryId), -- Bands, orchestras
      ("7994", expense.entertainment.entryId), -- Video game arcades
      ("7996", expense.entertainment.entryId), -- Amusement parks
      ("7998", expense.entertainment.entryId), -- Aquariums, zoos
      -- Fitness
      ("7941", expense.fitness.entryId), -- Sports clubs, fields
      ("7997", expense.fitness.entryId), -- Country clubs, gyms
      -- Transport & auto
      ("4111", expense.transport.entryId), -- Local transit
      ("4112", expense.transport.entryId), -- Passenger railways
      ("4121", expense.transport.entryId), -- Taxis
      ("4131", expense.transport.entryId), -- Bus lines
      ("4789", expense.transport.entryId), -- Transportation services
      ("5511", expense.transport.entryId), -- Car dealers
      ("5533", expense.transport.entryId), -- Auto parts
      ("5541", expense.transport.entryId), -- Service stations (fuel)
      ("5542", expense.transport.entryId), -- Automated fuel dispensers
      ("7523", expense.transport.entryId), -- Parking
      ("7538", expense.transport.entryId), -- Auto service shops
      ("7542", expense.transport.entryId), -- Car washes
      ("7549", expense.transport.entryId), -- Towing
      -- Travel
      ("4411", expense.travel.entryId), -- Cruise lines
      ("4511", expense.travel.entryId), -- Airlines
      ("4722", expense.travel.entryId), -- Travel agencies
      ("7011", expense.travel.entryId), -- Lodging, hotels
      ("7512", expense.travel.entryId), -- Car rentals
      -- Health & medical
      ("5912", expense.health.entryId), -- Drug stores, pharmacies
      ("8011", expense.health.entryId), -- Doctors
      ("8021", expense.health.entryId), -- Dentists
      ("8031", expense.health.entryId), -- Osteopaths
      ("8041", expense.health.entryId), -- Chiropractors
      ("8042", expense.health.entryId), -- Optometrists
      ("8043", expense.health.entryId), -- Opticians
      ("8049", expense.health.entryId), -- Podiatrists
      ("8050", expense.health.entryId), -- Nursing/personal care
      ("8062", expense.health.entryId), -- Hospitals
      ("8071", expense.health.entryId), -- Medical labs
      ("8099", expense.health.entryId), -- Medical services
      -- Education & books
      ("5192", expense.education.entryId), -- Books, periodicals, newspapers
      ("5942", expense.education.entryId), -- Book stores
      ("8211", expense.education.entryId), -- Elementary/secondary schools
      ("8220", expense.education.entryId), -- Colleges, universities
      ("8241", expense.education.entryId), -- Correspondence schools
      ("8244", expense.education.entryId), -- Business/secretarial schools
      ("8249", expense.education.entryId), -- Vocational schools
      ("8299", expense.education.entryId), -- Educational services
      -- Clothing
      ("5611", expense.clothing.entryId), -- Men's clothing
      ("5621", expense.clothing.entryId), -- Women's clothing
      ("5631", expense.clothing.entryId), -- Women's accessories
      ("5641", expense.clothing.entryId), -- Children's/infants' wear
      ("5651", expense.clothing.entryId), -- Family clothing
      ("5655", expense.clothing.entryId), -- Sports/riding apparel
      ("5661", expense.clothing.entryId), -- Shoes
      ("5691", expense.clothing.entryId), -- Men's & women's apparel
      ("5697", expense.clothing.entryId), -- Tailors, alterations
      ("5699", expense.clothing.entryId), -- Misc apparel & accessories
      -- Utilities & telecom
      ("4812", expense.electronics.entryId), -- Telecom equipment & phone sales
      ("4814", expense.utilities.entryId), -- Telecom services
      ("4815", expense.utilities.entryId), -- Monthly telecom
      ("4816", expense.utilities.entryId), -- Computer network/information services
      ("4899", expense.utilities.entryId), -- Cable, satellite, pay TV
      ("4900", expense.utilities.entryId), -- Utilities (electric, gas, water)
      -- Subscriptions
      ("5968", expense.subscriptions.entryId), -- Direct-marketing subscriptions
      ("5969", expense.subscriptions.entryId), -- Direct marketing - other
      -- Household & home improvement
      ("5200", expense.household.entryId), -- Home supply warehouse
      ("5211", expense.household.entryId), -- Lumber, building materials
      ("5231", expense.household.entryId), -- Glass, paint, wallpaper
      ("5251", expense.household.entryId), -- Hardware stores
      ("5261", expense.household.entryId), -- Nurseries, garden supply
      ("5712", expense.household.entryId), -- Furniture
      ("5713", expense.household.entryId), -- Floor covering
      ("5714", expense.household.entryId), -- Drapery, upholstery
      ("5719", expense.household.entryId), -- Misc home furnishings
      ("5722", expense.household.entryId), -- Household appliance stores
      ("7623", expense.household.entryId), -- A/C, refrigeration repair
      -- Electronics & digital goods
      ("5045", expense.electronics.entryId), -- Computers, peripherals
      ("5732", expense.electronics.entryId), -- Electronics stores
      ("5734", expense.electronics.entryId), -- Computer software stores
      ("5816", expense.electronics.entryId), -- Digital goods - games
      ("5817", expense.electronics.entryId), -- Digital goods - applications
      ("5818", expense.electronics.entryId), -- Digital goods - large merchant
      -- Beauty & personal care
      ("5977", expense.beauty.entryId), -- Cosmetic stores
      ("7230", expense.beauty.entryId), -- Barber & beauty shops
      ("7297", expense.beauty.entryId), -- Massage parlors
      ("7298", expense.beauty.entryId), -- Health & beauty spas
      -- Pets
      ("0742", expense.pets.entryId), -- Veterinary services
      ("5995", expense.pets.entryId), -- Pet shops, pet food
      -- General-merchandise shopping
      ("5300", expense.shopping.entryId), -- Wholesale clubs
      ("5310", expense.shopping.entryId), -- Discount stores
      ("5311", expense.shopping.entryId), -- Department stores
      ("5331", expense.shopping.entryId), -- Variety stores
      ("5399", expense.shopping.entryId), -- Misc general merchandise
      ("5944", expense.shopping.entryId), -- Jewelry
      ("5945", expense.shopping.entryId), -- Hobby, toy, game shops
      -- Gifts
      ("5947", expense.gifts.entryId), -- Gift, card, novelty shops
      ("5992", expense.gifts.entryId), -- Florists
      -- Insurance
      ("5960", expense.insurance.entryId), -- Direct marketing - insurance
      ("6300", expense.insurance.entryId), -- Insurance sales, underwriting
      -- Charity
      ("8398", expense.charity.entryId), -- Charitable & social service orgs
      -- Taxes, fines & government
      ("9211", expense.taxesFees.entryId), -- Court costs
      ("9222", expense.taxesFees.entryId), -- Fines
      ("9311", expense.taxesFees.entryId), -- Tax payments
      ("9399", expense.taxesFees.entryId), -- Government services
      -- Other / financial
      ("4829", expense.other.entryId), -- Money transfers
      ("6051", expense.other.entryId), -- Non-financial institutions (money orders, crypto)
      ("6540", expense.other.entryId), -- Non-financial - stored value
      ("5964", expense.other.entryId), -- Direct marketing - catalog
      ("5999", expense.other.entryId) -- Misc specialty retail
    ]
```

> Verify no duplicate keys (`Map.fromList` silently keeps the last — the "no dangling targets" test won't catch a dup). Scan the list; each MCC string appears once.

- [ ] **Step 5: (spec already discovered)**

`DefaultsSpec.hs` already exists and is auto-discovered by `hspec-discover` — no wiring needed.

- [ ] **Step 6: Run the test to verify it passes**

Run: `nix develop -c cabal test all --test-option='--match' --test-option='/Domain.Configuration.Defaults/' --test-show-details=direct`
Expected: all Defaults examples PASS (including the bumped count of 22 and the new MCC cases).

- [ ] **Step 7: Format, lint, commit**

```bash
nix develop -c just format
nix develop -c just lint
git add src/Domain/Configuration/Defaults.hs test/Domain/Configuration/DefaultsSpec.hs
git commit -m "feat(banking): add Dining/Beauty/Pets/Electronics/Shopping default categories and expand default MCC map"
```

---

## Task 2: Thread `mcc` through the write path (command → event → aggregate)

Single compile-unit: adding the field breaks every construction site; all must land together. No read-model or DTO change yet.

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs:103`
- Modify: `src/Domain/Transaction/Events.hs:96` and `:339`
- Modify: `src/Domain/Transaction/CommandHandler.hs:209`
- Modify: `src/Domain/Transaction/Projection.hs:175` and `:336`
- Modify: all other construction sites (list below)
- Test: extend `test/Domain/Transaction/EventsSpec.hs` + `test/Domain/Transaction/CommandHandlerPropertySpec.hs`
- **`TransactionPostingInitiated` construction sites also break** (record + positional, ~30 sites in `src` + `test`) in addition to `InitiateTransaction` (~27). `-Werror` flags every one, so **rely on the compiler as the checklist**: build, fix the flagged site, repeat until green. The enumerations below are aids, not guaranteed-exhaustive.

- [ ] **Step 1: Write the failing tests**

(a) Event JSON backward-compat + round-trip. **`test/Domain/Transaction/EventsSpec.hs` already exists** and already tests this exact contract for `TransactionPostingInitiated` (legacy-decode-as-`Nothing` via an existing `stripKey`/`KeyMap.delete` helper, plus `Just` round-trip). **Extend that spec** — do NOT create a new file (a new `describe "TransactionPostingInitiated JSON"` would collide). Add two cases mirroring the existing `externalTransactionId`/`labels` ones:

- decode a payload with the `"mcc"` key stripped (reuse the existing `stripKey` helper) ⇒ `mcc == Nothing`;
- a `sampleEvent {mcc = Just "5411"}` round-trips (`decode . encode == Just`).

Reuse the existing `sampleEvent`/fixture in that file; just set `mcc` on it.

(b) Command→event carries mcc. In `test/Domain/Transaction/CommandHandlerPropertySpec.hs`, add an example asserting the emitted `TransactionPostingInitiated.mcc` equals the command's `mcc` (mirror the existing "preserves labels and externalTransactionId" example at line ~95).

- [ ] **Step 2: Run to verify failure**

Run: `nix develop -c just build 2>&1 | tail -30`
Expected: compile errors — `mcc` not a field of `TransactionPostingInitiated` / `InitiateTransaction`.

- [ ] **Step 3: Add `mcc` to the command**

`src/Domain/Transaction/Commands.hs` — add after `externalTransactionId` (line 123), before `labels`:
```haskell
    -- | Original merchant category code from the provider statement, retained
    -- for imported transactions so the client can surface it. 'Nothing' for
    -- manual entries and providers that supply no MCC.
    mcc :: Maybe MCC,
```
Ensure `MCC` is imported (from `Domain.Core.Types`). Check the existing import list; add `MCC` if absent.

- [ ] **Step 4: Add `mcc` to the event + extend the decoder**

`src/Domain/Transaction/Events.hs` — add the field after `externalTransactionId` (line 116), before `labels`:
```haskell
    -- | Original provider MCC for imported transactions; 'Nothing' otherwise.
    mcc :: Maybe MCC,
```
Extend the hand-written `FromJSON` (line 339) — insert the decode line **at the position matching the record order** (after `externalTransactionId`, before `labels`):
```haskell
      <*> o .:? "externalTransactionId" .!= Nothing
      <*> o .:? "mcc" .!= Nothing
      <*> (fromMaybe Set.empty <$> o .:? "labels")
```
Add `MCC` to the imports if absent.

- [ ] **Step 5: Carry `mcc` from command to event in the handler**

`src/Domain/Transaction/CommandHandler.hs:209` — the record is built from `InitiateTransaction {..}` (fields already in scope). Add `mcc = mcc,` to the `TransactionPostingInitiated { ... }` record (after `externalTransactionId = externalTransactionId,`).

- [ ] **Step 6: Add `mcc` to the aggregate + fold**

`src/Domain/Transaction/Projection.hs`:
- Add field to `Transaction` (line 175), after `labels` (or grouped near `transactionType`):
  ```haskell
      -- | Original provider MCC for imported transactions; 'Nothing' otherwise.
      mcc :: Maybe MCC,
  ```
- In `transactionDefault` (the seed near line 222–260), add `mcc = Nothing` (find the record literal for the default `Transaction` and add the field; if it's positional, add in matching slot).
- In `handleTransactionEvent` for `TransactionPostingInitiatedTransactionEvent` (line 336), add:
  ```haskell
      & #mcc
      .~ evt.mcc
  ```
- Add `MCC` to imports if absent.

- [ ] **Step 7: Update every remaining construction site to `mcc = Nothing`**

Rule: record-syntax sites add `mcc = Nothing,` after the `externalTransactionId = …` line. Positional sites insert one `Nothing` **immediately after the `externalTransactionId` positional argument** (which sits after `transactionType`, before `labels`).

`InitiateTransaction` **record-syntax** sites (all `mcc = Nothing` except BankImportService, handled in Task 4):
- `src/Application/Services/AccountService.hs:562`
- `src/Application/Services/TransactionService.hs:289`, `:355`, `:422`
- `src/Application/Services/BankImportService.hs:629` → set in Task 4, but to keep the build green now add `mcc = Nothing` here and change it to `bankTx.mcc` in Task 4 (or jump ahead and set `bankTx.mcc` now — either keeps the build green).
- `test/Integration/CrossKindAmendmentIntegrationSpec.hs:113`
- `test/Integration/ReportingWorkflowIntegrationSpec.hs:138`, `:179`
- `test/Integration/TransferWorkflowSpec.hs:194`, `:235`, `:680`, `:754`, `:800`, `:836`
- `test/Application/Services/TransactionServiceSpec.hs:131`, `:157`, `:193`
- `test/Application/Services/ConfigurationServiceInUseSpec.hs:112`
- `test/Application/Services/AccountServiceIntegrationSpec.hs:440`
- `test/Domain/Transaction/AllocationsSpec.hs:216`
- `test/Domain/Transaction/CommandHandlerSpec.hs:134`, `:172`, `:200`, `:228`, `:253`, `:281`
- `test/Domain/Transaction/RelationsCommandHandlerSpec.hs:71`

`InitiateTransaction` **positional** sites (insert `Nothing` after the `externalTransactionId` arg):
- `test/Domain/Transaction/CommandHandlerPropertySpec.hs:90`, `:103`, `:220`, `:229`, `:238`, `:255`

Also update every `TransactionPostingInitiated` construction site (same `mcc = Nothing` / positional rule). These are numerous and mostly in tests/Testkit — e.g. `test/Testkit/TransactionEvents.hs`, `test/Domain/Transaction/EventsSpec.hs`, `LabelsProjectionSpec.hs`, `DescriptionAndDateSpec.hs`, `CommandHandlerSpec.hs`, `CommandHandlerPropertySpec.hs`, and the `Application/ProcessManagers/*` specs. Do NOT rely on a single grep; **build and let `-Werror` enumerate them**:

```bash
nix develop -c just build 2>&1 | grep -E "missing|Not in scope|expected|arguments" | head -80
```
Re-grep as an aid only: `grep -rn "TransactionPostingInitiated$\|TransactionPostingInitiated {\|\$ TransactionPostingInitiated" src test`.

- [ ] **Step 8: Build + run tests to verify pass**

```bash
nix develop -c just build 2>&1 | tail -20
nix develop -c cabal test all --test-option='--match' --test-option='/TransactionPostingInitiated JSON/' --test-show-details=direct
nix develop -c cabal test all --test-option='--match' --test-option='/InitiateTransaction/' --test-show-details=direct
```
Expected: build clean; new JSON + command-handler examples PASS.

- [ ] **Step 9: Format, lint, commit**

```bash
nix develop -c just format
nix develop -c just lint
git add -A
git commit -m "feat(transaction): thread optional mcc through InitiateTransaction command, event and aggregate"
```

---

## Task 3: Persist `mcc` on the read-model row

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs` (schema `:211`, `TransactionData` `:144`, projection `:294`, `entToData` `:379`)
- Test: `test/Application/ReadModels/TransactionReadModelSpec.hs` or the relevant existing read-model/integration spec

- [ ] **Step 1: Write the failing test**

Add a test (in the existing Transaction read-model spec if present, else create one) that applies a `TransactionPostingInitiated` event carrying `mcc = Just "5411"` through the projection and asserts the resulting `TransactionData.mcc == Just "5411"`; and that an event with `mcc = Nothing` yields `Nothing`. Reuse `Testkit.InMemoryEventStore` / existing projection-apply helpers. If the read model is exercised only via integration specs (needs Postgres — see note on `eventium_test`), place this in the integration suite alongside existing `TransactionEntity` projection tests.

- [ ] **Step 2: Run to verify failure**

Run: `nix develop -c just build 2>&1 | tail -20` — expect `mcc` not a field of `TransactionData`.

- [ ] **Step 3: Add the nullable column**

`src/Application/ReadModels/Transaction.hs` schema (line 211), add after `date UTCTime` (before `amendmentCount`):
```
    mcc Text Maybe
```
(Persistent stores it as a nullable `text` column; `runMigrationSilent` auto-adds it — no manual SQL.)

- [ ] **Step 4: Add `mcc` to `TransactionData`**

`TransactionData` (line 144), add after `date` (grouping near the denormalized scalar fields):
```haskell
    -- | Original provider MCC for imported transactions; 'Nothing' otherwise.
    mcc :: Maybe MCC,
```
Add `MCC` to imports if absent.

- [ ] **Step 5: Write the column in the projection**

In the `TransactionPostingInitiatedEvent` handler (line 294) `TransactionEntity { … }` record, add:
```haskell
                    transactionEntityMcc = evt.mcc,
```
(placed consistently with schema order, before `transactionEntityAmendmentCount`).

- [ ] **Step 6: Carry it in `entToData`**

`entToData` (line 379), add:
```haskell
      mcc = e.transactionEntityMcc,
```

- [ ] **Step 7: Build + test**

```bash
nix develop -c just build 2>&1 | tail -20
nix develop -c cabal test all --test-option='--match' --test-option='/TransactionData/' --test-show-details=direct
```
Expected: build clean; read-model mcc examples PASS.

> If Postgres integration tests are skipped in your environment, note the `eventium_test` DB requirement (see project memory) — those failures are environmental, not regressions.

- [ ] **Step 8: Format, lint, commit**

```bash
nix develop -c just format
nix develop -c just lint
git add src/Application/ReadModels/Transaction.hs test/...
git commit -m "feat(transaction): persist mcc on the transactions read-model row"
```

---

## Task 4: Expose `mcc` on `TransactionResponse` + produce it at import

**Files:**
- Modify: `src/Web/Types.hs` (`TransactionResponse` `:611`, `fromTransactionData` `:1080`, `fromTransaction` `:1116`)
- Modify: `src/Application/Services/BankImportService.hs:640` (`buildTransferCmd`)
- Test: a Web DTO unit test + a BankImport integration assertion

- [ ] **Step 1: Write the failing tests**

(a) DTO builder: given a `TransactionData` with `mcc = Just "5411"`, `fromTransactionData` yields a `TransactionResponse` whose `mcc == Just "5411"`; with `Nothing` → `Nothing`. Add to the existing Web types / transaction-response spec if one exists.

(b) Import end-to-end: extend the BankImport integration spec — import a monobank statement row whose MCC is non-zero and assert the recorded transaction's `mcc` is that code; import a row with MCC `0` (or a PrivatBank row) and assert `mcc == Nothing`. Reuse existing BankImport Testkit fixtures/monobank sample builders.

- [ ] **Step 2: Run to verify failure**

Run: `nix develop -c just build 2>&1 | tail -20` — expect `mcc` not a field of `TransactionResponse`.

- [ ] **Step 3: Add the DTO field**

`src/Web/Types.hs` `TransactionResponse` (line 611), add after `relations` (or grouped near `labels`):
```haskell
    -- | Original provider MCC for imported transactions; @null@ for manual
    -- entries and providers that supply no MCC.
    mcc :: Maybe Text
```
(Plain `Maybe Text` — the DTO layer does not depend on the `MCC` alias. Derived `ToJSON`/`FromJSON` pick it up automatically.)

- [ ] **Step 4: Populate both builders**

`fromTransactionData` (line 1080): add `mcc = mcc,` (the field is in scope via `TransactionData {..}`).
`fromTransaction` (line 1116): add `mcc = tx.mcc,`.

- [ ] **Step 5: Produce MCC at import**

`src/Application/Services/BankImportService.hs` `buildTransferCmd` (line 629): set
```haskell
          mcc = bankTx.mcc,
```
(replacing the temporary `mcc = Nothing` from Task 2 if it was added there). `bankTx :: BankTransaction` is in scope and `bankTx.mcc :: Maybe MCC`.

- [ ] **Step 6: Build + test**

```bash
nix develop -c just build 2>&1 | tail -20
nix develop -c cabal test all --test-option='--match' --test-option='/TransactionResponse/' --test-show-details=direct
nix develop -c cabal test all --test-option='--match' --test-option='/import/' --test-show-details=direct
```
Expected: build clean; DTO + import examples PASS.

- [ ] **Step 7: Format, lint, commit**

```bash
nix develop -c just format
nix develop -c just lint
git add src/Web/Types.hs src/Application/Services/BankImportService.hs test/...
git commit -m "feat(banking): surface imported transaction mcc on TransactionResponse"
```

---

## Task 5: Full verification + wrap-up

- [ ] **Step 1: Clean build with the CI flag (definitive `-Werror` check)**

Run: `nix develop -c just rebuild` (clean + `-fci` build). The warm `.o` cache can mask `-Werror`; this is the authoritative gate.
Expected: no warnings, no errors.

- [ ] **Step 2: Full test suite**

Run: `nix develop -c just test`
Expected: green (excluding known-environmental `eventium_test`/Postgres skips — see project memory; those are not regressions).

- [ ] **Step 3: Manual smoke via `/verify` (optional but recommended)**

Drive an actual bank import and inspect a returned `TransactionResponse` for the `mcc` field, and a manual transaction for `null`. Use the project `run`/`verify` skill if available.

- [ ] **Step 4: Final commit / PR**

```bash
git log --oneline master..HEAD
```
Open a PR titled `feat(banking): surface original MCC on imported transactions (tracker#37)` against `master`. Body: link tracker#37, note this is the **backend** half; the web half (display + "map this MCC" prefill + static MCC→name table) is tracked separately in the client repo.

---

## Notes / risks

- **Blast radius:** the record-field addition in Task 2 touches ~55 sites total (`InitiateTransaction` ~27 + `TransactionPostingInitiated` ~30, mostly tests/Testkit). `-Werror` flags every one, so use the compiler as the checklist; the enumerated lists are aids, not guaranteed-exhaustive.
- **Positional decoder ordering** (Events.hs FromJSON) must match the record field order — both place `mcc` between `externalTransactionId` and `labels`.
- **No backward-compat migration needed** for events (optional decode) or DB (nullable auto-migrated column); existing rows/events correctly read back `mcc = Nothing`. Consistent with the project's no-back-compat stance — this is correct modelling, not a compat shim.
- **MCC map duplicate keys:** `Map.fromList` keeps the last silently; the dangling-target test does not catch dups. Eyeball the list for uniqueness (Step 4, Task 1).
- **Income unaffected:** `resolveCategory` skips the MCC map for income; no income categories added. MCC is still persisted on imported income if the provider supplies one (it is threaded regardless of direction).
