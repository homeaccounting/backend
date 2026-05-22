{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.BalanceAsOfJoinSpec
-- Description : Pure unit tests for the TX-aggregate join inside 'foldBalanceAsOf'.
--
-- Task 9 of the editable-transaction-metadata spec made balance-as-of consult
-- the Transaction aggregate's authoritative @at@ via a lookup parameter, so
-- that user edits of a transaction's business date propagate into period
-- balances. These tests exercise the pure helper directly, with a lookup
-- backed by a small 'Map' fixture; the leg event's own @at@ is set to a
-- distinct value to make it obvious which date the fold actually consulted.
module Application.ReadModels.BalanceAsOfJoinSpec (spec) where

import Application.ReadModels.Account (foldBalanceAsOf)
import qualified Data.Map.Strict as Map
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountCreated (..),
    AccountDebited (..),
  )
import Domain.Core.Types
  ( AccountType (..),
    Currency (..),
    Money,
    TransactionId,
    UserId,
    defaultCash,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..))
import RIO
import Test.Hspec
import Testkit.Helpers (mockTransactionId, mockUserId)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

ownerUser :: UserId
ownerUser = mockUserId (UUID.fromWords 0xc0ffee 0 0 0)

txT :: TransactionId
txT = mockTransactionId (UUID.fromWords 0x7 0 0 0)

usd :: Rational -> Money
usd = unsafeMoney USD

-- | Build a UTCTime at midnight for the given date.
t :: Integer -> Int -> Int -> UTCTime
t y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

march15, march31, april1, april30 :: UTCTime
march15 = t 2026 3 15
march31 = t 2026 3 31
april1 = t 2026 4 1
april30 = t 2026 4 30

-- -----------------------------------------------------------------------------
-- Event-stream fixtures
-- -----------------------------------------------------------------------------

createdEvent :: AccountingEvent
createdEvent =
  AccountCreatedEvent
    AccountCreated
      { name = "Checking",
        initialBalance = usd 1000,
        by = ownerUser,
        accountType = Regular defaultCash,
        overdraftLimit = Nothing
      }

-- | A debit of 200. The leg event no longer carries its own @at@; whether
-- it counts toward a given cutoff is decided entirely by the lookup the
-- test passes to 'foldBalanceAsOf'.
debitT :: AccountingEvent
debitT =
  AccountDebitedEvent
    AccountDebited
      { amount = usd 200,
        transactionId = txT
      }

events :: [AccountingEvent]
events = [createdEvent, debitT]

-- -----------------------------------------------------------------------------
-- Lookups
-- -----------------------------------------------------------------------------

lookupFrom :: Map.Map TransactionId UTCTime -> TransactionId -> Maybe UTCTime
lookupFrom m txId = Map.lookup txId m

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Application.ReadModels.Account / foldBalanceAsOf (TX join)" $ do
  it "uses the TX aggregate's @at@ when it matches the leg's stamped @at@" $ do
    -- TX still dated 2026-03-15; query at 2026-03-31 should include the debit.
    let lookupAt = lookupFrom (Map.fromList [(txT, march15)])
    foldBalanceAsOf march31 lookupAt events `shouldBe` Just (usd 800)

  it "excludes a leg whose TX @at@ has been moved past the cutoff" $ do
    -- TX moved to 2026-04-01; query at 2026-03-31 should NOT include the debit.
    let lookupAt = lookupFrom (Map.fromList [(txT, april1)])
    foldBalanceAsOf march31 lookupAt events `shouldBe` Just (usd 1000)

  it "includes a leg moved out of March once the cutoff catches up" $ do
    -- TX moved to 2026-04-01; query at 2026-04-30 should include the debit.
    let lookupAt = lookupFrom (Map.fromList [(txT, april1)])
    foldBalanceAsOf april30 lookupAt events `shouldBe` Just (usd 800)

  it "skips a leg whose TX is absent from the lookup" $ do
    -- Defensive: empty lookup returns Nothing, so the leg is skipped
    -- entirely and the balance reports the initial value.
    let lookupAt = lookupFrom Map.empty
    foldBalanceAsOf march31 lookupAt events `shouldBe` Just (usd 1000)
