{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBankTransferSpec (spec) where

import Data.Time (addUTCTime)
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (unsafeExternalTransactionId)
import Infrastructure.Banking.PrivatBank (ownCardCounterpartLast4, privatBankTransferMatcher)
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    TransferMatcher (..),
    defaultTransferPairingWindow,
  )
import RIO
import Test.Hspec
import Testkit.BankingHelpers (mkSameCurrencyBankTx)

-- | Outgoing leg: account ends in 1440, description names the destination card
-- *9713.
outLeg :: BankTransaction
outLeg =
  (mkSameCurrencyBankTx (unsafeExternalTransactionId "out") (unsafeExternalAccountId "5168001440") (-20000))
    { description = "На свою картку *9713"
    }

-- | Incoming leg: account ends in 9713, description names the source card
-- *1440. Posted one second after the outgoing leg.
inLeg :: BankTransaction
inLeg =
  (mkSameCurrencyBankTx (unsafeExternalTransactionId "inc") (unsafeExternalAccountId "5168009713") 20000)
    { description = "Зі своєї картки *1440",
      time = addUTCTime 1 outLeg.time
    }

matcher :: BankTransaction -> BankTransaction -> Bool
matcher = (privatBankTransferMatcher defaultTransferPairingWindow).matchesTransfer

spec :: Spec
spec = do
  describe "ownCardCounterpartLast4" $ do
    it "reads the destination card last-4 from a 'На свою картку' row"
      $ ownCardCounterpartLast4 (outLeg {description = "На свою картку *9713"})
      `shouldBe` Just "9713"

    it "reads the source card last-4 from a 'Зі своєї картки' row"
      $ ownCardCounterpartLast4 (outLeg {description = "Зі своєї картки *1440"})
      `shouldBe` Just "1440"

    it "returns Nothing for a normal counterparty row"
      $ ownCardCounterpartLast4 (outLeg {description = "Сидоренко Р."})
      `shouldBe` Nothing

    it "returns Nothing for a ФОП own-funds transfer row"
      $ ownCardCounterpartLast4 (outLeg {description = "Переказ власних коштiв"})
      `shouldBe` Nothing

  describe "privatBankTransferMatcher" $ do
    it "matches a self-labeled pair naming each other's card last-4"
      $ matcher outLeg inLeg
      `shouldBe` True

    it "rejects a pair whose named last-4 does not match the other account"
      $ matcher
        (outLeg {description = "На свою картку *0000"})
        (inLeg {description = "Зі своєї картки *5555"})
      `shouldBe` False

    it "rejects legs of differing magnitude"
      $ matcher outLeg (inLeg {amount = 15000})
      `shouldBe` False

    it "rejects legs in different currencies"
      $ matcher outLeg (inLeg {currencyCode = 840})
      `shouldBe` False

    it "rejects a pair where neither leg is self-labeled"
      $ matcher
        (outLeg {description = "Сидоренко Р."})
        (inLeg {description = "Оплата послуг"})
      `shouldBe` False
