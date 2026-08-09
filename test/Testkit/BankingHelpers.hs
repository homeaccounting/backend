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
    mkCrossCurrencyBankTx,
    sampleBankTransaction,
    byLabel,
    byCounterparty,
  )
where

import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Core.Types
  ( BankProviderCategory,
    ExternalTransactionId,
    mkByCounterparty,
    mkByLabel,
    unsafeExternalTransactionId,
  )
import Infrastructure.Banking.Provider
  ( BankAccount (..),
    BankTransaction (..),
  )
import RIO
import qualified RIO.Text as T

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
-- amount in the account currency; @originalAmt@ is the amount in the
-- transaction's original currency.
mkCrossCurrencyBankTx ::
  ExternalTransactionId ->
  ExternalAccountId ->
  Rational ->
  Rational ->
  BankTransaction
mkCrossCurrencyBankTx eid accId accountAmt originalAmt =
  (mkSameCurrencyBankTx eid accId accountAmt) {originalAmount = Just originalAmt}

-- | Construct a minimal valid 'BankTransaction' with the given signed
-- @amount@, for tests that only care about amount-driven behaviour (e.g.
-- 'Infrastructure.Banking.Provider.defaultClassify').
sampleBankTransaction :: Rational -> BankTransaction
sampleBankTransaction =
  mkSameCurrencyBankTx (unsafeExternalTransactionId "sample-tx") (unsafeExternalAccountId "sample-account")

-- | Total test-only 'BankProviderCategory' constructors for a known-valid
-- label / counterparty token. 'mkByLabel' / 'mkByCounterparty' return 'Maybe'
-- (they trim and reject blank), so a spec with a statically-valid literal would
-- otherwise carry a @case … Nothing -> expectationFailure@ dance at every use
-- site. These unwrap it once, failing loudly (with a call stack) on the
-- can't-happen blank case. Pure, so they work in both IO specs and pure
-- contexts (@shouldBe@, list comprehensions). Constructor-validation tests that
-- assert the blank/trim behaviour should keep using 'mkByLabel' /
-- 'mkByCounterparty' directly. ('mkByMcc' needs no sibling — it is already total
-- over a parsed 'MCC'.)
byLabel :: (HasCallStack) => Text -> BankProviderCategory
byLabel t = fromMaybe (error ("byLabel: invalid label " <> T.unpack t)) (mkByLabel t)

byCounterparty :: (HasCallStack) => Text -> BankProviderCategory
byCounterparty t = fromMaybe (error ("byCounterparty: invalid token " <> T.unpack t)) (mkByCounterparty t)
