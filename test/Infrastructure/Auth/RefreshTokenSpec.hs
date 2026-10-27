{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.RefreshTokenSpec (spec) where

import qualified Data.Char as Char
import Infrastructure.Auth.RefreshToken
import RIO
import qualified RIO.Text as T
import Test.Hspec

spec :: Spec
spec = describe "refresh token crypto" $ do
  it "generates 43-char unpadded base64url tokens that differ" $ do
    a <- newRefreshToken
    b <- newRefreshToken
    T.length (unRefreshToken a) `shouldBe` 43
    T.all (\c -> Char.isAlphaNum c || c == '-' || c == '_') (unRefreshToken a) `shouldBe` True
    unRefreshToken a `shouldNotBe` unRefreshToken b
  it "hashes deterministically to 64 hex chars that never equal the token" $ do
    t <- newRefreshToken
    let h = unRefreshTokenHash (hashRefreshToken t)
    T.length h `shouldBe` 64
    T.all Char.isHexDigit h `shouldBe` True
    hashRefreshToken t `shouldBe` hashRefreshToken t
    h `shouldNotBe` unRefreshToken t
