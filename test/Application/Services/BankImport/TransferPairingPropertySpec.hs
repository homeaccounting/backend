{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.BankImport.TransferPairingPropertySpec (spec) where

import Application.Services.BankImport.TransferPairing
  ( creditLeg,
    creditLocalAccount,
    debitLeg,
    debitLocalAccount,
    pairInternalTransfers,
  )
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Banking.Import (ExternalTransactionId, unsafeExternalTransactionId)
import Domain.Banking.Types (ExternalAccountId, unsafeExternalAccountId)
import Domain.Core.Types (AccountId)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    TransferMatcher,
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
import RIO
import qualified RIO.List as L
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Testkit.BankingHelpers (mkSameCurrencyBankTx)
import Testkit.Helpers (mockAccountIdN)

matcher :: TransferMatcher
matcher = defaultTransferMatcher defaultTransferPairingWindow

-- | Legs with distinct external ids, as real bank statements have: the
-- properties identify a leg by its id, so two random legs sharing one would
-- read as a single transaction consumed twice.
genLegs :: Gen [(ExternalAccountId, AccountId, BankTransaction)]
genLegs = sized $ \n -> do
  k <- choose (0, n)
  traverse genLeg [1 .. k]

genLeg :: Int -> Gen (ExternalAccountId, AccountId, BankTransaction)
genLeg ix = do
  cardIx <- choose (1, 4) :: Gen Int -- external card
  acctIx <- choose (1, 3) :: Gen Int -- local account (fewer accounts than cards → siblings arise)
  let eid = unsafeExternalTransactionId (T.pack (show ix))
  amt <- elements [-100, -50, 50, 100] :: Gen Rational
  ccy <- elements [980, 840]
  secs <- choose (1700000000, 1700002000) :: Gen Integer
  let extAcc = unsafeExternalAccountId (T.pack ("card-" <> show cardIx))
      localAcc = mockAccountIdN (fromIntegral acctIx)
      tx =
        (mkSameCurrencyBankTx eid extAcc amt)
          { currencyCode = ccy,
            time = posixSecondsToUTCTime (fromIntegral secs)
          }
  pure (extAcc, localAcc, tx)

ids :: [(ExternalAccountId, AccountId, BankTransaction)] -> [ExternalTransactionId]
ids xs = [tx.externalId | (_, _, tx) <- xs]

spec :: Spec
spec = describe "pairInternalTransfers properties" $ do
  prop "partitions input: paired legs ∪ leftovers = input (no loss, no duplication)"
    $ forAll genLegs
    $ \input ->
      let (pairs, leftovers) = pairInternalTransfers matcher input
          pairedIds = concatMap (\t -> [(debitLeg t).externalId, (creditLeg t).externalId]) pairs
       in L.sort (pairedIds <> ids leftovers) === L.sort (ids input)

  prop "each transaction is consumed at most once"
    $ forAll genLegs
    $ \input ->
      let (pairs, _) = pairInternalTransfers matcher input
          pairedIds = concatMap (\t -> [(debitLeg t).externalId, (creditLeg t).externalId]) pairs
       in L.nub pairedIds === pairedIds

  prop "every pair is a valid transfer (diff LOCAL account, opposite sign, equal magnitude, same currency)"
    $ forAll genLegs
    $ \input ->
      let (pairs, _) = pairInternalTransfers matcher input
       in all validPair pairs
  where
    validPair t =
      let d = debitLeg t
          c = creditLeg t
       in debitLocalAccount t
            /= creditLocalAccount t
            && d.currencyCode
            == c.currencyCode
            && d.amount
            < 0
            && c.amount
            > 0
            && abs d.amount
            == abs c.amount
