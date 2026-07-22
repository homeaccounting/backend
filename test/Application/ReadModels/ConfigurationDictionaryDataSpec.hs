{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Application.ReadModels.ConfigurationDictionaryDataSpec
-- Description : Properties for the DictionaryData tree accessors.
--
-- The clone path replays @AddDictionaryEntry@ in
-- 'dictionaryEntriesParentFirst' order, so its parent-before-child guarantee is
-- load-bearing and is asserted directly here (rather than only through the
-- integration clone test).
module Application.ReadModels.ConfigurationDictionaryDataSpec (spec) where

import Application.ReadModels.Configuration
  ( DictionaryData (..),
    dictionaryEntriesParentFirst,
    dictionaryItemIds,
    dictionaryItems,
  )
import Domain.Configuration.Dictionary (DictionaryEntry (..), EntryRole (..), buildDictionaryTree)
import RIO.List (elemIndex)
import qualified RIO.Set as Set
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll)
import Testkit.Generators (genDictionaryTree)

-- | Build the read-model 'DictionaryData' the way 'loadDictionaries' does: from
-- a flat entry list via the domain materialiser.
mkData :: [DictionaryEntry] -> DictionaryData
mkData = DictionaryData . buildDictionaryTree

spec :: Spec
spec = describe "DictionaryData accessors" $ do
  prop "dictionaryEntriesParentFirst lists every parent before its children" $
    forAll genDictionaryTree $ \entries ->
      let rows = dictionaryEntriesParentFirst (mkData entries)
          ids = [eid | (eid, _, _, _) <- rows]
          precedes parent child = case (elemIndex parent ids, elemIndex child ids) of
            (Just pIx, Just cIx) -> pIx < cIx
            _ -> False
       in all
            (\(eid, _, _, mparent) -> maybe True (`precedes` eid) mparent)
            rows

  prop "dictionaryEntriesParentFirst preserves each entry's id, role and parent" $
    forAll genDictionaryTree $ \entries ->
      let rows = dictionaryEntriesParentFirst (mkData entries)
          fromRows = Set.fromList [(eid, role, parent) | (eid, _, role, parent) <- rows]
          fromEntries = Set.fromList [(e.entryId, e.role, e.parentId) | e <- entries]
       in fromRows == fromEntries

  prop "dictionaryItemIds are exactly the item ids" $
    forAll genDictionaryTree $ \entries ->
      dictionaryItemIds (mkData entries)
        == Set.fromList [e.entryId | e <- entries, e.role == ItemRole]

  prop "dictionaryItems ids equal the assignable ids" $
    forAll genDictionaryTree $ \entries ->
      let d = mkData entries
       in Set.fromList (map fst (dictionaryItems d)) == dictionaryItemIds d
