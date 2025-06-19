{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Web.API
  ( API
  , server
  , AccountResponse(..)
  , ErrorResponse(..)
  , CreateAccountRequest(..)
  , TransferMoneyRequest(..)
  ) where

import Data.Aeson (ToJSON, FromJSON)
import Data.Text (Text)
import GHC.Generics (Generic)
import Servant
import Data.UUID.V4 (nextRandom)
import Control.Monad.IO.Class

import Domain.Events
import Domain.Commands
import Domain.Account
import Infrastructure.EventStore
import Application.CommandHandlers
import Application.QueryHandlers

-- API Response Types
data AccountResponse = AccountResponse
  { responseAccount :: Account
  } deriving (Eq, Show, Generic)

data ErrorResponse = ErrorResponse
  { errorMessage :: Text
  } deriving (Eq, Show, Generic)

-- API Request Types
data CreateAccountRequest = CreateAccountRequest
  { requestAccountName :: Text
  , requestInitialBalance :: Integer
  } deriving (Eq, Show, Generic)

data TransferMoneyRequest = TransferMoneyRequest
  { requestFromAccountId :: AccountId
  , requestToAccountId :: AccountId
  , requestAmount :: Integer
  } deriving (Eq, Show, Generic)

-- JSON instances
instance ToJSON AccountResponse
instance FromJSON AccountResponse
instance ToJSON ErrorResponse
instance FromJSON ErrorResponse
instance ToJSON CreateAccountRequest
instance FromJSON CreateAccountRequest
instance ToJSON TransferMoneyRequest
instance FromJSON TransferMoneyRequest

-- API Definition
type API = 
       "accounts" :> Get '[JSON] [Account]
  :<|> "accounts" :> ReqBody '[JSON] CreateAccountRequest :> Post '[JSON] (Either ErrorResponse AccountResponse)
  :<|> "accounts" :> Capture "accountId" AccountId :> Get '[JSON] (Either ErrorResponse AccountResponse)
  :<|> "accounts" :> Capture "accountId" AccountId :> "balance" :> Get '[JSON] (Either ErrorResponse Balance)
  :<|> "transfer" :> ReqBody '[JSON] TransferMoneyRequest :> Post '[JSON] (Either ErrorResponse Text)
  :<|> "events" :> Get '[JSON] [StoredEvent]

-- Server Implementation
server :: AppState -> Server API
server appState = 
       handleGetAllAccounts
  :<|> handleCreateAccount
  :<|> handleGetAccount
  :<|> handleGetAccountBalance
  :<|> handleTransferMoney
  :<|> handleGetAllEvents
  where
    handleGetAllAccounts :: Handler [Account]
    handleGetAllAccounts = liftIO $ getAllAccounts appState

    handleCreateAccount :: CreateAccountRequest -> Handler (Either ErrorResponse AccountResponse)
    handleCreateAccount req = liftIO $ do
      newAccountId <- AccountId <$> nextRandom
      let cmd = CreateAccountCommand newAccountId (AccountName $ requestAccountName req) (Balance $ requestInitialBalance req)
          command = CreateAccount cmd
      result <- handleCommand appState command
      case result of
        Left err -> return $ Left $ ErrorResponse $ show err
        Right _ -> do
          -- Get the created account
          accountResult <- getAccount appState newAccountId
          case accountResult of
            Left err -> return $ Left $ ErrorResponse $ show err
            Right account -> return $ Right $ AccountResponse account

    handleGetAccount :: AccountId -> Handler (Either ErrorResponse AccountResponse)
    handleGetAccount accountId = liftIO $ do
      result <- getAccount appState accountId
      case result of
        Left err -> return $ Left $ ErrorResponse $ show err
        Right account -> return $ Right $ AccountResponse account

    handleGetAccountBalance :: AccountId -> Handler (Either ErrorResponse Balance)
    handleGetAccountBalance accountId = liftIO $ do
      result <- getAccountBalance appState accountId
      case result of
        Left err -> return $ Left $ ErrorResponse $ show err
        Right balance -> return $ Right balance

    handleTransferMoney :: TransferMoneyRequest -> Handler (Either ErrorResponse Text)
    handleTransferMoney req = liftIO $ do
      let cmd = TransferMoneyCommand (requestFromAccountId req) (requestToAccountId req) (Money $ requestAmount req)
          command = TransferMoney cmd
      result <- handleCommand appState command
      case result of
        Left err -> return $ Left $ ErrorResponse $ show err
        Right _ -> return $ Right "Transfer completed successfully"

    handleGetAllEvents :: Handler [StoredEvent]
    handleGetAllEvents = liftIO $ getAllEvents appState 