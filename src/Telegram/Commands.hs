{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.Commands
-- Description : Telegram bot command handlers
--
-- This module implements handlers for all bot commands:
--   - /start - Welcome and signup
--   - /login - Link Telegram to existing account
--   - /accounts - List accounts & select active one
--   - /newaccount - Create a new account
--   - /transfer - Transfer between accounts
--   - /income - Record income (External -> Account)
--   - /expense - Record expense (Account -> External)
--   - /transactions - List transactions (last 30 days)
--   - /cancel - Cancel current operation
--   - /help - Show help
module Telegram.Commands
  ( -- * Command Handlers
    handleCommand,
    handleMessage,
    handleCallbackQuery,

    -- * Individual Commands
    handleStart,
    handleSignup,
    handleLogin,
    handleAccounts,
    handleNewAccount,
    handleTransfer,
    handleIncome,
    handleExpense,
    handleTransactions,
    handleCancel,
    handleHelp,

    -- * Helpers
    sendMsg,
    sendMsgWithKeyboard,
    toTgKeyboard,
    getUserIdForTelegram,
    getUserRegularAccounts,
    findAccountByShortId,
    parseCallbackData,
  )
where

import Application.LinkCodeStore (mkLinkCodeToken)
import Application.ReadModels.Account
  ( AccountData (..),
    getAccount,
  )
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.Configuration (ConfigurationData (..), DictionaryData (..), getConfiguration)
import Application.ReadModels.Transaction (TransactionData (..), mkTransactionFilter)
import Application.ReadModels.User
  ( UserData (..),
    getUserByTelegramId,
  )
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (findOrCreateTelegramBotUser, redeemTelegramLinkCode)
import Application.Services.ConfigurationService (expenseCategoryDictId, incomeCategoryDictId, labelsDictId)
import Application.Services.TransactionService (initiateExpense, initiateIncome, initiateTransfer)
import qualified Application.Services.TransactionService as TransactionService
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as Set
import Data.Time (addUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Page (Page (..))
import Domain.Core.Range (mkRange)
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    DictionaryEntryId,
    DictionaryId,
    EntryName,
    Money,
    TelegramId (..),
    TelegramIdentity (..),
    UserId,
    defaultCash,
    mkAllocation,
    mkDictionaryEntryId,
    mkMoney,
    moneyCurrency,
    parseCurrency,
    unAccountId,
    unEntryName,
    unsafeMoney,
  )
import Domain.Transaction.Projection (StatusKind (..), TransactionStatus (..))
import Infrastructure.App (AppM, HasReadModel (..), HasTelegramClient (..))
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Servant.Client (ClientEnv)
import Telegram.Api (answerCallback, sendMessageWithKeyboard, sendTextMessage)
import qualified Telegram.Bot.API as TG
import Telegram.Formatting
  ( formatCommandList,
    formatMoney,
    formatTransactionLine,
    showCurrency,
  )
import Telegram.Keyboards
  ( InlineButton (..),
    InlineKeyboard (..),
    accountSelectionKeyboard,
    categoryKeyboard,
    currencyKeyboard,
  )
import Telegram.Types

-- -----------------------------------------------------------------------------
-- Main Command Router
-- -----------------------------------------------------------------------------

-- | Handle a command message (starts with /).
handleCommand :: TVar BotState -> TelegramIdentity -> Int64 -> Text -> AppM ()
handleCommand botState tgIdentity chatId text = do
  let (cmd, args) = parseCommand text
      telegramId = (.id) tgIdentity
  case cmd of
    "/start" -> handleStart botState tgIdentity chatId args
    "/signup" -> handleSignup botState tgIdentity chatId args
    "/login" -> handleLogin botState telegramId chatId args
    "/accounts" -> handleAccounts botState telegramId chatId
    "/newaccount" -> handleNewAccount botState telegramId chatId
    "/transfer" -> handleTransfer botState telegramId chatId
    "/income" -> handleIncome botState telegramId chatId
    "/expense" -> handleExpense botState telegramId chatId
    "/transactions" -> handleTransactions botState telegramId chatId
    "/cancel" -> handleCancel botState telegramId chatId
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
handleMessage botState telegramId chatId text = do
  state <- atomically $ Map.lookup telegramId . (.conversations) <$> readTVar botState
  case state of
    Just CreateAccountEnterName ->
      handleCreateAccountName botState telegramId chatId text
    Just (IncomeEnterAmount cat) ->
      handleIncomeAmount botState telegramId chatId cat text
    Just (IncomeEnterDescription cat money) ->
      handleIncomeDescription botState telegramId chatId cat money text
    Just (ExpenseEnterAmount cat) ->
      handleExpenseAmount botState telegramId chatId cat text
    Just (ExpenseEnterDescription cat money) ->
      handleExpenseDescription botState telegramId chatId cat money text
    Just (TransferEnterAmount srcId tgtId) ->
      handleTransferAmount botState telegramId chatId srcId tgtId text
    Just (TransferEnterDescription srcId tgtId money) ->
      handleTransferDescription botState telegramId chatId srcId tgtId money text
    _ ->
      sendMsg chatId "I don't understand. Use /help to see available commands."

-- -----------------------------------------------------------------------------
-- Callback Query Handler
-- -----------------------------------------------------------------------------

-- | Handle an inline keyboard button press.
handleCallbackQuery :: TVar BotState -> TelegramId -> Int64 -> TG.CallbackQueryId -> Text -> AppM ()
handleCallbackQuery botState telegramId chatId callbackQueryId rawData = do
  withClient $ \clientEnv -> void $ answerCallback clientEnv callbackQueryId Nothing
  case parseCallbackData rawData of
    Nothing -> sendMsg chatId "Invalid button data."
    Just Cancel -> handleCancel botState telegramId chatId
    Just cbData -> do
      state <- atomically $ Map.lookup telegramId . (.conversations) <$> readTVar botState
      dispatchCallback botState telegramId chatId state cbData

-- | Parse callback data from a raw text string.
parseCallbackData :: Text -> Maybe CallbackData
parseCallbackData "cancel" = Just Cancel
parseCallbackData "confirm" = Just Confirm
parseCallbackData t
  | "acc:" `T.isPrefixOf` t = case T.split (== ':') t of
      ["acc", accId, ctx] -> Just $ AccountSelect (AccountSelectionCallback accId ctx)
      _ -> Nothing
  | "cat:" `T.isPrefixOf` t = Just $ CategorySelect (T.drop 4 t)
  | "cur:" `T.isPrefixOf` t = Just $ CurrencySelect (T.drop 4 t)
  | otherwise = Nothing

-- | Dispatch a callback to the appropriate handler based on state.
dispatchCallback :: TVar BotState -> TelegramId -> Int64 -> Maybe ConversationState -> CallbackData -> AppM ()
-- /accounts selection callback
dispatchCallback botState telegramId chatId _ (AccountSelect cb)
  | cb.context == "select" = handleSelectCallback botState telegramId chatId cb.accountId
-- Account creation currency selection
dispatchCallback botState telegramId chatId (Just (CreateAccountSelectCurrency name)) (CurrencySelect curText) =
  handleCreateAccountCurrency botState telegramId chatId name curText
-- Income category selection
dispatchCallback botState telegramId chatId (Just IncomeSelectCategory) (CategorySelect catText) =
  handleIncomeCategorySelected botState telegramId chatId catText
-- Expense category selection
dispatchCallback botState telegramId chatId (Just ExpenseSelectCategory) (CategorySelect catText) =
  handleExpenseCategorySelected botState telegramId chatId catText
-- Transfer source account selection
dispatchCallback botState telegramId chatId (Just TransferSelectSource) (AccountSelect cb)
  | cb.context == "transfer_src" = handleTransferSourceSelected botState telegramId chatId cb.accountId
-- Transfer target account selection
dispatchCallback botState telegramId chatId (Just (TransferSelectTarget srcId)) (AccountSelect cb)
  | cb.context == "transfer_tgt" = handleTransferTargetSelected botState telegramId chatId srcId cb.accountId
-- Fallback
dispatchCallback _botState _telegramId chatId _ _ =
  sendMsg chatId "Unexpected input. Use /cancel to start over."

-- -----------------------------------------------------------------------------
-- Individual Command Handlers
-- -----------------------------------------------------------------------------

-- | Handle /start command.
--
-- When the payload begins with @LINK_@, redeems the token and links the
-- Telegram identity to the issuing user. Otherwise falls back to the
-- existing find-or-create behaviour (Task 8 will replace the fallback
-- with the block-and-prompt flow).
handleStart :: TVar BotState -> TelegramIdentity -> Int64 -> Maybe Text -> AppM ()
handleStart _botState tgIdentity chatId args =
  case stripLinkPrefix args of
    Just tok -> do
      result <- redeemTelegramLinkCode (mkLinkCodeToken tok) tgIdentity
      case result of
        Right _uid ->
          sendMsg
            chatId
            "Done \8212 this Telegram is now linked to your account. Send /help to get started."
        Left err -> do
          logInfo $ "Telegram link redemption failed: " <> displayShow err
          sendMsg
            chatId
            "That link is no longer valid. Generate a new one in the web app under \"Link Telegram\"."
    Nothing -> handleStartNoPayload tgIdentity chatId

-- | Handle /start with no payload.
--
-- Looks up the Telegram identity in the read model:
--   - If found, greets the user (welcome back).
--   - If not found, prompts them to link via the web app or use /signup.
-- No user is created in this branch.
handleStartNoPayload :: TelegramIdentity -> Int64 -> AppM ()
handleStartNoPayload tgIdentity chatId = do
  rm <- view userReadModelL
  existing <- liftIO (getUserByTelegramId rm ((.id) tgIdentity))
  case existing of
    Just _ -> sendWelcome False chatId
    Nothing ->
      sendMsg chatId
        $ T.unlines
          [ "I don't recognise this Telegram account.",
            "",
            "To use it with your existing account, open the web app and tap \"Link Telegram\".",
            "To create a brand-new account, send /signup."
          ]

-- | Handle /signup command.
--
-- Explicitly creates a new Telegram-only user (or returns the existing one).
-- This is the entry point that was previously the default behaviour of /start.
handleSignup :: TVar BotState -> TelegramIdentity -> Int64 -> Maybe Text -> AppM ()
handleSignup _botState tgIdentity chatId _args = do
  result <- findOrCreateTelegramBotUser tgIdentity
  case result of
    Left err -> do
      logError $ "Telegram /signup failed: " <> displayShow err
      sendMsg chatId "Failed to create your account. Please try again later."
    Right (_userId, isNew) -> sendWelcome isNew chatId

-- | Send the welcome message to a chat.
sendWelcome :: Bool -> Int64 -> AppM ()
sendWelcome isNew chatId =
  sendMsg chatId
    $ T.unlines
    $ [ if isNew
          then "Welcome to HomeAccounting Bot!\n\nYour account has been created successfully."
          else "Welcome back to HomeAccounting Bot!",
        "",
        "Available commands:"
      ]
    ++ formatCommandList

-- | Strip the @LINK_@ prefix from the start payload.
--
-- Returns @Just tok@ when the argument is @Just \"LINK_<tok>\"@, and
-- @Nothing@ for any other payload (or no payload at all).
stripLinkPrefix :: Maybe Text -> Maybe Text
stripLinkPrefix Nothing = Nothing
stripLinkPrefix (Just t) = T.stripPrefix "LINK_" t

-- | Handle /login command.
handleLogin :: TVar BotState -> TelegramId -> Int64 -> Maybe Text -> AppM ()
handleLogin _botState _telegramId chatId _args = do
  sendMsg chatId "To link your Telegram account, please log in at our website and use the 'Link Telegram' option."

-- | Handle /accounts command.
--
-- Shows accounts with inline keyboard buttons for selection.
handleAccounts :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleAccounts _botState telegramId chatId = do
  maybeAccounts <- getUserRegularAccounts telegramId

  case maybeAccounts of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just accounts
      | null accounts -> sendMsg chatId "You don't have any accounts yet. Use /newaccount to create one."
      | otherwise ->
          sendMsgWithKeyboard chatId "Your accounts (tap to select):" (accountSelectionKeyboard accounts "select")

-- | Handle /newaccount command.
handleNewAccount :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleNewAccount botState telegramId chatId = do
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.insert telegramId CreateAccountEnterName s.conversations}
  sendMsg chatId "Enter a name for your new account:"

-- | Handle account name input during account creation.
handleCreateAccountName :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleCreateAccountName botState telegramId chatId name = do
  let trimmedName = T.strip name
  if T.null trimmedName
    then sendMsg chatId "Account name cannot be empty. Please enter a name:"
    else do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (CreateAccountSelectCurrency trimmedName) s.conversations}
      sendMsgWithKeyboard chatId "Select a currency for the account:" currencyKeyboard

-- | Handle /transfer command.
handleTransfer :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleTransfer botState telegramId chatId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "You don't have an account yet. Use /start to create one."
    Just accounts
      | length accounts < 2 -> sendMsg chatId "You need at least 2 accounts for a transfer. Use /newaccount to create more."
      | otherwise -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId TransferSelectSource s.conversations}
          sendMsgWithKeyboard chatId "Select source account:" (accountSelectionKeyboard accounts "transfer_src")

-- | Handle /income command.
handleIncome :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleIncome botState telegramId chatId = do
  selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
  case selected of
    Nothing -> sendMsg chatId "No account selected. Use /accounts to select one first."
    Just _ -> do
      entries <- getCategoryEntries telegramId incomeCategoryDictId
      case entries of
        Nothing -> sendMsg chatId "Could not load income categories. Please try again."
        Just cats -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId IncomeSelectCategory s.conversations}
          sendMsgWithKeyboard chatId "Select income category:" (categoryKeyboard cats)

-- | Handle /expense command.
handleExpense :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleExpense botState telegramId chatId = do
  selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
  case selected of
    Nothing -> sendMsg chatId "No account selected. Use /accounts to select one first."
    Just _ -> do
      entries <- getCategoryEntries telegramId expenseCategoryDictId
      case entries of
        Nothing -> sendMsg chatId "Could not load expense categories. Please try again."
        Just cats -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId ExpenseSelectCategory s.conversations}
          sendMsgWithKeyboard chatId "Select expense category:" (categoryKeyboard cats)

-- | Handle /transactions command.
--
-- Lists transactions from the last 30 days. If an account is currently
-- selected (via /accounts) the list is filtered to transactions that
-- touch that account; otherwise every transaction the user can see is
-- shown. The window is always [now - 30 days, now].
handleTransactions :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleTransactions botState telegramId chatId = do
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> sendMsg chatId "Could not find your user account. Use /start first."
    Just userId -> do
      now <- liftIO getCurrentTime
      let thirtyDays = 30 * 86400 :: Int
          fromDate = addUTCTime (fromIntegral (negate thirtyDays)) now
      selected <-
        atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
      let maybeAcctId = fst <$> selected
      case mkRange (Just fromDate) (Just now) of
        Left err -> do
          logError $ "Failed to build transactions query: " <> display err
          sendMsg chatId "Failed to list transactions. Please try again."
        Right dateRange -> do
          let filt = mkTransactionFilter maybeAcctId dateRange (Just (PendingKind :| [CompletedKind])) Nothing
          (total, results) <- TransactionService.listTransactions userId filt (Page 50 0)
          entryNames <- getDictionaryEntryNames telegramId
          let header = case selected of
                Just (_, name) -> "Transactions for " <> name <> " (last 30 days):"
                Nothing -> "Your transactions (last 30 days):"
          if null results
            then sendMsg chatId $ header <> "\n\nNo transactions found."
            else do
              let maxItems = 20
                  shown = take maxItems results
                  overflow = total - length shown
                  body = T.unlines $ map (formatTransactionLine entryNames) shown
                  suffix =
                    if overflow > 0
                      then "\n... and " <> tshow overflow <> " more."
                      else ""
              sendMsg chatId $ header <> "\n\n" <> body <> suffix

-- | Handle /cancel command.
handleCancel :: TVar BotState -> TelegramId -> Int64 -> AppM ()
handleCancel botState telegramId chatId = do
  hadConversation <- atomically $ do
    s <- readTVar botState
    let had = Map.member telegramId s.conversations
    writeTVar botState $ s {conversations = Map.delete telegramId s.conversations}
    return had
  if hadConversation
    then sendMsg chatId "Operation cancelled."
    else sendMsg chatId "Nothing to cancel."

-- | Handle /help command.
handleHelp :: TelegramId -> Int64 -> AppM ()
handleHelp _telegramId chatId = do
  sendMsg chatId
    $ T.unlines
    $ ["HomeAccounting Bot Commands:", ""]
    ++ formatCommandList

-- -----------------------------------------------------------------------------
-- Callback Handlers
-- -----------------------------------------------------------------------------

-- | Handle account selection callback from /accounts.
handleSelectCallback :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleSelectCallback botState telegramId chatId shortId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "Could not find your accounts."
    Just accounts ->
      case findAccountByShortId shortId accounts of
        Nothing -> sendMsg chatId "Account not found."
        Just (accountId, name, _balance) -> do
          atomically $ modifyTVar' botState $ \s ->
            s {selectedAccounts = Map.insert telegramId (accountId, name) s.selectedAccounts}
          sendMsg chatId $ "Selected: " <> name

-- | Handle currency selection during account creation.
handleCreateAccountCurrency :: TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleCreateAccountCurrency botState telegramId chatId name curText = do
  case parseCurrency curText of
    Left _ -> sendMsg chatId "Invalid currency. Please select from the keyboard."
    Right currency -> do
      -- Clear conversation state
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.delete telegramId s.conversations}

      -- Look up user
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId "Could not find your user account. Use /start first."
        Just userId -> do
          let createCmd =
                CreateAccount
                  { name = name,
                    initialBalance = unsafeMoney currency 0,
                    createdBy = userId,
                    accountType = Regular defaultCash,
                    overdraftLimit = Nothing
                  }
          result <- createAccount createCmd
          case result of
            Left err -> do
              logError $ "Failed to create account: " <> displayShow err
              sendMsg chatId "Failed to create account. Please try again."
            Right (accountId, _accountData) -> do
              -- Auto-select the new account
              atomically $ modifyTVar' botState $ \s ->
                s {selectedAccounts = Map.insert telegramId (accountId, name) s.selectedAccounts}
              sendMsg chatId $ "Account \"" <> name <> "\" created and selected! (" <> showCurrency currency <> ")"

-- -----------------------------------------------------------------------------
-- Income Flow Handlers
-- -----------------------------------------------------------------------------

-- | Handle income category selection callback.
handleIncomeCategorySelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleIncomeCategorySelected botState telegramId chatId catText =
  case parseCategoryUUID catText of
    Nothing -> sendMsg chatId "Invalid category. Please select from the keyboard."
    Just _ -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (IncomeEnterAmount catText) s.conversations}
      sendMsg chatId "Enter amount:"

-- | Handle income amount input.
handleIncomeAmount :: TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleIncomeAmount botState telegramId chatId cat text =
  case parseAmount text of
    Nothing -> sendMsg chatId "Invalid amount. Please enter a positive number:"
    Just amt -> do
      selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
      case selected of
        Nothing -> do
          clearConversation botState telegramId
          sendMsg chatId "No account selected. Use /accounts to select one first."
        Just (accountId, _name) -> do
          accountReadModel <- view accountReadModelL
          maybeAcc <- getAccount accountReadModel accountId
          case maybeAcc of
            Nothing -> do
              clearConversation botState telegramId
              sendMsg chatId "Selected account not found. Use /accounts to choose another."
            Just accData -> do
              let currency = moneyCurrency accData.balance
              case mkMoney currency (toRational amt) of
                Left _ -> sendMsg chatId "Failed to create money amount. Please try again."
                Right money -> do
                  atomically $ modifyTVar' botState $ \s ->
                    s {conversations = Map.insert telegramId (IncomeEnterDescription cat money) s.conversations}
                  sendMsg chatId "Enter description:"

-- | Handle income description input and execute the transaction.
handleIncomeDescription :: TVar BotState -> TelegramId -> Int64 -> Text -> Money -> Text -> AppM ()
handleIncomeDescription botState telegramId chatId cat money description = do
  clearConversation botState telegramId
  case parseCategoryUUID cat of
    Nothing -> sendMsg chatId "Invalid category. Operation cancelled."
    Just categoryEntryId -> do
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId "Could not find your user account. Use /start first."
        Just userId -> do
          selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
          case selected of
            Nothing -> sendMsg chatId "No account selected. Use /accounts to select one first."
            Just (accountId, _name) -> case mkAllocation categoryEntryId money of
              Left allocErr -> do
                logError $ "Income failed (invalid allocation): " <> displayShow allocErr
                sendMsg chatId $ "Income recording failed: " <> tshow allocErr
              Right alloc -> do
                let allocations = NE.singleton alloc
                result <- initiateIncome userId accountId money allocations Set.empty description Nothing
                case result of
                  Left err -> do
                    logError $ "Income failed: " <> displayShow err
                    sendMsg chatId $ "Income recording failed: " <> tshow err
                  Right (_txId, txData) -> case txData.status of
                    Failed failureReason -> do
                      logError $ "Income transfer failed: " <> display failureReason
                      sendMsg chatId $ "Income recording failed: " <> failureReason
                    _ ->
                      sendMsg chatId $ "Income recorded: " <> formatMoney money <> " " <> showCurrency (moneyCurrency money)

-- -----------------------------------------------------------------------------
-- Expense Flow Handlers
-- -----------------------------------------------------------------------------

-- | Handle expense category selection callback.
handleExpenseCategorySelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleExpenseCategorySelected botState telegramId chatId catText =
  case parseCategoryUUID catText of
    Nothing -> sendMsg chatId "Invalid category. Please select from the keyboard."
    Just _ -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (ExpenseEnterAmount catText) s.conversations}
      sendMsg chatId "Enter amount:"

-- | Handle expense amount input.
handleExpenseAmount :: TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleExpenseAmount botState telegramId chatId cat text =
  case parseAmount text of
    Nothing -> sendMsg chatId "Invalid amount. Please enter a positive number:"
    Just amt -> do
      selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
      case selected of
        Nothing -> do
          clearConversation botState telegramId
          sendMsg chatId "No account selected. Use /accounts to select one first."
        Just (accountId, _name) -> do
          accountReadModel <- view accountReadModelL
          maybeAcc <- getAccount accountReadModel accountId
          case maybeAcc of
            Nothing -> do
              clearConversation botState telegramId
              sendMsg chatId "Selected account not found. Use /accounts to choose another."
            Just accData -> do
              let currency = moneyCurrency accData.balance
              case mkMoney currency (toRational amt) of
                Left _ -> sendMsg chatId "Failed to create money amount. Please try again."
                Right money -> do
                  atomically $ modifyTVar' botState $ \s ->
                    s {conversations = Map.insert telegramId (ExpenseEnterDescription cat money) s.conversations}
                  sendMsg chatId "Enter description:"

-- | Handle expense description input and execute the transaction.
handleExpenseDescription :: TVar BotState -> TelegramId -> Int64 -> Text -> Money -> Text -> AppM ()
handleExpenseDescription botState telegramId chatId cat money description = do
  clearConversation botState telegramId
  case parseCategoryUUID cat of
    Nothing -> sendMsg chatId "Invalid category. Operation cancelled."
    Just categoryEntryId -> do
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId "Could not find your user account. Use /start first."
        Just userId -> do
          selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
          case selected of
            Nothing -> sendMsg chatId "No account selected. Use /accounts to select one first."
            Just (accountId, _name) -> case mkAllocation categoryEntryId money of
              Left allocErr -> do
                logError $ "Expense failed (invalid allocation): " <> displayShow allocErr
                sendMsg chatId $ "Expense recording failed: " <> tshow allocErr
              Right alloc -> do
                let allocations = NE.singleton alloc
                result <- initiateExpense userId accountId money allocations Set.empty description Nothing
                case result of
                  Left err -> do
                    logError $ "Expense failed: " <> displayShow err
                    sendMsg chatId $ "Expense recording failed: " <> tshow err
                  Right (_txId, txData) -> case txData.status of
                    Failed failureReason -> do
                      logError $ "Expense transfer failed: " <> display failureReason
                      sendMsg chatId $ "Expense recording failed: " <> failureReason
                    _ ->
                      sendMsg chatId $ "Expense recorded: " <> formatMoney money <> " " <> showCurrency (moneyCurrency money)

-- -----------------------------------------------------------------------------
-- Transfer Flow Handlers
-- -----------------------------------------------------------------------------

-- | Handle transfer source account selection.
handleTransferSourceSelected :: TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleTransferSourceSelected botState telegramId chatId shortId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "Could not find your accounts."
    Just accounts ->
      case findAccountByShortId shortId accounts of
        Nothing -> sendMsg chatId "Account not found."
        Just (srcAccountId, _name, _balance) -> do
          let otherAccounts = filter (\(accId, _, _) -> accId /= srcAccountId) accounts
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId (TransferSelectTarget srcAccountId) s.conversations}
          sendMsgWithKeyboard chatId "Select target account:" (accountSelectionKeyboard otherAccounts "transfer_tgt")

-- | Handle transfer target account selection.
handleTransferTargetSelected :: TVar BotState -> TelegramId -> Int64 -> AccountId -> Text -> AppM ()
handleTransferTargetSelected botState telegramId chatId srcId shortId = do
  maybeAccounts <- getUserRegularAccounts telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId "Could not find your accounts."
    Just accounts ->
      case findAccountByShortId shortId accounts of
        Nothing -> sendMsg chatId "Account not found."
        Just (tgtAccountId, _name, _balance) -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId (TransferEnterAmount srcId tgtAccountId) s.conversations}
          sendMsg chatId "Enter amount:"

-- | Handle transfer amount input.
handleTransferAmount :: TVar BotState -> TelegramId -> Int64 -> AccountId -> AccountId -> Text -> AppM ()
handleTransferAmount botState telegramId chatId srcId tgtId text =
  case parseAmount text of
    Nothing -> sendMsg chatId "Invalid amount. Please enter a positive number:"
    Just amt -> do
      accountReadModel <- view accountReadModelL
      maybeAcc <- getAccount accountReadModel srcId
      case maybeAcc of
        Nothing -> do
          clearConversation botState telegramId
          sendMsg chatId "Source account not found. Use /transfer to start over."
        Just accData -> do
          let currency = moneyCurrency accData.balance
          case mkMoney currency (toRational amt) of
            Left _ -> sendMsg chatId "Failed to create money amount. Please try again."
            Right money -> do
              atomically $ modifyTVar' botState $ \s ->
                s {conversations = Map.insert telegramId (TransferEnterDescription srcId tgtId money) s.conversations}
              sendMsg chatId "Enter description:"

-- | Handle transfer description input and execute the transaction.
handleTransferDescription :: TVar BotState -> TelegramId -> Int64 -> AccountId -> AccountId -> Money -> Text -> AppM ()
handleTransferDescription botState telegramId chatId srcId tgtId money description = do
  clearConversation botState telegramId
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> sendMsg chatId "Could not find your user account. Use /start first."
    Just userId -> do
      result <- initiateTransfer userId srcId tgtId money Set.empty description Nothing Nothing
      case result of
        Left err -> do
          logError $ "Transfer failed: " <> displayShow err
          sendMsg chatId $ "Transfer failed: " <> tshow err
        Right (_txId, txData) -> case txData.status of
          Failed failureReason -> do
            logError $ "Transfer failed: " <> display failureReason
            sendMsg chatId $ "Transfer failed: " <> failureReason
          _ ->
            sendMsg chatId $ "Transfer completed: " <> formatMoney money <> " " <> showCurrency (moneyCurrency money)

-- -----------------------------------------------------------------------------
-- Category Parsers
-- -----------------------------------------------------------------------------

-- | Parse a category UUID from callback text into a DictionaryEntryId.
parseCategoryUUID :: Text -> Maybe DictionaryEntryId
parseCategoryUUID t = case UUID.fromString (T.unpack t) of
  Nothing -> Nothing
  Just uuid -> case mkDictionaryEntryId uuid of
    Left _ -> Nothing
    Right entryId -> Just entryId

-- | Parse a positive amount from user text input.
parseAmount :: Text -> Maybe Double
parseAmount text =
  case readMaybe (T.unpack (T.strip text)) of
    Just amt | amt > 0 -> Just amt
    _ -> Nothing

-- | Clear conversation state for a user.
clearConversation :: TVar BotState -> TelegramId -> AppM ()
clearConversation botState telegramId =
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.delete telegramId s.conversations}

-- -----------------------------------------------------------------------------
-- Configuration Lookup Helpers
-- -----------------------------------------------------------------------------

-- | Get category entries from the user's configuration for a given dictionary.
--
-- Looks up the user, their configuration, and returns the entries for the
-- specified dictionary ID as a list of (DictionaryEntryId, EntryName) pairs.
getCategoryEntries :: TelegramId -> DictionaryId -> AppM (Maybe [(DictionaryEntryId, EntryName)])
getCategoryEntries telegramId dictId = do
  userRM <- view userReadModelL
  maybeUser <- getUserByTelegramId userRM telegramId
  case maybeUser of
    Nothing -> return Nothing
    Just (_, userData) -> do
      configRM <- view configurationReadModelL
      maybeConfig <- liftIO $ getConfiguration configRM userData.configurationId
      case maybeConfig of
        Nothing -> return Nothing
        Just configData ->
          case Map.lookup dictId configData.dictionaries of
            Nothing -> return $ Just []
            Just dictData -> return $ Just $ Map.toList dictData.entries

-- | Build a flat DictionaryEntryId -> name lookup from the user's
--   configuration, merging the income, expense, and labels dictionaries
--   so a single map resolves both categories (on Income/Expense
--   transfer types) and labels (the per-transaction label set).
--   Returns an empty map when the user or configuration can't be
--   resolved so callers can proceed with the plain type label.
getDictionaryEntryNames :: TelegramId -> AppM (Map DictionaryEntryId Text)
getDictionaryEntryNames telegramId = do
  userRM <- view userReadModelL
  maybeUser <- getUserByTelegramId userRM telegramId
  case maybeUser of
    Nothing -> return Map.empty
    Just (_, userData) -> do
      configRM <- view configurationReadModelL
      maybeConfig <- liftIO $ getConfiguration configRM userData.configurationId
      return $ case maybeConfig of
        Nothing -> Map.empty
        Just configData ->
          let entriesFor dictId =
                maybe Map.empty (.entries) (Map.lookup dictId configData.dictionaries)
           in fmap unEntryName
                $ entriesFor incomeCategoryDictId
                <> entriesFor expenseCategoryDictId
                <> entriesFor labelsDictId

-- -----------------------------------------------------------------------------
-- User/Account Lookup Helpers
-- -----------------------------------------------------------------------------

-- | Look up the UserId for a Telegram user.
getUserIdForTelegram :: TelegramId -> AppM (Maybe UserId)
getUserIdForTelegram telegramId = do
  userReadModel <- view userReadModelL
  maybeUser <- getUserByTelegramId userReadModel telegramId
  return $ fmap fst maybeUser

-- | Get a user's regular (non-External) accounts as (AccountId, name, balance) triples.
-- Returns Nothing if the Telegram user is not found, Just accounts otherwise.
getUserRegularAccounts :: TelegramId -> AppM (Maybe [(AccountId, Text, Money)])
getUserRegularAccounts telegramId = do
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> return Nothing
    Just userId -> do
      accountReadModel <- view accountReadModelL
      accounts <- AccountRM.getUserRegularAccounts accountReadModel userId
      return $ Just accounts

-- | Find an account by short ID prefix (first 8 chars of UUID).
findAccountByShortId :: Text -> [(AccountId, Text, Money)] -> Maybe (AccountId, Text, Money)
findAccountByShortId shortId accounts =
  case filter matchesShortId accounts of
    [match] -> Just match
    _ -> Nothing
  where
    matchesShortId (accountId, _name, _balance) =
      let fullId = T.pack $ UUID.toString $ unAccountId accountId
       in T.take 8 fullId == shortId

-- -----------------------------------------------------------------------------
-- Telegram API Helpers
-- -----------------------------------------------------------------------------

-- | Convert our InlineKeyboard to telegram-bot-api InlineKeyboardMarkup.
toTgKeyboard :: InlineKeyboard -> TG.InlineKeyboardMarkup
toTgKeyboard keyboard =
  TG.InlineKeyboardMarkup
    { TG.inlineKeyboardMarkupInlineKeyboard = map (map toTgButton) keyboard.rows
    }
  where
    toTgButton btn =
      TG.InlineKeyboardButton
        { TG.inlineKeyboardButtonText = btn.text,
          TG.inlineKeyboardButtonUrl = Nothing,
          TG.inlineKeyboardButtonCallbackData = Just btn.callbackData,
          TG.inlineKeyboardButtonWebApp = Nothing,
          TG.inlineKeyboardButtonLoginUrl = Nothing,
          TG.inlineKeyboardButtonSwitchInlineQuery = Nothing,
          TG.inlineKeyboardButtonSwitchInlineQueryCurrentChat = Nothing,
          TG.inlineKeyboardButtonSwitchInlineQueryChosenChat = Nothing,
          TG.inlineKeyboardButtonCallbackGame = Nothing,
          TG.inlineKeyboardButtonPay = Nothing
        }

-- | Send a message with inline keyboard.
sendMsgWithKeyboard :: Int64 -> Text -> InlineKeyboard -> AppM ()
sendMsgWithKeyboard chatId text keyboard = withClient $ \clientEnv -> do
  let someChatId = TG.SomeChatId (TG.ChatId (fromIntegral chatId))
      tgKeyboard = toTgKeyboard keyboard
  result <- sendMessageWithKeyboard clientEnv someChatId text tgKeyboard
  case result of
    Left err -> logError $ "Failed to send message: " <> displayShow err
    Right _ -> return ()

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
