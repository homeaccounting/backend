{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.EventiumSpec
-- Description : accountingEventTag stamps the specific event type, not the generic wrapper name.
--
-- 'Infrastructure.Eventium.accountingEventTag' is what
-- 'metadataEnrichingEventStoreWriterWithTag' calls to compute the
-- @metadata.eventType@ stamped on every persisted 'AccountingEvent' (at the
-- 'applyAccountCommand' \/ 'applyTransactionCommand' \/ 'applyUserCommand' \/
-- 'applyConfigurationCommand' call sites, and in
-- 'Application.Services.ExchangeRatePublisher'). Before this, the
-- 'Typeable'-derived default tagged every event with the wrapper sum type's
-- own name ('AccountingEvent'), which is useless for filtering/alerting on a
-- specific event type.
module Infrastructure.EventiumSpec (spec) where

import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransactionContactSet (..))
import Infrastructure.Eventium (accountingEventTag)
import RIO
import Test.Hspec
import Testkit.Helpers (mockTransactionIdN)

-- | A well-formed 'AccountingEvent' wrapping a 'TransactionContactSet'.
contactSetEvent :: AccountingEvent
contactSetEvent =
  TransactionContactSetEvent
    TransactionContactSet
      { transactionId = mockTransactionIdN 1,
        contactId = Nothing
      }

spec :: Spec
spec = describe "accountingEventTag" $ do
  it "tags an event with its specific constructor name" $ do
    accountingEventTag contactSetEvent `shouldBe` "TransactionContactSet"

  it "never collapses to the generic AccountingEvent wrapper name" $ do
    accountingEventTag contactSetEvent `shouldNotBe` "AccountingEvent"
