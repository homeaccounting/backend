{-# LANGUAGE OverloadedStrings #-}

module Application.QueryHandlers
  ( getAllAccounts
  , getAccount
  , getAccountBalance
  , getAllEvents
  ) where

import Control.Concurrent.STM
import Control.Monad.IO.Class
import Data.Text (Text)

import Domain.Events
import Domain.Account
import Infrastructure.EventStore

-- Get all accounts (read from projection/read model)
getAllAccounts :: (MonadIO m) => AppState -> m [Account]
getAllAccounts appState = liftIO $ readTVarIO (accounts appState)

-- Get specific account by ID
getAccount :: (MonadIO m) => AppState -> AccountId -> m (Either String Account)
getAccount appState accountId = liftIO $ do
  currentAccounts <- readTVarIO (accounts appState)
  return $ findAccount accountId currentAccounts

-- Get account balance
getAccountBalance :: (MonadIO m) => AppState -> AccountId -> m (Either String Balance)
getAccountBalance appState accountId = liftIO $ do
  currentAccounts <- readTVarIO (accounts appState)
  return $ getBalance accountId currentAccounts

-- Get all events (for debugging/auditing)
getAllEvents :: (MonadIO m) => AppState -> m [StoredEvent]
getAllEvents appState = getEvents (eventStore appState) 