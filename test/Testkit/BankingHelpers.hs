{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.BankingHelpers
-- Description : Test helpers for the banking integration
--
-- Provides constructors for 'BankAccount' and 'BankTransaction' values, for
-- use in unit and integration tests.
module Testkit.BankingHelpers
  ( mkTestBankAccount,
    mkSameCurrencyBankTx,
    mkForeignCurrencyBankTx,
    sampleBankTransaction,
  )
where

import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Core.Types (ExternalTransactionId, unsafeExternalTransactionId)
import Infrastructure.Banking.Provider
  ( BankAccount (..),
    BankTransaction (..),
  )
import RIO

-- | Construct a test 'BankAccount'.
mkTestBankAccount :: ExternalAccountId -> Text -> Int -> BankAccount
mkTestBankAccount extId accNumber currency =
  BankAccount
    { externalAccountId = extId,
      accountNumber = accNumber,
      currencyCode = currency,
      cardMasks = [],
      balance = 0
    }

-- | Construct a same-currency 'BankTransaction' (UAH, 980) with a fixed
-- posix timestamp. Amount is in major units.
mkSameCurrencyBankTx ::
  ExternalTransactionId ->
  ExternalAccountId ->
  Rational ->
  BankTransaction
mkSameCurrencyBankTx eid accId amt =
  BankTransaction
    { externalId = eid,
      externalAccountId = accId,
      time = posixSecondsToUTCTime 1700000000,
      amount = amt,
      currencyCode = 980,
      description = "test",
      hold = False,
      category = Nothing,
      contact = Nothing,
      originalAmount = Nothing,
      notes = Nothing
    }

-- | Construct a cross-currency 'BankTransaction'. The @accountAmt@ is the
-- amount in the account currency; @foreignAmt@ is the amount in the
-- transaction's original currency.
mkForeignCurrencyBankTx ::
  ExternalTransactionId ->
  ExternalAccountId ->
  Rational ->
  Rational ->
  BankTransaction
mkForeignCurrencyBankTx eid accId accountAmt foreignAmt =
  (mkSameCurrencyBankTx eid accId accountAmt) {originalAmount = Just foreignAmt}

-- | Construct a minimal valid 'BankTransaction' with the given signed
-- @amount@, for tests that only care about amount-driven behaviour (e.g.
-- 'Infrastructure.Banking.Provider.defaultClassify').
sampleBankTransaction :: Rational -> BankTransaction
sampleBankTransaction =
  mkSameCurrencyBankTx (unsafeExternalTransactionId "sample-tx") (unsafeExternalAccountId "sample-account")
