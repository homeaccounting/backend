{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Localization.PresetSpec (spec) where

import Domain.Core.Types (Currency (..))
import Domain.Localization.Country (unsafeCountry)
import Domain.Localization.Language (Language (..))
import Domain.Localization.Preset (CountryPreset (..), presetFor)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Preset" $ do
  it "US -> English + USD"
    $ presetFor (unsafeCountry "US")
    `shouldBe` CountryPreset En (Just USD) (Just USD)

  it "UA -> Ukrainian + UAH"
    $ presetFor (unsafeCountry "UA")
    `shouldBe` CountryPreset Uk (Just UAH) (Just UAH)

  it "euro-area member -> English + EUR"
    $ presetFor (unsafeCountry "DE")
    `shouldBe` CountryPreset En (Just EUR) (Just EUR)

  it "uncovered code -> English + no currency (fallback)"
    $ presetFor (unsafeCountry "ZZ")
    `shouldBe` CountryPreset En Nothing Nothing
