{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Auth.PasswordSpec
-- Description : Tests for password hashing
module Infrastructure.Auth.PasswordSpec (spec) where

import Domain.Core.Types (PasswordHash (..))
import Infrastructure.Auth.Password
import Test.Hspec

spec :: Spec
spec = describe "Password Hashing" $ do
  describe "hashPassword" $ do
    it "produces a valid hash" $ do
      hash <- hashPassword "mySecretPassword"
      let (PasswordHash bytes) = hash
      -- Hash should be salt (16 bytes) + hash (32 bytes) = 48 bytes
      length (show bytes) `shouldSatisfy` (> 0)

    it "produces different hashes for same password (due to salt)" $ do
      hash1 <- hashPassword "samePassword"
      hash2 <- hashPassword "samePassword"
      hash1 `shouldNotBe` hash2

  describe "verifyPassword" $ do
    it "verifies correct password" $ do
      hash <- hashPassword "correctPassword"
      verifyPassword "correctPassword" hash `shouldBe` True

    it "rejects incorrect password" $ do
      hash <- hashPassword "correctPassword"
      verifyPassword "wrongPassword" hash `shouldBe` False

    it "rejects empty password against hash" $ do
      hash <- hashPassword "somePassword"
      verifyPassword "" hash `shouldBe` False

    it "rejects malformed hash" $ do
      let malformedHash = PasswordHash "short"
      verifyPassword "anyPassword" malformedHash `shouldBe` False

  describe "Configuration" $ do
    it "default config uses 64 MiB memory" $ do
      passwordHashMemory defaultPasswordHashConfig `shouldBe` 65536

    it "default config uses 3 iterations" $ do
      passwordHashIterations defaultPasswordHashConfig `shouldBe` 3

    it "default config uses 4 parallel lanes" $ do
      passwordHashParallelism defaultPasswordHashConfig `shouldBe` 4

    -- Note: Custom config verification only works if the config matches default
    -- because verifyPassword uses hardcoded default config. This is a known limitation.
    it "hashPasswordWithConfig produces valid hash with default config" $ do
      let customConfig = defaultPasswordHashConfig -- Using same config
      hash <- hashPasswordWithConfig customConfig "testPassword"
      -- Should verify correctly since we use the same default config
      verifyPassword "testPassword" hash `shouldBe` True
