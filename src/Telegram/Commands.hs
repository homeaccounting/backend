{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.Commands
-- Description : Telegram bot command handlers
--
-- This module implements handlers for all bot commands:
--   - /start - Welcome and signup
--   - /login - Link Telegram to existing account
--   - /accounts - List accounts
--   - /balance - Show balances
--   - /transfer - Transfer between accounts
--   - /income - Record income (External -> Account)
--   - /expense - Record expense (Account -> External)
--   - /help - Show help
module Telegram.Commands
  ( -- * Command Handlers
    handleCommand,
    handleMessage,
    handleCallbackQuery,

    -- * Individual Commands
    handleStart,
    handleLogin,
    handleAccounts,
    handleBalance,
    handleTransfer,
    handleIncome,
    handleExpense,
    handleHelp,
  )
where

import Application.ReadModels.AccountSummary
  ( AccountSummaryData (..),
    getAllAccountSummaries,
  )
import Application.ReadModels.UserSummary
  ( getUserByTelegramId,
  )
import Domain.Core.Types
  ( AccountType (..),
    Money,
    TelegramId (..),
    addMoney,
    unMoney,
    unsafeMoney,
  )
import Infrastructure.App (AppM, HasReadModel (..), HasTelegramClient (..))
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Servant.Client (ClientEnv)
import Telegram.Api (answerCallback, sendTextMessage)
import qualified Telegram.Bot.API as TG
import Telegram.Types

-- -----------------------------------------------------------------------------
-- Main Command Router
-- -----------------------------------------------------------------------------

-- | Handle a command message (starts with /).
handleCommand :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleCommand botState telegramId chatId text = do
  let (cmd, args) = parseCommand text
  case cmd of
    "/start" -> handleStart botState telegramId chatId args
    "/login" -> handleLogin botState telegramId chatId args
    "/accounts" -> handleAccounts botState telegramId chatId
    "/balance" -> handleBalance botState telegramId chatId args
    "/transfer" -> handleTransfer botState telegramId chatId
    "/income" -> handleIncome botState telegramId chatId
    "/expense" -> handleExpense botState telegramId chatId
    "/help" -> handleHelp telegramId chatId
    _ -> sendMsg chatId $ "Unknown command: " <> cmd <> ". Use /help to see available commands."

-- | Parse command and arguments from text.
parseCommand :: Text -> (Text, Maybe Text)
parseCommand text =
  case T.words text of
    [] -> ("", Nothing)
    [cmd] -> (T.toLower cmd, Nothing)
    (cmd : rest) -> (T.toLower cmd, Just $ T.unwords rest)

-- -----------------------------------------------------------------------------
-- Message Handler (Non-Command)
-- -----------------------------------------------------------------------------

-- | Handle a non-command message (part of a conversation flow).
handleMessage :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleMessage _botState _telegramId chatId _text = do
  sendMsg chatId "I don't understand. Use /help to see available commands."

-- -----------------------------------------------------------------------------
-- Callback Query Handler
-- -----------------------------------------------------------------------------

-- | Handle an inline keyboard button press.
handleCallbackQuery :: TVar BotState -> TelegramId -> Int64 -> TG.CallbackQueryId -> Text -> AppM ()
handleCallbackQuery _botState _telegramId _chatId callbackQueryId _callbackData = do
  withClient $ \clientEnv ->
    void $ answerCallback clientEnv callbackQueryId Nothing

-- -----------------------------------------------------------------------------
-- Individual Command Handlers
-- -----------------------------------------------------------------------------

-- | Handle /start command.
handleStart :: TVar BotState -> TelegramId -> Int64 -> Maybe Text -> AppM ()
handleStart _botState _telegramId chatId _args = do
  sendMsg chatId
    $ T.unlines
      [ "Welcome to HomeAccounting Bot!",
        "",
        "I can help you track your finances directly from Telegram.",
        "",
        "Available commands:",
        "/accounts - View your accounts",
        "/balance - Check balances",
        "/income - Record income",
        "/expense - Record expense",
        "/transfer - Transfer between accounts",
        "/help - Show all commands"
      ]

-- | Handle /login command.
handleLogin :: TVar BotState -> TelegramId -> Int64 -> Maybe Text -> AppM ()
handleLogin _botState _telegramId chatId _args = do
  sendMsg chatId "To link your Telegram account, please log in at our website and use the 'Link Telegram' option."

-- | Handle /accounts command.
handleAccounts :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleAccounts _botState telegramId chatId = do
  userReadModel <- view userSummaryReadModelL
  maybeUser <- getUserByTelegramId userReadModel telegramId

  case maybeUser of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just (userId, _userData) -> do
      accountReadModel <- view accountSummaryReadModelL
      allAccounts <- getAllAccountSummaries accountReadModel

      let userAccounts = Map.toList $ Map.filter (\acc -> accountSummaryDataCreatedBy acc == userId) allAccounts

      if null userAccounts
        then sendMsg chatId "You don't have any accounts yet."
        else do
          let formatAccount (_accId, acc) =
                "• " <> accountSummaryDataName acc <> " (" <> showAccountType (accountSummaryDataType acc) <> ")"
              accountList = T.unlines $ map formatAccount userAccounts
          sendMsg chatId $ "Your accounts:\n\n" <> accountList

-- | Handle /balance command.
handleBalance :: TVar BotState -> TelegramId -> Int64 -> Maybe Text -> AppM ()
handleBalance _botState telegramId chatId _args = do
  userReadModel <- view userSummaryReadModelL
  maybeUser <- getUserByTelegramId userReadModel telegramId

  case maybeUser of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just (userId, _userData) -> do
      accountReadModel <- view accountSummaryReadModelL
      allAccounts <- getAllAccountSummaries accountReadModel

      let userAccounts = Map.toList $ Map.filter (\acc -> accountSummaryDataCreatedBy acc == userId) allAccounts

      if null userAccounts
        then sendMsg chatId "You don't have any accounts yet."
        else do
          let formatBalance (_accId, acc) =
                accountSummaryDataName acc <> ": " <> formatMoney (accountSummaryDataBalance acc)
              balanceList = T.unlines $ map formatBalance userAccounts
              total = foldl' addMoney (unsafeMoney 0) $ map (accountSummaryDataBalance . snd) userAccounts
          sendMsg chatId $ "Your balances:\n\n" <> balanceList <> "\n---\nTotal: " <> formatMoney total

-- | Handle /transfer command.
handleTransfer :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleTransfer _botState _telegramId chatId = do
  sendMsg chatId "Transfer flow is not yet implemented. Coming soon!"

-- | Handle /income command.
handleIncome :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleIncome _botState _telegramId chatId = do
  sendMsg chatId "Income recording is not yet implemented. Coming soon!"

-- | Handle /expense command.
handleExpense :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleExpense _botState _telegramId chatId = do
  sendMsg chatId "Expense recording is not yet implemented. Coming soon!"

-- | Handle /help command.
handleHelp :: TelegramId -> Int64 -> AppM ()
handleHelp _telegramId chatId = do
  sendMsg chatId
    $ T.unlines
      [ "HomeAccounting Bot Commands:",
        "",
        "/start - Start using the bot",
        "/accounts - List your accounts",
        "/balance - Show account balances",
        "/transfer - Transfer between accounts",
        "/income - Record income",
        "/expense - Record expense",
        "/help - Show this help message"
      ]

-- -----------------------------------------------------------------------------
-- Telegram API Helpers
-- -----------------------------------------------------------------------------

-- | Send a text message to a chat via the Telegram API.
sendMsg :: Int64 -> Text -> AppM ()
sendMsg chatId text = withClient $ \clientEnv -> do
  let someChatId = TG.SomeChatId (TG.ChatId (fromIntegral chatId))
  result <- sendTextMessage clientEnv someChatId text
  case result of
    Left err -> logError $ "Failed to send message: " <> displayShow err
    Right _ -> return ()

-- | Run an action with the Telegram client, logging a warning if unavailable.
withClient :: (ClientEnv -> AppM ()) -> AppM ()
withClient action = do
  maybeClientEnv <- view telegramClientEnvL
  case maybeClientEnv of
    Nothing -> logWarn "Telegram client not available, cannot send message"
    Just clientEnv -> action clientEnv

-- | Format Money as text.
formatMoney :: Money -> Text
formatMoney m = T.pack $ show (fromRational (unMoney m) :: Double)

-- | Show account type as text.
showAccountType :: AccountType -> Text
showAccountType RegularAccount = "Regular"
showAccountType ExternalAccount = "External"
