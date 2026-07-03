module Domain.Core.AccountSubtypeKindSpec (spec) where

import Data.Aeson (decode, encode)
import qualified Data.Map.Strict as Map
import Domain.Core.Types
import RIO
import Test.Hspec

spec :: Spec
spec = describe "AccountSubtypeKind" $ do
  it "projects each AccountSubtype constructor to its kind" $ do
    accountSubtypeKind defaultCash `shouldBe` CashKind
    accountSubtypeKind defaultBankAccount `shouldBe` BankAccountKind
    accountSubtypeKind defaultEWallet `shouldBe` EWalletKind
    accountSubtypeKind defaultAsset `shouldBe` AssetKind
    accountSubtypeKind defaultLoan `shouldBe` LoanKind

  it "round-trips through JSON" $
    forM_ [minBound .. maxBound] $ \k ->
      decode (encode (k :: AccountSubtypeKind)) `shouldBe` Just k

  it "serialises a keyed map as a JSON object (round-trips)" $ do
    let m = Map.fromList [(CashKind, True), (BankAccountKind, False)]
    decode (encode m) `shouldBe` Just m
