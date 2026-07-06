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
    AccountSubtypeRequest (..),
    SetAccountSubtypeRequest (..),

    -- * Account Response DTOs
    AccountResponse (..),
    AccountListResponse (..),

    -- * Transaction Request DTOs
    CategoryAmount (..),
    AllocationsRequest (..),
    IncomeRequest (..),
    ExpenseRequest (..),
    AdjustBalanceRequest (..),
    TransferRequest (..),
    SetTransactionLabelsRequest (..),
    SetTransactionAllocationsRequest (..),
    ChangeTransactionDescriptionRequest (..),
    ChangeTransactionDateRequest (..),
    AmendTransactionRequest (..),

    -- * Transaction Response DTOs
    TransactionResponse (..),
    AllocationResponse (..),
    AllocationsResponse (..),
    TransactionListResponse (..),
    TransactionStatusResponse (..),
    TransactionRelation (..),
    TransactionRelationsResponse (..),

    -- * Reporting Response DTOs
    CategorySpend (..),
    SpendingByCategoryResponse (..),
    IncomeVsExpenseResponse (..),
    AccountNetWorth (..),
    NetWorthResponse (..),

    -- * Error Response DTOs
    ErrorResponse (..),
    ValidationErrorResponse (..),

    -- * Conversion Functions

    -- ** To Domain Types
    toDomainMoney,
    toCreateAccountCommand,
    toAccountSubtype,

    -- ** From Domain Types
    fromAccountData,
    fromTransaction,
    fromTransactionData,
    fromTransactionStatus,

    -- * Category / Label Parsing
    parseCategoryId,
    parseLabelIds,
    parseOptionalExchangeRate,

    -- * Serialization Helpers
    transactionTypeToText,
  )
where

-- For read model integration
import Application.ReadModels.Account (AccountData (..))
import Application.ReadModels.Transaction (TransactionData (..))
import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Bifunctor (first)
import Data.Coerce (coerce)
import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Types (AccountId, AccountStatus (..), AccountSubtype (..), AccountType (..), Allocation (..), Allocations (..), AssetProperties (..), AssetType (..), BankAccountProperties (..), CardNetwork (..), CashProperties (..), CategoryId, Currency (..), EWalletProperties (..), ExchangeRate, LabelId, LoanProperties (..), Money, TransactionId, TransactionType (..), UserId, allocationsOf, defaultCash, exchangeRateValue, mkDictionaryEntryId, mkExchangeRate, mkMoney, moneyCurrency, parseCurrency, renderRelationKind, unAccountId, unDictionaryEntryId, unMoney, unTransactionId)
-- 'allAllocations' removed: response now surfaces buckets directly via
-- 'allocationsResponseOf' (see below).
import Domain.Transaction.Projection (Transaction (..), TransactionStatus (..))
import Eventium (EventVersion (..))
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
    subtype :: Maybe AccountSubtypeRequest
  }
  deriving (Show, Eq, Generic)

instance ToJSON CreateAccountRequest

instance FromJSON CreateAccountRequest

-- | Request DTO for account subtype with discriminated JSON format.
data AccountSubtypeRequest = AccountSubtypeRequest
  { type_ :: Text,
    storageLocation :: Maybe Text,
    bankName :: Maybe Text,
    accountNumber :: Maybe Text,
    cardNetwork :: Maybe Text,
    provider :: Maybe Text,
    accountIdentifier :: Maybe Text,
    assetType :: Maybe Text,
    description :: Maybe Text,
    lender :: Maybe Text,
    interestRate :: Maybe Double,
    dueDate :: Maybe Text,
    metadata :: Maybe (Map Text Text)
  }
  deriving (Show, Eq, Generic)

instance FromJSON AccountSubtypeRequest where
  parseJSON = withObject "AccountSubtypeRequest" $ \o ->
    AccountSubtypeRequest
      <$> o .: "type"
      <*> o .:? "storageLocation"
      <*> o .:? "bankName"
      <*> o .:? "accountNumber"
      <*> o .:? "cardNetwork"
      <*> o .:? "provider"
      <*> o .:? "accountIdentifier"
      <*> o .:? "assetType"
      <*> o .:? "description"
      <*> o .:? "lender"
      <*> o .:? "interestRate"
      <*> o .:? "dueDate"
      <*> o .:? "metadata"

instance ToJSON AccountSubtypeRequest where
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
          ("assetType" .=) <$> r.assetType,
          ("description" .=) <$> r.description,
          ("lender" .=) <$> r.lender,
          ("interestRate" .=) <$> r.interestRate,
          ("dueDate" .=) <$> r.dueDate,
          ("metadata" .=) <$> r.metadata
        ]

-- | Request DTO for setting account subtype.
data SetAccountSubtypeRequest = SetAccountSubtypeRequest
  { subtype :: AccountSubtypeRequest
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetAccountSubtypeRequest

instance FromJSON SetAccountSubtypeRequest

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
    subtype :: Maybe Value,
    status :: Text,
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
--  - sourceAccountId: Source account UUID
--  - targetAccountId: Destination account UUID
--  - amount: Amount to transfer (must be positive)
--  - description: Description of the transfer
--
-- Validation:
--  - Both accounts must exist
--  - Amount must be > 0
--  - Source account must have sufficient funds
--  - Source and destination must be different
--  - Description should not be empty (best practice)
--
-- Example JSON:
-- @
-- {
--  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
--  "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
--  "amount": 300.00,
--  "description": "Rent payment"
-- }
-- @
-- | One category slice as sent by the create API (Double-based, like the
-- rest of the create DTOs).
data CategoryAmount = CategoryAmount
  { category :: UUID,
    amount :: Double,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON CategoryAmount

instance FromJSON CategoryAmount

-- | Two-bucket allocations on a create request. For income both buckets
-- may be populated (the expenses bucket is a reimbursement); for expense
-- the incomes bucket must be empty (enforced downstream by mkExpense →
-- ContraIncomeNotSupported).
data AllocationsRequest = AllocationsRequest
  { incomes :: [CategoryAmount],
    expenses :: [CategoryAmount]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AllocationsRequest

instance FromJSON AllocationsRequest

-- | Request to record an income transaction (External -> Regular account).
--
-- The categorised total is the sum of the allocation slices across both
-- buckets — there is no separate @amount@ field.
data IncomeRequest
  = IncomeRequest
  { accountId :: UUID,
    currency :: Text,
    allocations :: AllocationsRequest,
    description :: Text,
    date :: Maybe UTCTime,
    labels :: Maybe [UUID],
    -- | Optional typed relation from the new income to a pre-existing
    -- transaction (e.g. a 'refund' of an expense, or a generic 'associated'
    -- link). Absent in JSON decodes to 'Nothing' (generic instance).
    relation :: Maybe TransactionRelation
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeRequest

instance FromJSON IncomeRequest

-- | Request to record an expense transaction (Regular -> External account).
--
-- The categorised total is the sum of the allocation slices. The incomes
-- bucket must be empty (a contra-income expense is unsupported).
data ExpenseRequest
  = ExpenseRequest
  { accountId :: UUID,
    currency :: Text,
    allocations :: AllocationsRequest,
    description :: Text,
    date :: Maybe UTCTime,
    labels :: Maybe [UUID]
  }
  deriving (Show, Eq, Generic)

instance ToJSON ExpenseRequest

instance FromJSON ExpenseRequest

-- | Request to adjust an account balance to a specific target value.
--
-- The @date@ field is the business date at which the target balance was
-- correct (must not be in the future). The service computes the delta against
-- the account's balance at that point and records a synthetic adjustment
-- transaction.
--
-- Unlike 'IncomeRequest' / 'ExpenseRequest', whose @date@ field is optional
-- and defaults to server time when omitted, 'AdjustBalanceRequest.date' is
-- required: the business date defines /which/ historical snapshot the user
-- is reconciling to, so there is no sensible default. Do not relax this to
-- @Maybe UTCTime@ without first revisiting the service-layer contract.
data AdjustBalanceRequest = AdjustBalanceRequest
  { targetBalance :: Double,
    currency :: Text,
    date :: UTCTime,
    -- Stored as the synthetic adjustment transaction's description. Named
    -- @description@ for consistency with the income/expense/transfer DTOs.
    description :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AdjustBalanceRequest

instance FromJSON AdjustBalanceRequest

-- | Request to initiate an internal transfer (Regular -> Regular account).
data TransferRequest
  = TransferRequest
  { sourceAccountId :: UUID,
    targetAccountId :: UUID,
    amount :: Double,
    currency :: Text,
    description :: Text,
    exchangeRate :: Maybe Double,
    date :: Maybe UTCTime,
    labels :: Maybe [UUID]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransferRequest

instance FromJSON TransferRequest

-- | Body for @PUT \/api\/transactions\/:id\/labels@ — replaces the
-- label set on a Completed transaction.
data SetTransactionLabelsRequest = SetTransactionLabelsRequest
  { labels :: [UUID]
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetTransactionLabelsRequest

instance FromJSON SetTransactionLabelsRequest

-- | Body for @PATCH \/api\/transactions\/:id\/allocations@ — replaces the
-- allocation set on a Completed Income\/Expense transaction.
--
-- The body carries a non-empty list of 'Allocation' objects whose
-- amounts sum to the transaction's categorised total and which share
-- the categorised currency. The transaction's kind (Income vs Expense)
-- is structurally preserved — only the allocation breakdown changes.
newtype SetTransactionAllocationsRequest = SetTransactionAllocationsRequest
  { newAllocations :: Allocations
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetTransactionAllocationsRequest

instance FromJSON SetTransactionAllocationsRequest

-- | Body for @PUT \/api\/transactions\/:id\/description@ — replaces the
-- description on a Completed transaction.
newtype ChangeTransactionDescriptionRequest = ChangeTransactionDescriptionRequest
  { description :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeTransactionDescriptionRequest

instance FromJSON ChangeTransactionDescriptionRequest

-- | Body for @PUT \/api\/transactions\/:id\/date@ — replaces the
-- business date on a Completed transaction.
newtype ChangeTransactionDateRequest = ChangeTransactionDateRequest
  { at :: UTCTime
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeTransactionDateRequest

instance FromJSON ChangeTransactionDateRequest

-- | Body for @PUT \/api\/transactions\/:id\/amendment@ — replaces the
-- posting facts on a Completed transaction. The client supplies the
-- complete desired end-state; the saga computes the diff.
--
-- Cross-kind amendment is supported: the new kind (Income \/ Expense \/
-- Transfer) is structurally derived from the (source, target) account
-- types at the service layer. 'Adjustment' is out of scope (single
-- account; use 'AdjustAccountBalance').
--
-- @newAllocations@ is required when the new kind is Income or Expense
-- AND that kind differs from the current kind. Omit (@null@) for
-- within-kind amount edits and for Transfer-kind amendments.
data AmendTransactionRequest = AmendTransactionRequest
  { sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount :: Double,
    sourceCurrency :: Text,
    targetAmount :: Double,
    targetCurrency :: Text,
    exchangeRate :: Maybe Double,
    newAllocations :: Maybe Allocations
  }
  deriving (Show, Eq, Generic)

instance ToJSON AmendTransactionRequest

instance FromJSON AmendTransactionRequest

-- -----------------------------------------------------------------------------
-- Transaction Response DTOs
-- -----------------------------------------------------------------------------

-- | A single categorised allocation slice in a transaction response.
--
-- Mirrors the domain 'Allocation' (see @Domain.Core.Types@): the
-- 'categoryId' is the dictionary entry UUID rendered as text, and
-- 'amount' reuses the domain 'Money' JSON instance
-- (@{ "amount": <number>, "currency": <text> }@).
data AllocationResponse = AllocationResponse
  { categoryId :: Text,
    amount :: Money,
    comment :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON AllocationResponse

instance FromJSON AllocationResponse

-- | The two-bucket allocations surfaced in a transaction response.
--
-- Mirrors the domain 'Allocations' shape: 'incomes' carries earnings
-- categories and 'expenses' carries expense / reimbursement categories.
-- For uncategorised transfer types ('Transfer' / 'Adjustment') both
-- buckets are empty.
data AllocationsResponse = AllocationsResponse
  { incomes :: [AllocationResponse],
    expenses :: [AllocationResponse]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AllocationsResponse

instance FromJSON AllocationsResponse

-- | Response containing transaction details.
--
-- Fields:
--  - id: Unique identifier (UUID)
--  - sourceAccountId: Source account UUID
--  - targetAccountId: Destination account UUID
--  - amount: Transfer amount
--  - description: Transfer description
--  - status: Current transaction status
--  - failureReason: Reason for failure (if status is "Failed")
--
-- Example JSON (successful):
-- @
-- {
--  "id": "750e8400-e29b-41d4-a716-446655440002",
--  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
--  "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
--  "amount": 300.00,
--  "description": "Rent payment",
--  "status": "Completed",
--  "failureReason": null
-- }
-- @
--
-- Example JSON (failed):
-- @
-- {
--  "id": "750e8400-e29b-41d4-a716-446655440002",
--  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
--  "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
--  "amount": 500.00,
--  "description": "Bill payment",
--  "status": "Failed",
--  "failureReason": "Insufficient funds"
-- }
-- @
data TransactionResponse
  = TransactionResponse
  { id :: UUID,
    sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount :: Double,
    sourceCurrency :: Text,
    targetAmount :: Double,
    targetCurrency :: Text,
    exchangeRate :: Maybe Double,
    description :: Text,
    status :: Text,
    failureReason :: Maybe Text,
    transactionType :: Text,
    allocations :: AllocationsResponse,
    date :: Text,
    labels :: [UUID],
    -- | Count of completed amendments on this transaction. Always @0@
    -- on a transaction that has never been amended.
    amendmentCount :: Word,
    -- | Outbound typed relationships declared by this transaction (e.g. a
    -- 'Refund' edge to the expense it refunds). Empty for transactions with
    -- no declared edges.
    relations :: [TransactionRelation]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionResponse

instance FromJSON TransactionResponse

-- | A single typed relationship edge, used for BOTH request and response. It
-- names the /other/ endpoint ('relatedTransactionId') plus the kind wire token
-- ('relationKind'); the subject transaction is always implicit from context —
-- the new income on create, the response's own @id@ on
-- 'TransactionResponse.relations', or the @:id@ path param on
-- @GET \/:id\/relations@ (per 'outbound'\/'inbound' grouping). @relationKind@ is
-- @"refund"@ \/ @"merge"@ \/ @"split"@ \/ @"associated"@; the service enforces
-- the per-kind rules.
data TransactionRelation = TransactionRelation
  { relatedTransactionId :: UUID,
    relationKind :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionRelation

instance FromJSON TransactionRelation

-- | Response for @GET \/api\/transactions\/:id\/relations@: the edges pointing
-- out of ('outbound') and into ('inbound') the transaction.
data TransactionRelationsResponse = TransactionRelationsResponse
  { outbound :: [TransactionRelation],
    inbound :: [TransactionRelation]
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionRelationsResponse

instance FromJSON TransactionRelationsResponse

-- | Response envelope for GET /api/transactions.
--
-- Modelled on 'AccountListResponse'; leaves room for adding
-- 'nextCursor'/'total' later without a breaking change.
--
-- Example JSON:
--
-- @
-- {
--   "transactions": [ ... ],
--   "totalCount": 2
-- }
-- @
data TransactionListResponse = TransactionListResponse
  { transactions :: [TransactionResponse],
    -- | Count of ALL matches before pagination (clients compute page count).
    totalCount :: Int,
    -- | Effective page size applied (after defaulting).
    limit :: Int,
    -- | Effective offset applied.
    offset :: Int
  }
  deriving (Show, Eq, Generic)

instance ToJSON TransactionListResponse

instance FromJSON TransactionListResponse

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
-- Reporting Response DTOs
-- -----------------------------------------------------------------------------

-- | Net spend for one expense category over the requested period, in the
-- base currency. May be <= 0 when reimbursements exceed spend.
data CategorySpend = CategorySpend
  { categoryId :: Text,
    total :: Money
  }
  deriving (Show, Eq, Generic)

instance ToJSON CategorySpend

instance FromJSON CategorySpend

-- | GET /api/reports/spending-by-category
data SpendingByCategoryResponse = SpendingByCategoryResponse
  { categories :: [CategorySpend],
    total :: Money
  }
  deriving (Show, Eq, Generic)

instance ToJSON SpendingByCategoryResponse

instance FromJSON SpendingByCategoryResponse

-- | GET /api/reports/income-vs-expense (all amounts in base currency)
data IncomeVsExpenseResponse = IncomeVsExpenseResponse
  { income :: Money,
    expense :: Money,
    net :: Money
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeVsExpenseResponse

instance FromJSON IncomeVsExpenseResponse

-- | One owned account's contribution to net worth.
data AccountNetWorth = AccountNetWorth
  { accountId :: UUID,
    balance :: Money,
    baseBalance :: Money
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountNetWorth

instance FromJSON AccountNetWorth

-- | GET /api/reports/net-worth
data NetWorthResponse = NetWorthResponse
  { accounts :: [AccountNetWorth],
    total :: Money
  }
  deriving (Show, Eq, Generic)

instance ToJSON NetWorthResponse

instance FromJSON NetWorthResponse

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

-- | Converts a Double to Domain Money type.
--
-- Total: Money values can be negative (overdraft enforcement is at the
-- account level — see Domain/Account/CommandHandler.hs), and 'mkMoney' is
-- itself currently total.
--
-- Example:
-- >>> toDomainMoney USD 100.0
-- Money (100 % 1) USD
--
-- >>> toDomainMoney USD (-50.0)
-- Money ((-50) % 1) USD
toDomainMoney :: Currency -> Double -> Money
toDomainMoney cur d = case mkMoney cur (toRational d) of
  Right m -> m
  -- 'mkMoney' is total today; this branch is unreachable. Once mkMoney
  -- itself drops the Either (tracked separately), this case can go.
  Left err -> error ("toDomainMoney: " <> T.unpack err)

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
--  - Initial balance is non-negative, unless an overdraft limit is set and
--    |initialBalance| <= overdraftLimit
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

  -- Convert initial balance
  let domainBalance = toDomainMoney cur initialBalance

  -- Convert optional overdraft limit
  let domainLimit = case overdraftLimit of
        Nothing -> Nothing
        Just amt -> Just (Just (toDomainMoney cur (abs amt)))

  -- Parse account subtype (defaults to Cash)
  parsedType <- case subtype of
    Nothing -> Right defaultCash
    Just atr -> toAccountSubtype atr

  -- Create domain command with owner and type
  return $ CreateAccount name domainBalance createdBy (Regular parsedType) domainLimit
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
-- >>> let account = AccountData "Savings" (Money 1500.0) 5
-- >>> fromAccountData accountId account
-- AccountResponse accountId "Savings" 1500.0 5
fromAccountData :: AccountId -> AccountData -> AccountResponse
fromAccountData accountId AccountData {..} =
  AccountResponse
    { id = unAccountId accountId,
      name = name,
      balance = fromDomainMoney balance,
      currency = currencyToText (moneyCurrency balance),
      overdraftLimit = fmap fromDomainMoney overdraftLimit,
      subtype = case accountType of
        Regular at -> Just (fromAccountSubtype at)
        External -> Nothing,
      status = fromAccountStatus status,
      version = coerce version
    }

-- | Converts AccountStatus to Text representation.
fromAccountStatus :: AccountStatus -> Text
fromAccountStatus Opened = "Opened"
fromAccountStatus Closed = "Closed"

-- | Convert an AccountSubtypeRequest DTO to a domain AccountSubtype.
toAccountSubtype :: AccountSubtypeRequest -> Either Text AccountSubtype
toAccountSubtype req = case req.type_ of
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
          { assetType = parseAssetType <$> req.assetType,
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

-- | Convert a domain AccountSubtype to a JSON Value for API responses.
fromAccountSubtype :: AccountSubtype -> Value
fromAccountSubtype (Cash props) =
  object $
    catMaybes
      [ Just ("type" .= ("cash" :: Text)),
        ("storageLocation" .=) <$> props.storageLocation,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountSubtype (BankAccount props) =
  object $
    catMaybes
      [ Just ("type" .= ("bankAccount" :: Text)),
        ("bankName" .=) <$> props.bankName,
        ("accountNumber" .=) <$> props.accountNumber,
        ("cardNetwork" .=) . cardNetworkToText <$> props.cardNetwork,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountSubtype (EWallet props) =
  object $
    catMaybes
      [ Just ("type" .= ("eWallet" :: Text)),
        ("provider" .=) <$> props.provider,
        ("accountIdentifier" .=) <$> props.accountIdentifier,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountSubtype (Asset props) =
  object $
    catMaybes
      [ Just ("type" .= ("asset" :: Text)),
        ("assetType" .=) . assetTypeToText <$> props.assetType,
        ("description" .=) <$> props.description,
        if null props.metadata then Nothing else Just ("metadata" .= props.metadata)
      ]
fromAccountSubtype (Loan props) =
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

parseAssetType :: Text -> AssetType
parseAssetType "property" = Property
parseAssetType "vehicle" = Vehicle
parseAssetType "stocks" = Stocks
parseAssetType "retirementFund" = RetirementFund
parseAssetType other = OtherAsset other

assetTypeToText :: AssetType -> Text
assetTypeToText Property = "property"
assetTypeToText Vehicle = "vehicle"
assetTypeToText Stocks = "stocks"
assetTypeToText RetirementFund = "retirementFund"
assetTypeToText (OtherAsset t) = t

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
-- instead of requiring event replay. The transaction's declared outbound
-- edges (e.g. a 'Refund' link) are surfaced as 'relations', sourced directly
-- from 'TransactionData.relations' (batch-loaded on every query path).
fromTransactionData :: TransactionId -> TransactionData -> TransactionResponse
fromTransactionData txId TransactionData {..} =
  TransactionResponse
    { id = unTransactionId txId,
      sourceAccountId = unAccountId sourceAccountId,
      targetAccountId = unAccountId targetAccountId,
      sourceAmount = fromDomainMoney sourceAmount,
      sourceCurrency = T.pack (show (moneyCurrency sourceAmount)),
      targetAmount = fromDomainMoney targetAmount,
      targetCurrency = T.pack (show (moneyCurrency targetAmount)),
      exchangeRate = fmap (fromRational . exchangeRateValue) exchangeRate,
      description = description,
      status = fromTransactionStatus status,
      failureReason = case status of
        Failed failReason -> Just failReason
        _ -> Nothing,
      transactionType = transactionTypeToText transactionType,
      allocations = allocationsResponseOf transactionType,
      date = T.pack $ formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" date,
      labels = sort [unDictionaryEntryId eid | eid <- Set.toList labels],
      amendmentCount = amendmentCount,
      relations =
        [ TransactionRelation (unTransactionId rel) (renderRelationKind k)
        | (rel, k) <- relations
        ]
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
      sourceAccountId = unAccountId tx.sourceAccountId,
      targetAccountId = unAccountId tx.targetAccountId,
      sourceAmount = fromDomainMoney tx.sourceAmount,
      sourceCurrency = T.pack (show (moneyCurrency tx.sourceAmount)),
      targetAmount = fromDomainMoney tx.targetAmount,
      targetCurrency = T.pack (show (moneyCurrency tx.targetAmount)),
      exchangeRate = fmap (fromRational . exchangeRateValue) tx.exchangeRate,
      description = tx.description,
      status = fromTransactionStatus tx.status,
      failureReason = case tx.status of
        Failed failReason -> Just failReason
        _ -> Nothing,
      transactionType = transactionTypeToText tx.transactionType,
      allocations = allocationsResponseOf tx.transactionType,
      date = "",
      labels = sort [unDictionaryEntryId eid | eid <- Set.toList tx.labels],
      amendmentCount = tx.amendmentCount,
      relations = []
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
--
-- >>> fromTransactionStatus Cancelled
-- "Cancelled"
fromTransactionStatus :: TransactionStatus -> Text
fromTransactionStatus Pending = "Pending"
fromTransactionStatus Completed = "Completed"
fromTransactionStatus (Failed _) = "Failed"
fromTransactionStatus Cancelled = "Cancelled"

-- -----------------------------------------------------------------------------
-- Transfer Type / Category Serialization
-- -----------------------------------------------------------------------------

-- | Convert TransactionType to lowercase text for JSON responses.
transactionTypeToText :: TransactionType -> Text
transactionTypeToText (Income _) = "income"
transactionTypeToText (Expense _) = "expense"
transactionTypeToText Transfer = "transfer"
transactionTypeToText Adjustment = "adjustment"

-- | Build the two-bucket 'AllocationsResponse' for a 'TransactionType'.
--
-- Categorised types ('Income' / 'Expense') surface their full
-- @incomes@ / @expenses@ buckets, preserving slice order and converting
-- each domain 'Allocation' to an 'AllocationResponse' (category UUID as
-- text, amount reusing the domain 'Money' JSON instance). Non-categorised
-- types ('Transfer' / 'Adjustment') yield empty buckets.
allocationsResponseOf :: TransactionType -> AllocationsResponse
allocationsResponseOf tt = case allocationsOf tt of
  Nothing -> AllocationsResponse [] []
  Just (Allocations incs exps) ->
    AllocationsResponse
      (map toAllocationResponse incs)
      (map toAllocationResponse exps)
  where
    toAllocationResponse (Allocation cid amt cmt) =
      AllocationResponse
        { categoryId = T.pack $ UUID.toString $ unDictionaryEntryId cid,
          amount = amt,
          comment = cmt
        }

-- -----------------------------------------------------------------------------
-- Category Parsing
-- -----------------------------------------------------------------------------

-- | Parse a category UUID text into a CategoryId.
parseCategoryId :: Text -> Either Text CategoryId
parseCategoryId t = case UUID.fromString (T.unpack t) of
  Nothing -> Left $ "Invalid category ID (expected UUID): " <> t
  Just uuid -> mkDictionaryEntryId uuid

-- | Convert an optional list of label UUIDs into a 'Set LabelId'.
-- 'Nothing' and 'Just []' both yield an empty set; duplicates collapse
-- automatically via 'Set.fromList'. Any UUID that fails validation is
-- surfaced as a boundary 'Text' error.
parseLabelIds :: Maybe [UUID] -> Either Text (Set LabelId)
parseLabelIds Nothing = Right Set.empty
parseLabelIds (Just us) =
  Set.fromList
    <$> traverse (first ("Invalid label id: " <>) . mkDictionaryEntryId) us

-- | Parse an optional exchange-rate Double into a domain 'ExchangeRate'
-- for the (src, tgt) currency pair. 'Nothing' yields 'Nothing'.
parseOptionalExchangeRate ::
  Currency ->
  Currency ->
  Maybe Double ->
  Either Text (Maybe ExchangeRate)
parseOptionalExchangeRate _ _ Nothing = Right Nothing
parseOptionalExchangeRate src tgt (Just d) =
  Just <$> mkExchangeRate src tgt (toRational d)
