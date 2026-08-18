{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Localization.CountrySpec (spec) where

import Data.Aeson (decode, encode)
import qualified Data.Set as Set
import Domain.Localization.Country
  ( Country,
    euroAreaCountries,
    mkCountry,
    supportedCountries,
    unCountry,
    unsafeCountry,
  )
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Country" $ do
  it "accepts supported codes (US, UA, a euro-area member), normalizing case/space" $ do
    fmap unCountry (mkCountry "US") `shouldBe` Right "US"
    fmap unCountry (mkCountry "ua") `shouldBe` Right "UA"
    fmap unCountry (mkCountry " de ") `shouldBe` Right "DE"

  it "rejects malformed codes" $ do
    mkCountry "U" `shouldSatisfy` isLeft
    mkCountry "USA" `shouldSatisfy` isLeft
    mkCountry "1A" `shouldSatisfy` isLeft

  it "rejects well-formed but unsupported codes" $ do
    mkCountry "ZZ" `shouldSatisfy` isLeft
    mkCountry "JP" `shouldSatisfy` isLeft

  it "supported set is US + UA + euro-area"
    $ supportedCountries
    `shouldBe` Set.insert "US" (Set.insert "UA" euroAreaCountries)

  it "round-trips JSON as the plain code" $ do
    encode (unsafeCountry "DE") `shouldBe` "\"DE\""
    fmap unCountry (decode "\"UA\"" :: Maybe Country) `shouldBe` Just "UA"
