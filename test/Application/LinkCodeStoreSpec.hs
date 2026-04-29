{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.LinkCodeStoreSpec (spec) where

import Application.LinkCodeStore
  ( LinkCodeStore,
    LinkCodeToken,
    issueAt,
    newLinkCodeStore,
    redeemAt,
  )
import Data.Time (UTCTime, addUTCTime)
import qualified Data.Time as Time
import qualified Data.UUID.V4 as UUID
import Domain.Core.Types (UserId, mkUserId)
import RIO
import qualified RIO.List as L
import Test.Hspec

aUserId :: IO UserId
aUserId = do
  u <- UUID.nextRandom
  case mkUserId u of
    Right uid -> pure uid
    Left e -> fail (show e)

ttl :: Time.NominalDiffTime
ttl = 600 -- 10 min

spec :: Spec
spec = describe "Application.LinkCodeStore" $ do
  it "issue stores a token redeemable to the issuing user" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _exp) <- issueAt store uid ttl now
    redeemed <- redeemAt store tok now
    redeemed `shouldBe` Just uid

  it "issue replaces a prior code for the same user (only the latest is redeemable)" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tokOld, _) <- issueAt store uid ttl now
    (tokNew, _) <- issueAt store uid ttl now
    redeemAt store tokOld now `shouldReturn` Nothing
    redeemAt store tokNew now `shouldReturn` Just uid

  it "redeem is single-use" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    redeemAt store tok now `shouldReturn` Just uid
    redeemAt store tok now `shouldReturn` Nothing

  it "redeem returns Nothing for an expired token" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    let later = addUTCTime (ttl + 1) now
    redeemAt store tok later `shouldReturn` Nothing

  it "redeem returns Nothing for an unknown (already-consumed) token" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    _ <- redeemAt store tok now
    redeemAt store tok now `shouldReturn` Nothing

  it "concurrent redeem of the same token: exactly one wins" $ do
    store <- newLinkCodeStore
    uid <- aUserId
    now <- Time.getCurrentTime
    (tok, _) <- issueAt store uid ttl now
    results <- mapConcurrently (const (redeemAt store tok now)) [(1 :: Int) .. 32]
    length (L.filter (== Just uid) results) `shouldBe` 1
    length (L.filter (== Nothing) results) `shouldBe` 31
