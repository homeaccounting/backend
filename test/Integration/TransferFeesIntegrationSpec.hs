{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransferFeesIntegrationSpec
-- Description : End-to-end lifecycle of a transfer carrying fees.
--
-- One scenario: create with a fee, re-categorise it, change the fee total,
-- remove the fee, then cancel — checking balances, the read model and the
-- audit history after every step.
module Integration.TransferFeesIntegrationSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.ConfigurationService (addDictionaryEntry, expenseCategoryDictKind)
import Application.Services.TransactionHistoryService
  ( TransactionHistory (..),
    TransactionHistoryEntry (..),
    getTransactionHistory,
  )
import Application.Services.TransactionService
  ( amendTransaction,
    cancelTransaction,
    initiateTransfer,
    setTransactionAllocations,
  )
import qualified Data.Set as Set
import Domain.Configuration.Dictionary (EntryRole (ItemRole))
import Domain.Core.Errors (DomainError)
import Domain.Core.Types
import Domain.Transaction.Commands (InitiateTransactionAmendment (..))
import qualified Domain.Transaction.Events as Ev
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createDefaultAccount,
    expenseAllocs,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

usd :: Rational -> Money
usd = unsafeMoney USD

balanceOf :: AppEnv -> AccountId -> IO Rational
balanceOf env aid = do
  m <- runDbIn env (AccountRM.getAccount aid)
  maybe (fail "balanceOf: account not found") (pure . unMoney . (.balance)) m

orFail :: Either DomainError a -> IO a
orFail = either (fail . show) pure

amendment :: TransactionId -> TransactionData -> Rational -> Maybe Allocations -> UserId -> InitiateTransactionAmendment
amendment txId td src fees uid =
  InitiateTransactionAmendment
    { transactionId = txId,
      newSourceAccountId = td.sourceAccountId,
      newTargetAccountId = td.targetAccountId,
      newSourceAmount = usd src,
      newTargetAmount = usd src,
      newExchangeRate = Nothing,
      newAllocations = fees,
      newTransactionType = Transfer Nothing,
      contactId = Nothing,
      allowOverdraft = False,
      by = uid
    }

spec :: Spec
spec = describe "TransferFees" $
  it "creates, re-categorises, amends, strips the fee and cancels" $ do
    env <- createTestAppEnvWithProcessManager
    fx <- setupMetadataFixture env "transfer-fees-e2e@test.com"
    walletB <- createDefaultAccount env fx.userId "WalletB"
    bank <-
      runAppM env (addDictionaryEntry fx.userId expenseCategoryDictKind (unsafeEntryName "Bank fees") ItemRole Nothing)
        >>= orFail
    let src = fx.regularAccountId
        history txId = do
          h <- runAppM env (getTransactionHistory fx.userId txId) >>= orFail
          pure (maybe [] (.entries) h)
        balances = (,) <$> balanceOf env src <*> balanceOf env walletB
        fee025 = expenseAllocs fx (usd (1 / 4))

    -- 1. create with a 0.25 fee
    (txId, td) <-
      runAppM env (initiateTransfer fx.userId src walletB (usd (201 / 4)) (Just fee025) Set.empty "Fee e2e" Nothing Nothing Nothing)
        >>= orFail
    td.targetAmount `shouldBe` usd 50
    balances `shouldReturn` (5000 - 201 / 4, 5050)
    h1 <- history txId
    case [e | HistoryPostingInitiated e <- h1] of
      [e] -> e.transactionType `shouldBe` Transfer (Just fee025)
      other -> expectationFailure $ "expected one posting entry, got " <> show (length other)

    -- 2. re-categorise the fee (same total)
    let recat = mkExpenseAllocations (Allocation bank (usd (1 / 4)) Nothing :| [])
    td2 <- runAppM env (setTransactionAllocations fx.userId txId recat) >>= orFail
    td2.transactionType `shouldBe` Transfer (Just recat)
    balances `shouldReturn` (5000 - 201 / 4, 5050)
    h2 <- history txId
    [e.newAllocations | HistoryAllocationsChanged e <- h2] `shouldBe` [recat]

    -- 3. amend: fee 0.50 -> target 49.75
    let fee050 = expenseAllocs fx (usd (1 / 2))
    td3 <- runAppM env (amendTransaction fx.userId txId (amendment txId td2 (201 / 4) (Just fee050) fx.userId)) >>= orFail
    td3.transactionType `shouldBe` Transfer (Just fee050)
    td3.targetAmount `shouldBe` usd (199 / 4)
    balances `shouldReturn` (5000 - 201 / 4, 5000 + 199 / 4)
    h3 <- history txId
    [e.newTransactionType | HistoryAmendmentInitiated e <- h3] `shouldBe` [Transfer (Just fee050)]

    -- 4. amend removing the fee -> plain transfer, target = source
    td4 <- runAppM env (amendTransaction fx.userId txId (amendment txId td3 (201 / 4) Nothing fx.userId)) >>= orFail
    td4.transactionType `shouldBe` Transfer Nothing
    td4.targetAmount `shouldBe` usd (201 / 4)
    balances `shouldReturn` (5000 - 201 / 4, 5000 + 201 / 4)
    h4 <- history txId
    [e.newTransactionType | HistoryAmendmentInitiated e <- h4]
      `shouldBe` [Transfer (Just fee050), Transfer Nothing]

    -- 5. cancel restores both balances
    _ <- runAppM env (cancelTransaction fx.userId txId) >>= orFail
    balances `shouldReturn` (5000, 5000)
