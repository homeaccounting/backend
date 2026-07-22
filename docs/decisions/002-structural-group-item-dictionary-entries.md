# 002 - Structural group/item dictionary entries

## Status
Accepted

## Context
The dictionary-tree work (tracker#42) made income/expense a nested tree with a
per-kind `groupsAssignable :: DictionaryKind -> Bool` and a depth limit of 4,
where "is this a group?" was **emergent** — decided by whether a node currently
has children. Re-validating the feature against common accounting practice and
the well-known packages surfaced two problems:

1. **The emergent model creates a transition hazard.** If groups are
   non-assignable, adding the first child to a postable category (e.g. "Food")
   silently turns it into a non-assignable group, orphaning every transaction
   already posted to it against the new invariant. Any per-kind flip to
   non-assignable groups would have had to be sequenced behind a rule for this
   case (and behind rollup reporting, so a non-postable group is not a dead
   node) — a lot of machinery to make an emergent model safe.

2. **The design exceeds what the domain and the well-known software do.**
   Standard practice — QuickBooks, Xero, GnuCash, and YNAB/Mint/Monarch on the
   consumer side — is: transactions post to **leaves**, parents are **pure
   containers** (rollup totals), groups are **created explicitly** rather than
   converted from a leaf, and the consumer apps cap the hierarchy at **2 levels**
   (group → category). Four-level arbitrary nesting with per-kind assignable
   groups is enterprise chart-of-accounts territory a home app does not need.

## Decision
Model group and item **structurally**, and simplify the tree to two levels.

1. **A `DictionaryEntry` is created as either a group or an item.** A **group**
   is a pure container and is **never** assignable; an **item** is a leaf and is
   **always** assignable. The role is declared at creation and is **immutable** —
   there is no group↔item conversion. This eliminates the transition hazard at
   the root: assignability is a stored fact of the node, never emergent from
   whether it has children, so no node ever silently changes assignability.

2. **Assignability is universal and structural.** `entryAssignable` becomes "is
   this an item?", with no `DictionaryKind` parameter. **`groupsAssignable ::
   DictionaryKind -> Bool` is deleted**, along with the per-dictionary
   `groupsAssignable` field on the DTO. All groups, across all kinds, are
   non-assignable containers.

3. **Model the tree with a recursive ADT.**

   ```haskell
   data DictionaryNode
     = GroupNode DictionaryEntryId EntryName [DictionaryNode]  -- container, never assignable
     | ItemNode  DictionaryEntryId EntryName                    -- leaf, always assignable
   ```

   This is the **materialized** representation that command-handler validation
   and the DTO speak; an item cannot carry children by construction. **Persistence
   stays flat**: each stored entry carries its `role` and `parentId`, and the
   tree is derived, not stored. Events remain granular deltas and `Move` stays a
   `parentId` swap. (Events and the flat relational read-model row force a flat
   representation to exist regardless, so a canonical tree would be a *second*
   representation, not the only one — see the tracker#42 spec for that analysis.)

4. **Depth 2, enforced by validation.** `maxDictionaryDepth = 2`: a group may
   contain only items; items live at root or inside a group; groups live at root.
   Extending to 3 later is relaxing one rule (let a group hold sub-groups) plus
   bumping the constant — no reshape.

5. **Items may live at the root.** Root holds a mix of groups and top-level
   items, matching Mint/Monarch and leaving today's flat income/expense defaults
   as root-level items with no restructuring.

6. **Rollup reporting stays a separate, future concern.** Groups are
   non-assignable containers now; a later change can compute a group total as the
   sum of its descendant postings (with the single-count invariant: a transaction
   is counted once, and a parent total is Σ descendants only). That work is not a
   prerequisite for the structural model, which makes groups non-assignable safely
   and immediately.

## Consequences
- The transition hazard is **eliminated structurally** — an immutable role means
  no node ever changes assignability.
- The design matches the well-known accounting software: post-to-leaf, explicit
  pure-container groups, 2-level hierarchy.
- `groupsAssignable` and the DTO's per-dictionary `groupsAssignable` field are
  **removed**; `entryAssignable` simplifies to a constructor check.
- Contacts (#41) fit natively: folders are groups, people are items.
- Flat storage is retained, so add/move/remove/rename stay trivial; the recursive
  `DictionaryNode` ADT is derived for validation and the DTO.
- **Empty groups are representable**, so the DTO must carry each node's role
  explicitly — the client cannot infer "group" from "has children".
- New validation: adding under a parent requires that parent to **be a group**
  (`ParentNotAGroup`); item-under-item is impossible; group-under-group is
  rejected while depth is 2.
- Rollup reporting is deferred; when added, a group total becomes Σ descendants
  with the single-count invariant.
