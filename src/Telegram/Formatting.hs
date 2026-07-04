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

    -- * Confirmation Renderer
    formatRecordedTransaction,
  )
where

import Application.ReadModels.Transaction (TransactionData (..))
import Data.List (sort)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Allocations,
    Currency (..),
    DictionaryEntryId,
    Money,
    TransactionId,
    TransactionType (..),
    allAllocations,
    exchangeRateValue,
    moneyCurrency,
    unAccountId,
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
        let parts = fmap formatAllocation (allAllocations allocs)
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
        Cancelled -> "  [Cancelled]"
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

-- Confirmation Renderer

-- | Render a just-recorded transaction as a multi-line confirmation used by
-- all Telegram recording paths (@/income@, @/expense@, @/transfer@, and the
-- natural-language prompt). @entryNames@ resolves category and label ids;
-- @accountNames@ resolves the user's own account ids. Both maps degrade
-- gracefully: an unresolved category falls back to the bare amount, an
-- unresolved account is dropped (expense/income) or shown as a short id
-- (transfer, to preserve the @A -> B@ arrow). Total over all
-- 'TransactionType' and 'TransactionStatus' constructors.
formatRecordedTransaction ::
  Map DictionaryEntryId Text ->
  Map AccountId Text ->
  TransactionData ->
  Text
formatRecordedTransaction entryNames accountNames td =
  case td.transactionType of
    Income allocs -> categorised "Income" td.targetAmount td.targetAccountId allocs
    Expense allocs -> categorised "Expense" td.sourceAmount td.sourceAccountId allocs
    Transfer -> transfer
    Adjustment -> adjustment
  where
    header :: Text -> Text
    header kind = "\9989 " <> kind <> " recorded" <> statusMarker

    statusMarker :: Text
    statusMarker = case td.status of
      Completed -> ""
      Pending -> "  [Pending]"
      Cancelled -> "  [Cancelled]"
      Failed reason -> "  [Failed: " <> reason <> "]"

    amountText :: Money -> Text
    amountText m = formatMoney m <> " " <> showCurrency (moneyCurrency m)

    accountSuffix :: AccountId -> Text
    accountSuffix aid = maybe "" (" \xB7 " <>) (Map.lookup aid accountNames)

    accountRef :: AccountId -> Text
    accountRef aid =
      fromMaybe
        (T.take 8 (T.pack (UUID.toString (unAccountId aid))))
        (Map.lookup aid accountNames)

    labelLines :: [Text]
    labelLines =
      let ns = sort [n | lid <- Set.toList td.labels, Just n <- [Map.lookup lid entryNames]]
       in ["Labels: " <> T.intercalate ", " ns | not (null ns)]

    bullet :: Allocation -> Text
    bullet a =
      let amt = formatMoney a.amount
          labelled = case Map.lookup a.categoryId entryNames of
            Just n -> n <> " " <> amt
            Nothing -> amt
          commentTail = case a.comment of
            Just c | not (T.null c) -> " \x2014 " <> c
            _ -> ""
       in "\x2022 " <> labelled <> commentTail

    categorised :: Text -> Money -> AccountId -> Allocations -> Text
    categorised kind total accId allocs =
      T.intercalate "\n" $
        [ header kind,
          amountText total <> accountSuffix accId
        ]
          <> fmap bullet (allAllocations allocs)
          <> labelLines
          <> [formatDate td.date]

    transfer :: Text
    transfer =
      let crossCurrency = moneyCurrency td.sourceAmount /= moneyCurrency td.targetAmount
          amountLine =
            if crossCurrency
              then amountText td.sourceAmount <> " \x2192 " <> amountText td.targetAmount
              else amountText td.sourceAmount
          rateLines = case td.exchangeRate of
            Just er | crossCurrency -> ["Rate: " <> formatRate (exchangeRateValue er)]
            _ -> []
       in T.intercalate "\n" $
            [ header "Transfer",
              accountRef td.sourceAccountId <> " \x2192 " <> accountRef td.targetAccountId,
              amountLine
            ]
              <> rateLines
              <> labelLines
              <> [formatDate td.date]

    adjustment :: Text
    adjustment =
      T.intercalate "\n" $
        [ header "Adjustment",
          amountText td.sourceAmount <> accountSuffix td.sourceAccountId
        ]
          <> labelLines
          <> [formatDate td.date]

-- | Render an exchange rate to two decimal places.
formatRate :: Rational -> Text
formatRate r = T.pack $ showFFloat (Just 2) (fromRational r :: Double) ""
