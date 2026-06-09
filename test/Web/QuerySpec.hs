{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.QuerySpec
-- Description : Tests for comma-separated query-param parsing.
module Web.QuerySpec (spec) where

import qualified Data.List.NonEmpty as NE
import Domain.Transaction.Projection (StatusKind (..))
import RIO
import Servant (parseQueryParam)
import Test.Hspec
import Web.Query (CommaSep (..))

parseStatuses :: Text -> Either Text (NE.NonEmpty StatusKind)
parseStatuses raw = (.values) <$> (parseQueryParam raw :: Either Text (CommaSep StatusKind))

spec :: Spec
spec = do
  describe "CommaSep StatusKind" $ do
    it "parses a single value"
      $ parseStatuses "failed"
      `shouldBe` Right (FailedKind NE.:| [])

    it "parses multiple values"
      $ parseStatuses "failed,cancelled"
      `shouldBe` Right (FailedKind NE.:| [CancelledKind])

    it "trims whitespace around tokens"
      $ parseStatuses " failed , cancelled "
      `shouldBe` Right (FailedKind NE.:| [CancelledKind])

    it "rejects an empty element"
      $ parseStatuses "failed,,cancelled"
      `shouldSatisfy` isLeft

    it "rejects an empty string"
      $ parseStatuses ""
      `shouldSatisfy` isLeft

    it "rejects an unknown token"
      $ parseStatuses "failed,bogus"
      `shouldSatisfy` isLeft
