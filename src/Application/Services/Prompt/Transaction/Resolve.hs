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

import Application.Services.Prompt.Transaction.Intent
  ( IntentKind (..),
    TransactionIntent (..),
  )
import Application.Services.Prompt.Types (ResolveError (..))
import Data.Scientific (Scientific)
import qualified Data.Set as Set
import qualified Data.Text as DT
import Data.Text.Match (MatchResult (..), matchByName)
import Data.Time (UTCTime (..), defaultTimeLocale, parseTimeM)
import Data.Time.Calendar (Day)
import Domain.Core.Types
  ( AccountId,
    Allocations,
    CategoryId,
    Currency,
    LabelId,
    Money,
    mkAllocation,
    mkAllocations,
    mkMoney,
    parseCurrency,
  )
import RIO
import qualified RIO.Text as T

-- | The user's real data the resolver matches the intent against. Every list is
-- the canonical set the LLM was told to choose from; defaults cover the "no
-- category matched" fallback.
data ResolveContext = ResolveContext
  { -- | @(id, canonical name, native currency)@ per account.
    accounts :: ![(AccountId, Text, Currency)],
    incomeCategories :: ![(CategoryId, Text)],
    expenseCategories :: ![(CategoryId, Text)],
    labels :: ![(LabelId, Text)],
    defaultIncomeCategory :: !(Maybe CategoryId),
    defaultExpenseCategory :: !(Maybe CategoryId)
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
  ExpenseKind -> resolveExpense ctx prompt ti
  IncomeKind -> resolveIncome ctx prompt ti
  TransferKind -> resolveTransfer ctx prompt ti

resolveExpense :: ResolveContext -> Text -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveExpense ctx prompt ti = do
  (aid, aname, acur) <- resolveAccount ctx "sourceAccount" ti.sourceAccount
  currency <- resolveCurrency acur ti.currency
  money <- resolveAmount currency ti.amount
  cid <- resolveCategory ti.category ctx.expenseCategories ctx.defaultExpenseCategory
  allocs <- buildAllocations ExpenseKind cid money
  cname <- categoryName ctx.expenseCategories cid
  mdate <- resolveDate ti.date
  let desc = resolveDescription prompt ti.description
      interp = "Expense " <> amountText ti.amount <> " " <> tshow currency <> " from ‘" <> aname <> "’, category " <> cname
  Right (ResolvedExpense aid money allocs Set.empty desc mdate, interp)

resolveIncome :: ResolveContext -> Text -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveIncome ctx prompt ti = do
  (aid, aname, acur) <- resolveAccount ctx "targetAccount" ti.targetAccount
  currency <- resolveCurrency acur ti.currency
  money <- resolveAmount currency ti.amount
  cid <- resolveCategory ti.category ctx.incomeCategories ctx.defaultIncomeCategory
  allocs <- buildAllocations IncomeKind cid money
  cname <- categoryName ctx.incomeCategories cid
  mdate <- resolveDate ti.date
  let desc = resolveDescription prompt ti.description
      interp = "Income " <> amountText ti.amount <> " " <> tshow currency <> " to ‘" <> aname <> "’, category " <> cname
  Right (ResolvedIncome aid money allocs Set.empty desc mdate, interp)

resolveTransfer :: ResolveContext -> Text -> TransactionIntent -> Either ResolveError (Resolved, Text)
resolveTransfer ctx prompt ti = do
  (src, sname, scur) <- resolveAccount ctx "sourceAccount" ti.sourceAccount
  (tgt, tname, _) <- case ti.targetAccount of
    Nothing -> Left (ResolveError "targetAccount" "transfer needs a destination account")
    Just _ -> resolveAccount ctx "targetAccount" ti.targetAccount
  currency <- resolveCurrency scur ti.currency
  money <- resolveAmount currency ti.amount
  mdate <- resolveDate ti.date
  let desc = resolveDescription prompt ti.description
      interp = "Transfer " <> amountText ti.amount <> " " <> tshow currency <> " from ‘" <> sname <> "’ to ‘" <> tname <> "’"
  Right (ResolvedTransfer src tgt money Set.empty desc mdate, interp)

-- | Resolve an account name against the context, or fail on the given field.
resolveAccount ::
  ResolveContext ->
  Text ->
  Maybe Text ->
  Either ResolveError (AccountId, Text, Currency)
resolveAccount ctx fld = \case
  Nothing -> Left (ResolveError fld "no account specified")
  Just name -> case matchByName (\(_, n, _) -> n) name ctx.accounts of
    Matched acc -> Right acc
    NoMatch ->
      Left (ResolveError fld ("No account matches '" <> name <> "'. Your accounts: " <> accountNames))
    Ambiguous _ ->
      Left (ResolveError fld ("Account name '" <> name <> "' is ambiguous. Your accounts: " <> accountNames))
  where
    accountNames = T.intercalate ", " [n | (_, n, _) <- ctx.accounts]

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

-- | Build the single-allocation 'Allocations' for the kind.
buildAllocations :: IntentKind -> CategoryId -> Money -> Either ResolveError Allocations
buildAllocations kind cid money = do
  alloc <- first toResolveErr (mkAllocation cid money)
  let (incs, exps) = case kind of
        IncomeKind -> ([alloc], [])
        _ -> ([], [alloc])
  first toResolveErr (mkAllocations incs exps)
  where
    toResolveErr err = ResolveError "allocations" (tshow err)

-- | The canonical name for a resolved category id (falls back to the id text).
categoryName :: [(CategoryId, Text)] -> CategoryId -> Either ResolveError Text
categoryName cats cid = Right (fromMaybe (tshow cid) (lookup cid cats))

-- | Strict ISO @YYYY-MM-DD@ parse to a 'UTCTime' at midnight.
resolveDate :: Maybe Text -> Either ResolveError (Maybe UTCTime)
resolveDate = \case
  Nothing -> Right Nothing
  Just s -> case parseTimeM True defaultTimeLocale "%Y-%m-%d" (T.unpack s) :: Maybe Day of
    Just day -> Right (Just (UTCTime day 0))
    Nothing -> Left (ResolveError "date" ("Cannot parse date '" <> s <> "' (expected YYYY-MM-DD)"))

-- | The intent description if present and non-blank, else the original prompt.
resolveDescription :: Text -> Maybe Text -> Text
resolveDescription prompt = \case
  Just d | not (T.null (T.strip d)) -> d
  _ -> prompt
