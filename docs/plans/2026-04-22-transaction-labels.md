---
status: draft
date: 2026-04-22
spec: docs/specs/2026-04-22-transaction-labels-design.md
issue: homeaccounting/backend#30
---

# Transaction Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `labels` dictionary to user configuration and let every transaction carry a set of labels chosen from it. Also add edit endpoints to change labels and category on completed transactions, closing the "cannot re-classify past transactions" gap.

**Architecture:** Extend the existing CQRS + Event Sourcing stack along three axes: (1) treat `labels` as another well-known dictionary inside the `Configuration` aggregate, reusing its generic CRUD events and HTTP routes; (2) extend the Transaction aggregate with a `labels` field on `TransferInitiated` plus two new edit events (`TransactionLabelsSet`, `TransactionCategoryChanged`) that fire only in the `Completed` state; (3) block deletion of a dictionary entry that is still referenced by any transaction, via a service-layer in-use check over the existing `TransactionReadModel`.

**Tech Stack:** Haskell 9.10.3, RIO prelude, Servant, Eventium (event sourcing), PostgreSQL, Hspec + QuickCheck + hspec-discover, `just` task runner, ormolu + hlint via `just check`.

**Branch:** `feat/transaction-labels` (already created during brainstorming — the spec commits live here).

**Design reference:** `docs/specs/2026-04-22-transaction-labels-design.md`. Read the whole spec before starting; the plan is a delivery schedule, the spec is authoritative for semantics. If plan and spec disagree, flag it — do not silently diverge.

---

## File Map

Files created:

- `src/Application/Services/TransactionLabels.hs` — optional local module for the "find transactions referencing an entry" helper if it does not fit cleanly into `Application.ReadModels.Transaction`. Default: **add the helper directly to `Application.ReadModels.Transaction`** and skip this file; only create it if the read-model module grows unwieldy during Task 6.
- `test/Domain/Transaction/LabelsAndCategorySpec.hs` — command-handler unit tests for `SetTransactionLabels`, `ChangeTransactionCategory`.
- `test/Domain/Transaction/LabelsProjectionSpec.hs` — projection fold tests + property.
- `test/Domain/Configuration/LabelsDictionarySpec.hs` — command-handler unit tests for the relaxed `CannotRemoveLastEntry` rule.
- `test/Application/Services/ConfigurationServiceInUseSpec.hs` — in-use check on `removeDictionaryEntry` (exercises all three dictionaries).
- `test/Application/Services/TransactionServiceLabelsSpec.hs` — orchestration tests for label validation on create, edit operations, category change, access control.
- `test/Integration/TransactionLabelsIntegrationSpec.hs` — end-to-end flow from spec §6 "Integration".
- `test/Integration/TransactionCategoryEditIntegrationSpec.hs` — end-to-end for the category edit path.
- `test/Web/API/TransactionLabelsAPISpec.hs` — HTTP-level tests for `PUT /labels` and `PUT /category`.

Files modified:

- `src/Domain/Core/Types.hs` — add `type LabelId = DictionaryEntryId`.
- `src/Domain/Core/Errors.hs` — add new `DomainError` constructors.
- `src/Web/ErrorMapping.hs` — HTTP mapping for the new errors.
- `src/Domain/Transaction/Events.hs` — add `labels` to `TransferInitiated`; add `TransactionLabelsSet`, `TransactionCategoryChanged`; custom `FromJSON` for `TransferInitiated` with a default for `labels`.
- `src/Domain/Transaction/Commands.hs` — add `labels` to `InitiateTransfer`; add `SetTransactionLabels`, `ChangeTransactionCategory`.
- `src/Domain/Transaction/CommandHandler.hs` — handle the new commands; add `TransactionError` variants for the new rejection paths.
- `src/Domain/Transaction/Projection.hs` — add `labels` field; fold rules for the new events; update `transactionDefault`.
- `src/Domain/Configuration/CommandHandler.hs` — `requiresNonEmpty` predicate so the last-entry rule is skipped for `labels`.
- `src/Application/Services/ConfigurationService.hs` — add `labelsDictId`; add in-use check to `removeDictionaryEntry`.
- `src/Application/Services/TransactionService.hs` — validate labels on `initiateIncome`/`initiateExpense`/`initiateInternalTransfer`; implement `setTransactionLabels` and `changeTransactionCategory`.
- `src/Application/ReadModels/Transaction.hs` — add `labels :: Set DictionaryEntryId` to `TransactionData`; event handlers for the new events; `findReferencingTransactions` helper.
- `src/Web/Types.hs` — add `labels :: Maybe [UUID]` to request DTOs; add `labels :: [UUID]` to `TransactionResponse`; new `SetTransactionLabelsRequest`, `ChangeTransactionCategoryRequest`.
- `src/Web/API/TransactionAPI.hs` — wire the new `PUT /:id/labels` and `PUT /:id/category` endpoints; pass labels through to the service; include labels in existing responses.
- `test/Testkit/Generators.hs` — `genLabelSet`; fix the existing `genDictionaryId` list to include `"labels"`.

Every source edit lands in a commit that ships with its associated tests — the build stays green at every task boundary.

---

## Task 1 — New `DomainError` constructors and HTTP mapping

Keeps the build green and unblocks subsequent tasks that return these errors.

**Files:**
- Modify: `src/Domain/Core/Errors.hs`
- Modify: `src/Web/ErrorMapping.hs`
- Test: touched by existing ErrorMapping specs indirectly (no new spec file here).

- [ ] **Step 1.1: Add the new constructors to `DomainError`.**

In `src/Domain/Core/Errors.hs`, extend the `DomainError` sum type (after `FeatureDisabled Text`). Use the exact shapes from spec §5:

```haskell
  | -- | The referenced label does not exist in the user's labels dictionary.
    LabelNotFound Text
  | -- | The referenced category does not exist in the applicable dictionary.
    CategoryNotFound Text
  | -- | Cannot delete a label — still referenced by existing transactions.
    LabelInUse
      { entryId :: Text,
        usageCount :: Int
      }
  | -- | Cannot delete a category — still referenced by existing transactions.
    CategoryInUse
      { entryId :: Text,
        usageCount :: Int
      }
  | -- | Cannot edit labels on a transaction that is not in the Completed state.
    CannotEditTransactionLabelsInCurrentState
  | -- | Cannot change the category on an internal (no-category) transfer.
    CannotChangeCategoryOnInternalTransfer
```

Rationale for carrying UUIDs as `Text`: the `DomainError` module must not import `Domain.Core.Types`, otherwise the two modules become mutually recursive. The service layer converts `DictionaryEntryId` → `Text` at the point of constructing the error (UUIDs serialise trivially via `tshow`).

- [ ] **Step 1.2: Extend `renderDomainError` for the new cases.**

Add matching prose in `renderDomainError`:

```haskell
  LabelNotFound eid -> "Label not found: " <> eid
  CategoryNotFound eid -> "Category not found: " <> eid
  LabelInUse eid n ->
    "Cannot delete label " <> eid <> ": referenced by " <> T.pack (show n) <> " transaction(s)"
  CategoryInUse eid n ->
    "Cannot delete category " <> eid <> ": referenced by " <> T.pack (show n) <> " transaction(s)"
  CannotEditTransactionLabelsInCurrentState ->
    "Transaction labels can only be changed after the transfer has completed"
  CannotChangeCategoryOnInternalTransfer ->
    "Category cannot be set on an internal transfer"
```

- [ ] **Step 1.3: Add the HTTP mapping in `Web.ErrorMapping.mapDomainError`.**

Insert new cases in `src/Web/ErrorMapping.hs` before the catch-all. Use `err404` for not-found, `err409` (import from `Servant.Server`) for conflicts. If `err409` is not already exported, bring it in:

```haskell
import Servant.Server (ServerError, err400, err404, err409, err422, errBody)
```

```haskell
mapDomainError (LabelNotFound eid) =
  err404
    { errBody =
        encode $
          ErrorResponse
            { message = "Label not found",
              code = "LABEL_NOT_FOUND",
              details = Just $ Map.singleton "entryId" eid
            }
    }
mapDomainError (CategoryNotFound eid) =
  err404
    { errBody =
        encode $
          ErrorResponse
            { message = "Category not found",
              code = "CATEGORY_NOT_FOUND",
              details = Just $ Map.singleton "entryId" eid
            }
    }
mapDomainError (LabelInUse eid n) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Label is referenced by existing transactions",
              code = "LABEL_IN_USE",
              details =
                Just $
                  Map.fromList
                    [ ("entryId", eid),
                      ("usageCount", tshow n)
                    ]
            }
    }
mapDomainError (CategoryInUse eid n) =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Category is referenced by existing transactions",
              code = "CATEGORY_IN_USE",
              details =
                Just $
                  Map.fromList
                    [ ("entryId", eid),
                      ("usageCount", tshow n)
                    ]
            }
    }
mapDomainError CannotEditTransactionLabelsInCurrentState =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Transaction labels can only be changed after the transfer has completed",
              code = "TRANSACTION_NOT_COMPLETED",
              details = Nothing
            }
    }
mapDomainError CannotChangeCategoryOnInternalTransfer =
  err409
    { errBody =
        encode $
          ErrorResponse
            { message = "Category cannot be set on an internal transfer",
              code = "CATEGORY_NOT_APPLICABLE",
              details = Nothing
            }
    }
```

- [ ] **Step 1.4: Build + check.**

```bash
nix develop --command just build
nix develop --command just check
```

Expected: green. No existing behaviour changes.

- [ ] **Step 1.5: Commit.**

```bash
git add src/Domain/Core/Errors.hs src/Web/ErrorMapping.hs
git commit -m "$(cat <<'EOF'
feat(errors): add label/category error constructors (#30)

Introduces the DomainError cases used by the upcoming transaction
labels feature: LabelNotFound, CategoryNotFound, LabelInUse,
CategoryInUse, CannotEditTransactionLabelsInCurrentState,
CannotChangeCategoryOnInternalTransfer. HTTP mapping routes the
"not found" variants to 404 and the remaining ones to 409.

Promoting CategoryNotFound to a first-class error (rather than a
generic validation error) lets both the creation and edit paths share
one mapping.
EOF
)"
git push -u origin feat/transaction-labels
```

---

## Task 2 — `LabelId` alias and relaxed "last entry" rule in Configuration

Introduces the label type alias and makes the "cannot remove last entry" rule dictionary-specific.

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Modify: `src/Domain/Configuration/CommandHandler.hs`
- Modify: `src/Application/Services/ConfigurationService.hs`
- Create: `test/Domain/Configuration/LabelsDictionarySpec.hs`

- [ ] **Step 2.1: Add the type alias.**

In `src/Domain/Core/Types.hs`, near the `DictionaryEntryId` definition, add:

```haskell
-- | Alias for a label identifier. Labels reuse the same storage as
-- dictionary entries; treating them as aliases avoids a parallel type
-- hierarchy while keeping spec language ("labels") intact at call sites.
type LabelId = DictionaryEntryId
```

Export `LabelId` from the module header.

- [ ] **Step 2.2: Add the well-known `labelsDictId`.**

In `src/Application/Services/ConfigurationService.hs`, alongside `incomeCategoryDictId` / `expenseCategoryDictId` (around line 90–95), add:

```haskell
-- | Dictionary ID for transaction labels (optional, multi-valued per txn).
labelsDictId :: DictionaryId
labelsDictId = DictionaryId "labels"
```

Export it from the module's export list (near the other two):

```haskell
    -- * Well-known Dictionary IDs
    incomeCategoryDictId,
    expenseCategoryDictId,
    labelsDictId,
```

- [ ] **Step 2.3: Write the failing spec for relaxed last-entry rule.**

Create `test/Domain/Configuration/LabelsDictionarySpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.LabelsDictionarySpec
-- Description : Relaxed CannotRemoveLastEntry rule for the `labels` dictionary.
module Domain.Configuration.LabelsDictionarySpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import Domain.Configuration.CommandHandler
  ( ConfigurationCommand (..),
    ConfigurationError (..),
    handleConfigurationCommand,
  )
import Domain.Configuration.Commands (RemoveDictionaryEntry (..))
import Domain.Configuration.Projection (Configuration (..))
import Domain.Core.Types
  ( CreatedBy (System),
    Currency (USD),
    Dictionary (..),
    DictionaryEntry (..),
    DictionaryId (..),
    unsafeDictionaryEntryId,
    unsafeEntryName,
  )
import RIO
import Test.Hspec

seedConfig :: DictionaryId -> Configuration
seedConfig dictId =
  Configuration
    { baseCurrency = USD,
      defaultCurrency = USD,
      dictionaries =
        Map.singleton
          dictId
          Dictionary
            { entries =
                [ DictionaryEntry
                    { entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0),
                      name = unsafeEntryName "only"
                    }
                ]
            },
      createdBy = System,
      isCreated = True
    }

spec :: Spec
spec = describe "CannotRemoveLastEntry predicate" $ do
  it "still refuses for income-category when it would become empty" $
    let config = seedConfig (DictionaryId "income-category")
        cmd =
          RemoveDictionaryEntryConfigurationCommand
            RemoveDictionaryEntry
              { dictionaryId = DictionaryId "income-category",
                entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
              }
     in handleConfigurationCommand config cmd `shouldBe` Left CannotRemoveLastEntry

  it "still refuses for expense-category when it would become empty" $
    let config = seedConfig (DictionaryId "expense-category")
        cmd =
          RemoveDictionaryEntryConfigurationCommand
            RemoveDictionaryEntry
              { dictionaryId = DictionaryId "expense-category",
                entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
              }
     in handleConfigurationCommand config cmd `shouldBe` Left CannotRemoveLastEntry

  it "allows removing the last labels entry" $
    let config = seedConfig (DictionaryId "labels")
        cmd =
          RemoveDictionaryEntryConfigurationCommand
            RemoveDictionaryEntry
              { dictionaryId = DictionaryId "labels",
                entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
              }
     in handleConfigurationCommand config cmd `shouldSatisfy` isRight
```

- [ ] **Step 2.4: Run — confirm failure.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='CannotRemoveLastEntry predicate'
```

Expected: the third case fails (`Left CannotRemoveLastEntry` vs. `isRight`).

- [ ] **Step 2.5: Relax the rule in `Domain.Configuration.CommandHandler`.**

Replace the `isLastEntry` helper (lines 88–93) and the `RemoveDictionaryEntry` branch (lines 164–177) to go through a predicate:

```haskell
-- | Dictionaries that must never become empty.
-- income-category and expense-category are required because every Income
-- and Expense transaction references exactly one entry.
-- The `labels` dictionary is optional — may be emptied freely.
requiresNonEmpty :: DictionaryId -> Bool
requiresNonEmpty (DictionaryId "income-category") = True
requiresNonEmpty (DictionaryId "expense-category") = True
requiresNonEmpty _ = False

-- | Check whether removing the targeted entry would empty a required dictionary.
wouldEmptyRequiredDictionary :: DictionaryId -> Configuration -> Bool
wouldEmptyRequiredDictionary dictId config
  | not (requiresNonEmpty dictId) = False
  | otherwise =
      case Map.lookup dictId config.dictionaries of
        Nothing -> False
        Just dict -> length dict.entries == 1
```

Then in the `RemoveDictionaryEntry` guard:

```haskell
handleConfigurationCommand config (RemoveDictionaryEntryConfigurationCommand RemoveDictionaryEntry {..})
  | not config.isCreated = Left ConfigurationNotCreated
  | not (dictionaryExists dictionaryId config) = Left DictionaryNotFound
  | not (entryExists entryId dictionaryId config) = Left EntryNotFound
  | wouldEmptyRequiredDictionary dictionaryId config = Left CannotRemoveLastEntry
  | otherwise = ...
```

Delete the now-unused `isLastEntry` helper.

- [ ] **Step 2.6: Run — confirm green.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='CannotRemoveLastEntry predicate'
```

Expected: all three cases green. Also re-run the existing configuration command-handler spec to be sure nothing regressed:

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='/Domain.Configuration/'
```

- [ ] **Step 2.7: `just check` and commit.**

```bash
nix develop --command just check

git add src/Domain/Core/Types.hs \
        src/Application/Services/ConfigurationService.hs \
        src/Domain/Configuration/CommandHandler.hs \
        test/Domain/Configuration/LabelsDictionarySpec.hs
git commit -m "$(cat <<'EOF'
feat(config): labels dictionary + relaxed last-entry rule (#30)

- Introduces labelsDictId ("labels") alongside income/expense categories.
- Adds a LabelId type alias over DictionaryEntryId.
- Makes CannotRemoveLastEntry dictionary-specific: income/expense still
  refuse, labels may be emptied freely.
EOF
)"
git push
```

---

## Task 3 — Extend `TransferInitiated` with `labels` (backwards-compatible)

Adds the per-transaction label set, in one atomic change covering event, command, projection, default state, and read model. Includes a custom `FromJSON` so old serialised events still deserialise.

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Modify: `src/Domain/Transaction/Projection.hs`
- Modify: `src/Application/ReadModels/Transaction.hs`
- Test: extend existing `test/Domain/Transaction/*Spec.hs` where applicable (no new file yet).

- [ ] **Step 3.1: Add `labels` to `TransferInitiated` event.**

In `src/Domain/Transaction/Events.hs`:

```haskell
import Data.Set (Set)
import qualified Data.Set as Set
import Domain.Core.Types (AccountId, DictionaryEntryId, ExchangeRate, ExternalTransactionId, Money, TransferType, UserId)
```

Extend the record:

```haskell
data TransferInitiated = TransferInitiated
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    by :: UserId,
    transferType :: TransferType,
    externalTransactionId :: Maybe ExternalTransactionId,
    -- | Labels attached to this transfer (may be empty).
    labels :: Set DictionaryEntryId
  }
  deriving (Show, Eq)
```

Replace the `deriveJSON defaultOptions ''TransferInitiated` line with:

```haskell
deriveToJSON defaultOptions ''TransferInitiated

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Maybe (fromMaybe)

instance FromJSON TransferInitiated where
  parseJSON = withObject "TransferInitiated" $ \o ->
    TransferInitiated
      <$> o .: "sourceAccountId"
      <*> o .: "targetAccountId"
      <*> o .: "sourceAmount"
      <*> o .: "targetAmount"
      <*> o .:? "exchangeRate" .!= Nothing  -- explicit: was already nullable
      <*> o .: "description"
      <*> o .: "by"
      <*> o .: "transferType"
      <*> o .:? "externalTransactionId" .!= Nothing
      <*> (fromMaybe Set.empty <$> o .:? "labels")
```

Update the import and exported-name line:

```haskell
import Data.Aeson.TH (defaultOptions, deriveToJSON)
```

> `.!=` comes from `Data.Aeson`; add it to the import list.

Rationale: `deriveJSON` generates a FromJSON that fails on missing fields. Old persisted `TransferInitiated` events lack `labels`; defaulting to `Set.empty` keeps replay working. Keeping the manual parser verbose (spelling out every field) documents the wire contract explicitly.

- [ ] **Step 3.2: Add `labels` to `InitiateTransfer` command.**

In `src/Domain/Transaction/Commands.hs`:

```haskell
import Data.Set (Set)
import Domain.Core.Types (AccountId, DictionaryEntryId, ExchangeRate, ExternalTransactionId, Money, TransferType, UserId)
```

Extend the record:

```haskell
data InitiateTransfer = InitiateTransfer
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    initiatedBy :: UserId,
    transferType :: TransferType,
    externalTransactionId :: Maybe ExternalTransactionId,
    labels :: Set DictionaryEntryId
  }
  deriving (Show, Eq)
```

> Unlike events, `InitiateTransfer` is never persisted — it is an in-memory command. Keep `deriveJSON defaultOptions ''InitiateTransfer` as-is; JSON support is there only for Telegram bot command shipping. If the bot sends `InitiateTransfer` commands without `labels`, extend a custom FromJSON by the same pattern; otherwise leave the default.

- [ ] **Step 3.3: Propagate `labels` through the command handler.**

In `src/Domain/Transaction/CommandHandler.hs` (lines 117–143), the `InitiateTransfer` branch: add the new field when constructing the event:

```haskell
Right
  [ TransferInitiatedTransactionEvent
      TransferInitiated
        { sourceAccountId = sourceAccountId,
          targetAccountId = targetAccountId,
          sourceAmount = sourceAmount,
          targetAmount = targetAmount,
          exchangeRate = exchangeRate,
          description = description,
          by = initiatedBy,
          transferType = transferType,
          externalTransactionId = externalTransactionId,
          labels = labels
        }
  ]
```

- [ ] **Step 3.4: Add `labels` to the aggregate projection.**

In `src/Domain/Transaction/Projection.hs`:

```haskell
import Data.Set (Set)
import qualified Data.Set as Set
import Domain.Core.Types (AccountId, DictionaryEntryId, ExchangeRate, Money, TransferType (..), UserId, mkAccountId, mkDefaultMoney, unsafeDictionaryEntryId, unsafeUserId)
```

Extend the `Transaction` record:

```haskell
data Transaction = Transaction
  { ...
    transferType :: TransferType,
    labels :: Set DictionaryEntryId
  }
```

Extend `transactionDefault` with `labels = Set.empty`.

In `handleTransactionEvent` for `TransferInitiatedTransactionEvent`, add:

```haskell
& #labels .~ evt.labels
```

- [ ] **Step 3.5: Add `labels` to the read model `TransactionData`.**

In `src/Application/ReadModels/Transaction.hs`, extend `TransactionData`:

```haskell
data TransactionData
  = TransactionData
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    status :: TransactionStatus,
    transferType :: TransferType,
    date :: UTCTime,
    labels :: Set DictionaryEntryId
  }
```

Extend `processEvent` for `TransferInitiatedEvent` so the new entry carries labels:

```haskell
newEntry =
  TransactionData
    { ...
      date = eventDate,
      labels = evt.labels
    }
```

- [ ] **Step 3.6: Fix all remaining construction sites.**

Every place that builds an `InitiateTransfer` now has to supply `labels`. Grep for call sites:

```bash
rg -n "InitiateTransfer " src test
```

For Task 3, default every call site to `labels = Set.empty`. The upload services (bank import, telegram bot, HTTP handlers) will be given the real labels in Task 7. Same for `TransferInitiated` construction in tests — default to `Set.empty`.

- [ ] **Step 3.7: Build — expect a handful of type errors pointing at the grep hits.**

```bash
nix develop --command just build
```

Expected: errors about missing `labels` record field at the grep hits. Fix each one by adding `labels = Set.empty`.

- [ ] **Step 3.8: Run the full test suite.**

```bash
nix develop --command just test
```

Expected: green. The backwards-compatible FromJSON handles any pre-existing fixture events.

- [ ] **Step 3.9: `just check` and commit.**

```bash
nix develop --command just check
git add -A
git commit -m "$(cat <<'EOF'
feat(transaction): labels field on TransferInitiated (#30)

Adds `labels :: Set DictionaryEntryId` to InitiateTransfer command,
TransferInitiated event, Transaction projection, and the transaction
read model. The field defaults to an empty set and keeps existing
serialised events readable via a custom FromJSON parser.
EOF
)"
git push
```

---

## Task 4 — New Transaction events + commands for label / category edits

Introduces the two edit events and commands with their command-handler rules.

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`
- Modify: `src/Domain/Transaction/Commands.hs`
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Modify: `src/Domain/Transaction/Projection.hs`
- Create: `test/Domain/Transaction/LabelsAndCategorySpec.hs`
- Create: `test/Domain/Transaction/LabelsProjectionSpec.hs`

- [ ] **Step 4.1: Write the failing command-handler spec.**

Create `test/Domain/Transaction/LabelsAndCategorySpec.hs` (paths and imports follow existing command-handler spec patterns; see `test/Domain/Transaction/CommandHandlerSpec.hs` for a reference if one exists, or `test/Domain/Account/CommandHandlerSpec.hs` otherwise).

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.LabelsAndCategorySpec
-- Description : SetTransactionLabels / ChangeTransactionCategory command-handler rules.
module Domain.Transaction.LabelsAndCategorySpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types (TransferType (..), unsafeDictionaryEntryId)
import Domain.Transaction.CommandHandler
  ( TransactionCommand (..),
    TransactionError (..),
    handleTransactionCommand,
  )
import Domain.Transaction.Commands
  ( ChangeTransactionCategory (..),
    SetTransactionLabels (..),
  )
import Domain.Transaction.Projection
  ( Transaction (..),
    TransactionStatus (..),
    transactionDefault,
  )
import RIO
import Test.Hspec

completedIncome :: Transaction
completedIncome =
  transactionDefault
    { status = Completed,
      transferType = Income (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0))
    }

completedExpense :: Transaction
completedExpense =
  transactionDefault
    { status = Completed,
      transferType = Expense (unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0))
    }

completedTransfer :: Transaction
completedTransfer =
  transactionDefault
    { status = Completed,
      transferType = Transfer
    }

pendingIncome :: Transaction
pendingIncome = completedIncome {status = Pending}

spec :: Spec
spec = do
  describe "SetTransactionLabels" $ do
    it "accepted in Completed state and emits TransactionLabelsSet" $ do
      let cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = unsafeTransactionId',
                  labels = Set.fromList [unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0)]
                }
      handleTransactionCommand completedTransfer cmd `shouldSatisfy` isRight

    it "rejected on Pending with CannotEditLabelsInCurrentState" $ do
      let cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = unsafeTransactionId',
                  labels = Set.empty
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditLabelsInCurrentState

    it "rejected on Failed with CannotEditLabelsInCurrentState" $ do
      let failed = completedIncome {status = Failed "nope"}
          cmd =
            SetTransactionLabelsTransactionCommand
              SetTransactionLabels
                { transactionId = unsafeTransactionId',
                  labels = Set.empty
                }
      handleTransactionCommand failed cmd `shouldBe` Left CannotEditLabelsInCurrentState

  describe "ChangeTransactionCategory" $ do
    it "accepted on Income and emits TransactionCategoryChanged" $ do
      let newId = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)
          cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = unsafeTransactionId',
                  newCategory = newId
                }
      handleTransactionCommand completedIncome cmd `shouldSatisfy` isRight

    it "accepted on Expense" $ do
      let newId = unsafeDictionaryEntryId (UUID.fromWords 5 0 0 0)
          cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = unsafeTransactionId',
                  newCategory = newId
                }
      handleTransactionCommand completedExpense cmd `shouldSatisfy` isRight

    it "rejected on internal Transfer with CannotChangeCategoryOnInternalTransfer" $ do
      let cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = unsafeTransactionId',
                  newCategory = unsafeDictionaryEntryId (UUID.fromWords 6 0 0 0)
                }
      handleTransactionCommand completedTransfer cmd
        `shouldBe` Left CannotChangeCategoryOnInternalTransfer

    it "rejected in Pending state with CannotEditLabelsInCurrentState" $ do
      let cmd =
            ChangeTransactionCategoryTransactionCommand
              ChangeTransactionCategory
                { transactionId = unsafeTransactionId',
                  newCategory = unsafeDictionaryEntryId (UUID.fromWords 7 0 0 0)
                }
      handleTransactionCommand pendingIncome cmd `shouldBe` Left CannotEditLabelsInCurrentState
  where
    -- | The handler validates only aggregate state and command-domain contents,
    -- but the field is still populated with a real value (CLAUDE.md forbids
    -- partial functions — no `error` / `undefined` placeholders).
    unsafeTransactionId' = unsafeTransactionId (UUID.fromWords 100 0 0 0)
```

Add `unsafeTransactionId` to the `Domain.Core.Types` import.

- [ ] **Step 4.2: Run — expect failure (types don't exist yet).**

```bash
nix develop --command just build
```

Expected: compile errors pointing at `SetTransactionLabels`, `ChangeTransactionCategory`, `CannotEditLabelsInCurrentState`, `CannotChangeCategoryOnInternalTransfer`.

- [ ] **Step 4.3: Add the events.**

In `src/Domain/Transaction/Events.hs`:

```haskell
data TransactionLabelsSet = TransactionLabelsSet
  { -- | The transaction whose labels changed. Carried in the payload for
    -- symmetry with TransferFailed {reason}; the stream key (the aggregate id)
    -- is authoritative.
    transactionId :: TransactionId,
    labels :: Set DictionaryEntryId
  }
  deriving (Show, Eq)

data TransactionCategoryChanged = TransactionCategoryChanged
  { transactionId :: TransactionId,
    newCategory :: DictionaryEntryId
  }
  deriving (Show, Eq)
```

Register them in `transactionEvents`:

```haskell
transactionEvents :: [Name]
transactionEvents =
  [ ''TransferInitiated,
    ''TransferCompleted,
    ''TransferFailed,
    ''TransactionLabelsSet,
    ''TransactionCategoryChanged
  ]
```

Derive JSON for both (standard `deriveJSON defaultOptions`).

Export both from the module header.

- [ ] **Step 4.4: Add the commands.**

In `src/Domain/Transaction/Commands.hs`, mirror the events:

```haskell
data SetTransactionLabels = SetTransactionLabels
  { transactionId :: TransactionId,
    labels :: Set DictionaryEntryId
  }
  deriving (Show, Eq)

data ChangeTransactionCategory = ChangeTransactionCategory
  { transactionId :: TransactionId,
    newCategory :: DictionaryEntryId
  }
  deriving (Show, Eq)
```

Register in `transactionCommands`, export, derive JSON.

- [ ] **Step 4.5: Extend `TransactionError`.**

In `src/Domain/Transaction/CommandHandler.hs`:

```haskell
data TransactionError
  = TransactionAlreadyInitiated
  | TransactionNotPending
  | TransferToSameAccount
  | TransferAmountNotPositive
  | CannotEditLabelsInCurrentState
  | CannotChangeCategoryOnInternalTransfer
  deriving (Show, Eq)
```

> These are **aggregate-local** errors. The `DomainError` equivalents added in Task 1 (`CannotEditTransactionLabelsInCurrentState`, `CannotChangeCategoryOnInternalTransfer`) are produced by the service layer by translating from the aggregate error. This two-layer structure matches the pattern used for `AccountError` / `TransactionError` throughout the project.

- [ ] **Step 4.6: Implement the handler rules.**

Add two new branches to `handleTransactionCommand`:

```haskell
handleTransactionCommand transaction (SetTransactionLabelsTransactionCommand SetTransactionLabels {..}) =
  case transaction ^. #status of
    Completed ->
      Right
        [ TransactionLabelsSetTransactionEvent
            TransactionLabelsSet
              { transactionId = transactionId,
                labels = labels
              }
        ]
    _ -> Left CannotEditLabelsInCurrentState
handleTransactionCommand transaction (ChangeTransactionCategoryTransactionCommand ChangeTransactionCategory {..}) =
  case transaction ^. #status of
    Completed ->
      case transaction ^. #transferType of
        Transfer -> Left CannotChangeCategoryOnInternalTransfer
        Income _ ->
          Right
            [ TransactionCategoryChangedTransactionEvent
                TransactionCategoryChanged
                  { transactionId = transactionId,
                    newCategory = newCategory
                  }
            ]
        Expense _ ->
          Right
            [ TransactionCategoryChangedTransactionEvent
                TransactionCategoryChanged
                  { transactionId = transactionId,
                    newCategory = newCategory
                  }
            ]
    _ -> Left CannotEditLabelsInCurrentState
```

- [ ] **Step 4.7: Extend the projection.**

In `src/Domain/Transaction/Projection.hs`, add two more `handleTransactionEvent` branches:

```haskell
handleTransactionEvent transaction (TransactionLabelsSetTransactionEvent evt) =
  case transaction ^. #status of
    Completed -> transaction & #labels .~ evt.labels
    _ -> transaction -- defensive: projection accepts the event even if the
                    -- command handler would reject re-setting in non-Completed.
                    -- In practice the handler is authoritative, so this branch
                    -- is unreachable on well-formed streams.
handleTransactionEvent transaction (TransactionCategoryChangedTransactionEvent evt) =
  let newTT = case transaction ^. #transferType of
        Income _ -> Income evt.newCategory
        Expense _ -> Expense evt.newCategory
        Transfer -> Transfer -- unreachable; command handler rejects
   in transaction & #transferType .~ newTT
```

- [ ] **Step 4.8: Run the command-handler spec — expect green.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='/Domain.Transaction/'
```

Expected: all new cases green, old cases unaffected.

- [ ] **Step 4.9: Add the projection spec + property.**

Create `test/Domain/Transaction/LabelsProjectionSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Transaction.LabelsProjectionSpec
-- Description : Projection fold rules + property for labels / category edits.
module Domain.Transaction.LabelsProjectionSpec (spec) where

import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Types (DictionaryEntryId, TransferType (..), unsafeDictionaryEntryId, unsafeTransactionId)
import Domain.Transaction.Events
  ( TransactionCategoryChanged (..),
    TransactionLabelsSet (..),
    TransferInitiated (..),
  )
import Domain.Transaction.Projection
  ( Transaction (..),
    TransactionEvent (..),
    TransactionStatus (..),
    transactionDefault,
  )
import Eventium (Projection (..), latestProjection)
import RIO
import Test.Hspec
import Test.QuickCheck
import qualified Testkit.Generators as G

seedInitiated :: [DictionaryEntryId] -> TransactionEvent
seedInitiated ls = TransferInitiatedTransactionEvent $
  (mkTransferInitiated transactionDefault) {labels = Set.fromList ls}
  where
    mkTransferInitiated t =
      TransferInitiated
        { sourceAccountId = t.sourceAccountId,
          targetAccountId = t.targetAccountId,
          sourceAmount = t.sourceAmount,
          targetAmount = t.targetAmount,
          exchangeRate = t.exchangeRate,
          description = t.description,
          by = t.initiatedBy,
          transferType = Income (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)),
          externalTransactionId = Nothing,
          labels = Set.empty
        }

completed :: TransactionEvent
completed = TransferCompletedTransactionEvent TransferCompleted

-- Note: TransferCompleted is a marker record exported from Domain.Transaction.Events;
-- import it alongside TransferInitiated. If the existing codebase has renamed it,
-- mirror the name used in test/Domain/Transaction/ProjectionSpec.hs.
```

…continue with Spec cases mirroring the design §6:

```haskell
spec :: Spec
spec = describe "Transaction projection / labels + category edits" $ do
  it "folds TransactionLabelsSet after completion replaces the set" $ do
    let l1 = unsafeDictionaryEntryId (UUID.fromWords 10 0 0 0)
        l2 = unsafeDictionaryEntryId (UUID.fromWords 20 0 0 0)
        l3 = unsafeDictionaryEntryId (UUID.fromWords 30 0 0 0)
        evts =
          [ seedInitiated [l1],
            completed,
            TransactionLabelsSetTransactionEvent
              TransactionLabelsSet
                { transactionId = unsafeTransactionId (UUID.fromWords 77 0 0 0),
                  labels = Set.fromList [l2, l3]
                }
          ]
        Transaction {labels} =
          latestProjection
            (Projection transactionDefault Domain.Transaction.Projection.handleTransactionEvent)
            evts
    labels `shouldBe` Set.fromList [l2, l3]

  it "ChangeTransactionCategory rewrites the categorised TransferType" $ do
    let original = unsafeDictionaryEntryId (UUID.fromWords 40 0 0 0)
        replacement = unsafeDictionaryEntryId (UUID.fromWords 50 0 0 0)
        seed =
          (seedInitiated [])
            & case _ of
                TransferInitiatedTransactionEvent t ->
                  TransferInitiatedTransactionEvent
                    t {transferType = Income original}
                e -> e
        evts =
          [ seed,
            completed,
            TransactionCategoryChangedTransactionEvent
              TransactionCategoryChanged
                { transactionId = unsafeTransactionId (UUID.fromWords 77 0 0 0),
                  newCategory = replacement
                }
          ]
        Transaction {transferType} =
          latestProjection
            (Projection transactionDefault Domain.Transaction.Projection.handleTransactionEvent)
            evts
    transferType `shouldBe` Income replacement
```

Property:

```haskell
  describe "Property: last TransactionLabelsSet wins" $
    it "fold of N label-set events yields the last event's set" $
      property $ \sets ->
        not (null sets) ==>
          let l0 = seedInitiated []
              setEvents =
                [ TransactionLabelsSetTransactionEvent
                    TransactionLabelsSet
                      { transactionId = unsafeTransactionId (UUID.fromWords 77 0 0 0),
                        labels = s
                      }
                  | s <- sets
                ]
              Transaction {labels} =
                latestProjection
                  (Projection transactionDefault Domain.Transaction.Projection.handleTransactionEvent)
                  (l0 : completed : setEvents)
           in labels === last sets
```

Add Arbitrary for `Set DictionaryEntryId` in `Testkit/Generators.hs` if not already present (see Task 8).

> If any of the constructors I referenced (`TransferCompleted`, `latestProjection`) have slightly different shapes in the current codebase, mirror whatever the existing `test/Domain/Transaction/ProjectionSpec.hs` uses. The goal is correctness of the assertions, not exact imports.

- [ ] **Step 4.10: Run the projection spec + property — expect green.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='Transaction projection / labels'
```

- [ ] **Step 4.11: `just check` and commit.**

```bash
nix develop --command just check

git add src/Domain/Transaction/Events.hs \
        src/Domain/Transaction/Commands.hs \
        src/Domain/Transaction/CommandHandler.hs \
        src/Domain/Transaction/Projection.hs \
        test/Domain/Transaction/LabelsAndCategorySpec.hs \
        test/Domain/Transaction/LabelsProjectionSpec.hs
git commit -m "$(cat <<'EOF'
feat(transaction): TransactionLabelsSet / TransactionCategoryChanged (#30)

Introduces two new Transaction aggregate events with matching commands:

- SetTransactionLabels replaces the stored label set; accepted only in
  the Completed state.
- ChangeTransactionCategory replaces the category on Income/Expense
  transactions; rejected on internal transfers and in non-Completed
  states.

The projection folds both events to mutate labels and the categorised
TransferType in place.
EOF
)"
git push
```

---

## Task 5 — Register new events on the read model

`Application.ReadModels.Transaction` currently processes only `TransferInitiated`, `TransferCompleted`, `TransferFailed`. Extend it.

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs`
- Modify: `src/Domain/Models.hs` (if `AccountingEvent` is the union that needs extending — grep to confirm).

- [ ] **Step 5.1: Confirm how events reach the read model.**

```bash
rg -n "AccountingEvent" src/Domain/Models.hs | head
```

The existing pattern is likely a sum wrapping per-aggregate event types (`TransferInitiatedEvent`, `TransferCompletedEvent`, etc.). Two possible shapes:

- (a) `AccountingEvent` is built by a TH splice over all aggregate event lists — in which case registering `TransactionLabelsSet`/`TransactionCategoryChanged` in `transactionEvents` (Task 4) already extends `AccountingEvent` via the generated constructors `TransactionLabelsSetEvent` / `TransactionCategoryChangedEvent`. Verify by inspecting the generated names in `Domain.Models`.
- (b) `AccountingEvent` is a hand-written sum that enumerates constructors manually — in which case add the new constructors here.

Pick the path matching your code.

- [ ] **Step 5.2: Add read-model fold cases for the two new events.**

In `src/Application/ReadModels/Transaction.hs`, extend `processEvent`:

```haskell
TransactionLabelsSetEvent evt ->
  case mkTransactionIdSafe streamUuid of
    Nothing -> summaries
    Just transactionId ->
      Map.adjust
        (\summary -> summary {labels = evt.labels})
        transactionId
        summaries
TransactionCategoryChangedEvent evt ->
  case mkTransactionIdSafe streamUuid of
    Nothing -> summaries
    Just transactionId ->
      Map.adjust
        ( \summary ->
            summary
              { transferType = case summary.transferType of
                  Income _ -> Income evt.newCategory
                  Expense _ -> Expense evt.newCategory
                  Transfer -> Transfer -- unreachable for well-formed streams
              }
        )
        transactionId
        summaries
```

Imports: add `Domain.Transaction.Events` members `TransactionCategoryChanged (..)`, `TransactionLabelsSet (..)`; ensure `TransferType(..)` is imported for the pattern match.

- [ ] **Step 5.3: Add the `findReferencingTransactions` helper.**

In `src/Application/ReadModels/Transaction.hs`:

```haskell
-- | Count transactions referencing the given dictionary entry id, either
-- as a label (via TransactionData.labels) or as the categorised
-- TransferType (Income / Expense).
findReferencingTransactions ::
  (MonadIO m) =>
  TVar TransactionReadModel ->
  DictionaryEntryId ->
  m Int
findReferencingTransactions readModelTVar entryId = do
  model <- liftIO $ readTVarIO readModelTVar
  let matches =
        [ ()
        | td <- Map.elems model.summaryData,
          referencesEntry td
        ]
  pure (length matches)
  where
    referencesEntry td =
      Set.member entryId td.labels
        || case td.transferType of
          Income cid -> cid == entryId
          Expense cid -> cid == entryId
          Transfer -> False
```

Export `findReferencingTransactions` from the module.

- [ ] **Step 5.4: Build + run the full test suite.**

```bash
nix develop --command just build
nix develop --command just test
```

Expected: green; the existing fixture transactions all have `labels = Set.empty` (from Task 3), so references are only via category, behaving exactly as before.

- [ ] **Step 5.5: `just check` and commit.**

```bash
nix develop --command just check
git add -A
git commit -m "$(cat <<'EOF'
feat(read-model): fold label/category edit events + usage lookup (#30)

Extends Application.ReadModels.Transaction to:

- Handle TransactionLabelsSetEvent / TransactionCategoryChangedEvent in
  processEvent.
- Expose findReferencingTransactions, used by the Configuration
  service to block deletion of in-use entries.
EOF
)"
git push
```

---

## Task 6 — In-use check on `ConfigurationService.removeDictionaryEntry`

The service-layer gate from spec §2.4.

**Files:**
- Modify: `src/Application/Services/ConfigurationService.hs`
- Create: `test/Application/Services/ConfigurationServiceInUseSpec.hs`

- [ ] **Step 6.1: Write the failing spec.**

Create `test/Application/Services/ConfigurationServiceInUseSpec.hs`. Model the harness on existing `test/Application/Services/*ServiceSpec.hs` files: create a test `AppEnv` via `createTestAppEnv`, seed a user with a cloned configuration, create an income transaction referencing a category, then assert that `removeDictionaryEntry` refuses.

At minimum cover:

1. Deleting a referenced income category returns `Left (CategoryInUse eid 1)`.
2. Deleting a referenced label returns `Left (LabelInUse eid n)` where `n` is the exact count.
3. Deleting an unreferenced label succeeds.
4. Count is correct when multiple transactions reference the same label.

Use `Application.Services.TransactionService.initiateIncome` / `initiateExpense` / `initiateInternalTransfer` (from Task 7, but in this task can be simulated by directly writing a `TransferInitiated` event through the in-memory event store). To keep this task self-contained, use the latter path (seed events directly) — Task 7 adds the labels-aware orchestration that turns this back into an end-to-end flow.

- [ ] **Step 6.2: Run — expect failure.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='ConfigurationService / in-use'
```

- [ ] **Step 6.3: Implement the check.**

In `src/Application/Services/ConfigurationService.hs`, replace the body of `removeDictionaryEntry`:

```haskell
removeDictionaryEntry :: UserId -> DictionaryId -> DictionaryEntryId -> AppM (Either DomainError ())
removeDictionaryEntry userId dictId entryId = do
  logInfo $ "Removing dictionary entry from " <> displayShow dictId <> " for user " <> displayShow userId

  -- 1. Refuse if any transaction still references this entry.
  txnRM <- view transactionReadModelL
  usageCount <- liftIO $ findReferencingTransactions txnRM entryId
  if usageCount > 0
    then do
      let eidText = tshow (unDictionaryEntryId entryId)
      let err
            | dictId == labelsDictId = LabelInUse {entryId = eidText, usageCount = usageCount}
            | otherwise = CategoryInUse {entryId = eidText, usageCount = usageCount}
      logWarn $ "Refusing to remove entry — " <> displayShow usageCount <> " transaction(s) reference it"
      return $ Left err
    else do
      -- 2. Clone-on-write and issue the RemoveDictionaryEntry command.
      cloneResult <- ensureClonedConfiguration userId
      case cloneResult of
        Left err -> return $ Left err
        Right configId -> do
          let configUuid = unConfigurationId configId
          let cmd =
                RemoveDictionaryEntryConfigurationCommand
                  RemoveDictionaryEntry
                    { dictionaryId = dictId,
                      entryId = entryId
                    }
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL
          result <- liftIO $ applyConfigurationCommand writer reader id configUuid cmd
          case result of
            Left err -> do
              logError $ "RemoveDictionaryEntry rejected: " <> displayShow err
              return $ Left $ ConfigurationError (T.pack (show err))
            Right _ -> do
              logInfo "Dictionary entry removed successfully"
              return $ Right ()
```

Add required imports:

```haskell
import Application.ReadModels.Transaction (findReferencingTransactions)
import Domain.Core.Types (unDictionaryEntryId)
```

- [ ] **Step 6.4: Run the spec — expect green.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='ConfigurationService / in-use'
```

- [ ] **Step 6.5: `just check` and commit.**

```bash
nix develop --command just check

git add src/Application/Services/ConfigurationService.hs \
        test/Application/Services/ConfigurationServiceInUseSpec.hs
git commit -m "$(cat <<'EOF'
feat(config): refuse to remove in-use dictionary entries (#30)

removeDictionaryEntry now checks the transaction read model for any
reference to the targeted entry — either as a label or as the category
on an Income/Expense transaction. If the count is non-zero, the request
is refused with LabelInUse or CategoryInUse, matching the spec's
deletion-safety requirement.
EOF
)"
git push
```

---

## Task 7 — `TransactionService` label validation + edit operations

Wires labels through the creation endpoints and adds the new edit orchestration.

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`
- Create: `test/Application/Services/TransactionServiceLabelsSpec.hs`

- [ ] **Step 7.1: Write the failing spec.**

Create `test/Application/Services/TransactionServiceLabelsSpec.hs`. Cover:

1. `initiateIncome` with `labels = [validLabelId]` → succeeds; resulting `TransactionData.labels` contains the id.
2. `initiateIncome` with `labels = [unknownUuid]` → `Left (LabelNotFound _)`.
3. `setTransactionLabels` on a Completed transaction → success; read model reflects the new set.
4. `setTransactionLabels` on a Pending transaction → `Left CannotEditTransactionLabelsInCurrentState`.
5. `setTransactionLabels` with an unknown label id → `Left (LabelNotFound _)` (validation before dispatch).
6. `changeTransactionCategory` on a Completed Income → success.
7. `changeTransactionCategory` on a Completed Transfer → `Left CannotChangeCategoryOnInternalTransfer`.
8. `changeTransactionCategory` with an unknown category id → `Left (CategoryNotFound _)`.
9. Access control: a user who does not have Editor+ on either account gets `Left` (reuse whatever the existing transaction creation tests assert for access).

- [ ] **Step 7.2: Add the service signatures.**

In `src/Application/Services/TransactionService.hs` module header, add:

```haskell
    setTransactionLabels,
    changeTransactionCategory,
```

- [ ] **Step 7.3: Thread `labels` into the creation functions.**

Change signatures:

```haskell
initiateIncome ::
  UserId ->
  AccountId ->
  Money ->
  DictionaryEntryId ->
  Set DictionaryEntryId ->    -- new
  Text ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))

initiateExpense ::
  UserId ->
  AccountId ->
  Money ->
  DictionaryEntryId ->
  Set DictionaryEntryId ->    -- new
  Text ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))

initiateInternalTransfer ::
  UserId ->
  AccountId ->
  AccountId ->
  Money ->
  Set DictionaryEntryId ->    -- new
  Text ->
  Maybe Rational ->
  Maybe UTCTime ->
  AppM (Either DomainError (TransactionId, TransactionData))
```

Inside each, before building `InitiateTransfer`, validate the label set:

```haskell
validateResult <- validateLabels userId labels
case validateResult of
  Left err -> pure (Left err)
  Right () -> resolveAndInitiate ...
```

Helper, added in the same module:

```haskell
-- | Verify every id in the set exists in the user's `labels` dictionary.
validateLabels ::
  UserId ->
  Set DictionaryEntryId ->
  AppM (Either DomainError ())
validateLabels _ labels | Set.null labels = pure (Right ())
validateLabels userId labels = do
  -- Resolve the user's configuration.
  maybeConfig <- ConfigurationService.getConfigurationForUser userId
  case maybeConfig of
    Left err -> pure (Left err)
    Right configData ->
      let known =
            case Map.lookup labelsDictId configData.dictionaries of
              Just dict -> Map.keysSet dict.entries
              Nothing -> Set.empty
          missing = Set.difference labels known
       in case Set.toList missing of
            [] -> pure (Right ())
            (eid : _) ->
              pure . Left . LabelNotFound . tshow $ unDictionaryEntryId eid
```

Add matching import changes and `labels = labels` entries where `InitiateTransfer` is constructed (the three existing functions).

- [ ] **Step 7.4: Add `setTransactionLabels` / `changeTransactionCategory`.**

Following the same orchestration pattern as `initiateIncome` (look up user, fetch read model entry to confirm access, dispatch command, translate aggregate errors to `DomainError`, re-query read model):

```haskell
setTransactionLabels ::
  UserId ->
  TransactionId ->
  Set DictionaryEntryId ->
  AppM (Either DomainError TransactionData)
setTransactionLabels userId transactionId labels = do
  logInfo $ "Setting labels on " <> displayShow transactionId <> " for user " <> displayShow userId
  maybeAccessErr <- ensureEditorAccess userId transactionId
  case maybeAccessErr of
    Just err -> pure (Left err)
    Nothing -> do
      validateResult <- validateLabels userId labels
      case validateResult of
        Left err -> pure (Left err)
        Right () -> do
          let cmd =
                SetTransactionLabelsTransactionCommand
                  SetTransactionLabels
                    { transactionId = transactionId,
                      labels = labels
                    }
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL
          result <-
            liftIO $
              applyTransactionCommand
                writer
                reader
                id
                (unTransactionId transactionId)
                cmd
          case result of
            Left aggregateErr -> pure $ Left (translateTransactionError aggregateErr)
            Right _ -> do
              maybeData <- queryTransactionResult transactionId
              case maybeData of
                Left err -> pure (Left err)
                Right (_, td) -> pure (Right td)
```

`translateTransactionError` is a new helper:

```haskell
translateTransactionError :: TransactionError -> DomainError
translateTransactionError CannotEditLabelsInCurrentState =
  CannotEditTransactionLabelsInCurrentState
translateTransactionError CannotChangeCategoryOnInternalTransfer =
  CannotChangeCategoryOnInternalTransfer
translateTransactionError other =
  TransactionError (tshow other)
```

`changeTransactionCategory` mirrors `setTransactionLabels` but validates the category against the **right** dictionary (income-category or expense-category depending on the existing `transferType` on the read-model entry):

```haskell
changeTransactionCategory ::
  UserId ->
  TransactionId ->
  DictionaryEntryId ->
  AppM (Either DomainError TransactionData)
changeTransactionCategory userId transactionId newCategory = do
  logInfo $ "Changing category on " <> displayShow transactionId <> " for user " <> displayShow userId
  maybeAccessErr <- ensureEditorAccess userId transactionId
  case maybeAccessErr of
    Just err -> pure (Left err)
    Nothing -> do
      txnRM <- view transactionReadModelL
      maybeSummary <- liftIO $ ReadModel.getTransaction txnRM transactionId
      case maybeSummary of
        Nothing -> pure $ Left $ NotFound "Transaction" (tshow transactionId)
        Just summary -> do
          let dictForType = case summary.transferType of
                Income _ -> Just incomeCategoryDictId
                Expense _ -> Just expenseCategoryDictId
                Transfer -> Nothing
          case dictForType of
            Nothing -> pure $ Left CannotChangeCategoryOnInternalTransfer
            Just dictId -> do
              exists <- isCategoryKnown userId dictId newCategory
              if not exists
                then pure . Left . CategoryNotFound . tshow $ unDictionaryEntryId newCategory
                else do
                  let cmd =
                        ChangeTransactionCategoryTransactionCommand
                          ChangeTransactionCategory
                            { transactionId = transactionId,
                              newCategory = newCategory
                            }
                  writer <- view eventStoreWriterL
                  reader <- view eventStoreReaderL
                  result <-
                    liftIO $
                      applyTransactionCommand
                        writer
                        reader
                        id
                        (unTransactionId transactionId)
                        cmd
                  case result of
                    Left aggregateErr -> pure $ Left (translateTransactionError aggregateErr)
                    Right _ -> do
                      maybeData <- queryTransactionResult transactionId
                      case maybeData of
                        Left err -> pure (Left err)
                        Right (_, td) -> pure (Right td)
```

`ensureEditorAccess` and `isCategoryKnown` are small helpers you either have already (look for similar checks in other services) or add here. If a similar `ensureEditorAccess` helper exists in `AccountAccessService` or `AuthService`, reuse it. Otherwise the implementation is:

```haskell
ensureEditorAccess :: UserId -> TransactionId -> AppM (Maybe DomainError)
ensureEditorAccess userId transactionId = do
  txnRM <- view transactionReadModelL
  maybeSummary <- liftIO $ ReadModel.getTransaction txnRM transactionId
  case maybeSummary of
    Nothing -> pure $ Just $ NotFound "Transaction" (tshow transactionId)
    Just summary -> do
      accountRM <- view accountReadModelL
      accessible <- liftIO $ AccountRM.getAccessibleAccounts accountRM userId
      let editorAccounts =
            Set.fromList
              [ aid
              | (aid, role, _) <- accessible,
                role `elem` [Owner, Editor]
              ]
          allowed =
            Set.member summary.sourceAccountId editorAccounts
              || Set.member summary.targetAccountId editorAccounts
      if allowed
        then pure Nothing
        else pure $ Just $ AccountError "User does not have edit access to this transaction"
```

> If the project already has an `AccessDenied` constructor on `DomainError`, use that instead of `AccountError`. Grep first:  
> `rg -n "AccessDenied" src/`. If absent, `AccountError` with a clear message is the established idiom.

- [ ] **Step 7.5: Run the service spec — expect green.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='TransactionService / labels'
```

- [ ] **Step 7.6: Fix every call site changed by the new signatures.**

Callers: `incomeHandler`, `expenseHandler`, `transferHandler`, bank import service, telegram bot. Default `labels = Set.empty` here; Task 8 wires the real labels through for the HTTP handlers.

```bash
rg -n "initiateIncome\|initiateExpense\|initiateInternalTransfer" src/ | grep -v TransactionService.hs
```

- [ ] **Step 7.7: Build + test.**

```bash
nix develop --command just build
nix develop --command just test
```

Expected: green.

- [ ] **Step 7.8: `just check` and commit.**

```bash
nix develop --command just check

git add -A
git commit -m "$(cat <<'EOF'
feat(service): label validation + edit operations (#30)

TransactionService gains:

- `labels` argument on initiateIncome/initiateExpense/initiateInternalTransfer;
  unknown label ids are rejected with LabelNotFound.
- setTransactionLabels / changeTransactionCategory for the new HTTP
  edit endpoints. Both check Editor+ access and translate aggregate
  errors (CannotEditLabelsInCurrentState,
  CannotChangeCategoryOnInternalTransfer) to their DomainError
  equivalents.
- changeTransactionCategory also validates the new category exists in
  the dictionary matching the transaction's type.

All existing callers default to `labels = Set.empty` for now; the HTTP
handlers wire the real set in the next commit.
EOF
)"
git push
```

---

## Task 8 — Web DTOs + new edit endpoints

**Files:**
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API/TransactionAPI.hs`
- Create: `test/Web/API/TransactionLabelsAPISpec.hs`

- [ ] **Step 8.1: Extend request DTOs with labels.**

In `src/Web/Types.hs`, add `labels :: Maybe [UUID]` to `IncomeRequest`, `ExpenseRequest`, `InternalTransferRequest`:

```haskell
data IncomeRequest
  = IncomeRequest
  { accountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    description :: Text,
    date :: Maybe UTCTime,
    labels :: Maybe [UUID]
  }
  deriving (Show, Eq, Generic)
```

Repeat for `ExpenseRequest` and `InternalTransferRequest`.

- [ ] **Step 8.2: Add `labels :: [UUID]` to `TransactionResponse`.**

```haskell
data TransactionResponse
  = TransactionResponse
  { ...
    date :: Text,
    labels :: [UUID]
  }
```

Update `fromTransactionData`:

```haskell
labels = sort [unDictionaryEntryId eid | eid <- Set.toList labels]  -- where `labels` is td.labels
```

(`sort` for deterministic ordering; pulled from `RIO.List` or `Data.List`.)

- [ ] **Step 8.3: Add new edit-request DTOs.**

After `TransactionListResponse`:

```haskell
-- | Body for PUT /api/transactions/:id/labels.
data SetTransactionLabelsRequest = SetTransactionLabelsRequest
  { labels :: [UUID]
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetTransactionLabelsRequest
instance FromJSON SetTransactionLabelsRequest

-- | Body for PUT /api/transactions/:id/category.
data ChangeTransactionCategoryRequest = ChangeTransactionCategoryRequest
  { categoryId :: UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeTransactionCategoryRequest
instance FromJSON ChangeTransactionCategoryRequest
```

Export both from the module header.

- [ ] **Step 8.4: Convert request labels to `Set DictionaryEntryId`.**

Extend the helper area of `Web.Types` (near `parseCategoryId`):

```haskell
parseLabelIds :: Maybe [UUID] -> Either Text (Set DictionaryEntryId)
parseLabelIds Nothing = Right Set.empty
parseLabelIds (Just us) =
  Set.fromList
    <$> traverse (first (("Invalid label id: " <>) . tshow) . mkDictionaryEntryId) us
```

Export it.

- [ ] **Step 8.5: Wire labels into the POST handlers.**

In `src/Web/API/TransactionAPI.hs`, update `incomeHandler`/`expenseHandler`/`transferHandler` to parse labels and pass them through:

```haskell
labelSet <- validateField "labels" $ parseLabelIds request.labels
...
result <- TransactionService.initiateIncome userId accountId money categoryEntryId labelSet request.description request.date
```

(and the same for expense/transfer).

- [ ] **Step 8.6: Add the edit routes to the API type and server.**

In the `TransactionAPI` type, add the two routes **between** the list route and the `Capture "id"` GET route — nested resources should sit under the captured id:

```haskell
-- PUT /api/transactions/:id/labels
:<|> AuthProtect "jwt"
  :> "api"
  :> "transactions"
  :> Capture "id" UUID
  :> "labels"
  :> ReqBody '[JSON] SetTransactionLabelsRequest
  :> Put '[JSON] TransactionResponse
-- PUT /api/transactions/:id/category
:<|> AuthProtect "jwt"
  :> "api"
  :> "transactions"
  :> Capture "id" UUID
  :> "category"
  :> ReqBody '[JSON] ChangeTransactionCategoryRequest
  :> Put '[JSON] TransactionResponse
```

Extend the `transactionServer` combinator chain with the corresponding handlers:

```haskell
transactionServer =
  incomeHandler
    :<|> expenseHandler
    :<|> transferHandler
    :<|> listTransactionsHandler
    :<|> setLabelsHandler
    :<|> changeCategoryHandler
    :<|> getTransactionHandler
```

- [ ] **Step 8.7: Implement the handlers.**

```haskell
setLabelsHandler ::
  AuthenticatedUser ->
  UUID ->
  SetTransactionLabelsRequest ->
  AppM TransactionResponse
setLabelsHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  labelSet <- validateField "labels" $ parseLabelIds (Just req.labels)
  result <- TransactionService.setTransactionLabels user.userId transactionId labelSet
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err

changeCategoryHandler ::
  AuthenticatedUser ->
  UUID ->
  ChangeTransactionCategoryRequest ->
  AppM TransactionResponse
changeCategoryHandler user rawId req = do
  transactionId <- validateField "id" $ mkTransactionId rawId
  categoryId <- validateField "categoryId" $ mkDictionaryEntryId req.categoryId
  result <- TransactionService.changeTransactionCategory user.userId transactionId categoryId
  case result of
    Right td -> pure $ fromTransactionData transactionId td
    Left err -> throwDomainError err
```

Export both from the module header.

- [ ] **Step 8.8: Build + run tests.**

```bash
nix develop --command just build
nix develop --command just test
```

- [ ] **Step 8.9: Write HTTP-level tests.**

Create `test/Web/API/TransactionLabelsAPISpec.hs`. Model on the patterns in `test/Web/API/BankingAPISpec.hs` / `test/Web/API/TransactionAPISpec.hs`. Cover:

1. `PUT /api/transactions/<unknown-id>/labels` → 404.
2. `PUT /api/transactions/<id>/labels` on a Pending transaction → 409 code `TRANSACTION_NOT_COMPLETED`.
3. `PUT /api/transactions/<id>/labels` with unknown label id → 404 `LABEL_NOT_FOUND`.
4. `PUT /api/transactions/<id>/labels` happy path → 200 with the new set in the response.
5. `PUT /api/transactions/<id>/category` on an internal transfer → 409 `CATEGORY_NOT_APPLICABLE`.
6. `PUT /api/transactions/<id>/category` with unknown category id → 404 `CATEGORY_NOT_FOUND`.
7. `POST /api/transactions/income` with `{"labels": ["<valid-uuid>"]}` → 200; response carries `labels`.
8. `POST /api/transactions/income` with `{"labels": ["<unknown-uuid>"]}` → 404 `LABEL_NOT_FOUND`.

For each seed transaction, use the in-memory event-store test harness (see `createTestAppEnv`) and drive the happy-path path end-to-end through the service layer (faster than asserting on the write side alone).

- [ ] **Step 8.10: Run the HTTP spec + full test suite.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='/api/transactions/'
nix develop --command just test
```

- [ ] **Step 8.11: `just check` and commit.**

```bash
nix develop --command just check

git add -A
git commit -m "$(cat <<'EOF'
feat(api): transaction labels + category edit endpoints (#30)

- POST /api/transactions/income|expense|transfer now accept an optional
  labels array; validated against the user's labels dictionary.
- GET/POST responses include a labels array.
- New PUT /api/transactions/:id/labels replaces the label set on a
  Completed transaction.
- New PUT /api/transactions/:id/category replaces the category on a
  Completed Income/Expense transaction.
EOF
)"
git push
```

---

## Task 9 — Integration tests

End-to-end flows from spec §6.

**Files:**
- Create: `test/Integration/TransactionLabelsIntegrationSpec.hs`
- Create: `test/Integration/TransactionCategoryEditIntegrationSpec.hs`

- [ ] **Step 9.1: Write `TransactionLabelsIntegrationSpec`.**

Scenarios (all in one spec file, each its own `it`):

1. Add two labels (`kids`, `school`) to the user's configuration. Assert `GET /api/users/me/configuration` returns them under `labels`.
2. Create an expense with `labels = [kids]`. Assert the response echoes the label id.
3. Rename `kids` to `children`. Create another expense with `[children]`.
4. Re-set labels on the first expense to `[children, school]`. Assert the response carries both.
5. Attempt `DELETE /api/users/me/configuration/dictionaries/labels/entries/<children-id>` → 409 `LABEL_IN_USE` with `usageCount = 2`.
6. Re-set both expenses' labels to `[]`. Delete `children` again → 200.

Model the HTTP harness on `test/Integration/*IntegrationSpec.hs` if they exist, otherwise drive directly through services.

- [ ] **Step 9.2: Write `TransactionCategoryEditIntegrationSpec`.**

Scenarios:

1. Create an income with category `Salary`. Change its category to `Freelance`. Assert the response's `category` field reflects the new id.
2. Create an internal transfer. Attempt `PUT /category` → 409 `CATEGORY_NOT_APPLICABLE`.
3. Create an income with category `Salary`. Attempt to change to an id that isn't in the income-category dictionary → 404 `CATEGORY_NOT_FOUND`.

- [ ] **Step 9.3: Run the integration specs.**

```bash
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='Integration / TransactionLabels'
nix develop --command cabal test all \
  --test-show-details=direct \
  --test-option='--match' --test-option='Integration / TransactionCategoryEdit'
```

- [ ] **Step 9.4: `just check` and commit.**

```bash
nix develop --command just check
git add test/Integration/TransactionLabelsIntegrationSpec.hs \
        test/Integration/TransactionCategoryEditIntegrationSpec.hs
git commit -m "$(cat <<'EOF'
test(integration): transaction labels + category edit flows (#30)

End-to-end coverage from the design's §6 "Integration" cases:

- Labels lifecycle: add, apply, rename, re-set, blocked delete, delete.
- Category-edit lifecycle: change on income, reject on internal
  transfer, reject unknown id.
EOF
)"
git push
```

---

## Task 10 — Generators + housekeeping

**Files:**
- Modify: `test/Testkit/Generators.hs`

- [ ] **Step 10.1: Add `genLabelSet`.**

```haskell
-- | Arbitrary label set, biased toward small sizes so the "optional"
-- path of labels stays well-covered in generic transaction generators.
genLabelSet :: Gen (Set DictionaryEntryId)
genLabelSet = sized $ \n ->
  Set.fromList <$> vectorOf (min n 4) genDictionaryEntryId
```

- [ ] **Step 10.2: Fix `genDictionaryId`.**

The current definition is `elements ["income-category", "expense-category", "label", "tag"]`. Replace `"label"` and `"tag"` with `"labels"` to match the well-known id introduced in Task 2 (prevents tests from accidentally exercising undefined dictionary ids):

```haskell
genDictionaryId :: Gen DictionaryId
genDictionaryId = DictionaryId <$> elements ["income-category", "expense-category", "labels"]
```

- [ ] **Step 10.3: Extend any transfer/transaction generator with labels.**

If `Testkit/Generators.hs` defines `genTransferInitiated` or similar, add `labels <- genLabelSet` and plumb it through. Grep:

```bash
rg -n "genTransferInitiated|genInitiateTransfer" test/Testkit/
```

- [ ] **Step 10.4: `just test` + `just check`, commit, push.**

```bash
nix develop --command just test
nix develop --command just check

git add test/Testkit/Generators.hs
git commit -m "$(cat <<'EOF'
test(generators): genLabelSet + labels dictionary id (#30)

Adds a label-set generator biased toward small sizes and aligns
genDictionaryId with the new canonical "labels" id.
EOF
)"
git push
```

---

## Task 11 — Final verification + PR

- [ ] **Step 11.1: Rebuild from scratch + full test pass.**

```bash
nix develop --command just rebuild
nix develop --command just test
```

Expected: every spec green, no `-Wall -Werror` failures.

- [ ] **Step 11.2: `just check` one final time.**

```bash
nix develop --command just check
```

- [ ] **Step 11.3: Update the spec's frontmatter.**

Set `status: in-progress` in `docs/specs/2026-04-22-transaction-labels-design.md` (it will flip to `completed` after merge — do not do that here).

```bash
git add docs/specs/2026-04-22-transaction-labels-design.md
git commit -m "docs(specs): mark transaction-labels design in-progress"
git push
```

- [ ] **Step 11.4: Open the PR.**

```bash
gh pr create \
  --title "feat(transaction): labels feature + editable category (#30)" \
  --body "$(cat <<'EOF'
## Summary

Closes homeaccounting/backend#30.

- Introduces a `labels` dictionary in user configuration, served by the
  existing generic `/api/users/me/configuration/dictionaries/labels/entries`
  CRUD routes.
- Every transaction (income, expense, internal transfer) can carry zero
  or more labels. Labels are validated against the user's configuration
  on create and edit.
- New `PUT /api/transactions/:id/labels` replaces the label set on a
  Completed transaction.
- New `PUT /api/transactions/:id/category` replaces the category on a
  Completed income/expense transaction — closes the "cannot re-classify
  past transactions" gap flagged during design.
- Deleting a label or category that is still referenced by any
  transaction is refused with 409 `LABEL_IN_USE` / `CATEGORY_IN_USE`
  and the current usage count.

## Design

See `docs/specs/2026-04-22-transaction-labels-design.md` and the
accompanying plan `docs/plans/2026-04-22-transaction-labels.md`.

## Test plan

- [x] Domain command-handler unit tests for the new edit commands
  (`test/Domain/Transaction/LabelsAndCategorySpec.hs`).
- [x] Projection fold tests + QuickCheck property
  (`test/Domain/Transaction/LabelsProjectionSpec.hs`).
- [x] Relaxed last-entry rule (`test/Domain/Configuration/LabelsDictionarySpec.hs`).
- [x] ConfigurationService in-use check
  (`test/Application/Services/ConfigurationServiceInUseSpec.hs`).
- [x] TransactionService orchestration tests
  (`test/Application/Services/TransactionServiceLabelsSpec.hs`).
- [x] HTTP-level tests for the new edit endpoints and
  labels-in-request-DTOs (`test/Web/API/TransactionLabelsAPISpec.hs`).
- [x] End-to-end integration flows
  (`test/Integration/TransactionLabelsIntegrationSpec.hs`,
  `test/Integration/TransactionCategoryEditIntegrationSpec.hs`).
- [x] `just check` + `just test` both green against a fresh build.

## Compatibility

- Existing `TransferInitiated` events deserialise with `labels` defaulting
  to `Set.empty` via a hand-written `FromJSON` parser — no event-log
  rewrite required.
- Existing clients that ignore unknown JSON fields are unaffected; the new
  `labels` field on `TransactionResponse` is always an array.
EOF
)"
```

- [ ] **Step 11.5: Return the PR URL to the user.**

---

## Risk Register / Things That Can Bite

1. **Backwards-compatible event deserialisation.** The custom `FromJSON` for `TransferInitiated` in Task 3 is the single point that keeps historical events replayable. If you change it, re-check the Eventium test suite and any fixture files.
2. **`AccountingEvent` sum generation.** Task 5 depends on the new Transaction events flowing into the unified sum. If the sum is hand-written (not TH-derived from `transactionEvents`), it must be extended manually. Grep first (`rg -n "AccountingEvent" src/Domain/Models.hs`).
3. **Servant route ordering.** The new `PUT /:id/labels` and `PUT /:id/category` must sit alongside the `Capture "id" UUID :> Get` route. Declaration order doesn't affect matching (unique paths), but keep them grouped for readability.
4. **`AccessDenied` vs. `AccountError`.** If the codebase has an `AccessDenied` `DomainError` constructor, prefer it in `ensureEditorAccess`. Grep before typing.
5. **Labels ordering in responses.** Always emit `[UUID]` sorted; clients will likely diff responses. A `Set` preserves no insertion order, so downstream determinism depends on the sort at the DTO boundary.
6. **Don't refactor unrelated code.** The Change Philosophy in CLAUDE.md applies: keep this PR additive. If you spot tempting cleanups (e.g. `processEvent` readability, test-harness factoring), flag them and save for a follow-up.
7. **Task 7 translation between aggregate errors and `DomainError`.** If a new `TransactionError` is added in the future (not this PR), `translateTransactionError` must grow with it — the fallback `TransactionError (tshow other)` is a safety net, not a correct mapping.
8. **`labels` dictionary autocreation.** The Configuration read model already auto-creates dictionaries on first `DictionaryEntryAdded` (via `Map.findWithDefault`). No new event type is needed for seeding. Do not invent one.
