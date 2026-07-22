{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.DictionaryPropertySpec
-- Description : Properties for the dictionary domain model — the 'DictionaryKind'
--               slug codec, the structural 'entryAssignable' predicate, the
--               flat-to-tree materialiser, and group-qualified name-paths
--               (ADR 002). One spec per the single 'Domain.Configuration.Dictionary' module.
module Domain.Configuration.DictionaryPropertySpec (spec) where

import qualified Data.UUID as UUID
import Domain.Configuration.Dictionary
  ( DictionaryEntry (..),
    DictionaryKind,
    DictionaryNode (..),
    EntryRole (..),
    buildDictionaryTree,
    dictionaryKindSlug,
    entryAssignable,
    groupItemFallbacks,
    itemPaths,
    parseDictionaryKind,
  )
import Domain.Core.Types
  ( DictionaryEntryId,
    unsafeDictionaryEntryId,
    unsafeEntryName,
  )
import RIO
import qualified RIO.List as L
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (elements, forAll)
import Testkit.Generators (genDictionaryTree)

-- | The id carried by a materialised node, regardless of its role.
nodeId :: DictionaryNode -> DictionaryEntryId
nodeId (GroupNode eid _ _) = eid
nodeId (ItemNode eid _) = eid

-- | Every node in the forest, flattened depth-first.
flatten :: [DictionaryNode] -> [DictionaryNode]
flatten = concatMap go
  where
    go n@(ItemNode _ _) = [n]
    go n@(GroupNode _ _ kids) = n : flatten kids

-- | An 'ItemNode' can carry no children by construction — this holds for every
-- node reachable in the forest.
noItemChildren :: DictionaryNode -> Bool
noItemChildren (ItemNode _ _) = True
noItemChildren (GroupNode _ _ kids) = all noItemChildren kids

-- | Build two entries differing only by role, sharing a fresh id/name.
itemEntry :: DictionaryEntry
itemEntry =
  DictionaryEntry
    (unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0))
    (unsafeEntryName "leaf")
    ItemRole
    Nothing

groupEntry :: DictionaryEntry
groupEntry =
  DictionaryEntry
    (unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0))
    (unsafeEntryName "container")
    GroupRole
    Nothing

spec :: Spec
spec = do
  describe "DictionaryKind slug codec"
    $
    -- The wire/persistence slug must round-trip through the parser for every
    -- kind, so serialising and re-reading a kind is lossless.
    prop "parseDictionaryKind . dictionaryKindSlug is the identity"
    $ forAll (elements [minBound .. maxBound])
    $ \(k :: DictionaryKind) ->
      parseDictionaryKind (dictionaryKindSlug k) == Just k

  describe "entryAssignable" $ do
    it "an item is assignable"
      $ entryAssignable itemEntry
      `shouldBe` True

    it "a group is never assignable"
      $ entryAssignable groupEntry
      `shouldBe` False

  describe "buildDictionaryTree" $ do
    prop "an ItemNode never has children"
      $ forAll genDictionaryTree
      $ \es ->
        all noItemChildren (buildDictionaryTree es)

    prop "roots are exactly the entries with no parent"
      $ forAll genDictionaryTree
      $ \es ->
        L.sort (map nodeId (buildDictionaryTree es))
          == L.sort [e.entryId | e <- es, isNothing e.parentId]

    prop "every group's children are exactly the entries whose parent is that group"
      $ forAll genDictionaryTree
      $ \es ->
        all (childrenMatchAdjacency es) (flatten (buildDictionaryTree es))

    prop "an entry becomes a GroupNode iff its role is Group"
      $ forAll genDictionaryTree
      $ \es ->
        all (roleMatchesNode es) (flatten (buildDictionaryTree es))

    it "drops an entry whose parent id resolves to no existing entry" $ do
      let foodId = unsafeDictionaryEntryId (UUID.fromWords 10 0 0 0)
          missingId = unsafeDictionaryEntryId (UUID.fromWords 99 0 0 0)
          orphanId = unsafeDictionaryEntryId (UUID.fromWords 11 0 0 0)
          entries =
            [ DictionaryEntry foodId (unsafeEntryName "Food") GroupRole Nothing,
              DictionaryEntry orphanId (unsafeEntryName "Orphan") ItemRole (Just missingId)
            ]
      map nodeId (flatten (buildDictionaryTree entries)) `shouldBe` [foodId]

    it "drops a child pointing at an item parent (items are always leaves)" $ do
      let itemId = unsafeDictionaryEntryId (UUID.fromWords 20 0 0 0)
          childId = unsafeDictionaryEntryId (UUID.fromWords 21 0 0 0)
          entries =
            [ DictionaryEntry itemId (unsafeEntryName "Leaf") ItemRole Nothing,
              DictionaryEntry childId (unsafeEntryName "Child") ItemRole (Just itemId)
            ]
      map nodeId (flatten (buildDictionaryTree entries)) `shouldBe` [itemId]

  describe "itemPaths" $ do
    it "qualifies each item with its ancestor group path" $ do
      let foodId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
          groceriesId = unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0)
          diningId = unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0)
          otherId = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)
          entries =
            [ DictionaryEntry foodId (unsafeEntryName "Food") GroupRole Nothing,
              DictionaryEntry groceriesId (unsafeEntryName "Groceries") ItemRole (Just foodId),
              DictionaryEntry diningId (unsafeEntryName "Dining") ItemRole (Just foodId),
              DictionaryEntry otherId (unsafeEntryName "Other") ItemRole Nothing
            ]
      itemPaths (buildDictionaryTree entries)
        `shouldBe` [ (groceriesId, "Food / Groceries"),
                     (diningId, "Food / Dining"),
                     (otherId, "Other")
                   ]

  describe "groupItemFallbacks" $ do
    it "maps each group to its first descendant item" $ do
      let foodId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)
          groceriesId = unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0)
          diningId = unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0)
          housingId = unsafeDictionaryEntryId (UUID.fromWords 5 0 0 0)
          rentId = unsafeDictionaryEntryId (UUID.fromWords 6 0 0 0)
          otherId = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)
          entries =
            [ DictionaryEntry foodId (unsafeEntryName "Food") GroupRole Nothing,
              DictionaryEntry groceriesId (unsafeEntryName "Groceries") ItemRole (Just foodId),
              DictionaryEntry diningId (unsafeEntryName "Dining") ItemRole (Just foodId),
              DictionaryEntry housingId (unsafeEntryName "Housing") GroupRole Nothing,
              DictionaryEntry rentId (unsafeEntryName "Rent") ItemRole (Just housingId),
              DictionaryEntry otherId (unsafeEntryName "Other") ItemRole Nothing
            ]
      groupItemFallbacks (buildDictionaryTree entries)
        `shouldBe` [(groceriesId, "Food"), (rentId, "Housing")]
  where
    childrenMatchAdjacency _ (ItemNode _ _) = True
    childrenMatchAdjacency es (GroupNode gid _ kids) =
      L.sort (map nodeId kids)
        == L.sort [e.entryId | e <- es, e.parentId == Just gid]

    roleMatchesNode es node =
      case L.find (\e -> e.entryId == nodeId node) es of
        Nothing -> False
        Just e -> case node of
          GroupNode {} -> e.role == GroupRole
          ItemNode {} -> e.role == ItemRole
