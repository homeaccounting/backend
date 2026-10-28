{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.IdTokenSpec (spec) where

import Crypto.JOSE (Alg (HS256), KeyMaterialGenParam (..), genJWK, jwkKid)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Base64.URL as B64URL
import qualified Data.ByteString.Lazy as LBS
import Data.Time (addUTCTime, getCurrentTime)
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.IdToken
import Infrastructure.Auth.OAuth (OAuthUserInfo (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.IdTokens

spec :: Spec
spec = describe "verifyIdToken" $ do
  let verify = verifyIdToken testIdTokenConfig

  it "accepts a valid Google token and maps the claims" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tok <- signIdToken k (baseClaims Google now)
    verify Google (testJwkSet k) now tok "n-1"
      `shouldBe` Right OAuthUserInfo {subject = "sub-1", email = Just "u@example.com", emailVerified = True, name = Nothing, picture = Nothing}

  it "accepts Apple's string email_verified and the bare Google issuer" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tokA <- signIdToken k (KM.insert "email_verified" "true" (baseClaims Apple now))
    fmap (.emailVerified) (verify Apple (testJwkSet k) now tokA "n-1") `shouldBe` Right True
    tokG <- signIdToken k (KM.insert "iss" "accounts.google.com" (baseClaims Google now))
    fmap (.subject) (verify Google (testJwkSet k) now tokG "n-1") `shouldBe` Right "sub-1"

  it "treats a missing email_verified as unverified" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tok <- signIdToken k (KM.delete "email_verified" (baseClaims Google now))
    fmap (.emailVerified) (verify Google (testJwkSet k) now tok "n-1") `shouldBe` Right False

  describe "rejects" $ do
    let rejectsWith claimsF nonce expected = do
          k <- testRsaKey
          now <- getCurrentTime
          tok <- signIdToken k (claimsF (baseClaims Google now))
          verify Google (testJwkSet k) now tok nonce `shouldBe` Left expected

    it "a wrong audience" $ rejectsWith (KM.insert "aud" "someone-else") "n-1" WrongAudience
    it "a wrong issuer" $ rejectsWith (KM.insert "iss" "https://evil.example") "n-1" WrongIssuer
    it "an Apple issuer on a Google token" $ rejectsWith (KM.insert "iss" "https://appleid.apple.com") "n-1" WrongIssuer
    it "a nonce mismatch" $ rejectsWith id "other" NonceMismatch
    it "a missing nonce claim" $ rejectsWith (KM.delete "nonce") "n-1" NonceMismatch
    it "an empty request nonce, even against an empty claim" $ rejectsWith (KM.insert "nonce" "") "" NonceMismatch
    it "a missing subject" $ rejectsWith (KM.delete "sub") "n-1" MissingSubject
    -- jose skips iss/aud/exp checks when the claim is absent, so we enforce presence.
    it "a missing audience" $ rejectsWith (KM.delete "aud") "n-1" WrongAudience
    it "a missing issuer" $ rejectsWith (KM.delete "iss") "n-1" WrongIssuer
    it "a missing expiry" $ rejectsWith (KM.delete "exp") "n-1" Expired

    it "an expired token beyond the 60 s skew, but not within it" $ do
      k <- testRsaKey
      now <- getCurrentTime
      tok <- signIdToken k (baseClaims Google now) -- exp = now + 600
      verify Google (testJwkSet k) (addUTCTime 630 now) tok "n-1" `shouldSatisfy` isRight
      verify Google (testJwkSet k) (addUTCTime 700 now) tok "n-1" `shouldBe` Left Expired

    it "a signature from a different key with the same kid" $ do
      k <- testRsaKey
      other <- testRsaKey
      now <- getCurrentTime
      tok <- signIdToken other (baseClaims Google now)
      verify Google (testJwkSet k) now tok "n-1" `shouldBe` Left BadSignature

    it "a kid not in the key set" $ do
      k <- testRsaKey
      k2 <- genJWK (RSAGenParam 256)
      now <- getCurrentTime
      tok <- signIdToken (set jwkKid (Just "k2") k2) (baseClaims Google now)
      verify Google (testJwkSet k) now tok "n-1" `shouldBe` Left UnknownKeyId

    it "alg none" $ do
      k <- testRsaKey
      now <- getCurrentTime
      let b64 = decodeUtf8Lenient . B64URL.encodeUnpadded . LBS.toStrict . Aeson.encode
          tok = b64 (Aeson.object ["alg" Aeson..= ("none" :: Text), "kid" Aeson..= ("k1" :: Text)]) <> "." <> b64 (Aeson.Object (baseClaims Google now)) <> "."
      tokenKeyId tok `shouldBe` Left UnsupportedAlgorithm
      verify Google (testJwkSet k) now tok "n-1" `shouldBe` Left UnsupportedAlgorithm

    it "HS256" $ do
      k <- testRsaKey
      hk <- genJWK (OctGenParam 32)
      now <- getCurrentTime
      -- signIdToken picks the alg from the key type; sign HS256 explicitly here.
      tok <- signIdTokenWithAlg (set jwkKid (Just "k1") hk) HS256 (baseClaims Google now)
      verify Google (testJwkSet k) now tok "n-1" `shouldBe` Left UnsupportedAlgorithm

    it "garbage" $ do
      k <- testRsaKey
      now <- getCurrentTime
      verify Google (testJwkSet k) now "not-a-jwt" "n-1" `shouldSatisfy` either (\case MalformedToken _ -> True; _ -> False) (const False)

  it "never puts the token in a rejection" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tok <- signIdToken k (KM.insert "aud" "x" (baseClaims Google now))
    either (T.isInfixOf tok . tshow) (const False) (verify Google (testJwkSet k) now tok "n-1") `shouldBe` False

  describe "tokenKeyId" $ do
    it "returns the kid of an RS256 token" $ do
      k <- testRsaKey
      now <- getCurrentTime
      tok <- signIdToken k (baseClaims Google now)
      tokenKeyId tok `shouldBe` Right (Just "k1")

  describe "jwkSetHasKeyId" $ do
    it "finds a published kid and nothing else" $ do
      k <- testRsaKey
      jwkSetHasKeyId (testJwkSet k) "k1" `shouldBe` True
      jwkSetHasKeyId (testJwkSet k) "k2" `shouldBe` False
