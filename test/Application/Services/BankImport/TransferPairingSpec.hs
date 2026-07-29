{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.BankImport.TransferPairingSpec (spec) where

import Application.Services.BankImport.TransferPairing
  ( creditLeg,
    debitLeg,
    pairInternalTransfers,
  )
import Data.Time (addUTCTime)
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Core.Types (AccountId, unsafeExternalTransactionId)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    TransferMatcher,
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
import RIO
import qualified RIO.List as L
import Test.Hspec
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Helpers (mockAccountIdN)

matcher :: TransferMatcher
matcher = defaultTransferMatcher defaultTransferPairingWindow

extA, extB :: ExternalAccountId
extA = unsafeExternalAccountId "card-A"
extB = unsafeExternalAccountId "card-B"

localA, localB :: AccountId
localA = mockAccountIdN 10
localB = mockAccountIdN 20

debitA :: BankTransaction
debitA = mkSameCurrencyBankTx (unsafeExternalTransactionId "a-1") extA (-100)

creditB :: BankTransaction
creditB = mkSameCurrencyBankTx (unsafeExternalTransactionId "b-1") extB 100

triple :: ExternalAccountId -> AccountId -> BankTransaction -> (ExternalAccountId, AccountId, BankTransaction)
triple = (,,)

spec :: Spec
spec = describe "pairInternalTransfers" $ do
  it "pairs a debit and credit of equal magnitude across two linked accounts" $ do
    let (pairs, leftovers) =
          pairInternalTransfers matcher [triple extA localA debitA, triple extB localB creditB]
    length pairs `shouldBe` 1
    leftovers `shouldBe` []
    case pairs of
      [t] -> do
        (debitLeg t).externalId `shouldBe` debitA.externalId
        (creditLeg t).externalId `shouldBe` creditB.externalId
      _ -> expectationFailure "expected exactly one pair"

  it "does not pair legs on the SAME external account" $ do
    let creditA = mkSameCurrencyBankTx (unsafeExternalTransactionId "a-2") extA 100
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extA localA creditA]
    pairs `shouldBe` []

  it "does not pair two different cards that map to the SAME local account (sibling cards)" $ do
    let extC = unsafeExternalAccountId "card-A2"
        creditC = mkSameCurrencyBankTx (unsafeExternalTransactionId "c-9") extC 100
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extC localA creditC]
    pairs `shouldBe` []

  it "does not pair different magnitudes" $ do
    let creditB' = mkSameCurrencyBankTx (unsafeExternalTransactionId "b-2") extB 99
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extB localB creditB']
    pairs `shouldBe` []

  it "does not pair different currencies" $ do
    let creditUsd = (mkSameCurrencyBankTx (unsafeExternalTransactionId "b-3") extB 100) {currencyCode = 840}
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extB localB creditUsd]
    pairs `shouldBe` []

  it "does not pair legs outside the time window" $ do
    let farCredit = creditB {time = addUTCTime 600 creditB.time}
        (pairs, _) = pairInternalTransfers matcher [triple extA localA debitA, triple extB localB farCredit]
    pairs `shouldBe` []

  it "partitions: every input tx is either paired or a leftover, never both, never lost" $ do
    let solo = mkSameCurrencyBankTx (unsafeExternalTransactionId "c-1") extA (-7)
        input = [triple extA localA debitA, triple extB localB creditB, triple extA localA solo]
        (pairs, leftovers) = pairInternalTransfers matcher input
        pairedIds = concatMap (\t -> [(debitLeg t).externalId, (creditLeg t).externalId]) pairs
        leftoverIds = [tx.externalId | (_, _, tx) <- leftovers]
    L.sort (pairedIds <> leftoverIds) `shouldBe` L.sort [tx.externalId | (_, _, tx) <- input]
