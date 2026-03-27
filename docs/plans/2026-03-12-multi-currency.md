---
status: draft
---

# Multi-Currency Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add currency awareness to the Money type and enforce same-currency constraints on all money operations and transfers.

**Architecture:** Currency becomes a property of Money (data Money = Money { amount :: Rational, currency :: Currency }). Account currency is derived from balance.currency. All money operations validate currency match. Clean break on serialization — no backwards compatibility.

**Tech Stack:** Haskell, Servant, Eventium, QuickCheck, Hspec, LiquidHaskell

---

### Task 1: Add Currency type and update Money type in Domain.Core.Types

**Files:**
- Modify: `src/Domain/Core/Types.hs`

**Step 1: Add Currency type after line 73 (before Money section)**

Add between the imports and the Money section:

```haskell
-- -----------------------------------------------------------------------------
-- Currency Type
-- -----------------------------------------------------------------------------

-- | Supported currencies for the accounting system.
data Currency = UAH | USD | EUR | GBP
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

instance ToJSON Currency where
  toJSON UAH = "UAH"
  toJSON USD = "USD"
  toJSON EUR = "EUR"
  toJSON GBP = "GBP"

instance FromJSON Currency where
  parseJSON = withText "Currency" $ \case
    "UAH" -> pure UAH
    "USD" -> pure USD
    "EUR" -> pure EUR
    "GBP" -> pure GBP
    other -> fail $ "Unknown currency: " <> T.unpack other
```

**Step 2: Change Money from newtype to data**

Replace:
```haskell
newtype Money = Money
  { unMoney :: Rational
  }
  deriving (Show, Eq, Ord, Generic)
```

With:
```haskell
data Money = Money
  { amount :: Rational,
    currency :: Currency
  }
  deriving (Show, Eq, Ord, Generic)
```

**Step 3: Update unMoney accessor**

Replace:
```haskell
unMoney :: Money -> Rational
unMoney (Money r) = r
```

With:
```haskell
-- | Extract the rational amount from a Money value.
unMoney :: Money -> Rational
unMoney (Money r _) = r

-- | Extract the currency from a Money value.
moneyCurrency :: Money -> Currency
moneyCurrency (Money _ c) = c
```

**Step 4: Update ToJSON/FromJSON instances**

Replace Money JSON instances with:
```haskell
instance ToJSON Money where
  toJSON (Money amt cur) =
    object ["amount" .= (fromRational amt :: Double), "currency" .= cur]

instance FromJSON Money where
  parseJSON = withObject "Money" $ \o -> do
    (d :: Double) <- o .: "amount"
    cur <- o .: "currency"
    case mkMoney cur (toRational d) of
      Right money -> pure money
      Left err -> fail (T.unpack err)
```

Note: This requires adding `object`, `(.=)`, `(.:)`, `withObject` to the Aeson import:
```haskell
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, withText, (.=), (.:))
```

**Step 5: Update mkMoney smart constructor**

Replace:
```haskell
mkMoney :: Rational -> Either Text Money
mkMoney amount
  | amount < 0 = Left $ T.pack $ "Money amount must be non-negative: " <> show amount
  | otherwise = Right (Money amount)
```

With:
```haskell
mkMoney :: Currency -> Rational -> Either Text Money
mkMoney cur amt
  | amt < 0 = Left $ T.pack $ "Money amount must be non-negative: " <> show amt
  | otherwise = Right (Money amt cur)
```

**Step 6: Update unsafeMoney**

Replace:
```haskell
unsafeMoney :: Rational -> Money
unsafeMoney = Money
```

With:
```haskell
unsafeMoney :: Currency -> Rational -> Money
unsafeMoney = Money
```

**Step 7: Update addMoney (now returns Either)**

Replace:
```haskell
addMoney :: Money -> Money -> Money
addMoney (Money a) (Money b) = Money (a + b)
```

With:
```haskell
addMoney :: Money -> Money -> Either Text Money
addMoney (Money a c1) (Money b c2)
  | c1 /= c2 = Left $ T.pack $ "Currency mismatch: cannot add " <> show c1 <> " and " <> show c2
  | otherwise = Right (Money (a + b) c1)
```

**Step 8: Update subtractMoney (add currency check)**

Replace:
```haskell
subtractMoney :: Money -> Money -> Either Text Money
subtractMoney (Money a) (Money b)
  | a < b = Left $ T.pack $ "Insufficient funds: cannot subtract " <> show b <> " from " <> show a
  | otherwise = Right (Money (a - b))
```

With:
```haskell
subtractMoney :: Money -> Money -> Either Text Money
subtractMoney (Money a c1) (Money b c2)
  | c1 /= c2 = Left $ T.pack $ "Currency mismatch: cannot subtract " <> show c2 <> " from " <> show c1
  | a < b = Left $ T.pack $ "Insufficient funds: cannot subtract " <> show b <> " from " <> show a
  | otherwise = Right (Money (a - b) c1)
```

**Step 9: Update subtractMoneyAllowNegative (now returns Either)**

Replace:
```haskell
subtractMoneyAllowNegative :: Money -> Money -> Money
subtractMoneyAllowNegative (Money a) (Money b) = Money (a - b)
```

With:
```haskell
subtractMoneyAllowNegative :: Money -> Money -> Either Text Money
subtractMoneyAllowNegative (Money a c1) (Money b c2)
  | c1 /= c2 = Left $ T.pack $ "Currency mismatch: cannot subtract " <> show c2 <> " from " <> show c1
  | otherwise = Right (Money (a - b) c1)
```

**Step 10: Update module exports**

Add to the exports:
```haskell
    -- * Currency Type
    Currency (..),
    moneyCurrency,
```

**Step 11: Build to check compilation**

Run: `just build`
Expected: Many compilation errors in downstream modules (this is expected — we'll fix them in subsequent tasks)

**Step 12: Commit**

```bash
git add src/Domain/Core/Types.hs
git commit -m "feat: add Currency type and make Money currency-aware"
```

---

### Task 2: Fix Account Projection (accountDefault and event handlers)

**Files:**
- Modify: `src/Domain/Account/Projection.hs`

**Step 1: Update accountDefault to use Currency**

In `src/Domain/Account/Projection.hs`, replace:
```haskell
accountDefault :: Account
accountDefault = case mkMoney 0 of
  Right m ->
    Account
      { balance = m,
        name = "",
        createdBy = unsafeUserId UUID.nil,
        accountType = RegularAccount,
        accessList = []
      }
  Left _ -> error "accountDefault: mkMoney 0 should never fail"
```

With:
```haskell
accountDefault :: Account
accountDefault = case mkMoney UAH 0 of
  Right m ->
    Account
      { balance = m,
        name = "",
        createdBy = unsafeUserId UUID.nil,
        accountType = RegularAccount,
        accessList = []
      }
  Left _ -> error "accountDefault: mkMoney UAH 0 should never fail"
```

Also update the import to include `Currency (..)` and `mkMoney`:
```haskell
import Domain.Core.Types
  ( AccountAccess (..),
    AccountRole (..),
    AccountType (..),
    Currency (..),
    Money,
    UserId,
    addMoney,
    mkMoney,
    subtractMoneyAllowNegative,
    unsafeUserId,
  )
```

**Step 2: Update handleAccountEvent for AccountDebited**

The `subtractMoneyAllowNegative` now returns `Either`. Replace:
```haskell
handleAccountEvent account (AccountDebitedAccountEvent AccountDebited {..}) =
  let newBalance = subtractMoneyAllowNegative (account ^. #balance) amount
   in account & #balance .~ newBalance
```

With:
```haskell
handleAccountEvent account (AccountDebitedAccountEvent AccountDebited {..}) =
  case subtractMoneyAllowNegative (account ^. #balance) amount of
    Right newBalance -> account & #balance .~ newBalance
    Left _ -> account -- Should not happen: command handler validates currency match
```

**Step 3: Update handleAccountEvent for AccountCredited**

The `addMoney` now returns `Either`. Replace:
```haskell
handleAccountEvent account (AccountCreditedAccountEvent AccountCredited {..}) =
  let newBalance = addMoney (account ^. #balance) amount
   in account & #balance .~ newBalance
```

With:
```haskell
handleAccountEvent account (AccountCreditedAccountEvent AccountCredited {..}) =
  case addMoney (account ^. #balance) amount of
    Right newBalance -> account & #balance .~ newBalance
    Left _ -> account -- Should not happen: command handler validates currency match
```

**Step 4: Commit**

```bash
git add src/Domain/Account/Projection.hs
git commit -m "fix: update account projection for currency-aware Money"
```

---

### Task 3: Update Account CommandHandler for currency validation

**Files:**
- Modify: `src/Domain/Account/CommandHandler.hs`

**Step 1: Add CurrencyMismatch to AccountError**

In `src/Domain/Account/CommandHandler.hs`, add `CurrencyMismatch` to the `AccountError` type:

```haskell
data AccountError
  = AccountAlreadyExists
  | AccountNameEmpty
  | AccountDoesNotExist
  | ExternalAccountCannotBeShared
  | NotAccountOwner
  | CannotShareWithSelf
  | CannotRevokeOwner
  | UserHasNoAccess
  | InsufficientFunds
  | CurrencyMismatch
  deriving (Show, Eq)
```

**Step 2: Update DebitAccount handler to check currency**

Replace the DebitAccount handler:
```haskell
handleAccountCommand account (DebitAccountAccountCommand DebitAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | account ^. #accountType == ExternalAccount =
      Right
        [ AccountDebitedAccountEvent
            AccountDebited
              { amount = amount,
                transactionId = transactionId,
                reason = reason
              }
        ]
  | otherwise =
      case subtractMoney (account ^. #balance) amount of
        Right _ ->
          Right
            [ AccountDebitedAccountEvent
                AccountDebited
                  { amount = amount,
                    transactionId = transactionId,
                    reason = reason
                  }
            ]
        Left _ -> Left InsufficientFunds
```

With:
```haskell
handleAccountCommand account (DebitAccountAccountCommand DebitAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | moneyCurrency amount /= moneyCurrency (account ^. #balance) = Left CurrencyMismatch
  | account ^. #accountType == ExternalAccount =
      Right
        [ AccountDebitedAccountEvent
            AccountDebited
              { amount = amount,
                transactionId = transactionId,
                reason = reason
              }
        ]
  | otherwise =
      case subtractMoney (account ^. #balance) amount of
        Right _ ->
          Right
            [ AccountDebitedAccountEvent
                AccountDebited
                  { amount = amount,
                    transactionId = transactionId,
                    reason = reason
                  }
            ]
        Left _ -> Left InsufficientFunds
```

**Step 3: Update CreditAccount handler to check currency**

Replace:
```haskell
handleAccountCommand account (CreditAccountAccountCommand CreditAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | otherwise =
      Right
        [ AccountCreditedAccountEvent
            AccountCredited
              { amount = amount,
                transactionId = transactionId,
                reason = reason
              }
        ]
```

With:
```haskell
handleAccountCommand account (CreditAccountAccountCommand CreditAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | moneyCurrency amount /= moneyCurrency (account ^. #balance) = Left CurrencyMismatch
  | otherwise =
      Right
        [ AccountCreditedAccountEvent
            AccountCredited
              { amount = amount,
                transactionId = transactionId,
                reason = reason
              }
        ]
```

**Step 4: Update import to include moneyCurrency**

```haskell
import Domain.Core.Types (AccountType (..), moneyCurrency, subtractMoney)
```

**Step 5: Commit**

```bash
git add src/Domain/Account/CommandHandler.hs
git commit -m "feat: add CurrencyMismatch validation to account command handler"
```

---

### Task 4: Update Account read model for currency-aware Money operations

**Files:**
- Modify: `src/Application/ReadModels/Account.hs`

**Step 1: Update processEvent for AccountDebited**

Replace:
```haskell
        AccountDebitedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    summary
                      { balance =
                          subtractMoneyAllowNegative summary.balance evt.amount,
                        version = summary.version + 1
                      }
                )
                accountId
                summaries
```

With:
```haskell
        AccountDebitedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    case subtractMoneyAllowNegative summary.balance evt.amount of
                      Right newBalance ->
                        summary
                          { balance = newBalance,
                            version = summary.version + 1
                          }
                      Left _ -> summary -- Should not happen: command handler validates currency
                )
                accountId
                summaries
```

**Step 2: Update processEvent for AccountCredited**

Replace:
```haskell
        AccountCreditedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    summary
                      { balance =
                          summary.balance `addMoney` evt.amount,
                        version = summary.version + 1
                      }
                )
                accountId
                summaries
```

With:
```haskell
        AccountCreditedEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    case addMoney summary.balance evt.amount of
                      Right newBalance ->
                        summary
                          { balance = newBalance,
                            version = summary.version + 1
                          }
                      Left _ -> summary -- Should not happen: command handler validates currency
                )
                accountId
                summaries
```

**Step 3: Commit**

```bash
git add src/Application/ReadModels/Account.hs
git commit -m "fix: update account read model for currency-aware Money"
```

---

### Task 5: Update Web.Types (DTOs and conversion functions)

**Files:**
- Modify: `src/Web/Types.hs`

**Step 1: Add currency field to CreateAccountRequest**

Replace:
```haskell
data CreateAccountRequest
  = CreateAccountRequest
  { name :: Text,
    initialBalance :: Double
  }
  deriving (Show, Eq, Generic)
```

With:
```haskell
data CreateAccountRequest
  = CreateAccountRequest
  { name :: Text,
    initialBalance :: Double,
    currency :: Text
  }
  deriving (Show, Eq, Generic)
```

**Step 2: Update toDomainMoney to take currency**

Replace:
```haskell
toDomainMoney :: Double -> Either Text Money
toDomainMoney d = mkMoney (toRational d)
```

With:
```haskell
toDomainMoney :: Currency -> Double -> Either Text Money
toDomainMoney cur d = mkMoney cur (toRational d)
```

Add `Currency (..)` and `parseCurrency` to the import from Domain.Core.Types.

**Step 3: Update fromDomainMoney**

No change needed — `unMoney` still extracts the Rational amount.

**Step 4: Update toCreateAccountCommand**

Replace:
```haskell
toCreateAccountCommand :: UserId -> AccountType -> CreateAccountRequest -> Either Text CreateAccount
toCreateAccountCommand createdBy accountType CreateAccountRequest {..} = do
  when (T.null name) $
    Left "Account name cannot be empty"
  domainBalance <- toDomainMoney initialBalance
  return $ CreateAccount name domainBalance createdBy accountType
  where
    when :: Bool -> Either Text () -> Either Text ()
    when True action = action
    when False _ = Right ()
```

With:
```haskell
toCreateAccountCommand :: UserId -> AccountType -> CreateAccountRequest -> Either Text CreateAccount
toCreateAccountCommand createdBy accountType CreateAccountRequest {..} = do
  when (T.null name) $
    Left "Account name cannot be empty"
  cur <- parseCurrency currency
  domainBalance <- toDomainMoney cur initialBalance
  return $ CreateAccount name domainBalance createdBy accountType
  where
    when :: Bool -> Either Text () -> Either Text ()
    when True action = action
    when False _ = Right ()
```

**Step 5: Add parseCurrency helper**

Add a `parseCurrency` function (either in Web.Types or export from Domain.Core.Types):

```haskell
parseCurrency :: Text -> Either Text Currency
parseCurrency t = case T.toUpper t of
  "UAH" -> Right UAH
  "USD" -> Right USD
  "EUR" -> Right EUR
  "GBP" -> Right GBP
  _ -> Left $ "Unknown currency: " <> t
```

**Step 6: Update AccountResponse to include currency**

Replace:
```haskell
data AccountResponse
  = AccountResponse
  { id :: UUID,
    name :: Text,
    balance :: Double,
    version :: Int
  }
  deriving (Show, Eq, Generic)
```

With:
```haskell
data AccountResponse
  = AccountResponse
  { id :: UUID,
    name :: Text,
    balance :: Double,
    currency :: Text,
    version :: Int
  }
  deriving (Show, Eq, Generic)
```

**Step 7: Update fromAccountData to include currency**

Replace:
```haskell
fromAccountData :: AccountId -> AccountData -> AccountResponse
fromAccountData accountId AccountData {..} =
  AccountResponse
    { id = unAccountId accountId,
      name = name,
      balance = fromDomainMoney balance,
      version = version
    }
```

With:
```haskell
fromAccountData :: AccountId -> AccountData -> AccountResponse
fromAccountData accountId AccountData {..} =
  AccountResponse
    { id = unAccountId accountId,
      name = name,
      balance = fromDomainMoney balance,
      currency = currencyToText (moneyCurrency balance),
      version = version
    }
```

Add `currencyToText` helper:
```haskell
currencyToText :: Currency -> Text
currencyToText UAH = "UAH"
currencyToText USD = "USD"
currencyToText EUR = "EUR"
currencyToText GBP = "GBP"
```

**Step 8: Update TransferRequest and transfer-related DTOs — add currency to amount fields**

The IncomeRequest, ExpenseRequest, and InternalTransferRequest all have `amount :: Double`. These transfers should work with the account's currency, so we need a `currency` field on each:

Replace each request DTO to add a `currency :: Text` field.

For `IncomeRequest`:
```haskell
data IncomeRequest
  = IncomeRequest
  { accountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)
```

Similarly for `ExpenseRequest` and `InternalTransferRequest` and `TransferRequest`.

**Step 9: Update toInitiateTransferCommand and similar conversion functions**

These will need to parse the currency and use `toDomainMoney cur amount` instead of `toDomainMoney amount`.

**Step 10: Commit**

```bash
git add src/Web/Types.hs
git commit -m "feat: update Web DTOs for multi-currency support"
```

---

### Task 6: Fix remaining compilation errors in Infrastructure and Application layers

**Files:**
- Modify: Any remaining files that use `mkMoney`, `unsafeMoney`, `addMoney`, `subtractMoneyAllowNegative`

**Step 1: Search for all usages**

Run: `grep -rn "mkMoney\|unsafeMoney\|addMoney\|subtractMoneyAllowNegative\|unsafeMoney\|unMoney" src/`

Fix each call site:
- `mkMoney n` → `mkMoney UAH n` (or appropriate currency)
- `unsafeMoney n` → `unsafeMoney UAH n` (or appropriate currency)
- `addMoney a b` → use `Either` result
- `subtractMoneyAllowNegative a b` → use `Either` result

**Step 2: Fix all compilation errors**

Run: `just build`
Fix remaining issues iteratively.

**Step 3: Commit**

```bash
git add -A
git commit -m "fix: update all Money call sites for currency-aware API"
```

---

### Task 7: Update Testkit (Helpers and Generators)

**Files:**
- Modify: `test/Testkit/Helpers.hs`
- Modify: `test/Testkit/Generators.hs`

**Step 1: Update mockMoney in Helpers.hs**

Replace:
```haskell
mockMoney :: Rational -> Money
mockMoney = unsafeMoney
```

With:
```haskell
mockMoney :: Currency -> Rational -> Money
mockMoney = unsafeMoney
```

Alternatively, provide a convenience default:
```haskell
-- | Create a Money value without validation in the default currency (UAH).
mockMoney :: Rational -> Money
mockMoney = unsafeMoney UAH

-- | Create a Money value without validation in a specific currency.
mockMoneyWith :: Currency -> Rational -> Money
mockMoneyWith = unsafeMoney
```

The second approach minimizes changes in existing tests. Add `Currency (..)` to the import.

**Step 2: Update generators in Generators.hs**

Replace `genMoney`:
```haskell
genMoney :: Gen Money
genMoney = do
  cents <- choose (0, 100000000) :: Gen Integer
  let amount = fromInteger cents % 100
  pure $ unsafeMoney amount
```

With:
```haskell
genCurrency :: Gen Currency
genCurrency = elements [UAH, USD, EUR, GBP]

genMoney :: Gen Money
genMoney = do
  cents <- choose (0, 100000000) :: Gen Integer
  let amt = fromInteger cents % 100
  cur <- genCurrency
  pure $ unsafeMoney cur amt
```

Replace `genPositiveMoney`:
```haskell
genPositiveMoney :: Gen Money
genPositiveMoney = do
  cents <- choose (1, 100000000) :: Gen Integer
  let amt = fromInteger cents % 100
  cur <- genCurrency
  pure $ unsafeMoney cur amt
```

Add:
```haskell
-- | Generate a Money value in a specific currency.
genMoneyIn :: Currency -> Gen Money
genMoneyIn cur = do
  cents <- choose (0, 100000000) :: Gen Integer
  let amt = fromInteger cents % 100
  pure $ unsafeMoney cur amt

-- | Generate a positive Money value in a specific currency.
genPositiveMoneyIn :: Currency -> Gen Money
genPositiveMoneyIn cur = do
  cents <- choose (1, 100000000) :: Gen Integer
  let amt = fromInteger cents % 100
  pure $ unsafeMoney cur amt
```

Add `Arbitrary Currency`:
```haskell
instance Arbitrary Currency where
  arbitrary = genCurrency
```

Export `genCurrency`, `genMoneyIn`, `genPositiveMoneyIn`, and the `Currency` `Arbitrary` instance.

**Step 3: Commit**

```bash
git add test/Testkit/Helpers.hs test/Testkit/Generators.hs
git commit -m "feat: update test helpers and generators for multi-currency"
```

---

### Task 8: Update Domain.Core.Types unit tests

**Files:**
- Modify: `test/Domain/Core/TypesSpec.hs`

**Step 1: Update mkMoney tests**

All `mkMoney n` calls become `mkMoney UAH n` (or test both currencies).

Replace:
```haskell
        let result = mkMoney 100
```
With:
```haskell
        let result = mkMoney UAH 100
```

Similarly update all other `mkMoney` calls in the file.

**Step 2: Update addMoney tests**

`addMoney` now returns `Either`. Update assertions:

Replace:
```haskell
      let result = addMoney m1 m2
      unMoney result `shouldBe` 150
```
With:
```haskell
      let result = addMoney m1 m2
      case result of
        Right money -> unMoney money `shouldBe` 150
        Left err -> expectationFailure $ "Expected Right, got Left: " <> T.unpack err
```

Update commutativity and identity tests similarly.

**Step 3: Add currency mismatch tests**

Add new test cases:
```haskell
    context "Given different currencies" $ do
      it "Then addMoney returns error" $ do
        let m1 = mockMoney 100  -- UAH
        let m2 = mockMoneyWith USD 50
        let result = addMoney m1 m2
        shouldBeLeft result

      it "Then subtractMoney returns error" $ do
        let m1 = mockMoney 100  -- UAH
        let m2 = mockMoneyWith USD 50
        let result = subtractMoney m1 m2
        shouldBeLeft result
```

**Step 4: Add Currency JSON roundtrip test**

```haskell
currencySpec :: Spec
currencySpec = describe "Currency" $ do
  it "roundtrips through JSON" $ do
    forM_ [UAH, USD, EUR, GBP] $ \cur ->
      decode (encode cur) `shouldBe` Just cur
```

**Step 5: Commit**

```bash
git add test/Domain/Core/TypesSpec.hs
git commit -m "test: update Money unit tests for multi-currency"
```

---

### Task 9: Update Domain.Core.Types property tests

**Files:**
- Modify: `test/Domain/Core/TypesPropertySpec.hs`

**Step 1: Update Money property tests**

The key change: `addMoney` returns `Either` now, and properties should test same-currency operations.

For commutativity, generate two Money values with the same currency:
```haskell
    it "Then addition is commutative for same currency"
      $ property
      $ \(cur :: Currency) ->
        forAll (genMoneyIn cur) $ \m1 ->
          forAll (genMoneyIn cur) $ \m2 ->
            addMoney m1 m2 === addMoney m2 m1
```

Similarly for associativity and identity.

Add new properties:
```haskell
    it "Then addition fails for different currencies"
      $ property
      $ \(c1 :: Currency) (c2 :: Currency) ->
        c1 /= c2 ==>
          forAll (genMoneyIn c1) $ \m1 ->
            forAll (genMoneyIn c2) $ \m2 ->
              case addMoney m1 m2 of
                Left _ -> True
                Right _ -> False
```

**Step 2: Update subtraction properties**

Same pattern — test with same currency, add mismatch property.

**Step 3: Add Currency properties**

```haskell
currencyPropertySpec :: Spec
currencyPropertySpec = describe "Currency Properties" $ do
  it "roundtrips through JSON"
    $ property
    $ \(c :: Currency) ->
      decode (encode c) === Just c
```

**Step 4: Commit**

```bash
git add test/Domain/Core/TypesPropertySpec.hs
git commit -m "test: update Money property tests for multi-currency"
```

---

### Task 10: Update Account CommandHandler tests

**Files:**
- Modify: `test/Domain/Account/CommandHandlerSpec.hs`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs`

**Step 1: Update all mockMoney calls**

All `mockMoney n` calls stay the same (defaults to UAH). No changes needed if Task 7 kept the convenience default.

**Step 2: Add CurrencyMismatch unit tests in CommandHandlerSpec**

Add a new section for currency tests:
```haskell
currencyMismatchSpec :: Spec
currencyMismatchSpec = describe "Currency Mismatch" $ do
  context "Given UAH account" $ do
    describe "When debiting with USD amount" $ do
      it "Then rejects with CurrencyMismatch" $ do
        let account = regularAccountWithOwner testOwnerId  -- UAH balance
        let command =
              DebitAccountAccountCommand
                $ DebitAccount
                  { amount = mockMoneyWith USD 100,
                    transactionId = mockTransactionId (read "44444444-4444-4444-4444-444444444444"),
                    reason = "Cross-currency debit"
                  }
        let result = handleAccountCommand account command
        result `shouldBe` Left CurrencyMismatch

    describe "When crediting with EUR amount" $ do
      it "Then rejects with CurrencyMismatch" $ do
        let account = regularAccountWithOwner testOwnerId  -- UAH balance
        let command =
              CreditAccountAccountCommand
                $ CreditAccount
                  { amount = mockMoneyWith EUR 100,
                    transactionId = mockTransactionId (read "44444444-4444-4444-4444-444444444444"),
                    reason = "Cross-currency credit"
                  }
        let result = handleAccountCommand account command
        result `shouldBe` Left CurrencyMismatch
```

Add `currencyMismatchSpec` to the spec list and import `mockMoneyWith` and `Currency(..)`.

**Step 3: Update property tests**

In `CommandHandlerPropertySpec.hs`, update `createAccountWithOwner` and all `mockMoney` calls. Add a property:
```haskell
    it "Then rejects debit with different currency"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) (c1 :: Currency) (c2 :: Currency) ->
        c1 /= c2 ==>
          forAll (genMoneyIn c1) $ \balance ->
            forAll (genPositiveMoneyIn c2) $ \amt ->
              let account = createAccountWithOwner "Test" balance ownerId RegularAccount
                  command = DebitAccountAccountCommand $ DebitAccount amt txId "Cross-currency"
                  result = handleAccountCommand account command
               in result === Left CurrencyMismatch
```

**Step 4: Commit**

```bash
git add test/Domain/Account/CommandHandlerSpec.hs test/Domain/Account/CommandHandlerPropertySpec.hs
git commit -m "test: add currency mismatch tests for account command handler"
```

---

### Task 11: Update Transaction CommandHandler tests

**Files:**
- Modify: `test/Domain/Transaction/CommandHandlerSpec.hs`
- Modify: `test/Domain/Transaction/CommandHandlerPropertySpec.hs`

**Step 1: Update all mockMoney calls**

Same as Task 10 — `mockMoney n` defaults to UAH, so most calls don't change.

**Step 2: Verify all TransferInitiated constructions work**

The `TransferInitiated` event carries `Money` — just ensure all test constructions use same-currency amounts.

**Step 3: Commit**

```bash
git add test/Domain/Transaction/CommandHandlerSpec.hs test/Domain/Transaction/CommandHandlerPropertySpec.hs
git commit -m "test: update transaction tests for currency-aware Money"
```

---

### Task 12: Update TransferManager tests

**Files:**
- Modify: `test/Application/ProcessManagers/TransferManagerSpec.hs`
- Modify: `test/Application/ProcessManagers/TransferManagerPropertySpec.hs`

**Step 1: Update all unsafeMoney calls**

Replace `unsafeMoney n` with `unsafeMoney UAH n` in both test files.

**Step 2: Update property test generators**

In `TransferManagerPropertySpec.hs`, update `genPositiveAmount` usage:
```haskell
  pure $ unsafeMoney UAH amt
```

**Step 3: Commit**

```bash
git add test/Application/ProcessManagers/TransferManagerSpec.hs test/Application/ProcessManagers/TransferManagerPropertySpec.hs
git commit -m "test: update transfer manager tests for currency-aware Money"
```

---

### Task 13: Update Integration tests

**Files:**
- Modify: `test/Integration/TransferWorkflowSpec.hs`

**Step 1: Update all unsafeMoney calls**

Replace `unsafeMoney n` with `unsafeMoney UAH n` throughout.

**Step 2: Add cross-currency transfer failure test**

```haskell
    it "fails transfer between accounts with different currencies" $ do
      env <- createTestAppEnvWithProcessManager
      let writer = env.eventStoreWriter
          reader = env.eventStoreReader

      userUuid <- UUID.nextRandom
      uahAcctUuid <- UUID.nextRandom
      usdAcctUuid <- UUID.nextRandom

      -- Create UAH account
      _ <-
        applyAccountCommand writer reader uahAcctUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "UAH Account",
                initialBalance = unsafeMoney UAH 1000,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount
              }

      -- Create USD account
      _ <-
        applyAccountCommand writer reader usdAcctUuid
          $ CreateAccountAccountCommand
            CreateAccount
              { name = "USD Account",
                initialBalance = unsafeMoney USD 500,
                createdBy = unsafeUserId userUuid,
                accountType = RegularAccount
              }

      -- Attempt cross-currency transfer (should fail via saga compensation)
      txUuid <- initiateTransferOnly env uahAcctUuid usdAcctUuid userUuid 200 "Cross-currency"

      let txReadModel = env.transactionReadModel
      maybeTx <- getTransaction txReadModel (unsafeTransactionId txUuid)
      case maybeTx of
        Nothing -> expectationFailure "Transaction not found"
        Just txData ->
          txData.status `shouldBe` Failed "Currency mismatch"
```

Note: The exact failure message depends on how the account command handler error propagates through the saga compensation. The `RejectionReason` text should contain "Currency mismatch" — verify and adjust the assertion as needed.

**Step 3: Commit**

```bash
git add test/Integration/TransferWorkflowSpec.hs
git commit -m "test: add cross-currency transfer failure integration test"
```

---

### Task 14: Update remaining service and handler files

**Files:**
- Modify: Any remaining files found via `just build` that have compilation errors

**Step 1: Build and fix**

Run: `just build`

Fix any remaining compilation errors iteratively. Common patterns:
- `mkMoney n` → `mkMoney UAH n` (in `Main.hs`, service files, etc.)
- `unsafeMoney n` → `unsafeMoney UAH n`
- `addMoney a b` result now `Either` — handle appropriately
- `fromDomainMoney` — unchanged (still uses `unMoney`)

**Step 2: Run all tests**

Run: `just test`
Expected: All tests pass.

**Step 3: Format and lint**

Run: `just check`

**Step 4: Commit**

```bash
git add -A
git commit -m "fix: resolve remaining compilation issues for multi-currency"
```

---

### Task 15: Update Domain.Account.Errors with CurrencyMismatch variant

**Files:**
- Modify: `src/Domain/Account/Errors.hs`

**Step 1: Add CurrencyMismatch error type**

Add a new variant to the `AccountError` type in `Errors.hs`:

```haskell
  | -- | Currency mismatch between account and operation
    CurrencyMismatch
      { -- | The account involved
        currencyMismatchAccountId :: AccountId,
        -- | The account's currency
        currencyMismatchAccountCurrency :: Currency,
        -- | The operation's currency
        currencyMismatchOperationCurrency :: Currency
      }
```

Add `Currency` to the import from Domain.Core.Types.

**Step 2: Add error constructor**

```haskell
mkCurrencyMismatch :: AccountId -> Currency -> Currency -> AccountError
mkCurrencyMismatch accountId acctCur opCur =
  CurrencyMismatch
    { currencyMismatchAccountId = accountId,
      currencyMismatchAccountCurrency = acctCur,
      currencyMismatchOperationCurrency = opCur
    }
```

Export `mkCurrencyMismatch` and the `CurrencyMismatch` constructor.

**Step 3: Commit**

```bash
git add src/Domain/Account/Errors.hs
git commit -m "feat: add CurrencyMismatch to rich account error types"
```

---

### Task 16: Final verification

**Step 1: Run full build**

Run: `just build`
Expected: Clean build, no warnings.

**Step 2: Run all tests**

Run: `just test`
Expected: All tests pass.

**Step 3: Format and lint**

Run: `just check`
Expected: No formatting or lint issues.

**Step 4: Update design doc status**

Change `docs/specs/2026-03-12-multi-currency-design.md` frontmatter from `status: draft` to `status: completed`.

**Step 5: Final commit**

```bash
git add -A
git commit -m "docs: mark multi-currency design as completed"
```
