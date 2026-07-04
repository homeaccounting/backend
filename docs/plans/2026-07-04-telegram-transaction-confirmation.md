# Consistent Telegram Recorded-Transaction Confirmation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make all four Telegram transaction-recording paths (`/income`, `/expense`, `/transfer`, natural-language prompt) confirm with one shared, structured message built from the recorded `TransactionData`.

**Architecture:** A pure renderer `formatRecordedTransaction` in `src/Telegram/Formatting.hs` produces the message from a `TransactionData` plus two name maps (category/label names, account names). A thin effectful helper `replyRecordedTransaction` in `src/Telegram/Commands.hs` gathers those maps from existing read-model helpers and sends the message. The four success branches call the helper; the NL handler `runPrompt` is renamed `handlePromptText`.

**Tech Stack:** Haskell (GHC 9.10), RIO prelude, Hspec, ormolu, hlint. Build/test via `just` inside `nix develop`.

**Spec:** `docs/specs/2026-07-04-telegram-transaction-confirmation-design.md`

---

## Background the implementer needs

- **RIO prelude / `NoImplicitPrelude`.** `Text`, `Map`, `Set`, `fromMaybe`, `sort` come from explicit imports (see existing import lists). ormolu splits `<>` operator chains onto their own lines — that is the repo convention; do not fight it.
- **`-fci` / `-Werror`.** CI and `just build`/`just test` compile with `-Werror` over lib+exe+test. Any unused import/binding fails the build. Run `just build` (or `just rebuild` for a definitive warm-cache-proof check) before claiming done.
- **No partial functions**, no `error`/`undefined` in `src/`. The renderer must be total over all `TransactionType` and `TransactionStatus` constructors.
- **DuplicateRecordFields gotcha.** Dot-access on a record field shared across many record types can fail to resolve. This plan avoids it by reusing `getUserRegularAccounts` (which already returns `(AccountId, Text, Money)` triples) rather than calling `getAccount` and reading `AccountData.name`.
- **Formatter format.** `formatMoney :: Money -> Text` (2 dp), `showCurrency :: Currency -> Text`, `formatDate :: UTCTime -> Text` (`YYYY-MM-DD HH:MM`) already exist in `Telegram.Formatting`.

### Target message layouts

Expense (source account) / Income (target account), one bullet per allocation:

```
✅ Expense recorded
20.00 UAH · Cash
• Coffee 4.50 — morning latte
• Snacks 15.50 — office
2026-07-04 14:30
```

Transfer (both amounts + rate only when cross-currency):

```
✅ Transfer recorded
Cash → Savings
100.00 USD → 4150.00 UAH
Rate: 41.50
2026-07-04 14:30
```

Rules:
- Header: `✅ <Kind> recorded`, plus a status marker mirroring `formatTransactionLine`: `  [Pending]` / `  [Cancelled]`; `Completed` clean; `Failed` never reached here.
- Expense/Income: line 2 is `<total> <currency>[ · <account>]`; total = `sourceAmount` (expense) / `targetAmount` (income). One `• <category> <amount>[ — <comment>]` per allocation; unresolved category → bare amount; empty comment → no ` — `.
- Transfer: `<src> → <tgt>` (each falls back to 8-char short id when unresolved, so the arrow never drops); one amount line, two amounts + a `Rate:` line only when source/target currencies differ.
- `Adjustment` (unreachable from these paths, but total): `✅ Adjustment recorded` / `<amount> <currency>[ · <account>]` / date, no bullets.
- Labels: when `td.labels` non-empty, a `Labels: a, b` line (sorted, names from the entry map); omitted when empty.
- Account suffix: for expense/income/adjustment, omit ` · <name>` when the account id isn't in the map; for transfer, use the short-id fallback.

Emoji code points used: `✅` = `\9989`, `·` = `\xB7`, `•` = `\x2022`, `→` = `\x2192`, `—` = `\x2014`.

---

## Task 1: Rename `runPrompt` → `handlePromptText`

Mechanical, isolated. Do this first so later diffs stay clean.

**Files:**
- Modify: `src/Telegram/Commands.hs` (definition ~`:490`, call sites in `handlePromptCommand` ~`:475` and the free-text message router)

- [ ] **Step 1: Find every reference**

Run: `grep -rn "runPrompt" src/ test/`
Expected: the definition plus its call sites (at minimum `handlePromptCommand`, and the idle free-text message handler).

- [ ] **Step 2: Rename definition and all call sites**

Rename the function `runPrompt` to `handlePromptText` at its definition and update every call site found in Step 1. Update the Haddock comment referencing "runPrompt" if present (`grep -rn "runPrompt" src/` around the message-router comment near `:470`).

- [ ] **Step 3: Verify no references remain**

Run: `grep -rn "runPrompt" src/ test/`
Expected: no output.

- [ ] **Step 4: Build**

Run: `just build`
Expected: compiles clean, no warnings.

- [ ] **Step 5: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "refactor(telegram): rename runPrompt to handlePromptText"
```

---

## Task 2: Pure renderer `formatRecordedTransaction` (TDD)

**Files:**
- Modify: `src/Telegram/Formatting.hs` (add function + export + imports)
- Test: `test/Telegram/FormattingSpec.hs` (add a `describe "formatRecordedTransaction"` block)

- [ ] **Step 1: Write failing tests**

Append to `test/Telegram/FormattingSpec.hs`. Reuse the existing `sampleTxn`, `names`, `foodCat`, `salaryCat`, `orphanCat`, `lunchLabel`, `kyivLabel`, `uuidFromInt` fixtures already in that file. Add an account-name map and a couple of helpers for multi-allocation and transfers.

Add these imports to the file's import lists if not already present:
- from `Domain.Core.Types`: `AccountId`, `Allocation (..)`, `Allocations`, `ExchangeRate`, `Money`, `mkAllocation`, `mkExpenseAllocations`, `mkExchangeRate`, `unsafeMoney`
- `Telegram.Formatting (formatRecordedTransaction)` alongside the existing `formatTransactionLine` import
- `Data.List.NonEmpty` as needed (`(:|)` is in RIO's prelude via base; if unavailable, `import Data.List.NonEmpty (NonEmpty (..))`)

```haskell
-- Account name map: account 1 = "Cash", account 2 = "Savings"
acctNames :: Map.Map AccountId T.Text
acctNames =
  Map.fromList
    [ (unsafeAccountId (uuidFromInt 1), "Cash"),
      (unsafeAccountId (uuidFromInt 2), "Savings")
    ]

-- Build a multi-allocation expense: two lines against Food and Salary cats.
multiExpense :: TransactionType
multiExpense =
  let a1 = either (error . show) id (mkAllocation foodCat (unsafeMoney USD 4) (Just "latte"))
      a2 = either (error . show) id (mkAllocation salaryCat (unsafeMoney USD 16) Nothing)
   in Expense (mkExpenseAllocations (a1 :| [a2]))

recordedSpec :: Spec
recordedSpec = describe "formatRecordedTransaction" $ do
  it "renders an expense header, total·account line, bullet, and date" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn (expenseFor foodCat))
    out `shouldSatisfy` T.isInfixOf "\9989 Expense recorded"
    out `shouldSatisfy` T.isInfixOf "300.00 USD \xB7 Cash"
    out `shouldSatisfy` T.isInfixOf "\x2022 Food 300.00"
    out `shouldSatisfy` T.isInfixOf "2026-04-18 14:30"

  it "renders income against the target account" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn (incomeFor salaryCat))
    out `shouldSatisfy` T.isInfixOf "\9989 Income recorded"
    out `shouldSatisfy` T.isInfixOf "\x2022 Salary 300.00"

  it "renders one bullet per allocation with per-allocation comment" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn multiExpense)
    out `shouldSatisfy` T.isInfixOf "\x2022 Food 4.00 \x2014 latte"
    out `shouldSatisfy` T.isInfixOf "\x2022 Salary 16.00"
    -- allocation without a comment has no em-dash tail
    out `shouldNotSatisfy` T.isInfixOf "Salary 16.00 \x2014"

  it "falls back to the bare amount when a category is unresolved" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn (expenseFor orphanCat))
    out `shouldSatisfy` T.isInfixOf "\x2022 300.00"

  it "omits the account suffix when the account is unresolved" $ do
    let out = formatRecordedTransaction names Map.empty (sampleTxn (expenseFor foodCat))
    out `shouldSatisfy` T.isInfixOf "300.00 USD"
    out `shouldNotSatisfy` T.isInfixOf "\xB7"

  it "renders a same-currency transfer with one amount and no rate" $ do
    let out = formatRecordedTransaction names acctNames (sampleTxn Transfer)
    out `shouldSatisfy` T.isInfixOf "\9989 Transfer recorded"
    out `shouldSatisfy` T.isInfixOf "Cash \x2192 Savings"
    out `shouldSatisfy` T.isInfixOf "300.00 USD"
    out `shouldNotSatisfy` T.isInfixOf "Rate:"

  it "renders a cross-currency transfer with both amounts and a rate" $ do
    let er = either (error . show) id (mkExchangeRate USD UAH (toRational (41.5 :: Double)))
        txn =
          (sampleTxn Transfer)
            { sourceAmount = unsafeMoney USD 100,
              targetAmount = unsafeMoney UAH 4150,
              exchangeRate = Just er
            }
        out = formatRecordedTransaction names acctNames txn
    out `shouldSatisfy` T.isInfixOf "100.00 USD \x2192 4150.00 UAH"
    out `shouldSatisfy` T.isInfixOf "Rate: 41.50"

  it "falls back to a short id for an unresolved transfer endpoint" $ do
    let out = formatRecordedTransaction names Map.empty (sampleTxn Transfer)
    out `shouldSatisfy` T.isInfixOf "00000000 \x2192 00000000"

  it "appends a Pending marker but not for Completed" $ do
    let completed = formatRecordedTransaction names acctNames (sampleTxn (expenseFor foodCat))
        pending = formatRecordedTransaction names acctNames ((sampleTxn (expenseFor foodCat)) {status = Pending})
    completed `shouldNotSatisfy` T.isInfixOf "["
    pending `shouldSatisfy` T.isInfixOf "[Pending]"

  it "appends resolved labels sorted and omits when empty" $ do
    let withLabels = (sampleTxn (expenseFor foodCat)) {labels = Set.fromList [kyivLabel, lunchLabel]}
        out = formatRecordedTransaction names acctNames withLabels
    out `shouldSatisfy` T.isInfixOf "Labels: kyiv, lunch"
    formatRecordedTransaction names acctNames (sampleTxn (expenseFor foodCat))
      `shouldNotSatisfy` T.isInfixOf "Labels:"
```

Wire `recordedSpec` into the module's `spec`: change the top-level `spec` so it runs both blocks, e.g.

```haskell
spec :: Spec
spec = do
  lineSpec
  recordedSpec
```

renaming the existing `describe "formatTransactionLine" $ do …` binding to `lineSpec :: Spec` (or keep it inline and just append `recordedSpec` under the same `spec = do`). Ensure only one `spec` is exported.

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test all --test-option='--match' --test-option="/formatRecordedTransaction/"`
Expected: FAIL — `formatRecordedTransaction` not in scope / not exported.

- [ ] **Step 3: Implement the renderer**

In `src/Telegram/Formatting.hs`: add `formatRecordedTransaction` to the module export list (under "Value Renderers" or a new "Confirmation Renderer" section). Extend imports:
- `Domain.Core.Types`: add `AccountId`, `exchangeRateValue`, `unAccountId` to the existing import list (keep `Allocation (..)`, `Currency (..)`, `Money`, `TransactionType (..)`, `allAllocations`, `moneyCurrency`, `unMoney`).
- add `import Data.Maybe (fromMaybe)`
- add `import qualified Data.UUID as UUID`
- `Data.Map.Strict`, `Data.Set`, `Data.List (sort)`, `Numeric (showFFloat)`, `Domain.Transaction.Projection (TransactionStatus (..))` are already imported.

```haskell
-- | Render a just-recorded transaction as a multi-line confirmation used by
-- all Telegram recording paths (/income, /expense, /transfer, and the
-- natural-language prompt). @entryNames@ resolves category and label ids;
-- @accountNames@ resolves the user's own account ids. Both maps degrade
-- gracefully: an unresolved category falls back to the bare amount, an
-- unresolved account is dropped (expense/income) or shown as a short id
-- (transfer, to preserve the @A -> B@ arrow). Total over all
-- 'TransactionType' and 'TransactionStatus' constructors.
formatRecordedTransaction ::
  Map DictionaryEntryId Text ->
  Map AccountId Text ->
  TransactionData ->
  Text
formatRecordedTransaction entryNames accountNames td =
  case td.transactionType of
    Income allocs -> categorised "Income" td.targetAmount td.targetAccountId allocs
    Expense allocs -> categorised "Expense" td.sourceAmount td.sourceAccountId allocs
    Transfer -> transfer
    Adjustment -> adjustment
  where
    header :: Text -> Text
    header kind = "\9989 " <> kind <> " recorded" <> statusMarker

    statusMarker :: Text
    statusMarker = case td.status of
      Completed -> ""
      Pending -> "  [Pending]"
      Cancelled -> "  [Cancelled]"
      Failed reason -> "  [Failed: " <> reason <> "]"

    amountText :: Money -> Text
    amountText m = formatMoney m <> " " <> showCurrency (moneyCurrency m)

    accountSuffix :: AccountId -> Text
    accountSuffix aid = maybe "" (\n -> " \xB7 " <> n) (Map.lookup aid accountNames)

    accountRef :: AccountId -> Text
    accountRef aid =
      fromMaybe
        (T.take 8 (T.pack (UUID.toString (unAccountId aid))))
        (Map.lookup aid accountNames)

    labelLines :: [Text]
    labelLines =
      let ns = sort [n | lid <- Set.toList td.labels, Just n <- [Map.lookup lid entryNames]]
       in [ "Labels: " <> T.intercalate ", " ns | not (null ns)]

    bullet :: Allocation -> Text
    bullet a =
      let amt = formatMoney a.amount
          labelled = case Map.lookup a.categoryId entryNames of
            Just n -> n <> " " <> amt
            Nothing -> amt
          tail_ = case a.comment of
            Just c | not (T.null c) -> " \x2014 " <> c
            _ -> ""
       in "\x2022 " <> labelled <> tail_

    categorised :: Text -> Money -> AccountId -> Allocations -> Text
    categorised kind total accId allocs =
      T.intercalate "\n" $
        [ header kind,
          amountText total <> accountSuffix accId
        ]
          <> fmap bullet (allAllocations allocs)
          <> labelLines
          <> [formatDate td.date]

    transfer :: Text
    transfer =
      let crossCurrency = moneyCurrency td.sourceAmount /= moneyCurrency td.targetAmount
          amountLine =
            if crossCurrency
              then amountText td.sourceAmount <> " \x2192 " <> amountText td.targetAmount
              else amountText td.sourceAmount
          rateLines = case td.exchangeRate of
            Just er | crossCurrency -> ["Rate: " <> formatRate (exchangeRateValue er)]
            _ -> []
       in T.intercalate "\n" $
            [ header "Transfer",
              accountRef td.sourceAccountId <> " \x2192 " <> accountRef td.targetAccountId,
              amountLine
            ]
              <> rateLines
              <> labelLines
              <> [formatDate td.date]

    adjustment :: Text
    adjustment =
      T.intercalate "\n" $
        [ header "Adjustment",
          amountText td.sourceAmount <> accountSuffix td.sourceAccountId
        ]
          <> labelLines
          <> [formatDate td.date]

-- | Render an exchange rate to two decimal places.
formatRate :: Rational -> Text
formatRate r = T.pack $ showFFloat (Just 2) (fromRational r :: Double) ""
```

Note: `DictionaryEntryId` and `CategoryId` and `LabelId` are the same underlying type; `td.labels :: Set LabelId` and the map is keyed by `DictionaryEntryId` — the existing `formatTransactionLine` already looks labels up in that same map, so the key types unify. If the compiler complains about the `labelLines` lookup key type, mirror exactly what `formatTransactionLine` does (it uses the same `Map DictionaryEntryId Text` for both categories and labels).

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test all --test-option='--match' --test-option="/formatRecordedTransaction/"`
Expected: PASS (all `formatRecordedTransaction` examples green).

- [ ] **Step 5: Full build + format + lint**

Run: `just build && just check`
Expected: compiles clean; ormolu makes no changes (or accept its reflow); hlint clean.

- [ ] **Step 6: Commit**

```bash
git add src/Telegram/Formatting.hs test/Telegram/FormattingSpec.hs
git commit -m "feat(telegram): add shared recorded-transaction renderer"
```

---

## Task 3: Effectful helper + wire all four call sites

**Files:**
- Modify: `src/Telegram/Commands.hs` — add `replyRecordedTransaction`; replace the four success replies; update the `formatMoney`/`showCurrency` imports if they become unused.

- [ ] **Step 1: Add the effectful helper**

Near the other lookup helpers (e.g. after `getDictionaryEntryNames`, ~`:846`), add:

```haskell
-- | Send the shared, structured confirmation for a just-recorded
-- transaction. Resolves category/label names and the user's own account
-- names from existing read-model helpers, then delegates rendering to the
-- pure 'formatRecordedTransaction'. The displayed account is always the
-- user's own regular account (source for expense, target for income, both
-- for transfer), so 'getUserRegularAccounts' suffices — no External-account
-- lookup is needed.
replyRecordedTransaction :: TVar BotState -> TelegramId -> Int64 -> TransactionData -> AppM ()
replyRecordedTransaction _botState telegramId chatId td = do
  entryNames <- getDictionaryEntryNames telegramId
  maybeAccounts <- getUserRegularAccounts telegramId
  let accountNames =
        Map.fromList [(aid, n) | (aid, n, _) <- fromMaybe [] maybeAccounts]
  sendMsg chatId (formatRecordedTransaction entryNames accountNames td)
```

Notes:
- Drop the `_botState` parameter entirely if the compiler shows it is unused (per the repo's "no underscore params" preference — prefer removing an unused param over `_`-prefixing). It is included above only in case a caller finds it ergonomic; the simplest signature is `replyRecordedTransaction :: TelegramId -> Int64 -> TransactionData -> AppM ()`. Use that unless a call site needs bot state.
- Ensure `formatRecordedTransaction` is imported from `Telegram.Formatting` (add to the existing import list at ~`:110`), and `fromMaybe` is in scope (RIO exports it; otherwise add `import Data.Maybe (fromMaybe)`).

Adopt the no-param signature:

```haskell
replyRecordedTransaction :: TelegramId -> Int64 -> TransactionData -> AppM ()
replyRecordedTransaction telegramId chatId td = do
  entryNames <- getDictionaryEntryNames telegramId
  maybeAccounts <- getUserRegularAccounts telegramId
  let accountNames =
        Map.fromList [(aid, n) | (aid, n, _) <- fromMaybe [] maybeAccounts]
  sendMsg chatId (formatRecordedTransaction entryNames accountNames td)
```

- [ ] **Step 2: Wire `/income`**

In `handleIncomeDescription` (~`:625-630`), replace the success branch:

```haskell
                    _ ->
                      sendMsg chatId $ "Income recorded: " <> formatMoney money <> " " <> showCurrency (moneyCurrency money)
```

with:

```haskell
                    _ ->
                      replyRecordedTransaction telegramId chatId txData
```

- [ ] **Step 3: Wire `/expense`**

In `handleExpenseDescription` (~`:697-702`), replace the success branch analogously with `replyRecordedTransaction telegramId chatId txData`.

- [ ] **Step 4: Wire `/transfer`**

In `handleTransferDescription` (~`:770-775`), replace the success branch:

```haskell
          _ ->
            sendMsg chatId $ "Transfer completed: " <> formatMoney money <> " " <> showCurrency (moneyCurrency money)
```

with `replyRecordedTransaction telegramId chatId txData`.

> `handleTransferDescription` currently takes `telegramId` — confirm it is in scope (it is, per its signature `:758`). Same for income/expense handlers.

- [ ] **Step 5: Wire the NL prompt path**

In `handlePromptText` (formerly `runPrompt`, ~`:498-500`), replace:

```haskell
        Right (TransactionCreated interp _ _) ->
          sendMsg chatId ("\9989 " <> interp)
```

with:

```haskell
        Right (TransactionCreated _interp _txId txData) ->
          replyRecordedTransaction telegramId chatId txData
```

`handlePromptText` has `telegramId` in scope (its own parameter). The `interp` value is now unused — bind it as `_interp` (matching the shared-signature pattern-match; the other fields are already `_`).

- [ ] **Step 6: Clean up now-unused imports**

Run: `just build`
If `-Werror` flags `formatMoney`/`showCurrency`/`moneyCurrency` as unused in `Commands.hs`, remove them from that module's import list (they are still used inside `Telegram.Formatting`, unaffected). If they are still used elsewhere in `Commands.hs`, leave them.
Expected after cleanup: compiles clean, no warnings.

- [ ] **Step 7: Run the full test suite**

Run: `just test`
Expected: pass. Note per project memory: a full `cabal test all` needs a manually-created `eventium_test` Postgres DB; ~28 integration failures without it are environmental, not regressions. The relevant unit tests (`Telegram.FormattingSpec`, `Telegram.CommandsSpec`) must pass regardless.

- [ ] **Step 8: Commit**

```bash
git add src/Telegram/Commands.hs
git commit -m "feat(telegram): confirm recorded transactions via shared renderer"
```

---

## Task 4: Final verification

- [ ] **Step 1: Definitive clean build**

Run: `just rebuild`
Expected: clean `-fci` build from scratch — proves no `-Werror` regression masked by the incremental cache.

- [ ] **Step 2: Format + lint**

Run: `just check`
Expected: ormolu reports no changes (or its reflow is committed); hlint clean, no new suppressions.

- [ ] **Step 3: Targeted test replay**

Run: `cabal test all --test-option='--match' --test-option="/Telegram/"`
Expected: all Telegram specs pass.

- [ ] **Step 4: Manual sanity (optional, if a bot token + DB are available)**

Record one of each via Telegram (`/expense`, `/income`, `/transfer`, and a free-text prompt) and confirm each reply uses the `✅ <Kind> recorded` layout with account, allocation bullets, and date. See `docs/deployment.md` for running the bot locally.

- [ ] **Step 5: Verify no stale references**

Run: `grep -rn "recorded: \|Transfer completed:\|runPrompt" src/`
Expected: no matches — the old bespoke reply strings and the old handler name are gone.

---

## Definition of Done

- All four Telegram paths reply with the shared `formatRecordedTransaction` output.
- `runPrompt` renamed to `handlePromptText`; NL path no longer sends the LLM `interp` string.
- `just rebuild` and `just check` clean; `Telegram.FormattingSpec` / `Telegram.CommandsSpec` green.
- Renderer is total over all `TransactionType` / `TransactionStatus` constructors.
