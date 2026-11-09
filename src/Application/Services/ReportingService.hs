{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ReportingService
-- Description : Pure aggregation helpers for reporting endpoints
--
-- This module contains the pure, side-effect-free aggregation core behind the
-- reporting endpoints. All functions here operate on already-materialised
-- 'TransactionData' read-model rows; the effectful service wrappers live
-- elsewhere.
--
-- == Two-bucket / reimbursement semantics
--
-- Each categorised transaction carries allocations split into two buckets:
-- @incomes@ and @expenses@. The signed contribution of an allocation to a
-- category depends on the bucket and the transaction flow direction:
--
--   * expense-bucket on an 'Domain.Core.Types.Expense' txn → @+spend@
--   * expense-bucket on an 'Domain.Core.Types.Income' txn  → @-spend@ (reimbursement / contra)
--   * income-bucket on an 'Domain.Core.Types.Income' txn   → @+income@
--   * income-bucket on an 'Domain.Core.Types.Expense' txn  → impossible
--
-- == Base-currency conversion
--
-- Allocation amounts are denominated in the user-account (regular) leg
-- currency. They are converted to base currency using the transaction's own
-- leg ratio, @external/regular@. When @exchangeRate@ is 'Nothing' the
-- transaction is same-currency (user-account currency IS base) and the
-- allocation is returned unchanged.
module Application.Services.ReportingService
  ( externalLeg,
    regularLeg,
    allocationBase,
    FeeRates,
    resolveFeeRates,
    reportableTxns,
    withVisibleFees,
    aggregateIncomeExpense,
    aggregateSpending,
    spendingByCategory,
    incomeVsExpense,
    ownedRegularOpened,
    netWorth,
  )
where

import Application.ReadModels.Account (AccountData (..), getAccountIds, getOwnedAccounts)
import Application.ReadModels.Configuration (ConfigurationData (..))
import Application.ReadModels.ExchangeRate (lookupHistoricalRate)
import Application.ReadModels.Transaction (TransactionData (..), reportableTransactions, touchesVisible)
import qualified Application.Services.ConfigurationService as ConfigurationService
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Time (Day, getCurrentTime, utctDay)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Domain.ExchangeRate.Events (Provider)
import Domain.Transaction.Projection (TransactionStatus (..))
import Infrastructure.App (AppM, appConfigL, runDb)
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import RIO
import RIO.Time (UTCTime)

-- | The base-currency leg of a transaction. For an 'Expense' (Regular→External)
-- the external leg is @targetAmount@; for an 'Income' (External→Regular) it is
-- @sourceAmount@. Other kinds have no allocations, so the value is unused.
externalLeg :: TransactionData -> Money
externalLeg td = case td.transactionType of
  Expense _ -> td.targetAmount
  Income _ -> td.sourceAmount
  _ -> td.targetAmount

-- | The user-account leg of a transaction. For an 'Expense' it is
-- @sourceAmount@; for an 'Income' it is @targetAmount@. Allocations are
-- denominated in this leg's currency.
regularLeg :: TransactionData -> Money
regularLeg td = case td.transactionType of
  Expense _ -> td.sourceAmount
  Income _ -> td.targetAmount
  _ -> td.sourceAmount

-- | Convert a single allocation amount (in user-account currency) to base
-- currency via the transaction's leg ratio. Same-currency transactions
-- (@exchangeRate == Nothing@) return the allocation unchanged.
--
-- The division denominator is the regular leg, which equals the sum of
-- strictly-positive allocations and is therefore positive in the 'Just'
-- branch. A zero regular leg is treated as identity defensively.
allocationBase :: TransactionData -> Money -> Money
allocationBase td alloc = case td.exchangeRate of
  Nothing -> alloc
  Just _ ->
    let ext = externalLeg td
        reg = regularLeg td
     in if unMoney reg == 0
          then alloc
          else unsafeMoney ext.currency (unMoney alloc * (unMoney ext / unMoney reg))

-- | Select the transactions eligible for reporting from a read-model map.
--
-- A transaction is reportable when it is 'Completed', categorised
-- (Income / Expense) or a fee transfer (@'Transfer' ('Just' _)@), touches at
-- least one visible account, and falls within the optional inclusive
-- business-date window. Fee transfers are passed through 'withVisibleFees'.
reportableTxns ::
  Set AccountId ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Map TransactionId TransactionData ->
  [TransactionData]
reportableTxns visible mFrom mTo = withVisibleFees visible . filter keep . Map.elems
  where
    keep td =
      td.status
        == Completed
        && isCategorised td.transactionType
        && touchesVisible visible td
        && maybe True (<= td.date) mFrom
        && maybe True (td.date <=) mTo

-- | A fee is paid from the transfer's source account, so a fee transfer whose
-- source account is not visible keeps no fee (it becomes a plain transfer and
-- contributes nothing). Income / Expense and plain transfers are unchanged.
withVisibleFees :: Set AccountId -> [TransactionData] -> [TransactionData]
withVisibleFees visible = map strip
  where
    strip td = case td.transactionType of
      Transfer (Just _) | not (Set.member td.sourceAccountId visible) -> td {transactionType = Transfer Nothing}
      _ -> td

-- | Aggregate income, expense, and net totals (all in base currency) across a
-- list of transactions. Income comes from income-bucket allocations on
-- 'Income' txns. Expense is expense-bucket allocations on 'Expense' txns,
-- less expense-bucket allocations on 'Income' txns (reimbursements). Net is
-- @income - expense@.
--
-- Fees on a @'Transfer' ('Just' _)@ add to expense (see 'transferFees').
--
-- Precondition: 'FeeRates' holds a rate for every non-base fee currency/day in
-- the list (as produced by 'resolveFeeRates'); a missing key falls back to the
-- unconverted amount.
aggregateIncomeExpense :: Currency -> FeeRates -> [TransactionData] -> (Money, Money, Money)
aggregateIncomeExpense base rates txs =
  let incomeR =
        sum
          [ unMoney (allocationBase td a.amount)
          | td <- txs,
            Income allocs <- [td.transactionType],
            a <- allocs.incomes
          ]
      expensePos =
        [ unMoney (allocationBase td a.amount)
        | td <- txs,
          Expense allocs <- [td.transactionType],
          a <- allocs.expenses
        ]
      expenseNeg =
        [ negate (unMoney (allocationBase td a.amount))
        | td <- txs,
          Income allocs <- [td.transactionType],
          a <- allocs.expenses
        ]
      expenseR = sum (expensePos ++ expenseNeg ++ map snd (transferFees base rates txs))
   in (unsafeMoney base incomeR, unsafeMoney base expenseR, unsafeMoney base (incomeR - expenseR))

-- | Source-currency → base rates per transaction day, needed only for fee
-- transfers whose source currency differs from base. Must contain an entry for
-- every non-base fee (build it with 'resolveFeeRates').
type FeeRates = Map (Day, Currency) ExchangeRate

-- | Expense-bucket fee allocations of fee transfers, as positive base-currency
-- amounts. A fee already in base counts as is; otherwise it is converted with
-- the 'FeeRates' entry for the transaction day. 'resolveFeeRates' guarantees
-- the entry exists; the unconverted fallback is unreachable and only keeps
-- this total.
transferFees :: Currency -> FeeRates -> [TransactionData] -> [(CategoryId, Rational)]
transferFees base rates txs =
  [ (a.categoryId, toBase td a.amount)
  | td <- txs,
    Transfer (Just allocs) <- [td.transactionType],
    a <- allocs.expenses
  ]
  where
    toBase td m
      | m.currency == base = unMoney m
      | otherwise = maybe (unMoney m) (\er -> unMoney (convert er m)) (Map.lookup (utctDay td.date, m.currency) rates)

-- | Look up the rate of every non-base fee currency on its transaction day.
-- A missing rate yields @Left ('ExchangeRateUnavailable' _)@, worded like
-- 'netWorth'.
resolveFeeRates :: Currency -> [TransactionData] -> AppM (Either DomainError FeeRates)
resolveFeeRates base txs = do
  cfg <- view appConfigL
  let provider = cfg.exchangeRate.provider
      needed =
        Set.fromList
          [ (utctDay td.date, a.amount.currency)
          | td <- txs,
            Transfer (Just allocs) <- [td.transactionType],
            a <- allocs.expenses,
            a.amount.currency /= base
          ]
  runExceptT . fmap Map.fromList . forM (Set.toList needed) $ \(day, cur) -> do
    mer <- lift (runDb (lookupHistoricalRate provider day cur base))
    case mer of
      Just er -> pure ((day, cur), er)
      Nothing ->
        throwError
          . ExchangeRateUnavailable
          $ "No rate for "
          <> tshow cur
          <> " -> "
          <> tshow base

-- | Aggregate signed expense-bucket spend per category (in base currency).
-- Expense-bucket allocations on 'Expense' txns add; the same on 'Income' txns
-- (reimbursements) subtract. Categories net out per the two-bucket semantics.
-- Transfer fees add to their category like an expense.
--
-- Precondition: 'FeeRates' holds a rate for every non-base fee currency/day in
-- the list (as produced by 'resolveFeeRates'); a missing key falls back to the
-- unconverted amount.
aggregateSpending :: Currency -> FeeRates -> [TransactionData] -> Map CategoryId Money
aggregateSpending base rates txs =
  let pos =
        [ (a.categoryId, unMoney (allocationBase td a.amount))
        | td <- txs,
          Expense allocs <- [td.transactionType],
          a <- allocs.expenses
        ]
      neg =
        [ (a.categoryId, negate (unMoney (allocationBase td a.amount)))
        | td <- txs,
          Income allocs <- [td.transactionType],
          a <- allocs.expenses
        ]
   in Map.map (unsafeMoney base) (Map.fromListWith (+) (pos ++ neg ++ transferFees base rates txs))

-- -----------------------------------------------------------------------------
-- Effectful service wrappers
-- -----------------------------------------------------------------------------

-- | Resolve the reporting base currency for a user from their configuration.
-- Defaults to 'USD' when no configuration is available (mirrors AuthService's
-- @maybe USD@ fallback).
resolveBaseCurrency :: UserId -> AppM Currency
resolveBaseCurrency userId = do
  res <- ConfigurationService.getConfigurationForUser userId
  pure $ either (const USD) (\c -> c.baseCurrency) res

-- | The set of accounts the user can see (any role grants visibility).
visibleAccounts :: UserId -> AppM (Set AccountId)
visibleAccounts userId = runDb (getAccountIds userId)

-- | Spending grouped by category for the user's visible accounts within the
-- optional inclusive date window. Returns the base-currency grand total plus
-- the per-category breakdown.
spendingByCategory :: UserId -> Maybe UTCTime -> Maybe UTCTime -> AppM (Either DomainError (Money, [(CategoryId, Money)]))
spendingByCategory userId mFrom mTo = do
  base <- resolveBaseCurrency userId
  visible <- visibleAccounts userId
  txs <- withVisibleFees visible <$> runDb (reportableTransactions visible mFrom mTo)
  fmap
    ( \rates ->
        let perCat = aggregateSpending base rates txs
            totalR = sum [unMoney m | m <- Map.elems perCat]
         in (unsafeMoney base totalR, Map.toList perCat)
    )
    <$> resolveFeeRates base txs

-- | Income, expense, and net totals (all in base currency) for the user's
-- visible accounts within the optional inclusive date window.
incomeVsExpense :: UserId -> Maybe UTCTime -> Maybe UTCTime -> AppM (Either DomainError (Money, Money, Money))
incomeVsExpense userId mFrom mTo = do
  base <- resolveBaseCurrency userId
  visible <- visibleAccounts userId
  txs <- withVisibleFees visible <$> runDb (reportableTransactions visible mFrom mTo)
  fmap (\rates -> aggregateIncomeExpense base rates txs) <$> resolveFeeRates base txs

-- | Restrict an @(AccountId, AccountData)@ list to the accounts that count
-- towards a user's net worth: 'Regular' (not 'External'), 'Opened' (not
-- 'Closed'), and owned by the user (@createdBy == userId@). Accounts merely
-- shared TO the user are excluded because they fail the ownership predicate.
--
-- Pure helper, exposed for unit testing the scoping rules in isolation.
ownedRegularOpened :: UserId -> [(AccountId, AccountData)] -> [(AccountId, AccountData)]
ownedRegularOpened userId =
  filter (\(_, ad) -> ad.createdBy == userId && isRegular ad.accountType && ad.status == Opened)

-- | Compute a user's net worth in their base currency.
--
-- Net worth is the sum over the user's 'Regular', 'Opened', owned accounts
-- (see 'ownedRegularOpened') of each balance normalised to the base currency.
-- Base-currency balances contribute unconverted; non-base balances are
-- converted using the latest published FX rate for the configured provider.
--
-- Returns @Left ('ExchangeRateUnavailable' _)@ when any included non-base
-- account has no available rate to base. The 'Either' (rather than a thrown
-- Web error) keeps this function in the Application layer: the Web layer maps
-- 'ExchangeRateUnavailable' to HTTP 422 at the boundary.
--
-- The result carries the base-currency total and, per account, a
-- @(accountId, nativeBalance, baseBalance)@ row.
netWorth :: UserId -> AppM (Either DomainError (Money, [(AccountId, Money, Money)]))
netWorth userId = do
  base <- resolveBaseCurrency userId
  myAccts <- runDb (getOwnedAccounts userId)
  let owned = ownedRegularOpened userId (Map.toList myAccts)
  cfg <- view appConfigL
  now <- liftIO getCurrentTime
  let provider = cfg.exchangeRate.provider
      day = utctDay now
  runExceptT $ do
    rows <- forM owned $ \(aid, ad) -> do
      baseBal <- toBase provider day base ad.balance
      pure (aid, ad.balance, baseBal)
    pure (unsafeMoney base (sum [unMoney bb | (_, _, bb) <- rows]), rows)
  where
    toBase ::
      Provider ->
      Day ->
      Currency ->
      Money ->
      ExceptT DomainError AppM Money
    toBase provider day base bal
      | bal.currency == base = pure bal
      | otherwise = do
          mer <- lift (runDb (lookupHistoricalRate provider day bal.currency base))
          case mer of
            Just er -> pure (convert er bal)
            Nothing ->
              throwError
                . ExchangeRateUnavailable
                $ "No rate for "
                <> tshow bal.currency
                <> " -> "
                <> tshow base
