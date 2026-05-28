{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionAmendmentSpec
-- Description : Service-layer tests for 'amendTransfer'.
--
-- Covers the orchestration paths in 'amendTransfer':
--
--  * Identity short-circuit (spec §4.3): no events, same state.
--  * Happy path (amount-only): @amendmentCount@ bump and posting-field
--    replacement; @transferType@ is preserved by construction.
--  * Pure-handler rejection surfaced via the service: same-account pair.
--  * Account-type preservation: cannot flip an Income's Regular target
--    to an External account; can change the Regular subtype freely
--    (e.g. Cash → Bank) because that doesn't change 'transferType'.
--  * Books-close gate against the TX's current 'at'.
--  * Source-account swap: balance shifts on both old and new sources.
module Application.Services.TransactionAmendmentSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.AccountService (createAccount)
import Application.Services.ConfigurationService (closeBooksThrough)
import Application.Services.TransactionService
  ( amendTransfer,
    initiateExpense,
    initiateIncome,
    initiateInternalTransfer,
  )
import qualified Data.Set as Set
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    AccountSubtype,
    AccountType (..),
    UserId,
    defaultBankAccount,
    unMoney,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Commands (AmendTransfer (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createRegularAccount,
    setupMetadataFixture,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)

-- -----------------------------------------------------------------------------
-- Local helpers
-- -----------------------------------------------------------------------------

balanceUsd :: AppEnv -> AccountId -> IO Rational
balanceUsd env aid = do
  m <- AccountRM.getAccount env.accountReadModel aid
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail "balanceUsd: account not found"

-- | Create a Regular account with a specific subtype, bypassing the
-- shared fixture (which defaults to Cash).
createRegularAccountWithSubtype ::
  AppEnv -> UserId -> Text -> AccountSubtype -> IO AccountId
createRegularAccountWithSubtype env uid name_ subtype = do
  res <-
    runAppM env
      $ createAccount
      $ CreateAccount
        { name = name_,
          initialBalance = unsafeMoney Core.USD 1000,
          createdBy = uid,
          accountType = Regular subtype,
          overdraftLimit = Nothing
        }
  case res of
    Right (aid, _) -> pure aid
    Left err -> fail $ "createRegularAccountWithSubtype failed: " <> show err

bankSubtype :: AccountSubtype
bankSubtype = defaultBankAccount

amendCmd ::
  AccountId ->
  AccountId ->
  Rational ->
  Rational ->
  UserId ->
  AmendTransfer
amendCmd newSrc newTgt newSrcAmt newTgtAmt uid =
  AmendTransfer
    { transactionId = error "amendCmd: tx id must be overwritten by caller",
      newSourceAccountId = newSrc,
      newTargetAccountId = newTgt,
      newSourceAmount = unsafeMoney Core.USD newSrcAmt,
      newTargetAmount = unsafeMoney Core.USD newTgtAmt,
      newExchangeRate = Nothing,
      amendedBy = uid
    }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService.amendTransfer" $ do
  describe "Identity short-circuit"
    $ it "returns the current TransactionData unchanged when payload matches"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-identity@test.com"
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 100)
            fx.incomeCategory
            Set.empty
            "Seed"
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cmd =
            (amendCmd original.sourceAccountId original.targetAccountId 100 100 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      case result of
        Right td -> do
          td.amendmentCount `shouldBe` original.amendmentCount
          td.sourceAmount `shouldBe` original.sourceAmount
        Left err -> expectationFailure $ "expected Right, got: " <> show err

  describe "Happy path — amount only, increasing"
    $ it "bumps amendmentCount and updates posting facts; preserves transferType"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-amount-up@test.com"
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 100)
            fx.incomeCategory
            Set.empty
            "Seed"
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cmd =
            (amendCmd original.sourceAccountId original.targetAccountId 150 150 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      case result of
        Right td -> do
          td.sourceAmount `shouldBe` unsafeMoney Core.USD 150
          td.targetAmount `shouldBe` unsafeMoney Core.USD 150
          td.amendmentCount `shouldBe` 1
          td.transferType `shouldBe` original.transferType
        Left err -> expectationFailure $ "expected Right, got: " <> show err

  describe "Pure-handler rejection"
    $ it "rejects same-account-pair payload on a Regular→Regular transfer"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-same@test.com"
      walletB <- createRegularAccount env fx.userId "WalletB"
      transfer <-
        runAppM env
          $ initiateInternalTransfer
            fx.userId
            fx.regularAccountId
            walletB
            (unsafeMoney Core.USD 50)
            Set.empty
            "Seed"
            Nothing
            Nothing
      (txId, _td) <- case transfer of
        Right r -> pure r
        Left err -> fail $ "initiateInternalTransfer failed: " <> show err

      -- Both legs on walletB: both Regular (passes accountType parity),
      -- but source == target (fails same-account-pair).
      let cmd =
            (amendCmd walletB walletB 50 50 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      result `shouldBe` Left CannotAmendToSameAccountPair

  describe "Account-type preservation"
    $ it "rejects flipping the Income's Regular target to an External account"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-account-type@test.com"
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 100)
            fx.incomeCategory
            Set.empty
            "Seed"
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      -- 'original.sourceAccountId' is the External counterpart of the
      -- seeded Regular wallet (auto-created by 'initiateIncome'). Swap
      -- source and target so the new target is External (== original
      -- source) and the new source is the original Regular target —
      -- this attempts to flip Income (External → Regular) into
      -- Regular → External, which 'validateAccountTypePreserved' must
      -- reject.
      let cmd =
            (amendCmd original.targetAccountId original.sourceAccountId 100 100 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      result `shouldBe` Left CannotAmendAcrossAccountType

  describe "Subtype change within the same accountType"
    $ it "accepts swapping a Regular Cash source to a Regular Bank source on an Expense"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-subtype@test.com"
      -- The seeded regularAccount is Cash; create a Bank-subtype Regular.
      bankWallet <-
        createRegularAccountWithSubtype env fx.userId "BankWallet" bankSubtype
      create <-
        runAppM env
          $ initiateExpense
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            fx.expenseCategory
            Set.empty
            "Coffee"
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateExpense failed: " <> show err

      -- Amend source from Cash wallet to Bank wallet. AccountType on
      -- both legs stays the same (Regular source, External target);
      -- subtype changes within Regular are allowed.
      let cmd =
            (amendCmd bankWallet original.targetAccountId 25 25 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      case result of
        Right td -> do
          td.sourceAccountId `shouldBe` bankWallet
          td.transferType `shouldBe` original.transferType
        Left err -> expectationFailure $ "expected Right, got: " <> show err

  describe "Books-close gate"
    $ it "rejects amendment of a TX whose 'at' is on or before the cutoff"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-books-closed@test.com"
      let originalAt = utc 2026 3 10
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 100)
            fx.incomeCategory
            Set.empty
            "Backdated seed"
            (Just originalAt)
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cutoff = utc 2026 3 31
      _ <- runAppM env (closeBooksThrough fx.userId cutoff)

      let cmd =
            (amendCmd original.sourceAccountId original.targetAccountId 200 200 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      result
        `shouldBe` Left
          CannotEditClosedPeriod
            { current = cutoff,
              attempted = originalAt
            }

  describe "Source-account swap (full saga path)"
    $ it "issues debit on new source and reverses on old source"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-source-swap@test.com"
      walletB <- createRegularAccount env fx.userId "WalletB"
      walletC <- createRegularAccount env fx.userId "WalletC"

      transfer <-
        runAppM env
          $ initiateInternalTransfer
            fx.userId
            fx.regularAccountId
            walletB
            (unsafeMoney Core.USD 50)
            Set.empty
            "A→B"
            Nothing
            Nothing
      (txId, _original) <- case transfer of
        Right r -> pure r
        Left err -> fail $ "initiateInternalTransfer failed: " <> show err

      walletA_BeforeAmend <- balanceUsd env fx.regularAccountId
      walletC_BeforeAmend <- balanceUsd env walletC

      let cmd =
            (amendCmd walletC walletB 50 50 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransfer fx.userId txId cmd)
      case result of
        Right td -> do
          td.sourceAccountId `shouldBe` walletC
          td.amendmentCount `shouldBe` 1
        Left err -> expectationFailure $ "expected Right, got: " <> show err

      walletA_After <- balanceUsd env fx.regularAccountId
      walletC_After <- balanceUsd env walletC
      walletA_After `shouldBe` (walletA_BeforeAmend + 50)
      walletC_After `shouldBe` (walletC_BeforeAmend - 50)
