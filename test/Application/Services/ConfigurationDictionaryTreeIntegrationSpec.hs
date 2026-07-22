{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.ConfigurationDictionaryTreeIntegrationSpec
-- Description : End-to-end integration tests for the nested dictionary tree
--
-- These tests drive the real 'ConfigurationService' commands through the event
-- store and the persistent (SQL-backed) read model — not the pure in-memory
-- projection — then materialise the nested-tree DTO from the read-model data
-- exactly as the HTTP layer does. They cover the full add → add-child → move
-- lifecycle and the parent-must-be-a-group guard at the service boundary.
module Application.Services.ConfigurationDictionaryTreeIntegrationSpec (spec) where

import Application.ReadModels.Configuration
  ( ConfigurationData (..),
    DictionaryData,
    getConfiguration,
  )
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    moveDictionaryEntry,
  )
import qualified Data.Map.Strict as Map
import Domain.Configuration.Dictionary (DictionaryKind (..), EntryRole (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( DictionaryEntryId,
    UserId,
    unsafeEntryName,
  )
import Infrastructure.App (AppEnv (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.Fixtures (seedDefaultAndRegister)
import Testkit.InMemoryEventStore (createTestAppEnv, runDbIn)
import Web.API.ConfigurationAPI
  ( DictionaryEntryNode (..),
    DictionaryResponse (..),
    buildDictionaryResponse,
  )

spec :: Spec
spec =
  describe "Dictionary tree (event store + read model)" $ do
    it "nests entries into a tree after add and move" $ do
      env <- createTestAppEnv
      (userId, _foodId, _diningId, _groceriesId) <-
        buildMovedTree env "dicttree-nest@test.com"

      -- Read back through the persistent read model and materialise the DTO
      -- tree exactly as the HTTP layer does.
      dictData <- loadLabelDictionary env userId
      let response = buildDictionaryResponse dictData

      -- After the move the tree is a single group Food holding both items.
      case responseRoots response of
        [foodNode] -> do
          nodeName foodNode `shouldBe` "Food"
          nodeType foodNode `shouldBe` GroupRole
          -- Position order: Dining was added before Groceries, so it sorts first
          -- (a moved entry keeps its insertion position).
          map nodeName (nodeChildren foodNode) `shouldBe` ["Dining", "Groceries"]
          map nodeType (nodeChildren foodNode) `shouldBe` [ItemRole, ItemRole]
          concatMap nodeChildren (nodeChildren foodNode) `shouldBe` []
        other ->
          expectationFailure
            $ "Expected exactly one root (Food), got: "
            <> show (map nodeName other)

    it "rejects moving a group under an item" $ do
      env <- createTestAppEnv
      (userId, foodId, diningId, _groceriesId) <-
        buildMovedTree env "dicttree-cycle@test.com"

      -- Dining is an item (a leaf), so it can never hold children; moving the
      -- Food group under it must be rejected as "not a group".
      result <- runRIO env $ moveDictionaryEntry userId LabelKind foodId (Just diningId)
      case result of
        Left (ConfigurationError msg) ->
          msg `shouldSatisfy` T.isInfixOf "not a group"
        other ->
          expectationFailure
            $ "Expected a parent-not-a-group ConfigurationError, got: "
            <> show other

    it "returns siblings in insertion order, not alphabetical" $ do
      env <- createTestAppEnv
      userId <- seedDefaultAndRegister env "dicttree-order@test.com"
      -- Add root entries in a deliberately non-alphabetical order.
      _ <- addItem env userId "Zebra" Nothing
      _ <- addItem env userId "Apple" Nothing
      _ <- addGroup env userId "Middle" Nothing
      _ <- addItem env userId "Mango" Nothing

      dictData <- loadLabelDictionary env userId
      let response = buildDictionaryResponse dictData

      -- Canonical order is the persisted insertion order (position), so the
      -- roots come back as inserted — not sorted A–Z. Presentation re-sorts
      -- (alphabetical, most-used) are the client's concern.
      map nodeName (responseRoots response) `shouldBe` ["Zebra", "Apple", "Middle", "Mango"]

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

-- | Seed + register a fresh user, then build the tree Food(group) holding the
-- item Dining, add a root item Groceries, and move Groceries under Food.
-- Returns the user and the three entry ids. Everything goes through the real
-- service commands and lands in the event store / read model.
buildMovedTree ::
  AppEnv ->
  Text ->
  IO (UserId, DictionaryEntryId, DictionaryEntryId, DictionaryEntryId)
buildMovedTree env email = do
  userId <- seedDefaultAndRegister env email
  -- Labels start out empty (unlike the seeded income/expense category
  -- dictionaries), so the Food/Groceries/Dining names never collide with a
  -- pre-existing sibling.
  foodId <- addGroup env userId "Food" Nothing
  diningId <- addItem env userId "Dining" (Just foodId)
  groceriesId <- addItem env userId "Groceries" Nothing
  moveResult <- runRIO env $ moveDictionaryEntry userId LabelKind groceriesId (Just foodId)
  case moveResult of
    Left err -> fail $ "moveDictionaryEntry (Groceries under Food) failed: " <> show err
    Right () -> pure ()
  pure (userId, foodId, diningId, groceriesId)

-- | Add a Label group entry, failing the test if the service rejects it.
addGroup :: AppEnv -> UserId -> Text -> Maybe DictionaryEntryId -> IO DictionaryEntryId
addGroup = addEntryWithRole GroupRole

-- | Add a Label item entry, failing the test if the service rejects it.
addItem :: AppEnv -> UserId -> Text -> Maybe DictionaryEntryId -> IO DictionaryEntryId
addItem = addEntryWithRole ItemRole

addEntryWithRole :: EntryRole -> AppEnv -> UserId -> Text -> Maybe DictionaryEntryId -> IO DictionaryEntryId
addEntryWithRole role env userId name parentId = do
  result <- runRIO env $ addDictionaryEntry userId LabelKind (unsafeEntryName name) role parentId
  case result of
    Left err -> fail $ "addDictionaryEntry (" <> T.unpack name <> ") failed: " <> show err
    Right entryId -> pure entryId

-- | Load the user's Label dictionary from the persistent read model.
loadLabelDictionary :: AppEnv -> UserId -> IO DictionaryData
loadLabelDictionary env userId = do
  mUser <- runDbIn env (getUser userId)
  userData <- maybe (fail "loadLabelDictionary: user not found") pure mUser
  mConfig <- runDbIn env (getConfiguration userData.configurationId)
  config <- maybe (fail "loadLabelDictionary: configuration not found") pure mConfig
  case Map.lookup LabelKind config.dictionaries of
    Nothing -> fail "loadLabelDictionary: label dictionary missing"
    Just dict -> pure dict

-- | Field accessors via pattern match (project-wide 'NoFieldSelectors' disables
-- generated selectors, and dot-access on shared field names is brittle).
responseRoots :: DictionaryResponse -> [DictionaryEntryNode]
responseRoots (DictionaryResponse {roots = r}) = r

nodeName :: DictionaryEntryNode -> Text
nodeName (DictionaryEntryNode {name = n}) = n

nodeType :: DictionaryEntryNode -> EntryRole
nodeType (DictionaryEntryNode {type_ = t}) = t

nodeChildren :: DictionaryEntryNode -> [DictionaryEntryNode]
nodeChildren (DictionaryEntryNode {children = c}) = c
