{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Mirrors web's @src\/features\/accounts\/accountName.test.ts@ (ADR 009).
module Domain.Account.NamingSpec (spec) where

import Domain.Account.Naming
import Domain.Core.Types
  ( AccountSubtype (..),
    AssetProperties (..),
    AssetType (..),
    BankAccountProperties (..),
    CashProperties (..),
    Currency (..),
    EWalletProperties (..),
    LoanProperties (..),
    defaultAssetProperties,
    defaultBankAccountProperties,
    defaultCash,
    defaultCashProperties,
    defaultEWalletProperties,
    defaultLoanProperties,
  )
import Domain.Localization.Language (Language (..))
import Data.Char (toLower)
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (elements, forAll, sublistOf)

bank :: Maybe Text -> AccountSubtype
bank b = BankAccount defaultBankAccountProperties {bankName = b}

parts :: Text -> Currency -> AccountSubtype -> AccountNameParts
parts = accountNameParts En

card :: AccountNameParts
card = parts "Card" UAH (bank (Just "PrivatBank"))

shows :: Bool -> Bool -> ShownByContext
shows q c = ShownByContext {qualifierShown = q, currencyShown = c}

lowerFirst :: String -> String
lowerFirst (c : cs) = toLower c : cs
lowerFirst [] = []

spec :: Spec
spec = describe "Domain.Account.Naming" $ do
  describe "accountNameParts" $ do
    it "reads each kind's qualifier field" $ do
      let qualifierAndKind st = let p = parts "Main" UAH st in (p.kind, p.qualifier)
      qualifierAndKind (Cash defaultCashProperties {storageLocation = Just "Home safe"})
        `shouldBe` ("Cash", Just "Home safe")
      qualifierAndKind (bank (Just "PrivatBank")) `shouldBe` ("Bank account", Just "PrivatBank")
      qualifierAndKind (EWallet defaultEWalletProperties {provider = Just "PayPal"})
        `shouldBe` ("E-wallet", Just "PayPal")
      qualifierAndKind (Loan defaultLoanProperties {lender = Just "Monobank"})
        `shouldBe` ("Loan", Just "Monobank")

    it "shows an asset qualifier through its localized asset-type label" $ do
      let flat = Asset defaultAssetProperties {assetType = Just Property}
      (parts "Flat" UAH flat).qualifier `shouldBe` Just "Property"
      (accountNameParts Uk "Flat" UAH flat).qualifier `shouldBe` Just "Нерухомість"
      (accountNameParts Uk "Flat" UAH flat).kind `shouldBe` "Актив"

    it "maps every kind and asset type to a catalog label" $ do
      let kinds =
            [ ("Cash", defaultCash),
              ("Bank account", bank Nothing),
              ("E-wallet", EWallet defaultEWalletProperties),
              ("Asset", Asset defaultAssetProperties),
              ("Loan", Loan defaultLoanProperties)
            ]
          assetLabel lang t =
            (accountNameParts lang "A" UAH (Asset defaultAssetProperties {assetType = Just t})).qualifier
      forM_ kinds $ \(en, st) -> do
        (parts "A" UAH st).kind `shouldBe` en
        -- A missing uk entry would fall back to the English label.
        (accountNameParts Uk "A" UAH st).kind `shouldNotBe` en
      forM_ [Property, Vehicle, Stocks, RetirementFund, Electronics, Equipment, Furniture] $ \t -> do
        -- A missing en entry would fall back to the camelCase key.
        assetLabel En t `shouldNotBe` Just (T.pack (lowerFirst (show t)))
        assetLabel Uk t `shouldNotBe` assetLabel En t
      assetLabel Uk (OtherAsset "Paintings") `shouldBe` Just "Paintings"

    it "treats a blank qualifier as missing and trims the rest" $ do
      (parts "Card" UAH (bank (Just "   "))).qualifier `shouldBe` Nothing
      (parts "Card" UAH (bank Nothing)).qualifier `shouldBe` Nothing
      (parts "Card" UAH (bank (Just "  Mono "))).qualifier `shouldBe` Just "Mono"

  describe "fullAccountName" $ do
    it "joins kind, qualifier and name as a path with the currency suffix" $
      fullAccountName card `shouldBe` "Bank account \x203A PrivatBank \x203A Card \xB7 UAH"

    it "omits a missing qualifier segment" $
      fullAccountName (parts "Pocket" USD defaultCash) `shouldBe` "Cash \x203A Pocket \xB7 USD"

  describe "shortAccountName" $ do
    it "shows name, qualifier and currency when the context shows nothing" $
      shortAccountName (shows False False) card `shouldBe` "Card \xB7 PrivatBank \xB7 UAH"

    it "drops the qualifier when the context shows it" $
      shortAccountName (shows True False) card `shouldBe` "Card \xB7 UAH"

    it "drops the currency when the context shows it" $
      shortAccountName (shows False True) card `shouldBe` "Card \xB7 PrivatBank"

    it "is the bare name when the context shows both" $
      shortAccountName (shows True True) card `shouldBe` "Card"

    it "skips a missing qualifier" $
      shortAccountName (shows False False) (parts "Pocket" USD defaultCash) `shouldBe` "Pocket \xB7 USD"

  describe "accountMatches" $ do
    let usdCard = parts "Card" USD (bank (Just "PrivatBank"))

    it "matches when every token appears in the full name" $
      forM_ ["card", "PRIVAT", "usd", "bank", "privat usd", "  card  ", ""] $ \q ->
        (q, accountMatches q usdCard) `shouldBe` (q, True)

    it "does not match when a token is missing" $
      forM_ ["mono", "privat eur"] $ \q ->
        (q, accountMatches q usdCard) `shouldBe` (q, False)

    prop "matches any selection of the full name's words, in any case" $
      forAll (elements [card, usdCard, parts "Caf\xE9" UAH defaultCash]) $ \p ->
        forAll (sublistOf (T.words (fullAccountName p))) $ \ws ->
          accountMatches (T.unwords ws) p && accountMatches (T.toUpper (T.unwords ws)) p

    prop "never matches a token absent from the full name" $
      forAll (elements [card, usdCard]) $ \p ->
        forAll (sublistOf (T.words (fullAccountName p))) $ \ws ->
          not (accountMatches (T.unwords ("zzz" : ws)) p)

    it "ignores accents on both sides" $ do
      accountMatches "cafe" (parts "Caf\xE9" UAH defaultCash) `shouldBe` True
      accountMatches "caf\xE9" (parts "Cafe" UAH defaultCash) `shouldBe` True
