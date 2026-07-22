{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.ConfigurationDictionaryTreeSpec
-- Description : Pure tests for the server-materialised dictionary tree DTO.
--
-- The read model already holds the materialised tree ('DictionaryData' wraps
-- roots-first 'DictionaryNode's), so 'buildDictionaryResponse' is a thin
-- 'DictionaryNode' -> 'DictionaryResponse' mapping. These tests assert that
-- mapping — node role (@type@ = "group" / "item"), nested children, and empty
-- groups — against directly-constructed trees. Orphan/adjacency dropping now
-- happens upstream in the materialiser and is covered by
-- 'Domain.Configuration.DictionaryTreePropertySpec'.
module Web.API.ConfigurationDictionaryTreeSpec (spec) where

import Application.ReadModels.Configuration (DictionaryData (..))
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Configuration.Dictionary (DictionaryNode (..), EntryRole (..))
import Domain.Core.Types
  ( DictionaryEntryId,
    unsafeDictionaryEntryId,
    unsafeEntryName,
  )
import RIO
import Test.Hspec
import Web.API.ConfigurationAPI
  ( DictionaryEntryNode (..),
    DictionaryResponse (..),
    buildDictionaryResponse,
  )

foodId :: DictionaryEntryId
foodId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0)

diningId :: DictionaryEntryId
diningId = unsafeDictionaryEntryId (UUID.fromWords 2 0 0 0)

groceriesId :: DictionaryEntryId
groceriesId = unsafeDictionaryEntryId (UUID.fromWords 3 0 0 0)

foodUuid :: UUID
foodUuid = UUID.fromWords 1 0 0 0

diningUuid :: UUID
diningUuid = UUID.fromWords 2 0 0 0

groceriesUuid :: UUID
groceriesUuid = UUID.fromWords 3 0 0 0

shoppingId :: DictionaryEntryId
shoppingId = unsafeDictionaryEntryId (UUID.fromWords 4 0 0 0)

shoppingUuid :: UUID
shoppingUuid = UUID.fromWords 4 0 0 0

emptyGroupId :: DictionaryEntryId
emptyGroupId = unsafeDictionaryEntryId (UUID.fromWords 6 0 0 0)

emptyGroupUuid :: UUID
emptyGroupUuid = UUID.fromWords 6 0 0 0

-- | Food (root group) with two item children, Dining and Groceries.
sampleDict :: DictionaryData
sampleDict =
  DictionaryData
    [ GroupNode
        foodId
        (unsafeEntryName "Food")
        [ ItemNode diningId (unsafeEntryName "Dining"),
          ItemNode groceriesId (unsafeEntryName "Groceries")
        ]
    ]

spec :: Spec
spec = describe "buildDictionaryResponse" $ do
  it "materialises a single root group with its two item children" $ do
    let response = buildDictionaryResponse sampleDict
    map (.id) response.roots `shouldBe` [foodUuid]
    case response.roots of
      [food] -> do
        food.name `shouldBe` "Food"
        food.type_ `shouldBe` GroupRole
        map (.id) food.children `shouldMatchList` [diningUuid, groceriesUuid]
        map (.name) food.children `shouldMatchList` ["Dining", "Groceries"]
        map (.type_) food.children `shouldBe` [ItemRole, ItemRole]
        concatMap (.children) food.children `shouldBe` []
      other -> expectationFailure ("expected exactly one root, got " <> show (length other))

  it "materialises an empty group as a group node with no children" $ do
    let dictWithEmptyGroup =
          DictionaryData [GroupNode emptyGroupId (unsafeEntryName "Empty") []]
        response = buildDictionaryResponse dictWithEmptyGroup
    case response.roots of
      [grp] -> do
        grp.id `shouldBe` emptyGroupUuid
        grp.type_ `shouldBe` GroupRole
        grp.children `shouldBe` []
      other -> expectationFailure ("expected exactly one root, got " <> show (length other))

  it "materialises sibling groups each with their own item children independently" $ do
    let siblingGroups =
          DictionaryData
            [ GroupNode foodId (unsafeEntryName "Food") [ItemNode diningId (unsafeEntryName "Dining")],
              GroupNode shoppingId (unsafeEntryName "Shopping") [ItemNode groceriesId (unsafeEntryName "Groceries")]
            ]
        response = buildDictionaryResponse siblingGroups
    case response.roots of
      [food, shopping] -> do
        food.id `shouldBe` foodUuid
        food.type_ `shouldBe` GroupRole
        map (.id) food.children `shouldBe` [diningUuid]
        shopping.id `shouldBe` shoppingUuid
        shopping.type_ `shouldBe` GroupRole
        map (.id) shopping.children `shouldBe` [groceriesUuid]
      other -> expectationFailure ("expected two sibling groups, got " <> show (length other))
