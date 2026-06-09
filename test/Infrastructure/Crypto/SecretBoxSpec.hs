{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Crypto.SecretBoxSpec (spec) where

import qualified Data.ByteString as BS
import Infrastructure.Crypto.SecretBox
import Test.Hspec

ring :: KeyRing
ring = mkKeyRing 1 [(1, BS.replicate 32 7)]

spec :: Spec
spec = describe "Infrastructure.Crypto.SecretBox" $ do
  it "round-trips a token (encrypt then decrypt == identity)" $ do
    enc <- encryptSecret ring "u_abc123token"
    enc.keyVersion `shouldBe` 1
    decryptSecret ring enc `shouldBe` Right "u_abc123token"
  it "produces a different nonce each call (random nonce)" $ do
    a <- encryptSecret ring "same"
    b <- encryptSecret ring "same"
    (a.nonce == b.nonce) `shouldBe` False
  it "fails to decrypt when the auth tag is tampered" $ do
    enc <- encryptSecret ring "secret"
    let bad = enc {authTag = "AAAAAAAAAAAAAAAAAAAAAA=="}
    decryptSecret ring bad `shouldSatisfy` isLeftDecrypt
  it "fails to decrypt with an unknown key version" $ do
    enc <- encryptSecret ring "secret"
    let other = mkKeyRing 2 [(2, BS.replicate 32 9)]
    decryptSecret other enc `shouldSatisfy` isLeftDecrypt
  where
    isLeftDecrypt (Left _) = True
    isLeftDecrypt _ = False
