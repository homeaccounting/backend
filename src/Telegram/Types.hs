{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Telegram.Types
-- Description : Types for Telegram bot integration
--
-- This module defines types specific to Telegram bot operations,
-- including conversation state, callback data, and bot configuration.
module Telegram.Types
  ( -- * Bot State
    BotState (..),
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
import Domain.Core.Types (AccountId, Money, TelegramId, UserId)
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
    botStateConversations :: Map TelegramId ConversationState
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
      { transferSourceAccountId :: AccountId
      }
  | -- | Transfer flow: waiting for amount
    TransferEnterAmount
      { transferSourceAccountId :: AccountId,
        transferTargetAccountId :: AccountId
      }
  | -- | Transfer flow: waiting for reason
    TransferEnterReason
      { transferSourceAccountId :: AccountId,
        transferTargetAccountId :: AccountId,
        transferAmount :: Money
      }
  | -- | Income flow: waiting for account selection
    IncomeSelectAccount
  | -- | Income flow: waiting for amount
    IncomeEnterAmount
      { incomeTargetAccountId :: AccountId
      }
  | -- | Income flow: waiting for reason
    IncomeEnterReason
      { incomeTargetAccountId :: AccountId,
        incomeAmount :: Money
      }
  | -- | Expense flow: waiting for account selection
    ExpenseSelectAccount
  | -- | Expense flow: waiting for amount
    ExpenseEnterAmount
      { expenseSourceAccountId :: AccountId
      }
  | -- | Expense flow: waiting for reason
    ExpenseEnterReason
      { expenseSourceAccountId :: AccountId,
        expenseAmount :: Money
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
    selectAccountId :: Text,
    -- | Context (transfer_src, transfer_tgt, income, expense)
    selectContext :: Text
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
      { welcomeUserName :: Text
      }
  | -- | List of accounts
    AccountListMessage
      { accountListItems :: [(Text, Money)] -- (name, balance)
      }
  | -- | Account balance
    BalanceMessage
      { balanceAccountName :: Text,
        balanceAmount :: Money
      }
  | -- | Transfer confirmation
    TransferConfirmMessage
      { transferConfirmFrom :: Text,
        transferConfirmTo :: Text,
        transferConfirmAmount :: Money,
        transferConfirmReason :: Text
      }
  | -- | Transfer success
    TransferSuccessMessage
      { transferSuccessId :: Text
      }
  | -- | Error message
    ErrorMessage
      { errorText :: Text
      }
  | -- | Help message
    HelpMessage
  | -- | Prompt for account selection
    SelectAccountPrompt
      { selectAccountPromptTitle :: Text
      }
  | -- | Prompt for amount entry
    EnterAmountPrompt
  | -- | Prompt for reason entry
    EnterReasonPrompt
  deriving (Show, Eq, Generic)

instance ToJSON BotMessage

instance FromJSON BotMessage
