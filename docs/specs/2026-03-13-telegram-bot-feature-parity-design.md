---
status: draft
---

# Telegram Bot Feature Parity Design

## Goal

Bring the Telegram bot to feature parity with the Web API. Users should be able to: register, create accounts, list accounts, select a current account, and record income/expense/transfer transactions — all through the bot.

## Decisions

- **Current account session** — user runs `/select` to pick an active account; `/income` and `/expense` use it automatically
- **Category selection via inline keyboard** — categories are hardcoded enums, keyboards built directly from them
- **Minimal account creation** — name + currency only; balance defaults to 0, no overdraft
- **Reason always asked** — free-text reason required for every transaction
- **Transfers included** — full source → target → category → amount → reason flow
- **Wire existing state machine** — build on `ConversationState` in `Types.hs`, no new abstractions

## Bot State Changes

`BotState` gains a `selectedAccounts` map:

```haskell
data BotState = BotState
  { conversations    :: Map TelegramId ConversationState
  , selectedAccounts :: Map TelegramId (AccountId, Text)
  }
```

New `ConversationState` variants for account creation:

```haskell
| CreateAccountEnterName
| CreateAccountSelectCurrency { accountName :: Text }
```

New states for category selection:

```haskell
| IncomeSelectCategory
| ExpenseSelectCategory
| TransferSelectCategory { sourceAccountId, targetAccountId }
```

Existing income/expense/transfer reason states gain a `category :: Text` field.

New `CallbackData` variant:

```haskell
| CategorySelect Text  -- callback format: "cat:<category_name>"
```

## Command Flows

### `/newaccount`

1. Bot asks "Enter account name:" (free text)
2. User types name → bot shows currency keyboard (USD, EUR, GBP, UAH)
3. User taps currency → bot creates account (balance=0, no overdraft)
4. Bot confirms and auto-selects as current account

### `/select`

1. Bot shows account list as inline keyboard
2. User taps account → stored in `selectedAccounts`
3. Bot confirms selection

### `/income`

1. Check `selectedAccounts` — if none, reply "No account selected. Use /select first"
2. Show category keyboard: salary, freelance, investment, gift, other
3. User taps category → "Enter amount:"
4. User types amount (validated positive number) → "Enter reason:"
5. User types reason → execute income command
6. Confirm with summary

### `/expense`

Same as income with expense categories: food, transport, utilities, rent, entertainment, other.

### `/transfer`

1. Show source account keyboard
2. User taps source → show target account keyboard (exclude source)
3. User taps target → show category keyboard: rebalance, savings, other
4. User taps category → "Enter amount:"
5. User types amount → "Enter reason:"
6. User types reason → execute transfer command
7. Confirm with summary

### `/cancel`

Clears conversation state from any flow. Cancel button present on every keyboard.

## Callback Query Handler

Dispatches on `(ConversationState, CallbackData)`:

- `Cancel` from any state → clear state, send "Cancelled"
- `AccountSelect` with context `"select"` → store in `selectedAccounts`
- `AccountSelect` + `CreateAccountSelectCurrency` → create account
- `AccountSelect` + `TransferSelectSource` → advance to target selection
- `AccountSelect` + `TransferSelectTarget` → advance to category selection
- `CategorySelect` + `*SelectCategory` → store category, ask amount
- Free-text messages handled by `processMessage` based on conversation state

Amount validation: parse with `readMaybe`, must be positive.

## Modified Files

| File | Changes |
|---|---|
| `Types.hs` | `selectedAccounts` in `BotState`, `CreateAccount*` states, category states, `category` field on reason states, `CategorySelect` callback |
| `Commands.hs` | Implement `/newaccount`, `/select`, `/cancel`; wire `/income`, `/expense`, `/transfer`; handle free-text input by state |
| `Keyboards.hs` | Add `currencyKeyboard`, `categoryKeyboard` variants |
| `Bot.hs` | Wire `handleCallbackQuery` to process callbacks and drive state transitions; update `initBot` |
| `Api.hs` | No changes |

No new files. No domain/application layer changes — bot calls existing services.
