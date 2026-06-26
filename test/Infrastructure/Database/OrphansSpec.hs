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
import Domain.Core.Types (ExternalTransactionId, unsafeExternalTransactionId)
import Infrastructure.Database.Orphans ()
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, arbitrary, forAll, listOf1, suchThat)
import Testkit.Generators (genTransactionId)

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
