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
import Infrastructure.Auth.OAuth (IdTokenConfig (..), OAuthUserInfo (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.IdTokens

spec :: Spec
spec = do
  verifySpec
  bindNonceSpec
  canonicalServerUrlSpec
  acceptedServerUrlsSpec

verifySpec :: Spec
verifySpec = describe "verifyIdToken" $ do
  let verify p ks now = verifyIdToken testIdTokenConfig p ks now [testServerUrl]

  it "accepts a valid Google token and maps the claims" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tok <- signIdToken k (baseClaims Google now)
    verify Google (testJwkSet k) now tok testRawNonce
      `shouldBe` Right OAuthUserInfo {subject = "sub-1", email = Just "u@example.com", emailVerified = True, name = Nothing, picture = Nothing}

  it "accepts Apple's string email_verified and the bare Google issuer" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tokA <- signIdToken k (KM.insert "email_verified" "true" (baseClaims Apple now))
    fmap (.emailVerified) (verify Apple (testJwkSet k) now tokA testRawNonce) `shouldBe` Right True
    tokG <- signIdToken k (KM.insert "iss" "accounts.google.com" (baseClaims Google now))
    fmap (.subject) (verify Google (testJwkSet k) now tokG testRawNonce) `shouldBe` Right "sub-1"

  it "treats a missing email_verified as unverified" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tok <- signIdToken k (KM.delete "email_verified" (baseClaims Google now))
    fmap (.emailVerified) (verify Google (testJwkSet k) now tok testRawNonce) `shouldBe` Right False

  describe "rejects" $ do
    let rejectsWith claimsF nonce expected = do
          k <- testRsaKey
          now <- getCurrentTime
          tok <- signIdToken k (claimsF (baseClaims Google now))
          verify Google (testJwkSet k) now tok nonce `shouldBe` Left expected

    it "a wrong audience" $ rejectsWith (KM.insert "aud" "someone-else") testRawNonce WrongAudience
    it "a wrong issuer" $ rejectsWith (KM.insert "iss" "https://evil.example") testRawNonce WrongIssuer
    it "an Apple issuer on a Google token" $ rejectsWith (KM.insert "iss" "https://appleid.apple.com") testRawNonce WrongIssuer
    it "a nonce mismatch" $ rejectsWith id "other-raw-nonce-000" NonceMismatch
    it "a missing nonce claim" $ rejectsWith (KM.delete "nonce") testRawNonce NonceMismatch
    it "an unbound nonce claim equal to the raw nonce" $ rejectsWith (KM.insert "nonce" (Aeson.String testRawNonce)) testRawNonce NonceMismatch
    -- C1: a token a malicious server obtained for itself must not work here.
    it "a nonce bound to another server" $ rejectsWith (KM.insert "nonce" (Aeson.String (bindNonce "https://evil.example" testRawNonce))) testRawNonce NonceMismatch
    it "an empty raw nonce, even against an empty claim" $ rejectsWith (KM.insert "nonce" "") "" NonceTooShort
    it "a raw nonce shorter than 16 characters" $ do
      let raw = "fifteen-chars-x"
      rejectsWith (KM.insert "nonce" (Aeson.String (bindNonce testServerUrl raw))) raw NonceTooShort
    it "a missing subject" $ rejectsWith (KM.delete "sub") testRawNonce MissingSubject
    -- jose skips iss/aud/exp checks when the claim is absent, so we enforce presence.
    it "a missing audience" $ rejectsWith (KM.delete "aud") testRawNonce WrongAudience
    it "a missing issuer" $ rejectsWith (KM.delete "iss") testRawNonce WrongIssuer
    it "a missing expiry" $ rejectsWith (KM.delete "exp") testRawNonce Expired

    it "an expired token beyond the 60 s skew, but not within it" $ do
      k <- testRsaKey
      now <- getCurrentTime
      tok <- signIdToken k (baseClaims Google now) -- exp = now + 600
      verify Google (testJwkSet k) (addUTCTime 630 now) tok testRawNonce `shouldSatisfy` isRight
      verify Google (testJwkSet k) (addUTCTime 700 now) tok testRawNonce `shouldBe` Left Expired

    it "a signature from a different key with the same kid" $ do
      k <- testRsaKey
      other <- testRsaKey
      now <- getCurrentTime
      tok <- signIdToken other (baseClaims Google now)
      verify Google (testJwkSet k) now tok testRawNonce `shouldBe` Left BadSignature

    it "a kid not in the key set" $ do
      k <- testRsaKey
      k2 <- genJWK (RSAGenParam 256)
      now <- getCurrentTime
      tok <- signIdToken (set jwkKid (Just "k2") k2) (baseClaims Google now)
      verify Google (testJwkSet k) now tok testRawNonce `shouldBe` Left UnknownKeyId

    it "alg none" $ do
      k <- testRsaKey
      now <- getCurrentTime
      let b64 = decodeUtf8Lenient . B64URL.encodeUnpadded . LBS.toStrict . Aeson.encode
          tok = b64 (Aeson.object ["alg" Aeson..= ("none" :: Text), "kid" Aeson..= ("k1" :: Text)]) <> "." <> b64 (Aeson.Object (baseClaims Google now)) <> "."
      tokenKeyId tok `shouldBe` Left UnsupportedAlgorithm
      verify Google (testJwkSet k) now tok testRawNonce `shouldBe` Left UnsupportedAlgorithm

    it "HS256" $ do
      k <- testRsaKey
      hk <- genJWK (OctGenParam 32)
      now <- getCurrentTime
      -- signIdToken picks the alg from the key type; sign HS256 explicitly here.
      tok <- signIdTokenWithAlg (set jwkKid (Just "k1") hk) HS256 (baseClaims Google now)
      verify Google (testJwkSet k) now tok testRawNonce `shouldBe` Left UnsupportedAlgorithm

    it "garbage" $ do
      k <- testRsaKey
      now <- getCurrentTime
      verify Google (testJwkSet k) now "not-a-jwt" testRawNonce `shouldSatisfy` either (\case MalformedToken _ -> True; _ -> False) (const False)

  it "accepts a 16-character raw nonce" $ do
    k <- testRsaKey
    now <- getCurrentTime
    let raw = "sixteen-chars-xx"
    tok <- signIdToken k (KM.insert "nonce" (Aeson.String (bindNonce testServerUrl raw)) (baseClaims Google now))
    verify Google (testJwkSet k) now tok raw `shouldSatisfy` isRight

  it "accepts a nonce bound to any accepted server URL" $ do
    k <- testRsaKey
    now <- getCurrentTime
    let lan = "http://192.168.1.10:8080"
    tok <- signIdToken k (KM.insert "nonce" (Aeson.String (bindNonce lan testRawNonce)) (baseClaims Google now))
    verifyIdToken testIdTokenConfig Google (testJwkSet k) now [testServerUrl, lan] tok testRawNonce `shouldSatisfy` isRight
    verifyIdToken testIdTokenConfig Google (testJwkSet k) now [testServerUrl] tok testRawNonce `shouldBe` Left NonceMismatch

  it "never puts the token in a rejection" $ do
    k <- testRsaKey
    now <- getCurrentTime
    tok <- signIdToken k (KM.insert "aud" "x" (baseClaims Google now))
    either (T.isInfixOf tok . tshow) (const False) (verify Google (testJwkSet k) now tok testRawNonce) `shouldBe` False

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

bindNonceSpec :: Spec
bindNonceSpec = describe "bindNonce" $ do
  -- Known-answer vectors shared with the mobile app (spec §3.2).
  it "matches the hosted-server vector"
    $ bindNonce "https://homeaccounting.com" "r-123"
    `shouldBe` "K4QXi6gzIoAkDVeKWiHoKBylOAijdXPO2jzk6TbzR50"
  it "matches the LAN-server vector"
    $ bindNonce "http://192.168.1.10:8080" "r-123"
    `shouldBe` "QQmXHq-J6DZRuqC0ijWP2ps2PRHuAk4sFTxarI5iiSQ"

canonicalServerUrlSpec :: Spec
canonicalServerUrlSpec = describe "canonicalServerUrl" $ do
  let ok i o = it (T.unpack i) $ canonicalServerUrl i `shouldBe` Right o
      bad i = it ("rejects " <> T.unpack i) $ canonicalServerUrl i `shouldSatisfy` isLeft
  ok "HTTPS://HomeAccounting.com:443/" "https://homeaccounting.com"
  ok "http://192.168.1.10:8080/" "http://192.168.1.10:8080"
  ok "https://x.example/base/" "https://x.example/base"
  ok "http://h:80" "http://h"
  ok "https://h:80" "https://h:80"
  ok "http://[::1]:8080" "http://[::1]:8080"
  bad "ftp://h"
  bad "https://h/?q=1"
  bad "https://h/#f"
  bad "https://user@h"
  bad "not a url"
  bad "https://"
  bad "https://h:"
  bad "https://h:x"
  bad "https://h:99999"

acceptedServerUrlsSpec :: Spec
acceptedServerUrlsSpec = describe "acceptedServerUrls" $ do
  it "canonicalises api_base_url and the extra URLs, without duplicates"
    $ acceptedServerUrls "http://localhost:8080/" testIdTokenConfig {serverUrls = ["HTTP://LOCALHOST:8080", "https://box.example:443"]}
    `shouldBe` Right ["http://localhost:8080", "https://box.example"]
  it "fails on an invalid URL"
    $ acceptedServerUrls "http://localhost:8080" testIdTokenConfig {serverUrls = ["ftp://box"]}
    `shouldSatisfy` isLeft
