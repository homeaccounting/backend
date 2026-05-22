{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.AccountPropertySpec
-- Description : QuickCheck properties for 'balanceAsOf'.
--
-- These invariants complement the per-case unit spec by exercising
-- 'balanceAsOf' against randomly generated event streams seeded into a
-- fresh in-memory event store.
module Application.ReadModels.AccountPropertySpec (spec) where

import Application.ReadModels.Account (balanceAsOf)
import qualified Data.Map.Strict as Map
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import qualified Data.UUID as UUID
import Domain.Account.Events
  ( AccountCreated (..),
    AccountCredited (..),
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
    unMoney,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..))
import Eventium (EventStoreReader (..), EventStoreWriter (..), ExpectedPosition (..))
import RIO
import Test.Hspec
import Test.QuickCheck
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

ownerUser :: UserId
ownerUser = mockUserId (UUID.fromWords 0xc0ffee 0 0 0)

baseDay :: UTCTime
baseDay = UTCTime (fromGregorian 2026 1 1) (secondsToDiffTime 0)

-- | A random UTC instant inside a fixed 366-day window starting 2026-01-01.
genBusinessDay :: Gen UTCTime
genBusinessDay = do
  dayOffset <- choose (0 :: Int, 365)
  let delta = fromIntegral (dayOffset * 86400) :: NominalDiffTime
  pure $ addUTCTime delta baseDay

-- | A USD amount strictly positive, bounded to keep the running balance
-- representable and the test fast.
genPositiveUsdAmount :: Gen Money
genPositiveUsdAmount = (\n -> unsafeMoney USD (fromIntegral (n :: Int))) <$> choose (1, 10000)

-- | A signed flow: 'True' = credit, 'False' = debit, paired with a positive
-- amount and a business date.
data Flow = Flow {credit :: Bool, amount :: Money, at :: UTCTime}
  deriving (Show)

genFlow :: Gen Flow
genFlow = Flow <$> arbitrary <*> genPositiveUsdAmount <*> genBusinessDay

-- -----------------------------------------------------------------------------
-- Event-stream construction
--
-- These builders are intentionally local: each one hard-codes shape
-- specific to this property test (a fixed @"Checking"@ Regular/Cash
-- account, paired credit/debit legs over a generated @Flow@). If a
-- second spec needs the same shape, lift them into a @Testkit@ module
-- at that point — generalising them speculatively would only add
-- parameters that no one currently sets.
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

txIdOf :: Word32 -> TransactionId
txIdOf w = mockTransactionId (UUID.fromWords w 0 0 0)

flowEvent :: Word32 -> Flow -> AccountingEvent
flowEvent txWord f
  | f.credit =
      AccountCreditedEvent
        AccountCredited
          { amount = f.amount,
            transactionId = txIdOf txWord
          }
  | otherwise =
      AccountDebitedEvent
        AccountDebited
          { amount = f.amount,
            transactionId = txIdOf txWord
          }

-- | Sum the flows whose business date is at or before @D@, signed by direction.
expectedDelta :: UTCTime -> [Flow] -> Rational
expectedDelta cutoff =
  sum
    . map (\f -> (if f.credit then id else negate) (unMoney f.amount))
    . filter (\f -> f.at <= cutoff)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

seedAndQuery ::
  AccountId ->
  [AccountingEvent] ->
  [(TransactionId, UTCTime)] ->
  UTCTime ->
  IO (Maybe Money)
seedAndQuery accountId events lookupEntries asOf = do
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

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Application.ReadModels.Account / balanceAsOf (property)" $ do
  it "balanceAsOf at a far-future cutoff equals initialBalance + sum(credits) - sum(debits)"
    $ property
    $ forAll genPositiveUsdAmount
    $ \initial ->
      forAll (resize 30 (listOf genFlow)) $ \flows -> ioProperty $ do
        let indexedFlows = zip [(1 :: Word32) ..] flows
            events =
              createdEvent initial
                : [flowEvent i f | (i, f) <- indexedFlows]
            lookupEntries = [(txIdOf i, f.at) | (i, f) <- indexedFlows]
            farFuture = addUTCTime (366 * 86400) baseDay
        result <- seedAndQuery acctA events lookupEntries farFuture
        let expected = unsafeMoney USD (unMoney initial + expectedDelta farFuture flows)
        pure $ result === Just expected

  it "balanceAsOf is monotonic non-decreasing across credit-only suffixes"
    $ property
    $ forAll genPositiveUsdAmount
    $ \initial ->
      forAll (resize 20 (listOf genFlow)) $ \prefix ->
        forAll (resize 20 (listOf genPositiveUsdAmount)) $ \creditAmounts -> ioProperty $ do
          let t1 = addUTCTime (180 * 86400) baseDay
              t2 = addUTCTime (270 * 86400) baseDay
              cappedPrefix = [(i, capDate t1 f) | (i, f) <- zip [(1 :: Word32) ..] prefix]
              prefixEvents = [flowEvent i f | (i, f) <- cappedPrefix]
              prefixLookup = [(txIdOf i, f.at) | (i, f) <- cappedPrefix]
              suffix =
                [ ( 1000 + i,
                    addUTCTime (fromIntegral (i * 3600) :: NominalDiffTime) t1,
                    amt
                  )
                | (i, amt) <- zip [(1 :: Word32) ..] creditAmounts
                ]
              -- Credit-only suffix dated strictly between t1 and t2.
              suffixEvents =
                [ AccountCreditedEvent
                    AccountCredited
                      { amount = amt,
                        transactionId = txIdOf w
                      }
                | (w, _, amt) <- suffix
                ]
              suffixLookup = [(txIdOf w, at_) | (w, at_, _) <- suffix]
              events = createdEvent initial : prefixEvents ++ suffixEvents
              lookupEntries = prefixLookup ++ suffixLookup
          before <- seedAndQuery acctA events lookupEntries t1
          after <- seedAndQuery acctA events lookupEntries t2
          pure $ case (before, after) of
            (Just b1, Just b2) -> unMoney b2 >= unMoney b1
            _ -> False
  where
    capDate :: UTCTime -> Flow -> Flow
    capDate cutoff f = if f.at > cutoff then f {at = cutoff} else f
