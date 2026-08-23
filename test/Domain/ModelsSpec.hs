{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.ModelsSpec (spec) where

import qualified Data.UUID as UUID
import Domain.Account (AccountDebited (..))
import Domain.Configuration.Dictionary (DictionaryKind (IncomeKind))
import Domain.Configuration.Events (DictionaryEntryRenamed (..))
import Domain.Core.Types
  ( Currency (UAH),
    unsafeDictionaryEntryId,
    unsafeEntryName,
    unsafeMoney,
  )
import Domain.Models (AccountingEvent (..), isTransactionSagaEvent)
import RIO
import Test.Hspec
import Testkit.Helpers (mockTransactionIdN)

spec :: Spec
spec = describe "isTransactionSagaEvent" $ do
  it "accepts Account events (the transaction sagas react to them)" $ do
    let event =
          AccountDebitedEvent
            AccountDebited
              { amount = unsafeMoney UAH 100,
                transactionId = mockTransactionIdN 1
              }
    isTransactionSagaEvent event `shouldBe` True

  it "rejects Configuration events (no transaction saga reacts to them)" $ do
    let event =
          DictionaryEntryRenamedEvent
            DictionaryEntryRenamed
              { dictionaryKind = IncomeKind,
                entryId = unsafeDictionaryEntryId (UUID.fromWords 1 0 0 0),
                newName = unsafeEntryName "Salary"
              }
    isTransactionSagaEvent event `shouldBe` False
