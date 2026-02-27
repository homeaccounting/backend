# User Experience Specification

## 1. Overview

This document specifies the user experience for the personal accounting backend system. It serves as the authoritative reference for how users interact with the REST API, expected behaviors, feedback mechanisms, and error handling.

## 2. User Personas and Scenarios

### 2.1 Primary Personas

- **Personal Finance Tracker**: An individual who wants to track their personal finances across multiple accounts. Technically proficient enough to use REST APIs directly or through a client application. Goals: maintain accurate account balances, track money movements, have complete audit history.

- **Developer/Integrator**: A developer building a frontend application or integrating with the accounting API. Needs clear API contracts, predictable error responses, and comprehensive documentation.

### 2.2 Key User Scenarios

1. **Account Setup**: User creates accounts representing their real-world financial accounts (checking, savings, cash, etc.)

2. **Recording Transactions**: User records income (credits) and expenses (debits) against appropriate accounts

3. **Money Transfers**: User moves money between accounts (e.g., from checking to savings)

4. **Balance Inquiry**: User checks current balances and account status

5. **Audit Trail**: User reviews transaction history for a specific account or time period

## 3. Interface Overview

### 3.1 Interface Principles

- **RESTful Design**: Resources (accounts, transactions) accessed via standard HTTP methods
- **JSON Payloads**: All request and response bodies use JSON format
- **Explicit Errors**: All error conditions return structured error responses with actionable messages
- **Idempotency**: Commands include IDs to enable safe retries

### 3.2 Interface Elements

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/accounts` | POST | Create a new account |
| `/api/accounts` | GET | List all accounts |
| `/api/accounts/:id` | GET | Get account details |
| `/api/accounts/:id/credit` | POST | Add funds to account |
| `/api/accounts/:id/debit` | POST | Remove funds from account |
| `/api/transactions` | POST | Create transaction (transfer between accounts) |
| `/api/transactions/:id` | GET | Get transaction status |

## 4. Core Interaction Flows

### 4.1 Primary Flow: Create Account

1. **Initiation**:
   - User sends `POST /api/accounts` with account name and initial balance
   - System validates request payload

2. **Core Process**:
   - System generates unique AccountId (UUID)
   - System executes CreateAccount command
   - System persists AccountCreated event
   - System updates AccountSummary read model

3. **Completion**:
   - System returns 201 Created with account details
   - Response includes generated AccountId
   - Account is now available for operations

**Request:**
```json
{
  "name": "Checking Account",
  "initialBalance": 1000.00
}
```

**Response (201 Created):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Checking Account",
  "balance": 1000.00
}
```

### 4.2 Primary Flow: Transfer Money

1. **Initiation**:
   - User sends `POST /api/transactions` with source, target, and amount
   - System validates both accounts exist

2. **Core Process**:
   - System generates unique TransactionId (UUID)
   - System executes InitiateTransfer command
   - TransferManager saga:
     1. Debits source account
     2. On success: Credits target account, completes transfer
     3. On failure: Marks transfer as failed (no compensation needed if debit failed)
   - System persists all events atomically

3. **Completion**:
   - System returns 200 OK with transfer details
   - Both account balances updated in read model
   - Transfer status is "completed" or "failed"

**Request:**
```json
{
  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "targetAccountId": "660e8400-e29b-41d4-a716-446655440001",
  "amount": 250.00
}
```

**Response (200 OK):**
```json
{
  "id": "770e8400-e29b-41d4-a716-446655440002",
  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "targetAccountId": "660e8400-e29b-41d4-a716-446655440001",
  "amount": 250.00,
  "status": "completed"
}
```

### 4.3 Alternative Flow: Credit/Debit Account

For recording income or expenses without transfers:

1. **Credit**: `POST /api/accounts/:id/credit` with amount
2. **Debit**: `POST /api/accounts/:id/debit` with amount

Both return updated account balance.

### 4.4 Error Paths

1. **Insufficient Funds (Debit/Transfer)**:
   - Condition: Debit amount exceeds account balance
   - Response: 400 Bad Request
   - Message: "Insufficient funds. Available: X, Requested: Y"
   - Recovery: Reduce amount or credit account first

2. **Account Not Found**:
   - Condition: Referenced account ID does not exist
   - Response: 404 Not Found
   - Message: "Account not found: {id}"
   - Recovery: Verify account ID, create account if needed

3. **Invalid Amount**:
   - Condition: Amount is negative or zero
   - Response: 400 Bad Request
   - Message: "Amount must be positive"
   - Recovery: Provide valid positive amount

4. **Self-Transfer**:
   - Condition: Source and target accounts are the same
   - Response: 400 Bad Request
   - Message: "Cannot transfer to same account"
   - Recovery: Specify different target account

## 5. Feedback and Responses

### 5.1 Success Feedback

| Operation | Status Code | Response Body |
|-----------|-------------|---------------|
| Create Account | 201 Created | Full account object with ID |
| Credit Account | 200 OK | Updated account with new balance |
| Debit Account | 200 OK | Updated account with new balance |
| Transfer Money | 200 OK | Transfer object with status |
| Get Account | 200 OK | Account object |
| List Accounts | 200 OK | Array of account objects |

### 5.2 Error Feedback

All errors return a structured JSON response:

```json
{
  "error": {
    "code": "INSUFFICIENT_FUNDS",
    "message": "Insufficient funds. Available: 100.00, Requested: 150.00",
    "details": {
      "accountId": "550e8400-e29b-41d4-a716-446655440000",
      "available": 100.00,
      "requested": 150.00
    }
  }
}
```

| Error Category | HTTP Status | Error Codes |
|----------------|-------------|-------------|
| Validation | 400 | INVALID_AMOUNT, INVALID_NAME, SELF_TRANSFER |
| Business Rule | 400 | INSUFFICIENT_FUNDS, ACCOUNT_ALREADY_EXISTS |
| Not Found | 404 | ACCOUNT_NOT_FOUND, TRANSACTION_NOT_FOUND |
| Server Error | 500 | INTERNAL_ERROR |

### 5.3 In-Progress Feedback

For long-running transfers, the transaction endpoint returns status:

| Status | Meaning |
|--------|---------|
| `initiated` | Transfer started, awaiting processing |
| `completed` | Transfer successful, both accounts updated |
| `failed` | Transfer failed (e.g., insufficient funds) |

## 6. State Management

### 6.1 System States

- **Healthy**: All services running, database connected, API responsive
- **Degraded**: Read model stale but commands still work
- **Unavailable**: Database unreachable, API returns 503

### 6.2 Account States

- **Active**: Account exists and can process commands
- (Future: Frozen, Closed states not yet implemented)

### 6.3 Transfer States

- **Initiated**: Transfer command received
- **Completed**: Both debit and credit succeeded
- **Failed**: Debit failed (insufficient funds) or system error

### 6.4 State Persistence

- **Persistent**: All events in PostgreSQL event store
- **Transient**: Account summaries in memory (rebuilt on startup)

## 7. Accessibility Requirements

Not applicable for backend API. Frontend implementations should follow WCAG guidelines.

## 8. Localization and Internationalization

- **Language**: Error messages in English
- **Currency**: Amounts stored as decimal numbers (no currency symbol)
- **Dates**: ISO 8601 format (UTC)

Future consideration: Multi-currency support with explicit currency codes.

## 9. Performance Expectations

| Operation | Target Response Time |
|-----------|---------------------|
| Get Account | < 50ms |
| List Accounts | < 100ms |
| Create Account | < 200ms |
| Credit/Debit | < 200ms |
| Transfer | < 500ms |

- **Throughput**: Designed for personal use (< 100 requests/minute)
- **Feedback threshold**: Operations > 1s should show progress (N/A for sync API)

## 10. Implementation Guidance

### 10.1 Error Handling Implementation

- Use domain-specific error types (`AccountError`, `TransactionError`)
- Transform domain errors to HTTP responses at Web layer
- Include correlation IDs for traceability (via RIO logging)
- Never expose internal implementation details in error messages

### 10.2 State Management Implementation

- Aggregates enforce invariants via command handlers
- Events are the only way to change state
- Read models are projections, not source of truth
- Operations are idempotent via command/event IDs

## 11. Verification Criteria

### Functional Criteria
- [ ] Can create accounts with valid names and balances
- [ ] Can credit and debit accounts
- [ ] Can transfer between accounts
- [ ] Cannot overdraw accounts
- [ ] Cannot transfer to same account

### Error Handling Criteria
- [ ] All errors return structured JSON responses
- [ ] Error codes are consistent and documented
- [ ] Error messages are actionable

### Performance Criteria
- [ ] All operations complete within target times
- [ ] System handles concurrent requests correctly

---

## Related

- [Mission Statement](./mission-statement.md)
- [Operational Context](./operational-context.md)
- [API Implementation Plan](./plans/2025-12-01-account-backend.md)
