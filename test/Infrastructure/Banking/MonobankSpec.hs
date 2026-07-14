{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.MonobankSpec (spec) where

import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy as BSL
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Banking.Types (unBankProviderId, unsafeExternalAccountId)
import Domain.Core.Types (unsafeExternalTransactionId)
import Infrastructure.Banking.Monobank (descriptor)
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
  -- A single descriptor drives both the classify and descriptor-shape tests.
  -- The base URL and manager are unused by 'classify' and by the shape
  -- assertions, so a bottom manager is safe (never forced).
  let d = descriptor "http://unused" (error "Manager not used in these tests")

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
          case toProviderTransaction (unsafeExternalAccountId "acc-1") stmt of
            Left err -> expectationFailure ("adapter rejected statement: " <> show err)
            Right tx -> tx.mcc `shouldBe` Nothing

    it "handles missing 'comment' field" $ do
      -- Key is entirely absent (not `\"comment\": null`).
      let body :: BSL.ByteString
          body = "{\"id\":\"tx-nocomment\",\"time\":1700000000,\"description\":\"shop\",\"mcc\":5411,\"amount\":-500,\"operationAmount\":-500,\"currencyCode\":980,\"hold\":false}"
      case eitherDecode body :: Either String MonoStatement of
        Left err -> expectationFailure ("decode failed: " <> err)
        Right stmt ->
          case toProviderTransaction (unsafeExternalAccountId "acc-1") stmt of
            Left err -> expectationFailure ("adapter rejected statement: " <> show err)
            Right tx -> tx.notes `shouldBe` Nothing

  describe "classify" $ do
    let classify = d.classify

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

  describe "descriptor" $ do
    it "has the monobank id and display name" $ do
      unBankProviderId d.providerId `shouldBe` "monobank"
      d.displayName `shouldBe` "Monobank"

    it "supports the pull transport and not file import" $ do
      isJust d.pull `shouldBe` True
      isNothing d.fileImport `shouldBe` True

-- | Helper to build a minimal BankTransaction for classification testing.
mkTx :: Maybe Text -> Rational -> BankTransaction
mkTx mccVal amt =
  BankTransaction
    { externalId = unsafeExternalTransactionId "test-tx",
      externalAccountId = unsafeExternalAccountId "test-acc",
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
