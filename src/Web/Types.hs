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
    SetTransactionContactRequest (..),
    ChangeTransactionAllocationsRequest (..),
    ChangeTransactionDescriptionRequest (..),
    ChangeTransactionDateRequest (..),
    AmendTransactionRequest (..),
    MergeTransactionRequest (..),

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

    -- * Sync Response DTOs
    SyncVersionResponse (..),

    -- * Error Response DTOs
    ErrorResponse (..),
    ValidationErrorResponse (..),

    -- * Conversion Functions

    -- ** To Domain Types
    toDomainMoney,
    toCreateAccountCommand,
    toAccountSubtype,

    -- ** From Domain Types
    MoneyDTO (..),
    toMoneyDTO,
    AllocationsDTO (..),
    toAllocationsDTO,
    fromAllocationsDTO,
    fromAccountData,
    fromAccountSubtype,
    fromTransaction,
    fromTransactionData,
    fromTransactionStatus,

    -- * Category / Label / Contact Parsing
    parseCategoryId,
    parseLabelIds,
    parseContactId,
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
import Data.Scientific (Scientific)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time (UTCTime)
import Data.Time.Calendar (Day)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Data.Word (Word64)
import Domain.Account.Commands (CreateAccount (..))
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact)
import Domain.Core.Types (AccountId, AccountRole, AccountStatus (..), AccountSubtype (..), AccountType (..), Allocation (..), Allocations (..), AssetProperties (..), AssetType (..), BankAccountProperties (..), CardNetwork (..), CashProperties (..), CategoryId, ContactId, Currency (..), EWalletProperties (..), ExchangeRate, LabelId, LoanProperties (..), Money, TransactionId, TransactionType (..), UserId, allocationsOf, defaultCash, exchangeRateValue, mkDictionaryEntryId, mkExchangeRate, mkMoney, moneyCurrency, parseCurrency, renderRelationKind, roleToText, unAccountId, unDictionaryEntryId, unMoney, unTransactionId)
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
    initialBalance :: Scientific,
    currency :: Text,
    overdraftLimit :: Maybe Scientific,
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
    role :: Text, -- current user's role: "owner"|"editor"|"viewer" (tracker#29)
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
    amount :: Scientific,
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
    relation :: Maybe TransactionRelation,
    -- | Optional contact dictionary entry to associate with the new
    -- transaction. Absent in JSON decodes to 'Nothing' (generic instance).
    contactId :: Maybe UUID
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
    labels :: Maybe [UUID],
    -- | Optional contact dictionary entry to associate with the new
    -- transaction. Absent in JSON decodes to 'Nothing' (generic instance).
    contactId :: Maybe UUID
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
  { targetBalance :: Scientific,
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
    amount :: Scientific,
    currency :: Text,
    description :: Text,
    exchangeRate :: Maybe Scientific,
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

-- | Body for @PUT \/api\/transactions\/:id\/contact@ — replaces (or
-- clears, via @null@) the contact on a Completed transaction.
data SetTransactionContactRequest = SetTransactionContactRequest
  { contactId :: Maybe UUID
  }
  deriving (Show, Eq, Generic)

instance ToJSON SetTransactionContactRequest

instance FromJSON SetTransactionContactRequest

-- | Body for @PATCH \/api\/transactions\/:id\/allocations@ — replaces the
-- allocation set on a Completed Income\/Expense transaction.
--
-- The body carries a non-empty list of 'Allocation' objects whose
-- amounts sum to the transaction's categorised total and which share
-- the categorised currency. The transaction's kind (Income vs Expense)
-- is structurally preserved — only the allocation breakdown changes.
newtype ChangeTransactionAllocationsRequest = ChangeTransactionAllocationsRequest
  { newAllocations :: AllocationsDTO
  }
  deriving (Show, Eq, Generic)

instance ToJSON ChangeTransactionAllocationsRequest

instance FromJSON ChangeTransactionAllocationsRequest

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

-- | Body for @POST \/api\/transactions\/:id\/merge@ — the source
-- transactions to consolidate into the target (the @:id@ path param).
-- An empty list is rejected by the handler with a field-scoped 400.
--
-- Mirrored by the web client DTO in @web src\/api\/types.ts@
-- (@MergeTransactionRequest@); keep the two in lockstep.
newtype MergeTransactionRequest = MergeTransactionRequest
  { sourceTransactionIds :: [UUID]
  }
  deriving (Show, Eq, Generic)

instance ToJSON MergeTransactionRequest

instance FromJSON MergeTransactionRequest

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
--
-- @contactId@ carries the transaction's full desired contact state, same
-- as the other amendment fields carry the full desired posting facts:
-- @null@\/absent means "no contact" (clears an existing one), and a
-- present value that equals the current contact is a no-op. There is no
-- separate "leave unchanged" sentinel — resend the current value to
-- preserve it.
data AmendTransactionRequest = AmendTransactionRequest
  { sourceAccountId :: UUID,
    targetAccountId :: UUID,
    sourceAmount :: Scientific,
    sourceCurrency :: Text,
    targetAmount :: Scientific,
    targetCurrency :: Text,
    exchangeRate :: Maybe Scientific,
    newAllocations :: Maybe AllocationsDTO,
    contactId :: Maybe UUID
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
    amount :: MoneyDTO,
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
    -- | The transaction's single associated contact, if any. Surfaces the
    -- dictionary-entry id only — no resolved name.
    contactId :: Maybe UUID,
    -- | Count of completed amendments on this transaction. Always @0@
    -- on a transaction that has never been amended.
    amendmentCount :: Word,
    -- | Outbound typed relationships declared by this transaction (e.g. a
    -- 'Refund' edge to the expense it refunds). Empty for transactions with
    -- no declared edges.
    relations :: [TransactionRelation],
    -- | Raw provider category signal for imported transactions, surfaced
    -- faithfully as a tagged object: @{"kind":"mcc","value":"5411"}@ for an
    -- ISO 18245 merchant category code or @{"kind":"label","value":"eating_out"}@
    -- for a free-text provider label. @null@ for manual entries and providers
    -- that supply no category signal.
    bankProviderCategory :: Maybe BankProviderCategory,
    -- | Raw provider counterparty signal for imported transactions, surfaced
    -- faithfully as a plain string (the token verbatim, e.g. @"MagazinREMONTI"@) —
    -- 'BankProviderContact' has a plain-string JSON instance, unlike the tagged
    -- 'bankProviderCategory'. @null@ for manual entries and providers that
    -- supply no contact signal. Lets the client offer "map this token" to a
    -- dictionary contact.
    bankProviderContact :: Maybe BankProviderContact
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
    total :: MoneyDTO
  }
  deriving (Show, Eq, Generic)

instance ToJSON CategorySpend

instance FromJSON CategorySpend

-- | GET /api/reports/spending-by-category
data SpendingByCategoryResponse = SpendingByCategoryResponse
  { categories :: [CategorySpend],
    total :: MoneyDTO
  }
  deriving (Show, Eq, Generic)

instance ToJSON SpendingByCategoryResponse

instance FromJSON SpendingByCategoryResponse

-- | GET /api/reports/income-vs-expense (all amounts in base currency)
data IncomeVsExpenseResponse = IncomeVsExpenseResponse
  { income :: MoneyDTO,
    expense :: MoneyDTO,
    net :: MoneyDTO
  }
  deriving (Show, Eq, Generic)

instance ToJSON IncomeVsExpenseResponse

instance FromJSON IncomeVsExpenseResponse

-- | One owned account's contribution to net worth.
data AccountNetWorth = AccountNetWorth
  { accountId :: UUID,
    balance :: MoneyDTO,
    baseBalance :: MoneyDTO
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountNetWorth

instance FromJSON AccountNetWorth

-- | GET /api/reports/net-worth
data NetWorthResponse = NetWorthResponse
  { accounts :: [AccountNetWorth],
    total :: MoneyDTO
  }
  deriving (Show, Eq, Generic)

instance ToJSON NetWorthResponse

instance FromJSON NetWorthResponse

-- -----------------------------------------------------------------------------
-- Sync Response DTOs
-- -----------------------------------------------------------------------------

-- | GET /api/sync/version — the caller's per-user data-version counter
-- (tracker#45). Clients poll this to know when to refetch; the number itself
-- is opaque, only its monotonic increase matters. Stays well under 2^53 so it
-- round-trips exactly through JS's IEEE-754 doubles.
newtype SyncVersionResponse = SyncVersionResponse
  { version :: Word64
  }
  deriving (Show, Eq, Generic)

instance ToJSON SyncVersionResponse

instance FromJSON SyncVersionResponse

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

-- | Converts an inbound API amount to Domain Money.
--
-- The amount is a 'Scientific' — Aeson's exact decimal number type — *not* a
-- 'Double'. This is deliberate and load-bearing: the event store now holds
-- money as an exact decimal 'Rational' (@91899 % 100@), and @toRational@ on a
-- 'Double' yields the /binary/ fraction of the nearest representable value
-- (@4041760763239465 % 4398046511104@ for @918.99@), not the decimal. Routing
-- ingress through 'Double' therefore made edited allocations fail the exact
-- sum-against-total invariant (@AllocationsDoNotSumToTotal@). 'Scientific'
-- carries the decimal digits the client actually sent, so @toRational@ is the
-- exact decimal. (Same rationale as 'Resolve.parseAmount'.)
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
toDomainMoney :: Currency -> Scientific -> Money
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

-- | The public-API projection of a domain 'Money'.
--
-- Serializes as @{ "amount": <number>, "currency": <text> }@ with the amount
-- as a JSON number ('Double') — the historical, client-facing wire shape.
--
-- This is deliberately distinct from the domain 'Money' JSON instance, which
-- now encodes the /exact/ 'Rational' (see 'Domain.Core.Types'). The split
-- keeps two contracts honest at once: the event store persists the exact
-- value, while the API keeps its stable numeric shape for existing clients.
--
-- Decoding is /exact/: the amount is parsed as 'Scientific' (see
-- 'toDomainMoney'), so a client's @918.99@ becomes @91899 % 100@, matching the
-- stored total. Encoding is still a lossy 'Double' /display/ projection (safe
-- today for 2-decimal currencies), so @decode . encode@ is not identity for a
-- non-Double-exact decimal — only 'FromJSON' must be exact, since that is the
-- side compared against the exact stored value. Introducing a precise money
-- wire format (e.g. a decimal string or integer minor units with a per-currency
-- rounding policy) for >2-decimal currencies is a future, additive, versioned
-- change — and one de-risked by the exact event store, since no stored data
-- would migrate.
newtype MoneyDTO = MoneyDTO Money
  deriving (Show, Eq, Generic)

-- | Wrap a domain 'Money' as its public-API projection.
toMoneyDTO :: Money -> MoneyDTO
toMoneyDTO = MoneyDTO

instance ToJSON MoneyDTO where
  toJSON (MoneyDTO m) =
    object
      [ "amount" .= fromDomainMoney m,
        "currency" .= moneyCurrency m
      ]

instance FromJSON MoneyDTO where
  parseJSON = withObject "MoneyDTO" $ \o -> do
    d <- o .: "amount"
    cur <- o .: "currency"
    pure (MoneyDTO (toDomainMoney cur d))

-- | The public-API view of a domain 'Allocations'.
--
-- Structurally identical to the domain type — two buckets of category slices —
-- but each slice's @amount@ serializes through 'MoneyDTO' (a numeric JSON
-- @{ "amount": <number>, "currency": <text> }@), preserving the historical
-- client wire shape. This exists for the same reason as 'MoneyDTO': the
-- domain 'Allocations' / 'Money' JSON instances are now exact (for the event
-- store), so request/response DTOs that carry allocations project through this
-- numeric view instead of leaking the exact stored shape onto the API.
newtype AllocationsDTO = AllocationsDTO Allocations
  deriving (Show, Eq, Generic)

-- | Project a domain 'Allocations' to its public-API view.
toAllocationsDTO :: Allocations -> AllocationsDTO
toAllocationsDTO = AllocationsDTO

-- | Recover the domain 'Allocations' from its public-API view.
fromAllocationsDTO :: AllocationsDTO -> Allocations
fromAllocationsDTO (AllocationsDTO a) = a

instance ToJSON AllocationsDTO where
  toJSON (AllocationsDTO (Allocations incs exps)) =
    object ["incomes" .= map allocView incs, "expenses" .= map allocView exps]
    where
      allocView (Allocation cid amt cmt) =
        object
          [ "categoryId" .= cid,
            "amount" .= toMoneyDTO amt,
            "comment" .= cmt
          ]

instance FromJSON AllocationsDTO where
  parseJSON = withObject "AllocationsDTO" $ \o -> do
    incs <- o .: "incomes" >>= traverse parseAlloc
    exps <- o .: "expenses" >>= traverse parseAlloc
    pure (AllocationsDTO (Allocations incs exps))
    where
      parseAlloc = withObject "Allocation" $ \o -> do
        cid <- o .: "categoryId"
        MoneyDTO m <- o .: "amount"
        cmt <- o .:? "comment"
        pure (Allocation cid m cmt)

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
-- >>> fromAccountData accountId Owner account
-- AccountResponse accountId "Savings" 1500.0 5
fromAccountData :: AccountId -> AccountRole -> AccountData -> AccountResponse
fromAccountData accountId role AccountData {..} =
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
      role = roleToText role,
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
parseAssetType "electronics" = Electronics
parseAssetType "equipment" = Equipment
parseAssetType "furniture" = Furniture
parseAssetType other = OtherAsset other

assetTypeToText :: AssetType -> Text
assetTypeToText Property = "property"
assetTypeToText Vehicle = "vehicle"
assetTypeToText Stocks = "stocks"
assetTypeToText RetirementFund = "retirementFund"
assetTypeToText Electronics = "electronics"
assetTypeToText Equipment = "equipment"
assetTypeToText Furniture = "furniture"
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
      contactId = unDictionaryEntryId <$> contactId,
      amendmentCount = amendmentCount,
      relations =
        [ TransactionRelation (unTransactionId rel) (renderRelationKind k)
        | (rel, k) <- relations
        ],
      -- Surface the raw provider category signal verbatim (both MCC- and
      -- label-based categories); it serialises as a tagged @{kind,value}@
      -- object or @null@.
      bankProviderCategory = category,
      -- Surface the raw provider contact signal verbatim; it serialises as a
      -- plain string or @null@.
      bankProviderContact = providerContact
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
      contactId = unDictionaryEntryId <$> tx.contactId,
      amendmentCount = tx.amendmentCount,
      relations = [],
      bankProviderCategory = Nothing,
      bankProviderContact = Nothing
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
          amount = toMoneyDTO amt,
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

-- | Parse an optional contact UUID into a 'ContactId'. 'Nothing' yields
-- 'Nothing' (no contact); a present UUID is validated the same way as
-- 'parseCategoryId'.
parseContactId :: Maybe UUID -> Either Text (Maybe ContactId)
parseContactId Nothing = Right Nothing
parseContactId (Just u) =
  Just <$> first ("Invalid contact id: " <>) (mkDictionaryEntryId u)

-- | Parse an optional inbound exchange rate into a domain 'ExchangeRate'
-- for the (src, tgt) currency pair. 'Nothing' yields 'Nothing'.
--
-- The rate is a 'Scientific' — not a 'Double' — for the same reason as
-- 'toDomainMoney': the stored 'ExchangeRate' is an exact 'Rational', so a
-- client's @0.025@ must become @1 % 40@, not the binary fraction of the
-- nearest 'Double'. 'Scientific' carries the decimal the client sent, so
-- @toRational@ is exact.
parseOptionalExchangeRate ::
  Currency ->
  Currency ->
  Maybe Scientific ->
  Either Text (Maybe ExchangeRate)
parseOptionalExchangeRate _ _ Nothing = Right Nothing
parseOptionalExchangeRate src tgt (Just d) =
  Just <$> mkExchangeRate src tgt (toRational d)
