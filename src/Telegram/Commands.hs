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
    handleClearSelection,
    handlePromptCommand,
    handleNewAccount,
    handleTransfer,
    handleIncome,
    handleExpense,
    handleTransactions,
    handleCancel,
    handleHelp,
    handlePromptText,

    -- * Helpers
    sendMsg,
    sendMsgWithKeyboard,
    toTgKeyboard,
    getUserIdForTelegram,
    accessibleAccountsForTelegram,
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
import Application.ReadModels.Configuration (ConfigurationData (..), dictionaryItems, getConfiguration)
import Application.ReadModels.Transaction (TransactionData (..), mkTransactionFilter)
import Application.ReadModels.User
  ( UserData (..),
    getUserByTelegramId,
  )
import Application.Services.AccountService (createAccount)
import Application.Services.AuthService (findOrCreateTelegramBotUser, redeemTelegramLinkCode)
import Application.Services.ConfigurationService (expenseCategoryDictKind, incomeCategoryDictKind, labelsDictKind)
import Application.Services.Prompt.Types
  ( FailedTransaction (..),
    PromptError (..),
    PromptResult (..),
    RecordedTransaction (..),
  )
import qualified Application.Services.PromptService as PromptService
import Application.Services.TransactionService (initiateExpense, initiateIncome, initiateTransfer)
import qualified Application.Services.TransactionService as TransactionService
import qualified Data.Set as Set
import Data.Time (addUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Configuration.Dictionary (DictionaryKind)
import Domain.Core.Errors (renderDomainError)
import Domain.Core.Page (Page (..))
import Domain.Core.Range (mkRange)
import Domain.Core.Types
  ( AccountId,
    AccountType (..),
    DictionaryEntryId,
    EntryName,
    Money,
    TelegramId (..),
    TelegramIdentity (..),
    UserId,
    defaultCash,
    mkAllocation,
    mkDictionaryEntryId,
    mkExpenseAllocations,
    mkIncomeAllocations,
    mkMoney,
    moneyCurrency,
    parseCurrency,
    unAccountId,
    unEntryName,
    unsafeMoney,
  )
import Domain.Localization.Language (Language (..))
import Domain.Transaction.Projection (StatusKind (..), TransactionStatus (..))
import Infrastructure.App (AppM, HasTelegramClient (..), runDb)
import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Servant.Client (ClientEnv)
import Telegram.Api (answerCallback, registerChatCommands, sendMessageWithKeyboard, sendTextMessage)
import qualified Telegram.Bot.API as TG
import Telegram.Formatting
  ( formatCommandList,
    formatRecordedTransaction,
    formatTransactionLine,
    showCurrency,
  )
import Telegram.I18n
  ( AccountStrings (..),
    CommonStrings (..),
    ErrorStrings (..),
    PromptStrings (..),
    TelegramStrings (..),
    TransactionStrings (..),
    telegramStrings,
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
  lang <- languageForTelegram telegramId
  syncChatCommandMenu botState chatId lang
  case cmd of
    "/start" -> handleStart botState tgIdentity chatId args
    "/signup" -> handleSignup botState tgIdentity chatId args
    "/login" -> handleLogin lang botState telegramId chatId args
    "/accounts" -> handleAccounts lang botState telegramId chatId
    "/prompt" -> handlePromptCommand lang botState telegramId chatId args
    "/newaccount" -> handleNewAccount lang botState telegramId chatId
    "/transfer" -> handleTransfer lang botState telegramId chatId
    "/income" -> handleIncome lang botState telegramId chatId
    "/expense" -> handleExpense lang botState telegramId chatId
    "/transactions" -> handleTransactions lang botState telegramId chatId
    "/cancel" -> handleCancel lang botState telegramId chatId
    "/help" -> handleHelp lang telegramId chatId
    _ -> do
      let t = telegramStrings lang
      sendMsg chatId (t.common.unknownCommand cmd)

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
  lang <- languageForTelegram telegramId
  state <- atomically $ Map.lookup telegramId . (.conversations) <$> readTVar botState
  case state of
    -- No active conversation: treat any free text as a natural-language prompt
    -- (issue #28). The user's currently-selected account, if any, is applied.
    Nothing ->
      handlePromptText lang botState telegramId chatId text
    Just CreateAccountEnterName ->
      handleCreateAccountName lang botState telegramId chatId text
    Just (IncomeEnterAmount cat) ->
      handleIncomeAmount lang botState telegramId chatId cat text
    Just (IncomeEnterDescription cat money) ->
      handleIncomeDescription lang botState telegramId chatId cat money text
    Just (ExpenseEnterAmount cat) ->
      handleExpenseAmount lang botState telegramId chatId cat text
    Just (ExpenseEnterDescription cat money) ->
      handleExpenseDescription lang botState telegramId chatId cat money text
    Just (TransferEnterAmount srcId tgtId) ->
      handleTransferAmount lang botState telegramId chatId srcId tgtId text
    Just (TransferEnterDescription srcId tgtId money) ->
      handleTransferDescription lang botState telegramId chatId srcId tgtId money text
    -- A keyboard-driven step (selecting an account/category/currency) is in
    -- progress: a stray text message isn't a prompt, so nudge instead.
    Just _ ->
      sendMsg chatId (telegramStrings lang).common.tapButtonOrCancel

-- -----------------------------------------------------------------------------
-- Callback Query Handler
-- -----------------------------------------------------------------------------

-- | Handle an inline keyboard button press.
handleCallbackQuery :: TVar BotState -> TelegramId -> Int64 -> TG.CallbackQueryId -> Text -> AppM ()
handleCallbackQuery botState telegramId chatId callbackQueryId rawData = do
  withClient $ \clientEnv -> void $ answerCallback clientEnv callbackQueryId Nothing
  lang <- languageForTelegram telegramId
  case parseCallbackData rawData of
    Nothing -> sendMsg chatId (telegramStrings lang).errors.invalidButtonData
    Just Cancel -> handleCancel lang botState telegramId chatId
    Just ClearSelection -> handleClearSelection lang botState telegramId chatId
    Just cbData -> do
      state <- atomically $ Map.lookup telegramId . (.conversations) <$> readTVar botState
      dispatchCallback lang botState telegramId chatId state cbData

-- | Parse callback data from a raw text string.
parseCallbackData :: Text -> Maybe CallbackData
parseCallbackData "cancel" = Just Cancel
parseCallbackData "confirm" = Just Confirm
parseCallbackData "unselect" = Just ClearSelection
parseCallbackData t
  | "acc:" `T.isPrefixOf` t = case T.split (== ':') t of
      ["acc", accId, ctx] -> Just $ AccountSelect (AccountSelectionCallback accId ctx)
      _ -> Nothing
  | "cat:" `T.isPrefixOf` t = Just $ CategorySelect (T.drop 4 t)
  | "cur:" `T.isPrefixOf` t = Just $ CurrencySelect (T.drop 4 t)
  | otherwise = Nothing

-- | Dispatch a callback to the appropriate handler based on state.
dispatchCallback :: Language -> TVar BotState -> TelegramId -> Int64 -> Maybe ConversationState -> CallbackData -> AppM ()
-- /accounts selection callback
dispatchCallback lang botState telegramId chatId _ (AccountSelect cb)
  | cb.context == "select" = handleSelectCallback lang botState telegramId chatId cb.accountId
-- Account creation currency selection
dispatchCallback lang botState telegramId chatId (Just (CreateAccountSelectCurrency name)) (CurrencySelect curText) =
  handleCreateAccountCurrency lang botState telegramId chatId name curText
-- Income category selection
dispatchCallback lang botState telegramId chatId (Just IncomeSelectCategory) (CategorySelect catText) =
  handleIncomeCategorySelected lang botState telegramId chatId catText
-- Expense category selection
dispatchCallback lang botState telegramId chatId (Just ExpenseSelectCategory) (CategorySelect catText) =
  handleExpenseCategorySelected lang botState telegramId chatId catText
-- Transfer source account selection
dispatchCallback lang botState telegramId chatId (Just TransferSelectSource) (AccountSelect cb)
  | cb.context == "transfer_src" = handleTransferSourceSelected lang botState telegramId chatId cb.accountId
-- Transfer target account selection
dispatchCallback lang botState telegramId chatId (Just (TransferSelectTarget srcId)) (AccountSelect cb)
  | cb.context == "transfer_tgt" = handleTransferTargetSelected lang botState telegramId chatId srcId cb.accountId
-- Fallback
dispatchCallback lang _botState _telegramId chatId _ _ =
  sendMsg chatId (telegramStrings lang).errors.unexpectedInput

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
        Right _uid -> do
          -- The identity is now linked, so honour the account's stored language.
          lang <- languageForTelegram ((.id) tgIdentity)
          sendMsg chatId (telegramStrings lang).common.linkedSuccess
        Left err -> do
          logInfo $ "Telegram link redemption failed: " <> displayShow err
          -- Not linked by this token; falls back to En for an unknown identity.
          lang <- languageForTelegram ((.id) tgIdentity)
          sendMsg chatId (telegramStrings lang).common.linkInvalid
    Nothing -> handleStartNoPayload tgIdentity chatId

-- | Handle /start with no payload.
--
-- Looks up the Telegram identity in the read model:
--   - If found, greets the user (welcome back).
--   - If not found, prompts them to link via the web app or use /signup.
-- No user is created in this branch.
handleStartNoPayload :: TelegramIdentity -> Int64 -> AppM ()
handleStartNoPayload tgIdentity chatId = do
  existing <- runDb (getUserByTelegramId ((.id) tgIdentity))
  case existing of
    Just _ -> do
      lang <- languageForTelegram ((.id) tgIdentity)
      sendWelcome lang False chatId
    Nothing ->
      sendMsg chatId (telegramStrings En).common.unrecognisedAccount

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
      sendMsg chatId (telegramStrings En).errors.failedToCreateYourAccount
    Right (_userId, isNew) -> do
      lang <- languageForTelegram ((.id) tgIdentity)
      sendWelcome lang isNew chatId

-- | Send the welcome message to a chat, in the account's language.
--
-- A freshly-created account has no language preference yet, so it resolves to the
-- 'En' default; an already-linked account is greeted in its stored language.
sendWelcome :: Language -> Bool -> Int64 -> AppM ()
sendWelcome lang isNew chatId =
  let t = telegramStrings lang
   in sendMsg chatId
        $ T.unlines
        $ [ if isNew then t.common.welcomeNew else t.common.welcomeBack,
            "",
            t.common.welcomeTip,
            "",
            t.common.availableCommands
          ]
        ++ formatCommandList lang

-- | Strip the @LINK_@ prefix from the start payload.
--
-- Returns @Just tok@ when the argument is @Just \"LINK_<tok>\"@, and
-- @Nothing@ for any other payload (or no payload at all).
stripLinkPrefix :: Maybe Text -> Maybe Text
stripLinkPrefix Nothing = Nothing
stripLinkPrefix (Just t) = T.stripPrefix "LINK_" t

-- | Handle /login command.
handleLogin :: Language -> TVar BotState -> TelegramId -> Int64 -> Maybe Text -> AppM ()
handleLogin lang _botState _telegramId chatId _args = do
  sendMsg chatId (telegramStrings lang).common.loginPrompt

-- | Handle /accounts command.
--
-- Shows accounts with inline keyboard buttons for selection. A header line
-- surfaces the currently-selected account (used by prompts and /transactions),
-- the active account is marked with a check, and a Clear-selection button is
-- offered when something is selected.
handleAccounts :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleAccounts lang botState telegramId chatId = do
  let t = telegramStrings lang
  maybeAccounts <- accessibleAccountsForTelegram telegramId
  selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
  case maybeAccounts of
    Nothing -> sendMsg chatId t.accounts.noAccountYet
    Just accounts
      | null accounts -> sendMsg chatId t.accounts.noAccountsYet
      | otherwise -> do
          let header = case selected of
                Just (_, name) -> t.accounts.currentlySelected name
                Nothing -> t.accounts.noAccountSelectedHeader
              body = header <> "\n\n" <> t.accounts.yourAccountsPrompt
          sendMsgWithKeyboard chatId body (accountSelectionKeyboard lang accounts (fst <$> selected) "select")

-- | Handle /newaccount command.
handleNewAccount :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleNewAccount lang botState telegramId chatId = do
  atomically $ modifyTVar' botState $ \s ->
    s {conversations = Map.insert telegramId CreateAccountEnterName s.conversations}
  sendMsg chatId (telegramStrings lang).accounts.enterAccountName

-- | Handle account name input during account creation.
handleCreateAccountName :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleCreateAccountName lang botState telegramId chatId name = do
  let trimmedName = T.strip name
  if T.null trimmedName
    then sendMsg chatId (telegramStrings lang).accounts.accountNameEmpty
    else do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (CreateAccountSelectCurrency trimmedName) s.conversations}
      sendMsgWithKeyboard chatId (telegramStrings lang).accounts.selectCurrency (currencyKeyboard lang)

-- | Handle /transfer command.
handleTransfer :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleTransfer lang botState telegramId chatId = do
  let t = telegramStrings lang
  maybeAccounts <- accessibleAccountsForTelegram telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId t.accounts.noAccountYet
    Just accounts
      | length accounts < 2 -> sendMsg chatId t.transactions.needTwoAccounts
      | otherwise -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId TransferSelectSource s.conversations}
          sendMsgWithKeyboard chatId t.transactions.selectSourceAccount (accountSelectionKeyboard lang accounts Nothing "transfer_src")

-- | Handle /income command.
handleIncome :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleIncome lang botState telegramId chatId = do
  let t = telegramStrings lang
  selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
  case selected of
    Nothing -> sendMsg chatId t.transactions.noAccountSelectedUseAccounts
    Just _ -> do
      entries <- getCategoryEntries telegramId incomeCategoryDictKind
      case entries of
        Nothing -> sendMsg chatId t.transactions.couldNotLoadIncomeCategories
        Just cats -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId IncomeSelectCategory s.conversations}
          sendMsgWithKeyboard chatId t.transactions.selectIncomeCategory (categoryKeyboard lang cats)

-- | Handle /expense command.
handleExpense :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleExpense lang botState telegramId chatId = do
  let t = telegramStrings lang
  selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
  case selected of
    Nothing -> sendMsg chatId t.transactions.noAccountSelectedUseAccounts
    Just _ -> do
      entries <- getCategoryEntries telegramId expenseCategoryDictKind
      case entries of
        Nothing -> sendMsg chatId t.transactions.couldNotLoadExpenseCategories
        Just cats -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId ExpenseSelectCategory s.conversations}
          sendMsgWithKeyboard chatId t.transactions.selectExpenseCategory (categoryKeyboard lang cats)

-- | Handle /transactions command.
--
-- Lists transactions from the last 30 days. If an account is currently
-- selected (via /accounts) the list is filtered to transactions that
-- touch that account; otherwise every transaction the user can see is
-- shown. The window is always [now - 30 days, now].
handleTransactions :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleTransactions lang botState telegramId chatId = do
  let t = telegramStrings lang
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> sendMsg chatId t.errors.couldNotFindUserAccount
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
          sendMsg chatId t.errors.failedToListTransactions
        Right dateRange -> do
          let filt = mkTransactionFilter maybeAcctId dateRange (Just (PendingKind :| [CompletedKind])) Nothing
          (total, results) <- TransactionService.listTransactions userId filt (Page 50 0)
          entryNames <- getDictionaryEntryNames telegramId
          let header = case selected of
                Just (_, name) -> t.transactions.transactionsForHeader name
                Nothing -> t.transactions.yourTransactionsHeader
          if null results
            then sendMsg chatId $ header <> "\n\n" <> t.transactions.noTransactionsFound
            else do
              let maxItems = 20
                  shown = take maxItems results
                  overflow = total - length shown
                  body = T.unlines $ map (formatTransactionLine lang entryNames) shown
                  suffix =
                    if overflow > 0
                      then t.transactions.andMore overflow
                      else ""
              sendMsg chatId $ header <> "\n\n" <> body <> suffix

-- | Handle /cancel command.
handleCancel :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleCancel lang botState telegramId chatId = do
  hadConversation <- atomically $ do
    s <- readTVar botState
    let had = Map.member telegramId s.conversations
    writeTVar botState $ s {conversations = Map.delete telegramId s.conversations}
    return had
  if hadConversation
    then sendMsg chatId (telegramStrings lang).common.cancelled
    else sendMsg chatId (telegramStrings lang).common.nothingToCancel

-- | Handle /help command.
handleHelp :: Language -> TelegramId -> Int64 -> AppM ()
handleHelp lang _telegramId chatId = do
  let t = telegramStrings lang
  sendMsg chatId
    $ T.unlines
    $ [t.common.helpHeader, ""]
    ++ formatCommandList lang

-- -----------------------------------------------------------------------------
-- Prompt (natural language) — issue #28
-- -----------------------------------------------------------------------------

-- | Handle @/prompt [text]@.
--
-- With inline text (@/prompt coffee 4.50@) the transaction is recorded
-- immediately. With no argument we explain the feature; because 'handleMessage'
-- already routes any idle free-text message through 'handlePromptText', the user can
-- simply type their next message and it will be recorded.
handlePromptCommand :: Language -> TVar BotState -> TelegramId -> Int64 -> Maybe Text -> AppM ()
handlePromptCommand lang botState telegramId chatId args =
  case T.strip <$> args of
    Just t | not (T.null t) -> handlePromptText lang botState telegramId chatId t
    _ ->
      sendMsg chatId (telegramStrings lang).prompt.promptUsage

-- | Interpret free text as a transaction via the natural-language prompt
-- pipeline and reply with the outcome.
--
-- The user's currently-selected account (via /accounts), if any, is passed
-- through so it fills the transaction's primary account slot; otherwise the
-- account is resolved from the text by the existing rules (issue #28).
handlePromptText :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handlePromptText lang botState telegramId chatId text = do
  let t = telegramStrings lang
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> sendMsg chatId t.prompt.couldntFindAccountStart
    Just userId -> do
      selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
      result <- PromptService.handlePrompt userId (fst <$> selected) text
      case result of
        Right (TransactionsRecorded succeeded failed) -> do
          forM_ succeeded $ \r -> replyRecordedTransaction lang telegramId chatId r.tx
          unless (null failed)
            $ sendMsg chatId
            $ t.prompt.couldntRecordHeader
            <> T.unlines [t.prompt.failedTransactionLine (f.index + 1) f.reason | f <- failed]
        Left (PromptDomainError de) ->
          sendMsg chatId (t.prompt.domainError (renderDomainError de))
        Left PromptFeatureDisabled ->
          sendMsg chatId t.prompt.featureDisabled
        Left (PromptUpstreamError _) ->
          sendMsg chatId t.prompt.upstreamError

-- -----------------------------------------------------------------------------
-- Callback Handlers
-- -----------------------------------------------------------------------------

-- | Clear the user's selected account. Works regardless of any in-flight
-- conversation, so it is dispatched early alongside /cancel.
handleClearSelection :: Language -> TVar BotState -> TelegramId -> Int64 -> AppM ()
handleClearSelection lang botState telegramId chatId = do
  had <- atomically $ do
    s <- readTVar botState
    let existed = Map.member telegramId s.selectedAccounts
    writeTVar botState $ s {selectedAccounts = Map.delete telegramId s.selectedAccounts}
    return existed
  if had
    then sendMsg chatId (telegramStrings lang).common.selectionCleared
    else sendMsg chatId (telegramStrings lang).common.noAccountWasSelected

-- | Handle account selection callback from /accounts.
handleSelectCallback :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleSelectCallback lang botState telegramId chatId shortId = do
  let t = telegramStrings lang
  maybeAccounts <- accessibleAccountsForTelegram telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId t.errors.couldNotFindAccounts
    Just accounts ->
      case findAccountByShortId shortId accounts of
        Nothing -> sendMsg chatId t.errors.accountNotFound
        Just (accountId, name, _balance) -> do
          atomically $ modifyTVar' botState $ \s ->
            s {selectedAccounts = Map.insert telegramId (accountId, name) s.selectedAccounts}
          sendMsg chatId (t.accounts.selected name)

-- | Handle currency selection during account creation.
handleCreateAccountCurrency :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleCreateAccountCurrency lang botState telegramId chatId name curText = do
  let t = telegramStrings lang
  case parseCurrency curText of
    Left _ -> sendMsg chatId t.accounts.invalidCurrency
    Right currency -> do
      -- Clear conversation state
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.delete telegramId s.conversations}

      -- Look up user
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId t.errors.couldNotFindUserAccount
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
              sendMsg chatId t.accounts.failedToCreateAccount
            Right (accountId, _accountData) -> do
              -- Auto-select the new account
              atomically $ modifyTVar' botState $ \s ->
                s {selectedAccounts = Map.insert telegramId (accountId, name) s.selectedAccounts}
              sendMsg chatId $ t.accounts.createdSelected name (showCurrency currency)

-- -----------------------------------------------------------------------------
-- Income Flow Handlers
-- -----------------------------------------------------------------------------

-- | Handle income category selection callback.
handleIncomeCategorySelected :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleIncomeCategorySelected lang botState telegramId chatId catText =
  case parseCategoryUUID catText of
    Nothing -> sendMsg chatId (telegramStrings lang).transactions.invalidCategorySelectKeyboard
    Just _ -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (IncomeEnterAmount catText) s.conversations}
      sendMsg chatId (telegramStrings lang).transactions.enterAmount

-- | Handle income amount input.
handleIncomeAmount :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleIncomeAmount lang botState telegramId chatId cat text =
  let t = telegramStrings lang
   in case parseAmount text of
        Nothing -> sendMsg chatId t.transactions.invalidAmount
        Just amt -> do
          selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
          case selected of
            Nothing -> do
              clearConversation botState telegramId
              sendMsg chatId t.transactions.noAccountSelectedUseAccounts
            Just (accountId, _name) -> do
              maybeAcc <- runDb (getAccount accountId)
              case maybeAcc of
                Nothing -> do
                  clearConversation botState telegramId
                  sendMsg chatId t.accounts.selectedAccountNotFound
                Just accData -> do
                  let currency = moneyCurrency accData.balance
                  case mkMoney currency (toRational amt) of
                    Left _ -> sendMsg chatId t.transactions.failedToCreateMoney
                    Right money -> do
                      atomically $ modifyTVar' botState $ \s ->
                        s {conversations = Map.insert telegramId (IncomeEnterDescription cat money) s.conversations}
                      sendMsg chatId t.transactions.enterDescription

-- | Handle income description input and execute the transaction.
handleIncomeDescription :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> Money -> Text -> AppM ()
handleIncomeDescription lang botState telegramId chatId cat money description = do
  let t = telegramStrings lang
  clearConversation botState telegramId
  case parseCategoryUUID cat of
    Nothing -> sendMsg chatId t.transactions.invalidCategoryCancelled
    Just categoryEntryId -> do
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId t.errors.couldNotFindUserAccount
        Just userId -> do
          selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
          case selected of
            Nothing -> sendMsg chatId t.transactions.noAccountSelectedUseAccounts
            Just (accountId, _name) -> case mkAllocation categoryEntryId money Nothing of
              Left allocErr -> do
                logError $ "Income failed (invalid allocation): " <> displayShow allocErr
                sendMsg chatId $ t.transactions.incomeRecordingFailed (tshow allocErr)
              Right alloc -> do
                let allocations = mkIncomeAllocations (alloc :| [])
                result <- initiateIncome userId accountId money allocations Set.empty description Nothing Nothing Nothing
                case result of
                  Left err -> do
                    logError $ "Income failed: " <> displayShow err
                    sendMsg chatId $ t.transactions.incomeRecordingFailed (tshow err)
                  Right (_txId, txData) -> case txData.status of
                    Failed failureReason -> do
                      logError $ "Income transfer failed: " <> display failureReason
                      sendMsg chatId $ t.transactions.incomeRecordingFailed failureReason
                    _ ->
                      replyRecordedTransaction lang telegramId chatId txData

-- -----------------------------------------------------------------------------
-- Expense Flow Handlers
-- -----------------------------------------------------------------------------

-- | Handle expense category selection callback.
handleExpenseCategorySelected :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleExpenseCategorySelected lang botState telegramId chatId catText =
  case parseCategoryUUID catText of
    Nothing -> sendMsg chatId (telegramStrings lang).transactions.invalidCategorySelectKeyboard
    Just _ -> do
      atomically $ modifyTVar' botState $ \s ->
        s {conversations = Map.insert telegramId (ExpenseEnterAmount catText) s.conversations}
      sendMsg chatId (telegramStrings lang).transactions.enterAmount

-- | Handle expense amount input.
handleExpenseAmount :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> Text -> AppM ()
handleExpenseAmount lang botState telegramId chatId cat text =
  let t = telegramStrings lang
   in case parseAmount text of
        Nothing -> sendMsg chatId t.transactions.invalidAmount
        Just amt -> do
          selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
          case selected of
            Nothing -> do
              clearConversation botState telegramId
              sendMsg chatId t.transactions.noAccountSelectedUseAccounts
            Just (accountId, _name) -> do
              maybeAcc <- runDb (getAccount accountId)
              case maybeAcc of
                Nothing -> do
                  clearConversation botState telegramId
                  sendMsg chatId t.accounts.selectedAccountNotFound
                Just accData -> do
                  let currency = moneyCurrency accData.balance
                  case mkMoney currency (toRational amt) of
                    Left _ -> sendMsg chatId t.transactions.failedToCreateMoney
                    Right money -> do
                      atomically $ modifyTVar' botState $ \s ->
                        s {conversations = Map.insert telegramId (ExpenseEnterDescription cat money) s.conversations}
                      sendMsg chatId t.transactions.enterDescription

-- | Handle expense description input and execute the transaction.
handleExpenseDescription :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> Money -> Text -> AppM ()
handleExpenseDescription lang botState telegramId chatId cat money description = do
  let t = telegramStrings lang
  clearConversation botState telegramId
  case parseCategoryUUID cat of
    Nothing -> sendMsg chatId t.transactions.invalidCategoryCancelled
    Just categoryEntryId -> do
      maybeUserId <- getUserIdForTelegram telegramId
      case maybeUserId of
        Nothing -> sendMsg chatId t.errors.couldNotFindUserAccount
        Just userId -> do
          selected <- atomically $ Map.lookup telegramId . (.selectedAccounts) <$> readTVar botState
          case selected of
            Nothing -> sendMsg chatId t.transactions.noAccountSelectedUseAccounts
            Just (accountId, _name) -> case mkAllocation categoryEntryId money Nothing of
              Left allocErr -> do
                logError $ "Expense failed (invalid allocation): " <> displayShow allocErr
                sendMsg chatId $ t.transactions.expenseRecordingFailed (tshow allocErr)
              Right alloc -> do
                let allocations = mkExpenseAllocations (alloc :| [])
                result <- initiateExpense userId accountId money allocations Set.empty description Nothing Nothing Nothing
                case result of
                  Left err -> do
                    logError $ "Expense failed: " <> displayShow err
                    sendMsg chatId $ t.transactions.expenseRecordingFailed (tshow err)
                  Right (_txId, txData) -> case txData.status of
                    Failed failureReason -> do
                      logError $ "Expense transfer failed: " <> display failureReason
                      sendMsg chatId $ t.transactions.expenseRecordingFailed failureReason
                    _ ->
                      replyRecordedTransaction lang telegramId chatId txData

-- -----------------------------------------------------------------------------
-- Transfer Flow Handlers
-- -----------------------------------------------------------------------------

-- | Handle transfer source account selection.
handleTransferSourceSelected :: Language -> TVar BotState -> TelegramId -> Int64 -> Text -> AppM ()
handleTransferSourceSelected lang botState telegramId chatId shortId = do
  let t = telegramStrings lang
  maybeAccounts <- accessibleAccountsForTelegram telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId t.errors.couldNotFindAccounts
    Just accounts ->
      case findAccountByShortId shortId accounts of
        Nothing -> sendMsg chatId t.errors.accountNotFound
        Just (srcAccountId, _name, _balance) -> do
          let otherAccounts = filter (\(accId, _, _) -> accId /= srcAccountId) accounts
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId (TransferSelectTarget srcAccountId) s.conversations}
          sendMsgWithKeyboard chatId t.transactions.selectTargetAccount (accountSelectionKeyboard lang otherAccounts Nothing "transfer_tgt")

-- | Handle transfer target account selection.
handleTransferTargetSelected :: Language -> TVar BotState -> TelegramId -> Int64 -> AccountId -> Text -> AppM ()
handleTransferTargetSelected lang botState telegramId chatId srcId shortId = do
  let t = telegramStrings lang
  maybeAccounts <- accessibleAccountsForTelegram telegramId
  case maybeAccounts of
    Nothing -> sendMsg chatId t.errors.couldNotFindAccounts
    Just accounts ->
      case findAccountByShortId shortId accounts of
        Nothing -> sendMsg chatId t.errors.accountNotFound
        Just (tgtAccountId, _name, _balance) -> do
          atomically $ modifyTVar' botState $ \s ->
            s {conversations = Map.insert telegramId (TransferEnterAmount srcId tgtAccountId) s.conversations}
          sendMsg chatId t.transactions.enterAmount

-- | Handle transfer amount input.
handleTransferAmount :: Language -> TVar BotState -> TelegramId -> Int64 -> AccountId -> AccountId -> Text -> AppM ()
handleTransferAmount lang botState telegramId chatId srcId tgtId text =
  let t = telegramStrings lang
   in case parseAmount text of
        Nothing -> sendMsg chatId t.transactions.invalidAmount
        Just amt -> do
          maybeAcc <- runDb (getAccount srcId)
          case maybeAcc of
            Nothing -> do
              clearConversation botState telegramId
              sendMsg chatId t.transactions.sourceAccountNotFound
            Just accData -> do
              let currency = moneyCurrency accData.balance
              case mkMoney currency (toRational amt) of
                Left _ -> sendMsg chatId t.transactions.failedToCreateMoney
                Right money -> do
                  atomically $ modifyTVar' botState $ \s ->
                    s {conversations = Map.insert telegramId (TransferEnterDescription srcId tgtId money) s.conversations}
                  sendMsg chatId t.transactions.enterDescription

-- | Handle transfer description input and execute the transaction.
handleTransferDescription :: Language -> TVar BotState -> TelegramId -> Int64 -> AccountId -> AccountId -> Money -> Text -> AppM ()
handleTransferDescription lang botState telegramId chatId srcId tgtId money description = do
  let t = telegramStrings lang
  clearConversation botState telegramId
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> sendMsg chatId t.errors.couldNotFindUserAccount
    Just userId -> do
      result <- initiateTransfer userId srcId tgtId money Set.empty description Nothing Nothing Nothing
      case result of
        Left err -> do
          logError $ "Transfer failed: " <> displayShow err
          sendMsg chatId $ t.transactions.transferFailed (tshow err)
        Right (_txId, txData) -> case txData.status of
          Failed failureReason -> do
            logError $ "Transfer failed: " <> display failureReason
            sendMsg chatId $ t.transactions.transferFailed failureReason
          _ ->
            replyRecordedTransaction lang telegramId chatId txData

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
getCategoryEntries :: TelegramId -> DictionaryKind -> AppM (Maybe [(DictionaryEntryId, EntryName)])
getCategoryEntries telegramId dictKind = do
  maybeUser <- runDb (getUserByTelegramId telegramId)
  case maybeUser of
    Nothing -> return Nothing
    Just (_, userData) -> do
      maybeConfig <- runDb (getConfiguration userData.configurationId)
      case maybeConfig of
        Nothing -> return Nothing
        Just configData ->
          case Map.lookup dictKind configData.dictionaries of
            Nothing -> return $ Just []
            Just dictData -> return $ Just $ dictionaryItems dictData

-- | Build a flat DictionaryEntryId -> name lookup from the user's
--   configuration, merging the income, expense, and labels dictionaries
--   so a single map resolves both categories (on Income/Expense
--   transfer types) and labels (the per-transaction label set).
--   Returns an empty map when the user or configuration can't be
--   resolved so callers can proceed with the plain type label.
getDictionaryEntryNames :: TelegramId -> AppM (Map DictionaryEntryId Text)
getDictionaryEntryNames telegramId = do
  maybeUser <- runDb (getUserByTelegramId telegramId)
  case maybeUser of
    Nothing -> return Map.empty
    Just (_, userData) -> do
      maybeConfig <- runDb (getConfiguration userData.configurationId)
      return $ case maybeConfig of
        Nothing -> Map.empty
        Just configData ->
          let entriesFor dictKind =
                maybe [] dictionaryItems (Map.lookup dictKind configData.dictionaries)
           in Map.fromList
                [ (cid, unEntryName nm)
                | (cid, nm) <-
                    entriesFor incomeCategoryDictKind
                      <> entriesFor expenseCategoryDictKind
                      <> entriesFor labelsDictKind
                ]

-- | Send the shared, structured confirmation for a just-recorded
-- transaction. Resolves category/label names and the user's own account
-- names from existing read-model helpers, then delegates rendering to the
-- pure 'formatRecordedTransaction'. The displayed account is always a regular
-- account the user can access (source for expense, target for income, both
-- for transfer), so 'accessibleAccountsForTelegram' suffices — no
-- External-account lookup is needed.
replyRecordedTransaction :: Language -> TelegramId -> Int64 -> TransactionData -> AppM ()
replyRecordedTransaction lang telegramId chatId td = do
  entryNames <- getDictionaryEntryNames telegramId
  maybeAccounts <- accessibleAccountsForTelegram telegramId
  let accountNames =
        Map.fromList [(aid, n) | (aid, n, _) <- fromMaybe [] maybeAccounts]
  sendMsg chatId (formatRecordedTransaction lang entryNames accountNames td)

-- -----------------------------------------------------------------------------
-- User/Account Lookup Helpers
-- -----------------------------------------------------------------------------

-- | Look up the UserId for a Telegram user.
getUserIdForTelegram :: TelegramId -> AppM (Maybe UserId)
getUserIdForTelegram telegramId = do
  maybeUser <- runDb (getUserByTelegramId telegramId)
  return $ fmap fst maybeUser

-- | Resolve the persisted UI language for a Telegram user's replies.
--
-- Reads the user's configuration and returns its stored 'Language'. Unknown or
-- not-yet-linked Telegram accounts (and configurations that can't be resolved)
-- default to 'En', so onboarding and error paths always have a language.
languageForTelegram :: TelegramId -> AppM Language
languageForTelegram telegramId = do
  maybeUser <- runDb (getUserByTelegramId telegramId)
  case maybeUser of
    Nothing -> pure En
    Just (_, userData) -> do
      maybeConfig <- runDb (getConfiguration userData.configurationId)
      pure (maybe En (.language) maybeConfig)

-- | Ensure this chat's Telegram command menu is shown in @lang@.
--
-- The global 'registerCommands' registration scopes by the user's Telegram-client
-- language, so it cannot honour our per-user app-language signal. This pushes a
-- chat-scoped @setMyCommands@ (which overrides regardless of client language) —
-- but only when the chat's resolved language actually changed, memoised in
-- 'BotState.syncedCommandLangs', so it costs one API call on first contact or a
-- language switch and nothing otherwise. Best-effort: a failure is logged and
-- left un-memoised so the next interaction retries.
syncChatCommandMenu :: TVar BotState -> Int64 -> Language -> AppM ()
syncChatCommandMenu botState chatId lang = do
  synced <- (.syncedCommandLangs) <$> readTVarIO botState
  when (commandMenuNeedsSync synced chatId lang)
    $ withClient
    $ \clientEnv -> do
      result <- registerChatCommands clientEnv lang chatId
      case result of
        Right True ->
          atomically
            $ modifyTVar' botState
            $ \s -> s {syncedCommandLangs = Map.insert chatId lang s.syncedCommandLangs}
        Right False ->
          logWarn "Telegram returned false for per-chat setMyCommands"
        Left err ->
          logWarn $ "Failed to set per-chat command menu: " <> displayShow err

-- | Get the regular (non-External) accounts a Telegram user can access — those
-- they own plus any shared to them — as (AccountId, name, balance) triples.
-- Returns Nothing if the Telegram user is not found, Just accounts otherwise.
accessibleAccountsForTelegram :: TelegramId -> AppM (Maybe [(AccountId, Text, Money)])
accessibleAccountsForTelegram telegramId = do
  maybeUserId <- getUserIdForTelegram telegramId
  case maybeUserId of
    Nothing -> return Nothing
    Just userId -> do
      accounts <- runDb (AccountRM.getRegularAccounts userId)
      return $ Just [(aid, a.name, a.balance) | (aid, a) <- accounts]

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
