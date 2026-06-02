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
import Data.Foldable (toList)
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Domain.Core.Types
  ( Allocation (..),
    Currency (..),
    DictionaryEntryId,
    Money,
    TransactionId,
    TransactionType (..),
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
-- > • 2026-04-18 14:30  Expense · Food  300.0 USD — McDonald's  [lunch, kyiv]
--
-- Income and Expense rows are annotated with the category name resolved
-- from the supplied lookup map. Transfer rows and unresolved categories
-- (stale maps, missing entries) fall back to the bare type label. The
-- same map is used to render label names after the description as a
-- comma-separated list; unresolved label ids are dropped.
--
-- The @Completed@ status is omitted — transfers settle fast, so the bar
-- is redundant. Pending and Failed rows still carry a trailing
-- @[Pending]@ / @[Failed: reason]@ marker so atypical states stay
-- visible.
formatTransactionLine :: Map DictionaryEntryId Text -> (TransactionId, TransactionData) -> Text
formatTransactionLine entryNames (_txId, td) =
  let dateStr = formatDate td.date
      formatAllocation a =
        let amtText = formatMoney a.amount
         in case Map.lookup a.categoryId entryNames of
              Just name -> name <> ": " <> amtText
              Nothing -> amtText
      withAllocations kind allocs =
        let parts = fmap formatAllocation (toList allocs)
         in case parts of
              [] -> kind
              xs -> kind <> " \xB7 " <> T.intercalate ", " xs
      typeLabel = case td.transactionType of
        Income allocs -> withAllocations "Income" allocs
        Expense allocs -> withAllocations "Expense" allocs
        Transfer -> "Transfer"
        Adjustment -> "Adjustment"
      amt = formatMoney td.sourceAmount <> " " <> showCurrency (moneyCurrency td.sourceAmount)
      statusSuffix = case td.status of
        Completed -> ""
        Pending -> "  [Pending]"
        Failed reason -> "  [Failed: " <> reason <> "]"
      desc =
        if T.null td.description
          then ""
          else " \x2014 " <> td.description
      resolvedLabels =
        sort [name | lid <- Set.toList td.labels, Just name <- [Map.lookup lid entryNames]]
      labelsSuffix =
        if null resolvedLabels
          then ""
          else "  [" <> T.intercalate ", " resolvedLabels <> "]"
   in "\x2022 "
        <> dateStr
        <> "  "
        <> typeLabel
        <> "  "
        <> amt
        <> desc
        <> labelsSuffix
        <> statusSuffix

-- | Render the canonical bot command list as @\"/cmd - description\"@ lines.
formatCommandList :: [Text]
formatCommandList = map (\(cmd, desc) -> cmd <> " - " <> desc) botCommands
