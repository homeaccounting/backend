{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.MonobankSpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy as BSL
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Core.Types (unsafeExternalTransactionId)
import Infrastructure.Banking.Monobank (mkMonobankProvider)
import Infrastructure.Banking.Monobank.Internal
  ( MonoAccount (..),
    MonoClientInfo (..),
    MonoStatement (..),
    toProviderTransaction,
  )
import Infrastructure.Banking.Provider
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Monobank Provider" $ do
  describe "JSON parsing" $ do
    it "parses /personal/client-info" $ do
      let body :: BSL.ByteString
          body = "{\"accounts\":[{\"id\":\"abc\",\"iban\":\"UA123\",\"currencyCode\":980,\"balance\":10000}]}"
      case eitherDecode body :: Either String MonoClientInfo of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right info -> case info.accounts of
          [acc] -> do
            acc.monoAccId `shouldBe` "abc"
            acc.monoAccIban `shouldBe` "UA123"
            acc.monoAccCurrencyCode `shouldBe` 980
            acc.monoAccBalance `shouldBe` 10000
          other -> expectationFailure ("expected exactly 1 account, got " <> show (length other))

    it "parses a /personal/statement entry" $ do
      let body :: BSL.ByteString
          body = "{\"id\":\"tx1\",\"time\":1700000000,\"description\":\"groceries\",\"mcc\":5411,\"amount\":-12345,\"operationAmount\":-12345,\"currencyCode\":980,\"hold\":false,\"comment\":\"store\"}"
      case eitherDecode body :: Either String MonoStatement of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right stmt -> do
          stmt.stmtId `shouldBe` "tx1"
          stmt.stmtTime `shouldBe` 1700000000
          stmt.stmtAmount `shouldBe` -12345
          stmt.stmtOperationAmount `shouldBe` -12345
          stmt.stmtCurrencyCode `shouldBe` 980
          stmt.stmtMcc `shouldBe` 5411
          stmt.stmtHold `shouldBe` False
          stmt.stmtDescription `shouldBe` "groceries"
          stmt.stmtComment `shouldBe` Just "store"

    it "handles mcc=0 by mapping to Nothing in the adapter" $ do
      let body :: BSL.ByteString
          body = "{\"id\":\"tx-mcc0\",\"time\":1700000000,\"description\":\"atm\",\"mcc\":0,\"amount\":-100,\"operationAmount\":-100,\"currencyCode\":980,\"hold\":false,\"comment\":\"n/a\"}"
      case eitherDecode body :: Either String MonoStatement of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right stmt ->
          case toProviderTransaction "acc-1" stmt of
            Left err -> expectationFailure ("adapter rejected statement: " <> show err)
            Right tx -> tx.mcc `shouldBe` Nothing

    it "handles missing 'comment' field" $ do
      -- Key is entirely absent (not `\"comment\": null`).
      let body :: BSL.ByteString
          body = "{\"id\":\"tx-nocomment\",\"time\":1700000000,\"description\":\"shop\",\"mcc\":5411,\"amount\":-500,\"operationAmount\":-500,\"currencyCode\":980,\"hold\":false}"
      case eitherDecode body :: Either String MonoStatement of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right stmt ->
          case toProviderTransaction "acc-1" stmt of
            Left err -> expectationFailure ("adapter rejected statement: " <> show err)
            Right tx -> tx.notes `shouldBe` Nothing

  describe "classifyTransaction" $ do
    let provider = mkMonobankProvider "" "" (error "Manager not used in classify tests")
        classify = provider.classifyTransaction

    it "classifies MCC 4829 with negative amount as Expense"
      $ classify (mkTx (Just "4829") (-10))
      `shouldBe` ClassifiedExpense

    it "classifies MCC 4829 with positive amount as Income"
      $ classify (mkTx (Just "4829") 10)
      `shouldBe` ClassifiedIncome

    it "classifies positive amount as Income"
      $ classify (mkTx (Just "5411") 50)
      `shouldBe` ClassifiedIncome

    it "classifies negative amount as Expense"
      $ classify (mkTx (Just "5411") (-30))
      `shouldBe` ClassifiedExpense

    it "classifies zero MCC negative as Expense"
      $ classify (mkTx Nothing (-1))
      `shouldBe` ClassifiedExpense

    it "classifies no MCC positive as Income"
      $ classify (mkTx Nothing 1)
      `shouldBe` ClassifiedIncome

-- | Helper to build a minimal BankTransaction for classification testing.
mkTx :: Maybe Text -> Rational -> BankTransaction
mkTx mccVal amt =
  BankTransaction
    { externalId = unsafeExternalTransactionId "test-tx",
      accountId = "test-acc",
      time = posixSecondsToUTCTime 0,
      amount = amt,
      currencyCode = 980,
      description = "test",
      hold = False,
      mcc = mccVal,
      originalAmount = Nothing,
      notes = Nothing,
      categoryHint = Nothing
    }
