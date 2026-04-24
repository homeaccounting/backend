{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.BankingHelpers
-- Description : Test helpers for the banking integration
--
-- Provides a mock 'BankProvider' and constructors for 'BankAccount' and
-- 'BankTransaction' values, for use in unit and integration tests.
module Testkit.BankingHelpers
  ( mkMockProvider,
    mkTestBankAccount,
    mkSameCurrencyBankTx,
    mkForeignCurrencyBankTx,
  )
where

import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Core.Types (ExternalTransactionId)
import Infrastructure.Banking.Provider
  ( BankAccount (..),
    BankAccountId,
    BankProvider (..),
    BankTransaction (..),
    TransactionClassification (..),
  )
import RIO

-- | A mock 'BankProvider' for tests.
--
--  * 'fetchAccounts' returns the caller-supplied list.
--  * 'fetchStatements' returns the caller-supplied list (independent of args).
--  * 'registerWebhook' is a no-op that always succeeds.
--  * 'classifyTransaction' applies the Monobank sign rule:
--    non-negative amount → income, negative amount → expense.
mkMockProvider :: [BankAccount] -> [BankTransaction] -> BankProvider
mkMockProvider accs txs =
  BankProvider
    { providerName = "mock",
      fetchAccounts = pure (Right accs),
      fetchStatements = \_ _ _ -> pure (Right txs),
      registerWebhook = \_ -> pure (Right ()),
      classifyTransaction = \tx ->
        if tx.amount >= 0
          then ClassifiedIncome
          else ClassifiedExpense
    }

-- | Construct a test 'BankAccount'.
mkTestBankAccount :: BankAccountId -> Text -> Int -> BankAccount
mkTestBankAccount extId accNumber currency =
  BankAccount
    { externalId = extId,
      accountNumber = accNumber,
      currencyCode = currency,
      cardMasks = [],
      balance = 0
    }

-- | Construct a same-currency 'BankTransaction' (UAH, 980) with a fixed
-- posix timestamp. Amount is in major units.
mkSameCurrencyBankTx ::
  ExternalTransactionId ->
  BankAccountId ->
  Rational ->
  BankTransaction
mkSameCurrencyBankTx eid accId amt =
  BankTransaction
    { externalId = eid,
      accountId = accId,
      time = posixSecondsToUTCTime 1700000000,
      amount = amt,
      currencyCode = 980,
      description = "test",
      hold = False,
      mcc = Nothing,
      originalAmount = Nothing,
      notes = Nothing,
      categoryHint = Nothing
    }

-- | Construct a cross-currency 'BankTransaction'. The @accountAmt@ is the
-- amount in the account currency; @foreignAmt@ is the amount in the
-- transaction's original currency.
mkForeignCurrencyBankTx ::
  ExternalTransactionId ->
  BankAccountId ->
  Rational ->
  Rational ->
  BankTransaction
mkForeignCurrencyBankTx eid accId accountAmt foreignAmt =
  (mkSameCurrencyBankTx eid accId accountAmt) {originalAmount = Just foreignAmt}
