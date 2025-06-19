{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Domain.Account
  ( Account(..)
  , AccountState(..)
  , createAccount
  , transferMoney
  , applyEvent
  , getBalance
  ) where

import Data.Aeson (ToJSON, FromJSON)
import GHC.Generics (Generic)
import Domain.Events

-- Account aggregate root
data Account = Account
  { accountId :: AccountId
  , accountName :: AccountName
  , balance :: Balance
  , version :: Int
  } deriving (Eq, Show, Generic)

data AccountState = AccountState
  { accounts :: [Account]
  } deriving (Eq, Show, Generic)

-- JSON instances
instance ToJSON Account
instance FromJSON Account
instance ToJSON AccountState
instance FromJSON AccountState

-- Business logic
createAccount :: AccountId -> AccountName -> Balance -> Account
createAccount aid name bal = Account aid name bal 0

transferMoney :: AccountId -> AccountId -> Money -> [Account] -> Either String ([Event], [Account])
transferMoney fromId toId (Money amount) accounts = do
  fromAccount <- findAccount fromId accounts
  toAccount <- findAccount toId accounts
  
  let Balance fromBalance = balance fromAccount
  if fromBalance < amount
    then Left "Insufficient funds"
    else do
      let fromAccount' = fromAccount { balance = Balance (fromBalance - amount), version = version fromAccount + 1 }
          Balance toBalance = balance toAccount
          toAccount' = toAccount { balance = Balance (toBalance + amount), version = version toAccount + 1 }
          transferEvent = MoneyTransferred fromId toId (Money amount)
      Right ([transferEvent], [fromAccount', toAccount'])

findAccount :: AccountId -> [Account] -> Either String Account
findAccount aid accounts = 
  case filter (\acc -> accountId acc == aid) accounts of
    [account] -> Right account
    [] -> Left "Account not found"
    _ -> Left "Multiple accounts found with same ID"

applyEvent :: Event -> [Account] -> [Account]
applyEvent (AccountCreated aid name bal) accounts = 
  createAccount aid name bal : accounts
applyEvent (MoneyTransferred fromId toId (Money amount)) accounts =
  map updateAccount accounts
  where
    updateAccount acc
      | accountId acc == fromId = 
          let Balance currentBalance = balance acc
          in acc { balance = Balance (currentBalance - amount) }
      | accountId acc == toId = 
          let Balance currentBalance = balance acc
          in acc { balance = Balance (currentBalance + amount) }
      | otherwise = acc

getBalance :: AccountId -> [Account] -> Either String Balance
getBalance aid accounts = do
  account <- findAccount aid accounts
  Right (balance account) 