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
import Domain.Localization.Language (Language)
import Telegram.Formatting (formatMoney, showCurrency)
import Telegram.I18n (CommonStrings (..), TelegramStrings (..), telegramStrings)

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
  -- | Language for static button labels (Clear/Cancel)
  Language ->
  -- | List of (AccountId, Name, Balance)
  [(AccountId, Text, Money)] ->
  -- | Currently-selected account (marked with a check); Nothing = none
  Maybe AccountId ->
  -- | Context (e.g., "transfer_src", "transfer_tgt", "select")
  Text ->
  InlineKeyboard
accountSelectionKeyboard lang accounts selected context =
  InlineKeyboard
    { rows =
        map makeAccountButton accounts
          ++ clearRow
          ++ [[cancelButton lang]]
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
      [[InlineButton (telegramStrings lang).common.clearSelectionButton "unselect"] | inSelectContext, isJust selected]
    shortId accountId = T.take 8 $ T.pack $ UUID.toString $ unAccountId accountId
    showMoney m = formatMoney m <> " " <> showCurrency (moneyCurrency m)

-- | Build a confirm/cancel keyboard.
confirmCancelKeyboard :: Language -> InlineKeyboard
confirmCancelKeyboard lang =
  InlineKeyboard
    { rows =
        [ [ InlineButton (telegramStrings lang).common.confirmButton "confirm",
            InlineButton (telegramStrings lang).common.cancelButton "cancel"
          ]
        ]
    }

-- | Build a cancel-only keyboard.
cancelKeyboard :: Language -> InlineKeyboard
cancelKeyboard lang =
  InlineKeyboard
    { rows = [[cancelButton lang]]
    }

-- | Currency selection keyboard (2x2 grid + cancel). Currency codes are not
-- localized; only the trailing cancel button is.
currencyKeyboard :: Language -> InlineKeyboard
currencyKeyboard lang =
  InlineKeyboard
    { rows =
        [ [InlineButton "UAH" "cur:UAH", InlineButton "USD" "cur:USD"],
          [InlineButton "EUR" "cur:EUR", InlineButton "GBP" "cur:GBP"],
          [cancelButton lang]
        ]
    }

-- | Dynamic category keyboard built from dictionary entries.
--
-- Each entry becomes a button with the entry name as label and the
-- DictionaryEntryId UUID as callback data (prefixed with "cat:"). Entry names
-- are user/config content and are not localized; only the trailing cancel
-- button is.
categoryKeyboard :: Language -> [(DictionaryEntryId, EntryName)] -> InlineKeyboard
categoryKeyboard lang entries =
  InlineKeyboard
    { rows =
        map (\(eid, name) -> [InlineButton (unEntryName name) ("cat:" <> T.pack (UUID.toString (unDictionaryEntryId eid)))]) entries
          ++ [[cancelButton lang]]
    }

-- | Cancel button, localized.
cancelButton :: Language -> InlineButton
cancelButton lang = InlineButton (telegramStrings lang).common.cancelButton "cancel"
