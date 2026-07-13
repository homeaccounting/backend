{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.RegistrySpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Domain.Banking.Types (unsafeBankProviderId)
import Infrastructure.Banking.Provider
  ( BankProviderDescriptor (..),
    TransactionClassification (..),
    defaultClassify,
  )
import Infrastructure.Banking.Registry
  ( assembleRegistry,
    lookupProvider,
    registryBankProviderIds,
    registryFromList,
  )
import Infrastructure.Config (BankingConfig (..), ProviderSettings (..))
import RIO
import Test.Hspec
import Testkit.BankingHelpers (sampleBankTransaction)

-- | A minimal descriptor carrying only the given id (function fields are
-- irrelevant to registry assembly, which keys purely off 'providerId').
mkDescriptor :: Text -> BankProviderDescriptor
mkDescriptor slug =
  BankProviderDescriptor
    { providerId = unsafeBankProviderId slug,
      displayName = slug,
      classify = defaultClassify,
      pull = Nothing,
      fileImport = Nothing
    }

-- | A 'BankingConfig' whose @providers@ map carries one entry per (slug,
-- enabled) pair; the master @enabled@ flag is irrelevant to assembly.
bankingConfigWith :: [(Text, Bool)] -> BankingConfig
bankingConfigWith entries =
  BankingConfig
    { enabled = True,
      providers =
        Map.fromList
          [ (unsafeBankProviderId slug, ProviderSettings {enabled = en, settings = mempty})
          | (slug, en) <- entries
          ],
      tokenEncKey = ""
    }

spec :: Spec
spec = do
  let d =
        BankProviderDescriptor
          { providerId = unsafeBankProviderId "monobank",
            displayName = "Monobank",
            classify = defaultClassify,
            pull = Nothing,
            fileImport = Nothing
          }
      reg = registryFromList [d]

  describe "registry" $ do
    it "looks a descriptor up by id"
      $ fmap (.displayName) (lookupProvider (unsafeBankProviderId "monobank") reg)
      `shouldBe` Just "Monobank"
    it "misses an unknown id"
      $
      -- BankProviderDescriptor holds function fields, so it has no Eq/Show
      -- instance; assert absence via isNothing instead of `shouldBe Nothing`.
      isNothing (lookupProvider (unsafeBankProviderId "nope") reg)
      `shouldBe` True
    it "exposes its id set"
      $ registryBankProviderIds reg
      `shouldBe` Set.singleton (unsafeBankProviderId "monobank")

  describe "assembleRegistry" $ do
    let assembledIds entries descriptors =
          registryBankProviderIds (assembleRegistry (bankingConfigWith entries) descriptors)

    it "includes a descriptor whose id is enabled in config, keyed by its providerId"
      $ assembledIds [("monobank", True)] [mkDescriptor "monobank"]
      `shouldBe` Set.singleton (unsafeBankProviderId "monobank")

    it "excludes a descriptor whose id is present but disabled"
      $ assembledIds [("monobank", False)] [mkDescriptor "monobank"]
      `shouldBe` Set.empty

    it "excludes a descriptor whose id has no config entry"
      $ assembledIds [] [mkDescriptor "monobank"]
      `shouldBe` Set.empty

    it "keeps only the enabled descriptors when several candidates are present"
      $ assembledIds
        [("monobank", True), ("privat", False)]
        [mkDescriptor "monobank", mkDescriptor "privat"]
      `shouldBe` Set.singleton (unsafeBankProviderId "monobank")

    it "yields an empty registry for an empty descriptor list"
      $ assembledIds [("monobank", True)] []
      `shouldBe` Set.empty

    it "yields an empty registry when every candidate is disabled"
      $ assembledIds [("monobank", False)] [mkDescriptor "monobank"]
      `shouldBe` Set.empty

  describe "defaultClassify" $ do
    it "classifies a negative amount as expense"
      $ defaultClassify (sampleBankTransaction (-5))
      `shouldBe` ClassifiedExpense
    it "classifies a non-negative amount as income"
      $ defaultClassify (sampleBankTransaction 5)
      `shouldBe` ClassifiedIncome
