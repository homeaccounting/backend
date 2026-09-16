{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.BankImportDedupSpec
-- Description : Guarantees of the bank-import dedup projection.
--
-- The dedup table is the only thing between a re-synced statement and a
-- duplicate transaction. These examples cover the two properties it must hold
-- beyond plain insertion:
--
--   * __Legacy ids normalize on apply__ — a PrivatBank retail id written before
--     commit 38968e9 projects onto today's key, so 'isImported' matches what
--     the parser now produces. This is the backend#3 fix, and it works by
--     projection rather than table migration so a rebuild stays correct.
--   * __Attribution counting__ — a transaction's number of attributed external
--     ids, which reconciliation compares against capacity (a transfer takes
--     two, one per leg).
module Application.ReadModels.BankImportDedupSpec (spec) where

import Application.ReadModels.BankImportReadModel
  ( applyBankImportEvent,
    importAttributionCount,
    isImported,
    isReconciled,
  )
import Data.Time (UTCTime (..), fromGregorian)
import qualified Data.UUID as UUID
import Domain.Banking.Import (unsafeExternalTransactionId)
import Domain.Core.Types (TransactionId)
import RIO
import Test.Hspec
import Testkit.Helpers (mockAccountId, mockTransactionId)
import Testkit.InMemoryEventStore (runDbIn, seedGlobals)
import Testkit.TransactionEvents (postingInitiatedImportGlobal, transactionImportReconciledGlobal)

-- | The pre-38968e9 spelling of a real PrivatBank retail row.
legacyId :: Text
legacyId = "privatbank:04.08.2026 14:02:50:-149:-17835.51"

-- | What the parser produces for that same row today.
currentId :: Text
currentId = "privatbank:04.08.2026 14:02:50:(-149) % 1:(-1783551) % 100"

tx1 :: TransactionId
tx1 = mockTransactionId (UUID.fromWords 1 0 0 0)

businessAt :: UTCTime
businessAt = UTCTime (fromGregorian 2026 8 4) 0

spec :: Spec
spec = do
  describe "legacy external ids normalize on apply" $ do
    it "matches a legacy-keyed import against today's derivation" $ do
      env <-
        seedGlobals
          applyBankImportEvent
          [ postingInitiatedImportGlobal
              tx1
              (mockAccountId (UUID.fromWords 10 0 0 0))
              (mockAccountId (UUID.fromWords 11 0 0 0))
              (unsafeExternalTransactionId legacyId :| [])
              businessAt
              1
          ]
      imported <- runDbIn env (isImported (unsafeExternalTransactionId currentId))
      imported `shouldBe` True

    it "is idempotent across re-application" $ do
      let event =
            postingInitiatedImportGlobal
              tx1
              (mockAccountId (UUID.fromWords 10 0 0 0))
              (mockAccountId (UUID.fromWords 11 0 0 0))
              (unsafeExternalTransactionId legacyId :| [])
              businessAt
              1
      env <- seedGlobals applyBankImportEvent [event, event]
      n <- runDbIn env (importAttributionCount tx1)
      n `shouldBe` 1

  describe "importAttributionCount" $ do
    it "counts both legs of a detected internal transfer" $ do
      env <-
        seedGlobals
          applyBankImportEvent
          [ postingInitiatedImportGlobal
              tx1
              (mockAccountId (UUID.fromWords 10 0 0 0))
              (mockAccountId (UUID.fromWords 11 0 0 0))
              ( unsafeExternalTransactionId "mono-debit-leg"
                  :| [unsafeExternalTransactionId "mono-credit-leg"]
              )
              businessAt
              1
          ]
      n <- runDbIn env (importAttributionCount tx1)
      n `shouldBe` 2

    it "is zero for a transaction with no import attribution" $ do
      env <- seedGlobals applyBankImportEvent []
      n <- runDbIn env (importAttributionCount tx1)
      n `shouldBe` 0

    it "agrees with isReconciled for an attributed transaction" $ do
      env <-
        seedGlobals
          applyBankImportEvent
          [ postingInitiatedImportGlobal
              tx1
              (mockAccountId (UUID.fromWords 10 0 0 0))
              (mockAccountId (UUID.fromWords 11 0 0 0))
              (unsafeExternalTransactionId "mono-1" :| [])
              businessAt
              1
          ]
      (n, recon) <- runDbIn env ((,) <$> importAttributionCount tx1 <*> isReconciled tx1)
      n `shouldBe` 1
      recon `shouldBe` True

    it "agrees with isReconciled for an unattributed transaction" $ do
      env <- seedGlobals applyBankImportEvent []
      recon <- runDbIn env (isReconciled tx1)
      recon `shouldBe` False

  describe "already-canonical ids" $ do
    it "preserves an already-canonical PrivatBank id" $ do
      env <-
        seedGlobals
          applyBankImportEvent
          [ postingInitiatedImportGlobal
              tx1
              (mockAccountId (UUID.fromWords 10 0 0 0))
              (mockAccountId (UUID.fromWords 11 0 0 0))
              (unsafeExternalTransactionId currentId :| [])
              businessAt
              1
          ]
      imported <- runDbIn env (isImported (unsafeExternalTransactionId currentId))
      imported `shouldBe` True

  describe "TransactionImportReconciled event normalization" $ do
    it "normalizes legacy ids in reconciliation events" $ do
      env <-
        seedGlobals
          applyBankImportEvent
          [ transactionImportReconciledGlobal
              tx1
              (unsafeExternalTransactionId legacyId :| [])
              1
          ]
      imported <- runDbIn env (isImported (unsafeExternalTransactionId currentId))
      imported `shouldBe` True
