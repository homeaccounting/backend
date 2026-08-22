{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Telegram.I18n
-- Description : Localized output catalog for the Telegram bot.
--
-- A pure, exhaustive catalog of every user-facing string the Telegram bot
-- emits, indexed by 'Language'. It defines the string records and the two
-- concrete locales ('en', 'uk'); their values are loaded from the JSON files
-- under @locales\/telegram\/{en,uk}\/*.json@ (one file per namespace, mirroring the web
-- app's @src\/locales@ layout), embedded at compile time via
-- "Data.Embed". The call sites in "Telegram.Commands",
-- "Telegram.Formatting", "Telegram.Types" and "Telegram.Keyboards" read from it
-- via 'telegramStrings'.
--
-- Strings are grouped into cohesive, feature-scoped sub-records
-- ('CommonStrings', 'ErrorStrings', 'AccountStrings', 'TransactionStrings',
-- 'PromptStrings', 'CommandStrings'). Each sub-record is a distinct concrete
-- type so 'OverloadedRecordDot' resolves field access by the record's type.
--
-- Field names are kept unique across every record in the module on purpose. The
-- project builds with 'NoFieldSelectors' + 'DuplicateRecordFields', so
-- @x.field@ dot access needs the field label in scope (importers pull the record
-- in with @(..)@). Keeping labels unique means a single import list can bring
-- them all in without one label being ambiguous between two records. The
-- 'CommandStrings' description fields that would otherwise clash with the
-- top-level accessors ('accounts', 'transactions', 'prompt') are therefore named
-- 'viewAccounts', 'listTransactions' and 'recordFromText'.
--
-- Interpolating messages are function-typed with type-safe arguments;
-- non-interpolating messages are plain 'Text'. Each field is populated by
-- looking its name up in the embedded JSON catalog for the locale (with English
-- as the fallback), and interpolating fields fill @{placeholder}@ tokens in the
-- looked-up template. The English values are byte-identical to the wording
-- currently hard-coded at the call sites, so behaviour is unchanged. The
-- Ukrainian values are a best-effort first pass pending native review.
module Telegram.I18n
  ( TelegramStrings (..),
    CommonStrings (..),
    ErrorStrings (..),
    AccountStrings (..),
    TransactionStrings (..),
    PromptStrings (..),
    CommandStrings (..),
    telegramStrings,
    en,
    uk,
    enCatalogs,
    ukCatalogs,
  )
where

import qualified Data.Aeson as Aeson
import Data.Embed (embedFileBytes)
import Data.Text (replace)
import Domain.Localization.Language (Language (..))
import RIO
import qualified RIO.Map as Map

-- -----------------------------------------------------------------------------
-- Catalog shape
-- -----------------------------------------------------------------------------

-- | The full catalog of bot output for a single locale.
data TelegramStrings = TelegramStrings
  { common :: CommonStrings,
    errors :: ErrorStrings,
    accounts :: AccountStrings,
    transactions :: TransactionStrings,
    prompt :: PromptStrings,
    commands :: CommandStrings
  }

-- | Chrome, onboarding, auth and help text shared across flows, plus the
-- static keyboard button labels.
data CommonStrings = CommonStrings
  { cancelled :: Text,
    nothingToCancel :: Text,
    selectionCleared :: Text,
    noAccountWasSelected :: Text,
    tapButtonOrCancel :: Text,
    unknownCommand :: Text -> Text,
    confirmButton :: Text,
    cancelButton :: Text,
    clearSelectionButton :: Text,
    linkedSuccess :: Text,
    linkInvalid :: Text,
    unrecognisedAccount :: Text,
    welcomeNew :: Text,
    welcomeBack :: Text,
    welcomeTip :: Text,
    availableCommands :: Text,
    helpHeader :: Text,
    loginPrompt :: Text
  }

-- | Cross-cutting failure and not-found messages that are not tied to one
-- happy-path flow.
data ErrorStrings = ErrorStrings
  { invalidButtonData :: Text,
    unexpectedInput :: Text,
    couldNotFindUserAccount :: Text,
    couldNotFindAccounts :: Text,
    accountNotFound :: Text,
    failedToCreateYourAccount :: Text,
    failedToListTransactions :: Text
  }

-- | Account listing, creation and selection.
data AccountStrings = AccountStrings
  { noAccountYet :: Text,
    noAccountsYet :: Text,
    currentlySelected :: Text -> Text,
    noAccountSelectedHeader :: Text,
    yourAccountsPrompt :: Text,
    enterAccountName :: Text,
    accountNameEmpty :: Text,
    selectCurrency :: Text,
    invalidCurrency :: Text,
    failedToCreateAccount :: Text,
    createdSelected :: Text -> Text -> Text,
    selected :: Text -> Text,
    selectedAccountNotFound :: Text
  }

-- | Income / expense / transfer flows, the transactions listing, and the
-- transaction presentation labels/markers used by "Telegram.Formatting".
data TransactionStrings = TransactionStrings
  { needTwoAccounts :: Text,
    selectSourceAccount :: Text,
    selectTargetAccount :: Text,
    noAccountSelectedUseAccounts :: Text,
    couldNotLoadIncomeCategories :: Text,
    couldNotLoadExpenseCategories :: Text,
    selectIncomeCategory :: Text,
    selectExpenseCategory :: Text,
    invalidCategorySelectKeyboard :: Text,
    invalidCategoryCancelled :: Text,
    enterAmount :: Text,
    invalidAmount :: Text,
    enterDescription :: Text,
    failedToCreateMoney :: Text,
    incomeRecordingFailed :: Text -> Text,
    expenseRecordingFailed :: Text -> Text,
    transferFailed :: Text -> Text,
    sourceAccountNotFound :: Text,
    transactionsForHeader :: Text -> Text,
    yourTransactionsHeader :: Text,
    noTransactionsFound :: Text,
    andMore :: Int -> Text,
    incomeLabel :: Text,
    expenseLabel :: Text,
    transferLabel :: Text,
    adjustmentLabel :: Text,
    pendingMarker :: Text,
    cancelledMarker :: Text,
    failedMarker :: Text -> Text,
    recorded :: Text -> Text,
    labels :: Text -> Text,
    rate :: Text -> Text
  }

-- | Natural-language prompt flow (issue #28).
data PromptStrings = PromptStrings
  { couldntFindAccountStart :: Text,
    promptUsage :: Text,
    couldntRecordHeader :: Text,
    failedTransactionLine :: Int -> Text -> Text,
    domainError :: Text -> Text,
    featureDisabled :: Text,
    upstreamError :: Text
  }

-- | The @setMyCommands@ / help command descriptions. The command tokens
-- (@\/start@ etc.) are not localized and stay at the call site. The
-- 'viewAccounts', 'listTransactions' and 'recordFromText' fields describe the
-- @\/accounts@, @\/transactions@ and @\/prompt@ commands respectively; they are
-- named this way (not @accounts@ / @transactions@ / @prompt@) to stay unique
-- against the top-level accessors — see the module note on field labels.
data CommandStrings = CommandStrings
  { start :: Text,
    signup :: Text,
    viewAccounts :: Text,
    newaccount :: Text,
    recordFromText :: Text,
    income :: Text,
    expense :: Text,
    transfer :: Text,
    listTransactions :: Text,
    cancel :: Text,
    help :: Text
  }

-- | Dispatch the catalog for a locale. Total over 'Language'.
telegramStrings :: Language -> TelegramStrings
telegramStrings En = en
telegramStrings Uk = uk

-- -----------------------------------------------------------------------------
-- Catalog loading (embedded JSON, resolved at compile time)
-- -----------------------------------------------------------------------------

-- | Decode a JSON object of @field -> template@ into a map. A malformed or
-- unreadable file yields an empty map (never a partial crash); the completeness
-- test guards against a namespace silently decoding to nothing.
decodeCatalog :: ByteString -> Map Text Text
decodeCatalog = fromRight Map.empty . Aeson.eitherDecodeStrict

-- | Look up a template by key in the @primary@ catalog, falling back to the
-- @fallback@ catalog and, last of all, to the key itself. For the English
-- catalog @primary == fallback@.
tr :: Map Text Text -> Map Text Text -> Text -> Text
tr primary fallback key =
  Map.findWithDefault (Map.findWithDefault key key fallback) key primary

-- | Fill @{name}@ placeholders in a template with the supplied substitutions.
interp :: [(Text, Text)] -> Text -> Text
interp subs template = foldl' (\acc (k, v) -> replace ("{" <> k <> "}") v acc) template subs

-- Embedded JSON locale files. Paths are relative to the package root (where
-- cabal runs the build). 'embedFileBytes' registers each as a build dependency.
enCommonBytes, enErrorsBytes, enAccountsBytes, enTransactionsBytes, enPromptBytes, enCommandsBytes :: ByteString
enCommonBytes = $(embedFileBytes "locales/telegram/en/common.json")
enErrorsBytes = $(embedFileBytes "locales/telegram/en/errors.json")
enAccountsBytes = $(embedFileBytes "locales/telegram/en/accounts.json")
enTransactionsBytes = $(embedFileBytes "locales/telegram/en/transactions.json")
enPromptBytes = $(embedFileBytes "locales/telegram/en/prompt.json")
enCommandsBytes = $(embedFileBytes "locales/telegram/en/commands.json")

ukCommonBytes, ukErrorsBytes, ukAccountsBytes, ukTransactionsBytes, ukPromptBytes, ukCommandsBytes :: ByteString
ukCommonBytes = $(embedFileBytes "locales/telegram/uk/common.json")
ukErrorsBytes = $(embedFileBytes "locales/telegram/uk/errors.json")
ukAccountsBytes = $(embedFileBytes "locales/telegram/uk/accounts.json")
ukTransactionsBytes = $(embedFileBytes "locales/telegram/uk/transactions.json")
ukPromptBytes = $(embedFileBytes "locales/telegram/uk/prompt.json")
ukCommandsBytes = $(embedFileBytes "locales/telegram/uk/commands.json")

enCommon, enErrors, enAccounts, enTransactions, enPrompt, enCommands :: Map Text Text
enCommon = decodeCatalog enCommonBytes
enErrors = decodeCatalog enErrorsBytes
enAccounts = decodeCatalog enAccountsBytes
enTransactions = decodeCatalog enTransactionsBytes
enPrompt = decodeCatalog enPromptBytes
enCommands = decodeCatalog enCommandsBytes

ukCommon, ukErrors, ukAccounts, ukTransactions, ukPrompt, ukCommands :: Map Text Text
ukCommon = decodeCatalog ukCommonBytes
ukErrors = decodeCatalog ukErrorsBytes
ukAccounts = decodeCatalog ukAccountsBytes
ukTransactions = decodeCatalog ukTransactionsBytes
ukPrompt = decodeCatalog ukPromptBytes
ukCommands = decodeCatalog ukCommandsBytes

-- | The decoded English catalogs, keyed by namespace. Exposed for the
-- completeness test; the English catalog is also the fallback for every locale.
enCatalogs :: [(Text, Map Text Text)]
enCatalogs =
  [ ("common", enCommon),
    ("errors", enErrors),
    ("accounts", enAccounts),
    ("transactions", enTransactions),
    ("prompt", enPrompt),
    ("commands", enCommands)
  ]

-- | The decoded Ukrainian catalogs, keyed by namespace. Exposed for the
-- completeness test.
ukCatalogs :: [(Text, Map Text Text)]
ukCatalogs =
  [ ("common", ukCommon),
    ("errors", ukErrors),
    ("accounts", ukAccounts),
    ("transactions", ukTransactions),
    ("prompt", ukPrompt),
    ("commands", ukCommands)
  ]

-- -----------------------------------------------------------------------------
-- Record builders (populate every field from the namespace catalogs)
-- -----------------------------------------------------------------------------

mkCommon :: Map Text Text -> Map Text Text -> CommonStrings
mkCommon primary fallback =
  CommonStrings
    { cancelled = lk "cancelled",
      nothingToCancel = lk "nothingToCancel",
      selectionCleared = lk "selectionCleared",
      noAccountWasSelected = lk "noAccountWasSelected",
      tapButtonOrCancel = lk "tapButtonOrCancel",
      unknownCommand = \cmd -> interp [("command", cmd)] (lk "unknownCommand"),
      confirmButton = lk "confirmButton",
      cancelButton = lk "cancelButton",
      clearSelectionButton = lk "clearSelectionButton",
      linkedSuccess = lk "linkedSuccess",
      linkInvalid = lk "linkInvalid",
      unrecognisedAccount = lk "unrecognisedAccount",
      welcomeNew = lk "welcomeNew",
      welcomeBack = lk "welcomeBack",
      welcomeTip = lk "welcomeTip",
      availableCommands = lk "availableCommands",
      helpHeader = lk "helpHeader",
      loginPrompt = lk "loginPrompt"
    }
  where
    lk = tr primary fallback

mkErrors :: Map Text Text -> Map Text Text -> ErrorStrings
mkErrors primary fallback =
  ErrorStrings
    { invalidButtonData = lk "invalidButtonData",
      unexpectedInput = lk "unexpectedInput",
      couldNotFindUserAccount = lk "couldNotFindUserAccount",
      couldNotFindAccounts = lk "couldNotFindAccounts",
      accountNotFound = lk "accountNotFound",
      failedToCreateYourAccount = lk "failedToCreateYourAccount",
      failedToListTransactions = lk "failedToListTransactions"
    }
  where
    lk = tr primary fallback

mkAccounts :: Map Text Text -> Map Text Text -> AccountStrings
mkAccounts primary fallback =
  AccountStrings
    { noAccountYet = lk "noAccountYet",
      noAccountsYet = lk "noAccountsYet",
      currentlySelected = \name -> interp [("name", name)] (lk "currentlySelected"),
      noAccountSelectedHeader = lk "noAccountSelectedHeader",
      yourAccountsPrompt = lk "yourAccountsPrompt",
      enterAccountName = lk "enterAccountName",
      accountNameEmpty = lk "accountNameEmpty",
      selectCurrency = lk "selectCurrency",
      invalidCurrency = lk "invalidCurrency",
      failedToCreateAccount = lk "failedToCreateAccount",
      createdSelected = \name currency -> interp [("name", name), ("currency", currency)] (lk "createdSelected"),
      selected = \name -> interp [("name", name)] (lk "selected"),
      selectedAccountNotFound = lk "selectedAccountNotFound"
    }
  where
    lk = tr primary fallback

mkTransactions :: Map Text Text -> Map Text Text -> TransactionStrings
mkTransactions primary fallback =
  TransactionStrings
    { needTwoAccounts = lk "needTwoAccounts",
      selectSourceAccount = lk "selectSourceAccount",
      selectTargetAccount = lk "selectTargetAccount",
      noAccountSelectedUseAccounts = lk "noAccountSelectedUseAccounts",
      couldNotLoadIncomeCategories = lk "couldNotLoadIncomeCategories",
      couldNotLoadExpenseCategories = lk "couldNotLoadExpenseCategories",
      selectIncomeCategory = lk "selectIncomeCategory",
      selectExpenseCategory = lk "selectExpenseCategory",
      invalidCategorySelectKeyboard = lk "invalidCategorySelectKeyboard",
      invalidCategoryCancelled = lk "invalidCategoryCancelled",
      enterAmount = lk "enterAmount",
      invalidAmount = lk "invalidAmount",
      enterDescription = lk "enterDescription",
      failedToCreateMoney = lk "failedToCreateMoney",
      incomeRecordingFailed = \reason -> interp [("reason", reason)] (lk "incomeRecordingFailed"),
      expenseRecordingFailed = \reason -> interp [("reason", reason)] (lk "expenseRecordingFailed"),
      transferFailed = \reason -> interp [("reason", reason)] (lk "transferFailed"),
      sourceAccountNotFound = lk "sourceAccountNotFound",
      transactionsForHeader = \name -> interp [("name", name)] (lk "transactionsForHeader"),
      yourTransactionsHeader = lk "yourTransactionsHeader",
      noTransactionsFound = lk "noTransactionsFound",
      andMore = \n -> interp [("count", tshow n)] (lk "andMore"),
      incomeLabel = lk "incomeLabel",
      expenseLabel = lk "expenseLabel",
      transferLabel = lk "transferLabel",
      adjustmentLabel = lk "adjustmentLabel",
      pendingMarker = lk "pendingMarker",
      cancelledMarker = lk "cancelledMarker",
      failedMarker = \reason -> interp [("reason", reason)] (lk "failedMarker"),
      recorded = \kind -> interp [("kind", kind)] (lk "recorded"),
      labels = \value -> interp [("labels", value)] (lk "labels"),
      rate = \value -> interp [("rate", value)] (lk "rate")
    }
  where
    lk = tr primary fallback

mkPrompt :: Map Text Text -> Map Text Text -> PromptStrings
mkPrompt primary fallback =
  PromptStrings
    { couldntFindAccountStart = lk "couldntFindAccountStart",
      promptUsage = lk "promptUsage",
      couldntRecordHeader = lk "couldntRecordHeader",
      failedTransactionLine = \position reason -> interp [("index", tshow position), ("reason", reason)] (lk "failedTransactionLine"),
      domainError = \message -> interp [("message", message)] (lk "domainError"),
      featureDisabled = lk "featureDisabled",
      upstreamError = lk "upstreamError"
    }
  where
    lk = tr primary fallback

mkCommands :: Map Text Text -> Map Text Text -> CommandStrings
mkCommands primary fallback =
  CommandStrings
    { start = lk "start",
      signup = lk "signup",
      viewAccounts = lk "viewAccounts",
      newaccount = lk "newaccount",
      recordFromText = lk "recordFromText",
      income = lk "income",
      expense = lk "expense",
      transfer = lk "transfer",
      listTransactions = lk "listTransactions",
      cancel = lk "cancel",
      help = lk "help"
    }
  where
    lk = tr primary fallback

-- -----------------------------------------------------------------------------
-- English (byte-identical to the current hard-coded wording)
-- -----------------------------------------------------------------------------

en :: TelegramStrings
en =
  TelegramStrings
    { common = mkCommon enCommon enCommon,
      errors = mkErrors enErrors enErrors,
      accounts = mkAccounts enAccounts enAccounts,
      transactions = mkTransactions enTransactions enTransactions,
      prompt = mkPrompt enPrompt enPrompt,
      commands = mkCommands enCommands enCommands
    }

-- -----------------------------------------------------------------------------
-- Ukrainian (best-effort; pending native review) — English as fallback.
-- -----------------------------------------------------------------------------

uk :: TelegramStrings
uk =
  TelegramStrings
    { common = mkCommon ukCommon enCommon,
      errors = mkErrors ukErrors enErrors,
      accounts = mkAccounts ukAccounts enAccounts,
      transactions = mkTransactions ukTransactions enTransactions,
      prompt = mkPrompt ukPrompt enPrompt,
      commands = mkCommands ukCommands enCommands
    }
