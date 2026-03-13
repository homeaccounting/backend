# Overdraft Limits Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow accounts to carry negative balances with configurable overdraft limits; clean up Money type to always allow negatives.

**Architecture:** Remove non-negative constraint from Money type (smart constructor and subtraction). Add `overdraftLimit :: Maybe Money` to Account aggregate. Overdraft checks happen only in the Account command handler during debit validation. New `SetOverdraftLimit` command/event for owner-only configuration.

**Tech Stack:** Haskell, Servant, Eventium (event sourcing), QuickCheck, Hspec

---

### Task 1: Clean up Money type — remove non-negative constraint

**Files:**
- Modify: `src/Domain/Core/Types.hs:117-225`
- Modify: `test/Domain/Core/TypesSpec.hs:37-141`
- Modify: `test/Domain/Core/TypesPropertySpec.hs:36-116`
- Modify: `test/Testkit/Generators.hs:80-118`

**Step 1: Update Money property tests for new behavior**

In `test/Domain/Core/TypesPropertySpec.hs`:

- Remove the "maintains non-negativity invariant" property (line 39-42) — Money no longer has this invariant
- Change "subtraction maintains non-negativity when valid" (lines 71-80) to test that subtraction always succeeds for same-currency:

```haskell
    it "Then subtraction always succeeds for same currency"
      $ property
      $ forAll genCurrency
      $ \cur ->
        forAll (genMoneyIn cur) $ \m1 ->
          forAll (genMoneyIn cur) $ \m2 ->
            case subtractMoney m1 m2 of
              Right result -> unMoney result === unMoney m1 - unMoney m2
              Left _ -> property False
```

- Remove "subtraction fails when insufficient funds" property (lines 82-91) — subtraction no longer fails for this reason
- Keep currency mismatch tests as-is

**Step 2: Update Money unit tests**

In `test/Domain/Core/TypesSpec.hs`:

- Change the "Given negative amount / Then rejects with error message" test (lines 64-70) to verify negative amounts are accepted:

```haskell
    context "Given negative amount" $ do
      it "Then accepts negative amount" $ do
        let result = mkMoney USD (-10)
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` (-10)
          Left _ -> expectationFailure "Expected Right"
```

- Change the "Given insufficient funds / Then returns error" subtractMoney test (lines 122-130) to verify subtraction succeeds:

```haskell
    context "Given larger subtrahend" $ do
      it "Then returns negative result" $ do
        let m1 = mockMoney 50
        let m2 = mockMoney 100
        let result = subtractMoney m1 m2
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` (-50)
          Left _ -> expectationFailure "Expected Right"
```

**Step 3: Run tests — verify they fail**

Run: `just test`
Expected: Tests fail because `mkMoney` still rejects negatives and `subtractMoney` still rejects insufficient funds.

**Step 4: Update Money type implementation**

In `src/Domain/Core/Types.hs`:

1. Update module doc comment (line 126): Change "Invariant: Money values must be non-negative" to "Money values can be negative (overdraft enforcement is at account level)"

2. Update `mkMoney` (lines 177-180): Remove the negative check:

```haskell
mkMoney :: Currency -> Rational -> Either Text Money
mkMoney cur amt = Right (Money amt cur)
```

3. Merge `subtractMoney` and `subtractMoneyAllowNegative` — make `subtractMoney` always allow negatives (lines 211-225):

```haskell
subtractMoney :: Money -> Money -> Either Text Money
subtractMoney (Money a ca) (Money b cb)
  | ca /= cb = Left $ "Currency mismatch: cannot subtract " <> T.pack (show cb) <> " from " <> T.pack (show ca)
  | otherwise = Right (Money (a - b) ca)
```

4. Remove `subtractMoneyAllowNegative` entirely (lines 217-225)

5. Remove `subtractMoneyAllowNegative` from module exports (line 25)

6. Update `FromJSON Money` instance (lines 160-166) — `mkMoney` now always succeeds, so the error case is technically unreachable but keep it for safety

7. Update mathematical properties in doc comment (lines 129-133): Remove "Non-negative: forall m. unMoney m >= 0"

**Step 5: Fix all compilation errors from removing `subtractMoneyAllowNegative`**

Search for all usages of `subtractMoneyAllowNegative` and replace with `subtractMoney`:

- `src/Domain/Account/Projection.hs:68` — import: change `subtractMoneyAllowNegative` to `subtractMoney`
- `src/Domain/Account/Projection.hs:249` — usage: change `subtractMoneyAllowNegative` to `subtractMoney`
- `src/Application/ReadModels/Account.hs:75` — import: change `subtractMoneyAllowNegative` to `subtractMoney`
- `src/Application/ReadModels/Account.hs:273` — usage: change `subtractMoneyAllowNegative` to `subtractMoney`

**Step 6: Update generators to include negative Money**

In `test/Testkit/Generators.hs`, update `genMoneyIn` (lines 99-105) to generate both positive and negative amounts:

```haskell
genMoneyIn :: Currency -> Gen Money
genMoneyIn cur = do
  cents <- choose (-100000000, 100000000) :: Gen Integer
  let amt = fromInteger cents % 100
  pure $ unsafeMoney cur amt
```

Keep `genPositiveMoneyIn` unchanged (it's still useful for amounts that must be positive, like transfer amounts).

Also update `genMoney` doc comment (line 76-79) to remove "non-negative" language.

**Step 7: Run tests — verify they pass**

Run: `just test`
Expected: All tests pass.

**Step 8: Run format and lint**

Run: `just check`
Expected: No issues.

**Step 9: Commit**

```bash
git add src/Domain/Core/Types.hs src/Domain/Account/Projection.hs src/Application/ReadModels/Account.hs test/Domain/Core/TypesSpec.hs test/Domain/Core/TypesPropertySpec.hs test/Testkit/Generators.hs
git commit -m "refactor: remove non-negative constraint from Money type

Money values can now be negative. Overdraft enforcement will be
at the account level, not the type level. Merged subtractMoney
and subtractMoneyAllowNegative into a single function."
```

---

### Task 2: Add `overdraftLimit` field to Account aggregate

**Files:**
- Modify: `src/Domain/Account/Projection.hs:103-140`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs:135-140`
- Modify: `test/Domain/Account/CommandHandlerSpec.hs:70-83`

**Step 1: Write tests for overdraftLimit in account state**

In `test/Domain/Account/CommandHandlerPropertySpec.hs`, update the invariant test at line 135-140:

```haskell
    it "Then Regular account defaults to Just zero overdraft limit"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId RegularAccount
           in case account ^. #overdraftLimit of
                Just limit -> unMoney limit === 0
                Nothing -> property False

    it "Then External account defaults to Nothing overdraft limit"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId ExternalAccount
           in account ^. #overdraftLimit === Nothing
```

In `test/Domain/Account/CommandHandlerSpec.hs`, add checks in the existing creation tests:

- In "Then created account has correct state" test (around line 139-146), add:
```haskell
            newAccount ^. #overdraftLimit `shouldBe` Just (mockMoney 0)
```

- In "Then emits AccountCreated event with ExternalAccount type" test (around line 170-190), add after the account is created:
```haskell
            let newAccount = applyEvents events
            newAccount ^. #overdraftLimit `shouldBe` Nothing
```

**Step 2: Run tests — verify they fail**

Run: `just test`
Expected: Fail — Account type doesn't have `overdraftLimit` field.

**Step 3: Add overdraftLimit field to Account**

In `src/Domain/Account/Projection.hs`:

1. Add import for `mkMoney` and `unsafeMoney` from `Domain.Core.Types` (around line 64)

2. Add field to Account data type (after line 113):
```haskell
    -- | Overdraft limit. Nothing = unlimited, Just limit = max negative balance
    overdraftLimit :: Maybe Money
```

3. Update `accountDefault` (lines 130-140) — add `overdraftLimit = Just` for the default:
```haskell
accountDefault = case mkMoney USD 0 of
  Right m ->
    Account
      { balance = m,
        name = "",
        createdBy = unsafeUserId UUID.nil,
        accountType = RegularAccount,
        accessList = [],
        overdraftLimit = Just m
      }
  Left _ -> error "accountDefault: mkMoney 0 should never fail"
```

4. Update `handleAccountEvent` for `AccountCreated` (lines 218-232) — set overdraftLimit based on account type:
```haskell
handleAccountEvent account (AccountCreatedAccountEvent created) =
  let ownerId = created.by
      limit = case created.accountType of
        RegularAccount -> Just (unsafeMoney (moneyCurrency created.initialBalance) 0)
        ExternalAccount -> Nothing
   in account
        & #name .~ created.name
        & #balance .~ created.initialBalance
        & #createdBy .~ ownerId
        & #accountType .~ created.accountType
        & #accessList .~ [AccountAccess ownerId Owner]
        & #overdraftLimit .~ limit
```

Add `unsafeMoney` and `moneyCurrency` to the import from Domain.Core.Types.

**Step 4: Run tests — verify they pass**

Run: `just test`
Expected: All tests pass.

**Step 5: Run format and lint**

Run: `just check`

**Step 6: Commit**

```bash
git add src/Domain/Account/Projection.hs test/Domain/Account/CommandHandlerPropertySpec.hs test/Domain/Account/CommandHandlerSpec.hs
git commit -m "feat: add overdraftLimit field to Account aggregate

Regular accounts default to Just 0 (no overdraft allowed).
External accounts default to Nothing (unlimited)."
```

---

### Task 3: Update debit validation to use overdraftLimit

**Files:**
- Modify: `src/Domain/Account/CommandHandler.hs:180-204`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs:279-289`
- Modify: `test/Domain/Account/CommandHandlerSpec.hs:469-498`

**Step 1: Write property tests for overdraft debit validation**

In `test/Domain/Account/CommandHandlerPropertySpec.hs`, add new properties in the `businessRuleSpec` section:

```haskell
  describe "Overdraft enforcement" $ do
    it "Then debit succeeds when within overdraft limit"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn USD) $ \debitAmt ->
          -- Create account with balance 0 and overdraft limit >= debit amount
          let account =
                (createAccountWithOwner "Test" (mockMoney 0) ownerId RegularAccount)
                  {overdraftLimit = Just debitAmt}
              command =
                DebitAccountAccountCommand
                  $ DebitAccount debitAmt txId "Transfer"
              result = handleAccountCommand account command
           in result =/= Left InsufficientFunds

    it "Then debit fails when exceeding overdraft limit"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn USD) $ \debitAmt ->
          unMoney debitAmt > 0 ==>
            let account = createAccountWithOwner "Test" (mockMoney 0) ownerId RegularAccount
                -- Default overdraft is 0, so any positive debit on zero balance fails
                command =
                  DebitAccountAccountCommand
                    $ DebitAccount debitAmt txId "Transfer"
                result = handleAccountCommand account command
             in result === Left InsufficientFunds

    it "Then debit always succeeds with Nothing overdraft limit"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn USD) $ \debitAmt ->
          let account =
                (createAccountWithOwner "Test" (mockMoney 0) ownerId RegularAccount)
                  {overdraftLimit = Nothing}
              command =
                DebitAccountAccountCommand
                  $ DebitAccount debitAmt txId "Transfer"
              result = handleAccountCommand account command
           in result =/= Left InsufficientFunds
```

**Step 2: Run tests — verify they fail**

Run: `just test`
Expected: Fail — CommandHandler still uses old External/Regular branching.

**Step 3: Update CommandHandler debit validation**

In `src/Domain/Account/CommandHandler.hs`, replace the debit handling (lines 180-204):

1. Update import: add `unMoney` from `Domain.Core.Types`, add `Optics ((^.))` already imported

2. Replace the debit handler:
```haskell
-- Handle DebitAccount command (internal, issued by TransferManager saga)
handleAccountCommand account (DebitAccountAccountCommand DebitAccount {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | moneyCurrency amount /= moneyCurrency (account ^. #balance) = Left CurrencyMismatch
  | otherwise =
      case account ^. #overdraftLimit of
        Nothing ->
          -- Unlimited overdraft: always succeeds
          Right
            [ AccountDebitedAccountEvent
                AccountDebited
                  { amount = amount,
                    transactionId = transactionId,
                    reason = reason
                  }
            ]
        Just limit ->
          -- Check: balance - debitAmount >= -limit
          let newBalance = unMoney (account ^. #balance) - unMoney amount
              minAllowed = negate (unMoney limit)
           in if newBalance >= minAllowed
                then
                  Right
                    [ AccountDebitedAccountEvent
                        AccountDebited
                          { amount = amount,
                            transactionId = transactionId,
                            reason = reason
                          }
                    ]
                else Left InsufficientFunds
```

3. Remove `subtractMoney` from imports (line 53) — no longer needed in CommandHandler. Keep `moneyCurrency` and add `unMoney`.

**Step 4: Run tests — verify they pass**

Run: `just test`
Expected: All tests pass.

**Step 5: Run format and lint**

Run: `just check`

**Step 6: Commit**

```bash
git add src/Domain/Account/CommandHandler.hs test/Domain/Account/CommandHandlerPropertySpec.hs test/Domain/Account/CommandHandlerSpec.hs
git commit -m "feat: use overdraftLimit for debit validation

Replace External/Regular account type branching with unified
overdraft limit check. Nothing = unlimited, Just limit = enforce."
```

---

### Task 4: Add SetOverdraftLimit command, event, and handler

**Files:**
- Modify: `src/Domain/Account/Commands.hs`
- Modify: `src/Domain/Account/Events.hs`
- Modify: `src/Domain/Account/CommandHandler.hs`
- Modify: `src/Domain/Account/Projection.hs`
- Modify: `src/Domain/Account.hs`
- Modify: `src/Domain/Models.hs` (if needed — TH should auto-include)
- Modify: `test/Domain/Account/CommandHandlerSpec.hs`
- Modify: `test/Domain/Account/CommandHandlerPropertySpec.hs`

**Step 1: Write tests for SetOverdraftLimit**

In `test/Domain/Account/CommandHandlerSpec.hs`, add a new section:

```haskell
setOverdraftLimitSpec :: Spec
setOverdraftLimitSpec = describe "SetOverdraftLimit Command" $ do
  let testTransactionId = mockTransactionId (read "44444444-4444-4444-4444-444444444444")

  context "Given regular account with owner" $ do
    describe "When owner sets overdraft limit" $ do
      it "Then emits OverdraftLimitSet event" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoney 500),
                    setBy = testOwnerId
                  }
        let result = handleAccountCommand account command
        case result of
          Right events -> do
            length events `shouldBe` 1
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then overdraft limit is applied to account state" $ do
        let baseEvents =
              [ AccountCreatedAccountEvent
                  $ AccountCreated "Test Account" (mockMoney 1000) testOwnerId RegularAccount
              ]
        let account = applyEvents baseEvents
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoney 500),
                    setBy = testOwnerId
                  }
        case handleAccountCommand account command of
          Right events -> do
            let newAccount = applyEvents (baseEvents <> events)
            newAccount ^. #overdraftLimit `shouldBe` Just (mockMoney 500)
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then can set to Nothing for unlimited overdraft" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Nothing,
                    setBy = testOwnerId
                  }
        let result = handleAccountCommand account command
        shouldBeRight result

    describe "When non-owner tries to set overdraft limit" $ do
      it "Then rejects command" $ do
        let account = accountWithSharedAccess testOwnerId testEditorId Editor
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoney 500),
                    setBy = testEditorId
                  }
        let result = handleAccountCommand account command
        result `shouldSatisfy` isLeft

    describe "When setting overdraft with currency mismatch" $ do
      it "Then rejects command" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoneyWith EUR 500),
                    setBy = testOwnerId
                  }
        let result = handleAccountCommand account command
        result `shouldBe` Left CurrencyMismatch
```

Don't forget to add `setOverdraftLimitSpec` to the `spec` function and add the import for `SetOverdraftLimit (..)` and `OverdraftLimitSet (..)`.

In `test/Domain/Account/CommandHandlerPropertySpec.hs`, add:

```haskell
    it "Then only owner can set overdraft limit"
      $ property
      $ \(ownerId :: UserId) (nonOwnerId :: UserId) ->
        ownerId /= nonOwnerId ==>
          let account =
                applyEvents
                  [ AccountCreatedAccountEvent
                      $ AccountCreated "Test" (mockMoney 1000) ownerId RegularAccount,
                    AccountAccessGrantedAccountEvent
                      $ AccountAccessGranted nonOwnerId Editor ownerId
                  ]
              command =
                SetOverdraftLimitAccountCommand
                  $ SetOverdraftLimit
                    { overdraftLimit = Just (mockMoney 500),
                      setBy = nonOwnerId
                    }
              result = handleAccountCommand account command
           in isLeft result
```

**Step 2: Run tests — verify they fail**

Run: `just test`
Expected: Compilation fails — `SetOverdraftLimit` and related types don't exist yet.

**Step 3: Add SetOverdraftLimit command**

In `src/Domain/Account/Commands.hs`:

1. Add to `accountCommands` list:
```haskell
    ''SetOverdraftLimit
```

2. Add command type:
```haskell
-- | Command to set the overdraft limit on an account.
--
-- Overdraft limit controls the maximum negative balance allowed.
-- Nothing means unlimited overdraft (no balance check on debit).
-- Just limit means balance - debitAmount >= -limit must hold.
--
-- Business Rules:
--   - Only Owner can set overdraft limit
--   - If Just limit, currency must match account currency
--   - Setting a limit below current negative balance is allowed
data SetOverdraftLimit = SetOverdraftLimit
  { -- | New overdraft limit (Nothing = unlimited)
    overdraftLimit :: Maybe Money,
    -- | User setting the limit (must be Owner)
    setBy :: UserId
  }
  deriving (Show, Eq)
```

3. Add TH JSON derivation:
```haskell
deriveJSON defaultOptions ''SetOverdraftLimit
```

4. Add to module exports:
```haskell
    SetOverdraftLimit (..),
```

**Step 4: Add OverdraftLimitSet event**

In `src/Domain/Account/Events.hs`:

1. Add to `accountEvents` list:
```haskell
    ''OverdraftLimitSet
```

2. Add event type:
```haskell
-- | Event emitted when an account's overdraft limit is changed.
data OverdraftLimitSet = OverdraftLimitSet
  { -- | New overdraft limit (Nothing = unlimited)
    overdraftLimit :: Maybe Money,
    -- | User who set the limit (Owner)
    by :: UserId
  }
  deriving (Show, Eq)
```

3. Add TH JSON derivation:
```haskell
deriveJSON defaultOptions ''OverdraftLimitSet
```

4. Add to module exports:
```haskell
    OverdraftLimitSet (..),
```

**Step 5: Add command handler logic**

In `src/Domain/Account/CommandHandler.hs`, add a new pattern match before the CreditAccount handler:

```haskell
-- Handle SetOverdraftLimit command
handleAccountCommand account (SetOverdraftLimitAccountCommand SetOverdraftLimit {..})
  | T.null (account ^. #name) = Left AccountDoesNotExist
  | not (isOwner setBy account) = Left NotAccountOwner
  | otherwise =
      case overdraftLimit of
        Nothing ->
          Right
            [ OverdraftLimitSetAccountEvent
                OverdraftLimitSet
                  { overdraftLimit = overdraftLimit,
                    by = setBy
                  }
            ]
        Just limit
          | moneyCurrency limit /= moneyCurrency (account ^. #balance) -> Left CurrencyMismatch
          | otherwise ->
              Right
                [ OverdraftLimitSetAccountEvent
                    OverdraftLimitSet
                      { overdraftLimit = overdraftLimit,
                        by = setBy
                      }
                ]
```

Add `OverdraftLimitSet` to the import from `Domain.Account.Events` and `SetOverdraftLimit` to the import from `Domain.Account.Commands`.

**Step 6: Add projection handler**

In `src/Domain/Account/Projection.hs`:

1. Add `OverdraftLimitSet (..)` to import from `Domain.Account.Events`

2. Add event handler after the AccountCredited handler:
```haskell
handleAccountEvent account (OverdraftLimitSetAccountEvent OverdraftLimitSet {..}) =
  account & #overdraftLimit .~ overdraftLimit
```

**Step 7: Update Domain.Account re-exports**

In `src/Domain/Account.hs`, add `OverdraftLimitSet (..)` to the Events exports:
```haskell
    OverdraftLimitSet (..),
```

**Step 8: Run tests — verify they pass**

Run: `just test`
Expected: All tests pass.

**Step 9: Run format and lint**

Run: `just check`

**Step 10: Commit**

```bash
git add src/Domain/Account/Commands.hs src/Domain/Account/Events.hs src/Domain/Account/CommandHandler.hs src/Domain/Account/Projection.hs src/Domain/Account.hs test/Domain/Account/CommandHandlerSpec.hs test/Domain/Account/CommandHandlerPropertySpec.hs
git commit -m "feat: add SetOverdraftLimit command and OverdraftLimitSet event

Owner can set overdraft limit per account. Nothing = unlimited,
Just limit = enforce balance - debit >= -limit on future debits."
```

---

### Task 5: Add API endpoint for SetOverdraftLimit

**Files:**
- Modify: `src/Web/API/AccountAPI.hs`
- Modify: `src/Application/Services/AccountService.hs`

**Step 1: Add service function**

In `src/Application/Services/AccountService.hs`:

1. Add to module exports: `setOverdraftLimit`

2. Add imports for `SetOverdraftLimit (..)` from `Domain.Account.Commands` and `SetOverdraftLimitAccountCommand` from `Domain.Account.CommandHandler`

3. Add service function:

```haskell
-- | Set the overdraft limit on an account.
--
-- Orchestrates:
--   1. Validate account exists and user is Owner
--   2. Issue SetOverdraftLimit command
setOverdraftLimit ::
  UserId ->
  UUID ->
  Maybe Money ->
  AppM (Either DomainError ())
setOverdraftLimit requestingUserId accountUuid newLimit = do
  logInfo $ "Setting overdraft limit: " <> displayShow accountUuid

  case mkAccountId accountUuid of
    Left _err -> return $ Left $ NotFound "Account" (tshow accountUuid)
    Right _accountId -> do
      let setLimitCmd =
            SetOverdraftLimitAccountCommand
              SetOverdraftLimit
                { overdraftLimit = newLimit,
                  setBy = requestingUserId
                }

      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      result <- liftIO $ applyAccountCommand writer reader accountUuid setLimitCmd
      case result of
        Left err -> do
          logError $ "Set overdraft limit rejected: " <> displayShow err
          return $ Left $ AccountError "Set overdraft limit rejected by domain"
        Right _ -> do
          logInfo "Overdraft limit set successfully"
          return $ Right ()
```

**Step 2: Add API endpoint**

In `src/Web/API/AccountAPI.hs`:

1. Add request type:
```haskell
-- | Set overdraft limit request.
data SetOverdraftLimitRequest = SetOverdraftLimitRequest
  { overdraftLimit :: Maybe Double,
    currency :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetOverdraftLimitRequest

instance FromJSON SetOverdraftLimitRequest
```

2. Add endpoint to `AccountAPI` type:
```haskell
    -- PUT /api/accounts/:id/overdraft-limit - Set overdraft limit (requires auth, owner only)
    :<|> AuthProtect "jwt"
      :> "api"
      :> "accounts"
      :> Capture "id" UUID
      :> "overdraft-limit"
      :> ReqBody '[JSON] SetOverdraftLimitRequest
      :> Put '[JSON] NoContent
```

3. Add handler:
```haskell
-- | Handler for PUT /api/accounts/:id/overdraft-limit - Set overdraft limit.
setOverdraftLimitHandler :: AuthenticatedUser -> UUID -> SetOverdraftLimitRequest -> AppM NoContent
setOverdraftLimitHandler user accountUuid SetOverdraftLimitRequest {..} = do
  let userId = user.userId

  -- Convert request to domain types
  domainLimit <- case overdraftLimit of
    Nothing -> return Nothing
    Just amt -> do
      let curText = fromMaybe "USD" currency
      case parseCurrency curText of
        Left err -> throwDomainError $ ValidationErr $ mkValidationError "currency" err curText
        Right cur ->
          case mkMoney cur (toRational amt) of
            Left err -> throwDomainError $ ValidationErr $ mkValidationError "overdraftLimit" err (tshow amt)
            Right money -> return (Just money)

  result <- AccountService.setOverdraftLimit userId accountUuid domainLimit
  case result of
    Right () -> return NoContent
    Left err -> throwDomainError err
```

4. Add to `accountServer`:
```haskell
accountServer =
  createAccountHandler
    :<|> getAccountHandler
    :<|> listAccountsHandler
    :<|> shareAccountHandler
    :<|> revokeAccountAccessHandler
    :<|> setOverdraftLimitHandler
```

5. Add necessary imports: `parseCurrency`, `mkMoney` from `Domain.Core.Types`, `tshow` usage

**Step 3: Run tests — verify compilation**

Run: `just build`
Expected: Compiles successfully.

**Step 4: Run format and lint**

Run: `just check`

**Step 5: Commit**

```bash
git add src/Web/API/AccountAPI.hs src/Application/Services/AccountService.hs
git commit -m "feat: add PUT /api/accounts/:id/overdraft-limit endpoint

Owner-only endpoint to set overdraft limit. Accepts optional
amount (null = unlimited) with currency validation."
```

---

### Task 6: Update AccountData read model and response DTOs

**Files:**
- Modify: `src/Application/ReadModels/Account.hs:97-111`
- Modify: `src/Web/Types.hs:169-177`

**Step 1: Add overdraftLimit to AccountData**

In `src/Application/ReadModels/Account.hs`:

1. Add field to `AccountData` (after line 107):
```haskell
    -- | Overdraft limit (Nothing = unlimited)
    overdraftLimit :: Maybe Money,
```

2. Update `processEvent` for `AccountCreatedEvent` (around line 220-235) — set initial overdraftLimit:
```haskell
              let initialLimit = case evt.accountType of
                    RegularAccount -> Just (unsafeMoney (moneyCurrency evt.initialBalance) 0)
                    ExternalAccount -> Nothing
```
And include `overdraftLimit = initialLimit` in the `AccountData` constructor.

3. Add import: `OverdraftLimitSet (..)` from `Domain.Account.Events`, `unsafeMoney` from `Domain.Core.Types`

4. Add `OverdraftLimitSetEvent` to `accountEvents` list in `Domain.Account.Events` — already done in Task 4.

5. Add handler for `OverdraftLimitSetEvent` in `processEvent`:
```haskell
        OverdraftLimitSetEvent evt ->
          case mkAccountIdSafe streamUuid of
            Nothing -> summaries
            Just accountId ->
              Map.adjust
                ( \summary ->
                    summary
                      { overdraftLimit = evt.overdraftLimit,
                        version = summary.version + 1
                      }
                )
                accountId
                summaries
```

Note: The `OverdraftLimitSetEvent` constructor name comes from the TH-generated `AccountingEvent` sum type in `Domain.Models`. Check the exact constructor name by examining what `constructSumType` produces — it should be `OverdraftLimitSetEvent` based on the pattern `(++ "Event")`.

**Step 2: Update AccountResponse**

In `src/Web/Types.hs`:

1. Add field to `AccountResponse` (after line 175):
```haskell
    overdraftLimit :: Maybe Double
```

2. Update `fromAccountData` (around line 562) to include:
```haskell
      overdraftLimit = fmap (fromRational . unMoney) balance_overdraft
```
where `balance_overdraft` comes from the AccountData field. Use the actual field:
```haskell
      overdraftLimit = fmap (fromRational . unMoney) overdraftLimit
```

Add `unMoney` to the import from `Domain.Core.Types` if not already there.

**Step 3: Run tests — verify compilation and tests pass**

Run: `just test`
Expected: All tests pass.

**Step 4: Run format and lint**

Run: `just check`

**Step 5: Commit**

```bash
git add src/Application/ReadModels/Account.hs src/Web/Types.hs
git commit -m "feat: add overdraftLimit to read model and API response

AccountData and AccountResponse now include overdraftLimit field."
```

---

### Task 7: Update documentation

**Files:**
- Modify: `docs/plans/2026-03-13-overdraft-limits-design.md`

**Step 1: Mark design as completed**

Change `status: completed` to `status: completed` in the frontmatter.

**Step 2: Commit**

```bash
git add docs/plans/2026-03-13-overdraft-limits-design.md
git commit -m "docs: mark overdraft limits design as completed"
```
