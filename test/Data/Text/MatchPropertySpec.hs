{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Data.Text.MatchPropertySpec (spec) where

import Data.Text.Match (MatchResult (..), matchByName, normalizeName)
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "Data.Text.Match properties" $ do
  it "a unique non-blank name matches itself (any casing)"
    $ property
    $ \(s :: String) ->
      let n = T.pack s
       in not (T.null (normalizeName n)) ==>
            matchByName id (T.toUpper n) [n] === Matched n
  it "normalizeName is idempotent"
    $ property
    $ \(s :: String) ->
      let n = T.pack s in normalizeName (normalizeName n) === normalizeName n
  it "duplicate identical names are Ambiguous"
    $ property
    $ \(s :: String) ->
      let n = T.pack s
       in not (T.null (normalizeName n)) ==>
            matchByName id n [n, n] === Ambiguous [n, n]
