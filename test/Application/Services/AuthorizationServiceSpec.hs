{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Application.Services.AuthorizationServiceSpec
-- Description : Tests for Authorization service RBAC rules
module Application.Services.AuthorizationServiceSpec (spec) where

import Application.Services.AuthorizationService
import Data.Maybe (fromJust)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Core.Types
import Test.Hspec

-- Helper to create safe user IDs
mkTestUserId :: UUID -> Maybe UserId
mkTestUserId uuid = case mkUserId uuid of
  Right uid -> Just uid
  Left _ -> Nothing

-- Helper to create safe account IDs
mkTestAccountId :: UUID -> Maybe AccountId
mkTestAccountId uuid = case mkAccountId uuid of
  Right aid -> Just aid
  Left _ -> Nothing

-- Test data helpers
testUserId1 :: UserId
testUserId1 = fromJust $ mkTestUserId (UUID.fromWords 1 0 0 0)

testUserId2 :: UserId
testUserId2 = fromJust $ mkTestUserId (UUID.fromWords 2 0 0 0)

testUserId3 :: UserId
testUserId3 = fromJust $ mkTestUserId (UUID.fromWords 3 0 0 0)

testAccountId1 :: AccountId
testAccountId1 = fromJust $ mkTestAccountId (UUID.fromWords 10 0 0 0)

testAccountId2 :: AccountId
testAccountId2 = fromJust $ mkTestAccountId (UUID.fromWords 20 0 0 0)

-- Create account auth data with specified creator and access list
mkAuthData :: UserId -> AccountKind -> [AccountAccess] -> AccountAuthData
mkAuthData = AccountAuthData

spec :: Spec
spec = describe "AuthorizationService" $ do
  describe "canAccessAccount" $ do
    it "grants access if user is in access list with Owner role" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canAccessAccount testUserId1 accountData `shouldBe` AccessGranted Owner

    it "grants access if user is in access list with Editor role" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canAccessAccount testUserId2 accountData `shouldBe` AccessGranted Editor

    it "grants access if user is in access list with Viewer role" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Viewer]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canAccessAccount testUserId2 accountData `shouldBe` AccessGranted Viewer

    it "denies access if user is not in access list" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canAccessAccount testUserId3 accountData `shouldBe` AccessDenied

    it "grants Owner access to creator even if not in list" $ do
      let accessList = [] -- Empty access list
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canAccessAccount testUserId1 accountData `shouldBe` AccessGranted Owner

  describe "canModifyAccount" $ do
    it "returns True for Owner" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canModifyAccount testUserId1 accountData `shouldBe` True

    it "returns True for Editor" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canModifyAccount testUserId2 accountData `shouldBe` True

    it "returns False for Viewer" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Viewer]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canModifyAccount testUserId2 accountData `shouldBe` False

    it "returns False for no access" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canModifyAccount testUserId3 accountData `shouldBe` False

  describe "canManageAccount" $ do
    it "returns True for Owner" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canManageAccount testUserId1 accountData `shouldBe` True

    it "returns False for Editor" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canManageAccount testUserId2 accountData `shouldBe` False

    it "returns False for Viewer" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Viewer]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canManageAccount testUserId2 accountData `shouldBe` False

  describe "canTransfer" $ do
    it "authorizes transfer between accounts user can modify as Owner" $ do
      let sourceAccessList = [AccountAccess testUserId1 Owner]
          targetAccessList = [AccountAccess testUserId1 Owner]
          sourceData = mkAuthData testUserId1 (Regular defaultCash) sourceAccessList
          targetData = mkAuthData testUserId1 (Regular defaultCash) targetAccessList
      canTransfer testUserId1 sourceData targetData testAccountId1 testAccountId2 `shouldBe` TransferAuthorized

    it "authorizes transfer between accounts user can modify as Editor" $ do
      let sourceAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          targetAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          sourceData = mkAuthData testUserId1 (Regular defaultCash) sourceAccessList
          targetData = mkAuthData testUserId1 (Regular defaultCash) targetAccessList
      canTransfer testUserId2 sourceData targetData testAccountId1 testAccountId2 `shouldBe` TransferAuthorized

    it "denies if user can't modify source (Viewer)" $ do
      let sourceAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Viewer]
          targetAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          sourceData = mkAuthData testUserId1 (Regular defaultCash) sourceAccessList
          targetData = mkAuthData testUserId1 (Regular defaultCash) targetAccessList
      canTransfer testUserId2 sourceData targetData testAccountId1 testAccountId2 `shouldBe` TransferDenied (InsufficientRoleOnSource Viewer)

    it "denies if user can't modify target (Viewer)" $ do
      let sourceAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          targetAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Viewer]
          sourceData = mkAuthData testUserId1 (Regular defaultCash) sourceAccessList
          targetData = mkAuthData testUserId1 (Regular defaultCash) targetAccessList
      canTransfer testUserId2 sourceData targetData testAccountId1 testAccountId2 `shouldBe` TransferDenied (InsufficientRoleOnTarget Viewer)

    it "denies if user has no access to source" $ do
      let sourceAccessList = [AccountAccess testUserId1 Owner]
          targetAccessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          sourceData = mkAuthData testUserId1 (Regular defaultCash) sourceAccessList
          targetData = mkAuthData testUserId1 (Regular defaultCash) targetAccessList
      canTransfer testUserId2 sourceData targetData testAccountId1 testAccountId2 `shouldBe` TransferDenied NoAccessToSource

    it "denies transfer to same account" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          sourceData = mkAuthData testUserId1 (Regular defaultCash) accessList
          targetData = mkAuthData testUserId1 (Regular defaultCash) accessList
      canTransfer testUserId1 sourceData targetData testAccountId1 testAccountId1 `shouldBe` TransferDenied SameSourceAndTarget

  describe "Role Permission Matrix" $ do
    describe "Owner" $ do
      let accessList = [AccountAccess testUserId1 Owner]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList

      it "can view" $ do
        case canAccessAccount testUserId1 accountData of
          AccessGranted _ -> pure ()
          AccessDenied -> expectationFailure "Expected access to be granted"

      it "can transfer" $ do
        canModifyAccount testUserId1 accountData `shouldBe` True

      it "can manage (share/revoke/delete)" $ do
        canManageAccount testUserId1 accountData `shouldBe` True

    describe "Editor" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Editor]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList

      it "can view" $ do
        case canAccessAccount testUserId2 accountData of
          AccessGranted Editor -> pure ()
          _ -> expectationFailure "Expected Editor access"

      it "can transfer" $ do
        canModifyAccount testUserId2 accountData `shouldBe` True

      it "cannot manage (share/revoke/delete)" $ do
        canManageAccount testUserId2 accountData `shouldBe` False

    describe "Viewer" $ do
      let accessList = [AccountAccess testUserId1 Owner, AccountAccess testUserId2 Viewer]
          accountData = mkAuthData testUserId1 (Regular defaultCash) accessList

      it "can view" $ do
        case canAccessAccount testUserId2 accountData of
          AccessGranted Viewer -> pure ()
          _ -> expectationFailure "Expected Viewer access"

      it "cannot transfer" $ do
        canModifyAccount testUserId2 accountData `shouldBe` False

      it "cannot manage (share/revoke/delete)" $ do
        canManageAccount testUserId2 accountData `shouldBe` False
