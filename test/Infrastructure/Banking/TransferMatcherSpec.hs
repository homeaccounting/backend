{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.TransferMatcherSpec (spec) where

import Data.Time (addUTCTime)
import Domain.Banking.Import (unsafeExternalTransactionId)
import Domain.Banking.Types (unsafeExternalAccountId)
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
spec = do
  describe "defaultTransferMatcher" $ do
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

  describe "TransferMatcher composition (Semigroup/Monoid)" $ do
    -- Two trivial, complementary strategies: 'firstNeg' matches on the first
    -- leg's sign, 'secondNeg' on the second leg's. Their OR fires when either
    -- does, which is what @<>@ must produce.
    let firstNeg = TransferMatcher (\a _ -> a.amount < 0)
        secondNeg = TransferMatcher (\_ b -> b.amount < 0)
        -- Bound (rather than literal 'mempty') so the identity-law assertions
        -- below actually run instead of being rewritten away by hlint's
        -- Monoid-law hint.
        identityMatcher = mempty :: TransferMatcher
        out = mkSameCurrencyBankTx (unsafeExternalTransactionId "out") (unsafeExternalAccountId "acc-a") (-100)
        inc = mkSameCurrencyBankTx (unsafeExternalTransactionId "inc") (unsafeExternalAccountId "acc-b") 100

    it "<> is the OR of its component strategies" $ do
      let combined = (firstNeg <> secondNeg).matchesTransfer
      combined out inc `shouldBe` True -- firstNeg fires
      combined inc out `shouldBe` True -- secondNeg fires
      combined inc inc `shouldBe` False -- neither fires
    it "mempty never matches" $ do
      let never = identityMatcher.matchesTransfer
      never out inc `shouldBe` False
      never inc out `shouldBe` False

    it "mempty is a left identity for <>" $ do
      let combined = (identityMatcher <> firstNeg).matchesTransfer
      combined out inc `shouldBe` firstNeg.matchesTransfer out inc
      combined inc inc `shouldBe` firstNeg.matchesTransfer inc inc

    it "mempty is a right identity for <>" $ do
      let combined = (firstNeg <> identityMatcher).matchesTransfer
      combined out inc `shouldBe` firstNeg.matchesTransfer out inc
      combined inc inc `shouldBe` firstNeg.matchesTransfer inc inc
