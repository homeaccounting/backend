{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.ExternalIdSpec
-- Description : Pins the synthesized external-id format (ADR 004).
--
-- The golden cases below are the enforcement that commit 38968e9 lacked: it
-- changed the PrivatBank retail derivation in place, gave every
-- already-imported row a second identity, and broke import dedup in production
-- with no failing test. Changing the derivation MUST fail this spec. If a
-- change is genuinely wanted, it ships with a normalizer and these strings are
-- updated deliberately — never incidentally.
module Infrastructure.Banking.ExternalIdSpec (spec) where

import qualified Data.Text as T
import Domain.Banking.Import (unExternalTransactionId, unsafeExternalTransactionId)
import Infrastructure.Banking.ExternalId
  ( normalizePrivatBankRetailId,
    privatBankRetailExternalId,
    privatBankRetailPrefix,
  )
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Positive (..), Property, conjoin, (===))

-- | Normalize via raw text, for brevity in the assertions below.
norm :: Text -> Text
norm = unExternalTransactionId . normalizePrivatBankRetailId . unsafeExternalTransactionId

spec :: Spec
spec = do
  describe "privatBankRetailExternalId (GOLDEN — see module haddock)" $ do
    it "tags retail ids with the privatbank: prefix"
      $ privatBankRetailPrefix
      `shouldBe` "privatbank:"

    it "keys the AliExpress double-conversion row"
      $ privatBankRetailExternalId "06.08.2026 11:09:20" "-1221.17" "-19593.46"
      `shouldBe` "privatbank:06.08.2026 11:09:20:(-122117) % 100:(-979673) % 50"

    it "keys the YouTube Premium row"
      $ privatBankRetailExternalId "04.08.2026 14:02:50" "-149.0" "-17835.51"
      `shouldBe` "privatbank:04.08.2026 14:02:50:(-149) % 1:(-1783551) % 100"

    it "keys a positive (own-card credit) row"
      $ privatBankRetailExternalId "01.08.2026 18:34:46" "16998.0" "-15771.83"
      `shouldBe` "privatbank:01.08.2026 18:34:46:16998 % 1:(-1577183) % 100"

    it "keys the repo's CSV fixture row"
      $ privatBankRetailExternalId "10.07.2026 03:30:50" "-281" "87654.32"
      `shouldBe` "privatbank:10.07.2026 03:30:50:(-281) % 1:2191358 % 25"

    it "is spelling-independent: CSV and XLSX renderings agree"
      $ privatBankRetailExternalId "04.08.2026 14:02:50" "-149" "-17835.51"
      `shouldBe` privatBankRetailExternalId "04.08.2026 14:02:50" "-149.0" "-17835.51"

  describe "normalizePrivatBankRetailId" $ do
    it "repairs a pre-38968e9 key to the current derivation"
      $ norm "privatbank:06.08.2026 11:09:20:-1221.17:-19593.46"
      `shouldBe` "privatbank:06.08.2026 11:09:20:(-122117) % 100:(-979673) % 50"

    it "repairs a legacy whole-number amount (the YouTube Premium case)"
      $ norm "privatbank:04.08.2026 14:02:50:-149:-17835.51"
      `shouldBe` "privatbank:04.08.2026 14:02:50:(-149) % 1:(-1783551) % 100"

    it "leaves an already-canonical key untouched"
      $ norm "privatbank:06.08.2026 11:09:20:(-122117) % 100:(-979673) % 50"
      `shouldBe` "privatbank:06.08.2026 11:09:20:(-122117) % 100:(-979673) % 50"

    it "preserves the colons inside the date field"
      $ norm "privatbank:04.08.2026 14:02:50:-149:-17835.51"
      `shouldSatisfy` T.isInfixOf "04.08.2026 14:02:50"

    it "passes a Monobank id through unchanged"
      $ norm "a1b2c3d4-0000-0000-0000-000000000000"
      `shouldBe` "a1b2c3d4-0000-0000-0000-000000000000"

    it "passes a business-statement Референс through unchanged"
      $ norm "PB-2026-0000123456"
      `shouldBe` "PB-2026-0000123456"

    it "leaves a prefixed but malformed key untouched"
      $ norm "privatbank:no-colon-fields"
      `shouldBe` "privatbank:no-colon-fields"

    it "reaches canonical form in one pass with whitespace-padded fields"
      $ norm "privatbank:04.08.2026 14:02:50: -149 :-17835.51"
      `shouldBe` "privatbank:04.08.2026 14:02:50:(-149) % 1:(-1783551) % 100"

    prop "is idempotent for legacy-spelled keys" propIdempotent
    prop "collapses trailing-zero spellings of the same value" propSpellingAgnostic

-- | Idempotence over the LEGACY spelling space, which is what the dedup
-- projection actually reads: bare integers, raw decimals, and whitespace-padded
-- fields. Built by concatenation and never via 'privatBankRetailExternalId',
-- because the projection sees stored ids, never freshly-constructed ones.
propIdempotent :: Integer -> Integer -> Property
propIdempotent units frac =
  conjoin
    [ check (tshow units) (tshow frac),
      check (decimal units frac) (decimal frac units),
      check (" " <> tshow units <> " ") ("\t" <> decimal units frac <> " ")
    ]
  where
    check amount balance =
      let legacy = "privatbank:06.08.2026 11:09:20:" <> amount <> ":" <> balance
       in norm (norm legacy) === norm legacy
    decimal whole part = tshow whole <> "." <> tshow (abs part `mod` 100)

-- | "-80" and "-80.0" are the same money and must key identically — the CSV
-- (pre-38968e9) vs XLSX (current) spelling difference.
propSpellingAgnostic :: Positive Integer -> Property
propSpellingAgnostic (Positive n) =
  privatBankRetailExternalId "06.08.2026 11:09:20" (tshow n) "-1.5"
    === privatBankRetailExternalId "06.08.2026 11:09:20" (tshow n <> ".0") "-1.5"
