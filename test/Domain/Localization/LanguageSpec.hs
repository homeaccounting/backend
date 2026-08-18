{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Localization.LanguageSpec (spec) where

import Data.Aeson (decode, encode)
import Domain.Localization.Language (Language (..), languageCode, parseLanguage)
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Domain.Localization.Language" $ do
  it "round-trips code <-> value" $ do
    parseLanguage (languageCode En) `shouldBe` Right En
    parseLanguage (languageCode Uk) `shouldBe` Right Uk

  it "parses lowercase ISO 639-1 codes, trimming and case-folding" $ do
    parseLanguage "en" `shouldBe` Right En
    parseLanguage "UK" `shouldBe` Right Uk
    parseLanguage "  uk " `shouldBe` Right Uk

  it "rejects unsupported codes" $ do
    parseLanguage "ua" `shouldSatisfy` isLeft
    parseLanguage "fr" `shouldSatisfy` isLeft

  it "encodes JSON as the lowercase code (not the constructor name)" $ do
    -- Encode is pinned to the lowercase code; deriveJSON would emit "En"/"Uk".
    encode En `shouldBe` "\"en\""
    encode Uk `shouldBe` "\"uk\""
    (decode "\"uk\"" :: Maybe Language) `shouldBe` Just Uk
    -- Decode is case-insensitive (mirrors Currency's parseCurrency), but still
    -- rejects codes outside the supported set.
    (decode "\"fr\"" :: Maybe Language) `shouldBe` Nothing
