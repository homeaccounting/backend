{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Banking.TypesPropertySpec (spec) where

import qualified Data.Set as Set
import Domain.Banking.Types (mkBankProviderId, unBankProviderId, unsafeBankProviderId)
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Testkit.Generators ()

spec :: Spec
spec = describe "mkBankProviderId" $ do
  let known = Set.fromList [unsafeBankProviderId "monobank", unsafeBankProviderId "privatbank"]

  it "accepts an id present in the known set"
    $ mkBankProviderId known "monobank"
    `shouldBe` Right (unsafeBankProviderId "monobank")

  it "rejects an id absent from the known set"
    $ mkBankProviderId known "revolut"
    `shouldSatisfy` isLeft

  prop "round-trips text for any accepted id" $ \(t :: Text) ->
    let s = Set.singleton (unsafeBankProviderId t)
     in fmap unBankProviderId (mkBankProviderId s t) == Right t
