# Telegram Selected-Account Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Telegram-bot user see which account is currently selected and clear that selection, both through the existing `/accounts` view.

**Architecture:** Add a `ClearSelection` callback (`"unselect"` token). Extend the pure `accountSelectionKeyboard` to mark the selected account with `✓` and render a `[Clear selection]` row in the `/accounts` context. `handleAccounts` gains a header showing the current selection; a new `handleClearSelection` deletes the per-user entry from `BotState.selectedAccounts`. The prompt/transaction pipeline is untouched — it already reads that map.

**Tech Stack:** Haskell (GHC 9.10, RIO prelude, NoImplicitPrelude), Servant, Hspec + hspec-discover. Build/test via `just build` / `just test` (both pass `-fci`/`-Werror`). Enter `nix develop` first.

**Spec:** `docs/specs/2026-07-12-telegram-selected-account-visibility-design.md`

---

## File Structure

- **Modify** `src/Telegram/Types.hs` — add `ClearSelection` constructor to `CallbackData` (auto-exported via `CallbackData (..)`).
- **Modify** `src/Telegram/Keyboards.hs` — extend `accountSelectionKeyboard` signature with a `Maybe AccountId` "selected" parameter; add `✓` marker and conditional `[Clear selection]` row.
- **Modify** `src/Telegram/Commands.hs` — parse `"unselect"`; update `handleAccounts` (header + keyboard arg, un-underscore `botState`); route `ClearSelection` in `handleCallbackQuery`; add + export `handleClearSelection`; update the two transfer keyboard call sites to pass `Nothing`.
- **Create** `test/Telegram/KeyboardsSpec.hs` — pure tests for the `✓` marker and `[Clear selection]` row (auto-discovered by hspec-discover).
- **Modify** `test/Telegram/CommandsSpec.hs` — integration tests for `handleClearSelection` against the `botState` TVar; a pure `parseCallbackData "unselect"` assertion.

Note on `parseCallbackData`: it is already exported from `Telegram.Commands`. `AccountId` derives `Eq` (used for the `✓` comparison). New spec files require no cabal wiring — hspec-discover finds them; run `hpack` (via `just build`) after adding the file.

---

### Task 1: `ClearSelection` callback constructor

**Files:**
- Modify: `src/Telegram/Types.hs` (the `CallbackData` sum type, ~line 130-141)

- [ ] **Step 1: Add the constructor**

In `src/Telegram/Types.hs`, add a `ClearSelection` constructor to `CallbackData`, immediately after `Confirm`:

```haskell
  | -- | Confirm current operation
    Confirm
  | -- | Clear the user's selected account
    ClearSelection
  deriving (Show, Eq, Generic)
```

The export list already uses `CallbackData (..)`, so no export change is needed. The `ToJSON`/`FromJSON` derived instances cover the new nullary constructor automatically.

- [ ] **Step 2: Build**

Run: `just build`
Expected: compiles clean (no `-Werror` issues; no incomplete-pattern warnings yet because `parseCallbackData` builds `CallbackData`, it doesn't pattern-match exhaustively on it, and `dispatchCallback`'s fallback catches everything).

- [ ] **Step 3: Commit**

```bash
git add src/Telegram/Types.hs
git commit -m "feat(telegram): add ClearSelection callback constructor"
```

---

### Task 2: Keyboard marks selection and offers Clear (pure, TDD)

**Files:**
- Create: `test/Telegram/KeyboardsSpec.hs`
- Modify: `src/Telegram/Keyboards.hs` (`accountSelectionKeyboard`, ~line 56-76)

- [ ] **Step 1: Write the failing test**

Create `test/Telegram/KeyboardsSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Telegram.KeyboardsSpec (spec) where

import qualified Data.Text as T
import qualified Data.UUID as UUID
import Data.Maybe (fromMaybe)
import Domain.Core.Types (AccountId, Currency (..), Money, unsafeAccountId, unsafeMoney)
import Telegram.Keyboards
  ( InlineButton (..),
    InlineKeyboard (..),
    accountSelectionKeyboard,
  )
import Test.Hspec

acc :: Int -> AccountId
acc n =
  let s = "00000000-0000-0000-0000-" <> replicate (12 - length (show n)) '0' <> show n
   in unsafeAccountId (fromMaybe (error "bad uuid") (UUID.fromString s))

-- Two sample accounts with USD balances.
sampleAccounts :: [(AccountId, T.Text, Money)]
sampleAccounts =
  [ (acc 1, "Cash", unsafeMoney USD 1200),
    (acc 2, "Card", unsafeMoney USD 350)
  ]

buttonTexts :: InlineKeyboard -> [T.Text]
buttonTexts kb = [b.text | row <- kb.rows, b <- row]

spec :: Spec
spec = do
  describe "accountSelectionKeyboard" $ do
    it "prefixes the selected account with a check mark in the select context" $ do
      let kb = accountSelectionKeyboard sampleAccounts (Just (acc 2)) "select"
          texts = buttonTexts kb
      any (\t -> "Card" `T.isInfixOf` t && "\x2713" `T.isInfixOf` t) texts `shouldBe` True
      any (\t -> "Cash" `T.isInfixOf` t && "\x2713" `T.isInfixOf` t) texts `shouldBe` False

    it "adds a Clear selection row when an account is selected in the select context" $ do
      let kb = accountSelectionKeyboard sampleAccounts (Just (acc 1)) "select"
      any (\b -> b.callbackData == "unselect") (concat kb.rows) `shouldBe` True

    it "omits the Clear selection row when nothing is selected" $ do
      let kb = accountSelectionKeyboard sampleAccounts Nothing "select"
      any (\b -> b.callbackData == "unselect") (concat kb.rows) `shouldBe` False

    it "never marks or offers Clear in transfer contexts" $ do
      let kb = accountSelectionKeyboard sampleAccounts (Just (acc 1)) "transfer_src"
          texts = buttonTexts kb
      any (\t -> "\x2713" `T.isInfixOf` t) texts `shouldBe` False
      any (\b -> b.callbackData == "unselect") (concat kb.rows) `shouldBe` False
```

Note: `OverloadedRecordDot`, `NoFieldSelectors`, and `DuplicateRecordFields` are project-wide `default-extensions` (applied to the test stanza too), so the dot-access above (`b.text`, `kb.rows`, `b.callbackData`) needs only the `OverloadedStrings` pragma shown — no extra `LANGUAGE` line.

- [ ] **Step 2: Run test, verify it fails to compile**

Run: `cabal test all --test-option='--match' --test-option="/accountSelectionKeyboard/" 2>&1 | tail -20`
Expected: compile error — `accountSelectionKeyboard` still takes 2 args, not 3.

- [ ] **Step 3: Implement the keyboard change**

In `src/Telegram/Keyboards.hs`, change `accountSelectionKeyboard` to accept the selected account and render the marker + Clear row. Replace the existing definition (lines ~56-76) with:

```haskell
accountSelectionKeyboard ::
  -- | List of (AccountId, Name, Balance)
  [(AccountId, Text, Money)] ->
  -- | Currently-selected account (marked with a check); Nothing = none
  Maybe AccountId ->
  -- | Context (e.g., "transfer_src", "transfer_tgt", "select")
  Text ->
  InlineKeyboard
accountSelectionKeyboard accounts selected context =
  InlineKeyboard
    { rows =
        map makeAccountButton accounts
          ++ clearRow
          ++ [[cancelButton]]
    }
  where
    makeAccountButton (accountId, name, balance) =
      [ InlineButton
          { text = marker accountId <> name <> " (" <> showMoney balance <> ")",
            callbackData = "acc:" <> shortId accountId <> ":" <> context
          }
      ]
    marker accountId
      | selected == Just accountId = "\x2713 "
      | otherwise = ""
    clearRow =
      [[InlineButton "Clear selection" "unselect"] | context == "select", isJust selected]
    shortId accountId = T.take 8 $ T.pack $ UUID.toString $ unAccountId accountId
    showMoney m = formatMoney m <> " " <> showCurrency (moneyCurrency m)
```

Add `isJust` to the imports at the top of the module: add `import Data.Maybe (isJust)`.

- [ ] **Step 4: Update the three keyboard call sites (same commit — keeps the tree compiling)**

The arity change breaks the library until every caller is updated, and the library + test suite are one compilation unit. Update all three call sites in `src/Telegram/Commands.hs` now, so this commit builds:

1. `handleTransfer` (~line 373): `accountSelectionKeyboard accounts "transfer_src"` → `accountSelectionKeyboard accounts Nothing "transfer_src"`.
2. `handleTransferSourceSelected` (~line 730): `accountSelectionKeyboard otherAccounts "transfer_tgt"` → `accountSelectionKeyboard otherAccounts Nothing "transfer_tgt"`.
3. `handleAccounts` (~line 342): `accountSelectionKeyboard accounts "select"` → `accountSelectionKeyboard accounts Nothing "select"`. (Task 3 replaces `Nothing` with the real selection; passing `Nothing` here is a compiling placeholder.)

- [ ] **Step 5: Run tests, verify pass**

Run: `cabal test all --test-option='--match' --test-option="/accountSelectionKeyboard/"`
Expected: 4 examples, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add src/Telegram/Keyboards.hs src/Telegram/Commands.hs test/Telegram/KeyboardsSpec.hs
git commit -m "feat(telegram): mark selected account and add Clear row in keyboard"
```

---

### Task 3: Wire `/accounts` header, call sites, and clear handler

**Files:**
- Modify: `src/Telegram/Commands.hs`

The three keyboard call sites were already updated in Task 2 (all passing `Nothing`), so the tree compiles going in. This task swaps `handleAccounts`'s `Nothing` for the real selection, adds the header, and wires the clear handler + callback.

- [ ] **Step 1: Add the failing integration test for clearing**

In `test/Telegram/CommandsSpec.hs`, extend the existing `Telegram.Commands` and `Telegram.Types` imports (do not add duplicate module-import lines):

```haskell
import Telegram.Commands (handleClearSelection, handleMessage, handleSignup, handleStart, parseCallbackData)
import Telegram.Types (BotState (..), CallbackData (..), emptyBotState)
```

Add these specs (place near the other `describe` blocks):

```haskell
  describe "parseCallbackData" $ do
    it "parses \"unselect\" as ClearSelection" $
      parseCallbackData "unselect" `shouldBe` Just ClearSelection

  describe "handleClearSelection" $ do
    it "removes the user's selected account from bot state" $ do
      env <- createTestAppEnv
      botState <-
        newTVarIO
          emptyBotState
            { selectedAccounts =
                Map.singleton freshTgIdent.id (someAccountId, "Cash")
            }
      runAppM env $ handleClearSelection botState freshTgIdent.id testChatId
      s <- readTVarIO botState
      Map.lookup freshTgIdent.id s.selectedAccounts `shouldBe` Nothing

    it "is a no-op when nothing was selected" $ do
      env <- createTestAppEnv
      botState <- newTVarIO emptyBotState
      runAppM env $ handleClearSelection botState freshTgIdent.id testChatId
      s <- readTVarIO botState
      s.selectedAccounts `shouldBe` Map.empty
```

Add a helper `someAccountId` near the other helpers (reuse `unsafeAccountId` + a fixed UUID):

```haskell
someAccountId :: AccountId
someAccountId =
  unsafeAccountId (fromMaybe (error "bad uuid") (UUID.fromString "00000000-0000-0000-0000-000000000001"))
```

and extend imports. `CommandsSpec` imports `RIO`, which already re-exports `fromMaybe`, so do **not** add `Data.Maybe`. Add only:

```haskell
import qualified Data.UUID as UUID
```

and add `AccountId` and `unsafeAccountId` to the existing `Domain.Core.Types` import list.

- [ ] **Step 2: Rewrite `handleAccounts` and add `handleClearSelection`**

In `src/Telegram/Commands.hs`, un-underscore the `botState` param and add the header. Replace `handleAccounts` (~lines 333-342) with:

```haskell
-- | Handle /accounts command.
--
-- Shows accounts with inline keyboard buttons for selection. A header line
-- surfaces the currently-selected account (used by prompts and /transactions),
-- the active account is marked with a check, and a Clear-selection button is
-- offered when something is selected.
handleAccounts :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleAccounts botState telegramId chatId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
  case maybeAccounts of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just accounts
      | null accounts -> sendMsg chatId "You don't have any accounts yet. Use /newaccount to create one."
      | otherwise -> do
          let header = case selected of
                Just (_, name) -> "Currently selected: " <> name
                Nothing -> "No account selected."
              body = header <> "\n\nYour accounts (tap to select):"
          sendMsgWithKeyboard chatId body (accountSelectionKeyboard accounts (fst <$> selected) "select")
```

Add `handleClearSelection` (place near `handleSelectCallback`, ~line 522):

```haskell
-- | Clear the user's selected account. Works regardless of any in-flight
-- conversation, so it is dispatched early alongside /cancel.
handleClearSelection :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleClearSelection botState telegramId chatId = do
  had <- atomically $ do
    s <- readTVar botState
    let existed = Map.member telegramId s.selectedAccounts
    writeTVar botState $ s {selectedAccounts = Map.delete telegramId s.selectedAccounts}
    return existed
  if had
    then sendMsg chatId "Selection cleared."
    else sendMsg chatId "No account was selected."
```

Export `handleClearSelection` from the module: add it to the `-- * Individual Commands` export block (near `handleAccounts` on ~line 30).

- [ ] **Step 3: Parse and route the `unselect` callback**

In `parseCallbackData` (~line 207-216), add a clause alongside the other literals:

```haskell
parseCallbackData "cancel" = Just Cancel
parseCallbackData "confirm" = Just Confirm
parseCallbackData "unselect" = Just ClearSelection
```

In `handleCallbackQuery` (~line 196-204), route `ClearSelection` early, alongside `Cancel`:

```haskell
  case parseCallbackData rawData of
    Nothing -> sendMsg chatId "Invalid button data."
    Just Cancel -> handleCancel botState telegramId chatId
    Just ClearSelection -> handleClearSelection botState telegramId chatId
    Just cbData -> do
      state <- atomically $ Map.lookup telegramId . (.conversations) <$> readTVar botState
      dispatchCallback botState telegramId chatId state cbData
```

- [ ] **Step 4: Run the full Telegram test group, verify pass**

Run: `cabal test all --test-option='--match' --test-option="/Telegram/"`
Expected: existing Telegram specs still pass; the new `parseCallbackData`, `handleClearSelection`, and `accountSelectionKeyboard` examples pass (0 failures).

- [ ] **Step 5: Full build + lint (`-Werror` gate)**

Run: `just build && just lint`
Expected: no warnings/errors. In particular confirm no `-Wincomplete-patterns` for `CallbackData` (the `Just cbData` fallthrough handles the remaining constructors) and no unused-import warnings.

- [ ] **Step 6: Commit**

```bash
git add src/Telegram/Commands.hs test/Telegram/CommandsSpec.hs
git commit -m "feat(telegram): show selected account in /accounts and support clearing"
```

---

### Task 4: Full verification

- [ ] **Step 1: Clean rebuild + full test run**

The incremental `.o` cache can mask `-Werror` regressions on warm builds. Run a definitive check:

Run: `just rebuild && just test`
Expected: build succeeds under `-fci`; test suite green except the known environmental `eventium_test`-DB integration failures (those require a manually-created `eventium_test` Postgres DB and are unrelated to this change).

- [ ] **Step 2: Format check**

Run: `just check`
Expected: ormolu makes no changes (or run `just format` and commit if it does); hlint clean.

- [ ] **Step 3: Commit any formatting**

```bash
git add -A && git commit -m "style(telegram): ormolu" || echo "nothing to format"
```

---

## Notes for the implementer

- Enter `nix develop` before running any `just`/`cabal` command.
- RIO has `NoImplicitPrelude`; `isJust` comes from `Data.Maybe`, `Map` operations from `RIO.Map` in `Commands.hs` (already imported) and `Data.Map.Strict` in `Keyboards.hs`/`Types.hs`.
- Do not reference issue/ticket numbers in test `describe`/`it` titles (repo convention: behaviour names only).
- Prefer dropping an unused parameter over `_`-prefixing it — but here `handleAccounts` genuinely uses `botState` now, so the `_botState` becomes `botState`.
- Keep the reply strings exactly as specified so they read consistently with the existing `"Selected: <name>"` feedback.
