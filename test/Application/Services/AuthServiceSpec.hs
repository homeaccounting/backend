{-# LANGUAGE OverloadedRecordDot #-}
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

import Application.LinkCodeStore (LinkCodeToken, mkLinkCodeToken, redeemAt)
import Application.ReadModels.User (getUserByOAuthIdentity, getUserByTelegramId)
import Application.Services.AuthService
  ( AuthResult (..),
    TelegramLinkCodeResult (..),
    issueTelegramLinkCode,
    linkOAuthIdentityToUser,
    linkOrSignInWithOAuth,
    redeemTelegramLinkCode,
  )
import Data.Time (addUTCTime, getCurrentTime)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (OAuthProvider (..), TelegramIdentity (..))
import Infrastructure.App (AppEnv (..), runAppM)
import qualified Infrastructure.Auth.OAuth as OAuth
import Infrastructure.Auth.Telegram (TelegramConfig (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.Fixtures (registerUser)
import Testkit.Helpers (mockTelegramId)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

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
      linked <- runDbIn env (getUserByOAuthIdentity Google "google-subject-1")
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
      linked <- runDbIn env (getUserByOAuthIdentity Google "google-subject-3")
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
      linked <- runDbIn env (getUserByOAuthIdentity Google "google-stable-sub-1")
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

  describe "issueTelegramLinkCode" $ do
    it "returns a deep-link of the correct shape and the token round-trips through the store" $ do
      env <- createTestAppEnv
      uid <- registerUser env "alice@example.com"
      let tgCfg = env.telegramConfig
          linkCodeStore = env.linkCodeStore

      res <- runAppM env $ issueTelegramLinkCode uid
      case res of
        Left err -> expectationFailure $ "expected Right, got Left: " <> show err
        Right result -> do
          let dl = result.deepLink
              expectedPrefix = "https://t.me/" <> tgCfg.botUsername <> "?start=LINK_"
          dl `shouldSatisfy` T.isPrefixOf expectedPrefix
          let tok = mkLinkCodeToken (T.drop (T.length expectedPrefix) dl)
          now <- getCurrentTime
          let futureNow = addUTCTime 1 now
          mUid <- redeemAt linkCodeStore tok futureNow
          mUid `shouldBe` Just uid

    it "replaces a prior code for the same user — the old token becomes unredeemable" $ do
      env <- createTestAppEnv
      uid <- registerUser env "bob@example.com"
      let tgCfg = env.telegramConfig
          linkCodeStore = env.linkCodeStore
          prefix = "https://t.me/" <> tgCfg.botUsername <> "?start=LINK_"

      res1 <- runAppM env $ issueTelegramLinkCode uid
      tok1 <- case res1 of
        Left err -> fail $ "first issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ mkLinkCodeToken (T.drop (T.length prefix) r.deepLink)

      res2 <- runAppM env $ issueTelegramLinkCode uid
      tok2 <- case res2 of
        Left err -> fail $ "second issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ mkLinkCodeToken (T.drop (T.length prefix) r.deepLink)

      now <- getCurrentTime
      let futureNow = addUTCTime 1 now
      mUid1 <- redeemAt linkCodeStore tok1 futureNow
      mUid1 `shouldBe` Nothing

      mUid2 <- redeemAt linkCodeStore tok2 futureNow
      mUid2 `shouldBe` Just uid

  describe "redeemTelegramLinkCode" $ do
    let tgIdentX =
          TelegramIdentity
            { id = mockTelegramId 111111,
              username = Just "alice_tg",
              firstName = "Alice"
            }
        tgIdentY =
          TelegramIdentity
            { id = mockTelegramId 222222,
              username = Just "bob_tg",
              firstName = "Bob"
            }
        extractToken :: TelegramLinkCodeResult -> TelegramConfig -> LinkCodeToken
        extractToken result tgCfg =
          let prefix = "https://t.me/" <> tgCfg.botUsername <> "?start=LINK_"
           in mkLinkCodeToken (T.drop (T.length prefix) result.deepLink)

    it "happy path — redeems code and links Telegram identity to issuing user" $ do
      env <- createTestAppEnv
      uid <- registerUser env "alice@example.com"

      issueRes <- runAppM env $ issueTelegramLinkCode uid
      tok <- case issueRes of
        Left err -> fail $ "issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ extractToken r env.telegramConfig

      res <- runAppM env $ redeemTelegramLinkCode tok tgIdentX
      case res of
        Left err -> expectationFailure $ "expected Right, got Left: " <> show err
        Right returnedUid -> do
          returnedUid `shouldBe` uid
          linked <- runDbIn env (getUserByTelegramId tgIdentX.id)
          case linked of
            Nothing -> expectationFailure "expected Telegram identity to be linked after redemption"
            Just (linkedUid, _) -> linkedUid `shouldBe` uid

    it "token unknown / never issued — returns NotFound" $ do
      env <- createTestAppEnv

      res <- runAppM env $ redeemTelegramLinkCode (mkLinkCodeToken "not-a-real-token") tgIdentX
      case res of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "expected NotFound, got: " <> show err
        Right _ -> expectationFailure "expected Left NotFound"

    it "token already consumed — second redeem returns NotFound and no duplicate event emitted" $ do
      env <- createTestAppEnv
      uid <- registerUser env "alice@example.com"

      issueRes <- runAppM env $ issueTelegramLinkCode uid
      tok <- case issueRes of
        Left err -> fail $ "issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ extractToken r env.telegramConfig

      res1 <- runAppM env $ redeemTelegramLinkCode tok tgIdentX
      case res1 of
        Left err -> expectationFailure $ "first redeem expected Right, got Left: " <> show err
        Right _ -> pure ()

      res2 <- runAppM env $ redeemTelegramLinkCode tok tgIdentX
      case res2 of
        Left (NotFound _ _) -> pure ()
        Left err -> expectationFailure $ "expected NotFound on second redeem, got: " <> show err
        Right _ -> expectationFailure "expected Left NotFound on second redeem"

    it "cross-user collision — Telegram ID already linked to another user fails with AccountError" $ do
      env <- createTestAppEnv
      uidA <- registerUser env "alice@example.com"
      uidB <- registerUser env "bob@example.com"

      -- Link tgIdentX to user A
      issueResA <- runAppM env $ issueTelegramLinkCode uidA
      tokA <- case issueResA of
        Left err -> fail $ "issueTelegramLinkCode for A failed: " <> show err
        Right r -> pure $ extractToken r env.telegramConfig
      resA <- runAppM env $ redeemTelegramLinkCode tokA tgIdentX
      case resA of
        Left err -> expectationFailure $ "linking tgIdentX to user A failed: " <> show err
        Right _ -> pure ()

      -- User B issues a code and redeems with the same Telegram identity X
      issueResB <- runAppM env $ issueTelegramLinkCode uidB
      tokB <- case issueResB of
        Left err -> fail $ "issueTelegramLinkCode for B failed: " <> show err
        Right r -> pure $ extractToken r env.telegramConfig
      resB <- runAppM env $ redeemTelegramLinkCode tokB tgIdentX
      case resB of
        Left (AccountError _) -> pure ()
        Left err -> expectationFailure $ "expected AccountError, got: " <> show err
        Right _ -> expectationFailure "expected Left AccountError"

    it "target user already has a different Telegram linked — aggregate guard fires" $ do
      env <- createTestAppEnv
      uidA <- registerUser env "alice@example.com"

      -- Link tgIdentX to user A
      issueRes1 <- runAppM env $ issueTelegramLinkCode uidA
      tok1 <- case issueRes1 of
        Left err -> fail $ "first issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ extractToken r env.telegramConfig
      res1 <- runAppM env $ redeemTelegramLinkCode tok1 tgIdentX
      case res1 of
        Left err -> expectationFailure $ "linking tgIdentX to user A failed: " <> show err
        Right _ -> pure ()

      -- Issue again for user A and try to link a different Telegram identity Y
      issueRes2 <- runAppM env $ issueTelegramLinkCode uidA
      tok2 <- case issueRes2 of
        Left err -> fail $ "second issueTelegramLinkCode failed: " <> show err
        Right r -> pure $ extractToken r env.telegramConfig
      res2 <- runAppM env $ redeemTelegramLinkCode tok2 tgIdentY
      res2 `shouldSatisfy` isLeft
