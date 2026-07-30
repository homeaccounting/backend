{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.TransactionAmendmentSpec
-- Description : Service-layer tests for 'amendTransaction'.
--
-- Covers the orchestration paths in 'amendTransaction':
--
--  * Identity short-circuit (spec §4.3): no events, same state.
--  * Happy path (amount-only): @amendmentCount@ bump and posting-field
--    replacement; @transactionType@ is preserved by construction.
--  * Pure-handler rejection surfaced via the service: same-account pair.
--  * Account-type preservation: cannot flip an Income's Regular target
--    to an External account; can change the Regular subtype freely
--    (e.g. Cash → Bank) because that doesn't change 'transactionType'.
--  * Books-close gate against the TX's current 'at'.
--  * Source-account swap: balance shifts on both old and new sources.
module Application.Services.TransactionAmendmentSpec (spec) where

import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.ConfigurationService (closeBooksThrough)
import Application.Services.TransactionService
  ( amendTransaction,
    initiateExpense,
    initiateIncome,
    initiateTransfer,
  )
import qualified Data.Set as Set
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types
  ( AccountId,
    AccountSubtype,
    TransactionType (..),
    UserId,
    defaultBankAccount,
    defaultCash,
    moneyCurrency,
    unMoney,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.Transaction.Commands (InitiateTransactionAmendment (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures
  ( MetadataFixture (..),
    createAccount,
    createDefaultAccount,
    expenseAllocs,
    incomeAllocs,
    seedExchangeRates,
    setupMetadataFixture,
    userExternalAccountId,
  )
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager, runDbIn)
import Testkit.Time (utc)

-- -----------------------------------------------------------------------------
-- Local helpers
-- -----------------------------------------------------------------------------

balanceUsd :: AppEnv -> AccountId -> IO Rational
balanceUsd env aid = do
  m <- runDbIn env (AccountRM.getAccount aid)
  case m of
    Just acc -> pure (unMoney acc.balance)
    Nothing -> fail "balanceUsd: account not found"

bankSubtype :: AccountSubtype
bankSubtype = defaultBankAccount

amendCmd ::
  AccountId ->
  AccountId ->
  Rational ->
  Rational ->
  UserId ->
  InitiateTransactionAmendment
amendCmd newSrc newTgt newSrcAmt newTgtAmt uid =
  InitiateTransactionAmendment
    { transactionId = error "amendCmd: tx id must be overwritten by caller",
      newSourceAccountId = newSrc,
      newTargetAccountId = newTgt,
      newSourceAmount = unsafeMoney Core.USD newSrcAmt,
      newTargetAmount = unsafeMoney Core.USD newTgtAmt,
      newExchangeRate = Nothing,
      newAllocations = Nothing,
      newTransactionType = Transfer,
      contactId = Nothing,
      allowOverdraft = False,
      by = uid
    }

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "TransactionService.amendTransaction" $ do
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
            (incomeAllocs fx (unsafeMoney Core.USD 100))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cmd =
            (amendCmd original.sourceAccountId original.targetAccountId 100 100 fx.userId)
              { transactionId = txId,
                newAllocations = Just (incomeAllocs fx (unsafeMoney Core.USD 100))
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      case result of
        Right td -> do
          td.amendmentCount `shouldBe` original.amendmentCount
          td.sourceAmount `shouldBe` original.sourceAmount
        Left err -> expectationFailure $ "expected Right, got: " <> show err

  describe "Happy path — amount only, increasing"
    $ it "bumps amendmentCount, updates posting facts, and rescales Income allocations"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-amount-up@test.com"
      create <-
        runAppM env
          $ initiateIncome
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 100)
            (incomeAllocs fx (unsafeMoney Core.USD 100))
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cmd =
            (amendCmd original.sourceAccountId original.targetAccountId 150 150 fx.userId)
              { transactionId = txId,
                newAllocations = Just (incomeAllocs fx (unsafeMoney Core.USD 150))
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      case result of
        Right td -> do
          td.sourceAmount `shouldBe` unsafeMoney Core.USD 150
          td.targetAmount `shouldBe` unsafeMoney Core.USD 150
          td.amendmentCount `shouldBe` 1
          -- The categorised side (target for Income) went from 100 -> 150,
          -- so the explicit allocation now totals 150 USD.
          td.transactionType `shouldBe` Income (incomeAllocs fx (unsafeMoney Core.USD 150))
        Left err -> expectationFailure $ "expected Right, got: " <> show err

  describe "Pure-handler rejection"
    $ it "rejects same-account-pair payload on a Regular→Regular transfer"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-same@test.com"
      walletB <- createDefaultAccount env fx.userId "WalletB"
      transfer <-
        runAppM env
          $ initiateTransfer
            fx.userId
            fx.regularAccountId
            walletB
            (unsafeMoney Core.USD 50)
            Set.empty
            "Seed"
            Nothing
            Nothing
            Nothing
      (txId, _td) <- case transfer of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      -- Both legs on walletB: both Regular (passes accountType parity),
      -- but source == target (fails same-account-pair).
      let cmd =
            (amendCmd walletB walletB 50 50 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      result `shouldBe` Left CannotAmendToSameAccountPair

  describe "Subtype change within the same accountType"
    $ it "accepts swapping a Regular Cash source to a Regular Bank source on an Expense"
    $ do
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-subtype@test.com"
      -- The seeded regularAccount is Cash; create a Bank-subtype Regular.
      bankWallet <-
        createAccount env fx.userId "BankWallet" bankSubtype Core.USD 1000
      create <-
        runAppM env
          $ initiateExpense
            fx.userId
            fx.regularAccountId
            (unsafeMoney Core.USD 25)
            (expenseAllocs fx (unsafeMoney Core.USD 25))
            Set.empty
            "Coffee"
            Nothing
            Nothing
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateExpense failed: " <> show err

      -- Amend source from Cash wallet to Bank wallet. AccountType on
      -- both legs stays the same (Regular source, External target);
      -- subtype changes within Regular are allowed.
      let cmd =
            (amendCmd bankWallet original.targetAccountId 25 25 fx.userId)
              { transactionId = txId,
                newAllocations = Just (expenseAllocs fx (unsafeMoney Core.USD 25))
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      case result of
        Right td -> do
          td.sourceAccountId `shouldBe` bankWallet
          td.transactionType `shouldBe` original.transactionType
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
            (incomeAllocs fx (unsafeMoney Core.USD 100))
            Set.empty
            "Backdated seed"
            (Just originalAt)
            Nothing
            Nothing
      (txId, original) <- case create of
        Right r -> pure r
        Left err -> fail $ "initiateIncome failed: " <> show err

      let cutoff = utc 2026 3 31
      _ <- runAppM env (closeBooksThrough fx.userId cutoff)

      let cmd =
            (amendCmd original.sourceAccountId original.targetAccountId 200 200 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
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
      walletB <- createDefaultAccount env fx.userId "WalletB"
      walletC <- createDefaultAccount env fx.userId "WalletC"

      transfer <-
        runAppM env
          $ initiateTransfer
            fx.userId
            fx.regularAccountId
            walletB
            (unsafeMoney Core.USD 50)
            Set.empty
            "A→B"
            Nothing
            Nothing
            Nothing
      (txId, _original) <- case transfer of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      walletA_BeforeAmend <- balanceUsd env fx.regularAccountId
      walletC_BeforeAmend <- balanceUsd env walletC

      let cmd =
            (amendCmd walletC walletB 50 50 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      case result of
        Right td -> do
          td.sourceAccountId `shouldBe` walletC
          td.amendmentCount `shouldBe` 1
        Left err -> expectationFailure $ "expected Right, got: " <> show err

      walletA_After <- balanceUsd env fx.regularAccountId
      walletC_After <- balanceUsd env walletC
      walletA_After `shouldBe` (walletA_BeforeAmend + 50)
      walletC_After `shouldBe` (walletC_BeforeAmend - 50)

  describe "Cross-currency cross-kind amendment"
    $ it "resolves the External leg into the External account's currency (regression: convert to Income in a non-base account)"
    $ do
      env <- createTestAppEnvWithProcessManager
      -- Base currency is USD, so the user's External account is USD. Seed both
      -- rate directions so the create (UAH->USD) and the amendment (USD->UAH)
      -- can each resolve their cross-currency leg.
      seedExchangeRates env [(Core.USD, Core.UAH, 40), (Core.UAH, Core.USD, 1 / 40)]
      fx <- setupMetadataFixture env "amend-fx@test.com"
      uahAcc <- createAccount env fx.userId "Hryvnia" defaultCash Core.UAH 1000
      -- Seed a ₴200 expense in the UAH account; its External leg is resolved to USD.
      create <-
        runAppM env
          $ initiateExpense
            fx.userId
            uahAcc
            (unsafeMoney Core.UAH 200)
            (expenseAllocs fx (unsafeMoney Core.UAH 200))
            Set.empty
            "Groceries"
            Nothing
            Nothing
            Nothing
      txId <- case create of
        Right (tid, _) -> pure tid
        Left err -> fail $ "initiateExpense failed: " <> show err
      ext <- userExternalAccountId env fx.userId
      -- Convert Expense -> Income exactly as the web client builds the payload:
      -- both legs in the regular (UAH) currency, no rate, income allocations.
      -- The service must re-resolve the External (USD) leg via the ECB rate;
      -- before the fix this failed with CurrencyMismatch (surfaced as
      -- InsufficientFundsForAmendment).
      let cmd =
            (amendCmd ext uahAcc 200 200 fx.userId)
              { transactionId = txId,
                newSourceAmount = unsafeMoney Core.UAH 200,
                newTargetAmount = unsafeMoney Core.UAH 200,
                newAllocations = Just (incomeAllocs fx (unsafeMoney Core.UAH 200))
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      case result of
        Left err -> expectationFailure $ "amend should succeed, got: " <> show err
        Right td -> do
          td.sourceAccountId `shouldBe` ext
          td.targetAccountId `shouldBe` uahAcc
          -- External (source) leg now carries USD; the Regular (target) leg keeps
          -- UAH; a cross-currency rate is recorded.
          moneyCurrency td.sourceAmount `shouldBe` Core.USD
          moneyCurrency td.targetAmount `shouldBe` Core.UAH
          td.exchangeRate `shouldSatisfy` isJust

  describe "Overdraft guard (ordinary, user-initiated amendment)"
    $ it "rejects a source-account swap whose debit exceeds the new source's balance"
    $ do
      -- Regression guard: 'allowOverdraft' on 'InitiateTransactionAmendment'
      -- defaults to False for every user-initiated amend (only the merge
      -- saga sets it True). Confirms the balance guard was NOT flipped
      -- globally when the saga started honouring the flag.
      env <- createTestAppEnvWithProcessManager
      fx <- setupMetadataFixture env "amend-overdraft-guard@test.com"
      walletB <- createDefaultAccount env fx.userId "WalletB"
      lowAcc <- createAccount env fx.userId "Low" defaultCash Core.USD 10
      transfer <-
        runAppM env
          $ initiateTransfer
            fx.userId
            fx.regularAccountId
            walletB
            (unsafeMoney Core.USD 50)
            Set.empty
            "A→B"
            Nothing
            Nothing
            Nothing
      (txId, _original) <- case transfer of
        Right r -> pure r
        Left err -> fail $ "initiateTransfer failed: " <> show err

      -- Swap the source to the 10-balance account while keeping the amount at
      -- 50: the debit exceeds the new source's balance and allowOverdraft is
      -- False, so the guard must still reject it.
      let cmd =
            (amendCmd lowAcc walletB 50 50 fx.userId)
              { transactionId = txId
              }
      result <- runAppM env (amendTransaction fx.userId txId cmd)
      case result of
        Left (InsufficientFundsForAmendment _) -> pure ()
        other -> expectationFailure $ "expected InsufficientFundsForAmendment, got: " <> show other
