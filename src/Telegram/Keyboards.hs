{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Telegram.Keyboards
-- Description : Inline keyboard builders for Telegram bot
--
-- This module provides functions to build inline keyboards for:
--   - Account selection
--   - Confirmation dialogs
--   - Cancel buttons
module Telegram.Keyboards
  ( -- * Keyboard Builders
    accountSelectionKeyboard,
    confirmCancelKeyboard,
    cancelKeyboard,

    -- * Types
    InlineKeyboard (..),
    InlineButton (..),
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Domain.Core.Types (AccountId, Money, unAccountId)

-- -----------------------------------------------------------------------------
-- Types
-- -----------------------------------------------------------------------------

-- | Inline keyboard markup.
data InlineKeyboard = InlineKeyboard
  { rows :: [[InlineButton]]
  }
  deriving (Show, Eq)

-- | Single inline keyboard button.
data InlineButton = InlineButton
  { text :: Text,
    callbackData :: Text
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- Keyboard Builders
-- -----------------------------------------------------------------------------

-- | Build an account selection keyboard.
--
-- Each account is displayed as a button with name and balance.
-- Callback data contains the account ID and context.
accountSelectionKeyboard ::
  -- | List of (AccountId, Name, Balance)
  [(AccountId, Text, Money)] ->
  -- | Context (e.g., "transfer_src", "income")
  Text ->
  InlineKeyboard
accountSelectionKeyboard accounts context =
  InlineKeyboard
    { rows =
        map makeAccountButton accounts
          ++ [[cancelButton]]
    }
  where
    makeAccountButton (accountId, name, balance) =
      [ InlineButton
          { text = name <> " (" <> showMoney balance <> ")",
            callbackData = "acc:" <> shortId accountId <> ":" <> context
          }
      ]
    shortId accountId = T.take 8 $ T.pack $ UUID.toString $ unAccountId accountId
    showMoney m = T.pack $ show m -- Simplified, would format properly

-- | Build a confirm/cancel keyboard.
confirmCancelKeyboard :: InlineKeyboard
confirmCancelKeyboard =
  InlineKeyboard
    { rows =
        [ [ InlineButton "Confirm" "confirm",
            InlineButton "Cancel" "cancel"
          ]
        ]
    }

-- | Build a cancel-only keyboard.
cancelKeyboard :: InlineKeyboard
cancelKeyboard =
  InlineKeyboard
    { rows = [[cancelButton]]
    }

-- | Cancel button.
cancelButton :: InlineButton
cancelButton = InlineButton "Cancel" "cancel"
