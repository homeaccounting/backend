{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionTransferFeeSpec
-- Description : Service-layer tests for transfers that carry fee allocations.
--
-- Covers 'initiateTransfer' (fee-aware create), 'amendTransaction' (add,
-- change and remove a fee) and 'setTransactionAllocations' (re-categorise
-- a fee) against the in-memory event store with the transfer saga wired.
module Application.Services.TransactionTransferFeeSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.TransactionService
  ( amendTransaction,
    initiateTransfer,
    setTransactionAllocations,
  )
import qualified Data.Set as Set
import qualified Data.UUID as UUID
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
import Domain.Transaction.Commands (InitiateTransactionAmendment (..))
import Domain.Transaction.Types
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createAccount,
    createDefaultAccount,
    expenseAllocs,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)

balanceOf :: AppEnv -> AccountId -> IO Rational
balanceOf env aid = do
  m <- runDbIn env (AccountRM.getAccount aid)
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail "balanceOf: account not found"

usd, uah :: Rational -> Money
usd = unsafeMoney USD
uah = unsafeMoney UAH

-- | Two USD wallets for one user.
setupWallets :: Text -> IO (AppEnv, MetadataFixture, AccountId)
setupWallets email = do
  env <- createTestAppEnvWithProcessManager
  fx <- setupMetadataFixture env email
  walletB <- createDefaultAccount env fx.userId "WalletB"
  pure (env, fx, walletB)

transferWith ::
  AppEnv ->
  MetadataFixture ->
  AccountId ->
  Money ->
  Maybe Allocations ->
  Maybe Rational ->
  IO (Either DomainError (TransactionId, TransactionData))
transferWith env fx tgt amount fees rate =
  runAppM env
    $ initiateTransfer fx.userId fx.regularAccountId tgt amount fees Set.empty "Fee transfer" rate Nothing Nothing

amendTo :: TransactionId -> TransactionData -> Rational -> Maybe Allocations -> UserId -> InitiateTransactionAmendment
amendTo txId td srcAmt fees uid =
  InitiateTransactionAmendment
    { transactionId = txId,
      newSourceAccountId = td.sourceAccountId,
      newTargetAccountId = td.targetAccountId,
      newSourceAmount = usd srcAmt,
      newTargetAmount = usd srcAmt,
      newExchangeRate = Nothing,
      newAllocations = fees,
      newTransactionType = Transfer Nothing,
      contactId = Nothing,
      allowOverdraft = False,
      by = uid
    }

spec :: Spec
spec = describe "TransactionService transfer fees" $ do
  describe "initiateTransfer" $ do
    it "debits the source by the amount and credits amount minus the fee" $ do
      (env, fx, walletB) <- setupWallets "fee-create@test.com"
      let fees = expenseAllocs fx (usd (1 / 4))
      (_, td) <- transferWith env fx walletB (usd (201 / 4)) (Just fees) Nothing >>= unwrapTd
      td.sourceAmount `shouldBe` usd (201 / 4)
      td.targetAmount `shouldBe` usd 50
      td.transactionType `shouldBe` Transfer (Just fees)
      balanceOf env fx.regularAccountId `shouldReturn` (5000 - 201 / 4)
      balanceOf env walletB `shouldReturn` 5050

    it "excludes fees from the converted target amount (cross-currency)" $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "fee-cross@test.com"
      src <- createAccount env fx.userId "Hryvnia" defaultCash UAH 5000
      tgt <- createAccount env fx.userId "Dollars" defaultCash USD 5000
      let fees = expenseAllocs fx (uah 10)
      res <-
        runAppM env
          $ initiateTransfer fx.userId src tgt (uah 1010) (Just fees) Set.empty "Cross fee" (Just (1 / 40)) Nothing Nothing
      (_, td) <- unwrapTd res
      td.sourceAmount `shouldBe` uah 1010
      td.targetAmount `shouldBe` usd 25
      td.transactionType `shouldBe` Transfer (Just fees)
      balanceOf env src `shouldReturn` 3990
      balanceOf env tgt `shouldReturn` 5025

    it "rejects a fee category missing from the expense dictionary" $ do
      (env, fx, walletB) <- setupWallets "fee-unknown@test.com"
      let unknown = unsafeDictionaryEntryId (UUID.fromWords 0xDEADBEEF 0xDEADBEEF 0xDEADBEEF 0xDEADBEEF)
          bad = mkExpenseAllocations (Allocation unknown (usd 1) Nothing :| [])
      res <- transferWith env fx walletB (usd 100) (Just bad) Nothing
      case res of
        Left (CategoryNotFound _) -> pure ()
        other -> expectationFailure $ "expected CategoryNotFound, got: " <> show other

  describe "amendTransaction" $ do
    it "adds a fee to a plain transfer" $ do
      (env, fx, walletB) <- setupWallets "fee-amend-add@test.com"
      (txId, td) <- transferWith env fx walletB (usd 100) Nothing Nothing >>= unwrapTd
      let fees = expenseAllocs fx (usd 1)
      res <- runAppM env (amendTransaction fx.userId txId (amendTo txId td 100 (Just fees) fx.userId))
      td' <- either (fail . show) pure res
      td'.transactionType `shouldBe` Transfer (Just fees)
      td'.sourceAmount `shouldBe` usd 100
      td'.targetAmount `shouldBe` usd 99
      balanceOf env fx.regularAccountId `shouldReturn` 4900
      balanceOf env walletB `shouldReturn` 5099

    it "recomputes the target when the fee total changes" $ do
      (env, fx, walletB) <- setupWallets "fee-amend-change@test.com"
      (txId, td) <-
        transferWith env fx walletB (usd 100) (Just (expenseAllocs fx (usd 1))) Nothing >>= unwrapTd
      let fees = expenseAllocs fx (usd 3)
      res <- runAppM env (amendTransaction fx.userId txId (amendTo txId td 100 (Just fees) fx.userId))
      td' <- either (fail . show) pure res
      td'.transactionType `shouldBe` Transfer (Just fees)
      td'.targetAmount `shouldBe` usd 97
      balanceOf env walletB `shouldReturn` 5097

    it "removes the fee when allocations are cleared" $ do
      (env, fx, walletB) <- setupWallets "fee-amend-remove@test.com"
      (txId, td) <-
        transferWith env fx walletB (usd 100) (Just (expenseAllocs fx (usd 1))) Nothing >>= unwrapTd
      res <- runAppM env (amendTransaction fx.userId txId (amendTo txId td 100 Nothing fx.userId))
      td' <- either (fail . show) pure res
      td'.transactionType `shouldBe` Transfer Nothing
      td'.targetAmount `shouldBe` usd 100
      balanceOf env walletB `shouldReturn` 5100

  describe "setTransactionAllocations" $ do
    it "re-categorises a transfer fee without changing its total" $ do
      (env, fx, walletB) <- setupWallets "fee-recat@test.com"
      (txId, _) <-
        transferWith env fx walletB (usd 100) (Just (expenseAllocs fx (usd 1))) Nothing >>= unwrapTd
      let split =
            mkExpenseAllocations
              ( Allocation fx.expenseCategory (usd (1 / 4)) Nothing
                  :| [Allocation fx.expenseCategory (usd (3 / 4)) (Just "bank")]
              )
      res <- runAppM env (setTransactionAllocations fx.userId txId split)
      td' <- either (fail . show) pure res
      td'.transactionType `shouldBe` Transfer (Just split)
      td'.targetAmount `shouldBe` usd 99

    it "rejects allocations on a transfer without fees" $ do
      (env, fx, walletB) <- setupWallets "fee-recat-none@test.com"
      (txId, _) <- transferWith env fx walletB (usd 100) Nothing Nothing >>= unwrapTd
      res <- runAppM env (setTransactionAllocations fx.userId txId (expenseAllocs fx (usd 1)))
      res `shouldBe` Left CannotSetAllocationsOnUncategorisedTransaction
  where
    unwrapTd = either (fail . show) pure
