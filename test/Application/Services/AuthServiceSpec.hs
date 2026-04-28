{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AuthServiceSpec
-- Description : Unit tests for AuthService — OAuth callback decision tree.
--
-- Drives 'linkOrSignInWithOAuth' and 'linkOAuthIdentityToUser' directly with
-- handcrafted 'OAuthUserInfo' values, bypassing the HTTP layer in
-- 'Infrastructure.Auth.OAuth'.
module Application.Services.AuthServiceSpec (spec) where

import Application.ReadModels.User (getUserByOAuthIdentity)
import Application.Services.AuthService
  ( AuthResult (..),
    linkOAuthIdentityToUser,
    linkOrSignInWithOAuth,
  )
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.App (AppEnv (..), runAppM)
import qualified Infrastructure.Auth.OAuth as OAuth
import RIO
import Test.Hspec
import Testkit.Fixtures (registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv)

-- -----------------------------------------------------------------------------
-- Test data
-- -----------------------------------------------------------------------------

-- | A baseline OAuth userinfo with the verified-email signal set. Tests override
-- specific fields with record update syntax.
mkUserInfo :: Text -> Text -> Bool -> OAuth.OAuthUserInfo
mkUserInfo subj email verified =
  OAuth.OAuthUserInfo
    { OAuth.subject = subj,
      OAuth.email = Just email,
      OAuth.emailVerified = verified,
      OAuth.name = Nothing,
      OAuth.picture = Nothing
    }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  describe "linkOrSignInWithOAuth" $ do
    it "auto-links a verified Google email to the existing email/password user" $ do
      env <- createTestAppEnv
      existingUid <- registerUser env "alice@example.com"

      let userInfo = mkUserInfo "google-subject-1" "alice@example.com" True
      res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
      case res of
        Right auth -> auth.userId `shouldBe` existingUid
        Left err -> expectationFailure $ "expected Right, got Left: " <> show err

      -- The OAuth identity is now attached to the existing user.
      linked <- getUserByOAuthIdentity env.userReadModel Google "google-subject-1"
      case linked of
        Just (uid, _) -> uid `shouldBe` existingUid
        Nothing -> expectationFailure "expected the OAuth identity to be linked to the existing user"

    it "creates a new user when email is unverified, even if it matches an existing user" $ do
      env <- createTestAppEnv
      existingUid <- registerUser env "bob@example.com"

      let userInfo = mkUserInfo "google-subject-2" "bob@example.com" False
      res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
      case res of
        Right auth -> auth.userId `shouldNotBe` existingUid
        Left err -> expectationFailure $ "expected Right, got Left: " <> show err

    it "creates a new user when no pre-existing user has this email" $ do
      env <- createTestAppEnv

      let userInfo = mkUserInfo "google-subject-3" "fresh@example.com" True
      res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
      case res of
        Right _ -> pure () -- new user, any userId
        Left err -> expectationFailure $ "expected Right, got Left: " <> show err

      -- The new user is now reachable via the OAuth identity.
      linked <- getUserByOAuthIdentity env.userReadModel Google "google-subject-3"
      case linked of
        Just _ -> pure ()
        Nothing -> expectationFailure "expected the new user to be reachable via OAuth identity"

    it "signs in the same user on a repeat OAuth callback (no extra link emitted)" $ do
      env <- createTestAppEnv

      let userInfo = mkUserInfo "google-subject-4" "diana@example.com" True
      res1 <- runAppM env $ linkOrSignInWithOAuth Google userInfo
      res2 <- runAppM env $ linkOrSignInWithOAuth Google userInfo
      case (res1, res2) of
        (Right a1, Right a2) -> a1.userId `shouldBe` a2.userId
        (Left e, _) -> expectationFailure $ "expected first Right, got Left: " <> show e
        (_, Left e) -> expectationFailure $ "expected second Right, got Left: " <> show e

    it "rejects with ValidationErr when the OAuth provider returns no email" $ do
      env <- createTestAppEnv

      let userInfo = (mkUserInfo "google-subject-5" "ignored" True) {OAuth.email = Nothing}
      res <- runAppM env $ linkOrSignInWithOAuth Google userInfo
      case res of
        Left (ValidationErr _) -> pure ()
        Left err -> expectationFailure $ "expected ValidationErr, got: " <> show err
        Right _ -> expectationFailure "expected Left ValidationErr"

  describe "linkOAuthIdentityToUser" $ do
    it "links a Google identity to the user, keyed on the userinfo subject" $ do
      env <- createTestAppEnv
      uid <- registerUser env "alice@example.com"

      let userInfo = mkUserInfo "google-stable-sub-1" "alice@example.com" True
      res <- runAppM env $ linkOAuthIdentityToUser uid Google userInfo
      case res of
        Right () -> pure ()
        Left err -> expectationFailure $ "expected Right, got Left: " <> show err

      -- The identity is keyed on userinfo.subject (not on any auth code).
      linked <- getUserByOAuthIdentity env.userReadModel Google "google-stable-sub-1"
      case linked of
        Just (linkedUid, _) -> linkedUid `shouldBe` uid
        Nothing -> expectationFailure "expected the OAuth identity to be linked to the user"

    it "rejects when the OAuth identity is already linked to another user" $ do
      env <- createTestAppEnv
      uidA <- registerUser env "alice@example.com"
      uidB <- registerUser env "bob@example.com"

      let userInfo = mkUserInfo "google-stable-sub-2" "alice@example.com" True
      _ <- runAppM env $ linkOAuthIdentityToUser uidA Google userInfo

      res <- runAppM env $ linkOAuthIdentityToUser uidB Google userInfo
      case res of
        Left (AccountError _) -> pure ()
        Left err -> expectationFailure $ "expected AccountError, got: " <> show err
        Right _ -> expectationFailure "expected Left AccountError"
