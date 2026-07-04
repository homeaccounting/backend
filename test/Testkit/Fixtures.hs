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
  )
where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.ExchangeRate (applyExchangeRateEvent)
import Application.ReadModels.User (UserData (..), applyUserEvent, getUser)
import qualified Application.Services.AccountService as AccountService
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( expenseCategoryDictId,
    incomeCategoryDictId,
    seedDefaultConfiguration,
  )
import qualified Data.Map.Strict as Map
import Data.Time (getCurrentTime, utctDay)
import qualified Data.UUID as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreateAccount (..), CreditAccount (..))
import Domain.Core.Types
  ( AccountId,
    AccountSubtype,
    AccountType (..),
    Allocation (..),
    Allocations,
    DictionaryEntryId,
    DictionaryId,
    Money,
    UserId,
    defaultBankAccount,
    defaultCash,
    mkExpenseAllocations,
    mkIncomeAllocations,
    unAccountId,
    unUserId,
    unsafeMoney,
    unsafeTransactionId,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Domain.ExchangeRate.Events (ExchangeRatesPublished (..))
import Domain.Models (AccountingEvent (..))
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

-- | Return the first 'DictionaryEntryId' from the named dictionary on the
-- given user's configuration.
--
-- "First" is whatever 'Map.keys' returns from the dictionary's entry map —
-- callers should only rely on stability within a single test, not on a
-- specific ordering across runs.
firstDictionaryEntry :: AppEnv -> UserId -> DictionaryId -> IO DictionaryEntryId
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
              case Map.keys dict.entries of
                (eid : _) -> pure eid
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
  incomeCat <- firstDictionaryEntry env uid incomeCategoryDictId
  expenseCat <- firstDictionaryEntry env uid expenseCategoryDictId
  accId <- createDefaultAccount env uid "Wallet"
  pure
    MetadataFixture
      { userId = uid,
        regularAccountId = accId,
        incomeCategory = incomeCat,
        expenseCategory = expenseCat
      }
