{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.TransferMatcherSpec (spec) where

import Data.Time (addUTCTime)
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (unsafeExternalTransactionId)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    TransferMatcher (..),
    defaultTransferMatcher,
    defaultTransferPairingWindow,
  )
import RIO
import Test.Hspec
import Testkit.BankingHelpers (mkSameCurrencyBankTx)

spec :: Spec
spec = describe "defaultTransferMatcher" $ do
  let matcher = (defaultTransferMatcher defaultTransferPairingWindow).matchesTransfer
      out = mkSameCurrencyBankTx (unsafeExternalTransactionId "out") (unsafeExternalAccountId "acc-a") (-100)
      inc = mkSameCurrencyBankTx (unsafeExternalTransactionId "inc") (unsafeExternalAccountId "acc-b") 100

  it "matches opposite-sign, equal-magnitude, same-currency, same-time legs"
    $ matcher out inc
    `shouldBe` True

  it "rejects same-sign legs"
    $ matcher out (inc {amount = -100})
    `shouldBe` False

  it "rejects unequal magnitudes"
    $ matcher out (inc {amount = 200})
    `shouldBe` False

  it "rejects different currencies"
    $ matcher out (inc {currencyCode = 840})
    `shouldBe` False

  it "rejects legs 10 minutes apart"
    $ matcher out (inc {time = addUTCTime 600 inc.time})
    `shouldBe` False
