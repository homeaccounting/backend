{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.RefreshTokenStoreSpec (spec) where

import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Infrastructure.Auth.RefreshToken
import Infrastructure.Auth.RefreshTokenStore
import RIO
import Test.Hspec
import Testkit.Fixtures (registerUser)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)

day :: NominalDiffTime
day = 86400

spec :: Spec
spec = describe "RefreshTokenStore" $ do
  it "finds a started family's token as live and unrotated" $ do
    env <- createTestAppEnv
    uid <- registerUser env "store1@example.com"
    now <- getCurrentTime
    tok <- runDbIn env (startFamily (60 * day) uid now)
    Just s <- runDbIn env (findRefreshToken (hashRefreshToken tok))
    s.userId `shouldBe` uid
    s.rotatedAt `shouldBe` Nothing
    s.revokedAt `shouldBe` Nothing
    s.expiresAt `shouldBe` addUTCTime (60 * day) now

  it "markRotated wins once, then loses" $ do
    env <- createTestAppEnv
    uid <- registerUser env "store2@example.com"
    now <- getCurrentTime
    tok <- runDbIn env (startFamily (60 * day) uid now)
    runDbIn env (markRotated (hashRefreshToken tok) now) `shouldReturn` True
    runDbIn env (markRotated (hashRefreshToken tok) now) `shouldReturn` False

  it "revokeFamily revokes a successor issued earlier in the family" $ do
    env <- createTestAppEnv
    uid <- registerUser env "store3@example.com"
    now <- getCurrentTime
    first <- runDbIn env (startFamily (60 * day) uid now)
    Just s <- runDbIn env (findRefreshToken (hashRefreshToken first))
    Just next <- runDbIn env (issueSuccessor (60 * day) uid s.familyId now)
    runDbIn env (revokeFamily s.familyId now)
    Just n <- runDbIn env (findRefreshToken (hashRefreshToken next))
    n.revokedAt `shouldBe` Just now
    Just f <- runDbIn env (findRefreshToken (hashRefreshToken first))
    f.revokedAt `shouldBe` Just now
    runDbIn env (markRotated (hashRefreshToken next) now) `shouldReturn` False

  it "revokeFamily revokes live rows and leaves expired ones alone" $ do
    env <- createTestAppEnv
    uid <- registerUser env "revoke-expired@example.com"
    now <- getCurrentTime
    let past = addUTCTime (-(2 * day)) now
    first <- runDbIn env (startFamily (60 * day) uid now)
    Just s <- runDbIn env (findRefreshToken (hashRefreshToken first))
    -- issued at a past time so its prune removes nothing and the row stays expired
    Just old <- runDbIn env (issueSuccessor day uid s.familyId past)
    runDbIn env (revokeFamily s.familyId now)
    Just f <- runDbIn env (findRefreshToken (hashRefreshToken first))
    f.revokedAt `shouldBe` Just now
    o <- runDbIn env (findRefreshToken (hashRefreshToken old))
    fmap (.revokedAt) o `shouldBe` Just Nothing

  it "issueSuccessor refuses a revoked family" $ do
    env <- createTestAppEnv
    uid <- registerUser env "store4@example.com"
    now <- getCurrentTime
    tok <- runDbIn env (startFamily (60 * day) uid now)
    Just s <- runDbIn env (findRefreshToken (hashRefreshToken tok))
    runDbIn env (revokeFamily s.familyId now)
    r <- runDbIn env (issueSuccessor (60 * day) uid s.familyId now)
    isNothing r `shouldBe` True

  it "prunes only that user's expired rows when issuing" $ do
    env <- createTestAppEnv
    alice <- registerUser env "prune-a@example.com"
    bob <- registerUser env "prune-b@example.com"
    now <- getCurrentTime
    let past = addUTCTime (-(2 * day)) now
    oldAlice <- runDbIn env (startFamily day alice past) -- expired yesterday
    oldBob <- runDbIn env (startFamily day bob past)
    liveAlice <- runDbIn env (startFamily (60 * day) alice now) -- triggers the prune for alice
    runDbIn env (findRefreshToken (hashRefreshToken oldAlice)) >>= (`shouldSatisfy` isNothing)
    runDbIn env (findRefreshToken (hashRefreshToken oldBob)) >>= (`shouldSatisfy` isJust)
    -- the issueSuccessor path prunes too, and keeps the user's own live rows
    Just live <- runDbIn env (findRefreshToken (hashRefreshToken liveAlice))
    Just next <- runDbIn env (issueSuccessor (60 * day) alice live.familyId now)
    runDbIn env (findRefreshToken (hashRefreshToken next)) >>= (`shouldSatisfy` isJust)
    runDbIn env (findRefreshToken (hashRefreshToken oldAlice)) >>= (`shouldSatisfy` isNothing)

  it "claimFamily is True for a live family and False once revoked" $ do
    env <- createTestAppEnv
    uid <- registerUser env "claim@example.com"
    now <- getCurrentTime
    tok <- runDbIn env (startFamily (60 * day) uid now)
    Just s <- runDbIn env (findRefreshToken (hashRefreshToken tok))
    runDbIn env (claimFamily s.familyId) `shouldReturn` True
    runDbIn env (revokeFamily s.familyId now)
    runDbIn env (claimFamily s.familyId) `shouldReturn` False
