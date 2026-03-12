---
status: completed
---

# Income/Expense Transfers Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add TransferType (Income/Expense/InternalTransfer) and TransferCategory enums to the Transaction aggregate, with three dedicated API endpoints for income, expense, and internal transfers.

**Architecture:** Extend the existing Transaction aggregate with two new fields (type, category). The service layer resolves External accounts for income/expense. Three new API endpoints replace the single transfer endpoint. The saga and Account aggregate remain unchanged.

**Tech Stack:** Haskell, Servant, Eventium, Hspec/QuickCheck, Aeson, RIO

---

### Task 1: Add TransferType and TransferCategory to Domain.Core.Types

**Files:**
- Modify: `src/Domain/Core/Types.hs`

**Step 1: Add the new types after AccountAccess (around line 409)**

```haskell
-- | Type of transfer operation.
data TransferType
  = Income
  | Expense
  | InternalTransfer
  deriving (Show, Eq, Generic)

instance ToJSON TransferType

instance FromJSON TransferType

-- | Category for income transfers.
data IncomeCategory
  = Salary
  | Freelance
  | Investment
  | IncomeGift
  | IncomeOther
  deriving (Show, Eq, Generic)

instance ToJSON IncomeCategory

instance FromJSON IncomeCategory

-- | Category for expense transfers.
data ExpenseCategory
  = Food
  | Transport
  | Utilities
  | Rent
  | Entertainment
  | ExpenseOther
  deriving (Show, Eq, Generic)

instance ToJSON ExpenseCategory

instance FromJSON ExpenseCategory

-- | Category for internal (account-to-account) transfers.
data InternalCategory
  = Rebalance
  | Savings
  | InternalOther
  deriving (Show, Eq, Generic)

instance ToJSON InternalCategory

instance FromJSON InternalCategory

-- | Transfer category, scoped by transfer type.
data TransferCategory
  = IncomeCat IncomeCategory
  | ExpenseCat ExpenseCategory
  | InternalCat InternalCategory
  deriving (Show, Eq, Generic)

instance ToJSON TransferCategory

instance FromJSON TransferCategory

-- | Validate that a TransferCategory is consistent with its TransferType.
validateTransferCategory :: TransferType -> TransferCategory -> Either Text ()
validateTransferCategory Income (IncomeCat _) = Right ()
validateTransferCategory Expense (ExpenseCat _) = Right ()
validateTransferCategory InternalTransfer (InternalCat _) = Right ()
validateTransferCategory transferType category =
  Left $ "Category " <> T.pack (show category) <> " is not valid for transfer type " <> T.pack (show transferType)
```

**Step 2: Export the new types in the module export list (around line 10-53)**

Add to exports:
```haskell
    -- * Transfer Types
    TransferType (..),
    IncomeCategory (..),
    ExpenseCategory (..),
    InternalCategory (..),
    TransferCategory (..),
    validateTransferCategory,
```

**Step 3: Verify it compiles**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && just build`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "feat: add TransferType and TransferCategory domain types"
```

---

### Task 2: Write property tests for type/category validation

**Files:**
- Create: `test/Domain/Core/TransferCategoryPropertySpec.hs`

**Step 1: Write the property tests**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Domain.Core.TransferCategoryPropertySpec (spec) where

import Domain.Core.Types
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

instance Arbitrary IncomeCategory where
  arbitrary = elements [Salary, Freelance, Investment, IncomeGift, IncomeOther]

instance Arbitrary ExpenseCategory where
  arbitrary = elements [Food, Transport, Utilities, Rent, Entertainment, ExpenseOther]

instance Arbitrary InternalCategory where
  arbitrary = elements [Rebalance, Savings, InternalOther]

instance Arbitrary TransferType where
  arbitrary = elements [Income, Expense, InternalTransfer]

instance Arbitrary TransferCategory where
  arbitrary =
    oneof
      [ IncomeCat <$> arbitrary,
        ExpenseCat <$> arbitrary,
        InternalCat <$> arbitrary
      ]

spec :: Spec
spec = describe "TransferCategory validation" $ do
  describe "validateTransferCategory" $ do
    prop "accepts Income with IncomeCat" $ \(cat :: IncomeCategory) ->
      validateTransferCategory Income (IncomeCat cat) == Right ()

    prop "accepts Expense with ExpenseCat" $ \(cat :: ExpenseCategory) ->
      validateTransferCategory Expense (ExpenseCat cat) == Right ()

    prop "accepts InternalTransfer with InternalCat" $ \(cat :: InternalCategory) ->
      validateTransferCategory InternalTransfer (InternalCat cat) == Right ()

    prop "rejects mismatched type and category" $ \(tt :: TransferType) (tc :: TransferCategory) ->
      not (isMatching tt tc) ==> isLeft (validateTransferCategory tt tc)

isMatching :: TransferType -> TransferCategory -> Bool
isMatching Income (IncomeCat _) = True
isMatching Expense (ExpenseCat _) = True
isMatching InternalTransfer (InternalCat _) = True
isMatching _ _ = False

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
```

**Step 2: Run the tests**

Run: `cabal test all --test-option='--match' --test-option='/TransferCategory/'`
Expected: PASS

**Step 3: Commit**

```bash
git add test/Domain/Core/TransferCategoryPropertySpec.hs
git commit -m "test: add property tests for TransferCategory validation"
```

---

### Task 3: Add type and category to Transaction events

**Files:**
- Modify: `src/Domain/Transaction/Events.hs`

**Step 1: Add import for new types**

Add to imports:
```haskell
import Domain.Core.Types (AccountId, Money, TransferCategory, TransferType, UserId)
```

**Step 2: Add fields to TransferInitiated (after `by` field, line 74)**

```haskell
data TransferInitiated = TransferInitiated
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    amount :: Money,
    reason :: Text,
    by :: UserId,
    transferType :: TransferType,
    category :: TransferCategory
  }
```

**Step 3: Verify it compiles (it won't yet — dependent code needs updating)**

Run: `just build`
Expected: FAIL — dependent files need updating. That's fine, continue to next task.

---

### Task 4: Add type and category to Transaction commands

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs`

**Step 1: Add import for new types**

Add to imports:
```haskell
import Domain.Core.Types (AccountId, Money, TransferCategory, TransferType, UserId)
```

**Step 2: Add fields to InitiateTransfer (after `initiatedBy` field, line 89)**

```haskell
data InitiateTransfer = InitiateTransfer
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    amount :: Money,
    reason :: Text,
    initiatedBy :: UserId,
    transferType :: TransferType,
    category :: TransferCategory
  }
```

---

### Task 5: Update Transaction projection to include new fields

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs`

**Step 1: Add import**

Add `TransferCategory`, `TransferType` to the import from `Domain.Core.Types`.

**Step 2: Add fields to Transaction record (after `initiatedBy`, line 134)**

```haskell
data Transaction = Transaction
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    amount :: Money,
    reason :: Text,
    status :: TransactionStatus,
    initiatedBy :: UserId,
    transferType :: TransferType,
    category :: TransferCategory
  }
```

**Step 3: Update transactionDefault (around line 157)**

Add default values for the new fields. Use `Income` and `IncomeCat IncomeOther` as placeholder defaults (will be overwritten by first event):

```haskell
      transferType = Income,
      category = IncomeCat IncomeOther
```

Add `IncomeCategory (..), TransferCategory (..), TransferType (..)` to the import.

**Step 4: Update handleTransactionEvent for TransferInitiated (around line 229)**

Add the two new field assignments:

```haskell
    & #transferType .~ evt.transferType
    & #category .~ evt.category
```

---

### Task 6: Update Transaction command handler validation

**Files:**
- Modify: `src/Domain/Transaction/CommandHandler.hs`

**Step 1: Add import**

Add `validateTransferCategory` to import from `Domain.Core.Types`.

**Step 2: Add new error variant to TransactionError (around line 56)**

```haskell
data TransactionError
  = TransactionAlreadyInitiated
  | TransactionNotPending
  | TransferToSameAccount
  | TransferAmountNotPositive
  | TransferCategoryMismatch
  deriving (Show, Eq)
```

**Step 3: Add category validation in InitiateTransfer handler (around line 125)**

After the amount check, before emitting the event, add:

```haskell
                else case validateTransferCategory transferType category of
                  Left _ -> Left TransferCategoryMismatch
                  Right () ->
                    Right [TransferInitiatedTransactionEvent ...]
```

**Step 4: Pass new fields through in the TransferInitiated event construction**

```haskell
TransferInitiated
  { fromAccountId = fromAccountId,
    toAccountId = toAccountId,
    amount = amount,
    reason = reason,
    by = initiatedBy,
    transferType = transferType,
    category = category
  }
```

---

### Task 7: Fix all compilation errors and verify build

**Files:**
- Modify: `test/Domain/Transaction/CommandHandlerSpec.hs` — update test InitiateTransfer constructions with new fields
- Modify: `test/Domain/Transaction/CommandHandlerPropertySpec.hs` — update Arbitrary instance and test data
- Modify: `test/Integration/TransferWorkflowSpec.hs` — update test InitiateTransfer constructions
- Modify: `src/Web/Types.hs` — update `toInitiateTransferCommand`
- Modify: `src/Application/ReadModels/Transaction.hs` — add new fields to `TransactionData` and event handler
- Modify: `test/Testkit/Helpers.hs` or `test/Testkit/Generators.hs` — update if they construct InitiateTransfer

For each file, add `transferType = InternalTransfer` and `category = InternalCat InternalOther` to existing test transfers (they were all account-to-account transfers).

**Step 1: Update TransactionData in the read model**

In `src/Application/ReadModels/Transaction.hs`, add to `TransactionData`:

```haskell
data TransactionData = TransactionData
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    amount :: Money,
    reason :: Text,
    status :: TransactionStatus,
    transferType :: TransferType,
    category :: TransferCategory
  }
```

Update `processEvent` for `TransferInitiatedEvent` to include the new fields:

```haskell
let newEntry =
      TransactionData
        { fromAccountId = evt.fromAccountId,
          toAccountId = evt.toAccountId,
          amount = evt.amount,
          reason = evt.reason,
          status = Pending,
          transferType = evt.transferType,
          category = evt.category
        }
```

**Step 2: Update Web.Types**

In `src/Web/Types.hs`:
- Update `TransferRequest` — for now, keep the old DTO (will be replaced in Task 9). Add `transferType` and `category` fields temporarily or default them.
- Update `TransactionResponse` — add `transferType` and `category` fields.
- Update `fromTransactionData` — include the new fields.
- Update `toInitiateTransferCommand` — pass through the new fields.

**Step 3: Update all test files**

Add the two new fields to every `InitiateTransfer` construction in test files.

**Step 4: Build and test**

Run: `just build && just test`
Expected: BUILD SUCCEEDED, all tests pass

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: add type and category to Transaction aggregate, events, and read model"
```

---

### Task 8: Update TransactionService to resolve External accounts

**Files:**
- Modify: `src/Application/Services/TransactionService.hs`

**Step 1: Add new imports**

```haskell
import Application.ReadModels.User (UserData (..), getUser)
import Domain.Core.Types
  ( AccountType (..),
    TransferCategory (..),
    TransferType (..),
    TransactionId,
    mkTransactionId,
    validateTransferCategory,
  )
import Application.ReadModels.Account (AccountData (..), getAccount)
```

**Step 2: Add three new service functions**

```haskell
-- | Initiate an income transfer (External -> Regular).
initiateIncome ::
  UserId -> AccountId -> Money -> IncomeCategory -> Text ->
  AppM (Either DomainError (TransactionId, TransactionData))

-- | Initiate an expense transfer (Regular -> External).
initiateExpense ::
  UserId -> AccountId -> Money -> ExpenseCategory -> Text ->
  AppM (Either DomainError (TransactionId, TransactionData))

-- | Initiate an internal transfer (Regular -> Regular).
initiateInternalTransfer ::
  UserId -> AccountId -> AccountId -> Money -> InternalCategory -> Text ->
  AppM (Either DomainError (TransactionId, TransactionData))
```

Each function:
1. Looks up the user's External account via User read model (`externalAccountId`)
2. For income/expense, validates the target/source account is Regular via Account read model
3. Constructs `InitiateTransfer` with the correct `transferType` and `category`
4. Delegates to the existing `initiateTransfer` internal function

**Step 3: Build**

Run: `just build`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add src/Application/Services/TransactionService.hs
git commit -m "feat: add income, expense, and internal transfer service functions"
```

---

### Task 9: Create three new API endpoints

**Files:**
- Modify: `src/Web/API/TransactionAPI.hs`
- Modify: `src/Web/Types.hs`
- Modify: `src/Web/API.hs` (if needed for re-exports)

**Step 1: Add new request DTOs in Web.Types**

```haskell
data IncomeRequest = IncomeRequest
  { accountId :: UUID,
    amount :: Double,
    category :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeRequest
instance FromJSON IncomeRequest

data ExpenseRequest = ExpenseRequest
  { accountId :: UUID,
    amount :: Double,
    category :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ExpenseRequest
instance FromJSON ExpenseRequest

data InternalTransferRequest = InternalTransferRequest
  { fromAccountId :: UUID,
    toAccountId :: UUID,
    amount :: Double,
    category :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON InternalTransferRequest
instance FromJSON InternalTransferRequest
```

Add category parsing helpers:

```haskell
parseIncomeCategory :: Text -> Either Text IncomeCategory
parseIncomeCategory "salary" = Right Salary
parseIncomeCategory "freelance" = Right Freelance
parseIncomeCategory "investment" = Right Investment
parseIncomeCategory "gift" = Right IncomeGift
parseIncomeCategory "other" = Right IncomeOther
parseIncomeCategory t = Left $ "Unknown income category: " <> t

parseExpenseCategory :: Text -> Either Text ExpenseCategory
parseExpenseCategory "food" = Right Food
parseExpenseCategory "transport" = Right Transport
parseExpenseCategory "utilities" = Right Utilities
parseExpenseCategory "rent" = Right Rent
parseExpenseCategory "entertainment" = Right Entertainment
parseExpenseCategory "other" = Right ExpenseOther
parseExpenseCategory t = Left $ "Unknown expense category: " <> t

parseInternalCategory :: Text -> Either Text InternalCategory
parseInternalCategory "rebalance" = Right Rebalance
parseInternalCategory "savings" = Right Savings
parseInternalCategory "other" = Right InternalOther
parseInternalCategory t = Left $ "Unknown internal category: " <> t
```

**Step 2: Update TransactionAPI type**

Replace the existing POST endpoint with three:

```haskell
type TransactionAPI =
  -- POST /api/transactions/income
  AuthProtect "jwt"
    :> "api" :> "transactions" :> "income"
    :> ReqBody '[JSON] IncomeRequest
    :> Post '[JSON] TransactionResponse
  -- POST /api/transactions/expense
  :<|> AuthProtect "jwt"
    :> "api" :> "transactions" :> "expense"
    :> ReqBody '[JSON] ExpenseRequest
    :> Post '[JSON] TransactionResponse
  -- POST /api/transactions/transfer
  :<|> AuthProtect "jwt"
    :> "api" :> "transactions" :> "transfer"
    :> ReqBody '[JSON] InternalTransferRequest
    :> Post '[JSON] TransactionResponse
  -- GET /api/transactions/:id
  :<|> AuthProtect "jwt"
    :> "api" :> "transactions"
    :> Capture "id" UUID
    :> Get '[JSON] TransactionResponse
```

**Step 3: Implement three new handlers**

```haskell
incomeHandler :: AuthenticatedUser -> IncomeRequest -> AppM TransactionResponse
expenseHandler :: AuthenticatedUser -> ExpenseRequest -> AppM TransactionResponse
transferHandler :: AuthenticatedUser -> InternalTransferRequest -> AppM TransactionResponse
```

Each handler:
1. Parses and validates the category string
2. Converts UUID to AccountId
3. Converts amount to Money
4. Calls the corresponding service function
5. Returns TransactionResponse

**Step 4: Update transactionServer**

```haskell
transactionServer =
  incomeHandler
    :<|> expenseHandler
    :<|> transferHandler
    :<|> getTransactionHandler
```

**Step 5: Update TransactionResponse in Web.Types**

Add `transferType :: Text` and `category :: Text` fields. Update `fromTransactionData` accordingly.

**Step 6: Build and test**

Run: `just build && just test`
Expected: BUILD SUCCEEDED, all tests pass

**Step 7: Commit**

```bash
git add src/Web/API/TransactionAPI.hs src/Web/Types.hs
git commit -m "feat: add /income, /expense, /transfer API endpoints"
```

---

### Task 10: Write integration tests for new endpoints

**Files:**
- Modify: `test/Integration/TransferWorkflowSpec.hs`

**Step 1: Add income flow integration test**

Test that creates a user with External account, then initiates income via the service layer (External → Regular), and verifies:
- Transaction has `transferType = Income` and correct `IncomeCat` category
- Regular account balance increases
- External account balance decreases (goes negative)

**Step 2: Add expense flow integration test**

Same pattern but Regular → External, verifying:
- Transaction has `transferType = Expense` and correct `ExpenseCat` category
- Regular account balance decreases
- External account balance increases (less negative)

**Step 3: Add internal transfer integration test**

Regular → Regular with `InternalCat` category, verifying:
- Transaction has `transferType = InternalTransfer`
- Both account balances updated correctly

**Step 4: Add category mismatch rejection test**

Verify that attempting to create a transfer with mismatched type/category is rejected.

**Step 5: Run tests**

Run: `just test`
Expected: All tests pass

**Step 6: Commit**

```bash
git add test/Integration/TransferWorkflowSpec.hs
git commit -m "test: add integration tests for income, expense, and transfer workflows"
```

---

### Task 11: Run full check and final cleanup

**Step 1: Format and lint**

Run: `just check`
Expected: No issues

**Step 2: Run all tests**

Run: `just test`
Expected: All tests pass

**Step 3: Final commit if any formatting changes**

```bash
git add -A
git commit -m "chore: formatting"
```
