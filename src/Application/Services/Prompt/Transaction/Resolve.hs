{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Transaction.Resolve
-- Description : Pure resolution of a decoded 'TransactionIntent' into concrete,
--               validated values against the user's real data.
--
-- This is the accuracy-critical core of the @create_transaction@ intent. It is
-- __pure__ (no IO, no notion of "now"): given the user's accounts, categories,
-- and labels, it turns the LLM's text payload into a fully-resolved 'Resolved'
-- value plus a human-readable interpretation, or short-circuits to a
-- 'ResolveError' naming the offending field.
--
-- Resolution follows the design's rules table (§5): name matching for accounts
-- and categories, currency defaulting to the account's native currency, decimal
-- normalization (comma → dot), strict ISO date parsing, and a category default
-- fallback. Labels are a reserved slot (empty in v1). All domain construction
-- goes through the smart constructors so the domain invariants hold.
module Application.Services.Prompt.Transaction.Resolve
  ( ResolveContext (..),
    Resolved (..),
    resolveIntent,
  )
where

import Application.ReadModels.Account (RegularAccountData (..))
import Application.Services.Prompt.Transaction.Intent
  ( IntentAllocation (..),
    IntentKind (..),
    TransactionIntent (..),
  )
import Application.Services.Prompt.Types (ResolveError (..))
import qualified Data.Map.Strict as Map
import Data.Ratio (denominator, numerator)
import Data.Scientific (Scientific)
import qualified Data.Set as Set
import qualified Data.Text as DT
import Data.Text.Match (MatchResult (..), matchByName)
import Data.Time (UTCTime (..), defaultTimeLocale, parseTimeM)
import Data.Time.Calendar (Day)
import Domain.Configuration.Projection (ConfigurationDefaults (..))
import Domain.Core.Types
  ( AccountId,
    AccountSubtypeKind (..),
    Allocations,
    CategoryId,
    Currency,
    LabelId,
    Money,
    mkAllocation,
    mkAllocations,
    mkMoney,
    moneyCurrency,
    parseCurrency,
    unMoney,
  )
import Numeric (showFFloat)
import RIO
import qualified RIO.Text as T

-- | The user's real data the resolver matches the intent against. Every list is
-- the canonical set the LLM was told to choose from; defaults cover the "no
-- category matched" fallback.
data ResolveContext = ResolveContext
  { -- | The user's regular accounts (id, name, native currency via balance,
    -- and subtype kind), reusing the account read model's projection. The id
    -- is carried outside 'RegularAccountData', matching every other
    -- read-model @*Data@ convention.
    accounts :: ![(AccountId, RegularAccountData)],
    incomeCategories :: ![(CategoryId, Text)],
    expenseCategories :: ![(CategoryId, Text)],
    labels :: ![(LabelId, Text)],
    -- | The user's configured defaults (category + account), reused verbatim
    -- from the configuration read model.
    defaults :: !ConfigurationDefaults,
    -- | The account the client currently has selected (issue #28), if any.
    -- When set and valid, it fills the transaction's __primary__ account slot
    -- (source for expense/transfer, target for income), overriding the
    -- resolver's inference — but an explicit account __name__ in the prompt
    -- still wins over it. An unknown id here is ignored (falls back to
    -- inference). Never fills a transfer's destination.
    selectedAccount :: !(Maybe AccountId)
  }

-- | A fully-resolved, validated transaction ready for the write path.
--
-- The 'AccountId' role differs per constructor: for 'ResolvedIncome' it is the
-- __target__ (money enters it); for 'ResolvedExpense' the __source__; for
-- 'ResolvedTransfer' the two ids are __source then target__. Positional (not
-- record) to sidestep partial field selectors across constructors.
data Resolved
  = ResolvedIncome AccountId Money Allocations (Set LabelId) Text (Maybe UTCTime)
  | ResolvedExpense AccountId Money Allocations (Set LabelId) Text (Maybe UTCTime)
  | ResolvedTransfer AccountId AccountId Money (Set LabelId) Text (Maybe UTCTime)
  deriving (Show, Eq)

-- | Resolve a decoded intent against the user's data.
--
-- The second argument is the original user prompt, used as the description
-- fallback. Returns the 'Resolved' value paired with a human-readable
-- interpretation, or the first 'ResolveError' encountered.
resolveIntent :: ResolveContext -> Text -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveIntent ctx prompt ti = case ti.kind of
  ExpenseKind -> resolveExpense ctx ti
  IncomeKind -> resolveIncome ctx ti
  TransferKind -> resolveTransfer ctx prompt ti

resolveExpense :: ResolveContext -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveExpense ctx ti = do
  (aid, aname, acur) <- resolvePrimaryAccount ctx "sourceAccount" ti.sourceAccount
  currency <- resolveCurrency acur ti.currency
  lns <- resolveAllocLines currency ctx.expenseCategories ctx.defaults.expenseCategory ti.allocations
  (money, allocs) <- buildAllocations ExpenseKind currency lns
  mdate <- resolveDate ti.date
  let desc = resolveDescription (summariseAllocations ctx.expenseCategories lns) ti.description
      interp =
        "Expense "
          <> showAmount (unMoney money)
          <> " "
          <> tshow currency
          <> " from ‘"
          <> aname
          <> "’, "
          <> tshow (length lns)
          <> " item(s)"
  Right (ResolvedExpense aid money allocs Set.empty desc mdate, interp)

resolveIncome :: ResolveContext -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveIncome ctx ti = do
  (aid, aname, acur) <- resolvePrimaryAccount ctx "targetAccount" ti.targetAccount
  currency <- resolveCurrency acur ti.currency
  lns <- resolveAllocLines currency ctx.incomeCategories ctx.defaults.incomeCategory ti.allocations
  (money, allocs) <- buildAllocations IncomeKind currency lns
  mdate <- resolveDate ti.date
  let desc = resolveDescription (summariseAllocations ctx.incomeCategories lns) ti.description
      interp =
        "Income "
          <> showAmount (unMoney money)
          <> " "
          <> tshow currency
          <> " to ‘"
          <> aname
          <> "’, "
          <> tshow (length lns)
          <> " item(s)"
  Right (ResolvedIncome aid money allocs Set.empty desc mdate, interp)

resolveTransfer :: ResolveContext -> Text -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveTransfer ctx prompt ti = do
  (src, sname, scur) <- resolvePrimaryAccount ctx "sourceAccount" ti.sourceAccount
  (tgt, tname, _) <- case ti.targetAccount of
    Nothing -> Left (ResolveError "targetAccount" "transfer needs a destination account")
    Just _ -> resolveAccount ctx "targetAccount" ti.targetAccount
  currency <- resolveCurrency scur ti.currency
  amt <- maybe (Left (ResolveError "amount" "transfer needs an amount")) Right ti.amount
  money <- resolveAmount currency amt
  mdate <- resolveDate ti.date
  let desc = resolveDescription prompt ti.description
      interp = "Transfer " <> amountText amt <> " " <> tshow currency <> " from ‘" <> sname <> "’ to ‘" <> tname <> "’"
  Right (ResolvedTransfer src tgt money Set.empty desc mdate, interp)

-- | Resolve the transaction's __primary__ (own-side) account, honouring a
-- client selection (issue #28). Precedence:
--
--   1. an explicit account __name__ in the prompt that matches a real account
--      wins (the user's words outrank ambient UI state);
--   2. else a valid 'selectedAccount' takes the slot, overriding inference;
--   3. else fall back to the #26 'resolveAccount' inference ladder.
--
-- Used only for the primary slot (source for expense/transfer, target for
-- income); a transfer's destination always goes through 'resolveAccount' so the
-- selection can never fill it.
resolvePrimaryAccount ::
  ResolveContext ->
  Text ->
  Maybe Text ->
  Either ResolveError (AccountId, Text, Currency)
resolvePrimaryAccount ctx fld mname
  | Just acc <- mname >>= explicitMatch = Right acc
  | Just acc <- ctx.selectedAccount >>= accountById ctx = Right acc
  | otherwise = resolveAccount ctx fld mname
  where
    explicitMatch name = case matchByName accountName name ctx.accounts of
      Matched a -> Just (projectAccount a)
      _ -> Nothing

-- | The name projection used to match accounts by name, over the
-- @(id, data)@ pairs 'ResolveContext.accounts' now carries.
accountName :: (AccountId, RegularAccountData) -> Text
accountName (_, a) = a.name

-- | Project a resolved account to @(id, canonical name, native currency)@.
projectAccount :: (AccountId, RegularAccountData) -> (AccountId, Text, Currency)
projectAccount (aid, a) = (aid, a.name, moneyCurrency a.balance)

-- | Look up one of the user's accounts by id, projected. 'Nothing' when the id
-- is not among the user's regular accounts (e.g. a stale selection).
accountById :: ResolveContext -> AccountId -> Maybe (AccountId, Text, Currency)
accountById ctx aid = case [a | a@(i, _) <- ctx.accounts, i == aid] of
  (a : _) -> Just (projectAccount a)
  [] -> Nothing

-- | Resolve an account reference against the context. Precedence:
--
--   1. an exact/unique account __name__ match wins;
--   2. else, if the text is a __subtype keyword__ ("cash"/"bank"/"card"/"wallet"),
--      that subtype's default account, else the unique account of that subtype;
--   3. else the __global__ default account — also the "omitted account" case, and
--      the fallback for an __ambiguous__ or __unknown__ reference;
--   4. else — only when no default account is configured at all — error.
--
-- Recording to a default beats failing (product decision): an ambiguous match
-- (e.g. "card" when several accounts are named "… card", which name-matching
-- alone reports as ambiguous) or an otherwise-unknown name falls back to the
-- per-type default and then the global default rather than erroring. Returns
-- @(id, canonical name, native currency)@, dropping the subtype kind.
resolveAccount ::
  ResolveContext ->
  Text ->
  Maybe Text ->
  Either ResolveError (AccountId, Text, Currency)
resolveAccount ctx fld = \case
  -- Omitted account: global default, else a clean "not specified".
  Nothing -> maybe (Left (ResolveError fld "no account specified")) Right globalDefault
  Just name -> case matchByName accountName name ctx.accounts of
    Matched acc -> Right (projectAccount acc)
    Ambiguous _ -> fallback name (ambiguousErr name)
    NoMatch -> fallback name (noMatch name)
  where
    accountNames = T.intercalate ", " [a.name | (_, a) <- ctx.accounts]
    ambiguousErr name = ResolveError fld ("Account name '" <> name <> "' is ambiguous. Your accounts: " <> accountNames)
    noMatch name = ResolveError fld ("No account matches '" <> name <> "'. Your accounts: " <> accountNames)
    globalDefault = ctx.defaults.account >>= accountById ctx
    subtypeDefault kind = Map.lookup kind ctx.defaults.subtypeAccounts >>= accountById ctx
    accountsOfKind kind = [a | a@(_, r) <- ctx.accounts, r.subtype == kind]
    -- No exact/unique name matched. Prefer the account for a recognised subtype
    -- keyword (its default, else the unique account of that kind); otherwise, and
    -- as the final fallback, the global default. Only fail (@onFail@) when there
    -- is no default account to record to.
    fallback name onFail = case subtypeAccount =<< keywordSubtype name of
      Just acc -> Right acc
      Nothing -> maybe (Left onFail) Right globalDefault
    subtypeAccount kind = case subtypeDefault kind of
      Just acc -> Just acc
      Nothing -> case accountsOfKind kind of
        [only] -> Just (projectAccount only)
        _ -> Nothing

-- | Recognise an account-subtype keyword in the free-text account field. The
-- @card@ keyword aliases 'BankAccountKind' (cards are typically bank cards).
-- Match is case-insensitive and substring-based; e-wallet checked before bank
-- so "wallet" never falls through.
keywordSubtype :: Text -> Maybe AccountSubtypeKind
keywordSubtype t
  | any (`T.isInfixOf` s) ["e-wallet", "ewallet", "wallet"] = Just EWalletKind
  | any (`T.isInfixOf` s) ["bank", "card"] = Just BankAccountKind
  | "cash" `T.isInfixOf` s = Just CashKind
  | otherwise = Nothing
  where
    s = T.toLower (T.strip t)

-- | Explicit currency (parsed) or the account's native currency.
resolveCurrency :: Currency -> Maybe Text -> Either ResolveError Currency
resolveCurrency native = \case
  Nothing -> Right native
  Just c -> first (ResolveError "currency") (parseCurrency c)

-- | Normalize (comma → dot), parse to a positive number, and build 'Money'.
--
-- Parsing goes through 'Scientific' (exact for decimal literals) rather than
-- 'Double', so decimal strings like @"0.1"@ become the exact 'Rational' @1/10@
-- with no binary-float rounding — 'Money' is a 'Rational' and the rest of the
-- pipeline is exact.
resolveAmount :: Currency -> Text -> Either ResolveError Money
resolveAmount currency raw =
  case readMaybe (T.unpack (amountText raw)) :: Maybe Scientific of
    Nothing -> Left (ResolveError "amount" ("Cannot read amount '" <> raw <> "'"))
    Just sci
      | sci <= 0 -> Left (ResolveError "amount" "amount must be positive")
      | otherwise -> first (ResolveError "amount") (mkMoney currency (toRational sci))

-- | The amount text with the decimal separator normalized and trimmed.
amountText :: Text -> Text
amountText = T.strip . DT.replace "," "."

-- | Render a money amount for the human-readable interpretation string:
-- whole numbers show without decimals, fractional amounts to 2 places.
showAmount :: Rational -> Text
showAmount r
  | denominator r == 1 = tshow (numerator r)
  | otherwise = T.pack (showFFloat (Just 2) (fromRational r :: Double) "")

-- | Match a category within the kind's list, else fall back to the default.
resolveCategory ::
  Maybe Text ->
  [(CategoryId, Text)] ->
  Maybe CategoryId ->
  Either ResolveError CategoryId
resolveCategory mName cats def = case mName >>= matched of
  Just cid -> Right cid
  Nothing -> case def of
    Just cid -> Right cid
    Nothing -> Left (ResolveError "category" "no matching category and no default configured")
  where
    matched name = case matchByName snd name cats of
      Matched (cid, _) -> Just cid
      _ -> Nothing

-- | Resolve each line's category (match → default) into (categoryId, money, comment).
resolveAllocLines ::
  Currency ->
  [(CategoryId, Text)] ->
  Maybe CategoryId ->
  [IntentAllocation] ->
  Either ResolveError [(CategoryId, Money, Maybe Text)]
resolveAllocLines currency cats def =
  traverse $ \ia -> do
    money <- resolveAmount currency ia.amount
    cid <- resolveCategory ia.category cats def
    pure (cid, money, ia.comment)

-- | Build the kind's 'Allocations' from resolved lines and derive the total.
buildAllocations ::
  IntentKind ->
  Currency ->
  [(CategoryId, Money, Maybe Text)] ->
  Either ResolveError (Money, Allocations)
buildAllocations kind currency lns = do
  allocs <- traverse (\(cid, m, cmt) -> first toResolveErr (mkAllocation cid m cmt)) lns
  let (incs, exps) = case kind of
        IncomeKind -> (allocs, [])
        ExpenseKind -> ([], allocs)
        TransferKind -> ([], allocs) -- unreachable: transfer uses resolveTransfer
  as <- first toResolveErr (mkAllocations incs exps) -- rejects empty list (both buckets empty)
  total <- first (ResolveError "amount") (mkMoney currency (sum [unMoney m | (_, m, _) <- lns]))
  pure (total, as)
  where
    toResolveErr err = ResolveError "allocations" (tshow err)

-- | Strict ISO @YYYY-MM-DD@ parse to a 'UTCTime' at midnight.
resolveDate :: Maybe Text -> Either ResolveError (Maybe UTCTime)
resolveDate = \case
  Nothing -> Right Nothing
  Just s -> case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack s) :: Maybe Day of
    Just day -> Right (Just (UTCTime day 0))
    Nothing -> Left (ResolveError "date" ("Cannot parse date '" <> s <> "' (expected YYYY-MM-DD)"))

-- | The intent description if present and non-blank, else the given fallback
-- (an allocation summary for income/expense, the original prompt for transfer).
resolveDescription :: Text -> Maybe Text -> Text
resolveDescription fallback = \case
  Just d | not (T.null (T.strip d)) -> d
  _ -> fallback

-- | A short human summary of the resolved allocation lines, used as the
-- transaction description when the model didn't supply one: each line's
-- comment if present, else its category name, joined by ", ".
--
-- Callers guarantee @lns@ is non-empty ('buildAllocations' rejects the empty
-- case), so the join is never @""@.
summariseAllocations :: [(CategoryId, Text)] -> [(CategoryId, Money, Maybe Text)] -> Text
summariseAllocations cats =
  T.intercalate ", " . map lineLabel
  where
    lineLabel (cid, _, mcmt) = fromMaybe (categoryLabel cid) mcmt
    categoryLabel cid = fromMaybe "Other" (lookup cid cats)
