{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.LinkCodeStorePropertySpec (spec) where

import Application.LinkCodeStore
  ( issueAt,
    newLinkCodeStore,
    redeemAt,
    unLinkCodeToken,
  )
import Control.Monad (replicateM)
import qualified Data.Time as Time
import qualified Data.UUID.V4 as UUID
import Domain.Core.Types (UserId, mkUserId)
import RIO
import qualified RIO.HashSet as HashSet
import Test.Hspec
import Test.QuickCheck
import qualified Test.QuickCheck.Monadic as QCM

genUserId :: IO UserId
genUserId = do
  u <- UUID.nextRandom
  case mkUserId u of
    Right uid -> pure uid
    Left e -> fail (show e)

spec :: Spec
spec = describe "LinkCodeStore properties" $ do
  it "issuing for N distinct users yields N distinct active tokens"
    $ property
    $ \(Positive (Small n)) ->
      n <= 50 ==>
        QCM.monadicIO $ do
          store <- QCM.run newLinkCodeStore
          now <- QCM.run Time.getCurrentTime
          toks <- QCM.run $ replicateM n $ do
            uid <- genUserId
            fst <$> issueAt store uid 600 now
          QCM.assert (HashSet.size (HashSet.fromList (map unLinkCodeToken toks)) == n)

  it "redeem is observationally equivalent to redeem >> redeem (idempotent by deletion)"
    $ property
    $ QCM.monadicIO
    $ do
      store <- QCM.run newLinkCodeStore
      now <- QCM.run Time.getCurrentTime
      uid <- QCM.run genUserId
      (tok, _) <- QCM.run $ issueAt store uid 600 now
      r1 <- QCM.run $ redeemAt store tok now
      r2 <- QCM.run $ redeemAt store tok now
      r3 <- QCM.run $ redeemAt store tok now
      QCM.assert (r1 == Just uid && isNothing r2 && isNothing r3)
