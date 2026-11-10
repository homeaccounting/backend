{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Transaction.Types
-- Description : Transaction type and category allocations
--
-- The categorised shape of a transaction ('TransactionType') and its
-- category 'Allocations', with the smart constructors that enforce their
-- invariants. Transaction-specific, so it lives in the Transaction context
-- rather than the shared 'Domain.Core.Types' kernel.
module Domain.Transaction.Types
  ( TransactionType (..),
    TransactionKind (..),
    kindOf,
    deriveTransactionKind,
    mkIncome,
    mkExpense,
    mkTransfer,
    transferFeeTotal,
    transferNetAmount,
    transferGrossAmount,
    allocationsTotal,
    allocationsOf,
    isCategorised,
    validateAllocations,
    replaceAllocations,
    Allocation (..),
    mkAllocation,
    Allocations (..),
    mkAllocations,
    mkIncomeAllocations,
    mkExpenseAllocations,
    mkMixedAllocations,
    allAllocations,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.List.NonEmpty (NonEmpty, toList)
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types (AccountType (..), CategoryId, Currency, Money (..), mkMoney, unMoney)
import GHC.Generics (Generic)

-- | A single category slice of a transaction's categorised amount.
--
-- An 'Allocation' associates a portion of a transaction's total amount
-- with a category. Allocations are the building blocks of multi-category
-- splits: a 1000 UAH grocery purchase that is 200 UAH food and 800 UAH
-- housekeeping has two Allocations summing to 1000 UAH.
--
-- Invariants (enforced by the smart constructors of 'TransactionType' that
-- wrap allocation lists):
--
--   * amount > 0 (strict positivity)
--   * all allocations on one transaction share a 'Currency'
--   * sum of amounts equals the categorised total of the transaction

{-@
data Allocation = Allocation
  { categoryId :: CategoryId
  , amount     :: {m : Money | (amount m) > 0}
  , comment    :: Maybe Text
  }
@-}
data Allocation = Allocation
  { categoryId :: CategoryId,
    amount :: Money,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON Allocation

instance FromJSON Allocation

-- | Smart constructor for an 'Allocation'. Enforces @amount > 0@; the
-- optional comment is trimmed and blank text normalizes to 'Nothing'.
--
-- >>> import Data.UUID (fromWords)
-- >>> let c = unsafeDictionaryEntryId (fromWords 1 0 0 0)
-- >>> let Right m = mkDefaultMoney 10
-- >>> fmap (.amount) (mkAllocation c m Nothing)
-- Right (Money {amount = 10 % 1, currency = USD})
mkAllocation :: CategoryId -> Money -> Maybe Text -> Either DomainError Allocation
mkAllocation cid m mcomment
  | unMoney m > 0 = Right (Allocation cid m (normalizeComment mcomment))
  | otherwise =
      Left . ValidationErr $
        mkValidationError
          "amount"
          "Allocation amount must be positive"
          (T.pack (show (unMoney m)))

-- | Trim a comment; blank / whitespace-only becomes 'Nothing'.
normalizeComment :: Maybe Text -> Maybe Text
normalizeComment mt = do
  t <- mt
  let s = T.strip t
  if T.null s then Nothing else Just s

-- | The categorised side of a transaction, split into two buckets by the
-- dictionary the categories come from. The contra effect (a reimbursement
-- reducing an expense category) is derived from bucket + flow direction —
-- never a negative amount. Build via 'mkIncomeAllocations' /
-- 'mkExpenseAllocations' (single-bucket totals), 'mkMixedAllocations'
-- (both buckets), or 'mkAllocations' (dynamic, from possibly-empty lists).
data Allocations = Allocations
  { incomes :: [Allocation], -- categories from the income-category dict
    expenses :: [Allocation] -- categories from the expense-category dict
  }
  deriving (Show, Eq, Generic)

instance ToJSON Allocations

instance FromJSON Allocations

-- | All allocations regardless of bucket — the categorised lines as a flat list.
allAllocations :: Allocations -> [Allocation]
allAllocations a = a.incomes <> a.expenses

-- | Smart constructor. Enforces only the cross-bucket structural invariant
-- (not both empty); per-allocation positivity, currency, and sum-vs-total
-- are checked against an anchor amount by 'validateAllocations' /
-- 'mkIncome' / 'mkExpense'. Kind-agnostic by design — directional rules
-- (no contra-income) live in the constructors/handler.
mkAllocations :: [Allocation] -> [Allocation] -> Either DomainError Allocations
mkAllocations incs exps
  | null incs && null exps = Left AllocationsEmpty
  | otherwise = Right (Allocations incs exps)

-- | Allocations entirely in the income bucket (expense bucket empty).
-- Total: 'NonEmpty' guarantees the not-both-empty invariant, so — unlike
-- the fallible 'mkAllocations' — this returns 'Allocations' directly.
mkIncomeAllocations :: NonEmpty Allocation -> Allocations
mkIncomeAllocations xs = Allocations (toList xs) []

-- | Allocations entirely in the expense bucket (income bucket empty). Total.
mkExpenseAllocations :: NonEmpty Allocation -> Allocations
mkExpenseAllocations xs = Allocations [] (toList xs)

-- | Allocations spanning both buckets (income earnings + expense
-- reimbursements), e.g. a salary transfer bundling a rent reimbursement. Total.
mkMixedAllocations :: NonEmpty Allocation -> NonEmpty Allocation -> Allocations
mkMixedAllocations incs exps = Allocations (toList incs) (toList exps)

-- | Type of transfer operation.
--
-- 'Income' and 'Expense' carry one or more 'Allocation's whose amounts
-- sum to the transaction's categorised total. Construct via 'mkIncome'
-- / 'mkExpense' smart constructors to ensure the invariants hold.
--
-- 'Transfer' (internal account-to-account) optionally carries bank fees as
-- expense-bucket 'Allocations' (see 'mkTransfer'); 'Adjustment' (balance
-- reconciliation) has no category side.
data TransactionType
  = Income Allocations
  | Expense Allocations
  | Transfer (Maybe Allocations)
  | Adjustment
  deriving (Show, Eq, Generic)

instance ToJSON TransactionType

instance FromJSON TransactionType

-- | The kind of a 'TransactionType', ignoring its payload. Used by command
-- handlers to enforce kind-preservation across edits.
data TransactionKind = IncomeKind | ExpenseKind | TransferKind | AdjustmentKind
  deriving (Show, Eq, Generic)

instance ToJSON TransactionKind

instance FromJSON TransactionKind

-- | Project a 'TransactionType' onto its 'TransactionKind' (constructor tag).
kindOf :: TransactionType -> TransactionKind
kindOf (Income _) = IncomeKind
kindOf (Expense _) = ExpenseKind
kindOf (Transfer _) = TransferKind
kindOf Adjustment = AdjustmentKind

-- | Derive the 'TransactionKind' from the account types of the two endpoints.
--
-- The mapping reflects the financial semantics of money flowing between
-- account kinds:
--
-- * @Regular → External@: money leaves the user's assets → 'ExpenseKind'
-- * @External → Regular@: money enters the user's assets → 'IncomeKind'
-- * @Regular → Regular@: money moves between user's own accounts → 'TransferKind'
-- * @External → External@: structurally unreachable for valid inputs (the
--   service layer rejects @source == target@, and every user has exactly one
--   External account). The branch is kept exhaustive to satisfy the
--   no-partial-functions rule; the result is irrelevant.
deriveTransactionKind :: AccountType -> AccountType -> TransactionKind
deriveTransactionKind (Regular _) External = ExpenseKind
deriveTransactionKind External (Regular _) = IncomeKind
deriveTransactionKind (Regular _) (Regular _) = TransferKind
deriveTransactionKind External External = TransferKind -- DEAD: unreachable; value irrelevant

-- | The allocations on a categorised 'TransactionType', 'Nothing' otherwise.
allocationsOf :: TransactionType -> Maybe Allocations
allocationsOf (Income xs) = Just xs
allocationsOf (Expense xs) = Just xs
allocationsOf (Transfer fees) = fees
allocationsOf Adjustment = Nothing

-- | True for Income / Expense / fee-carrying Transfer; False otherwise.
isCategorised :: TransactionType -> Bool
isCategorised = isJust . allocationsOf

-- | Validate an allocation list against an expected categorised total.
--
-- Returns @Right ()@ when:
--
--   * every allocation amount is strictly positive
--   * every allocation shares 'expectedTotal''s currency
--   * the sum of allocation amounts equals 'expectedTotal'
validateAllocations ::
  Money ->
  Allocations ->
  Either DomainError ()
validateAllocations expectedTotal a =
  validateAllocationItems expectedTotal.currency a *> checkSum
  where
    checkSum =
      let s = Money (allocationsTotal a) expectedTotal.currency
       in if s == expectedTotal
            then Right ()
            else
              Left . ValidationErr $
                mkValidationError "allocations" "Sum of allocations must equal categorised amount" (T.pack (show s.amount))

-- | Per-item allocation invariants shared by every categorised constructor:
-- non-empty, every amount strictly positive, every amount in 'expectedCurrency'.
validateAllocationItems :: Currency -> Allocations -> Either DomainError ()
validateAllocationItems expectedCurrency a =
  checkNotEmpty *> checkPositive *> checkCurrency
  where
    xs = allAllocations a

    checkNotEmpty
      | null xs = Left AllocationsEmpty
      | otherwise = Right ()

    checkPositive = case filter (\x -> x.amount.amount <= 0) xs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError "amount" "Allocation amount must be positive" (T.pack (show bad.amount.amount))

    checkCurrency = case filter (\x -> x.amount.currency /= expectedCurrency) xs of
      [] -> Right ()
      (bad : _) ->
        Left . ValidationErr $
          mkValidationError "currency" "All allocations must share the categorised currency" (T.pack (show bad.amount.currency))

-- | Sum of every allocation amount across both buckets.
allocationsTotal :: Allocations -> Rational
allocationsTotal a = sum (fmap (\x -> x.amount.amount) (allAllocations a))

-- | Replace the allocations payload of a categorised 'TransactionType'.
--
-- No-op on a fee-less 'Transfer' and on 'Adjustment' (no allocations to replace).
-- The new allocations must already satisfy the smart-constructor
-- invariants for the surrounding kind (sum-equals-total, currency
-- consistency, amount > 0); this helper does not re-validate.
replaceAllocations :: Allocations -> TransactionType -> TransactionType
replaceAllocations new tt = case tt of
  Income _ -> Income new
  Expense _ -> Expense new
  Transfer (Just _) -> Transfer (Just new)
  Transfer Nothing -> Transfer Nothing
  Adjustment -> Adjustment

-- | Construct a Transfer 'TransactionType' from the debited (source) amount
-- and optional fee allocations.
--
-- Fees must be expense-bucket only, positive, in the source currency, and sum
-- to strictly less than the source amount. The target-side equation depends on
-- the target account and is checked by the command handler, not here.
mkTransfer :: Money -> Maybe Allocations -> Either DomainError TransactionType
mkTransfer _ Nothing = Right (Transfer Nothing)
mkTransfer source (Just a) = do
  if null a.incomes then Right () else Left TransferFeeIncomeNotSupported
  validateAllocationItems source.currency a
  if allocationsTotal a < source.amount then Right () else Left TransferFeesNotBelowSource
  pure (Transfer (Just a))

-- | Total of the fee allocations on a 'Transfer'; 0 for anything else.
transferFeeTotal :: TransactionType -> Rational
transferFeeTotal (Transfer (Just a)) = allocationsTotal a
transferFeeTotal _ = 0

-- | The part of a transfer's debited amount that reaches the target side
-- (before any FX conversion): the debited amount less the transfer's fees.
transferNetAmount :: Money -> TransactionType -> Either DomainError Money
transferNetAmount debited tt =
  either
    (\msg -> Left (ValidationErr (mkValidationError "amount" msg (T.pack (show debited.amount)))))
    Right
    (mkMoney debited.currency (debited.amount - transferFeeTotal tt))

-- | Inverse of 'transferNetAmount': the net amount plus the transfer's fees,
-- i.e. the total debited from the source. Identity for anything but a fee
-- transfer.
transferGrossAmount :: Money -> TransactionType -> Money
transferGrossAmount net tt = Money (net.amount + transferFeeTotal tt) net.currency

-- | Construct an Income 'TransactionType'.
--
-- The categorised amount is the transaction's target-side amount
-- (the side credited by the income). The allocations must:
--
--   * carry at least one slice across both buckets ('AllocationsEmpty')
--   * each have @amount > 0@
--   * all share the same 'Currency' as the categorised total
--   * sum to the categorised total
--
-- Both buckets may be populated: a non-empty @expenses@ bucket is a
-- reimbursement (contra-expense), which is allowed on income.
mkIncome :: Money -> Allocations -> Either DomainError TransactionType
mkIncome categorisedTotal a = do
  validateAllocations categorisedTotal a
  pure (Income a)

-- | Construct an Expense 'TransactionType'.
--
-- The categorised amount is the transaction's source-side amount
-- (the side debited by the expense). Same invariants as 'mkIncome',
-- plus the directional contra rule: the @incomes@ bucket must be empty
-- (a contra-income expense is unsupported → 'ContraIncomeNotSupported').
mkExpense :: Money -> Allocations -> Either DomainError TransactionType
mkExpense categorisedTotal a = do
  validateAllocations categorisedTotal a
  if null a.incomes
    then pure (Expense a)
    else Left ContraIncomeNotSupported
