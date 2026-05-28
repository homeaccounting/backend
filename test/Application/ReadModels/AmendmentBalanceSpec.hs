{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.AmendmentBalanceSpec
-- Description : Tests for AccountDebitReversed / AccountCreditReversed folds.
--
-- Covers both the live read-model fold ('handleAccountEvents' /
-- 'processEvent') and the temporal balance fold ('balanceAsOf').
module Application.ReadModels.AmendmentBalanceSpec (spec) where

import Application.ReadModels.Account
  ( AccountData (..),
    accountToMap,
    balanceAsOf,
    createAccountReadModel,
    handleAccountEvents,
  )
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountCreated (..),
    AccountCreditReversed (..),
    AccountCredited (..),
    AccountDebitReversed (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Currency (..),
    Money,
    TransactionId,
    UserId,
    defaultCash,
    unAccountId,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..))
import Eventium (EventHandler (..), EventStoreReader (..), EventStoreWriter (..), ExpectedPosition (..), StreamEvent (..), emptyMetadata)
import qualified Eventium
import RIO
import Test.Hspec
import Testkit.Helpers (mockAccountId, mockTransactionId, mockUserId)
import Testkit.InMemoryEventStore (InMemoryEventStores (..), createInMemoryEventStores)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

acctA :: AccountId
acctA = mockAccountId (UUID.fromWords 0xa 0 0 0)

ownerUser :: UserId
ownerUser = mockUserId (UUID.fromWords 0xc0ffee 0 0 0)

usd :: Rational -> Money
usd = unsafeMoney USD

t :: Integer -> Int -> Int -> UTCTime
t y mo d = UTCTime (fromGregorian y mo d) (secondsToDiffTime 0)

t1, t2, t3, t4 :: UTCTime
t1 = t 2026 1 1
t2 = t 2026 2 1
t3 = t 2026 3 1
t4 = t 2026 4 1

txIdOf :: Word32 -> TransactionId
txIdOf w = mockTransactionId (UUID.fromWords w 0 0 0)

-- -----------------------------------------------------------------------------
-- Event builders
-- -----------------------------------------------------------------------------

createdEvent :: Money -> AccountingEvent
createdEvent initial =
  AccountCreatedEvent
    AccountCreated
      { name = "Checking",
        initialBalance = initial,
        by = ownerUser,
        accountType = Regular defaultCash,
        overdraftLimit = Nothing
      }

creditEvent :: Word32 -> Money -> AccountingEvent
creditEvent w amt =
  AccountCreditedEvent
    AccountCredited {amount = amt, transactionId = txIdOf w}

debitEvent :: Word32 -> Money -> AccountingEvent
debitEvent w amt =
  AccountDebitedEvent
    AccountDebited {amount = amt, transactionId = txIdOf w}

debitReversedEvent :: Word32 -> Money -> UTCTime -> AccountingEvent
debitReversedEvent w amt at_ =
  AccountDebitReversedEvent
    AccountDebitReversed {amount = amt, transactionId = txIdOf w, at = at_}

creditReversedEvent :: Word32 -> Money -> UTCTime -> AccountingEvent
creditReversedEvent w amt at_ =
  AccountCreditReversedEvent
    AccountCreditReversed {amount = amt, transactionId = txIdOf w, at = at_}

-- -----------------------------------------------------------------------------
-- Test harness: live read model
-- -----------------------------------------------------------------------------

-- | Apply 'AccountingEvent' payloads through the production
-- 'handleAccountEvents' pipeline by synthesising GlobalStreamEvents on
-- the target account's stream.
runLiveBalance :: AccountId -> [AccountingEvent] -> IO (Maybe Money)
runLiveBalance accountId events = do
  rm <- createAccountReadModel
  let EventHandler h = handleAccountEvents rm
  h (zipWith mkGlobal [0 ..] events)
  m <- accountToMap rm
  pure ((.balance) <$> Map.lookup accountId m)
  where
    mkGlobal :: Eventium.SequenceNumber -> AccountingEvent -> Eventium.GlobalStreamEvent AccountingEvent
    mkGlobal seqNo payload =
      let inner =
            StreamEvent
              (unAccountId accountId)
              0
              (emptyMetadata "")
              payload
       in StreamEvent () seqNo (emptyMetadata "") inner

-- -----------------------------------------------------------------------------
-- Test harness: temporal balance fold (balanceAsOf)
-- -----------------------------------------------------------------------------

runBalanceAsOf ::
  AccountId ->
  [AccountingEvent] ->
  [(TransactionId, UTCTime)] ->
  UTCTime ->
  IO (Maybe Money)
runBalanceAsOf accountId events lookupEntries asOf = do
  stores <- createInMemoryEventStores
  let EventStoreWriter stmWrite = stores.inMemoryWriter
      EventStoreReader stmRead = stores.inMemoryReader
      ioReader = EventStoreReader (atomically . stmRead)
      lookupMap = Map.fromList lookupEntries
      lookupAt txId_ = Map.lookup txId_ lookupMap
  unless (null events)
    $ void
    $ atomically
    $ stmWrite (unAccountId accountId) AnyPosition events
  balanceAsOf ioReader lookupAt accountId asOf

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Account read model — reversal events" $ do
  describe "live balance (handleAccountEvents)" $ do
    it "AccountDebitReversed adds back to the live balance" $ do
      result <-
        runLiveBalance
          acctA
          [ createdEvent (usd 1000),
            debitEvent 1 (usd 200),
            debitReversedEvent 1 (usd 200) t2
          ]
      result `shouldBe` Just (usd 1000)

    it "AccountCreditReversed subtracts from the live balance" $ do
      result <-
        runLiveBalance
          acctA
          [ createdEvent (usd 0),
            creditEvent 1 (usd 100),
            creditReversedEvent 1 (usd 100) t2
          ]
      result `shouldBe` Just (usd 0)

    it "AccountCreditReversed can take the balance negative" $ do
      result <-
        runLiveBalance
          acctA
          [ createdEvent (usd 0),
            creditEvent 1 (usd 100),
            debitEvent 2 (usd 80),
            creditReversedEvent 1 (usd 100) t2
          ]
      result `shouldBe` Just (usd (-80))

  describe "balanceAsOf" $ do
    it "folds AccountDebitReversed with at <= cutoff symmetrically" $ do
      let events =
            [ createdEvent (usd 1000),
              debitEvent 1 (usd 200),
              debitReversedEvent 1 (usd 200) t2
            ]
          lookup_ = [(txIdOf 1, t2)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 1000)

    it "folds AccountCreditReversed with at <= cutoff symmetrically" $ do
      let events =
            [ createdEvent (usd 0),
              creditEvent 1 (usd 100),
              creditReversedEvent 1 (usd 100) t2
            ]
          lookup_ = [(txIdOf 1, t2)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 0)

    it "skips reversal whose lookup-resolved business date is after the cutoff" $ do
      -- Both the original debit and its reversal key off the same
      -- transactionId. With the TX's authoritative @at@ resolved to t4
      -- and cutoff t3, both legs are skipped — preserving symmetry.
      let events =
            [ createdEvent (usd 1000),
              debitEvent 1 (usd 200),
              debitReversedEvent 1 (usd 200) t1
            ]
          lookup_ = [(txIdOf 1, t4)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 1000)
