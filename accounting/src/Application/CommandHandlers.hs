{-# LANGUAGE OverloadedStrings #-}

module Application.CommandHandlers
  ( handleCommand
  , handleCreateAccount
  , handleTransferMoney
  ) where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (toText)

import Domain.Commands
import Domain.Events
import Domain.Account
import Infrastructure.EventStore

-- Main command handler dispatcher
handleCommand :: (MonadIO m) => AppState -> Command -> m (Either String [StoredEvent])
handleCommand appState (CreateAccount cmd) = handleCreateAccount appState cmd
handleCommand appState (TransferMoney cmd) = handleTransferMoney appState cmd

-- Handle CreateAccount command
handleCreateAccount :: (MonadIO m) => AppState -> CreateAccountCommand -> m (Either String [StoredEvent])
handleCreateAccount appState cmd = liftIO $ do
  let AccountId uuid = createAccountId cmd
      aggregateIdText = toText uuid
  
  -- Check if account already exists
  currentAccounts <- readTVarIO (accounts appState)
  case findAccount (createAccountId cmd) currentAccounts of
    Right _ -> return $ Left "Account already exists"
    Left _ -> do
      -- Create and store event
      let event = AccountCreated (createAccountId cmd) (createAccountName cmd) (createInitialBalance cmd)
      storedEvent <- appendEvent (eventStore appState) aggregateIdText "AccountCreated" event 1
      
      -- Update read model
      let newAccount = createAccount (createAccountId cmd) (createAccountName cmd) (createInitialBalance cmd)
      atomically $ do
        currentAccs <- readTVar (accounts appState)
        writeTVar (accounts appState) (newAccount : currentAccs)
      
      return $ Right [storedEvent]

-- Handle TransferMoney command
handleTransferMoney :: (MonadIO m) => AppState -> TransferMoneyCommand -> m (Either String [StoredEvent])
handleTransferMoney appState cmd = liftIO $ do
  currentAccounts <- readTVarIO (accounts appState)
  
  case transferMoney (transferFromAccountId cmd) (transferToAccountId cmd) (transferAmount cmd) currentAccounts of
    Left err -> return $ Left err
    Right (events, updatedAccounts) -> do
      let AccountId fromUuid = transferFromAccountId cmd
          fromAggregateId = toText fromUuid
      
      -- Store events (in this simple case, we only have one transfer event)
      storedEvents <- mapM (\event -> do
        let eventTypeText = case event of
              MoneyTransferred _ _ _ -> "MoneyTransferred"
              _ -> "Unknown"
        appendEvent (eventStore appState) fromAggregateId eventTypeText event 1
        ) events
      
      -- Update read model
      atomically $ do
        let updateAccount acc newAccs = 
              case findAccount (accountId acc) newAccs of
                Right updatedAcc -> updatedAcc : filter (\a -> accountId a /= accountId acc) newAccs
                Left _ -> acc : newAccs
            finalAccounts = foldr updateAccount [] updatedAccounts
        writeTVar (accounts appState) finalAccounts
      
      return $ Right storedEvents 