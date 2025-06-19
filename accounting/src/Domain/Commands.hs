{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Domain.Commands
  ( Command(..)
  , CreateAccountCommand(..)
  , TransferMoneyCommand(..)
  ) where

import Data.Aeson (ToJSON, FromJSON)
import GHC.Generics (Generic)
import Domain.Events

-- Command types for CQRS
data CreateAccountCommand = CreateAccountCommand
  { createAccountId :: AccountId
  , createAccountName :: AccountName
  , createInitialBalance :: Balance
  } deriving (Eq, Show, Generic)

data TransferMoneyCommand = TransferMoneyCommand
  { transferFromAccountId :: AccountId
  , transferToAccountId :: AccountId
  , transferAmount :: Money
  } deriving (Eq, Show, Generic)

data Command
  = CreateAccount CreateAccountCommand
  | TransferMoney TransferMoneyCommand
  deriving (Eq, Show, Generic)

-- JSON instances
instance ToJSON CreateAccountCommand
instance FromJSON CreateAccountCommand
instance ToJSON TransferMoneyCommand
instance FromJSON TransferMoneyCommand
instance ToJSON Command
instance FromJSON Command 