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
    currencyKeyboard,
    categoryKeyboard,

    -- * Types
    InlineKeyboard (..),
    InlineButton (..),
  )
where

import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Domain.Core.Types (AccountId, DictionaryEntryId, EntryName, Money, moneyCurrency, unAccountId, unDictionaryEntryId, unEntryName)
import Telegram.Formatting (formatMoney, showCurrency)

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
  -- | Currently-selected account (marked with a check); Nothing = none
  Maybe AccountId ->
  -- | Context (e.g., "transfer_src", "transfer_tgt", "select")
  Text ->
  InlineKeyboard
accountSelectionKeyboard accounts selected context =
  InlineKeyboard
    { rows =
        map makeAccountButton accounts
          ++ clearRow
          ++ [[cancelButton]]
    }
  where
    makeAccountButton (accountId, name, balance) =
      [ InlineButton
          { text = marker accountId <> name <> " (" <> showMoney balance <> ")",
            callbackData = "acc:" <> shortId accountId <> ":" <> context
          }
      ]
    -- The selected-account marker and Clear row belong only to the /accounts
    -- selection view; transfer flows never surface the global selection.
    inSelectContext = context == "select"
    marker accountId
      | inSelectContext, selected == Just accountId = "\x2713 "
      | otherwise = ""
    clearRow =
      [[InlineButton "Clear selection" "unselect"] | inSelectContext, isJust selected]
    shortId accountId = T.take 8 $ T.pack $ UUID.toString $ unAccountId accountId
    showMoney m = formatMoney m <> " " <> showCurrency (moneyCurrency m)

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

-- | Currency selection keyboard (2x2 grid + cancel).
currencyKeyboard :: InlineKeyboard
currencyKeyboard =
  InlineKeyboard
    { rows =
        [ [InlineButton "UAH" "cur:UAH", InlineButton "USD" "cur:USD"],
          [InlineButton "EUR" "cur:EUR", InlineButton "GBP" "cur:GBP"],
          [cancelButton]
        ]
    }

-- | Dynamic category keyboard built from dictionary entries.
--
-- Each entry becomes a button with the entry name as label and the
-- DictionaryEntryId UUID as callback data (prefixed with "cat:").
categoryKeyboard :: [(DictionaryEntryId, EntryName)] -> InlineKeyboard
categoryKeyboard entries =
  InlineKeyboard
    { rows =
        map (\(eid, name) -> [InlineButton (unEntryName name) ("cat:" <> T.pack (UUID.toString (unDictionaryEntryId eid)))]) entries
          ++ [[cancelButton]]
    }

-- | Cancel button.
cancelButton :: InlineButton
cancelButton = InlineButton "Cancel" "cancel"
