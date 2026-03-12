{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Telegram.Types
-- Description : Types for Telegram bot integration
--
-- This module defines types specific to Telegram bot operations,
-- including conversation state, callback data, and bot configuration.
module Telegram.Types
  ( -- * Bot State
    BotState (..),
    emptyBotState,
    ConversationState (..),

    -- * Callback Data
    CallbackData (..),
    AccountSelectionCallback (..),

    -- * Message Types
    BotMessage (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, TelegramId)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Bot State
-- -----------------------------------------------------------------------------

-- | Global bot state.
--
-- This tracks:
--   - Active conversations (multi-step flows)
--   - Session data per user
data BotState = BotState
  { -- | Active conversations by Telegram user ID
    conversations :: Map TelegramId ConversationState
  }
  deriving (Show, Eq, Generic)

-- | Initial empty bot state.
emptyBotState :: BotState
emptyBotState = BotState Map.empty

-- | State for a multi-step conversation.
--
-- Used for flows like /transfer that require multiple inputs.
data ConversationState
  = -- | Transfer flow: waiting for source account
    TransferSelectSource
  | -- | Transfer flow: waiting for target account
    TransferSelectTarget
      { sourceAccountId :: AccountId
      }
  | -- | Transfer flow: waiting for amount
    TransferEnterAmount
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId
      }
  | -- | Transfer flow: waiting for reason
    TransferEnterReason
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId,
        amount :: Money
      }
  | -- | Income flow: waiting for account selection
    IncomeSelectAccount
  | -- | Income flow: waiting for amount
    IncomeEnterAmount
      { targetAccountId :: AccountId
      }
  | -- | Income flow: waiting for reason
    IncomeEnterReason
      { targetAccountId :: AccountId,
        amount :: Money
      }
  | -- | Expense flow: waiting for account selection
    ExpenseSelectAccount
  | -- | Expense flow: waiting for amount
    ExpenseEnterAmount
      { sourceAccountId :: AccountId
      }
  | -- | Expense flow: waiting for reason
    ExpenseEnterReason
      { sourceAccountId :: AccountId,
        amount :: Money
      }
  deriving (Show, Eq, Generic)

instance ToJSON ConversationState

instance FromJSON ConversationState

-- -----------------------------------------------------------------------------
-- Callback Data
-- -----------------------------------------------------------------------------

-- | Callback data for inline keyboard buttons.
--
-- This is serialized to the callback_data field in Telegram buttons.
-- Keep it short to fit within Telegram's 64-byte limit.
data CallbackData
  = -- | Account selection callback
    AccountSelect AccountSelectionCallback
  | -- | Cancel current operation
    Cancel
  | -- | Confirm current operation
    Confirm
  deriving (Show, Eq, Generic)

instance ToJSON CallbackData

instance FromJSON CallbackData

-- | Callback data for account selection buttons.
data AccountSelectionCallback = AccountSelectionCallback
  { -- | Selected account ID (shortened for space)
    accountId :: Text,
    -- | Context (transfer_src, transfer_tgt, income, expense)
    context :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountSelectionCallback

instance FromJSON AccountSelectionCallback

-- -----------------------------------------------------------------------------
-- Message Types
-- -----------------------------------------------------------------------------

-- | Bot response messages.
--
-- These are the messages the bot can send to users.
data BotMessage
  = -- | Welcome message for new users
    WelcomeMessage
      { userName :: Text
      }
  | -- | List of accounts
    AccountListMessage
      { items :: [(Text, Money)] -- (name, balance)
      }
  | -- | Account balance
    BalanceMessage
      { accountName :: Text,
        amount :: Money
      }
  | -- | Transfer confirmation
    TransferConfirmMessage
      { from :: Text,
        to :: Text,
        amount :: Money,
        reason :: Text
      }
  | -- | Transfer success
    TransferSuccessMessage
      { transactionId :: Text
      }
  | -- | Error message
    ErrorMessage
      { text :: Text
      }
  | -- | Help message
    HelpMessage
  | -- | Prompt for account selection
    SelectAccountPrompt
      { title :: Text
      }
  | -- | Prompt for amount entry
    EnterAmountPrompt
  | -- | Prompt for reason entry
    EnterReasonPrompt
  deriving (Show, Eq, Generic)

instance ToJSON BotMessage

instance FromJSON BotMessage
