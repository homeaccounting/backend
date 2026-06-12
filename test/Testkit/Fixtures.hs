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
    createRegularAccount,
    firstDictionaryEntry,
    seedDefaultAndRegister,
    userExternalAccountId,
    MetadataFixture (..),
    setupMetadataFixture,
    incomeAllocs,
    expenseAllocs,
  )
where

import qualified Application.ReadModels.Configuration as ConfigRM
import Application.ReadModels.User (UserData (..), getUser)
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (AuthResult (..), register)
import Application.Services.ConfigurationService
  ( expenseCategoryDictId,
    incomeCategoryDictId,
    seedDefaultConfiguration,
  )
import qualified Data.Map.Strict as Map
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    Allocation (..),
    Allocations,
    DictionaryEntryId,
    DictionaryId,
    Money,
    UserId,
    defaultCash,
    mkExpenseAllocations,
    mkIncomeAllocations,
    unsafeMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv (..), runAppM)
import RIO

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

-- | Create a 'Regular Cash' account with a 5000 USD starting balance and no
-- overdraft.
--
-- This matches the shape used by the integration specs that just need
-- "an account to attach a transaction to". Specs that need a different
-- 'AccountType' or initial balance should call 'createAccount' directly.
createRegularAccount :: AppEnv -> UserId -> Text -> IO AccountId
createRegularAccount env uid accName = do
  res <-
    runAppM env
      $ createAccount
      $ CreateAccount
        { name = accName,
          initialBalance = unsafeMoney Core.USD 5000,
          createdBy = uid,
          accountType = Regular defaultCash,
          overdraftLimit = Nothing
        }
  case res of
    Left err -> fail $ "createRegularAccount " <> show accName <> " failed: " <> show err
    Right (aid, _) -> pure aid

-- | Resolve the user's auto-created External account id. Fails the test
-- if the user is missing from the read model.
userExternalAccountId :: AppEnv -> UserId -> IO AccountId
userExternalAccountId env uid = do
  mUser <- getUser env.userReadModel uid
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
  mUser <- getUser env.userReadModel uid
  case mUser of
    Nothing -> fail $ "firstDictionaryEntry: user not found: " <> show uid
    Just ud -> do
      mCfg <- ConfigRM.getConfiguration env.configurationReadModel ud.configurationId
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
incomeAllocs fx amt = mkIncomeAllocations (Allocation fx.incomeCategory amt :| [])

-- | Same as 'incomeAllocs' but targeting the fixture's expense
-- category — for use with 'initiateExpense'.
expenseAllocs :: MetadataFixture -> Money -> Allocations
expenseAllocs fx amt = mkExpenseAllocations (Allocation fx.expenseCategory amt :| [])

-- | Seed the default configuration, register a user, then resolve the
-- first income / expense category and create a Regular USD wallet.
setupMetadataFixture :: AppEnv -> Text -> IO MetadataFixture
setupMetadataFixture env email = do
  uid <- seedDefaultAndRegister env email
  incomeCat <- firstDictionaryEntry env uid incomeCategoryDictId
  expenseCat <- firstDictionaryEntry env uid expenseCategoryDictId
  accId <- createRegularAccount env uid "Wallet"
  pure
    MetadataFixture
      { userId = uid,
        regularAccountId = accId,
        incomeCategory = incomeCat,
        expenseCategory = expenseCat
      }
