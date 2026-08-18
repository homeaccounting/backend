{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.ConfigurationTreePropertySpec
-- Description : Property tests for dictionary-tree invariants
--
-- Proves the structural invariants of the Configuration dictionary tree over
-- randomly generated depth-2 trees (ADR 002):
--
--   * Moving an entry onto itself or one of its descendants is always rejected
--     (a self-move trips the cycle guard; a descendant is always an item, so it
--     trips the parent-must-be-a-group guard first).
--   * No accepted Add or Move ever produces a tree whose deepest node exceeds
--     'maxDictionaryDepth' (= 2).
--   * No accepted Add or Move ever produces a tree whose an entry's parent is an
--     item — parents are always groups.
module Domain.Configuration.ConfigurationTreePropertySpec (spec) where

import Domain.Configuration
import Domain.Configuration.Dictionary (DictionaryEntry (..), EntryRole (..))
import qualified Domain.Configuration.Dictionary as DictKind
import Domain.Configuration.Events (ConfigurationCreated (..))
import Domain.Core.Types
import Domain.Localization.Language (Language (..))
import Eventium (latestProjection)
import RIO
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators (genDictionaryEntryId, genDictionaryTree, genEntryName)

spec :: Spec
spec = describe "Configuration dictionary tree invariants" $ do
  it "rejects moving an entry onto itself or one of its descendants"
    $ property prop_cycleRejected
  it "never accepts an Add/Move that pushes any node beyond the depth limit"
    $ property prop_depthBounded
  it "never accepts an Add/Move that parents an entry under an item"
    $ property prop_parentsAreGroups

-- | The dictionary kind exercised by these properties. Any kind behaves
-- identically for the tree guards; a concrete one is fixed for determinism.
treeKind :: DictKind.DictionaryKind
treeKind = DictKind.ExpenseKind

-- | Rebuild the event stream that materialises a generated tree. Entries are
-- emitted parent-before-child by 'genDictionaryTree', so replaying the adds in
-- order reconstructs the tree faithfully. Each add carries the entry's role.
buildEvents :: [DictionaryEntry] -> [ConfigurationEvent]
buildEvents entries =
  ConfigurationCreatedConfigurationEvent
    ConfigurationCreated
      { baseCurrency = UAH,
        defaultCurrency = UAH,
        language = En,
        country = Nothing,
        createdBy = System
      }
    : map added entries
  where
    added e =
      DictionaryEntryAddedConfigurationEvent
        DictionaryEntryAdded
          { dictionaryKind = treeKind,
            entryId = e.entryId,
            name = e.name,
            role = e.role,
            parentId = e.parentId
          }

buildConfig :: [DictionaryEntry] -> Configuration
buildConfig = latestProjection configurationProjection . buildEvents

-- | For any generated tree, moving a node under itself or any of its
-- descendants is rejected. At depth 2 the specific guard that fires depends on
-- roles (self-move of a group -> cycle; anything else -> parent-not-a-group or
-- cycle), so the invariant is simply that the command is rejected.
prop_cycleRejected :: Property
prop_cycleRejected =
  forAll genDictionaryTree $ \entries ->
    let config = buildConfig entries
     in forAll (elements entries) $ \entry ->
          forAll (elements (entry.entryId : descendantsOf entry.entryId entries)) $ \target ->
            let command =
                  MoveDictionaryEntryConfigurationCommand
                    MoveDictionaryEntry
                      { dictionaryKind = treeKind,
                        entryId = entry.entryId,
                        newParentId = Just target
                      }
                result = handleConfigurationCommand config command
             in counterexample ("expected rejection, got " <> show result)
                  $ isLeft result

-- | Any accepted Add or Move leaves every node within 'maxDictionaryDepth';
-- rejected commands establish nothing and pass vacuously.
prop_depthBounded :: Property
prop_depthBounded =
  forAll genDictionaryTree $ \entries ->
    let config = buildConfig entries
     in forAllBlind (genTreeCommand entries) $ \command ->
          case handleConfigurationCommand config command of
            Left _ -> property True
            Right events ->
              let config' = latestProjection configurationProjection (buildEvents entries <> events)
                  es' = entriesOf treeKind config'
                  maxDepth = foldr (max . (\e -> depthOf e.entryId es')) 1 es'
               in counterexample ("resulting max depth = " <> show maxDepth)
                    $ maxDepth
                    <= maxDictionaryDepth

-- | Any accepted Add or Move leaves every parented entry sitting under a group;
-- rejected commands establish nothing and pass vacuously.
prop_parentsAreGroups :: Property
prop_parentsAreGroups =
  forAll genDictionaryTree $ \entries ->
    let config = buildConfig entries
     in forAllBlind (genTreeCommand entries) $ \command ->
          case handleConfigurationCommand config command of
            Left _ -> property True
            Right events ->
              let config' = latestProjection configurationProjection (buildEvents entries <> events)
                  es' = entriesOf treeKind config'
                  parentIsGroup e = case e.parentId of
                    Nothing -> True
                    Just p -> isGroupEntry p es'
               in counterexample "an entry is parented under an item"
                    $ all parentIsGroup es'

-- | Generate a random Add or Move command against an existing tree. Adds pick a
-- random role and parent; moves pick an existing entry and a random parent, so
-- both accepted and rejected paths are covered.
genTreeCommand :: [DictionaryEntry] -> Gen ConfigurationCommand
genTreeCommand entries = oneof [genAdd, genMove]
  where
    ids = map (.entryId) entries
    genParent = frequency [(1, pure Nothing), (3, Just <$> elements ids)]
    genRole = elements [GroupRole, ItemRole]
    genAdd = do
      eid <- genDictionaryEntryId
      nm <- genEntryName
      entryRole <- genRole
      parent <- genParent
      pure
        $ AddDictionaryEntryConfigurationCommand
          AddDictionaryEntry
            { dictionaryKind = treeKind,
              entryId = eid,
              name = nm,
              role = entryRole,
              parentId = parent
            }
    genMove = do
      eid <- elements ids
      parent <- genParent
      pure
        $ MoveDictionaryEntryConfigurationCommand
          MoveDictionaryEntry
            { dictionaryKind = treeKind,
              entryId = eid,
              newParentId = parent
            }
