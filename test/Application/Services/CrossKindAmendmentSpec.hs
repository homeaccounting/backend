{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.CrossKindAmendmentSpec
-- Description : Service-layer truth-table tests for cross-kind amendment synthesis.
--
-- Covers all seven rows of the spec §"Service layer" truth table:
--
--  1. Within-kind Income amount-only amend with explicit allocations.
--  2. Cross-kind Income → Transfer: allocations dropped, kind becomes Transfer.
--  3. Cross-kind Transfer → Income with supplied allocations: accepted.
--  4. Cross-kind Transfer → Income with newAllocations = Nothing: rejected.
--  5. Transfer-derived kind with allocations supplied: rejected.
--  6. Income kind with unknown categoryId: rejected.
--  7. Identity amend: no events emitted, amendmentCount unchanged.
--
-- Also covers Task 7 property:
--
--  (4) 'isIdentityAmend' holds for self-amend: for any (td, cmd) where all
--      comparison fields of cmd are derived from td, isIdentityAmend td cmd
--      returns True.
--
-- New-contract coverage (within-kind amendment, no cross-kind change):
--
--  (8) Within-kind Income amend with newAllocations = Nothing → rejected with
--      'AllocationsRequiredForCategorisedKind'.
--  (9) Within-kind Income amend with allocations that do not sum to the new
--      target amount → rejected with a 'ValidationErr' (field \"allocations\").
module Application.Services.CrossKindAmendmentSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.ConfigurationService
  ( seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( amendTransaction,
    initiateIncome,
    initiateTransfer,
    isIdentityAmend,
  )
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..), ValidationError (..))
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Allocations,
    TransactionId,
    TransactionType (..),
    UserId,
    mkIncomeAllocations,
    unsafeDictionaryEntryId,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Commands (AmendTransaction (..))
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, (===))
import Testkit.Fixtures
  ( MetadataFixture (..),
    createDefaultAccount,
    incomeAllocs,
    setupMetadataFixture,
    userExternalAccountId,
  )
import Testkit.Generators (genIdentityAmendInputs)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)

-- -----------------------------------------------------------------------------
-- Local helpers
-- -----------------------------------------------------------------------------

-- | Construct an 'AmendTransaction' with the minimum required fields.
-- 'newTransactionType' is a placeholder — the service overwrites it via
-- 'synthesiseAmendmentTransactionType' before dispatching.
buildAmend ::
  TransactionId ->
  AccountId ->
  AccountId ->
  Rational ->
  Rational ->
  Maybe Allocations ->
  UserId ->
  AmendTransaction
buildAmend txId src tgt srcAmt tgtAmt mAllocs uid =
  AmendTransaction
    { transactionId = txId,
      newSourceAccountId = src,
      newTargetAccountId = tgt,
      newSourceAmount = unsafeMoney Core.USD srcAmt,
      newTargetAmount = unsafeMoney Core.USD tgtAmt,
      newExchangeRate = Nothing,
      newAllocations = mAllocs,
      newTransactionType = Transfer, -- placeholder; overwritten by service
      by = uid
    }

-- | Seed a fresh env, register a user with default configuration,
-- and resolve common accounts. Returns the fixture plus an extra
-- Regular account (accB) and the user's External account id.
data CrossKindFixture = CrossKindFixture
  { ckEnv :: !AppEnv,
    ckFx :: !MetadataFixture,
    -- | An additional Regular USD wallet for "both sides Regular" scenarios.
    ckAccB :: !AccountId,
    -- | The user's auto-created External account id.
    ckExternal :: !AccountId
  }

setupCrossKindFixture :: Text -> IO CrossKindFixture
setupCrossKindFixture email = do
  env <- createTestAppEnvWithProcessManager
  runAppM env seedDefaultConfiguration
  fx <- setupMetadataFixture env email
  accB <- createDefaultAccount env fx.userId "WalletB"
  extId <- userExternalAccountId env fx.userId
  pure
    CrossKindFixture
      { ckEnv = env,
        ckFx = fx,
        ckAccB = accB,
        ckExternal = extId
      }

-- | Seed an Income transaction (External → Regular) with a single
-- income-category allocation equal to the amount.
seedIncome :: CrossKindFixture -> Rational -> IO (TransactionId, TransactionData)
seedIncome ck amt = do
  let env = ck.ckEnv
      fx = ck.ckFx
  res <-
    runAppM env
      $ initiateIncome
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (incomeAllocs fx (unsafeMoney Core.USD amt))
        Set.empty
        "Seed"
        Nothing
  case res of
    Right r -> pure r
    Left err -> fail $ "seedIncome failed: " <> show err

-- | Seed a Transfer (Regular → Regular) transaction.
seedTransfer :: CrossKindFixture -> Rational -> IO (TransactionId, TransactionData)
seedTransfer ck amt = do
  let env = ck.ckEnv
      fx = ck.ckFx
  res <-
    runAppM env
      $ initiateTransfer
        fx.userId
        fx.regularAccountId
        ck.ckAccB
        (unsafeMoney Core.USD amt)
        Set.empty
        "Seed"
        Nothing
        Nothing
  case res of
    Right r -> pure r
    Left err -> fail $ "seedTransfer failed: " <> show err

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "amendTransaction — cross-kind synthesis" $ do
  it "(1) within-kind amount-only Income amend with explicit allocations" $ do
    ck <- setupCrossKindFixture "cross-kind-1@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, original) <- seedIncome ck 100
    -- Same accounts and kind; amount bumped to 150 with explicit allocations
    -- summing to the new total (amount-changing amends no longer rescale).
    let cmd =
          buildAmend
            txId
            original.sourceAccountId
            original.targetAccountId
            150
            150
            (Just (incomeAllocs fx (unsafeMoney Core.USD 150)))
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    case result of
      Right td -> do
        td.amendmentCount `shouldBe` 1
        td.sourceAmount `shouldBe` unsafeMoney Core.USD 150
        -- Income kind preserved; explicit allocation now totals 150.
        td.transactionType
          `shouldBe` Income (incomeAllocs fx (unsafeMoney Core.USD 150))
      Left err -> expectationFailure $ "expected Right, got: " <> show err

  it "(2) cross-kind Income → Transfer drops allocations" $ do
    ck <- setupCrossKindFixture "cross-kind-2@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, _original) <- seedIncome ck 100
    -- Swap to Regular → Regular: kind becomes Transfer, allocations dropped.
    let cmd =
          buildAmend
            txId
            fx.regularAccountId
            ck.ckAccB
            100
            100
            Nothing
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    case result of
      Right td -> td.transactionType `shouldBe` Transfer
      Left err -> expectationFailure $ "expected Right, got: " <> show err

  it "(3) cross-kind Transfer → Income with supplied allocations" $ do
    ck <- setupCrossKindFixture "cross-kind-3@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, _original) <- seedTransfer ck 100
    -- Amend source to External, target stays Regular: kind becomes Income.
    let newAllocs = incomeAllocs fx (unsafeMoney Core.USD 100)
        cmd =
          buildAmend
            txId
            ck.ckExternal
            fx.regularAccountId
            100
            100
            (Just newAllocs)
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    case result of
      Right td -> td.transactionType `shouldBe` Income newAllocs
      Left err -> expectationFailure $ "expected Right, got: " <> show err

  it "(4) rejects Transfer → Income with newAllocations = Nothing" $ do
    ck <- setupCrossKindFixture "cross-kind-4@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, _original) <- seedTransfer ck 100
    -- Kind change to Income with no allocations supplied: must reject.
    let cmd =
          buildAmend
            txId
            ck.ckExternal
            fx.regularAccountId
            100
            100
            Nothing
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    result `shouldBe` Left AllocationsRequiredForCategorisedKind

  it "(5) rejects allocations supplied for Transfer-derived kind" $ do
    ck <- setupCrossKindFixture "cross-kind-5@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    -- Seed an Income first; amend to Regular → Regular (Transfer kind)
    -- while also supplying allocations — must reject.
    (txId, _original) <- seedIncome ck 100
    let bogusAllocs = incomeAllocs fx (unsafeMoney Core.USD 100)
        cmd =
          buildAmend
            txId
            fx.regularAccountId
            ck.ckAccB
            100
            100
            (Just bogusAllocs)
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    result `shouldBe` Left AllocationsNotAllowedForTransferKind

  it "(6) rejects allocation with categoryId not in user's income dictionary" $ do
    ck <- setupCrossKindFixture "cross-kind-6@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, original) <- seedIncome ck 100
    -- Construct an allocation with a DictionaryEntryId that was never
    -- added to this user's income dictionary.
    let unknownEntryId =
          unsafeDictionaryEntryId
            (UUID.fromWords 0xDEADBEEF 0xDEADBEEF 0xDEADBEEF 0xDEADBEEF)
        badAllocs = mkIncomeAllocations (Allocation unknownEntryId (unsafeMoney Core.USD 100) Nothing :| [])
        cmd =
          buildAmend
            txId
            original.sourceAccountId
            original.targetAccountId
            100
            100
            (Just badAllocs)
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    case result of
      Left (CategoryNotFound _) -> pure ()
      other -> expectationFailure $ "expected Left (CategoryNotFound _), got: " <> show other

  it "(7) identity-amend short-circuits with no events emitted" $ do
    ck <- setupCrossKindFixture "cross-kind-7@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, original) <- seedIncome ck 100
    -- Re-supply the exact same payload including allocations so the
    -- synthesised newTransactionType equals the existing transactionType.
    let sameAllocs = incomeAllocs fx (unsafeMoney Core.USD 100)
        cmd =
          buildAmend
            txId
            original.sourceAccountId
            original.targetAccountId
            100
            100
            (Just sameAllocs)
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    case result of
      Right td -> do
        -- No TransactionAmendmentCompleted event: count stays at its
        -- post-initiation value of 0.
        td.amendmentCount `shouldBe` 0
        td.sourceAmount `shouldBe` original.sourceAmount
        td.transactionType `shouldBe` original.transactionType
      Left err -> expectationFailure $ "expected Right, got: " <> show err

  prop "(4) isIdentityAmend holds for self-amend"
    $ forAll genIdentityAmendInputs
    $ \(td, cmd) -> isIdentityAmend td cmd === True

  -- -------------------------------------------------------------------------
  -- New-contract coverage: within-kind categorised amendment edge cases
  -- -------------------------------------------------------------------------

  it "(8) within-kind Income amend with newAllocations = Nothing is rejected" $ do
    -- Scenario: the transaction stays Income (same External → Regular accounts)
    -- but the caller omits 'newAllocations'. Since the derived kind is
    -- IncomeKind, 'synthesiseAmendmentTransactionType' must reject with
    -- 'AllocationsRequiredForCategorisedKind'.
    ck <- setupCrossKindFixture "cross-kind-8@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, original) <- seedIncome ck 100
    -- Same accounts as the original (stays Income), amount changes, no allocs.
    let cmd =
          buildAmend
            txId
            original.sourceAccountId
            original.targetAccountId
            150
            150
            Nothing -- omitting allocations for a categorised kind must be rejected
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    result `shouldBe` Left AllocationsRequiredForCategorisedKind

  it "(9) within-kind Income amend with allocations that do not sum to newTargetAmount is rejected" $ do
    -- Scenario: the caller supplies newAllocations but their combined total
    -- (120 USD) is less than the new target amount (150 USD).
    -- 'mkIncome' enforces sum == categorised total and returns a ValidationErr.
    ck <- setupCrossKindFixture "cross-kind-9@test.com"
    let env = ck.ckEnv
        fx = ck.ckFx
    (txId, original) <- seedIncome ck 100
    -- Allocations sum to 120, but newTargetAmount is 150 → mismatch.
    let mismatchedAllocs = incomeAllocs fx (unsafeMoney Core.USD 120)
        cmd =
          buildAmend
            txId
            original.sourceAccountId
            original.targetAccountId
            150
            150
            (Just mismatchedAllocs)
            fx.userId
    result <- runAppM env (amendTransaction fx.userId txId cmd)
    case result of
      Left (ValidationErr ve) -> ve.validationField `shouldBe` "allocations"
      other -> expectationFailure $ "expected Left (ValidationErr {validationField=\"allocations\"}), got: " <> show other
