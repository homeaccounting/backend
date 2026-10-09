{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.RefreshTokenPropertySpec (spec) where

import Data.Time (UTCTime, addUTCTime)
import qualified Data.UUID as UUID
import Infrastructure.Auth.RefreshToken
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators (genUTCTime, genUserId)

genFamilyId :: Gen FamilyId
genFamilyId = mkFamilyId <$> (UUID.fromWords <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary)

-- | A stored token whose expiry is strictly after @now@ (live) or at/before it.
genStored :: UTCTime -> Bool -> Gen StoredRefreshToken
genStored now live = do
  uid <- genUserId
  fam <- genFamilyId
  delta <- fromIntegral <$> (choose (1, 10000000) :: Gen Int)
  rotated <- oneof [pure Nothing, Just <$> genUTCTime]
  revoked <- oneof [pure Nothing, Just <$> genUTCTime]
  let expires = if live then addUTCTime delta now else addUTCTime (negate delta + 1) now
  pure StoredRefreshToken {userId = uid, familyId = fam, expiresAt = expires, rotatedAt = rotated, revokedAt = revoked}

spec :: Spec
spec = describe "decideRefresh" $ do
  it "rejects an unknown token"
    $ forAll genUTCTime
    $ \now -> decideRefresh now Nothing === Reject RefreshUnknown

  it "rejects an expired token as expired, whatever its rotated/revoked state"
    $ forAll genUTCTime
    $ \now -> forAll (genStored now False) $ \s ->
      decideRefresh now (Just s) === Reject RefreshExpired

  it "revokes the family when a live token was already rotated or revoked"
    $ forAll genUTCTime
    $ \now -> forAll (genStored now True) $ \s ->
      (isJust s.rotatedAt || isJust s.revokedAt) ==>
        decideRefresh now (Just s) === RevokeFamily s.familyId

  it "rotates a live, never-used token with its stored user and family"
    $ forAll genUTCTime
    $ \now -> forAll (genStored now True) $ \s0 ->
      let s = s0 {rotatedAt = Nothing, revokedAt = Nothing}
       in decideRefresh now (Just s) === Rotate s.userId s.familyId
