{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Auth.OAuthSpec (spec) where

import qualified Data.ByteString.Lazy.Char8 as LBS
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (OAuthUserInfo (..), parseUserInfo)
import Test.Hspec

spec :: Spec
spec = describe "parseUserInfo (Google)" $ do
  it "sets emailVerified=True when Google returns email_verified=true" $ do
    let body =
          LBS.pack
            "{\"id\":\"g-1\",\"email\":\"alice@example.com\",\"email_verified\":true,\"name\":\"Alice\"}"
    case parseUserInfo Google body of
      Just info -> do
        info.subject `shouldBe` "g-1"
        info.email `shouldBe` Just "alice@example.com"
        info.emailVerified `shouldBe` True
      Nothing -> expectationFailure "expected Just"

  it "sets emailVerified=False when Google returns email_verified=false" $ do
    let body =
          LBS.pack
            "{\"id\":\"g-2\",\"email\":\"bob@example.com\",\"email_verified\":false}"
    case parseUserInfo Google body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"

  it "defaults emailVerified=False when Google omits the email_verified claim" $ do
    -- Older Google responses or non-OIDC variants may omit the claim entirely.
    let body =
          LBS.pack
            "{\"id\":\"g-3\",\"email\":\"carol@example.com\"}"
    case parseUserInfo Google body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"

  it "defaults emailVerified=False for the GitHub parser" $ do
    -- GitHub's basic /user endpoint doesn't return email_verified.
    let body = LBS.pack "{\"id\":42,\"email\":\"dan@example.com\",\"login\":\"dan\"}"
    case parseUserInfo GitHub body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"

  it "defaults emailVerified=False for the Microsoft parser" $ do
    let body =
          LBS.pack
            "{\"id\":\"ms-1\",\"mail\":\"eve@example.com\",\"displayName\":\"Eve\"}"
    case parseUserInfo Microsoft body of
      Just info -> info.emailVerified `shouldBe` False
      Nothing -> expectationFailure "expected Just"
