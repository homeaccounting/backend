{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.ProvidersSpec (spec) where

import Data.Aeson (Object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Banking.Types (unsafeBankProviderId)
import Domain.Localization.Country (unsafeCountry)
import qualified Infrastructure.Banking.Monobank as Monobank
import qualified Infrastructure.Banking.PrivatBank as PrivatBank
import qualified Infrastructure.Banking.PrivatBankBusiness as PrivatBankBusiness
import Infrastructure.Banking.Provider (BankProviderDescriptor (..), ProviderCoverage (..))
import Infrastructure.Banking.Providers (buildRegistry)
import Infrastructure.Banking.Registry (lookupProvider, registryBankProviderIds)
import Infrastructure.Config (BankingConfig (..), ProviderSettings (..))
import Network.HTTP.Client (Manager)
import RIO
import Test.Hspec

-- | A 'BankingConfig' with a single @monobank@ entry with the given
-- enabled flag and raw settings object.
bankingConfigWith :: Bool -> Object -> BankingConfig
bankingConfigWith en settingsObj =
  BankingConfig
    { enabled = True,
      providers =
        Map.singleton
          (unsafeBankProviderId "monobank")
          ProviderSettings {enabled = en, settings = settingsObj},
      tokenEncKey = ""
    }

-- | A 'Manager' that is never forced: 'buildRegistry' only closes over it in
-- descriptor fields, it never invokes any HTTP call.
unusedManager :: Manager
unusedManager = error "Manager not used by buildRegistry"

spec :: Spec
spec = describe "Infrastructure.Banking.Providers" $ do
  describe "buildRegistry" $ do
    it "includes monobank when its config entry is enabled" $ do
      let reg = buildRegistry (bankingConfigWith True KM.empty) unusedManager
      isJust (lookupProvider (unsafeBankProviderId "monobank") reg) `shouldBe` True
      registryBankProviderIds reg `shouldBe` Set.singleton (unsafeBankProviderId "monobank")

    it "still includes monobank when its settings carry an api_base_url override" $ do
      let settingsObj = KM.fromList ["api_base_url" .= ("https://mock.example" :: Text)]
          reg = buildRegistry (bankingConfigWith True settingsObj) unusedManager
      isJust (lookupProvider (unsafeBankProviderId "monobank") reg) `shouldBe` True

    it "excludes monobank when its config entry is disabled" $ do
      let reg = buildRegistry (bankingConfigWith False KM.empty) unusedManager
      registryBankProviderIds reg `shouldBe` Set.empty

    it "yields an empty registry when there is no monobank config entry at all" $ do
      let cfg = BankingConfig {enabled = True, providers = Map.empty, tokenEncKey = ""}
          reg = buildRegistry cfg unusedManager
      registryBankProviderIds reg `shouldBe` Set.empty

  describe "provider coverage tags" $ do
    let ua = RegionalCoverage (Set.singleton (unsafeCountry "UA"))
    it "monobank is UA-regional" $ do
      let monobank = Monobank.descriptorFromConfig (bankingConfigWith True KM.empty) unusedManager
      monobank.coverage `shouldBe` ua
    it "privatbank is UA-regional"
      $ PrivatBank.descriptor.coverage
      `shouldBe` ua
    it "privatbank-business is UA-regional"
      $ PrivatBankBusiness.descriptor.coverage
      `shouldBe` ua
