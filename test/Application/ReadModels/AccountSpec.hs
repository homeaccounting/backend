{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.AccountSpec
-- Description : Unit tests for the account read model's balanceAsOf query.
--
-- These tests exercise 'balanceAsOf' against an in-memory event store seeded
-- via the raw STM versioned writer (bypassing the tagged-codec publishing
-- pipeline so we test the read-side fold without the write-side machinery).
module Application.ReadModels.AccountSpec (spec) where

import Application.ReadModels.Account (balanceAsOf)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountCreated (..),
    AccountCredited (..),
    AccountDebited (..),
    OverdraftLimitSet (..),
  )
import Domain.Core.Types
  ( AccountId,
    AccountRole (..),
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
import Eventium (EventStoreReader (..), EventStoreWriter (..), ExpectedPosition (..))
import RIO
import Test.Hspec
import Testkit.Helpers
  ( mockAccountId,
    mockTransactionId,
    mockUserId,
  )
import Testkit.InMemoryEventStore
  ( InMemoryEventStores (..),
    createInMemoryEventStores,
  )

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

acctA :: AccountId
acctA = mockAccountId (UUID.fromWords 0xa 0 0 0)

unknownAcct :: AccountId
unknownAcct = mockAccountId (UUID.fromWords 0xdead 0 0 0)

ownerUser :: UserId
ownerUser = mockUserId (UUID.fromWords 0xc0ffee 0 0 0)

usd :: Rational -> Money
usd = unsafeMoney USD

-- | Build a UTCTime at midnight for the given date.
t :: Integer -> Int -> Int -> UTCTime
t y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

t1, t2, t3, t4 :: UTCTime
t1 = t 2026 1 1
t2 = t 2026 2 1
t3 = t 2026 3 1
t4 = t 2026 4 1

-- -----------------------------------------------------------------------------
-- Test harness
-- -----------------------------------------------------------------------------

-- | Seed events into a fresh in-memory event store and run 'balanceAsOf'.
--
-- The seeded stream bypasses the tagged-codec publishing pipeline used by
-- the production tagged writer. We write directly to the STM versioned
-- store and lift the reader into IO. This keeps the test focused on the
-- read-side fold and avoids spinning up command handlers, sagas, and
-- read-model handlers for unit tests.
runBalanceAsOf ::
  AccountId ->
  -- | Events to seed onto the target account's stream.
  [AccountingEvent] ->
  -- | Lookup table mapping transactionId -> authoritative business date.
  [(TransactionId, UTCTime)] ->
  -- | Business cutoff D.
  UTCTime ->
  IO (Maybe Money)
runBalanceAsOf accountId events lookupEntries asOf = do
  stores <- createInMemoryEventStores
  let EventStoreWriter stmWrite = stores.inMemoryWriter
      EventStoreReader stmRead = stores.inMemoryReader
      ioReader = EventStoreReader (atomically . stmRead)
      lookupMap = Map.fromList lookupEntries
      lookupAt txId = Map.lookup txId lookupMap
  unless (null events)
    $ void
    $ atomically
    $ stmWrite (unAccountId accountId) AnyPosition events
  balanceAsOf ioReader lookupAt accountId asOf

-- | Construct a 'TransactionId' from a 'Word32' (matches the convention used
-- by 'creditEvent' / 'debitEvent').
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
creditEvent txWord amount =
  AccountCreditedEvent
    AccountCredited
      { amount = amount,
        transactionId = txIdOf txWord
      }

debitEvent :: Word32 -> Money -> AccountingEvent
debitEvent txWord amount =
  AccountDebitedEvent
    AccountDebited
      { amount = amount,
        transactionId = txIdOf txWord
      }

accessGrantedEvent :: AccountingEvent
accessGrantedEvent =
  AccountAccessGrantedEvent
    AccountAccessGranted
      { userId = mockUserId (UUID.fromWords 0xfeed 0 0 0),
        role = Editor,
        by = ownerUser
      }

overdraftSetEvent :: AccountingEvent
overdraftSetEvent =
  OverdraftLimitSetEvent
    OverdraftLimitSet
      { overdraftLimit = Just (usd 500),
        by = ownerUser
      }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Application.ReadModels.Account" $ do
  describe "balanceAsOf" $ do
    it "returns Nothing for an unknown account" $ do
      result <- runBalanceAsOf unknownAcct [] [] t1
      result `shouldBe` Nothing

    it "returns initialBalance when D >= AccountCreated and no debits/credits exist" $ do
      let initial = usd 1000
      result <- runBalanceAsOf acctA [createdEvent initial] [] t2
      result `shouldBe` Just initial

    it "includes credits with at <= D" $ do
      let initial = usd 1000
          events =
            [ createdEvent initial,
              creditEvent 1 (usd 200)
            ]
          lookup_ = [(txIdOf 1, t2)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 1200)

    it "subtracts debits with at <= D" $ do
      let initial = usd 1000
          events =
            [ createdEvent initial,
              debitEvent 1 (usd 300)
            ]
          lookup_ = [(txIdOf 1, t2)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 700)

    it "excludes credits with at > D" $ do
      let initial = usd 1000
          events =
            [ createdEvent initial,
              creditEvent 1 (usd 200),
              creditEvent 2 (usd 500)
            ]
          lookup_ = [(txIdOf 1, t2), (txIdOf 2, t4)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 1200)

    it "excludes debits with at > D" $ do
      let initial = usd 1000
          events =
            [ createdEvent initial,
              debitEvent 1 (usd 300),
              debitEvent 2 (usd 400)
            ]
          lookup_ = [(txIdOf 1, t2), (txIdOf 2, t4)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 700)

    it "ignores access/overdraft events for balance purposes" $ do
      let initial = usd 1000
          events =
            [ createdEvent initial,
              accessGrantedEvent,
              overdraftSetEvent,
              creditEvent 1 (usd 200)
            ]
          lookup_ = [(txIdOf 1, t2)]
      result <- runBalanceAsOf acctA events lookup_ t3
      result `shouldBe` Just (usd 1200)
