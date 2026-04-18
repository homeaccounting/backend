{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Telegram.Formatting
-- Description : Pure presentation helpers for Telegram bot output
--
-- Centralizes the value-renderers used to compose bot messages and
-- button labels: money amounts, currency codes, dates, transaction
-- lines, and the canonical command list. Keeping presentation separate
-- from the command handlers in "Telegram.Commands" makes the handlers
-- easier to read and these renderers trivially unit-testable.
--
-- Ad-hoc one-shot copy (prompts like @"Enter amount:"@, error messages)
-- intentionally stays next to the state transition that emits it —
-- moving every string here would add ceremony without reuse.
module Telegram.Formatting
  ( -- * Value Renderers
    formatMoney,
    showCurrency,
    formatDate,

    -- * Listing Renderers
    formatTransactionLine,
    formatCommandList,
  )
where

import Application.ReadModels.Transaction (TransactionData (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Domain.Core.Types
  ( Currency (..),
    Money,
    TransactionId,
    TransferType (..),
    moneyCurrency,
    unMoney,
  )
import Domain.Transaction.Projection (TransactionStatus (..))
import Numeric (showFFloat)
import Telegram.Types (botCommands)

-- -----------------------------------------------------------------------------
-- Value Renderers
-- -----------------------------------------------------------------------------

-- | Format a 'Money' amount as a human-readable number with two decimal places.
formatMoney :: Money -> Text
formatMoney m = T.pack $ showFFloat (Just 2) (fromRational (unMoney m) :: Double) ""

-- | Render a 'Currency' as its three-letter code.
showCurrency :: Currency -> Text
showCurrency UAH = "UAH"
showCurrency USD = "USD"
showCurrency EUR = "EUR"
showCurrency GBP = "GBP"

-- | Format a 'UTCTime' as @YYYY-MM-DD HH:MM@ in UTC.
formatDate :: UTCTime -> Text
formatDate = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M"

-- -----------------------------------------------------------------------------
-- Listing Renderers
-- -----------------------------------------------------------------------------

-- | Render a single transaction as a one-line bullet entry, e.g.
--
-- > • 2026-04-18 14:30  Transfer  300.0 USD — Rent payment  [Completed]
formatTransactionLine :: (TransactionId, TransactionData) -> Text
formatTransactionLine (_txId, td) =
  let dateStr = formatDate td.date
      typeLabel = case td.transferType of
        Income _ -> "Income"
        Expense _ -> "Expense"
        Transfer -> "Transfer"
      amt = formatMoney td.sourceAmount <> " " <> showCurrency (moneyCurrency td.sourceAmount)
      statusLabel = case td.status of
        Pending -> "Pending"
        Completed -> "Completed"
        Failed reason -> "Failed: " <> reason
      desc =
        if T.null td.description
          then ""
          else " \x2014 " <> td.description
   in "\x2022 "
        <> dateStr
        <> "  "
        <> typeLabel
        <> "  "
        <> amt
        <> desc
        <> "  ["
        <> statusLabel
        <> "]"

-- | Render the canonical bot command list as @\"/cmd - description\"@ lines.
formatCommandList :: [Text]
formatCommandList = map (\(cmd, desc) -> cmd <> " - " <> desc) botCommands
