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
    emptyBotState,
    ConversationState (..),

    -- * Commands
    botCommands,
    commandMenuNeedsSync,

    -- * Callback Data
    CallbackData (..),
    AccountSelectionCallback (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.Core.Types (AccountId, Money, TelegramId)
import Domain.Localization.Language (Language (..))
import GHC.Generics (Generic)
import Telegram.I18n (CommandStrings (..), TelegramStrings (..), telegramStrings)

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
    conversations :: Map TelegramId ConversationState,
    -- | Selected accounts by Telegram user ID
    selectedAccounts :: Map TelegramId (AccountId, Text),
    -- | The language the per-chat command menu was last set to, by chat id.
    -- Lets the bot push a chat-scoped @setMyCommands@ only when a chat's
    -- resolved language actually changes (see 'commandMenuNeedsSync').
    syncedCommandLangs :: Map Int64 Language
  }
  deriving (Show, Eq, Generic)

-- | Initial empty bot state.
emptyBotState :: BotState
emptyBotState = BotState Map.empty Map.empty Map.empty

-- | Whether the chat-scoped command menu must be (re)pushed for @chatId@ to
-- match @lang@. The unset baseline is 'En' — the global default menu already
-- shows English — so a fresh English chat needs no per-chat override, while any
-- non-English chat, or a chat whose language changed, does.
commandMenuNeedsSync :: Map Int64 Language -> Int64 -> Language -> Bool
commandMenuNeedsSync synced chatId lang =
  Map.findWithDefault En chatId synced /= lang

-- -----------------------------------------------------------------------------
-- Commands
-- -----------------------------------------------------------------------------

-- | Canonical list of bot commands (command, description) for a locale.
--
-- Single source of truth used by setMyCommands, /help, and /start. The command
-- tokens (@\/start@ etc.) are stable across locales; only the descriptions are
-- localized via 'Telegram.I18n'.
botCommands :: Language -> [(Text, Text)]
botCommands lang =
  let strings = telegramStrings lang
      c = strings.commands
   in [ ("/start", c.start),
        ("/signup", c.signup),
        ("/accounts", c.viewAccounts),
        ("/newaccount", c.newaccount),
        ("/prompt", c.recordFromText),
        ("/income", c.income),
        ("/expense", c.expense),
        ("/transfer", c.transfer),
        ("/transactions", c.listTransactions),
        ("/cancel", c.cancel),
        ("/help", c.help)
      ]

-- | State for a multi-step conversation.
--
-- Used for flows like /transfer that require multiple inputs.
data ConversationState
  = -- Transfer flow
    TransferSelectSource
  | TransferSelectTarget
      { sourceAccountId :: AccountId
      }
  | TransferEnterAmount
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId
      }
  | TransferEnterDescription
      { sourceAccountId :: AccountId,
        targetAccountId :: AccountId,
        amount :: Money
      }
  | -- Income flow
    IncomeSelectCategory
  | IncomeEnterAmount
      { category :: Text
      }
  | IncomeEnterDescription
      { category :: Text,
        amount :: Money
      }
  | -- Expense flow
    ExpenseSelectCategory
  | ExpenseEnterAmount
      { category :: Text
      }
  | ExpenseEnterDescription
      { category :: Text,
        amount :: Money
      }
  | -- Account creation flow
    CreateAccountEnterName
  | CreateAccountSelectCurrency
      { accountName :: Text
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
  | -- | Category selection callback
    CategorySelect Text
  | -- | Currency selection callback
    CurrencySelect Text
  | -- | Cancel current operation
    Cancel
  | -- | Confirm current operation
    Confirm
  | -- | Clear the user's selected account
    ClearSelection
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
