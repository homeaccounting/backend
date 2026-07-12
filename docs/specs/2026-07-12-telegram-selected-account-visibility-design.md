---
status: draft
date: 2026-07-12
---

# See and clear the selected account in the Telegram bot

## Problem

The Telegram bot keeps a per-user *selected account*
(`BotState.selectedAccounts :: Map TelegramId (AccountId, Text)`). This
selection matters: it fills the primary account slot for the
natural-language prompt path (`handlePromptText` →
`PromptService.handlePrompt`) and it scopes the `/transactions` listing.

Two capabilities are missing:

1. **See the current selection.** Nothing surfaces which account is
   selected. The only feedback is the momentary `"Selected: <name>"`
   reply at the instant of selection; the `/accounts` list does not mark
   the active account, so a user returning later cannot tell what their
   prompts will post against.
2. **Clear the selection.** Once `selectedAccounts` holds an entry there
   is no way to remove it. `/cancel` only clears `conversations`, never
   `selectedAccounts`.

## Approach

Surface both capabilities through the existing `/accounts` view — the
single place where account selection already happens — rather than adding
a new command. Selecting, seeing, and clearing all live together.

The prompt/transaction pipeline is **not** changed: it already reads
`selectedAccounts` and will correctly observe an absent entry after a
clear.

### 1. Callback data — `Telegram/Types.hs`

Add one constructor to `CallbackData`:

```haskell
| ClearSelection   -- clears the user's selected account
```

Wire the text token `"unselect"` ↔ `ClearSelection` in
`parseCallbackData`. The token is well within Telegram's 64-byte
`callback_data` limit.

### 2. Keyboard — `Telegram/Keyboards.hs`

Extend `accountSelectionKeyboard` with a `Maybe AccountId` "currently
selected" parameter:

- The button whose `AccountId` equals the selected one is prefixed with
  `✓ ` in its label.
- When the context is `"select"` **and** an account is selected, a
  `[ Clear selection ]` row (callback data `"unselect"`) is appended above
  the `Cancel` row.
- The two transfer call sites (`"transfer_src"`, `"transfer_tgt"`) pass
  `Nothing`: no `✓` marker and no Clear row, preserving current behaviour.

### 3. Handlers — `Telegram/Commands.hs`

- `handleAccounts`: its currently-ignored `_botState` parameter is
  un-underscored so it can read the user's entry from `selectedAccounts`.
  The header text — `"Currently selected: <name>"` when set, else
  `"No account selected."` — is folded into the single existing
  `sendMsgWithKeyboard` call (the `/accounts` reply is one message), and
  the selected `AccountId` is passed into `accountSelectionKeyboard`.
- `handleCallbackQuery`: handle `ClearSelection` early — alongside
  `Cancel`, before the conversation-state dispatch — so it works
  irrespective of any in-flight conversation. A new `handleClearSelection`
  deletes the user's entry from `selectedAccounts` and replies
  `"Selection cleared."`, or `"No account was selected."` when there was
  nothing to clear. The plain-message reply is consistent with the
  existing `"Selected: <name>"` feedback. `handleClearSelection` is added
  to the module export list so the integration test can drive it directly
  (no need to fabricate a `TG.CallbackQueryId`).

## Data flow

```
/accounts
  → read selectedAccounts[telegramId] from BotState
  → header ("Currently selected: X" | "No account selected.")
  → accountSelectionKeyboard accounts (fst <$> selected) "select"
       (✓ on the active account; [Clear selection] row when selected)

tap [Clear selection]
  → callback "unselect" → ClearSelection
  → Map.delete telegramId selectedAccounts
  → reply "Selection cleared."
```

## Testing (TDD)

- **Pure unit tests**
  - `parseCallbackData "unselect"` yields `ClearSelection`.
  - `accountSelectionKeyboard` prefixes exactly the selected account with
    `✓` and includes the `Clear selection` row only when an account is
    selected in the `"select"` context; transfer contexts never do.
- **Integration test (`test/Telegram/CommandsSpec.hs`)**
  - With `selectedAccounts` seeded, invoking `handleClearSelection` removes
    the user's entry from the `botState` TVar.
  - Clearing when nothing is selected is a safe no-op (state unchanged).

  Consistent with the existing spec, tests assert on `botState` /
  read-model side-effects, not on reply text (the Telegram client is
  `Nothing` in tests).

## Out of scope (YAGNI)

- No dedicated `/selected` command.
- No toggle-off by re-tapping the already-selected account.
- No persistence of the selection across bot restarts (it is, and remains,
  in-memory only).
