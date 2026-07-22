{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | The dictionary domain model in one home: the closed set of dictionaries
-- ('DictionaryKind'), the flat entry list ('DictionaryEntry' with its immutable
-- 'EntryRole' — 'GroupRole' containers vs. 'ItemRole' leaves, ADR 002), the
-- 'Dictionary' collection, the derived typed tree ('DictionaryNode', built by
-- 'buildDictionaryTree'), and group-qualified name-paths ('ItemPath',
-- 'itemPaths', 'groupItemFallbacks'). The flat list is the source of truth
-- (events + read-model rows are flat); an 'ItemNode' cannot carry children by
-- construction. Shared identifier/name primitives ('DictionaryEntryId',
-- 'EntryName') live in "Domain.Core.Types".
--
-- Note the 'DictionaryKind' constructors 'IncomeKind' and 'ExpenseKind' share
-- names with 'Domain.Core.Types.TransactionKind'. The few call sites that need
-- both sum types disambiguate with a qualified import of this module instead of
-- forcing a rename.
module Domain.Configuration.Dictionary
  ( -- * Kinds
    DictionaryKind (..),
    dictionaryKindSlug,
    parseDictionaryKind,

    -- * Entries
    EntryRole (..),
    entryAssignable,
    DictionaryEntry (..),
    Dictionary (..),

    -- * Materialised tree
    DictionaryNode (..),
    ItemPath,
    buildDictionaryTree,
    itemPaths,
    groupItemFallbacks,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Domain.Core.Types
  ( DictionaryEntryId,
    EntryName,
    unEntryName,
  )
import RIO
import RIO.Char (isUpper, toLower)
import RIO.List (find)
import qualified RIO.Map as Map
import qualified RIO.Text as T

-- | The closed, code-defined set of dictionaries. There is no user-created
-- dictionary, so this is a sum type rather than a free-text id.
data DictionaryKind
  = IncomeKind
  | ExpenseKind
  | LabelKind
  | ContactKind
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- | Wire/persistence slug, DERIVED from the constructor: drop the "Kind"
-- suffix and lowercase, inserting '-' before each interior capital.
-- IncomeKind -> "income", ExpenseKind -> "expense", LabelKind -> "label",
-- ContactKind -> "contact". Single source of truth; adding a kind cannot drift
-- its slug. (No multi-word kinds exist yet, so kebab-casing is a no-op today,
-- but the helper handles them for future kinds.)
dictionaryKindSlug :: DictionaryKind -> Text
dictionaryKindSlug kind = kebab (stripKindSuffix (T.pack (show kind)))
  where
    stripKindSuffix s = fromMaybe s (T.stripSuffix "Kind" s)
    kebab t = case T.uncons t of
      Nothing -> t
      Just (c, cs) -> T.cons (toLower c) (T.concatMap kebabChar cs)
    kebabChar x
      | isUpper x = T.pack ['-', toLower x]
      | otherwise = T.singleton x

-- | Parse a slug back to its kind. Total over the closed set; 'Nothing' for
-- an unknown slug (surfaces as a 404 at the API boundary).
parseDictionaryKind :: Text -> Maybe DictionaryKind
parseDictionaryKind t =
  find (\k -> dictionaryKindSlug k == t) [minBound .. maxBound]

instance ToJSON DictionaryKind where
  toJSON = toJSON . dictionaryKindSlug

instance FromJSON DictionaryKind where
  parseJSON = withText "DictionaryKind" $ \t ->
    maybe (fail ("unknown DictionaryKind: " <> show t)) pure (parseDictionaryKind t)

-- | Whether a dictionary entry is a pure container ('GroupRole', never
-- assignable) or a leaf ('ItemRole', always assignable). Declared at creation
-- and immutable — there is no group<->item conversion (ADR 002).
data EntryRole = GroupRole | ItemRole
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- Wire form is the lowercased role name: "group" / "item".
instance ToJSON EntryRole where
  toJSON GroupRole = "group"
  toJSON ItemRole = "item"

instance FromJSON EntryRole where
  parseJSON = withText "EntryRole" $ \case
    "group" -> pure GroupRole
    "item" -> pure ItemRole
    other -> fail ("unknown EntryRole: " <> show other)

-- | Whether an entry may be attached to a transaction. Structural and uniform
-- across all kinds: items are always assignable, groups never (ADR 002).
entryAssignable :: DictionaryEntry -> Bool
entryAssignable entry = entry.role == ItemRole

-- | A single dictionary entry / tree node. @parentId = Nothing@ is a root node;
-- otherwise it names the containing group (adjacency list). The 'role' is an
-- immutable, stored fact: a 'GroupRole' is a pure container (never assignable),
-- an 'ItemRole' is a leaf (always assignable) — group-ness is structural, not
-- emergent (ADR 002).
data DictionaryEntry = DictionaryEntry
  { entryId :: DictionaryEntryId,
    name :: EntryName,
    role :: EntryRole,
    parentId :: Maybe DictionaryEntryId
  }
  deriving (Show, Eq, Generic)

instance ToJSON DictionaryEntry

instance FromJSON DictionaryEntry

-- | A collection of entries.
data Dictionary = Dictionary
  { entries :: [DictionaryEntry]
  }
  deriving (Show, Eq, Generic)

instance ToJSON Dictionary

instance FromJSON Dictionary

-- | A node in the materialised tree. Groups hold children; items are leaves.
data DictionaryNode
  = GroupNode DictionaryEntryId EntryName [DictionaryNode]
  | ItemNode DictionaryEntryId EntryName
  deriving (Show, Eq, Generic)

-- | Build the roots-first tree from a flat entry list. Entries whose parent id
-- does not resolve to an existing group are dropped (orphans/cycles), matching
-- the previous materialiser's behaviour. An 'ItemRole' is always a leaf even if some
-- entry erroneously points at it (that child is dropped).
buildDictionaryTree :: [DictionaryEntry] -> [DictionaryNode]
buildDictionaryTree entries = buildLevel Nothing
  where
    childrenByParent :: Map (Maybe DictionaryEntryId) [DictionaryEntry]
    childrenByParent =
      Map.fromListWith (flip (<>)) [(e.parentId, [e]) | e <- entries]

    buildLevel :: Maybe DictionaryEntryId -> [DictionaryNode]
    buildLevel parent =
      [ toNode e
      | e <- Map.findWithDefault [] parent childrenByParent
      ]

    toNode :: DictionaryEntry -> DictionaryNode
    toNode e = case e.role of
      ItemRole -> ItemNode e.entryId e.name
      GroupRole -> GroupNode e.entryId e.name (buildLevel (Just e.entryId))

-- | A group-qualified item name-path, e.g. @"Food / Groceries"@; a root-level
-- item is just its own name.
type ItemPath = Text

-- | Separator between ancestor names in an 'ItemPath' — the single source of
-- the path format.
pathSeparator :: Text
pathSeparator = " / "

-- | Join an ancestor-name chain (root first) into an 'ItemPath'.
joinPath :: [EntryName] -> ItemPath
joinPath = T.intercalate pathSeparator . map unEntryName

-- | Every leaf item paired with its group-qualified 'ItemPath' (pre-order DFS).
-- Gives a category picker or the LLM prompt the group context while the id
-- still points at the assignable leaf.
itemPaths :: [DictionaryNode] -> [(DictionaryEntryId, ItemPath)]
itemPaths = go []
  where
    go prefix = concatMap (node prefix)
    node prefix (ItemNode eid nm) = [(eid, joinPath (prefix <> [nm]))]
    node prefix (GroupNode _ gnm kids) = go (prefix <> [gnm]) kids

-- | For each group (at any level), its first descendant item paired with the
-- group's 'ItemPath'. Lets a category that names a group resolve to that
-- group's first assignable item rather than a global default. Groups with no
-- items are omitted.
groupItemFallbacks :: [DictionaryNode] -> [(DictionaryEntryId, ItemPath)]
groupItemFallbacks = go []
  where
    go prefix = concatMap (node prefix)
    node _ (ItemNode _ _) = []
    node prefix (GroupNode _ gnm kids) =
      let path = prefix <> [gnm]
          here = case firstItemId kids of
            (iid : _) -> [(iid, joinPath path)]
            [] -> []
       in here <> go path kids
    firstItemId = concatMap leafIds
    leafIds (ItemNode iid _) = [iid]
    leafIds (GroupNode _ _ kids) = concatMap leafIds kids
