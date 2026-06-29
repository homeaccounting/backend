{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Database.OrphansSpec
-- Description : Round-trip properties for read-model id 'PersistField' instances.
--
-- A persisted read model is only correct if the ids it stores in columns
-- decode back to the exact value that was written. These properties pin that
-- invariant for the id types used as columns.
module Infrastructure.Database.OrphansSpec (spec) where

import Database.Persist (PersistField (..))
import Domain.Core.Types
  ( AccountRole (..),
    AccountStatus (..),
    AccountType (..),
    ExternalTransactionId,
    defaultBankAccount,
    unsafeExternalTransactionId,
  )
import Infrastructure.Database.Orphans ()
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, arbitrary, forAll, listOf1, suchThat)
import Testkit.Generators (genAccountId, genMoney, genTransactionId, genUserId)

-- | Generate a non-empty 'ExternalTransactionId' (the smart constructor rejects
-- empty text).
genExternalTransactionId :: Gen ExternalTransactionId
genExternalTransactionId =
  unsafeExternalTransactionId
    . T.pack
    <$> listOf1 (suchThat arbitrary (/= '\NUL'))

spec :: Spec
spec = describe "Infrastructure.Database.Orphans" $ do
  prop "ExternalTransactionId round-trips through PersistValue"
    $ forAll genExternalTransactionId
    $ \extId ->
      fromPersistValue (toPersistValue extId) `shouldBe` Right extId

  prop "TransactionId round-trips through PersistValue"
    $ forAll genTransactionId
    $ \txId ->
      fromPersistValue (toPersistValue txId) `shouldBe` Right txId

  prop "AccountId round-trips through PersistValue"
    $ forAll genAccountId
    $ \accId ->
      fromPersistValue (toPersistValue accId) `shouldBe` Right accId

  prop "UserId round-trips through PersistValue"
    $ forAll genUserId
    $ \uid ->
      fromPersistValue (toPersistValue uid) `shouldBe` Right uid

  prop "Money round-trips through PersistValue (JSON column)"
    $ forAll genMoney
    $ \m ->
      fromPersistValue (toPersistValue m) `shouldBe` Right m

  it "AccountRole / AccountStatus / AccountType round-trip through PersistValue" $ do
    let roundTrips x = fromPersistValue (toPersistValue x) `shouldBe` Right x
    mapM_ roundTrips [Owner, Editor, Viewer]
    mapM_ roundTrips [Opened, Closed]
    roundTrips External
    roundTrips (Regular defaultBankAccount)
