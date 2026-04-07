{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Web.Types
-- Description : HTTP API request and response data transfer objects (DTOs)
--
-- This module defines the data transfer objects used in the REST API layer.
-- DTOs provide a stable API contract separate from internal domain types,
-- enabling API evolution without affecting the domain model.
--
-- Design Principles:
--   - Explicit validation at API boundary
--   - Separate API types from domain types
--   - JSON serialization for HTTP transport
--   - Clear error messages for invalid requests
--   - Type safety for all conversions
--
-- Architecture Pattern:
--   1. Client sends Request DTO (JSON)
--   2. API layer validates and converts to Domain Command
--   3. Command Handler processes and emits Events
--   4. Read Model projects Events to current state
--   5. API layer converts state to Response DTO (JSON)
--   6. Response sent to client
--
-- This separation allows:
--   - API versioning without domain changes
--   - Different representations for different clients
--   - Validation at system boundaries
--   - Clear API contracts
--
-- Usage Example:
-- >>> -- Client request
-- >>> let request = CreateAccountRequest "Savings" 1000.0
-- >>> -- Validate and convert to domain
-- >>> accountCmd <- validateCreateAccountRequest request
-- >>> -- Execute command
-- >>> events <- applyAccountCommand writer reader accountId accountCmd
-- >>> -- Build response
-- >>> return $ AccountResponse accountId "Savings" (Money 1000.0) 1
module Web.Types
  ( -- * Account Request DTOs
    CreateAccountRequest (..),
    AccountTypeRequest (..),
    SetAccountTypeRequest (..),

    -- * Account Response DTOs
    AccountResponse (..),
    AccountListResponse (..),

    -- * Transaction Request DTOs
    TransferRequest (..),
    IncomeRequest (..),
    ExpenseRequest (..),
    InternalTransferRequest (..),

    -- * Transaction Response DTOs
    TransactionResponse (..),
    TransactionStatusResponse (..),

    -- * Error Response DTOs
    ErrorResponse (..),
    ValidationErrorResponse (..),

    -- * Conversion Functions

    -- ** To Domain Types
    toDomainMoney,
    toCreateAccountCommand,
    toAccountType,
    toInitiateTransferCommand,

    -- ** From Domain Types
    fromAccountData,
    fromTransaction,
    fromTransactionData,
    fromTransactionStatus,

    -- * Category Parsing
    parseIncomeCategory,
    parseExpenseCategory,
    parseInternalCategory,

    -- * Serialization Helpers
    transferTypeToText,
    transferCategoryToText,
  )
where

-- For read model integration
import Application.ReadModels.Account (AccountData (..))
import Application.ReadModels.Transaction (TransactionData (..))
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.UUID (UUID)
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types (AccountCategory (..), AccountId, AccountType (..), AssetKind (..), AssetProperties (..), BankAccountProperties (..), CardNetwork (..), CashProperties (..), Currency (..), EWalletProperties (..), ExpenseCategory (..), IncomeCategory (..), InternalCategory (..), LoanProperties (..), Money, TransactionId, TransferCategory (..), TransferType (..), UserId, defaultCash, exchangeRateValue, mkMoney, moneyCurrency, parseCurrency, unAccountId, unMoney, unTransactionId)
import Domain.Transaction.Commands (InitiateTransfer (..))
import Domain.Transaction.Projection (Transaction (..), TransactionStatus (..))
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- Account Request DTOs
-- -----------------------------------------------------------------------------

-- | Request to create a new account.
--
-- Fields:
--  - name: Human-readable name for the account
--  - initialBalance: Starting balance (must be non-negative)
--
-- Validation:
--  - Name must not be empty
--  - Initial balance must be >= 0
--
-- Example JSON:
-- @
-- {
--  "name": "Savings Account",
--  "initialBalance": 1000.50
-- }
-- @
data CreateAccountRequest
  = CreateAccountRequest
  { name :: Text,
    initialBalance :: Double,
    currency :: Text,
    overdraftLimit :: Maybe Double,
    accountType :: Maybe AccountTypeRequest
  }
  deriving (Show, Eq, Generic)

instance ToJSON CreateAccountRequest

instance FromJSON CreateAccountRequest

-- | Request DTO for account type with discriminated JSON format.
data AccountTypeRequest = AccountTypeRequest
  { type_ :: Text,
    storageLocation :: Maybe Text,
    bankName :: Maybe Text,
    accountNumber :: Maybe Text,
    cardNetwork :: Maybe Text,
    provider :: Maybe Text,
    accountIdentifier :: Maybe Text,
    assetKind :: Maybe Text,
    description :: Maybe Text,
    lender :: Maybe Text,
    interestRate :: Maybe Double,
    dueDate :: Maybe Text,
    metadata :: Maybe (Map Text Text)
  }
  deriving (Show, Eq, Generic)

instance FromJSON AccountTypeRequest where
  parseJSON = withObject "AccountTypeRequest" $ \o ->
    AccountTypeRequest
      <$> o .: "type"
      <*> o .:? "storageLocation"
      <*> o .:? "bankName"
      <*> o .:? "accountNumber"
      <*> o .:? "cardNetwork"
      <*> o .:? "provider"
      <*> o .:? "accountIdentifier"
      <*> o .:? "assetKind"
      <*> o .:? "description"
      <*> o .:? "lender"
      <*> o .:? "interestRate"
      <*> o .:? "dueDate"
      <*> o .:? "metadata"

instance ToJSON AccountTypeRequest where
  toJSON r =
    object $
      catMaybes
        [ Just ("type" .= r.type_),
          ("storageLocation" .=) <$> r.storageLocation,
          ("bankName" .=) <$> r.bankName,
          ("accountNumber" .=) <$> r.accountNumber,
          ("cardNetwork" .=) <$> r.cardNetwork,
          ("provider" .=) <$> r.provider,
          ("accountIdentifier" .=) <$> r.accountIdentifier,
          ("assetKind" .=) <$> r.assetKind,
          ("description" .=) <$> r.description,
          ("lender" .=) <$> r.lender,
          ("interestRate" .=) <$> r.interestRate,
          ("dueDate" .=) <$> r.dueDate,
          ("metadata" .=) <$> r.metadata
        ]

-- | Request DTO for setting account type.
data SetAccountTypeRequest = SetAccountTypeRequest
  { accountType :: AccountTypeRequest
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetAccountTypeRequest

instance FromJSON SetAccountTypeRequest

-- | Request to credit (add money to) an account.
--
-- Fields:
--  - amount: Amount to add (must be positive)
--  - reason: Description of the credit operation
--
-- Validation:
--  - Amount must be > 0
--  - Reason should not be empty (best practice)
--
-- Example JSON:
-- -----------------------------------------------------------------------------
-- Account Response DTOs
-- -----------------------------------------------------------------------------

-- | Response containing account information.
--
-- Fields:
--  - id: Unique identifier (UUID)
--  - name: Human-readable name
--  - balance: Current account balance
--  - version: Event stream version (for optimistic locking)
--
-- Example JSON:
-- @
-- {
--  "id": "550e8400-e29b-41d4-a716-446655440000",
--  "name": "Savings Account",
--  "balance": 1500.50,
--  "version": 5
-- }
-- @
data AccountResponse
  = AccountResponse
  { id :: UUID,
    name :: Text,
    balance :: Double,
    currency :: Text,
    overdraftLimit :: Maybe Double,
    accountType :: Maybe Value,
    version :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountResponse

instance FromJSON AccountResponse

-- | Response containing a list of accounts.
--
-- Used for listing all accounts or filtered account queries.
--
-- Example JSON:
-- @
-- {
--  "accounts": [
--    {
--      "id": "550e8400-e29b-41d4-a716-446655440000",
--      "name": "Savings",
--      "balance": 1500.50,
--      "version": 5
--    },
--    {
--      "id": "650e8400-e29b-41d4-a716-446655440001",
--      "name": "Checking",
--      "balance": 750.25,
--      "version": 3
--    }
--  ],
--  "totalCount": 2
-- }
-- @
data AccountListResponse
  = AccountListResponse
  { accounts :: [AccountResponse],
    totalCount :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountListResponse

instance FromJSON AccountListResponse

-- -----------------------------------------------------------------------------
-- Transaction Request DTOs
-- -----------------------------------------------------------------------------

-- | Request to initiate a money transfer between accounts.
--
-- Fields:
--  - fromAccountId: Source account UUID
--  - toAccountId: Destination account UUID
--  - amount: Amount to transfer (must be positive)
--  - reason: Description of the transfer
--
-- Validation:
--  - Both accounts must exist
--  - Amount must be > 0
--  - Source account must have sufficient funds
--  - Source and destination must be different
--  - Reason should not be empty (best practice)
--
-- Example JSON:
-- @
-- {
--  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
--  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
--  "amount": 300.00,
--  "reason": "Rent payment"
-- }
-- @
data TransferRequest
  = TransferRequest
  { fromAccountId :: UUID,
    toAccountId :: UUID,
    amount :: Double,
    currency :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransferRequest

instance FromJSON TransferRequest

-- | Request to record an income transaction (External -> Regular account).
data IncomeRequest
  = IncomeRequest
  { accountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeRequest

instance FromJSON IncomeRequest

-- | Request to record an expense transaction (Regular -> External account).
data ExpenseRequest
  = ExpenseRequest
  { accountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    reason :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ExpenseRequest

instance FromJSON ExpenseRequest

-- | Request to initiate an internal transfer (Regular -> Regular account).
data InternalTransferRequest
  = InternalTransferRequest
  { fromAccountId :: UUID,
    toAccountId :: UUID,
    amount :: Double,
    currency :: Text,
    category :: Text,
    reason :: Text,
    exchangeRate :: Maybe Double
  }
  deriving (Show, Eq, Generic)

instance ToJSON InternalTransferRequest

instance FromJSON InternalTransferRequest

-- -----------------------------------------------------------------------------
-- Transaction Response DTOs
-- -----------------------------------------------------------------------------

-- | Response containing transaction details.
--
-- Fields:
--  - id: Unique identifier (UUID)
--  - fromAccountId: Source account UUID
--  - toAccountId: Destination account UUID
--  - amount: Transfer amount
--  - reason: Transfer description
--  - status: Current transaction status
--  - failureReason: Reason for failure (if status is "Failed")
--
-- Example JSON (successful):
-- @
-- {
--  "id": "750e8400-e29b-41d4-a716-446655440002",
--  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
--  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
--  "amount": 300.00,
--  "reason": "Rent payment",
--  "status": "Completed",
--  "failureReason": null
-- }
-- @
--
-- Example JSON (failed):
-- @
-- {
--  "id": "750e8400-e29b-41d4-a716-446655440002",
--  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
--  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
--  "amount": 500.00,
--  "reason": "Bill payment",
--  "status": "Failed",
--  "failureReason": "Insufficient funds"
-- }
-- @
data TransactionResponse
  = TransactionResponse
  { id :: UUID,
    fromAccountId :: UUID,
    toAccountId :: UUID,
    sourceAmount :: Double,
    sourceCurrency :: Text,
    targetAmount :: Double,
    targetCurrency :: Text,
    exchangeRate :: Maybe Double,
    reason :: Text,
    status :: Text,
    failureReason :: Maybe Text,
    transferType :: Text,
    category :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionResponse

instance FromJSON TransactionResponse

-- | Simplified response for transaction status queries.
--
-- Used when only the status is needed without full transaction details.
--
-- Example JSON:
-- @
-- {
--  "id": "750e8400-e29b-41d4-a716-446655440002",
--  "status": "Completed"
-- }
-- @
data TransactionStatusResponse
  = TransactionStatusResponse
  { id :: UUID,
    status :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionStatusResponse

instance FromJSON TransactionStatusResponse

-- -----------------------------------------------------------------------------
-- Error Response DTOs
-- -----------------------------------------------------------------------------

-- | Generic error response for API errors.
--
-- Fields:
--  - message: Human-readable error description
--  - code: Machine-readable error code
--  - details: Additional error context (optional)
--
-- Example JSON:
-- @
-- {
--  "message": "Account not found",
--  "code": "ACCOUNT_NOT_FOUND",
--  "details": {
--    "accountId": "550e8400-e29b-41d4-a716-446655440000"
--  }
-- }
-- @
data ErrorResponse
  = ErrorResponse
  { message :: Text,
    code :: Text,
    details :: Maybe (Map Text Text)
  }
  deriving (Show, Eq, Generic)

instance ToJSON ErrorResponse

instance FromJSON ErrorResponse

-- | Validation error response with field-specific errors.
--
-- Used when request validation fails at the API boundary.
--
-- Example JSON:
-- @
-- {
--  "message": "Request validation failed",
--  "fieldErrors": {
--    "name": "Account name cannot be empty",
--    "initialBalance": "Initial balance must be non-negative"
--  }
-- }
-- @
data ValidationErrorResponse
  = ValidationErrorResponse
  { message :: Text,
    fieldErrors :: Map Text Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ValidationErrorResponse

instance FromJSON ValidationErrorResponse

-- -----------------------------------------------------------------------------
-- Conversion Functions: Request DTOs → Domain Commands
-- -----------------------------------------------------------------------------

-- | Converts a Double to Domain Money type with validation.
--
-- Returns Left with error message if amount is negative.
--
-- Example:
-- >>> toDomainMoney 100.0
-- Right (Money 100.0)
--
-- >>> toDomainMoney (-50.0)
-- Left "Money amount must be non-negative: -50.0"
toDomainMoney :: Currency -> Double -> Either Text Money
toDomainMoney cur d = mkMoney cur (toRational d)

-- | Converts Domain Money to Double for API responses.
--
-- Example:
-- >>> fromDomainMoney (Money (100 % 1))
-- 100.0
fromDomainMoney :: Money -> Double
fromDomainMoney = fromRational . unMoney

-- | Converts CreateAccountRequest to Domain CreateAccount command.
--
-- Validates:
--  - Account name is not empty
--  - Initial balance is non-negative
--
-- Additional parameters:
--  - createdBy: User ID of the account creator (becomes Owner)
--  - accountType: Type of account (Regular or External)
--
-- Example:
-- >>> let request = CreateAccountRequest "Savings" 1000.0
-- >>> toCreateAccountCommand userId RegularAccount request
-- Right (CreateAccount "Savings" (Money 1000.0) userId RegularAccount)
toCreateAccountCommand :: UserId -> CreateAccountRequest -> Either Text CreateAccount
toCreateAccountCommand createdBy CreateAccountRequest {..} = do
  -- Validate account name
  when (T.null name) $
    Left "Account name cannot be empty"

  -- Parse currency
  cur <- parseCurrency currency

  -- Validate and convert initial balance
  domainBalance <- toDomainMoney cur initialBalance

  -- Convert optional overdraft limit
  domainLimit <- case overdraftLimit of
    Nothing -> Right Nothing
    Just amt -> do
      money <- toDomainMoney cur (abs amt)
      Right (Just (Just money))

  -- Parse account type (defaults to Cash)
  parsedType <- case accountType of
    Nothing -> Right defaultCash
    Just atr -> toAccountType atr

  -- Create domain command with owner and type
  return $ CreateAccount name domainBalance createdBy (Regular parsedType) domainLimit
  where
    when :: Bool -> Either Text () -> Either Text ()
    when True action = action
    when False _ = Right ()

-- | Converts TransferRequest to Domain InitiateTransfer command.
--
-- Validates:
--  - Amount is positive
--  - Source and destination are different
--  - Reason is not empty (warning)
--
-- Additional parameters:
--  - initiatedBy: User ID of the user initiating the transfer
--
-- Note: Transaction ID will be generated by the API layer.
--
-- Example:
-- >>> let request = TransferRequest fromId toId 300.0 "Rent"
-- >>> toInitiateTransferCommand userId fromId toId request
-- Right (InitiateTransfer fromId toId (Money 300.0) "Rent" userId)
toInitiateTransferCommand ::
  UserId ->
  AccountId ->
  AccountId ->
  TransferRequest ->
  Either Text InitiateTransfer
toInitiateTransferCommand initiatedBy fromId toId TransferRequest {..} = do
  -- Validate amount is positive
  when (amount <= 0) $
    Left "Transfer amount must be positive"

  -- Parse currency
  cur <- parseCurrency currency

  -- Convert to domain Money
  domainAmount <- toDomainMoney cur amount

  -- Validate source and destination are different
  when (fromId == toId) $
    Left "Cannot transfer to the same account"

  -- Validate reason (warning, not error)
  when (T.null reason) $
    Left "Transfer reason should not be empty"

  -- Create domain command with user who initiated
  -- Default to InternalTransfer / InternalOther (will be replaced by dedicated endpoints)
  return $
    InitiateTransfer
      { fromAccountId = fromId,
        toAccountId = toId,
        sourceAmount = domainAmount,
        targetAmount = domainAmount,
        exchangeRate = Nothing,
        reason = reason,
        initiatedBy = initiatedBy,
        transferType = InternalTransfer,
        category = InternalCat InternalOther
      }
  where
    when :: Bool -> Either Text () -> Either Text ()
    when True action = action
    when False _ = Right ()

-- -----------------------------------------------------------------------------
-- Conversion Functions: Domain Types → Response DTOs
-- -----------------------------------------------------------------------------

-- | Converts AccountData (read model) to AccountResponse.
--
-- Example:
-- >>> let summary = AccountData "Savings" (Money 1500.0) 5
-- >>> fromAccountData accountId summary
-- AccountResponse accountId "Savings" 1500.0 5
fromAccountData :: AccountId -> AccountData -> AccountResponse
fromAccountData accountId AccountData {..} =
  AccountResponse
    { id = unAccountId accountId,
      name = name,
      balance = fromDomainMoney balance,
      currency = currencyToText (moneyCurrency balance),
      overdraftLimit = fmap fromDomainMoney overdraftLimit,
      accountType = case accountCategory of
        Regular at -> Just (fromAccountType at)
        External -> Nothing,
      version = version
    }

-- | Convert an AccountTypeRequest DTO to a domain AccountType.
toAccountType :: AccountTypeRequest -> Either Text AccountType
toAccountType req = case req.type_ of
  "cash" ->
    Right $
      Cash
        CashProperties
          { storageLocation = req.storageLocation,
            metadata = fromMaybe mempty req.metadata
          }
  "bankAccount" ->
    Right $
      BankAccount
        BankAccountProperties
          { bankName = req.bankName,
            accountNumber = req.accountNumber,
            cardNetwork = parseCardNetwork <$> req.cardNetwork,
            metadata = fromMaybe mempty req.metadata
          }
  "eWallet" ->
    Right $
      EWallet
        EWalletProperties
          { provider = req.provider,
            accountIdentifier = req.accountIdentifier,
            metadata = fromMaybe mempty req.metadata
          }
  "asset" ->
    Right $
      Asset
        AssetProperties
          { assetKind = parseAssetKind <$> req.assetKind,
            description = req.description,
            metadata = fromMaybe mempty req.metadata
          }
  "loan" ->
    Right $
      Loan
        LoanProperties
          { lender = req.lender,
            interestRate = toRational <$> req.interestRate,
            dueDate = req.dueDate >>= parseDay,
            metadata = fromMaybe mempty req.metadata
          }
  other -> Left $ "Unknown account type: " <> other

-- | Convert a domain AccountType to a JSON Value for API responses.
fromAccountType :: AccountType -> Value
fromAccountType (Cash props) =
  object $
    catMaybes
      [ Just ("type" .= ("cash" :: Text)),
        ("storageLocation" .=) <$> props.storageLocation,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountType (BankAccount props) =
  object $
    catMaybes
      [ Just ("type" .= ("bankAccount" :: Text)),
        ("bankName" .=) <$> props.bankName,
        ("accountNumber" .=) <$> props.accountNumber,
        ("cardNetwork" .=) . cardNetworkToText <$> props.cardNetwork,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountType (EWallet props) =
  object $
    catMaybes
      [ Just ("type" .= ("eWallet" :: Text)),
        ("provider" .=) <$> props.provider,
        ("accountIdentifier" .=) <$> props.accountIdentifier,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountType (Asset props) =
  object $
    catMaybes
      [ Just ("type" .= ("asset" :: Text)),
        ("assetKind" .=) . assetKindToText <$> props.assetKind,
        ("description" .=) <$> props.description,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountType (Loan props) =
  object $
    catMaybes
      [ Just ("type" .= ("loan" :: Text)),
        ("lender" .=) <$> props.lender,
        ("interestRate" .=) <$> (fromRational <$> props.interestRate :: Maybe Double),
        ("dueDate" .=) <$> props.dueDate,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]

parseCardNetwork :: Text -> CardNetwork
parseCardNetwork "visa" = Visa
parseCardNetwork "mastercard" = Mastercard
parseCardNetwork "amex" = Amex
parseCardNetwork other = OtherCardNetwork other

cardNetworkToText :: CardNetwork -> Text
cardNetworkToText Visa = "visa"
cardNetworkToText Mastercard = "mastercard"
cardNetworkToText Amex = "amex"
cardNetworkToText (OtherCardNetwork t) = t

parseAssetKind :: Text -> AssetKind
parseAssetKind "property" = Property
parseAssetKind "vehicle" = Vehicle
parseAssetKind "stocks" = Stocks
parseAssetKind "retirementFund" = RetirementFund
parseAssetKind other = OtherAsset other

assetKindToText :: AssetKind -> Text
assetKindToText Property = "property"
assetKindToText Vehicle = "vehicle"
assetKindToText Stocks = "stocks"
assetKindToText RetirementFund = "retirementFund"
assetKindToText (OtherAsset t) = t

parseDay :: Text -> Maybe Day
parseDay = parseTimeM True defaultTimeLocale "%Y-%m-%d" . T.unpack

-- | Convert a Currency to its text representation.
currencyToText :: Currency -> Text
currencyToText UAH = "UAH"
currencyToText USD = "USD"
currencyToText EUR = "EUR"
currencyToText GBP = "GBP"

-- | Converts TransactionData (read model) to TransactionResponse.
--
-- This is the preferred conversion function as it uses the read model
-- instead of requiring event replay.
--
-- Example:
-- >>> let summary = TransactionData fromId toId (Money 300.0) "Rent" Completed
-- >>> fromTransactionData txId summary
-- TransactionResponse txId fromId toId 300.0 "Rent" "Completed" Nothing
fromTransactionData :: TransactionId -> TransactionData -> TransactionResponse
fromTransactionData txId TransactionData {..} =
  TransactionResponse
    { id = unTransactionId txId,
      fromAccountId = unAccountId fromAccountId,
      toAccountId = unAccountId toAccountId,
      sourceAmount = fromDomainMoney sourceAmount,
      sourceCurrency = T.pack (show (moneyCurrency sourceAmount)),
      targetAmount = fromDomainMoney targetAmount,
      targetCurrency = T.pack (show (moneyCurrency targetAmount)),
      exchangeRate = fmap (fromRational . exchangeRateValue) exchangeRate,
      reason = reason,
      status = fromTransactionStatus status,
      failureReason = case status of
        Failed failReason -> Just failReason
        _ -> Nothing,
      transferType = transferTypeToText transferType,
      category = transferCategoryToText category
    }

-- | Converts Transaction aggregate to TransactionResponse.
--
-- Note: This function is kept for backward compatibility but prefer
-- using 'fromTransactionData' with the read model instead.
--
-- Example:
-- >>> let transaction = Transaction fromId toId (Money 300.0) "Rent" Completed
-- >>> fromTransaction txId transaction
-- TransactionResponse txId fromId toId 300.0 "Rent" "Completed" Nothing
fromTransaction :: TransactionId -> Transaction -> TransactionResponse
fromTransaction txId tx =
  TransactionResponse
    { id = unTransactionId txId,
      fromAccountId = unAccountId tx.fromAccountId,
      toAccountId = unAccountId tx.toAccountId,
      sourceAmount = fromDomainMoney tx.sourceAmount,
      sourceCurrency = T.pack (show (moneyCurrency tx.sourceAmount)),
      targetAmount = fromDomainMoney tx.targetAmount,
      targetCurrency = T.pack (show (moneyCurrency tx.targetAmount)),
      exchangeRate = fmap (fromRational . exchangeRateValue) tx.exchangeRate,
      reason = tx.reason,
      status = fromTransactionStatus tx.status,
      failureReason = case tx.status of
        Failed failReason -> Just failReason
        _ -> Nothing,
      transferType = transferTypeToText tx.transferType,
      category = transferCategoryToText tx.category
    }

-- | Converts TransactionStatus to Text representation.
--
-- Example:
-- >>> fromTransactionStatus Pending
-- "Pending"
--
-- >>> fromTransactionStatus Completed
-- "Completed"
--
-- >>> fromTransactionStatus (Failed "Insufficient funds")
-- "Failed"
fromTransactionStatus :: TransactionStatus -> Text
fromTransactionStatus Pending = "Pending"
fromTransactionStatus Completed = "Completed"
fromTransactionStatus (Failed _) = "Failed"

-- -----------------------------------------------------------------------------
-- Transfer Type / Category Serialization
-- -----------------------------------------------------------------------------

-- | Convert TransferType to lowercase text for JSON responses.
transferTypeToText :: TransferType -> Text
transferTypeToText Income = "income"
transferTypeToText Expense = "expense"
transferTypeToText InternalTransfer = "transfer"

-- | Convert TransferCategory to lowercase text for JSON responses.
transferCategoryToText :: TransferCategory -> Text
transferCategoryToText (IncomeCat Salary) = "salary"
transferCategoryToText (IncomeCat Freelance) = "freelance"
transferCategoryToText (IncomeCat Investment) = "investment"
transferCategoryToText (IncomeCat IncomeGift) = "gift"
transferCategoryToText (IncomeCat IncomeOther) = "other"
transferCategoryToText (ExpenseCat Food) = "food"
transferCategoryToText (ExpenseCat Transport) = "transport"
transferCategoryToText (ExpenseCat Utilities) = "utilities"
transferCategoryToText (ExpenseCat Rent) = "rent"
transferCategoryToText (ExpenseCat Entertainment) = "entertainment"
transferCategoryToText (ExpenseCat ExpenseOther) = "other"
transferCategoryToText (InternalCat Rebalance) = "rebalance"
transferCategoryToText (InternalCat Savings) = "savings"
transferCategoryToText (InternalCat InternalOther) = "other"

-- -----------------------------------------------------------------------------
-- Category Parsing
-- -----------------------------------------------------------------------------

-- | Parse a text string into an IncomeCategory.
parseIncomeCategory :: Text -> Either Text IncomeCategory
parseIncomeCategory t = case T.toLower t of
  "salary" -> Right Salary
  "freelance" -> Right Freelance
  "investment" -> Right Investment
  "gift" -> Right IncomeGift
  "other" -> Right IncomeOther
  _ -> Left $ "Unknown income category: " <> t

-- | Parse a text string into an ExpenseCategory.
parseExpenseCategory :: Text -> Either Text ExpenseCategory
parseExpenseCategory t = case T.toLower t of
  "food" -> Right Food
  "transport" -> Right Transport
  "utilities" -> Right Utilities
  "rent" -> Right Rent
  "entertainment" -> Right Entertainment
  "other" -> Right ExpenseOther
  _ -> Left $ "Unknown expense category: " <> t

-- | Parse a text string into an InternalCategory.
parseInternalCategory :: Text -> Either Text InternalCategory
parseInternalCategory t = case T.toLower t of
  "rebalance" -> Right Rebalance
  "savings" -> Right Savings
  "other" -> Right InternalOther
  _ -> Left $ "Unknown internal category: " <> t
