# Eventium Telemetry — Event-Persistence Slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a generic, framework-free, structured telemetry sink to eventium-core and implement it for the event-persistence (write) path, plus a generic `EventMetadata.custom` context map — so the app (later specs) can log & meter every persisted event and attribute it to a user.

**Architecture:** One `Telemetry m` sink (`newtype` over `Signal -> m ()`) with a single growing `Signal` sum type; the write path emits through a decorator `telemetryEventStoreWriter` that wraps the versioned `EventStoreWriter`. `EventMetadata` gains a `custom :: Map Text Text` bag with hand-written omit-empty JSON. Silent by default; no new dependencies.

**Tech Stack:** Haskell (GHC 9.10), hpack, cabal, hspec (+ hspec-discover), aeson 2.2, `containers`. All library code lands in the **eventium** repo at `/Users/oleksandrsy/Projects/Self/eventium`.

**Spec:** `docs/specs/2026-08-01-eventium-telemetry-event-persistence-design.md` (in the backend repo).

---

## Cross-repo & environment notes (read first)

- **All Tasks 1–5 edit the eventium repo** at `/Users/oleksandrsy/Projects/Self/eventium`, on a new branch there (e.g. `feat/telemetry-event-persistence`). This plan doc and the spec live in the *backend* repo; they are not committed to eventium.
- Enter eventium's dev shell before building: `cd /Users/oleksandrsy/Projects/Self/eventium && nix develop` (or rely on direnv). Tooling: `just`, `cabal`, `hpack`, `ormolu`, `hlint`.
- Build after editing `package.yaml`: `just build` (runs `hpack` then `cabal build`). New `src/**.hs` modules are auto-discovered by hpack — no manual exposed-modules list.
- Run the core test suite: `cabal test eventium-core:spec` (append `--test-option=--match --test-option="/Pattern/"` to filter). New `tests/**Spec.hs` files matching `module X (spec)` are auto-discovered by hspec-discover.
- Format/lint before each commit: `just format && just lint` (ormolu + hlint; the repo is `-Werror` under the `ci` flag — see `just ci`).
- Commits in eventium are GPG-signed; the signing agent may prompt. If signing fails in an automated shell, hand the commit to the user (they run `! git commit …`).
- **Task 6 edits the backend repo** (the silent seam) and is gated on eventium 0.6.0 being consumable by the backend — see that task.

## File Structure (eventium repo, paths relative to repo root)

- **Create** `eventium-core/src/Eventium/Telemetry.hs` — the sink: `Telemetry`, `Signal`, `ConflictInfo`, `StreamKeyText`, `silentTelemetry`. Imports only `Eventium.Store.Types` (low-level, no cycle).
- **Create** `eventium-core/src/Eventium/Store/Telemetry.hs` — `telemetryEventStoreWriter` write decorator.
- **Modify** `eventium-core/src/Eventium/Store/Types.hs` — add `custom` field + hand-written JSON + `insertCustomMetadata`; fix `emptyMetadata` and `tagEvents` construction sites.
- **Modify** `eventium-core/src/Eventium/Store/Class.hs` — fix the enriching-writer construction site.
- **Modify** `eventium-core/src/Eventium.hs` — re-export the two new modules.
- **Modify** `eventium-core/package.yaml` — bump version to `0.6.0`.
- **Modify** `CHANGELOG.md`, `eventium-sql-common/README.md` — document the change / update the metadata example.
- **Create** `eventium-core/tests/Eventium/Store/MetadataSpec.hs` — `EventMetadata` JSON round-trip + legacy decode (both historical shapes).
- **Create** `eventium-core/tests/Eventium/Store/TelemetrySpec.hs` — write-decorator behaviour (capturing sink + fake writers).

> **Import-cycle rule (locks in a spec constraint):** `Signal` must reference **only** low-level shared types from `Eventium.Store.Types` (and its own newtypes). When later specs add read-model/subscription constructors, define any "name" types in `Eventium.Telemetry` itself — never import a subsystem module into `Eventium.Telemetry`, or the subsystem (which imports `Eventium.Telemetry` to emit) will form a cycle.

---

## Task 1: `EventMetadata.custom` field, JSON, and helper

**Files:**
- Modify: `eventium-core/src/Eventium/Store/Types.hs`
- Modify: `eventium-core/src/Eventium/Store/Class.hs` (one construction site)
- Test: `eventium-core/tests/Eventium/Store/MetadataSpec.hs` (create)

- [ ] **Step 1: Write the failing test**

Create `eventium-core/tests/Eventium/Store/MetadataSpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Eventium.Store.MetadataSpec (spec) where

import Data.Aeson (Value (Null, Object), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Eventium.Store.Types (EventMetadata, emptyMetadata, insertCustomMetadata)
import Test.Hspec

spec :: Spec
spec = describe "EventMetadata JSON" $ do
  it "round-trips a non-empty custom map and includes the key" $ do
    let md = insertCustomMetadata "userId" "u-1" (emptyMetadata "Foo")
    decode (encode md) `shouldBe` Just md
    case decode (encode md) :: Maybe Value of
      Just (Object o) -> KM.member "custom" o `shouldBe` True
      _ -> expectationFailure "expected object"

  it "omits custom when empty" $ do
    case decode (encode (emptyMetadata "Foo")) :: Maybe Value of
      Just (Object o) -> KM.member "custom" o `shouldBe` False
      _ -> expectationFailure "expected object"

  it "omits Nothing Maybe fields (no explicit null)" $ do
    case decode (encode (emptyMetadata "Foo")) :: Maybe Value of
      Just (Object o) -> KM.member "correlationId" o `shouldBe` False
      _ -> expectationFailure "expected object"

  it "decodes a legacy row with explicit nulls and no custom key" $ do
    let legacy = object ["eventType" .= ("Foo" :: String),
                         "correlationId" .= Null, "causationId" .= Null,
                         "createdAt" .= Null]
    (decode (encode legacy) :: Maybe EventMetadata) `shouldBe` Just (emptyMetadata "Foo")

  it "decodes a new row that omits the optional keys to the same value" $ do
    let new = object ["eventType" .= ("Foo" :: String)]
    (decode (encode new) :: Maybe EventMetadata) `shouldBe` Just (emptyMetadata "Foo")
```

- [ ] **Step 2: Run the test — verify it fails to compile**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test eventium-core:spec --test-option=--match --test-option="/EventMetadata JSON/"`
Expected: **compile error** — `insertCustomMetadata` not in scope (and, after adding the field, the positional constructor sites won't typecheck). That is the red state.

- [ ] **Step 3: Add the field, hand-written instances, and helper**

In `eventium-core/src/Eventium/Store/Types.hs`:
1. Ensure the file has `{-# LANGUAGE OverloadedStrings #-}` at the top (add if absent).
2. Add imports: `import qualified Data.Map.Strict as Map` and `import Data.Map.Strict (Map)`, and ensure `Data.Aeson` brings `object, (.=), (.:), (.:?), (.!=), withObject`.
3. Add `custom` to the record and drop the `Generic`-derived JSON:

```haskell
data EventMetadata = EventMetadata
  { eventType :: !EventTypeName,
    correlationId :: !(Maybe UUID),
    causationId :: !(Maybe UUID),
    createdAt :: !(Maybe UTCTime),
    custom :: !(Map Text Text)
  }
  deriving (Show, Eq, Generic)

instance ToJSON EventMetadata where
  toJSON md =
    object $
      ["eventType" .= md.eventType]
        ++ maybe [] (\v -> ["correlationId" .= v]) md.correlationId
        ++ maybe [] (\v -> ["causationId" .= v]) md.causationId
        ++ maybe [] (\v -> ["createdAt" .= v]) md.createdAt
        ++ ([("custom" .= md.custom) | not (Map.null md.custom)])

instance FromJSON EventMetadata where
  parseJSON = withObject "EventMetadata" $ \o ->
    EventMetadata
      <$> o .: "eventType"
      <*> o .:? "correlationId"
      <*> o .:? "causationId"
      <*> o .:? "createdAt"
      <*> o .:? "custom" .!= mempty
```

4. Update `emptyMetadata` and add the helper (place `insertCustomMetadata` right after `emptyMetadata`, and add it to the module export list):

```haskell
emptyMetadata :: Text -> EventMetadata
emptyMetadata et = EventMetadata et Nothing Nothing Nothing mempty

-- | Insert one key/value into an event's 'custom' context map.
-- @insertCustomMetadata "userId" uid@.
insertCustomMetadata :: Text -> Text -> EventMetadata -> EventMetadata
insertCustomMetadata k v md = md {custom = Map.insert k v md.custom}
```

5. Fix the `tagEvents` construction site (same file, ~line 218): append `mempty`:
   `TaggedEvent (EventMetadata (eventTypeNameOf e) Nothing Nothing (Just now) mempty) (codec.encode e)`.
6. Add `insertCustomMetadata` to the module's export list (near `emptyMetadata`). `EventMetadata (..)` already exports the new field.

In `eventium-core/src/Eventium/Store/Class.hs` (~line 202), fix the enriching writer's construction: append `mempty`:
`enricher (EventMetadata (eventTypeNameOf e) Nothing Nothing (Just now) mempty)`.

- [ ] **Step 4: Run the test — verify it passes**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && just build && cabal test eventium-core:spec --test-option=--match --test-option="/EventMetadata JSON/"`
Expected: **PASS** (5 examples). If `just build` reports any *other* positional `EventMetadata` site, fix it the same way (append `mempty`) — the compiler enumerates them all.

- [ ] **Step 5: Format, lint, commit** (in the eventium repo)

```bash
cd /Users/oleksandrsy/Projects/Self/eventium
just format && just lint
git add eventium-core/src/Eventium/Store/Types.hs eventium-core/src/Eventium/Store/Class.hs eventium-core/tests/Eventium/Store/MetadataSpec.hs
git commit -m "feat(store): EventMetadata.custom context map + omit-empty JSON"
```

---

## Task 2: `Eventium.Telemetry` — the sink and signal

**Files:**
- Create: `eventium-core/src/Eventium/Telemetry.hs`
- Test: `eventium-core/tests/Eventium/TelemetrySpec.hs` (create)

- [ ] **Step 1: Write the failing test**

Create `eventium-core/tests/Eventium/TelemetrySpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Eventium.TelemetrySpec (spec) where

import Data.IORef
import Eventium.Store.Types (emptyMetadata)
import Eventium.Telemetry
import Test.Hspec

spec :: Spec
spec = describe "Telemetry" $ do
  it "silentTelemetry emits nothing" $ do
    ref <- newIORef (0 :: Int)
    let t = silentTelemetry :: Telemetry IO
    t.emit (EventsPersisted (StreamKeyText "s") [emptyMetadata "Foo"] [])
    readIORef ref `shouldReturn` 0

  it "a capturing sink records the signal it is given" $ do
    ref <- newIORef []
    let t = Telemetry (\sig -> modifyIORef' ref (sig :)) :: Telemetry IO
    let sig = EventsPersisted (StreamKeyText "s") [emptyMetadata "Foo"] []
    t.emit sig
    readIORef ref `shouldReturn` [sig]
```

- [ ] **Step 2: Run — verify it fails to compile**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test eventium-core:spec --test-option=--match --test-option="/Telemetry/"`
Expected: compile error — `Eventium.Telemetry` module does not exist.

- [ ] **Step 3: Create the module**

Create `eventium-core/src/Eventium/Telemetry.hs`:

```haskell
-- | A generic, framework-free, structured telemetry sink. The host app
-- supplies one interpreter ('Telemetry'); eventium emits typed 'Signal's
-- through it. No logging-framework dependency — a contravariant-style sink over
-- a domain signal type. See the event-persistence design spec.
module Eventium.Telemetry
  ( Telemetry (..),
    Signal (..),
    ConflictInfo (..),
    StreamKeyText (..),
    silentTelemetry,
  )
where

import Data.Text (Text)
import Eventium.Store.Types
  ( EventMetadata,
    EventVersion,
    EventWriteResult,
    ExpectedPosition,
  )

-- | A structured telemetry sink. @emit@ runs in the caller's monad @m@.
-- Interpreters MUST NOT throw: a write-path emit may run inside the write
-- transaction, so a throwing interpreter could roll back a committed write.
newtype Telemetry m = Telemetry {emit :: Signal -> m ()}

-- | A rendered event-stream key (streams may key on any type; the write
-- decorator renders 'UUID' streams to text at the emit site).
newtype StreamKeyText = StreamKeyText Text
  deriving (Show, Eq)

-- | Everything eventium can report, across all subsystems. One growing closed
-- sum type. This slice introduces only the write-path constructors.
data Signal
  = -- | Events durably written on the versioned (aggregate) write path:
    -- stream key, per-event metadata (each carries @eventType@, @correlationId@,
    -- @custom@), and assigned per-stream versions + global positions.
    EventsPersisted !StreamKeyText ![EventMetadata] !EventWriteResult
  | -- | An expected-position (optimistic concurrency) check failed; nothing
    -- was written.
    WriteConflict !StreamKeyText !ConflictInfo
  deriving (Show, Eq)

-- | Optimistic-concurrency conflict detail. @expected@ is the caller's asserted
-- position; @actual@ is the stream's real end version.
data ConflictInfo = ConflictInfo
  { expected :: !(ExpectedPosition EventVersion),
    actual :: !EventVersion
  }
  deriving (Show, Eq)

-- | No-op sink — the default everywhere; guarantees silent, zero-cost behaviour
-- unless the app opts in.
silentTelemetry :: (Applicative m) => Telemetry m
silentTelemetry = Telemetry (const (pure ()))
```

> **Verify exports before building:** confirm `Eventium.Store.Types` exports `EventVersion`, `EventWriteResult`, and `ExpectedPosition` (the `(..)` variants for `ExpectedPosition` are needed by Task 3's test). If any is missing from the export list, add it in a one-line change to `Store.Types` and note it in the commit.

- [ ] **Step 4: Run — verify it passes**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && just build && cabal test eventium-core:spec --test-option=--match --test-option="/Telemetry/"`
Expected: **PASS** (2 examples).

- [ ] **Step 5: Format, lint, commit**

```bash
cd /Users/oleksandrsy/Projects/Self/eventium
just format && just lint
git add eventium-core/src/Eventium/Telemetry.hs eventium-core/tests/Eventium/TelemetrySpec.hs
git commit -m "feat(telemetry): Telemetry sink + Signal type (write-path constructors)"
```

---

## Task 3: `telemetryEventStoreWriter` — the write decorator

**Files:**
- Create: `eventium-core/src/Eventium/Store/Telemetry.hs`
- Test: `eventium-core/tests/Eventium/Store/TelemetrySpec.hs` (create)

- [ ] **Step 1: Write the failing test**

Create `eventium-core/tests/Eventium/Store/TelemetrySpec.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Eventium.Store.TelemetrySpec (spec) where

import Data.IORef
import Data.Text (Text)
import Eventium.Store.Class (EventStoreWriter (..))
import Eventium.Store.Telemetry (telemetryEventStoreWriter)
import Eventium.Store.Types
  ( EventVersion (..),
    ExpectedPosition (..),
    SequenceNumber (..),
    TaggedEvent (..),
    EventWriteError (..),
    emptyMetadata,
  )
import Eventium.Telemetry
import qualified Eventium.UUID as UUID
import Test.Hspec

capturing :: IO (IORef [Signal], Telemetry IO)
capturing = do
  ref <- newIORef []
  pure (ref, Telemetry (\s -> modifyIORef' ref (++ [s])))

ev :: TaggedEvent Text
ev = TaggedEvent (emptyMetadata "Foo") "payload"

key :: UUID.UUID
key = UUID.nil  -- adjust to the module's nil/constructor if named differently

spec :: Spec
spec = describe "telemetryEventStoreWriter" $ do
  it "emits EventsPersisted on a successful write" $ do
    (ref, t) <- capturing
    let wr = [(EventVersion 1, SequenceNumber 10)]
    let inner = EventStoreWriter (\_ _ _ -> pure (Right wr))
    _ <- (telemetryEventStoreWriter t inner).storeEvents key AnyPosition [ev]
    signals <- readIORef ref
    signals `shouldBe` [EventsPersisted (StreamKeyText (UUID.uuidToText key)) [emptyMetadata "Foo"] wr]

  it "emits WriteConflict on an expected-position failure" $ do
    (ref, t) <- capturing
    let inner = EventStoreWriter (\_ _ _ -> pure (Left (EventStreamNotAtExpectedVersion (EventVersion 7))))
    _ <- (telemetryEventStoreWriter t inner).storeEvents key (ExactPosition (EventVersion 3)) [ev]
    signals <- readIORef ref
    signals `shouldBe` [WriteConflict (StreamKeyText (UUID.uuidToText key)) (ConflictInfo (ExactPosition (EventVersion 3)) (EventVersion 7))]

  it "emits nothing for an empty batch (even on a Left)" $ do
    (ref, t) <- capturing
    let inner = EventStoreWriter (\_ _ _ -> pure (Left (EventStreamNotAtExpectedVersion (EventVersion 7))))
    _ <- (telemetryEventStoreWriter t inner).storeEvents key (ExactPosition (EventVersion 3)) ([] :: [TaggedEvent Text])
    readIORef ref `shouldReturn` []

  it "silentTelemetry emits nothing" $ do
    (ref, _) <- capturing
    let wr = [(EventVersion 1, SequenceNumber 10)]
    let inner = EventStoreWriter (\_ _ _ -> pure (Right wr))
    _ <- (telemetryEventStoreWriter silentTelemetry inner).storeEvents key AnyPosition [ev]
    readIORef ref `shouldReturn` []
```

> If `UUID.nil`/`UUID.uuidToText` are named differently in `Eventium.UUID`, adjust — Step 2's compile error will name the missing identifier. Use whatever the module exports (e.g. a `fromWords`/`nil` constructor and a `toText`).

- [ ] **Step 2: Run — verify it fails to compile**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && cabal test eventium-core:spec --test-option=--match --test-option="/telemetryEventStoreWriter/"`
Expected: compile error — `Eventium.Store.Telemetry` does not exist.

- [ ] **Step 3: Create the decorator**

Create `eventium-core/src/Eventium/Store/Telemetry.hs`:

```haskell
-- | Write-path telemetry: a decorator that emits a 'Signal' on each versioned
-- write outcome. Specialized to the versioned (aggregate) path so the stream
-- key ('UUID') and positions ('EventVersion') are concrete.
module Eventium.Store.Telemetry
  ( telemetryEventStoreWriter,
  )
where

import Eventium.Store.Class (EventStoreWriter (..), VersionedEventStoreWriter)
import Eventium.Store.Types
  ( EventWriteError (..),
    TaggedEvent (..),
  )
import Eventium.Telemetry
import qualified Eventium.UUID as UUID

-- | Wrap a versioned 'TaggedEvent' writer so it emits 'EventsPersisted' on a
-- successful write and 'WriteConflict' on an optimistic-concurrency failure.
-- An empty batch emits nothing. A store-level exception is not reported (the
-- decorator does not bracket) — see the design spec's deferred note.
telemetryEventStoreWriter ::
  (Monad m) =>
  Telemetry m ->
  VersionedEventStoreWriter m (TaggedEvent encoded) ->
  VersionedEventStoreWriter m (TaggedEvent encoded)
telemetryEventStoreWriter telemetry (EventStoreWriter write) =
  EventStoreWriter $ \key expectedPos events -> do
    result <- write key expectedPos events
    case events of
      [] -> pure ()
      _ ->
        let sk = StreamKeyText (UUID.uuidToText key)
         in case result of
              Right wr -> telemetry.emit (EventsPersisted sk (map (.metadata) events) wr)
              Left (EventStreamNotAtExpectedVersion actualPos) ->
                telemetry.emit (WriteConflict sk (ConflictInfo expectedPos actualPos))
    pure result
```

- [ ] **Step 4: Run — verify it passes**

Run: `cd /Users/oleksandrsy/Projects/Self/eventium && just build && cabal test eventium-core:spec --test-option=--match --test-option="/telemetryEventStoreWriter/"`
Expected: **PASS** (4 examples).

- [ ] **Step 5: Format, lint, commit**

```bash
cd /Users/oleksandrsy/Projects/Self/eventium
just format && just lint
git add eventium-core/src/Eventium/Store/Telemetry.hs eventium-core/tests/Eventium/Store/TelemetrySpec.hs
git commit -m "feat(store): telemetryEventStoreWriter write-path decorator"
```

---

## Task 4: Re-export from the umbrella module + version bump + docs

**Files:**
- Modify: `eventium-core/src/Eventium.hs`
- Modify: `eventium-core/package.yaml`
- Modify: `CHANGELOG.md`
- Modify: `eventium-sql-common/README.md`

- [ ] **Step 1: Re-export the new modules**

In `eventium-core/src/Eventium.hs`, add (alphabetically among the `import … as X` lines):

```haskell
import Eventium.Store.Telemetry as X
import Eventium.Telemetry as X
```

(No umbrella re-export clash: `grep -rnwE "^(expected|actual|emit)" eventium-core/src` finds no other top-level `expected`/`actual`/`emit`/`Signal`/`Telemetry`, so re-exporting `ConflictInfo(..)`'s field labels through `module X` is safe.)

- [ ] **Step 2: Bump the version — co-version the whole suite**

The eventium packages are co-versioned (all currently `0.5.2`), and every sibling
package **and example** pins `eventium-* >= 0.5.0 && < 0.6.0`. Bumping only
`eventium-core` would break resolution. So:
- Set `version:` to `0.6.0` in ALL six library `package.yaml` files:
  `eventium-core`, `eventium-sql-common`, `eventium-postgresql`, `eventium-sqlite`,
  `eventium-memory`, `eventium-testkit`.
- Update **every** `eventium-* >= 0.5.0 && < 0.6.0` bound to
  `>= 0.6.0 && < 0.7.0` — in all six library packages **and** the three examples
  (`examples/cafe`, `examples/counter-cli`, `examples/bank`). Grep to find them all:
  `grep -rn "eventium-.* < 0.6.0" eventium-* examples`.
- Run `just build` (regenerates every `.cabal` via hpack) and confirm the whole
  workspace still resolves + builds.

- [ ] **Step 3: CHANGELOG**

Prepend a `## 0.6.0` section to `CHANGELOG.md`:

```markdown
## 0.6.0

### Added

- **Telemetry (`Eventium.Telemetry`)** — a generic, framework-free structured
  sink (`Telemetry m` over a `Signal` sum type) with a `silentTelemetry` no-op
  default. First subsystem wired: the write path, via
  `telemetryEventStoreWriter` (`Eventium.Store.Telemetry`), emitting
  `EventsPersisted` / `WriteConflict`.
- **`EventMetadata.custom :: Map Text Text`** — a generic per-event context bag
  (e.g. an app's user id), plus `insertCustomMetadata`. Injected via the existing
  `MetadataEnricher` seam.

### Changed

- `EventMetadata` JSON now **omits** absent/empty optional fields (the three
  `Maybe`s and `custom`) instead of emitting explicit `null`. Fully
  read-compatible: pre-existing rows with explicit `null`s still decode. New
  writes are leaner and no longer byte-identical to historical rows.
```

- [ ] **Step 4: Fix the doc example**

In `eventium-sql-common/README.md` (~lines 35–37), change the metadata example that shows `"causationId": null` to the omitted-key shape fresh writes now produce (drop the null keys from the example).

- [ ] **Step 5: Full build + test + lint, then commit**

Run:
```bash
cd /Users/oleksandrsy/Projects/Self/eventium
just build && cabal test eventium-core:spec && just check
```
Expected: whole `eventium-core` suite green; ormolu/hlint clean.

```bash
git add eventium-core/src/Eventium.hs eventium-core/package.yaml CHANGELOG.md eventium-sql-common/README.md
git commit -m "feat(telemetry): export from umbrella, bump 0.6.0, changelog + docs"
```

---

## Task 5: Full-suite guard across all eventium packages

**Files:** none (verification only)

- [ ] **Step 1: Build & test every package with the CI flag**

Some packages depend on `eventium-core`; the `EventMetadata` constructor arity change could ripple. Run:
```bash
cd /Users/oleksandrsy/Projects/Self/eventium
just ci   # or: cabal build all -fci && cabal test all -fci
```
Expected: all packages (`eventium-core`, `eventium-sql-common`, `eventium-postgresql`, `eventium-sqlite`, `eventium-memory`, `eventium-testkit`, examples) build and test green under `-Werror`.

- [ ] **Step 2: Fix any positional `EventMetadata` fallout**

If any package fails to compile on a positional `EventMetadata (...)` construction, append `mempty` for the new `custom` field (the compiler names each site). Commit fixes:
```bash
git add -A && git commit -m "fix: seed EventMetadata.custom at remaining construction sites"
```
(Expected: none outside `eventium-core`, since backends construct metadata through the enriching writers — but verify, don't assume.)

- [ ] **Step 3: Open the eventium PR**

Push the branch and open a PR against eventium `master`:
```bash
git push -u origin feat/telemetry-event-persistence
gh pr create --repo aleks-sidorenko/eventium --title "feat(telemetry): structured sink + event-persistence slice" --body "Implements eventium#10 Spec 1 (write path). See backend spec 2026-08-01-eventium-telemetry-event-persistence-design.md."
```

---

## Task 6: Backend silent seam (backend repo — gated on eventium 0.6.0)

**Files (backend repo `/Users/oleksandrsy/Projects/Current/Wix/server-infra`):**
- Modify: `cabal.project` and/or `package.yaml` — depend on eventium `0.6.0`.
- Modify: `src/Infrastructure/Eventium.hs` — wrap the tagged writer with `telemetryEventStoreWriter silentTelemetry`.

> **Gate:** the backend currently resolves eventium from Hackage `0.5.2`. This task needs `0.6.0`. Choose one: (a) publish eventium `0.6.0` and bump the backend bound; or (b) for pre-publish validation, point `cabal.project` at the local checkout (`source-repository-package`/local `packages:` entry for `../../../Self/eventium/*`). Prefer (a) once the eventium PR merges; use (b) only to validate the seam early.

- [ ] **Step 1: Bump the eventium dependency** to allow `0.6.0` (widen the `< 0.6.0` bounds in `package.yaml` to `< 0.7.0`; re-run `hpack` via `just build`).

- [ ] **Step 2: Wire the silent seam**

In `src/Infrastructure/Eventium.hs`, wrap the tagged writer where the decorator stack is assembled (near `metadataEnriching*` / `publishing*`) with `telemetryEventStoreWriter silentTelemetry`. Import it from `Eventium.Store.Telemetry` (or the umbrella). This is **zero behaviour change** — `silentTelemetry` is a no-op.

- [ ] **Step 3: Build + test the backend**

Run: `cd /Users/oleksandrsy/Projects/Current/Wix/server-infra && just build && just test`
Expected: green; no behavioural diff (the seam is silent). Full `cabal test all` needs the `eventium_test` Postgres DB — its absence causes ~28 environmental failures unrelated to this change.

- [ ] **Step 4: Commit** (hand to the user if GPG signing prompts)

```bash
git add src/Infrastructure/Eventium.hs package.yaml cabal.project backend.cabal
git commit -m "chore(eventium): wire silent telemetry seam into the write stack"
```

---

## Done criteria

- eventium: `Eventium.Telemetry` + `Eventium.Store.Telemetry` exist, `EventMetadata.custom` ships with omit-empty read-compatible JSON, all packages green under `-fci`, PR open against eventium `master`.
- backend: the silent `telemetryEventStoreWriter silentTelemetry` seam composes with the real writer stack with no behavioural change (once eventium 0.6.0 is consumable).
- The real logging/metrics interpreter and `insertCustomMetadata "userId"` enricher are **Spec 2**, not this plan.
