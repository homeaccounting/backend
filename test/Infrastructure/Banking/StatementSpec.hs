{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.StatementSpec (spec) where

import Data.Ratio ((%))
import Data.Time (LocalTime (..), TimeOfDay (..), UTCTime (..), fromGregorian, timeOfDayToTime)
import Data.Time.Zones.All (TZLabel (..))
import Infrastructure.Banking.Statement (assembleNumber, isNumericToken, localToUtcIn, parseSignedDecimal, stripTrailingComma)
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "parseSignedDecimal" $ do
    it "parses an unsigned integer" $ parseSignedDecimal "43000" `shouldBe` Just (43000 % 1)
    it "parses a signed fractional amount" $ parseSignedDecimal "-6919.91" `shouldBe` Just ((-691991) % 100)
    it "rejects non-numeric text" $ parseSignedDecimal "abc" `shouldBe` Nothing
    it "rejects the empty string" $ parseSignedDecimal "" `shouldBe` Nothing

  describe "isNumericToken" $ do
    it "accepts digits, decimal point, comma and grouping spaces" $ do
      isNumericToken "918.99," `shouldBe` True
      isNumericToken "10" `shouldBe` True
      isNumericToken "000.00" `shouldBe` True
    it "rejects the empty string and non-numeric tokens" $ do
      isNumericToken "" `shouldBe` False
      isNumericToken "USD" `shouldBe` False

  describe "assembleNumber" $ do
    it "joins a run, dropping grouping spaces/NBSP and a trailing comma" $ do
      assembleNumber ["10", "000.00,"] `shouldBe` "10000.00"
      assembleNumber ["918.99,"] `shouldBe` "918.99"
      assembleNumber ["10\160\&000.00"] `shouldBe` "10000.00"

  describe "stripTrailingComma" $ do
    it "drops a single trailing comma and is a no-op otherwise" $ do
      stripTrailingComma "918.99," `shouldBe` "918.99"
      stripTrailingComma "USD" `shouldBe` "USD"

  describe "localToUtcIn" $ do
    it "converts a summer (EEST, +3) Kyiv wall clock"
      $ localToUtcIn Europe__Kiev (LocalTime (fromGregorian 2026 8 6) (TimeOfDay 11 9 20))
      `shouldBe` UTCTime (fromGregorian 2026 8 6) (timeOfDayToTime (TimeOfDay 8 9 20))

    it "converts a winter (EET, +2) Kyiv wall clock"
      $ localToUtcIn Europe__Kiev (LocalTime (fromGregorian 2026 1 15) (TimeOfDay 11 9 20))
      `shouldBe` UTCTime (fromGregorian 2026 1 15) (timeOfDayToTime (TimeOfDay 9 9 20))

    it "rolls back a day when the local clock is just after midnight"
      $ localToUtcIn Europe__Kiev (LocalTime (fromGregorian 2026 8 9) (TimeOfDay 0 2 57))
      `shouldBe` UTCTime (fromGregorian 2026 8 8) (timeOfDayToTime (TimeOfDay 21 2 57))
