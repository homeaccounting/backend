# Contact Dictionary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional per-transaction contact (counterparty) reference to income and expense transactions, drawn from a user-curated contact dictionary, with match-only auto-linking during bank import.

**Architecture:** Thread an optional scalar `contactId :: Maybe ContactId` (a `DictionaryEntryId` alias) through the transaction command/event/aggregate/read-model/DTO stack, exactly mirroring the existing `labels` wiring but scalar-and-nullable (nullable column, not a join table). Reuse the already-generic `ContactKind` dictionary (CRUD + REST work today). Reject contacts on transfers/adjustments with a domain error. Bank import matches the (normalized) statement description against existing contacts only — it never creates entries.

**Tech Stack:** Haskell (GHC 9.10.3), RIO prelude, Servant, Eventium (event sourcing), PostgreSQL, Hspec + QuickCheck, LiquidHaskell, ormolu, hlint, `just`.

---

## Conventions for every task

- **This is a Haskell/event-sourced codebase.** For each new field/command/event/error, the fastest correct path is to **find the adjacent `labels`/`category` code cited by line number and mirror it exactly** — same field ordering, same TH derivations, same JSON style (ormolu splits `<$>`/`.:` chains onto their own lines — do not fight it), same LiquidHaskell treatment.
- **Naming (repo conventions):** command `SetTransactionContact`, event `TransactionContactSet`; actor field is `by :: UserId`; dictionary-kind constructor is `ContactKind` (already exists). Never export data constructors or field selectors — smart constructors / accessors only.
- **No auto-create dictionaries** — import is match-only. No default contact. DTO exposes id only (no resolved name).
- **Build/verify commands:**
  - Enter the dev shell once per session: `nix develop`
  - Fast inner loop: `just build`
  - Full test: `just test`
  - Targeted test: `cabal test all --test-option='--match' --test-option="/PATTERN/"`
  - Format + lint before every commit: `just check`
  - `-fci`/`-Werror` is enforced; a warm `.o` cache can mask warnings — if a commit touches many modules, run `just rebuild` once before the final commit of that task.
- **DB for integration tests:** full `cabal test all` needs a manually-created `eventium_test` Postgres DB (`just docker-up` does not create it). If integration specs error on connection, that is environmental — note it, don't treat as a regression.
- **Commit after every green task** using Conventional Commits (`feat:`/`test:`/`refactor:`), scope `contacts` where useful.
- **Re-run flaky failures once** before treating as real (Cabal-7125 / `-j` spuriousness is known).

---

## File map

| File | Responsibility | Change |
|------|----------------|--------|
| `src/Domain/Core/Types.hs` | `type ContactId = DictionaryEntryId` + export | Modify |
| `src/Domain/Core/Errors.hs` | `ContactNotFound`, `ContactInUse`, `ContactNotAllowedOnTransfer` | Modify |
| `src/Application/Services/ConfigurationService.hs` | `contactsDictKind`; 3-way removal guard | Modify |
| `src/Domain/Transaction/Commands.hs` | `contactId` on `InitiateTransaction`; new `SetTransactionContact`; amendment `contactId` | Modify |
| `src/Domain/Transaction/Events.hs` | `contactId` on `TransactionPostingInitiated` (+ back-compat `FromJSON`); new `TransactionContactSet`; amendment `contactId` | Modify |
| `src/Domain/Transaction/*` (aggregate/projection) | apply contact to aggregate state | Modify |
| `src/Application/Services/TransactionService.hs` | `validateContact`, transfer guard, `setTransactionContact`, wiring | Modify |
| `src/Application/ReadModels/Transaction.hs` | `TransactionData.contactId`, nullable column, projection, referencing count | Modify |
| `src/Web/Types.hs` | `TransactionResponse.contactId`, request DTOs, `parseContactId`, `fromTransactionData` | Modify |
| `src/Web/API/TransactionAPI.hs` | set-contact route/handler; create handlers pass contact | Modify |
| `src/Application/Services/BankImportService.hs` | `resolveContact` (match-only) + wiring + provenance | Modify |
| `test/Testkit/*` | `postingInitiatedGlobal` contact arg, generator, fixture | Modify |
| `test/Domain/...`, `test/Application/...`, `test/Integration/...`, `test/Web/API/...` | tests | Create/Modify |

Ordering is bottom-up: types → errors → commands/events → aggregate → service → read model → DTO/web → import. Each task is independently green and committable.

---

### Task 1: `ContactId` type alias

**Files:**
- Modify: `src/Domain/Core/Types.hs` (alias near `LabelId` ~:645 / `CategoryId` ~:650; export list ~:66)

- [ ] **Step 1: Add the alias and export**

Mirror the `LabelId` / `CategoryId` lines exactly. Add:

```haskell
-- | A contact (counterparty) reference: the source of an income or the
-- beneficiary of an expense. An entry in the shared @contact@ dictionary.
type ContactId = DictionaryEntryId
```

Add `ContactId` to the module export list right beside `LabelId` and `CategoryId`. Because it is a type alias for `DictionaryEntryId`, it inherits all of that type's LiquidHaskell refinements — no new refinement work.

- [ ] **Step 2: Build**

Run: `just build`
Expected: compiles clean (no new warnings under `-fci`).

- [ ] **Step 3: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "feat(contacts): add ContactId type alias"
```

---

### Task 2: Domain errors

**Files:**
- Modify: `src/Domain/Core/Errors.hs` (near `LabelNotFound` ~:73, `CategoryNotFound` ~:75, `LabelInUse` ~:77, `CategoryInUse` ~:82)
- Test: `test/Domain/Core/ErrorsSpec.hs` if one exists (else fold into service tests later)

- [ ] **Step 1: Add three constructors to `DomainError`**

Mirror the label/category constructors **exactly** — check their real shapes first, they are not uniform:
- `LabelNotFound` / `CategoryNotFound` carry a **`Text`** (a rendered entry id), *not* a `ContactId`.
- `LabelInUse` / `CategoryInUse` are **records** `{ entryId :: Text, usageCount :: Int }` (Task 14 constructs `ContactInUse { entryId = ..., usageCount = ... }`, so it MUST be a record).

```haskell
  | ContactNotFound Text
  | ContactInUse { entryId :: Text, usageCount :: Int }
  | ContactNotAllowedOnTransfer
```

Match how `LabelNotFound`/`CategoryNotFound` render their id and how `LabelInUse`/`CategoryInUse` are shaped/derived. (Adjust field names/records to whatever the current source shows — read it, don't trust this snippet blindly.) If `DomainError` has any `-Wincomplete-patterns`-checked total functions (error-code mapping, HTTP status mapping in `Web/*`), add the new constructors there too — the build will tell you where via `-Werror`.

- [ ] **Step 2: Build and let `-Werror` find every incomplete match**

Run: `just build`
Expected: FAIL initially with non-exhaustive pattern warnings pointing at every `case` over `DomainError` (e.g. HTTP status mapping in `Web/`). Add branches:
- `ContactNotFound _` / `ContactInUse _` → mirror `LabelNotFound` / `LabelInUse` (e.g. 404 / 409 respectively).
- `ContactNotAllowedOnTransfer` → mirror a 400/validation-style mapping.

- [ ] **Step 3: Build until clean**

Run: `just build`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Domain/Core/Errors.hs src/Web/ ; git commit -m "feat(contacts): add ContactNotFound/ContactInUse/ContactNotAllowedOnTransfer errors"
```

---

### Task 3: `contactsDictKind` helper

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs` (beside `labelsDictKind` ~:186; export list ~:50)

- [ ] **Step 1: Add and export**

```haskell
contactsDictKind :: DictionaryKind
contactsDictKind = ContactKind
```

Export it beside `labelsDictKind`.

- [ ] **Step 2: Build**

Run: `just build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/Application/Services/ConfigurationService.hs
git commit -m "feat(contacts): add contactsDictKind helper"
```

---

### Task 4: `contactId` on create command + event (with back-compat decode)

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs` (`InitiateTransaction` ~:103-133, TH list ~:60-75, JSON ~:424)
- Modify: `src/Domain/Transaction/Events.hs` (`TransactionPostingInitiated` ~:96-121, back-compat `FromJSON` ~:340-353)
- Test: `test/Domain/Transaction/EventsSpec.hs` (or the existing events JSON spec)

- [ ] **Step 1: Write the failing test — old event JSON (no `contactId`) decodes to `Nothing`, new round-trips**

Mirror the existing `labels`-defaulting decode test. Add to the events spec:

```haskell
it "decodes a TransactionPostingInitiated event that predates contactId with contactId = Nothing" $ do
  let json = <existing sample WITHOUT a contactId key>
  fmap (.contactId) (eitherDecode json) `shouldBe` Right (Nothing :: Maybe ContactId)

it "round-trips contactId when present" $ do
  let ev = <builder with contactId = Just someContactId>
  eitherDecode (encode ev) `shouldBe` Right ev
```

(Use the destructure-via-constructor pattern to read `.contactId` if dot-access is ambiguous under `DuplicateRecordFields` — see the HasField gotcha memory.)

- [ ] **Step 2: Run to verify it fails**

Run: `cabal test all --test-option='--match' --test-option="/TransactionPostingInitiated/"`
Expected: FAIL (field/constructor doesn't exist yet).

- [ ] **Step 3: Add the field to command and event**

- `InitiateTransaction`: add `contactId :: Maybe ContactId` (mirror the `labels :: Set LabelId` field at ~:126). Update the TH field list and any explicit `ToJSON`/`FromJSON`.
- `TransactionPostingInitiated`: add `contactId :: Maybe ContactId` (mirror `labels` ~:119).
- In the hand-written back-compat `FromJSON` for `TransactionPostingInitiated` (~:340-353), add `contactId <- o .:? "contactId" .!= Nothing` alongside the `labels` default (`.!= mempty`).

- [ ] **Step 4: Run tests to verify pass**

Run: `cabal test all --test-option='--match' --test-option="/TransactionPostingInitiated/"`
Expected: PASS.

- [ ] **Step 5: Fix all now-broken constructor call sites**

`just build` will flag every place that constructs `InitiateTransaction` / `TransactionPostingInitiated` (services, Testkit, other tests) with a missing field. Default each to `Nothing` for now (import wiring comes in Task 13; Testkit contact arg in Task 12-adjacent). Run `just build` until clean.

- [ ] **Step 6: Commit**

```bash
git add -A ; git commit -m "feat(contacts): thread optional contactId through create command/event"
```

---

### Task 5: `SetTransactionContact` command + `TransactionContactSet` event

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs` (mirror `SetTransactionLabels` ~:181-187)
- Modify: `src/Domain/Transaction/Events.hs` (mirror `TransactionLabelsSet` ~:152-160)
- Test: transaction events/commands spec

- [ ] **Step 1: Write failing JSON round-trip test for the new event**

```haskell
it "round-trips TransactionContactSet" $ do
  let ev = <TransactionContactSet with transactionId, contactId = Just cid, by = uid>
  eitherDecode (encode ev) `shouldBe` Right ev
```

- [ ] **Step 2: Run to verify fail**

Run: `cabal test all --test-option='--match' --test-option="/TransactionContactSet/"`
Expected: FAIL (constructor missing).

- [ ] **Step 3: Add command + event**

```haskell
-- Commands.hs, mirroring SetTransactionLabels
data SetTransactionContact = SetTransactionContact
  { transactionId :: TransactionId
  , contactId :: Maybe ContactId
  , by :: UserId
  }

-- Events.hs, mirroring TransactionLabelsSet
data TransactionContactSet = TransactionContactSet
  { transactionId :: TransactionId
  , contactId :: Maybe ContactId
  , by :: UserId
  }
```

Register them in the same TH lists / sum types / JSON instances the label pair is registered in (search for `SetTransactionLabels` and `TransactionLabelsSet` and add a sibling everywhere).

- [ ] **Step 4: Run to verify pass + build**

Run: `cabal test all --test-option='--match' --test-option="/TransactionContactSet/"` then `just build`
Expected: PASS / clean.

- [ ] **Step 5: Commit**

```bash
git add -A ; git commit -m "feat(contacts): add SetTransactionContact command and TransactionContactSet event"
```

---

### Task 6: Amendment carries `contactId`

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs` (`AmendTransaction` / `CompleteTransactionAmendment` ~:297-340)
- Modify: `src/Domain/Transaction/Events.hs` (`TransactionAmendmentInitiated` / `...Completed` ~:217-265; back-compat decode if these have hand-written `FromJSON`)
- Test: amendment events spec

- [ ] **Step 1: Failing round-trip / back-compat test** for amendment event(s) carrying `contactId :: Maybe ContactId` (same shape as Task 4's tests).

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/Amendment/"`

- [ ] **Step 3: Add `contactId :: Maybe ContactId`** to the amendment command(s) and event(s); add `.:? "contactId" .!= Nothing` to any hand-written decoders.

- [ ] **Step 4: Run → PASS**, then `just build` and fix call sites (default `Nothing`).

- [ ] **Step 5: Commit** `feat(contacts): thread contactId through amendment command/event`.

---

### Task 7: Aggregate applies contact to state

**Files:**
- Modify: the transaction aggregate/projection under `src/Domain/Transaction/` (the module with the `apply`/`project` fold over events — find where `TransactionLabelsSet` and `labels` update aggregate state)
- Test: `test/Domain/Transaction/<AggregateOrProjection>Spec.hs`

- [ ] **Step 1: Write failing property/unit tests** for aggregate state:
  - Applying `TransactionPostingInitiated{contactId = Just c}` yields aggregate with contact `Just c`.
  - Applying `TransactionContactSet{contactId = Just c'}` overrides it; `Nothing` clears it.
  - Applying amendment-completed updates contact.
  Mirror the equivalent `labels` aggregate tests.

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/Transaction.*contact/"` (adjust pattern to your describe titles — no issue numbers in titles).

- [ ] **Step 3: Implement:** add a `contactId :: Maybe ContactId` field to the aggregate state record; update the event fold to set it on `TransactionPostingInitiated`, `TransactionContactSet`, and amendment-completed. Mirror `labels` handling.

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): apply contact to transaction aggregate state`.

---

### Task 8: `validateContact` + transfer guard (service)

**Files:**
- Modify: `src/Application/Services/TransactionService.hs` (`validateContact` beside `validateLabels` ~:736-749; helpers `assignableEntryIds` ~:1152)
- Test: `test/Application/Services/TransactionServiceSpec.hs` (or the relevant service/property spec)

- [ ] **Step 1: Write failing tests**

```haskell
describe "validateContact" $ do
  it "accepts Nothing" $ ...            -- runs, no error
  it "accepts a known assignable contact id" $ ...
  it "rejects an unknown contact id with ContactNotFound" $ ...

describe "contact on transfer" $
  it "rejects a contact on a transfer/adjustment with ContactNotAllowedOnTransfer" $ ...
```

Use `Testkit` in-memory event store + dictionary fixtures. Reuse existing helpers; do not hand-roll a dictionary setup.

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/validateContact/"`

- [ ] **Step 3: Implement**

```haskell
-- Mirror validateLabels' real shape: it takes a UserId, loads config via
-- getConfigurationForUser, then calls the PURE assignableEntryIds kind cfg.
validateContact :: UserId -> Maybe ContactId -> AppM ()
validateContact _ Nothing = pure ()
validateContact userId (Just cid) = do
  cfg <- getConfigurationForUser userId >>= either throwError pure
  let assignable = assignableEntryIds contactsDictKind cfg   -- pure, takes cfg
  unless (cid `Set.member` assignable) $
    throwError (ContactNotFound (renderEntryId cid))          -- ContactNotFound carries Text
```

Model precisely on `validateLabels` (which takes `UserId`, loads config, iterates a `Set LabelId`); here it is a single optional id. Use whatever id→`Text` rendering `LabelNotFound` uses (shown next to `validateLabels`). Add a small guard helper:

```haskell
guardNoContactOnTransfer :: TransactionKind -> Maybe ContactId -> AppM ()
guardNoContactOnTransfer kind (Just _)
  | kind `elem` [TransferKind, AdjustmentKind] = throwError ContactNotAllowedOnTransfer
guardNoContactOnTransfer _ _ = pure ()
```

(Use the actual kind constructors from `Domain.Core.Types`; `deriveTransactionKind`/`kindOf` are available.)

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit** `feat(contacts): add validateContact and transfer guard`.

---

### Task 9: Wire contact into income/expense/transfer create paths

**Files:**
- Modify: `src/Application/Services/TransactionService.hs` (`initiateIncome` ~:254-305, `initiateExpense` ~:320-366, `initiateTransfer` ~:386-433)
- Test: service spec

- [ ] **Step 1: Failing tests** — creating income/expense with a valid `contactId` results in `TransactionPostingInitiated.contactId = Just c`; with an unknown id → `ContactNotFound`; `initiateTransfer` given a contact → `ContactNotAllowedOnTransfer`.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — thread `contactId` from the create input through `validateContact` (income/expense) into the emitted `InitiateTransaction{contactId = ...}`. In `initiateTransfer`, call `guardNoContactOnTransfer` (transfer inputs shouldn't carry one, but this defends internal callers). Income/expense set the field; transfer always emits `contactId = Nothing`.

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): validate and record contact on income/expense create`.

---

### Task 10: `setTransactionContact` service action

**Files:**
- Modify: `src/Application/Services/TransactionService.hs` (mirror `setTransactionLabels` ~:445-465)
- Test: service spec

- [ ] **Step 1: Failing tests** — `setTransactionContact` on an income/expense validates then emits `TransactionContactSet`; unknown id → `ContactNotFound`; on a transfer transaction → `ContactNotAllowedOnTransfer`; `Nothing` clears the contact.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — load the transaction (to know its kind), `guardNoContactOnTransfer`, `validateContact`, then emit `SetTransactionContact`. Mirror `setTransactionLabels` structure and its optimistic-concurrency/version handling.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit** `feat(contacts): add setTransactionContact service action`.

---

### Task 11: Amendment validation + guard wiring

**Files:**
- Modify: `src/Application/Services/TransactionService.hs` (amendment dispatch ~:942-973)
- Test: service / cross-kind amendment spec

- [ ] **Step 1: Failing tests** — amending an income/expense to set a valid contact records it; amending to an unknown contact → `ContactNotFound`; amending a transaction to transfer/adjustment kind *with* a contact → `ContactNotAllowedOnTransfer`.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** — in the amendment path, `validateContact` the amended `contactId` and `guardNoContactOnTransfer` against the amended target kind; carry `contactId` onto the amendment command/event emitted.

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): validate contact on amendment`.

---

### Task 12: Testkit support for contact

**Files:**
- Modify: `test/Testkit/TransactionEvents.hs` (`postingInitiatedGlobal` ~:49-67)
- Modify: `test/Testkit/Generators.hs` (add `genContactId` beside `genDictionaryEntryId` ~:232 / `genLabelSet` ~:290)
- Modify: `test/Testkit/Fixtures.hs` (add a contact fixture beside `MetadataFixture` ~:231-260 if useful)

- [ ] **Step 1: Extend `postingInitiatedGlobal`** to take a `Maybe ContactId` and set `contactId` on the built event (mirror how it takes `Set LabelId` and sets `labels` at ~:67). Update all existing callers to pass `Nothing` (the build/tests will list them).

- [ ] **Step 2: Add `genContactId :: Gen (Maybe ContactId)`** (or reuse `genDictionaryEntryId` wrapped in `Gen (Maybe ...)`), for property tests.

- [ ] **Step 3: Build tests** — `just build` (test component) until clean.

- [ ] **Step 4: Commit** `test(contacts): extend Testkit with contact support`.

> Note: it is fine to do this task earlier if a prior task's tests need it; keep the Testkit change in its own commit regardless.

---

### Task 13: Read model — `TransactionData.contactId` + nullable column + projection

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs` (`TransactionData` ~:146-168; `TransactionEntity` persist block; projection ~:291-332; `entToData` ~:386-399; `getTransaction` ~:450-456)
- Test: `test/Application/ReadModels/TransactionListSpec.hs`

- [ ] **Step 1: Failing read-model test** — project `TransactionPostingInitiated{contactId = Just c}` then `getTransaction` returns `TransactionData` with `contactId = Just c`; a `TransactionContactSet` updates it; amendment-completed updates it. Mirror the `labels` read-model tests (but note: value lives on the row, not a join table).

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/TransactionList/"`

- [ ] **Step 3: Implement**
- Add `contactId :: Maybe ContactId` to `TransactionData`.
- **`isIdentityAmend` landmine (from Tasks 8-11):** `isIdentityAmend` in `TransactionService.hs` compares accounts/amounts/rate/`transactionType` but NOT `contactId` (it couldn't — `TransactionData` didn't carry it). Once `TransactionData.contactId` exists, extend `isIdentityAmend` to also compare `contactId`, so an amendment that changes ONLY the contact is not wrongly short-circuited as a no-op and dropped. Add a test: amend changing only contact → dispatched and applied.
- Add a **nullable** column to the `TransactionEntity` persist block (e.g. `contactId (Maybe DictionaryEntryId) Maybe`). No new table/index required (a single scalar); add an index only if a contact filter is implemented.
- Projection: set the column on `TransactionPostingInitiated`, `TransactionContactSet`, and amendment-completed (mirror where `setLabels` is called at ~:323 / ~:328-329, but write the scalar directly on the row via an update rather than a join-table write).
- `entToData`: read the column into `TransactionData.contactId`.

Per project policy there is **no backward-compat phase** — the schema is auto-created by eventium-postgresql; a fresh column is fine. If a migration/recreate step is needed for local dev, note it (drop/recreate the read-model table or bump the projection checkpoint).

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): surface contactId on transaction read model`.

---

### Task 14: Deletion guard — `ContactInUse` (3-way branch)

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs` (`findReferencingTransactions` ~:542-543)
- Modify: `src/Application/Services/ConfigurationService.hs` (`removeDictionaryEntry` binary→three-way branch ~:283-287)
- Test: `test/Application/Services/ConfigurationService*Spec.hs`

- [ ] **Step 1: Failing tests**
  - Removing a contact referenced by a transaction → `ContactInUse`.
  - Removing an unreferenced contact → succeeds.
  - Removing a category / label still behaves as before (regression guard — the branch is changing shape).
  - After removal of an unreferenced contact, historical rows that referenced a *different* contact remain resolvable.

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/removeDictionaryEntry/"`

- [ ] **Step 3: Implement**
- Extend `findReferencingTransactions` — note its real shape: `findReferencingTransactions :: DictionaryEntryId -> SqlPersistT m Int` takes **no kind** and already unconditionally *unions* category (allocation) refs + label refs (entry ids are globally unique, so the cross-kind union is safe by existing design). The change is simply to **add contact refs to that union**: a `WHERE contactId = ?` `selectList` on the transaction row (scalar column, not a join table). Do not add a kind parameter.
- Convert the binary label-vs-category `if/else` in `removeDictionaryEntry` (~:285-287) into a **three-way branch**: label → `LabelInUse`, category → `CategoryInUse`, contact → `ContactInUse`. Use a `case`/guard over `DictionaryKind` so a future kind fails compilation rather than silently skipping the guard.

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): block removal of in-use contacts (ContactInUse)`.

---

### Task 15: Web DTO + endpoints

**Files:**
- Modify: `src/Web/Types.hs` (`TransactionResponse` ~:611-638; `fromTransactionData` ~:1083-1109; `CreateIncome`/`CreateExpense` requests ~:383-453; new `SetTransactionContactRequest`; `parseContactId` beside `parseCategoryId` ~:1203)
- Modify: `src/Web/API/TransactionAPI.hs` (routes ~:150-168; create handlers ~:292-338; new set-contact handler mirroring `setLabelsHandler` ~:350-352)
- Test: `test/Web/API/TransactionAPISpec.hs`, and a new `test/Web/API/TransactionContactAPISpec.hs` (mirror `TransactionLabelsAPISpec.hs`)

- [ ] **Step 1: Failing Web API tests**
  - `POST` create income/expense with `contactId` → 2xx and `TransactionResponse.contactId` echoes it.
  - Create with unknown `contactId` → error mapped from `ContactNotFound`.
  - New set-contact endpoint updates the contact; response reflects it; `Nothing`/null clears it.
  - `GET` transaction includes `contactId`.
  - (No create-transfer-with-contact test — the `CreateTransfer` DTO has no contact field. The transfer reject is covered at the service layer in Tasks 9/11.)

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/TransactionContact/"`

- [ ] **Step 3: Implement**
- `TransactionResponse`: add `contactId :: Maybe UUID` (id only, no name). Map it in `fromTransactionData` from `TransactionData.contactId` (unwrap `DictionaryEntryId` to `UUID`).
- `CreateIncome`/`CreateExpense` request DTOs: add `contactId :: Maybe UUID`; parse via `parseContactId` (mirror `parseCategoryId`). **Do not** add it to `CreateTransfer`.
- Add `SetTransactionContactRequest { contactId :: Maybe UUID }`.
- **Amendment contact (landmine from Task 6 — must handle here):** `AmendTransaction.contactId` is **full-replacement** (`Nothing` = clear). The amendment handler in `TransactionAPI.hs` currently hardcodes `contactId = Nothing`, which would **silently wipe** a transaction's contact on every amendment once contact becomes settable. Fix in this task: add `contactId :: Maybe UUID` to `AmendTransactionRequest`, have the client send the full desired value, and thread it through the amendment handler (replace the hardcoded `Nothing`). If the amendment request should mean "leave contact unchanged when omitted," implement that by defaulting the dispatched command's `contactId` to the *existing* `transaction.contactId` in `TransactionService.amendTransaction` (mirroring the `newTransactionType` synthesis/overwrite) — and add a test proving an amendment that doesn't touch contact preserves it. Search `TransactionAPI.hs` for the `contactId = Nothing` comment referencing Task 15.
- `TransactionAPI`: add the set-contact route + handler (mirror `setLabelsHandler`) calling `TransactionService.setTransactionContact`; thread `contactId` through the income/expense create handlers.

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): expose contactId on transaction DTO and endpoints`.

---

### Task 16: Bank import — match-only `resolveContact`

**Files:**
- Modify: `src/Application/Services/BankImportService.hs` (`resolveContact` beside `resolveCategory` ~:358-387; `buildTransferCmd` ~:628-647; provenance logging beside `logCategoryResolution` ~:396-432; config already loaded at `commitMatchingCurrencyImport` ~:566-572)
- Test: `test/Application/Services/BankImportServiceSpec.hs`

- [ ] **Step 1: Failing tests**
  - A `BankTransaction` whose `description` matches an existing contact (case/whitespace-insensitive) → resulting `InitiateTransaction.contactId = Just <that id>`, and **no `AddDictionaryEntry` is issued** (assert the dictionary is unchanged / entry count constant).
  - Non-matching description → `contactId = Nothing`.
  - Blank/whitespace-only description → `Nothing`.
  - Runs only for income/expense (a matched-currency transfer import carries no contact).

- [ ] **Step 2: Run → FAIL.** `cabal test all --test-option='--match' --test-option="/resolveContact/"`

- [ ] **Step 3: Implement**

```haskell
data ContactResolution = MatchedExisting ContactId | NoMatch

resolveContact :: ConfigurationData -> TransactionKind -> Text -> ContactResolution
resolveContact cfg kind desc
  | kind `notElem` [IncomeKind, ExpenseKind] = NoMatch
  | T.null norm = NoMatch
  | otherwise = maybe NoMatch MatchedExisting (lookupByName norm)
  where
    norm = normalizeName desc                       -- trim + collapse internal whitespace
    lookupByName n =
      fmap fst
        . find (\(_, name) -> caseFold (unEntryName name) == caseFold n)
        $ dictionaryItems (dictionaries cfg ! contactsDictKind)  -- handle Map lookup safely
```

Normalize with a small pure helper (`T.strip` + collapse runs of whitespace to a single space). Match case-insensitively (`RIO.Text` case folding). It reads the already-loaded `ConfigurationData`; **it never issues a command**. Thread the result into `buildTransferCmd` as `InitiateTransaction.contactId` (no `ImportInfo` change). Log provenance next to `logCategoryResolution` (`merchant = tx.description`, resolution = matched/none).

- [ ] **Step 4: Run → PASS**; `just build`.

- [ ] **Step 5: Commit** `feat(contacts): match-only contact extraction during bank import`.

---

### Task 17: Integration tests

**Files:**
- Create: `test/Integration/TransactionContactIntegrationSpec.hs` (mirror `TransactionLabelsIntegrationSpec.hs`)
- Modify: `test/Integration/BankImportWorkflowSpec.hs`

- [ ] **Step 1: Write integration specs** (require `eventium_test` DB — see conventions):
  - Create income with contact → set a different contact → amend → project: `getTransaction` reflects the final contact at each step.
  - Remove-in-use contact → `ContactInUse`; remove after repointing/clearing → succeeds.
  - End-to-end import: pre-seed a contact, import a statement whose description matches → imported transaction links that contact; import a non-matching statement → no contact, dictionary unchanged.

- [ ] **Step 2: Run.** `cabal test all --test-option='--match' --test-option="/Contact/"` (start `just docker-up` + ensure `eventium_test` exists).
Expected: PASS (or environmental DB skip — note if so).

- [ ] **Step 3: Commit** `test(contacts): integration coverage for contact lifecycle and import`.

---

### Task 18: Full verification, hpack, hlint, docs

- [ ] **Step 1: Regenerate cabal + rebuild cold** (any new test module means `package.yaml`/hpack must run; a cold build gives a definitive `-Werror` check that the warm cache can mask):

Run: `just rebuild`
Expected: clean build.

- [ ] **Step 2: Full test + check**

Run: `just test` then `just check`
Expected: all green; ormolu + hlint clean (no suppressions).

- [ ] **Step 3: Flip spec status + link the plan**

Edit `docs/specs/2026-07-22-contact-dictionary-design.md` frontmatter `status: draft` → `status: completed`.

- [ ] **Step 4: Commit**

```bash
git add -A ; git commit -m "chore(contacts): finalize contact dictionary feature (tracker#41)"
```

- [ ] **Step 5: Open PR** (per user's git conventions — Conventional-Commit PR title, based off `master`):

```bash
git push -u origin feat/contact-dictionary
gh pr create --repo homeaccounting/backend --base master \
  --title "feat(contacts): optional contact (counterparty) on income & expense (tracker#41)" \
  --body "Implements tracker#41. See docs/specs/2026-07-22-contact-dictionary-design.md and docs/plans/2026-07-22-contact-dictionary.md. Web client work is out of scope (separate repo)."
```

---

## Definition of done

- Optional `contactId` accepted and validated on income/expense create, set-contact, and amendment; surfaced on the read model and DTO (id only).
- Contacts rejected on transfers/adjustments (`ContactNotAllowedOnTransfer`) on every path that shares a command shape.
- In-use contacts cannot be removed (`ContactInUse`); removal otherwise leaves history resolvable.
- Bank import links an existing contact by normalized description match, never creating entries.
- `just rebuild`, `just test`, `just check` all green; no hlint suppressions; LiquidHaskell verifies.
- Spec status `completed`; PR opened against `master`.
