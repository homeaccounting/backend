# Account Types Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Introduce user-facing account types (Cash, Bank Account, E-Wallet, Asset, Loan) with per-type structured properties, renaming existing `AccountType` to `AccountCategory` with `Regular`/`External` constructors.

**Architecture:** New `AccountType` sum type with per-variant property records nested inside `AccountCategory`'s `Regular` constructor. Custom JSON serialization for backwards compatibility with existing events. New `SetAccountType` command/event for changing account type. Overdraft defaults driven by account type at creation time.

**Tech Stack:** Haskell, Servant, Eventium (event sourcing), QuickCheck, Hspec, Aeson

**Spec:** `docs/specs/2026-04-07-account-types-design.md`

---

### Task 1: Define new domain types in `Domain.Core.Types`

**Files:**
- Modify: `src/Domain/Core/Types.hs:494-503`

This is the foundation — every subsequent task depends on these types compiling.

- [ ] **Step 1: Add new types above the existing `AccountType` definition**

Add new types before line 494. These are the per-variant property records, sub-enums, and the new `AccountType` sum type:

```haskell
-- | Network of a bank card.
data CardNetwork
  = Visa
  | Mastercard
  | Amex
  | OtherCardNetwork Text
  deriving (Show, Eq, Generic)

instance ToJSON CardNetwork

instance FromJSON CardNetwork

-- | Kind of asset held.
data AssetKind
  = Property
  | Vehicle
  | Stocks
  | RetirementFund
  | OtherAsset Text
  deriving (Show, Eq, Generic)

instance ToJSON AssetKind

instance FromJSON AssetKind

-- | Properties specific to cash accounts.
data CashProperties = CashProperties
  { storageLocation :: Maybe Text
  , metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON CashProperties

instance FromJSON CashProperties

-- | Properties specific to bank accounts (checking, savings, debit/credit cards).
data BankAccountProperties = BankAccountProperties
  { bankName :: Maybe Text
  , accountNumber :: Maybe Text
  , cardNetwork :: Maybe CardNetwork
  , metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON BankAccountProperties

instance FromJSON BankAccountProperties

-- | Properties specific to electronic wallet accounts.
data EWalletProperties = EWalletProperties
  { provider :: Maybe Text
  , accountIdentifier :: Maybe Text
  , metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON EWalletProperties

instance FromJSON EWalletProperties

-- | Properties specific to asset accounts (property, vehicles, stocks, etc.).
data AssetProperties = AssetProperties
  { assetKind :: Maybe AssetKind
  , description :: Maybe Text
  , metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AssetProperties

instance FromJSON AssetProperties

-- | Properties specific to loan/liability accounts.
data LoanProperties = LoanProperties
  { lender :: Maybe Text
  , interestRate :: Maybe Rational
  , dueDate :: Maybe Day
  , metadata :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON LoanProperties

instance FromJSON LoanProperties

-- | Default property constructors with all fields empty.
defaultCashProperties :: CashProperties
defaultCashProperties = CashProperties Nothing mempty

defaultBankAccountProperties :: BankAccountProperties
defaultBankAccountProperties = BankAccountProperties Nothing Nothing Nothing mempty

defaultEWalletProperties :: EWalletProperties
defaultEWalletProperties = EWalletProperties Nothing Nothing mempty

defaultAssetProperties :: AssetProperties
defaultAssetProperties = AssetProperties Nothing Nothing mempty

defaultLoanProperties :: LoanProperties
defaultLoanProperties = LoanProperties Nothing Nothing Nothing mempty

-- | User-facing account classification with per-type properties.
data AccountType
  = Cash CashProperties
  | BankAccount BankAccountProperties
  | EWallet EWalletProperties
  | Asset AssetProperties
  | Loan LoanProperties
  deriving (Show, Eq, Generic)

instance ToJSON AccountType

instance FromJSON AccountType

-- | Convenience constructors with default empty properties.
defaultCash :: AccountType
defaultCash = Cash defaultCashProperties

defaultBankAccount :: AccountType
defaultBankAccount = BankAccount defaultBankAccountProperties

defaultEWallet :: AccountType
defaultEWallet = EWallet defaultEWalletProperties

defaultAsset :: AccountType
defaultAsset = Asset defaultAssetProperties

defaultLoan :: AccountType
defaultLoan = Loan defaultLoanProperties
```

- [ ] **Step 2: Rename existing `AccountType` to `AccountCategory` and update constructors**

Replace the existing `AccountType` definition (lines 494-503) with:

```haskell
-- | Business behavior classification for accounts.
--
-- Regular accounts are user-created and carry an AccountType for UI categorization.
-- External accounts are system-created for tracking income/expenses.
data AccountCategory
  = Regular AccountType
  | External
  deriving (Show, Eq, Generic)
```

- [ ] **Step 3: Write custom JSON instances for `AccountCategory`**

Replace the Generic-derived `ToJSON`/`FromJSON` instances (lines 501-503) with custom instances that handle backwards compatibility. Old events contain `"RegularAccount"` and `"ExternalAccount"` strings:

```haskell
instance ToJSON AccountCategory where
  toJSON External = String "External"
  toJSON (Regular at) = object ["tag" .= String "Regular", "accountType" .= at]

instance FromJSON AccountCategory where
  parseJSON (String "External") = pure External
  parseJSON (String "ExternalAccount") = pure External
  parseJSON (String "RegularAccount") = pure (Regular defaultCash)
  parseJSON (String "Internal") = pure (Regular defaultCash)
  parseJSON (Object o) = do
    tag <- o .: "tag"
    case (tag :: Text) of
      "Internal" -> Regular <$> o .: "accountType"
      "RegularAccount" -> Regular <$> o .:? "accountType" .!= defaultCash
      _ -> fail $ "Unknown AccountCategory tag: " <> show tag
  parseJSON v = fail $ "Cannot parse AccountCategory from: " <> show v
```

- [ ] **Step 4: Update imports**

Add to the module's import list: `Data.Map (Map)`, `Data.Time.Calendar (Day)`, and ensure `Data.Aeson` has `object`, `(.=)`, `(.:)`, `(.:?)`, `(.!=)`, `Object`, `String` imported.

- [ ] **Step 5: Update module exports**

Export all new types, constructors, default values, and property records from the module. Add to the export list:

```haskell
  -- Account types
  AccountType (..)
  CardNetwork (..)
  AssetKind (..)
  CashProperties (..)
  BankAccountProperties (..)
  EWalletProperties (..)
  AssetProperties (..)
  LoanProperties (..)
  defaultCashProperties
  defaultBankAccountProperties
  defaultEWalletProperties
  defaultAssetProperties
  defaultLoanProperties
  defaultCash
  defaultBankAccount
  defaultEWallet
  defaultAsset
  defaultLoan
  -- Account category (renamed from AccountType)
  AccountCategory (..)
```

Remove the old `AccountType (..)` export (it now refers to the new sum type).

- [ ] **Step 6: Build to verify types compile**

Run: `just build`
Expected: Build failure — downstream code still references old `AccountType` constructors (`RegularAccount`, `ExternalAccount`). This is expected; we'll fix references in subsequent tasks.

- [ ] **Step 7: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "feat(domain): add AccountType sum type and rename old AccountType to AccountCategory"
```

---

### Task 2: Update Account events

**Files:**
- Modify: `src/Domain/Account/Events.hs:54-62,75-87,173-178`

- [ ] **Step 1: Update `AccountCreated` event field**

Rename the `accountType` field to `accountCategory` and change its type from `AccountType` to `AccountCategory` in the `AccountCreated` record (around line 82):

```haskell
  , accountCategory :: AccountCategory
```

- [ ] **Step 2: Add custom JSON for `AccountCreated` to preserve JSON key name**

The `AccountCreated` event must serialize `accountCategory` as the JSON key `"accountType"` for backwards compatibility. Replace the `deriveJSON defaultOptions ''AccountCreated` TH splice with a custom instance that maps the Haskell field `accountCategory` to JSON key `"accountType"`. Use Aeson's `fieldLabelModifier`:

```haskell
$(deriveJSON defaultOptions { fieldLabelModifier = \case
    "accountCategory" -> "accountType"
    other -> other
  } ''AccountCreated)
```

- [ ] **Step 3: Add `AccountTypeSet` event definition**

Add before the TH deriveJSON section (before line 173):

```haskell
-- | Event emitted when an account's user-facing type is changed.
data AccountTypeSet = AccountTypeSet
  { accountType :: AccountType
  , by :: UserId
  }
  deriving (Show, Eq, Generic)
```

And add its JSON derivation:

```haskell
$(deriveJSON defaultOptions ''AccountTypeSet)
```

- [ ] **Step 4: Register in TH event list**

Add `''AccountTypeSet` to the `accountEvents` list (around line 54-62).

- [ ] **Step 5: Update imports**

Update imports to reference `AccountCategory` instead of `AccountType` from `Domain.Core.Types`.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Account/Events.hs
git commit -m "feat(domain): add AccountTypeSet event and rename accountType field to accountCategory"
```

---

### Task 3: Update Account commands

**Files:**
- Modify: `src/Domain/Account/Commands.hs:56-64,86-98,218-223`

- [ ] **Step 1: Update `CreateAccount` command field**

Rename the `accountType` field to `accountCategory` and change type to `AccountCategory` (around line 92):

```haskell
  , accountCategory :: AccountCategory
```

- [ ] **Step 2: Add custom JSON for `CreateAccount`**

Same backwards compat approach as events — map `accountCategory` to JSON key `"accountType"`:

```haskell
$(deriveJSON defaultOptions { fieldLabelModifier = \case
    "accountCategory" -> "accountType"
    other -> other
  } ''CreateAccount)
```

- [ ] **Step 3: Add `SetAccountType` command definition**

Add before the TH deriveJSON section (before line 218):

```haskell
-- | Command to change an account's user-facing type. Owner only.
data SetAccountType = SetAccountType
  { accountType :: AccountType
  , setBy :: UserId
  }
  deriving (Show, Eq, Generic)
```

And add its JSON derivation:

```haskell
$(deriveJSON defaultOptions ''SetAccountType)
```

- [ ] **Step 4: Register in TH command list**

Add `''SetAccountType` to the `accountCommands` list (around line 56-64).

- [ ] **Step 5: Update imports**

Update imports to reference `AccountCategory` and `AccountType` from `Domain.Core.Types`.

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Account/Commands.hs
git commit -m "feat(domain): add SetAccountType command and rename accountType field to accountCategory"
```

---

### Task 4: Update Account errors

**Files:**
- Modify: `src/Domain/Account/Errors.hs:57-118,277-303`
- Modify: `src/Domain/Account/CommandHandler.hs:68-79`

- [ ] **Step 1: Add `ExternalTypeNotSettable` to rich error type**

Add new variant to the `AccountError` type in `Errors.hs` (after `ExternalAccountNotShareable`, around line 112):

```haskell
  | ExternalTypeNotSettable
      { externalTypeNotSettableId :: AccountId
      }
```

- [ ] **Step 2: Add error constructor**

Add after `mkExternalAccountNotShareable` (around line 284):

```haskell
mkExternalTypeNotSettable :: AccountId -> AccountError
mkExternalTypeNotSettable accountId =
  mkAppError
    "setAccountType"
    "Cannot set type on external account"
    [("accountId", tshow (unAccountId accountId))]
    (ExternalTypeNotSettable {externalTypeNotSettableId = accountId})
```

- [ ] **Step 3: Add simple error to command handler**

Add `ExternalTypeNotSettable` to the `AccountError` enum in `CommandHandler.hs` (around line 79):

```haskell
  | ExternalTypeNotSettable
```

- [ ] **Step 4: Build to verify errors compile**

Run: `just build`
Expected: Still fails on other downstream references, but error types should compile.

- [ ] **Step 5: Commit**

```bash
git add src/Domain/Account/Errors.hs src/Domain/Account/CommandHandler.hs
git commit -m "feat(domain): add ExternalTypeNotSettable error variant"
```

---

### Task 5: Update Account projection

**Files:**
- Modify: `src/Domain/Account/Projection.hs:105-119,134-145,222-265`

- [ ] **Step 1: Rename `accountType` field to `accountCategory` in `Account` record**

In the `Account` data type (around line 113), change:

```haskell
  , accountCategory :: AccountCategory
```

- [ ] **Step 2: Update `accountDefault`**

Update the default value (around line 134-145) to use the new type:

```haskell
  , accountCategory = Regular defaultCash
```

- [ ] **Step 3: Update `handleAccountEvent` for `AccountCreated`**

In the AccountCreated handler (around line 223-239), update the field assignment:

```haskell
  , accountCategory = event.accountCategory
```

- [ ] **Step 4: Add handler for `AccountTypeSet`**

Add a new case to `handleAccountEvent` (after OverdraftLimitSet handler, around line 265):

```haskell
handleAccountEvent account (AccountTypeSetAccountEvent event) =
  account {accountCategory = Regular event.accountType}
```

- [ ] **Step 5: Update all field access**

Search for `.accountType` in this file and replace with `.accountCategory`. Update helper functions like `isOwner`, `hasAccess`, etc. if they pattern match on `AccountType`.

- [ ] **Step 6: Update imports**

Update imports to reference `AccountCategory`, `Regular`, `External`, `AccountType`, `defaultCash` from `Domain.Core.Types`.

- [ ] **Step 7: Commit**

```bash
git add src/Domain/Account/Projection.hs
git commit -m "feat(domain): update Account projection for AccountCategory and AccountTypeSet"
```

---

### Task 6: Update Account command handler

**Files:**
- Modify: `src/Domain/Account/CommandHandler.hs:138-257`

- [ ] **Step 1: Update `CreateAccount` handler**

In the CreateAccount case (around line 140-162):

1. Replace all references to `cmd.accountType` with `cmd.accountCategory`
2. Update the overdraft default logic (lines 148-152) to:

```haskell
        Nothing -> case cmd.accountCategory of
          External -> Nothing
          Regular (Loan _) -> Nothing
          Regular _ -> Just (unsafeMoney (moneyCurrency cmd.initialBalance) 0)
```

3. Update the `AccountCreated` event construction to pass `accountCategory`:

```haskell
        AccountCreatedAccountEvent
          AccountCreated
            { name = cmd.name
            , initialBalance = cmd.initialBalance
            , by = cmd.createdBy
            , accountCategory = cmd.accountCategory
            , overdraftLimit = resolvedOverdraft
            }
```

- [ ] **Step 2: Update other handlers that check account type**

In `ShareAccount` handler (around line 164-177), update the external account check from:

```haskell
account.accountType == ExternalAccount
```

to:

```haskell
account.accountCategory == External
```

Similarly update `DebitAccount` handler (around line 193-220) if it checks `accountType`.

- [ ] **Step 3: Add `SetAccountType` handler**

Add a new case before the CreditAccount handler (around line 246). Follow the `SetOverdraftLimit` pattern:

```haskell
handleAccountCommand account (SetAccountTypeAccountCommand cmd) =
  case account.accountCategory of
    External -> Left ExternalTypeNotSettable
    Regular _ ->
      if not (isOwner cmd.setBy account)
        then Left NotAccountOwner
        else
          Right
            [ AccountTypeSetAccountEvent
                AccountTypeSet
                  { accountType = cmd.accountType
                  , by = cmd.setBy
                  }
            ]
```

- [ ] **Step 4: Update imports**

Update imports to use `AccountCategory (..)`, `AccountType (..)`, `defaultCash` from `Domain.Core.Types`.

- [ ] **Step 5: Commit**

```bash
git add src/Domain/Account/CommandHandler.hs
git commit -m "feat(domain): add SetAccountType handler and update overdraft defaults by type"
```

---

### Task 7: Update read model

**Files:**
- Modify: `src/Application/ReadModels/Account.hs:99-115,224-240,304-316`

- [ ] **Step 1: Rename `accountType` field in `AccountData`**

Change the field (around line 107) to:

```haskell
  , accountCategory :: AccountCategory
```

- [ ] **Step 2: Update `processEvent` for AccountCreated**

In the AccountCreated handler (around line 224-240), update field assignment:

```haskell
  , accountCategory = event.accountCategory
```

- [ ] **Step 3: Add handler for AccountTypeSet**

Add after the OverdraftLimitSet handler (around line 316):

```haskell
processEvent readModel (AccountTypeSetEvent streamId event) = do
  atomically $ modifyTVar' readModel $ Map.adjust
    (\ad -> ad {accountCategory = Regular event.accountType})
    (unsafeAccountId streamId)
```

Adapt to the exact pattern used by other handlers in this file (they may use a different event wrapper or update pattern).

- [ ] **Step 4: Update all field references**

Replace `.accountType` with `.accountCategory` throughout the file.

- [ ] **Step 5: Update imports**

Update imports to reference `AccountCategory`, `Regular`, `External`, `AccountType` from `Domain.Core.Types`.

- [ ] **Step 6: Commit**

```bash
git add src/Application/ReadModels/Account.hs
git commit -m "feat(readmodel): update AccountData for AccountCategory and handle AccountTypeSet"
```

---

### Task 8: Update Account service

**Files:**
- Modify: `src/Application/Services/AccountService.hs:81-117,173-228,302-329`

- [ ] **Step 1: Update field references**

Replace all `.accountType` references with `.accountCategory` throughout the file. In `shareAccount` (around line 198), update the external account check:

```haskell
summary.accountCategory == External
```

- [ ] **Step 2: Add `setAccountType` service function**

Follow the `setOverdraftLimit` pattern (lines 302-329). Add after it:

```haskell
setAccountType ::
  ( MonadReader env m
  , HasEventStore env
  , HasAccountReadModel env
  , MonadIO m
  , MonadError AppError m
  ) =>
  UserId ->
  UUID ->
  AccountType ->
  m ()
setAccountType userId rawAccountId accountType = do
  accountId <- parseAccountId rawAccountId
  void $
    executeAccountCommand
      accountId
      ( SetAccountTypeAccountCommand
          SetAccountType
            { accountType = accountType
            , setBy = userId
            }
      )
```

Adapt to match the exact pattern and imports of `setOverdraftLimit`.

- [ ] **Step 3: Update imports**

Add `SetAccountType`, `SetAccountTypeAccountCommand`, and `AccountType` to imports.

- [ ] **Step 4: Commit**

```bash
git add src/Application/Services/AccountService.hs
git commit -m "feat(service): add setAccountType service and update field references"
```

---

### Task 9: Update Web types and DTOs

**Files:**
- Modify: `src/Web/Types.hs:125-132,170-179,490-514`

- [ ] **Step 1: Add `AccountTypeRequest` DTO**

Add a new DTO type for the discriminated JSON request format:

```haskell
data AccountTypeRequest = AccountTypeRequest
  { type_ :: Text
  , storageLocation :: Maybe Text
  , bankName :: Maybe Text
  , accountNumber :: Maybe Text
  , cardNetwork :: Maybe Text
  , provider :: Maybe Text
  , accountIdentifier :: Maybe Text
  , assetKind :: Maybe Text
  , description :: Maybe Text
  , lender :: Maybe Text
  , interestRate :: Maybe Double
  , dueDate :: Maybe Text
  , metadata :: Maybe (Map Text Text)
  }
  deriving (Show, Eq, Generic)
```

Add custom JSON instance that maps `type_` to `"type"`:

```haskell
instance FromJSON AccountTypeRequest where
  parseJSON = withObject "AccountTypeRequest" $ \o ->
    AccountTypeRequest
      <$> o .: "type"
      <*> o .:? "storageLocation"
      <*> o .:? "bankName"
      <*> o .:? "accountNumber"
      <*> o .:? "cardNetwork"
      <*> o .:? "provider"
      <*> o .:? "accountIdentifier"
      <*> o .:? "assetKind"
      <*> o .:? "description"
      <*> o .:? "lender"
      <*> o .:? "interestRate"
      <*> o .:? "dueDate"
      <*> o .:? "metadata"

instance ToJSON AccountTypeRequest where
  toJSON r = object $ catMaybes
    [ Just ("type" .= r.type_)
    , ("storageLocation" .=) <$> r.storageLocation
    , ("bankName" .=) <$> r.bankName
    , ("accountNumber" .=) <$> r.accountNumber
    , ("cardNetwork" .=) <$> r.cardNetwork
    , ("provider" .=) <$> r.provider
    , ("accountIdentifier" .=) <$> r.accountIdentifier
    , ("assetKind" .=) <$> r.assetKind
    , ("description" .=) <$> r.description
    , ("lender" .=) <$> r.lender
    , ("interestRate" .=) <$> r.interestRate
    , ("dueDate" .=) <$> r.dueDate
    , ("metadata" .=) <$> r.metadata
    ]
```

- [ ] **Step 2: Add `toAccountType` conversion function**

```haskell
toAccountType :: AccountTypeRequest -> Either Text AccountType
toAccountType req = case req.type_ of
  "cash" -> Right $ Cash CashProperties
    { storageLocation = req.storageLocation
    , metadata = fromMaybe mempty req.metadata
    }
  "bankAccount" -> Right $ BankAccount BankAccountProperties
    { bankName = req.bankName
    , accountNumber = req.accountNumber
    , cardNetwork = parseCardNetwork <$> req.cardNetwork
    , metadata = fromMaybe mempty req.metadata
    }
  "eWallet" -> Right $ EWallet EWalletProperties
    { provider = req.provider
    , accountIdentifier = req.accountIdentifier
    , metadata = fromMaybe mempty req.metadata
    }
  "asset" -> Right $ Asset AssetProperties
    { assetKind = parseAssetKind <$> req.assetKind
    , description = req.description
    , metadata = fromMaybe mempty req.metadata
    }
  "loan" -> do
    let parsedRate = toRational <$> req.interestRate
    let parsedDate = req.dueDate >>= parseDay
    Right $ Loan LoanProperties
      { lender = req.lender
      , interestRate = parsedRate
      , dueDate = parsedDate
      , metadata = fromMaybe mempty req.metadata
      }
  other -> Left $ "Unknown account type: " <> other

parseCardNetwork :: Text -> CardNetwork
parseCardNetwork "visa" = Visa
parseCardNetwork "mastercard" = Mastercard
parseCardNetwork "amex" = Amex
parseCardNetwork other = OtherCardNetwork other

parseAssetKind :: Text -> AssetKind
parseAssetKind "property" = Property
parseAssetKind "vehicle" = Vehicle
parseAssetKind "stocks" = Stocks
parseAssetKind "retirementFund" = RetirementFund
parseAssetKind other = OtherAsset other

parseDay :: Text -> Maybe Day
parseDay = parseTimeM True defaultTimeLocale "%Y-%m-%d" . unpack
```

- [ ] **Step 3: Add `fromAccountType` for response serialization**

```haskell
fromAccountType :: AccountType -> Value
fromAccountType (Cash props) = object $ catMaybes
  [ Just ("type" .= ("cash" :: Text))
  , ("storageLocation" .=) <$> props.storageLocation
  , if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
  ]
fromAccountType (BankAccount props) = object $ catMaybes
  [ Just ("type" .= ("bankAccount" :: Text))
  , ("bankName" .=) <$> props.bankName
  , ("accountNumber" .=) <$> props.accountNumber
  , ("cardNetwork" .=) <$> (cardNetworkToText <$> props.cardNetwork)
  , if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
  ]
fromAccountType (EWallet props) = object $ catMaybes
  [ Just ("type" .= ("eWallet" :: Text))
  , ("provider" .=) <$> props.provider
  , ("accountIdentifier" .=) <$> props.accountIdentifier
  , if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
  ]
fromAccountType (Asset props) = object $ catMaybes
  [ Just ("type" .= ("asset" :: Text))
  , ("assetKind" .=) <$> (assetKindToText <$> props.assetKind)
  , ("description" .=) <$> props.description
  , if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
  ]
fromAccountType (Loan props) = object $ catMaybes
  [ Just ("type" .= ("loan" :: Text))
  , ("lender" .=) <$> props.lender
  , ("interestRate" .=) <$> (fromRational <$> props.interestRate :: Maybe Double)
  , ("dueDate" .=) <$> props.dueDate
  , if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
  ]

cardNetworkToText :: CardNetwork -> Text
cardNetworkToText Visa = "visa"
cardNetworkToText Mastercard = "mastercard"
cardNetworkToText Amex = "amex"
cardNetworkToText (OtherCardNetwork t) = t

assetKindToText :: AssetKind -> Text
assetKindToText Property = "property"
assetKindToText Vehicle = "vehicle"
assetKindToText Stocks = "stocks"
assetKindToText RetirementFund = "retirementFund"
assetKindToText (OtherAsset t) = t
```

- [ ] **Step 4: Add `accountType` field to `CreateAccountRequest`**

Update the record (around line 125-132) to include:

```haskell
  , accountType :: Maybe AccountTypeRequest
```

- [ ] **Step 5: Add `accountType` field to `AccountResponse`**

Update the record (around line 170-179) to include:

```haskell
  , accountType :: Maybe Value
```

- [ ] **Step 6: Add `SetAccountTypeRequest` DTO**

```haskell
data SetAccountTypeRequest = SetAccountTypeRequest
  { accountType :: AccountTypeRequest
  }
  deriving (Show, Eq, Generic, FromJSON, ToJSON)
```

- [ ] **Step 7: Update `toCreateAccountCommand`**

Change the signature (around line 490) from:

```haskell
toCreateAccountCommand :: UserId -> AccountType -> CreateAccountRequest -> Either Text CreateAccount
```

to:

```haskell
toCreateAccountCommand :: UserId -> CreateAccountRequest -> Either Text CreateAccount
```

In the body, parse `accountType` from the request and wrap in `Regular`:

```haskell
  parsedType <- case req.accountType of
    Nothing -> Right defaultCash
    Just atr -> toAccountType atr
  -- ... use Regular parsedType as accountCategory
```

Update the `CreateAccount` construction to use `accountCategory = Regular parsedType`.

- [ ] **Step 8: Update `fromAccountData` response conversion**

Update the function that converts `AccountData` to `AccountResponse` to include the `accountType` field:

```haskell
  , accountType = case ad.accountCategory of
      Regular at -> Just (fromAccountType at)
      External -> Nothing
```

- [ ] **Step 9: Commit**

```bash
git add src/Web/Types.hs
git commit -m "feat(web): add AccountTypeRequest DTO, toAccountType conversion, and update request/response types"
```

---

### Task 10: Update Web API endpoints

**Files:**
- Modify: `src/Web/API/AccountAPI.hs:92-133,170-177,184-197`

- [ ] **Step 1: Add `SetAccountType` endpoint to API type**

Add to the `AccountAPI` type (around line 127-133), after the overdraft-limit endpoint:

```haskell
  :<|> Capture "accountId" UUID
    :> "type"
    :> ReqBody '[JSON] SetAccountTypeRequest
    :> Put '[JSON] NoContent
```

- [ ] **Step 2: Create `setAccountTypeHandler`**

Follow the `setOverdraftLimitHandler` pattern:

```haskell
setAccountTypeHandler :: AuthenticatedUser -> UUID -> SetAccountTypeRequest -> AppM NoContent
setAccountTypeHandler authUser accountId req = do
  case toAccountType req.accountType of
    Left err -> throwError $ validationError err
    Right accountType -> do
      AccountService.setAccountType authUser.userId accountId accountType
      pure NoContent
```

- [ ] **Step 3: Update `createAccountHandler`**

Update the handler (around line 184-197) to call the new `toCreateAccountCommand` signature (without the `AccountType` parameter):

```haskell
  case toCreateAccountCommand authUser.userId req of
```

Remove the hardcoded `RegularAccount` argument.

- [ ] **Step 4: Wire handler into server**

Add `setAccountTypeHandler` to `accountServer` (around line 170-177).

- [ ] **Step 5: Update imports**

Add imports for `SetAccountTypeRequest`, `toAccountType`, and the service function.

- [ ] **Step 6: Build to verify full compilation**

Run: `just build`
Expected: Build succeeds (all downstream references now updated).

- [ ] **Step 7: Commit**

```bash
git add src/Web/API/AccountAPI.hs
git commit -m "feat(web): add PUT /accounts/:id/type endpoint and update createAccountHandler"
```

---

### Task 11: Update test helpers and generators

**Files:**
- Modify: `test/Testkit/Generators.hs:16-42,65-93`
- Modify: `test/Testkit/Helpers.hs:16-34,55-66`

- [ ] **Step 1: Add generators for new types**

In `test/Testkit/Generators.hs`, add:

```haskell
genCardNetwork :: Gen CardNetwork
genCardNetwork =
  oneof
    [ pure Visa
    , pure Mastercard
    , pure Amex
    , OtherCardNetwork <$> genText
    ]

genAssetKind :: Gen AssetKind
genAssetKind =
  oneof
    [ pure Property
    , pure Vehicle
    , pure Stocks
    , pure RetirementFund
    , OtherAsset <$> genText
    ]

genCashProperties :: Gen CashProperties
genCashProperties =
  CashProperties
    <$> arbitrary
    <*> pure mempty

genBankAccountProperties :: Gen BankAccountProperties
genBankAccountProperties =
  BankAccountProperties
    <$> arbitrary
    <*> arbitrary
    <*> liftArbitrary genCardNetwork
    <*> pure mempty

genEWalletProperties :: Gen EWalletProperties
genEWalletProperties =
  EWalletProperties
    <$> arbitrary
    <*> arbitrary
    <*> pure mempty

genAssetProperties :: Gen AssetProperties
genAssetProperties =
  AssetProperties
    <$> liftArbitrary genAssetKind
    <*> arbitrary
    <*> pure mempty

genLoanProperties :: Gen LoanProperties
genLoanProperties =
  LoanProperties
    <$> arbitrary
    <*> (fmap toRational <$> (arbitrary :: Gen (Maybe Double)))
    <*> arbitrary
    <*> pure mempty

genAccountType :: Gen AccountType
genAccountType =
  oneof
    [ Cash <$> genCashProperties
    , BankAccount <$> genBankAccountProperties
    , EWallet <$> genEWalletProperties
    , Asset <$> genAssetProperties
    , Loan <$> genLoanProperties
    ]

genAccountCategory :: Gen AccountCategory
genAccountCategory =
  frequency
    [ (4, Regular <$> genAccountType)
    , (1, pure External)
    ]
```

Add a `genText :: Gen Text` helper if not already present, or use the existing text generation pattern.

- [ ] **Step 2: Add Arbitrary instances**

```haskell
instance Arbitrary AccountType where
  arbitrary = genAccountType

instance Arbitrary AccountCategory where
  arbitrary = genAccountCategory

instance Arbitrary CardNetwork where
  arbitrary = genCardNetwork

instance Arbitrary AssetKind where
  arbitrary = genAssetKind

instance Arbitrary CashProperties where
  arbitrary = genCashProperties

instance Arbitrary BankAccountProperties where
  arbitrary = genBankAccountProperties

instance Arbitrary EWalletProperties where
  arbitrary = genEWalletProperties

instance Arbitrary AssetProperties where
  arbitrary = genAssetProperties

instance Arbitrary LoanProperties where
  arbitrary = genLoanProperties
```

- [ ] **Step 3: Update module exports**

Export all new generators and Arbitrary instances.

- [ ] **Step 4: Add mock constructors in Helpers**

In `test/Testkit/Helpers.hs`, add:

```haskell
mockAccountType :: AccountType
mockAccountType = defaultCash

mockAccountCategory :: AccountCategory
mockAccountCategory = Regular defaultCash
```

Export these from the module.

- [ ] **Step 5: Commit**

```bash
git add test/Testkit/Generators.hs test/Testkit/Helpers.hs
git commit -m "test: add generators and helpers for AccountType and AccountCategory"
```

---

### Task 12: Update existing unit and property tests

**Files:**
- Modify: `test/Domain/Account/CommandHandlerSpec.hs:40-94`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs:54-68`
- Modify: `test/Application/Services/AccountServiceSpec.hs`

- [ ] **Step 1: Update CommandHandlerSpec helpers**

In `test/Domain/Account/CommandHandlerSpec.hs`, update helpers (around lines 71-94):

Replace `RegularAccount` with `Regular defaultCash` and `ExternalAccount` with `External` in `regularAccountWithOwner`, `externalAccountWithOwner`, and `accountWithSharedAccess`.

- [ ] **Step 2: Update CommandHandlerPropertySpec helpers**

In `test/Domain/Account/CommandHandlerPropertySpec.hs`, update `createAccountWithOwner` (around lines 54-68):

Replace the overdraft default pattern match to use `AccountCategory`:

```haskell
  let overdraft = case category of
        External -> Nothing
        Regular (Loan _) -> Nothing
        Regular _ -> Just (unsafeMoney (moneyCurrency initialBalance) 0)
```

Replace `RegularAccount`/`ExternalAccount` references with `Regular defaultCash`/`External`.

- [ ] **Step 3: Update AccountServiceSpec**

Replace all `RegularAccount`/`ExternalAccount` references with `Regular mockAccountType`/`External`.

- [ ] **Step 4: Run all tests**

Run: `just test`
Expected: All existing tests pass with the renamed types.

- [ ] **Step 5: Commit**

```bash
git add test/
git commit -m "test: update existing tests for AccountCategory rename"
```

---

### Task 13: Write tests for SetAccountType command handler

**Files:**
- Modify: `test/Domain/Account/CommandHandlerSpec.hs`

- [ ] **Step 1: Write unit tests for SetAccountType**

Add a new `setAccountTypeSpec` section following the `setOverdraftLimitSpec` pattern:

```haskell
setAccountTypeSpec :: Spec
setAccountTypeSpec = do
  describe "Given SetAccountType command" $ do
    context "When account is regular and user is owner" $ do
      it "Then emits AccountTypeSet event" $ do
        let account = regularAccountWithOwner testUserId
        let cmd = SetAccountTypeAccountCommand
              SetAccountType
                { accountType = defaultBankAccount
                , setBy = testUserId
                }
        let result = handleAccountCommand account cmd
        result `shouldSatisfy` isRight

    context "When account is external" $ do
      it "Then rejects with ExternalTypeNotSettable" $ do
        let account = externalAccountWithOwner testUserId
        let cmd = SetAccountTypeAccountCommand
              SetAccountType
                { accountType = defaultCash
                , setBy = testUserId
                }
        handleAccountCommand account cmd `shouldBe` Left ExternalTypeNotSettable

    context "When user is not owner" $ do
      it "Then rejects with NotAccountOwner" $ do
        let account = regularAccountWithOwner testUserId
        let cmd = SetAccountTypeAccountCommand
              SetAccountType
                { accountType = defaultBankAccount
                , setBy = otherUserId
                }
        handleAccountCommand account cmd `shouldBe` Left NotAccountOwner
```

- [ ] **Step 2: Register in spec**

Add `setAccountTypeSpec` to the top-level `spec` function.

- [ ] **Step 3: Run tests to verify they pass**

Run: `cabal test all --test-option='--match' --test-option="/SetAccountType/"`
Expected: All SetAccountType tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/Domain/Account/CommandHandlerSpec.hs
git commit -m "test: add unit tests for SetAccountType command handler"
```

---

### Task 14: Write tests for overdraft defaults by account type

**Files:**
- Modify: `test/Domain/Account/CommandHandlerSpec.hs`

- [ ] **Step 1: Write tests for overdraft defaults**

Add tests in the CreateAccount section verifying default overdraft per type:

```haskell
    context "When overdraft not specified for Loan account" $ do
      it "Then defaults to unlimited (Nothing)" $ do
        let cmd = CreateAccountCommand CreateAccount
              { name = "My Loan"
              , initialBalance = mockMoney 0
              , createdBy = testUserId
              , accountCategory = Regular defaultLoan
              , overdraftLimit = Nothing
              }
        case handleAccountCommand accountDefault cmd of
          Right [AccountCreatedAccountEvent e] ->
            e.overdraftLimit `shouldBe` Nothing
          other -> expectationFailure $ "Unexpected: " <> show other

    context "When overdraft not specified for Cash account" $ do
      it "Then defaults to zero" $ do
        let cmd = CreateAccountCommand CreateAccount
              { name = "My Cash"
              , initialBalance = mockMoney 0
              , createdBy = testUserId
              , accountCategory = Regular defaultCash
              , overdraftLimit = Nothing
              }
        case handleAccountCommand accountDefault cmd of
          Right [AccountCreatedAccountEvent e] ->
            e.overdraftLimit `shouldBe` Just (unsafeMoney USD 0)
          other -> expectationFailure $ "Unexpected: " <> show other
```

- [ ] **Step 2: Run tests**

Run: `cabal test all --test-option='--match' --test-option="/overdraft/"`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/Domain/Account/CommandHandlerSpec.hs
git commit -m "test: add overdraft default tests per account type"
```

---

### Task 15: Write property tests for serialization and SetAccountType

**Files:**
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs`

- [ ] **Step 1: Add serialization roundtrip properties**

```haskell
serializationSpec :: Spec
serializationSpec = do
  describe "AccountType JSON roundtrip" $ do
    it "survives encode/decode" $ property $ \(at :: AccountType) ->
      eitherDecode (encode at) === Right at

  describe "AccountCategory JSON roundtrip" $ do
    it "survives encode/decode" $ property $ \(ac :: AccountCategory) ->
      eitherDecode (encode ac) === Right ac

  describe "AccountCategory backwards compat" $ do
    it "parses old RegularAccount string" $ do
      eitherDecode "\"RegularAccount\"" `shouldBe` Right (Regular defaultCash)

    it "parses old ExternalAccount string" $ do
      eitherDecode "\"ExternalAccount\"" `shouldBe` Right External
```

- [ ] **Step 2: Add SetAccountType property tests**

```haskell
  describe "SetAccountType" $ do
    it "is idempotent" $ property $
      forAll genAccountType $ \at ->
        forAll genAccountType $ \at2 ->
          let account = regularAccountWithOwner testUserId
              cmd1 = SetAccountTypeAccountCommand SetAccountType { accountType = at, setBy = testUserId }
              cmd2 = SetAccountTypeAccountCommand SetAccountType { accountType = at2, setBy = testUserId }
              -- Apply both commands in sequence
              afterFirst = applyEvents account (fromRight [] $ handleAccountCommand account cmd1)
              afterSecond = applyEvents afterFirst (fromRight [] $ handleAccountCommand afterFirst cmd2)
              -- Apply only second command directly
              directSecond = applyEvents account (fromRight [] $ handleAccountCommand account cmd2)
          in afterSecond.accountCategory === directSecond.accountCategory

    it "always fails on External accounts" $ property $
      forAll genAccountType $ \at ->
        let account = externalAccountWithOwner testUserId
            cmd = SetAccountTypeAccountCommand SetAccountType { accountType = at, setBy = testUserId }
        in handleAccountCommand account cmd === Left ExternalTypeNotSettable
```

- [ ] **Step 3: Register in spec and run**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/Domain/Account/CommandHandlerPropertySpec.hs
git commit -m "test: add property tests for AccountType serialization and SetAccountType"
```

---

### Task 16: Write DTO conversion tests

**Files:**
- Create: `test/Web/TypesSpec.hs` (or modify if it exists)

- [ ] **Step 1: Write tests for `toAccountType` conversion**

```haskell
toAccountTypeSpec :: Spec
toAccountTypeSpec = do
  describe "toAccountType" $ do
    it "parses cash type" $ do
      let req = AccountTypeRequest "cash" (Just "wallet") Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      toAccountType req `shouldBe` Right (Cash (CashProperties (Just "wallet") mempty))

    it "parses bankAccount type" $ do
      let req = AccountTypeRequest "bankAccount" Nothing (Just "Monobank") (Just "1234") (Just "visa") Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      case toAccountType req of
        Right (BankAccount props) -> do
          props.bankName `shouldBe` Just "Monobank"
          props.cardNetwork `shouldBe` Just Visa
        other -> expectationFailure $ "Expected BankAccount, got: " <> show other

    it "parses loan type" $ do
      let req = AccountTypeRequest "loan" Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing (Just "Bank") (Just 12.5) (Just "2028-01-15") Nothing
      case toAccountType req of
        Right (Loan props) -> do
          props.lender `shouldBe` Just "Bank"
          props.interestRate `shouldBe` Just (toRational (12.5 :: Double))
        other -> expectationFailure $ "Expected Loan, got: " <> show other

    it "rejects unknown type" $ do
      let req = AccountTypeRequest "unknown" Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      toAccountType req `shouldSatisfy` isLeft

    it "ignores irrelevant fields" $ do
      let req = AccountTypeRequest "cash" (Just "wallet") (Just "ignored-bank") Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
      case toAccountType req of
        Right (Cash props) -> props.storageLocation `shouldBe` Just "wallet"
        other -> expectationFailure $ "Expected Cash, got: " <> show other
```

- [ ] **Step 2: Run tests**

Run: `cabal test all --test-option='--match' --test-option="/toAccountType/"`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add test/Web/TypesSpec.hs
git commit -m "test: add DTO conversion tests for toAccountType"
```

---

### Task 17: Integration test

**Files:**
- Modify or create: `test/Application/Services/AccountServiceSpec.hs` (or `AccountServiceIntegrationSpec.hs`)

- [ ] **Step 1: Write integration test for account creation with type**

Add a test that creates an account with a specific type through the service layer and verifies the type is persisted in the read model:

```haskell
    it "creates account with BankAccount type" $ do
      let cmd = CreateAccount
            { name = "My Checking"
            , initialBalance = mockMoney 100
            , createdBy = testUserId
            , accountCategory = Regular (BankAccount BankAccountProperties
                { bankName = Just "Monobank"
                , accountNumber = Just "1234"
                , cardNetwork = Just Visa
                , metadata = mempty
                })
            , overdraftLimit = Nothing
            }
      result <- runApp $ AccountService.createAccount cmd
      case result of
        Right (_, accountData) ->
          accountData.accountCategory `shouldBe` Regular (BankAccount BankAccountProperties
            { bankName = Just "Monobank"
            , accountNumber = Just "1234"
            , cardNetwork = Just Visa
            , metadata = mempty
            })
        Left err -> expectationFailure $ show err
```

- [ ] **Step 2: Write integration test for SetAccountType**

```haskell
    it "changes account type from Cash to BankAccount" $ do
      -- Create as Cash
      Right (accountId, _) <- runApp $ AccountService.createAccount createCashCmd
      -- Change to BankAccount
      Right () <- runApp $ AccountService.setAccountType testUserId (unAccountId accountId) defaultBankAccount
      -- Verify
      Right (_, updated) <- runApp $ AccountService.getAccount (unAccountId accountId)
      case updated.accountCategory of
        Regular (BankAccount _) -> pure ()
        other -> expectationFailure $ "Expected BankAccount, got: " <> show other
```

- [ ] **Step 3: Write integration test for backwards compat**

Seed an old-format `AccountCreated` event (with `"RegularAccount"` string) and verify the read model initializes correctly with `Regular defaultCash`.

- [ ] **Step 4: Run all tests**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/
git commit -m "test: add integration tests for account types"
```

---

### Task 18: Format, lint, and final verification

**Files:** All modified files

- [ ] **Step 1: Format all code**

Run: `just format`

- [ ] **Step 2: Lint all code**

Run: `just lint`
Fix any issues.

- [ ] **Step 3: Run full test suite**

Run: `just test`
Expected: All tests pass.

- [ ] **Step 4: Build with CI flags**

Run: `cabal build -fci`
Expected: No warnings treated as errors.

- [ ] **Step 5: Commit any formatting/lint fixes**

```bash
git add -A
git commit -m "chore: format and lint fixes"
```
