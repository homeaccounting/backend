{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.Fixtures
-- Description : Shared service-layer fixtures (user, account, dictionary).
--
-- Builders that go through the @Application.Services.*@ entry points to
-- seed test state in an in-memory 'AppEnv'. Previously each integration
-- spec carried its own copy; consolidating them here means a single
-- place to update when the service layer's signatures change.
--
-- All helpers fail the test (via 'fail') if the underlying service call
-- returns 'Left'. They are intentionally not 'AppM'-flavoured: callers
-- already hold an 'AppEnv' and want a plain 'IO' setup helper.
module Testkit.Fixtures
  ( registerUser,
    createAccount,
    createDefaultAccount,
    registerWithAccount,
    creditAccount,
    firstDictionaryEntry,
    seedDefaultAndRegister,
    seedExchangeRates,
    seedRegisteredUser,
    userExternalAccountId,
    MetadataFixture (..),
    setupMetadataFixture,
    incomeAllocs,
    expenseAllocs,
    postExpense,
    postIncome,
    unwrapTx,
    seedContact,
    statusOf,
    allocAmounts,
  )
where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.ExchangeRate (applyExchangeRateEvent)
import Application.ReadModels.Transaction (TransactionData (..))
import Application.ReadModels.User (UserData (..), applyUserEvent, getUser)
import qualified Application.Services.AccountService as AccountService
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( addDictionaryEntry,
    contactsDictKind,
    expenseCategoryDictKind,
    incomeCategoryDictKind,
    seedDefaultConfiguration,
  )
import Application.Services.TransactionService
  ( getTransaction,
    initiateExpense,
    initiateIncome,
  )
import qualified Data.Map.Strict as Map
import Data.Time (getCurrentTime, utctDay)
import qualified Data.UUID as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreateAccount (..), CreditAccount (..))
import Domain.Configuration.Dictionary (DictionaryKind, EntryRole (ItemRole))
import Domain.Core.Errors (DomainError)
import Domain.Core.Types
  ( AccountId,
    AccountSubtype,
    AccountType (..),
    Allocation (..),
    Allocations,
    ContactId,
    DictionaryEntryId,
    Money,
    TransactionId,
    UserId,
    allAllocations,
    allocationsOf,
    defaultBankAccount,
    defaultCash,
    mkExpenseAllocations,
    mkIncomeAllocations,
    unAccountId,
    unMoney,
    unTransactionId,
    unUserId,
    unsafeEntryName,
    unsafeMoney,
    unsafeTransactionId,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Projection (TransactionStatus)
import Domain.User.Events (UserRegistered (..))
import Eventium (GlobalStreamEvent, StreamEvent (..), emptyMetadata)
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Config (AppConfig (..), ExchangeRateConfig (..))
import Infrastructure.Eventium (applyAccountCommand)
import RIO
import Testkit.Helpers (globalEvent, mockExchangeRate, mockPasswordHash)
import Testkit.InMemoryEventStore (runDbIn)

-- | Seed a registered user directly into the persistent User read model at a
-- fixed 'UserId' and external-account id, by applying a synthesized
-- 'UserRegistered' through the read model's own apply. For tests that need a
-- specific id (so they bypass 'AuthService.register', which mints random ids).
seedRegisteredUser :: AppEnv -> UserId -> AccountId -> Text -> IO ()
seedRegisteredUser env uid extAcc email =
  runDbIn env
    $ applyUserEvent
    $ globalEvent
      (unUserId uid)
      0
      ( UserRegisteredEvent
          UserRegistered
            { email = email,
              passwordHash = mockPasswordHash "seed",
              externalAccountId = extAcc
            }
      )
      0

-- | Register a user via 'AuthService.register' and return the resulting 'UserId'.
--
-- Uses a fixed test password ("password123"); specs that need a specific
-- password should call 'register' directly.
registerUser :: AppEnv -> Text -> IO UserId
registerUser env email = do
  res <- runAppM env $ register email "password123"
  case res of
    Left err -> fail $ "registerUser " <> show email <> " failed: " <> show err
    Right auth -> pure auth.userId

-- | Create a 'Regular' account with the given subtype, currency, and starting
-- balance. The single account-creation primitive; the wrappers below are thin
-- specialisations. (External accounts are auto-created per user — resolve one
-- via 'userExternalAccountId' rather than creating it here.)
createAccount ::
  AppEnv -> UserId -> Text -> AccountSubtype -> Core.Currency -> Rational -> IO AccountId
createAccount env uid accName subtype currency balance = do
  res <-
    runAppM env
      $ AccountService.createAccount
      $ CreateAccount
        { name = accName,
          initialBalance = unsafeMoney currency balance,
          createdBy = uid,
          accountType = Regular subtype,
          overdraftLimit = Nothing
        }
  case res of
    Left err -> fail $ "createAccount " <> show accName <> " failed: " <> show err
    Right (aid, _) -> pure aid

-- | A 'Regular Cash' account with a 5000 USD starting balance — the common
-- "an account to attach a transaction to" case.
createDefaultAccount :: AppEnv -> UserId -> Text -> IO AccountId
createDefaultAccount env uid accName = createAccount env uid accName defaultCash Core.USD 5000

-- | Register a user and create a USD 'Regular' bank account they own, returning
-- both ids — the common "a user with one account" starting point.
registerWithAccount :: AppEnv -> Text -> Text -> IO (UserId, AccountId)
registerWithAccount env email accName = do
  uid <- registerUser env email
  acct <- createAccount env uid accName defaultBankAccount Core.USD 100
  pure (uid, acct)

-- | Append a single 'AccountCredited' event directly (bypassing the saga) so the
-- stream grows by exactly one event. @seed@ yields a distinct synthetic
-- transaction id, letting callers append several independent credits.
creditAccount :: AppEnv -> AccountId -> Word32 -> Money -> IO ()
creditAccount env accountId seed amount =
  void
    $ applyAccountCommand
      env.eventStoreWriter
      env.eventStoreReader
      id
      (unAccountId accountId)
      ( CreditAccountAccountCommand
          CreditAccount
            { amount = amount,
              transactionId = unsafeTransactionId (UUID.fromWords seed 0 0 7)
            }
      )

-- | Publish a set of @(source, target, rate)@ exchange rates into the env's
-- exchange-rate read model, dated today, exactly as the provider feed would.
-- Lets cross-currency flows (create and amendment) resolve their non-base leg.
seedExchangeRates :: AppEnv -> [(Core.Currency, Core.Currency, Rational)] -> IO ()
seedExchangeRates env rates = do
  today <- utctDay <$> getCurrentTime
  let rateMap = Map.fromList [((s, t), mockExchangeRate s t r) | (s, t, r) <- rates]
      payload =
        ExchangeRatesPublishedEvent
          ExchangeRatesPublished
            { provider = env.config.exchangeRate.provider,
              rates = rateMap,
              at = today
            }
      versioned = StreamEvent UUID.nil 0 (emptyMetadata mempty) payload
      global :: GlobalStreamEvent AccountingEvent
      global = StreamEvent () 0 (emptyMetadata mempty) versioned
  runDbIn env (applyExchangeRateEvent global)

-- | Resolve the user's auto-created External account id. Fails the test
-- if the user is missing from the read model.
userExternalAccountId :: AppEnv -> UserId -> IO AccountId
userExternalAccountId env uid = do
  mUser <- runDbIn env (getUser uid)
  case mUser of
    Nothing -> fail $ "userExternalAccountId: user not found: " <> show uid
    Just ud -> pure ud.externalAccountId

-- | Return the first assignable (item) 'DictionaryEntryId' from the named
-- dictionary on the given user's configuration.
--
-- "First" is the first item in 'dictionaryItems' pre-order — callers should
-- only rely on stability within a single test, not on a specific ordering
-- across runs.
firstDictionaryEntry :: AppEnv -> UserId -> DictionaryKind -> IO DictionaryEntryId
firstDictionaryEntry env uid dictId = do
  mUser <- runDbIn env (getUser uid)
  case mUser of
    Nothing -> fail $ "firstDictionaryEntry: user not found: " <> show uid
    Just ud -> do
      mCfg <- runDbIn env (ConfigRM.getConfiguration ud.configurationId)
      case mCfg of
        Nothing -> fail $ "firstDictionaryEntry: configuration not found for user " <> show uid
        Just cfg ->
          case Map.lookup dictId cfg.dictionaries of
            Nothing -> fail $ "firstDictionaryEntry: dictionary " <> show dictId <> " missing"
            Just dict ->
              case ConfigRM.dictionaryItems dict of
                ((eid, _) : _) -> pure eid
                [] -> fail $ "firstDictionaryEntry: dictionary " <> show dictId <> " is empty"

-- | Seed the default configuration and register a fresh user. Returns
-- the new user's id.
--
-- Most service-layer specs open their setup with @seedDefaultConfiguration@
-- followed by @register@; this combinator removes the boilerplate.
seedDefaultAndRegister :: AppEnv -> Text -> IO UserId
seedDefaultAndRegister env email = do
  runAppM env seedDefaultConfiguration
  registerUser env email

-- | A user with a Regular account and the first income / expense
-- category dictionary entries. The common starting point for
-- transaction service-layer specs.
data MetadataFixture = MetadataFixture
  { userId :: !UserId,
    regularAccountId :: !AccountId,
    incomeCategory :: !DictionaryEntryId,
    expenseCategory :: !DictionaryEntryId
  }

-- | Build a length-1 'NonEmpty' Allocation list from the fixture's
-- income category at the given amount. Convenience used by service
-- specs that pre-date the multi-category design and merely need a
-- valid 'Allocations' to pass to 'initiateIncome'.
incomeAllocs :: MetadataFixture -> Money -> Allocations
incomeAllocs fx amt = mkIncomeAllocations (Allocation fx.incomeCategory amt Nothing :| [])

-- | Same as 'incomeAllocs' but targeting the fixture's expense
-- category — for use with 'initiateExpense'.
expenseAllocs :: MetadataFixture -> Money -> Allocations
expenseAllocs fx amt = mkExpenseAllocations (Allocation fx.expenseCategory amt Nothing :| [])

-- | Seed the default configuration, register a user, then resolve the
-- first income / expense category and create a Regular USD wallet.
setupMetadataFixture :: AppEnv -> Text -> IO MetadataFixture
setupMetadataFixture env email = do
  uid <- seedDefaultAndRegister env email
  incomeCat <- firstDictionaryEntry env uid incomeCategoryDictKind
  expenseCat <- firstDictionaryEntry env uid expenseCategoryDictKind
  accId <- createDefaultAccount env uid "Wallet"
  pure
    MetadataFixture
      { userId = uid,
        regularAccountId = accId,
        incomeCategory = incomeCat,
        expenseCategory = expenseCat
      }

-- -----------------------------------------------------------------------------
-- Transaction posting + queries
-- -----------------------------------------------------------------------------

-- | Post an Expense of the given amount against the fixture wallet and
-- (optionally) a contact; return the new transaction id.
postExpense :: AppEnv -> MetadataFixture -> Rational -> Maybe ContactId -> IO TransactionId
postExpense env fx amt contact = do
  res <-
    runAppM env
      $ initiateExpense
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (expenseAllocs fx (unsafeMoney Core.USD amt))
        mempty
        "Expense"
        Nothing
        Nothing
        contact
  unwrapTx "initiateExpense" res

-- | Post an Income of the given amount against the fixture wallet.
postIncome :: AppEnv -> MetadataFixture -> Rational -> Maybe ContactId -> IO TransactionId
postIncome env fx amt contact = do
  res <-
    runAppM env
      $ initiateIncome
        fx.userId
        fx.regularAccountId
        (unsafeMoney Core.USD amt)
        (incomeAllocs fx (unsafeMoney Core.USD amt))
        mempty
        "Income"
        Nothing
        Nothing
        contact
  unwrapTx "initiateIncome" res

-- | Extract the new transaction id from an @initiate*@ service result,
-- failing the test (with context) on 'Left'. Handy when a spec posts a
-- transaction directly (custom account / currency / date) instead of via
-- 'postExpense' \/ 'postIncome'.
unwrapTx :: String -> Either DomainError (TransactionId, TransactionData) -> IO TransactionId
unwrapTx ctx res = case res of
  Left err -> fail $ ctx <> " failed: " <> show err
  Right (tid, _) -> pure tid

-- | Add a contact-dictionary entry for the user and return its id.
seedContact :: AppEnv -> UserId -> Text -> IO ContactId
seedContact env uid name = do
  res <- runAppM env $ addDictionaryEntry uid contactsDictKind (unsafeEntryName name) ItemRole Nothing
  case res of
    Left err -> fail $ "seedContact failed: " <> show err
    Right eid -> pure eid

-- | Resolve the current 'TransactionStatus' of a transaction via the read model.
statusOf :: AppEnv -> TransactionId -> IO TransactionStatus
statusOf env tid = do
  res <- runAppM env (getTransaction (unTransactionId tid))
  case res of
    Left err -> fail $ "getTransaction failed: " <> show err
    Right (_, td) -> pure td.status

-- | Flat list of allocation amounts across both buckets of a transaction.
allocAmounts :: TransactionData -> [Rational]
allocAmounts td = case allocationsOf td.transactionType of
  Just a -> [unMoney al.amount | al <- allAllocations a]
  Nothing -> []
