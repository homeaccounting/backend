# Telegram Bot Feature Parity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Bring the Telegram bot to feature parity with the Web API — account creation, selection, income, expense, and transfer flows.

**Architecture:** Wire the existing `ConversationState` state machine to drive multi-step Telegram flows. Add new states for account creation and category selection. The callback query handler dispatches on `(ConversationState, CallbackData)` to advance flows. All commands call existing application services (`AccountService`, `TransactionService`).

**Tech Stack:** Haskell, Servant (telegram-bot-api), RIO, STM (TVar for bot state)

---

### Task 1: Extend Types.hs — BotState, ConversationState, CallbackData

**Files:**
- Modify: `src/Telegram/Types.hs`

**Step 1: Add `selectedAccounts` to `BotState` and update `emptyBotState`**

Replace the current `BotState` and `emptyBotState`:

```haskell
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, TelegramId)
```

```haskell
data BotState = BotState
  { conversations :: Map TelegramId ConversationState,
    selectedAccounts :: Map TelegramId (AccountId, Text)
  }
  deriving (Show, Eq, Generic)

emptyBotState :: BotState
emptyBotState = BotState Map.empty Map.empty
```

**Step 2: Add new `ConversationState` variants**

Add these constructors to the existing `ConversationState` type:

```haskell
data ConversationState
  = -- Transfer flow (existing)
    TransferSelectSource
  | TransferSelectTarget
      { sourceAccountId :: AccountId
      }
  | TransferSelectCategory
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId
      }
  | TransferEnterAmount
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId,
        category :: Text
      }
  | TransferEnterReason
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId,
        category :: Text,
        amount :: Money
      }
  | -- Income flow
    IncomeSelectCategory
  | IncomeEnterAmount
      { category :: Text
      }
  | IncomeEnterReason
      { category :: Text,
        amount :: Money
      }
  | -- Expense flow
    ExpenseSelectCategory
  | ExpenseEnterAmount
      { category :: Text
      }
  | ExpenseEnterReason
      { category :: Text,
        amount :: Money
      }
  | -- Account creation flow
    CreateAccountEnterName
  | CreateAccountSelectCurrency
      { accountName :: Text
      }
  deriving (Show, Eq, Generic)
```

Note: Income/Expense no longer have `SelectAccount` — they use `selectedAccounts` from `BotState`. The `targetAccountId`/`sourceAccountId` fields are removed from income/expense states; the selected account is read from `BotState` at execution time.

**Step 3: Add `CategorySelect` to `CallbackData`**

```haskell
data CallbackData
  = AccountSelect AccountSelectionCallback
  | CategorySelect Text    -- callback format: "cat:<category_name>"
  | CurrencySelect Text    -- callback format: "cur:<currency_code>"
  | Cancel
  | Confirm
  deriving (Show, Eq, Generic)
```

**Step 4: Update module exports**

Add `CurrencySelect` to the export list and `CategorySelect`.

**Step 5: Build and fix any compilation errors**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

Expected: Compilation may show warnings about unused fields, but should succeed.

**Step 6: Commit**

```bash
git add src/Telegram/Types.hs
git commit -m "feat(telegram): extend types for multi-step bot flows

Add selectedAccounts to BotState, category/currency selection states,
and CategorySelect/CurrencySelect callback variants."
```

---

### Task 2: Add keyboards — currency, income categories, expense categories, internal categories

**Files:**
- Modify: `src/Telegram/Keyboards.hs`

**Step 1: Add currency keyboard**

```haskell
currencyKeyboard :: InlineKeyboard
currencyKeyboard =
  InlineKeyboard
    { rows =
        [ [InlineButton "UAH" "cur:UAH", InlineButton "USD" "cur:USD"],
          [InlineButton "EUR" "cur:EUR", InlineButton "GBP" "cur:GBP"],
          [cancelButton]
        ]
    }
```

**Step 2: Add income category keyboard**

```haskell
incomeCategoryKeyboard :: InlineKeyboard
incomeCategoryKeyboard =
  InlineKeyboard
    { rows =
        [ [InlineButton "Salary" "cat:salary", InlineButton "Freelance" "cat:freelance"],
          [InlineButton "Investment" "cat:investment", InlineButton "Gift" "cat:gift"],
          [InlineButton "Other" "cat:other"],
          [cancelButton]
        ]
    }
```

**Step 3: Add expense category keyboard**

```haskell
expenseCategoryKeyboard :: InlineKeyboard
expenseCategoryKeyboard =
  InlineKeyboard
    { rows =
        [ [InlineButton "Food" "cat:food", InlineButton "Transport" "cat:transport"],
          [InlineButton "Utilities" "cat:utilities", InlineButton "Rent" "cat:rent"],
          [InlineButton "Entertainment" "cat:entertainment", InlineButton "Other" "cat:other"],
          [cancelButton]
        ]
    }
```

**Step 4: Add internal transfer category keyboard**

```haskell
internalCategoryKeyboard :: InlineKeyboard
internalCategoryKeyboard =
  InlineKeyboard
    { rows =
        [ [InlineButton "Rebalance" "cat:rebalance", InlineButton "Savings" "cat:savings"],
          [InlineButton "Other" "cat:other"],
          [cancelButton]
        ]
    }
```

**Step 5: Update module exports**

Add `currencyKeyboard`, `incomeCategoryKeyboard`, `expenseCategoryKeyboard`, `internalCategoryKeyboard` to exports.

**Step 6: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

Expected: Success.

**Step 7: Commit**

```bash
git add src/Telegram/Keyboards.hs
git commit -m "feat(telegram): add currency and category keyboards"
```

---

### Task 3: Add keyboard-to-TG conversion helper and sendMsgWithKeyboard to Commands.hs

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Add helper to convert `InlineKeyboard` to TG markup**

Add this import and helper function:

```haskell
import Telegram.Api (answerCallback, sendTextMessage, sendMessageWithKeyboard)
import Telegram.Keyboards
  ( InlineKeyboard (..),
    InlineButton (..),
    accountSelectionKeyboard,
    currencyKeyboard,
    incomeCategoryKeyboard,
    expenseCategoryKeyboard,
    internalCategoryKeyboard,
  )
import qualified Telegram.Bot.API as TG
```

```haskell
-- | Convert our InlineKeyboard to telegram-bot-api InlineKeyboardMarkup.
toTgKeyboard :: InlineKeyboard -> TG.InlineKeyboardMarkup
toTgKeyboard kb =
  TG.InlineKeyboardMarkup
    { TG.inlineKeyboardMarkupInlineKeyboard = map (map toTgButton) kb.rows
    }

toTgButton :: InlineButton -> TG.InlineKeyboardButton
toTgButton btn =
  TG.InlineKeyboardButton
    { TG.inlineKeyboardButtonText = btn.text,
      TG.inlineKeyboardButtonCallbackData = Just btn.callbackData,
      TG.inlineKeyboardButtonUrl = Nothing,
      TG.inlineKeyboardButtonWebApp = Nothing,
      TG.inlineKeyboardButtonLoginUrl = Nothing,
      TG.inlineKeyboardButtonSwitchInlineQuery = Nothing,
      TG.inlineKeyboardButtonSwitchInlineQueryCurrentChat = Nothing,
      TG.inlineKeyboardButtonSwitchInlineQueryChosenChat = Nothing,
      TG.inlineKeyboardButtonCopy = Nothing,
      TG.inlineKeyboardButtonCallbackGame = Nothing,
      TG.inlineKeyboardButtonPay = Nothing
    }
```

Note: Check the actual `InlineKeyboardButton` record fields in the `telegram-bot-api` library. The fields above are approximate — verify against the library version used. Run `cabal repl` and `:info TG.InlineKeyboardButton` to get exact fields.

**Step 2: Add `sendMsgWithKeyboard` helper**

```haskell
-- | Send a message with inline keyboard to a chat.
sendMsgWithKeyboard :: Int64 -> Text -> InlineKeyboard -> AppM ()
sendMsgWithKeyboard chatId text keyboard = withClient $ \clientEnv -> do
  let someChatId = TG.SomeChatId (TG.ChatId (fromIntegral chatId))
      tgKeyboard = toTgKeyboard keyboard
  result <- sendMessageWithKeyboard clientEnv someChatId text tgKeyboard
  case result of
    Left err -> logError $ "Failed to send message: " <> displayShow err
    Right _ -> return ()
```

**Step 3: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

If `InlineKeyboardButton` fields don't match, run `nix develop -c cabal repl` and `:info TG.InlineKeyboardButton` to get the exact field names.

**Step 4: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): add keyboard conversion and sendMsgWithKeyboard helper"
```

---

### Task 4: Implement /newaccount command

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Add imports for account creation**

```haskell
import Application.Services.AccountService (createAccount)
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    Money,
    TelegramId (..),
    TelegramIdentity (..),
    moneyCurrency,
    mkMoney,
    unMoney,
  )
```

**Step 2: Add /newaccount to the command router**

In `handleCommand`, add a case:

```haskell
    "/newaccount" -> handleNewAccount botState telegramId chatId
```

**Step 3: Implement `handleNewAccount`**

```haskell
-- | Handle /newaccount command — start account creation flow.
handleNewAccount :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleNewAccount botState telegramId chatId = do
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.insert telegramId CreateAccountEnterName s.conversations}
  sendMsg chatId "Enter a name for your new account:"
```

**Step 4: Handle name input in `handleMessage`**

Replace the current `handleMessage` stub with state-aware dispatch:

```haskell
handleMessage :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleMessage botState telegramId chatId text = do
  state <- atomically $ do
    s <- readTVar botState
    return $ Map.lookup telegramId s.conversations
  case state of
    Just CreateAccountEnterName ->
      handleCreateAccountName botState telegramId chatId text
    Just (CreateAccountSelectCurrency _) ->
      sendMsg chatId "Please tap a currency button above."
    -- (more states will be added in later tasks)
    _ ->
      sendMsg chatId "I don't understand. Use /help to see available commands."
```

**Step 5: Implement name handler**

```haskell
-- | Handle account name input during creation flow.
handleCreateAccountName :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleCreateAccountName botState telegramId chatId name = do
  let trimmedName = T.strip name
  if T.null trimmedName
    then sendMsg chatId "Account name cannot be empty. Please enter a name:"
    else do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (CreateAccountSelectCurrency trimmedName) s.conversations}
      sendMsgWithKeyboard chatId "Select currency:" currencyKeyboard
```

**Step 6: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

Expected: Success (callback handling for currency will be in Task 7).

**Step 7: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement /newaccount command (name entry step)"
```

---

### Task 5: Implement /select command

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Add /select to the command router**

```haskell
    "/select" -> handleSelect botState telegramId chatId
```

**Step 2: Implement `handleSelect`**

```haskell
-- | Handle /select command — pick current account.
handleSelect :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleSelect _botState telegramId chatId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just [] -> sendMsg chatId "You don't have any accounts yet. Use /newaccount to create one."
    Just accounts -> do
      let keyboard = accountSelectionKeyboard accounts "select"
      sendMsgWithKeyboard chatId "Select an account:" keyboard
```

**Step 3: Extract `getUserRegularAccounts` helper**

This helper is reused by /select, /transfer, /income, /expense — extract it:

```haskell
-- | Get user's regular accounts as (AccountId, Name, Balance) triples.
-- Returns Nothing if user not found, Just [] if no accounts.
getUserRegularAccounts :: TelegramId -> AppM (Maybe [(AccountId, Text, Money)])
getUserRegularAccounts telegramId = do
  userReadModel <- view userReadModelL
  maybeUser <- getUserByTelegramId userReadModel telegramId
  case maybeUser of
    Nothing -> return Nothing
    Just (userId, _userData) -> do
      accountReadModel <- view accountReadModelL
      allAccounts <- getAllAccounts accountReadModel
      let userAccounts =
            [ (accId, acc.name, acc.balance)
              | (accId, acc) <- Map.toList allAccounts,
                acc.createdBy == userId,
                acc.accountType == RegularAccount
            ]
      return $ Just userAccounts
```

**Step 4: Also extract `getUserId` helper for reuse**

```haskell
-- | Look up UserId for a TelegramId.
getUserIdForTelegram :: TelegramId -> AppM (Maybe UserId)
getUserIdForTelegram telegramId = do
  userReadModel <- view userReadModelL
  maybeUser <- getUserByTelegramId userReadModel telegramId
  return $ fmap fst maybeUser
```

Add necessary imports:

```haskell
import Domain.Core.Types (AccountType (..), ...)
```

**Step 5: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 6: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement /select command and account helpers"
```

---

### Task 6: Implement /cancel command

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Add /cancel to the command router**

```haskell
    "/cancel" -> handleCancel botState telegramId chatId
```

**Step 2: Implement `handleCancel`**

```haskell
-- | Handle /cancel command — cancel current flow.
handleCancel :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleCancel botState telegramId chatId = do
  hadConversation <- atomically $ do
    s <- readTVar botState
    let had = Map.member telegramId s.conversations
    writeTVar botState $ s {conversations = Map.delete telegramId s.conversations}
    return had
  if hadConversation
    then sendMsg chatId "Operation cancelled."
    else sendMsg chatId "Nothing to cancel."
```

**Step 3: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 4: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement /cancel command"
```

---

### Task 7: Implement callback query handler — dispatch and account creation completion

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Parse callback data**

Add a parsing function:

```haskell
-- | Parse callback data string into CallbackData.
parseCallbackData :: Text -> Maybe CallbackData
parseCallbackData "cancel" = Just Cancel
parseCallbackData "confirm" = Just Confirm
parseCallbackData t
  | "acc:" `T.isPrefixOf` t =
      case T.splitOn ":" t of
        ["acc", accId, ctx] -> Just $ AccountSelect (AccountSelectionCallback accId ctx)
        _ -> Nothing
  | "cat:" `T.isPrefixOf` t =
      Just $ CategorySelect (T.drop 4 t)
  | "cur:" `T.isPrefixOf` t =
      Just $ CurrencySelect (T.drop 4 t)
  | otherwise = Nothing
```

**Step 2: Replace the `handleCallbackQuery` stub**

```haskell
handleCallbackQuery :: TVar BotState -> TelegramId -> Int64 -> TG.CallbackQueryId -> Text -> AppM ()
handleCallbackQuery botState telegramId chatId callbackQueryId rawData = do
  -- Always acknowledge the callback to remove loading indicator
  withClient $ \clientEnv ->
    void $ answerCallback clientEnv callbackQueryId Nothing

  case parseCallbackData rawData of
    Nothing -> sendMsg chatId "Invalid button data."
    Just Cancel -> handleCancel botState telegramId chatId
    Just cbData -> do
      state <- atomically $ do
        s <- readTVar botState
        return $ Map.lookup telegramId s.conversations
      dispatchCallback botState telegramId chatId state cbData
```

**Step 3: Implement `dispatchCallback`**

```haskell
-- | Dispatch a parsed callback based on conversation state.
dispatchCallback :: TVar BotState -> TelegramId -> Int64 -> Maybe ConversationState -> CallbackData -> AppM ()
-- Account selection for /select (no conversation state needed)
dispatchCallback botState telegramId chatId _ (AccountSelect cb)
  | cb.context == "select" = handleSelectCallback botState telegramId chatId cb.accountId
-- Currency selection during account creation
dispatchCallback botState telegramId chatId (Just (CreateAccountSelectCurrency name)) (CurrencySelect curText) =
  handleCreateAccountCurrency botState telegramId chatId name curText
-- (more cases added in later tasks)
dispatchCallback _botState _telegramId chatId _ _ =
  sendMsg chatId "Unexpected input. Use /cancel to start over."
```

**Step 4: Implement `/select` callback handler**

```haskell
-- | Handle account selection callback for /select.
handleSelectCallback :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleSelectCallback botState telegramId chatId shortAccountId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "User not found."
    Just accounts ->
      case findAccountByShortId shortAccountId accounts of
        Nothing -> sendMsg chatId "Account not found."
        Just (accountId, name, _balance) -> do
          atomically $ modifyTVar' botState $ \s ->
            s {selectedAccounts = Map.insert telegramId (accountId, name) s.selectedAccounts}
          sendMsg chatId $ "Selected: " <> name
```

**Step 5: Add `findAccountByShortId` helper**

```haskell
import qualified Data.UUID as UUID

-- | Find an account by short ID prefix (first 8 chars of UUID).
findAccountByShortId :: Text -> [(AccountId, Text, Money)] -> Maybe (AccountId, Text, Money)
findAccountByShortId shortId accounts =
  find (\(accId, _, _) -> T.take 8 (T.pack (UUID.toString (unAccountId accId))) == shortId) accounts
```

Add import: `import Domain.Core.Types (..., unAccountId)`

**Step 6: Implement currency selection handler for account creation**

```haskell
-- | Handle currency selection during account creation.
handleCreateAccountCurrency :: TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleCreateAccountCurrency botState telegramId chatId name curText = do
  case parseCurrency curText of
    Nothing -> sendMsg chatId "Invalid currency. Please tap a button above."
    Just currency -> do
      -- Clear conversation state
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.delete telegramId s.conversations}

      -- Look up user ID
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId "User not found. Use /start first."
        Just userId -> do
          -- Create zero money in selected currency
          case mkMoney currency 0 of
            Left err -> sendMsg chatId $ "Error: " <> err
            Right zeroBalance -> do
              let cmd =
                    CreateAccount
                      { name = name,
                        initialBalance = zeroBalance,
                        createdBy = userId,
                        accountType = RegularAccount,
                        overdraftLimit = Nothing
                      }
              result <- createAccount cmd
              case result of
                Left err -> sendMsg chatId $ "Failed to create account: " <> tshow err
                Right (accountId, _accountData) -> do
                  -- Auto-select the new account
                  atomically $ modifyTVar' botState $ \s ->
                    s {selectedAccounts = Map.insert telegramId (accountId, name) s.selectedAccounts}
                  sendMsg chatId $ "Account \"" <> name <> "\" created and selected!"

-- | Parse currency from text.
parseCurrency :: Text -> Maybe Currency
parseCurrency "UAH" = Just UAH
parseCurrency "USD" = Just USD
parseCurrency "EUR" = Just EUR
parseCurrency "GBP" = Just GBP
parseCurrency _ = Nothing
```

Add import: `import Domain.Account.Commands (CreateAccount (..))`
Add import: `import Application.Services.AccountService (createAccount)`

**Step 7: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 8: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement callback handler, /select and account creation flows"
```

---

### Task 8: Implement /income command flow

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Wire /income to show category keyboard**

Replace the stub:

```haskell
handleIncome :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleIncome botState telegramId chatId = do
  -- Check selected account
  selected <- atomically $ do
    s <- readTVar botState
    return $ Map.lookup telegramId s.selectedAccounts
  case selected of
    Nothing -> sendMsg chatId "No account selected. Use /select first."
    Just (_accountId, _name) -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId IncomeSelectCategory s.conversations}
      sendMsgWithKeyboard chatId "Select income category:" incomeCategoryKeyboard
```

**Step 2: Add category callback dispatch in `dispatchCallback`**

Add these cases:

```haskell
-- Income category selection
dispatchCallback botState telegramId chatId (Just IncomeSelectCategory) (CategorySelect catText) =
  handleIncomeCategorySelected botState telegramId chatId catText
-- Income amount entry is handled via text message (Task 10)
```

**Step 3: Implement category selection handler**

```haskell
-- | Handle income category selection.
handleIncomeCategorySelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleIncomeCategorySelected botState telegramId chatId catText = do
  case parseIncomeCategory catText of
    Nothing -> sendMsg chatId "Invalid category."
    Just _cat -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (IncomeEnterAmount catText) s.conversations}
      sendMsg chatId "Enter amount:"

-- | Parse income category from text.
parseIncomeCategory :: Text -> Maybe IncomeCategory
parseIncomeCategory "salary" = Just Salary
parseIncomeCategory "freelance" = Just Freelance
parseIncomeCategory "investment" = Just Investment
parseIncomeCategory "gift" = Just IncomeGift
parseIncomeCategory "other" = Just IncomeOther
parseIncomeCategory _ = Nothing
```

Add import: `import Domain.Core.Types (..., IncomeCategory (..))`

**Step 4: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 5: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement /income category selection step"
```

---

### Task 9: Implement /expense command flow

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Wire /expense to show category keyboard**

Replace the stub:

```haskell
handleExpense :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleExpense botState telegramId chatId = do
  selected <- atomically $ do
    s <- readTVar botState
    return $ Map.lookup telegramId s.selectedAccounts
  case selected of
    Nothing -> sendMsg chatId "No account selected. Use /select first."
    Just (_accountId, _name) -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId ExpenseSelectCategory s.conversations}
      sendMsgWithKeyboard chatId "Select expense category:" expenseCategoryKeyboard
```

**Step 2: Add category callback dispatch in `dispatchCallback`**

```haskell
-- Expense category selection
dispatchCallback botState telegramId chatId (Just ExpenseSelectCategory) (CategorySelect catText) =
  handleExpenseCategorySelected botState telegramId chatId catText
```

**Step 3: Implement category selection handler**

```haskell
-- | Handle expense category selection.
handleExpenseCategorySelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleExpenseCategorySelected botState telegramId chatId catText = do
  case parseExpenseCategory catText of
    Nothing -> sendMsg chatId "Invalid category."
    Just _cat -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (ExpenseEnterAmount catText) s.conversations}
      sendMsg chatId "Enter amount:"

-- | Parse expense category from text.
parseExpenseCategory :: Text -> Maybe ExpenseCategory
parseExpenseCategory "food" = Just Food
parseExpenseCategory "transport" = Just Transport
parseExpenseCategory "utilities" = Just Utilities
parseExpenseCategory "rent" = Just Rent
parseExpenseCategory "entertainment" = Just Entertainment
parseExpenseCategory "other" = Just ExpenseOther
parseExpenseCategory _ = Nothing
```

Add import: `import Domain.Core.Types (..., ExpenseCategory (..))`

**Step 4: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 5: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement /expense category selection step"
```

---

### Task 10: Implement amount and reason text input handling for income/expense

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Extend `handleMessage` with amount/reason states**

Add these cases to `handleMessage`:

```haskell
    -- Income amount
    Just (IncomeEnterAmount _cat) ->
      handleAmountInput botState telegramId chatId text $ \money ->
        let cat = _cat  -- category text from state
        in atomically (modifyTVar' botState $ \s ->
             s {conversations = Map.insert telegramId (IncomeEnterReason cat money) s.conversations})
           >> sendMsg chatId "Enter reason:"

    -- Income reason
    Just (IncomeEnterReason cat money) ->
      handleIncomeComplete botState telegramId chatId cat money text

    -- Expense amount
    Just (ExpenseEnterAmount _cat) ->
      handleAmountInput botState telegramId chatId text $ \money ->
        let cat = _cat
        in atomically (modifyTVar' botState $ \s ->
             s {conversations = Map.insert telegramId (ExpenseEnterReason cat money) s.conversations})
           >> sendMsg chatId "Enter reason:"

    -- Expense reason
    Just (ExpenseEnterReason cat money) ->
      handleExpenseComplete botState telegramId chatId cat money text
```

**Step 2: Implement amount parsing helper**

```haskell
import Text.Read (readMaybe)

-- | Parse and validate amount input, then run continuation.
handleAmountInput :: TVar BotState -> TelegramId -> Int64 -> Text -> (Money -> AppM ()) -> AppM ()
handleAmountInput _botState _telegramId chatId text onSuccess = do
  -- Get selected account's currency
  -- For now, parse as rational and create Money with account currency
  case readMaybe (T.unpack (T.strip text)) :: Maybe Double of
    Nothing -> sendMsg chatId "Please enter a valid number (e.g. 100.50):"
    Just dbl
      | dbl <= 0 -> sendMsg chatId "Amount must be positive. Please enter again:"
      | otherwise -> do
          -- We need the selected account's currency
          -- This will be passed from the calling context
          -- For now use a simple approach
          let rational = toRational dbl
          case mkMoney USD rational of  -- currency will be fixed in the next step
            Left err -> sendMsg chatId $ "Invalid amount: " <> err
            Right money -> onSuccess money
```

Wait — we need the selected account's currency. Let me revise. The amount handler needs to know which currency. Let's read it from the selected account:

```haskell
-- | Parse amount input and create Money with selected account's currency.
handleAmountInput :: TVar BotState -> TelegramId -> Int64 -> Text -> (Money -> AppM ()) -> AppM ()
handleAmountInput botState telegramId chatId text onSuccess = do
  selected <- atomically $ do
    s <- readTVar botState
    return $ Map.lookup telegramId s.selectedAccounts
  case selected of
    Nothing -> sendMsg chatId "No account selected. Use /select first."
    Just (accountId, _name) -> do
      -- Look up account to get currency
      accountReadModel <- view accountReadModelL
      maybeAcc <- liftIO $ ReadModel.getAccount accountReadModel accountId
      case maybeAcc of
        Nothing -> sendMsg chatId "Selected account not found."
        Just acc -> do
          let currency = moneyCurrency acc.balance
          case readMaybe (T.unpack (T.strip text)) :: Maybe Double of
            Nothing -> sendMsg chatId "Please enter a valid number (e.g. 100.50):"
            Just dbl
              | dbl <= 0 -> sendMsg chatId "Amount must be positive. Please enter again:"
              | otherwise ->
                  case mkMoney currency (toRational dbl) of
                    Left err -> sendMsg chatId $ "Invalid amount: " <> err
                    Right money -> onSuccess money
```

Add imports:
```haskell
import qualified Application.ReadModels.Account as ReadModel
import Application.ReadModels.Account (AccountData (..))
```

**Step 3: Implement income completion**

```haskell
import Application.Services.TransactionService (initiateIncome, initiateExpense, initiateInternalTransfer)

-- | Complete the income flow — execute the transaction.
handleIncomeComplete :: TVar BotState -> TelegramId -> Int64 -> Text -> Money -> Text -> AppM ()
handleIncomeComplete botState telegramId chatId catText money reason = do
  -- Clear conversation state
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.delete telegramId s.conversations}

  case parseIncomeCategory catText of
    Nothing -> sendMsg chatId "Invalid category."
    Just cat -> do
      maybeUserId <- getUserIdForTelegram telegramId
      selected <- atomically $ do
        s <- readTVar botState
        return $ Map.lookup telegramId s.selectedAccounts
      case (maybeUserId, selected) of
        (Just userId, Just (accountId, accountName)) -> do
          result <- initiateIncome userId accountId money cat reason
          case result of
            Left err -> sendMsg chatId $ "Failed: " <> tshow err
            Right (_txId, _txData) ->
              sendMsg chatId $
                "Income recorded: +" <> formatMoney money <> " " <> showCurrency (moneyCurrency money)
                  <> " (" <> catText <> ") to " <> accountName
        _ -> sendMsg chatId "Error: user or account not found."
```

**Step 4: Implement expense completion**

```haskell
-- | Complete the expense flow — execute the transaction.
handleExpenseComplete :: TVar BotState -> TelegramId -> Int64 -> Text -> Money -> Text -> AppM ()
handleExpenseComplete botState telegramId chatId catText money reason = do
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.delete telegramId s.conversations}

  case parseExpenseCategory catText of
    Nothing -> sendMsg chatId "Invalid category."
    Just cat -> do
      maybeUserId <- getUserIdForTelegram telegramId
      selected <- atomically $ do
        s <- readTVar botState
        return $ Map.lookup telegramId s.selectedAccounts
      case (maybeUserId, selected) of
        (Just userId, Just (accountId, accountName)) -> do
          result <- initiateExpense userId accountId money cat reason
          case result of
            Left err -> sendMsg chatId $ "Failed: " <> tshow err
            Right (_txId, _txData) ->
              sendMsg chatId $
                "Expense recorded: -" <> formatMoney money <> " " <> showCurrency (moneyCurrency money)
                  <> " (" <> catText <> ") from " <> accountName
        _ -> sendMsg chatId "Error: user or account not found."
```

**Step 5: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 6: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement income/expense amount, reason, and execution"
```

---

### Task 11: Implement /transfer command flow

**Files:**
- Modify: `src/Telegram/Commands.hs`

**Step 1: Wire /transfer to show source account keyboard**

Replace the stub:

```haskell
handleTransfer :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleTransfer botState telegramId chatId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just [] -> sendMsg chatId "You need at least 2 accounts for a transfer."
    Just [_] -> sendMsg chatId "You need at least 2 accounts for a transfer."
    Just accounts -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId TransferSelectSource s.conversations}
      let keyboard = accountSelectionKeyboard accounts "transfer_src"
      sendMsgWithKeyboard chatId "Select source account:" keyboard
```

**Step 2: Add transfer callback dispatch cases in `dispatchCallback`**

```haskell
-- Transfer source selection
dispatchCallback botState telegramId chatId (Just TransferSelectSource) (AccountSelect cb)
  | cb.context == "transfer_src" =
      handleTransferSourceSelected botState telegramId chatId cb.accountId
-- Transfer target selection
dispatchCallback botState telegramId chatId (Just (TransferSelectTarget _srcId)) (AccountSelect cb)
  | cb.context == "transfer_tgt" =
      handleTransferTargetSelected botState telegramId chatId cb.accountId
-- Transfer category selection
dispatchCallback botState telegramId chatId (Just (TransferSelectCategory _srcId _tgtId)) (CategorySelect catText) =
  handleTransferCategorySelected botState telegramId chatId catText
```

**Step 3: Implement transfer handlers**

```haskell
-- | Handle transfer source account selection.
handleTransferSourceSelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleTransferSourceSelected botState telegramId chatId shortAccountId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "User not found."
    Just accounts ->
      case findAccountByShortId shortAccountId accounts of
        Nothing -> sendMsg chatId "Account not found."
        Just (sourceId, _sourceName, _) -> do
          -- Show target accounts (exclude source)
          let targetAccounts = filter (\(accId, _, _) -> accId /= sourceId) accounts
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId (TransferSelectTarget sourceId) s.conversations}
          let keyboard = accountSelectionKeyboard targetAccounts "transfer_tgt"
          sendMsgWithKeyboard chatId "Select target account:" keyboard

-- | Handle transfer target account selection.
handleTransferTargetSelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleTransferTargetSelected botState telegramId chatId shortAccountId = do
  state <- atomically $ do
    s <- readTVar botState
    return $ Map.lookup telegramId s.conversations
  case state of
    Just (TransferSelectTarget sourceId) -> do
      maybeAccounts <- getUserRegularAccounts telegramId
      case maybeAccounts of
        Nothing -> sendMsg chatId "User not found."
        Just accounts ->
          case findAccountByShortId shortAccountId accounts of
            Nothing -> sendMsg chatId "Account not found."
            Just (targetId, _targetName, _) -> do
              atomically $ modifyTVar' botState $ \s ->
                s {conversations = Map.insert telegramId (TransferSelectCategory sourceId targetId) s.conversations}
              sendMsgWithKeyboard chatId "Select transfer category:" internalCategoryKeyboard
    _ -> sendMsg chatId "Unexpected state. Use /cancel to start over."

-- | Handle transfer category selection.
handleTransferCategorySelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleTransferCategorySelected botState telegramId chatId catText = do
  state <- atomically $ do
    s <- readTVar botState
    return $ Map.lookup telegramId s.conversations
  case state of
    Just (TransferSelectCategory sourceId targetId) ->
      case parseInternalCategory catText of
        Nothing -> sendMsg chatId "Invalid category."
        Just _cat -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId (TransferEnterAmount sourceId targetId catText) s.conversations}
          sendMsg chatId "Enter amount:"
    _ -> sendMsg chatId "Unexpected state. Use /cancel to start over."

-- | Parse internal category from text.
parseInternalCategory :: Text -> Maybe InternalCategory
parseInternalCategory "rebalance" = Just Rebalance
parseInternalCategory "savings" = Just Savings
parseInternalCategory "other" = Just InternalOther
parseInternalCategory _ = Nothing
```

Add import: `import Domain.Core.Types (..., InternalCategory (..))`

**Step 4: Add transfer amount/reason handling to `handleMessage`**

```haskell
    -- Transfer amount
    Just (TransferEnterAmount srcId tgtId cat) ->
      handleTransferAmountInput botState telegramId chatId srcId tgtId cat text

    -- Transfer reason
    Just (TransferEnterReason srcId tgtId cat money) ->
      handleTransferComplete botState telegramId chatId srcId tgtId cat money text
```

**Step 5: Implement transfer amount and completion handlers**

```haskell
-- | Handle transfer amount input.
handleTransferAmountInput :: TVar BotState -> TelegramId -> Int64 -> AccountId -> AccountId -> Text -> Text -> AppM ()
handleTransferAmountInput botState telegramId chatId srcId tgtId catText text = do
  -- Get source account currency
  accountReadModel <- view accountReadModelL
  maybeAcc <- liftIO $ ReadModel.getAccount accountReadModel srcId
  case maybeAcc of
    Nothing -> sendMsg chatId "Source account not found."
    Just acc -> do
      let currency = moneyCurrency acc.balance
      case readMaybe (T.unpack (T.strip text)) :: Maybe Double of
        Nothing -> sendMsg chatId "Please enter a valid number (e.g. 100.50):"
        Just dbl
          | dbl <= 0 -> sendMsg chatId "Amount must be positive. Please enter again:"
          | otherwise ->
              case mkMoney currency (toRational dbl) of
                Left err -> sendMsg chatId $ "Invalid amount: " <> err
                Right money -> do
                  atomically $ modifyTVar' botState $ \s ->
                    s {conversations = Map.insert telegramId (TransferEnterReason srcId tgtId catText money) s.conversations}
                  sendMsg chatId "Enter reason:"

-- | Complete the transfer flow.
handleTransferComplete :: TVar BotState -> TelegramId -> Int64 -> AccountId -> AccountId -> Text -> Money -> Text -> AppM ()
handleTransferComplete botState telegramId chatId srcId tgtId catText money reason = do
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.delete telegramId s.conversations}

  case parseInternalCategory catText of
    Nothing -> sendMsg chatId "Invalid category."
    Just cat -> do
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId "User not found."
        Just userId -> do
          result <- initiateInternalTransfer userId srcId tgtId money cat reason
          case result of
            Left err -> sendMsg chatId $ "Transfer failed: " <> tshow err
            Right (_txId, _txData) ->
              sendMsg chatId $
                "Transfer initiated: " <> formatMoney money <> " " <> showCurrency (moneyCurrency money)
                  <> " (" <> catText <> ")"
```

**Step 6: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 7: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): implement /transfer flow with account and category selection"
```

---

### Task 12: Update Bot.hs initBot and help text

**Files:**
- Modify: `src/Telegram/Bot.hs`
- Modify: `src/Telegram/Commands.hs`

**Step 1: Update `initBot` in Bot.hs**

The current `initBot` creates `BotState mempty` which is now incorrect (needs two fields):

```haskell
initBot :: (MonadIO m) => TelegramConfig -> m (TVar BotState)
initBot _config = liftIO $ newTVarIO emptyBotState
```

Import `emptyBotState` from `Telegram.Types`:

```haskell
import Telegram.Types (BotState (..), emptyBotState)
```

Remove the `where emptyBotState = BotState mempty` clause.

**Step 2: Update help text in Commands.hs**

```haskell
handleHelp :: TelegramId -> Int64 -> AppM ()
handleHelp _telegramId chatId = do
  sendMsg chatId
    $ T.unlines
      [ "HomeAccounting Bot Commands:",
        "",
        "/start - Start using the bot",
        "/newaccount - Create a new account",
        "/accounts - List your accounts",
        "/balance - Show account balances",
        "/select - Select current account",
        "/income - Record income",
        "/expense - Record expense",
        "/transfer - Transfer between accounts",
        "/cancel - Cancel current operation",
        "/help - Show this help message"
      ]
```

Also update the `/start` welcome message to include `/newaccount`, `/select`, `/cancel`.

**Step 3: Build**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just build`

**Step 4: Commit**

```bash
git add src/Telegram/Bot.hs src/Telegram/Commands.hs
git commit -m "feat(telegram): update help text and fix initBot for new BotState"
```

---

### Task 13: Format and lint

**Step 1: Format**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just format`

**Step 2: Lint**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just lint`

Fix any issues.

**Step 3: Full build with CI flags**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c cabal build -fci`

**Step 4: Run tests**

Run: `cd /Users/oleksandrsy/Projects/Self/Homeaccounting/backend && nix develop -c just test`

**Step 5: Commit any formatting/lint fixes**

```bash
git add -A
git commit -m "chore: format and lint telegram bot code"
```
