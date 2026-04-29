# Curl Commands Reference

This document provides raw curl commands for all API endpoints. Copy and paste these commands directly into your terminal, replacing the placeholder values as needed.

## Base URL

```bash
export API_BASE="http://localhost:8080"
```

---

## Authentication Endpoints

### 1. Register

Create a new user account with email and password.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user@example.com",
    "password": "SecurePass123!"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "token": "***REMOVED***",
  "userId": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "expiresIn": 3600
}
```

### 2. Login

Authenticate with email and password.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "user@example.com",
    "password": "SecurePass123!"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "token": "***REMOVED***",
  "userId": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "expiresIn": 3600
}
```

### 3. Refresh Token

Refresh an existing JWT token.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{
    "token": "***REMOVED***_HERE"
  }' | jq
```

### 4. OAuth Initiate

Start an OAuth authentication flow.

**Request:**
```bash
# Supported providers: google, github, microsoft
curl -X GET $API_BASE/api/auth/oauth/google | jq
```

**Expected Response (200 OK):**
```json
{
  "redirectUrl": "https://accounts.google.com/o/oauth2/v2/auth?...",
  "state": "random-state-string"
}
```

### 5. OAuth Callback

Handle OAuth provider callback (typically called by the OAuth provider redirect).

**Request:**
```bash
curl -X GET "$API_BASE/api/auth/oauth/google/callback?code=AUTH_CODE&state=STATE" | jq
```

### 6. Link OAuth (Requires Auth)

Link an OAuth provider to an existing account.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/link-oauth \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "provider": "Google",
    "code": "AUTH_CODE",
    "state": "STATE"
  }' | jq
```

### 7. Issue Telegram Deep-Link Code (Requires Auth)

Issue a single-use deep-link the authenticated user can open in Telegram to attach
their Telegram identity to their existing account. The link expires after 10 minutes.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/telegram/link-code \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{}' | jq
```

**Expected Response (200 OK):**
```json
{
  "deepLink": "https://t.me/YourBot?start=LINK_<token>",
  "expiresAt": "2026-04-28T20:00:00Z"
}
```

---

## User Profile Endpoints

All user profile endpoints require JWT authentication.

### 1. Get Profile

Get the current authenticated user's profile.

**Request:**
```bash
curl -X GET $API_BASE/api/users/me \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response (200 OK):**
```json
{
  "userId": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "hasPassword": true,
  "oauthIdentities": [],
  "telegramIdentity": null,
  "externalAccountId": "650e8400-e29b-41d4-a716-446655440001"
}
```

### 2. Update Profile

Update the user's profile (email).

**Request:**
```bash
curl -X PUT $API_BASE/api/users/me \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "email": "newemail@example.com"
  }' | jq
```

### 3. Change Password

Change the current user's password.

**Request:**
```bash
curl -X POST $API_BASE/api/users/me/change-password \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "currentPassword": "OldPassword123!",
    "newPassword": "NewPassword456!"
  }' | jq
```

**Expected Response (204 No Content)**

### 4. Unlink OAuth Provider

Remove a linked OAuth provider from the account.

**Request:**
```bash
# Supported providers: google, github, microsoft
curl -X DELETE $API_BASE/api/users/me/oauth/google \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response (204 No Content)**

### 5. Unlink Telegram

Remove the linked Telegram account.

**Request:**
```bash
curl -X DELETE $API_BASE/api/users/me/telegram \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response (204 No Content)**

---

## Account Endpoints

### 1. Create Account (Requires Auth)

Create a new account with an initial balance.

**Request:**
```bash
curl -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "name": "Savings Account",
    "currency": "USD",
    "initialBalance": 1000.0
  }' | jq
```

**Expected Response (201 Created):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Savings Account",
  "currency": "USD",
  "balance": 1000.0,
  "version": 1
}
```

### 2. Get Account by ID

Retrieve account information by UUID (public).

**Request:**
```bash
# Replace {account-id} with actual UUID
curl -X GET $API_BASE/api/accounts/{account-id} | jq
```

**Example:**
```bash
curl -X GET $API_BASE/api/accounts/550e8400-e29b-41d4-a716-446655440000 | jq
```

**Expected Response (200 OK):**
```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Savings Account",
  "currency": "USD",
  "balance": 1000.0,
  "version": 1
}
```

### 3. List All Accounts

Retrieve a list of all accounts in the system (public).

**Request:**
```bash
curl -X GET $API_BASE/api/accounts | jq
```

**Expected Response (200 OK):**
```json
{
  "accounts": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "Savings Account",
      "currency": "USD",
      "balance": 1000.0,
      "version": 1
    },
    {
      "id": "650e8400-e29b-41d4-a716-446655440001",
      "name": "Checking Account",
      "currency": "USD",
      "balance": 500.0,
      "version": 1
    }
  ],
  "totalCount": 2
}
```

### 4. Share Account (Requires Auth)

Share an account with another user.

**Request:**
```bash
# Replace {account-id} with actual UUID
curl -X POST $API_BASE/api/accounts/{account-id}/share \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "userId": "TARGET_USER_UUID",
    "role": "editor"
  }' | jq
```

**Supported Roles:** `owner`, `editor`, `viewer`

**Expected Response (204 No Content)**

### 5. Revoke Account Access (Requires Auth)

Revoke a user's access to an account.

**Request:**
```bash
# Replace {account-id} and {user-id} with actual UUIDs
curl -X DELETE $API_BASE/api/accounts/{account-id}/access/{user-id} \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response (204 No Content)**

---

## Configuration Endpoints

### 1. Get Configuration (Requires Auth)

Get the current user's configuration including currencies and category dictionaries.

**Request:**
```bash
curl -X GET $API_BASE/api/users/me/configuration \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response (200 OK):**
```json
{
  "baseCurrency": "USD",
  "defaultCurrency": "USD",
  "dictionaries": {
    "income-category": {
      "entries": [
        { "id": "a1b2c3d4-...", "name": "Salary" },
        { "id": "e5f6a7b8-...", "name": "Freelance" }
      ]
    },
    "expense-category": {
      "entries": [
        { "id": "c9d0e1f2-...", "name": "Food" },
        { "id": "a3b4c5d6-...", "name": "Transport" }
      ]
    }
  }
}
```

### 2. Change Base Currency (Requires Auth)

**Request:**
```bash
curl -X PUT $API_BASE/api/users/me/configuration/base-currency \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{"currency": "EUR"}' | jq
```

**Expected Response:** 204 No Content

### 3. Change Default Currency (Requires Auth)

**Request:**
```bash
curl -X PUT $API_BASE/api/users/me/configuration/default-currency \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{"currency": "UAH"}' | jq
```

**Expected Response:** 204 No Content

### 4. List Dictionary Entries (Requires Auth)

**Request:**
```bash
curl -X GET $API_BASE/api/users/me/configuration/dictionaries/income-category \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response (200 OK):**
```json
{
  "entries": [
    { "id": "a1b2c3d4-...", "name": "Salary" },
    { "id": "e5f6a7b8-...", "name": "Freelance" }
  ]
}
```

### 5. Add Dictionary Entry (Requires Auth)

**Request:**
```bash
curl -X POST $API_BASE/api/users/me/configuration/dictionaries/income-category/entries \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{"name": "Side Hustle"}' | jq
```

**Expected Response (201 Created):**
```json
{
  "id": "f7a8b9c0-...",
  "name": "Side Hustle"
}
```

### 6. Rename Dictionary Entry (Requires Auth)

**Request:**
```bash
curl -X PUT $API_BASE/api/users/me/configuration/dictionaries/income-category/entries/ENTRY_UUID \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{"name": "Gig Work"}' | jq
```

**Expected Response:** 204 No Content

### 7. Remove Dictionary Entry (Requires Auth)

**Request:**
```bash
curl -X DELETE $API_BASE/api/users/me/configuration/dictionaries/income-category/entries/ENTRY_UUID \
  -H "Authorization: Bearer ***REMOVED***" | jq
```

**Expected Response:** 204 No Content

---

## Transaction Endpoints

### 1. Record Income (Requires Auth)

Record income to an account. The `category` field must be a UUID from the user's income-category dictionary (see Configuration Endpoints above).

**Request:**
```bash
curl -X POST $API_BASE/api/transactions/income \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "accountId": "550e8400-e29b-41d4-a716-446655440000",
    "amount": 500.0,
    "currency": "USD",
    "category": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "description": "Monthly salary"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "id": "750e8400-e29b-41d4-a716-446655440002",
  "transferType": "income",
  "accountId": "550e8400-e29b-41d4-a716-446655440000",
  "amount": 500.0,
  "category": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "description": "Monthly salary",
  "status": "Pending",
  "failureReason": null
}
```

### 2. Record Expense (Requires Auth)

Record an expense from an account. The `category` field must be a UUID from the user's expense-category dictionary.

**Request:**
```bash
curl -X POST $API_BASE/api/transactions/expense \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "accountId": "550e8400-e29b-41d4-a716-446655440000",
    "amount": 100.0,
    "currency": "USD",
    "category": "c9d0e1f2-a3b4-c5d6-e7f8-901234567890",
    "description": "Groceries"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "id": "750e8400-e29b-41d4-a716-446655440003",
  "transferType": "expense",
  "accountId": "550e8400-e29b-41d4-a716-446655440000",
  "amount": 100.0,
  "category": "c9d0e1f2-a3b4-c5d6-e7f8-901234567890",
  "description": "Groceries",
  "status": "Pending",
  "failureReason": null
}
```

### 3. Initiate Transfer (Requires Auth)

Transfer money between two accounts. This operation is asynchronous and processed by the TransferManager.

**Request:**
```bash
curl -X POST $API_BASE/api/transactions/transfer \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
    "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
    "amount": 300.0,
    "currency": "USD",
    "description": "Rent payment"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "id": "750e8400-e29b-41d4-a716-446655440004",
  "transferType": "transfer",
  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 300.0,
  "description": "Rent payment",
  "status": "Pending",
  "failureReason": null
}
```

### 4. Get Transaction Status

Query the status of a transaction (public).

**Request:**
```bash
# Replace {transaction-id} with actual UUID
curl -X GET $API_BASE/api/transactions/{transaction-id} | jq
```

**Expected Response - Completed (200 OK):**
```json
{
  "id": "750e8400-e29b-41d4-a716-446655440002",
  "transferType": "transfer",
  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 300.0,
  "category": "rebalance",
  "description": "Rent payment",
  "status": "Completed",
  "failureReason": null
}
```

**Expected Response - Failed (200 OK):**
```json
{
  "id": "750e8400-e29b-41d4-a716-446655440002",
  "transferType": "transfer",
  "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 500.0,
  "category": "other",
  "description": "Large transfer",
  "status": "Failed",
  "failureReason": "Insufficient funds in source account"
}
```

### 5. List Transactions (Requires Auth)

List transactions visible to the authenticated user, with optional filters by
account and inclusive business-time date range.

- All query parameters are optional. Omitting them all returns every
  transaction the caller can see.
- `from` / `to` are full ISO-8601 UTC datetimes (e.g. `2026-04-10T14:30:00Z`).
  Date-only values are rejected with 400.
- If both bounds are supplied, `from > to` returns 400 (validation).
- Unknown or forbidden `accountId` yields `200` with an empty list (filter
  semantics — does not leak account existence).

**Request (no filters):**
```bash
curl -X GET $API_BASE/api/transactions \
  -H "Authorization: Bearer $TOKEN" | jq
```

**Request (filter by account + date range):**
```bash
curl -X GET "$API_BASE/api/transactions?accountId=550e8400-e29b-41d4-a716-446655440000&from=2026-01-01T00:00:00Z&to=2026-12-31T23:59:59Z" \
  -H "Authorization: Bearer $TOKEN" | jq
```

**Expected Response (200 OK):**
```json
{
  "transactions": [
    {
      "id": "750e8400-e29b-41d4-a716-446655440002",
      "transferType": "transfer",
      "sourceAccountId": "550e8400-e29b-41d4-a716-446655440000",
      "targetAccountId": "650e8400-e29b-41d4-a716-446655440001",
      "amount": 300.0,
      "category": "rebalance",
      "description": "Rent payment",
      "status": "Completed",
      "failureReason": null
    }
  ],
  "totalCount": 1
}
```

**Expected Response - Invalid Range (400 Bad Request):**
```json
{
  "validationMessage": "Validation failed",
  "fieldErrors": {
    "query": "from must be <= to"
  }
}
```

---

## Telegram Webhook

### Receive Bot Update

```bash
curl -X POST $API_BASE/api/telegram/webhook \
  -H "Content-Type: application/json" \
  -d '{
    "updateId": 123456,
    "updateMessage": {
      "messageId": 1,
      "messageFrom": {
        "userId": 123456789,
        "userIsBot": false,
        "userFirstName": "John"
      },
      "messageChat": {
        "chatId": 123456789,
        "chatType": "private"
      },
      "messageDate": 1700000000,
      "messageText": "/start"
    }
  }' | jq
```

---

## Error Responses

### 401 Unauthorized

Missing or invalid JWT token on a protected endpoint.

```json
{
  "message": "Missing or invalid authentication token"
}
```

**Example Trigger:**
```bash
curl -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -d '{"name": "Test", "currency": "USD", "initialBalance": 100.0}' | jq
```

### 400 Bad Request - Validation Error

Invalid request data (e.g., negative amount, empty name).

```json
{
  "validationMessage": "Invalid request",
  "fieldErrors": {
    "error": "Account name must not be empty"
  }
}
```

### 404 Not Found - Resource Not Found

Account or transaction does not exist.

```json
{
  "message": "Account not found",
  "code": "ACCOUNT_NOT_FOUND",
  "details": {
    "id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

**Example Trigger:**
```bash
curl -X GET $API_BASE/api/accounts/00000000-0000-0000-0000-000000000000 | jq
```

### 500 Internal Server Error

Unexpected server error.

```json
{
  "message": "Internal error",
  "code": "INTERNAL_ERROR",
  "details": null
}
```

---

## Complete Workflow Example

Here's a complete workflow demonstrating all operations:

```bash
# 1. Register a user
echo "Registering user..."
REGISTER=$(curl -s -X POST $API_BASE/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "demo@example.com", "password": "Demo123!"}')
TOKEN=$(echo $REGISTER | jq -r '.token')
USER_ID=$(echo $REGISTER | jq -r '.userId')
echo "Token: ${TOKEN:0:20}..."
echo "User ID: $USER_ID"

# 2. Get user profile
echo -e "\nGetting profile..."
curl -s -X GET $API_BASE/api/users/me \
  -H "Authorization: Bearer $TOKEN" | jq

# 3. Create two accounts
echo -e "\nCreating accounts..."
SAVINGS=$(curl -s -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name": "Savings", "currency": "USD", "initialBalance": 1000.0}')
SAVINGS_ID=$(echo $SAVINGS | jq -r '.id')
echo "Savings ID: $SAVINGS_ID"

CHECKING=$(curl -s -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name": "Checking", "currency": "USD", "initialBalance": 500.0}')
CHECKING_ID=$(echo $CHECKING | jq -r '.id')
echo "Checking ID: $CHECKING_ID"

# 4. List all accounts
echo -e "\nListing accounts..."
curl -s -X GET $API_BASE/api/accounts | jq

# 5. Transfer money
echo -e "\nInitiating transfer..."
TRANSFER=$(curl -s -X POST $API_BASE/api/transactions/transfer \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{
    \"sourceAccountId\": \"$SAVINGS_ID\",
    \"targetAccountId\": \"$CHECKING_ID\",
    \"amount\": 300.0,
    \"currency\": \"USD\",
    \"category\": \"rebalance\",
    \"description\": \"Transfer\"
  }")
TX_ID=$(echo $TRANSFER | jq -r '.id')
echo "Transaction ID: $TX_ID"
echo $TRANSFER | jq

# 6. Poll transaction status
echo -e "\nChecking transaction status..."
for i in {1..5}; do
  sleep 1
  STATUS=$(curl -s -X GET $API_BASE/api/transactions/$TX_ID)
  echo "Attempt $i:"
  echo $STATUS | jq
  if [ "$(echo $STATUS | jq -r '.status')" != "Pending" ]; then
    break
  fi
done

# 7. Check final balances
echo -e "\nFinal balances..."
echo "Savings:"
curl -s -X GET $API_BASE/api/accounts/$SAVINGS_ID | jq
echo -e "\nChecking:"
curl -s -X GET $API_BASE/api/accounts/$CHECKING_ID | jq
```

---

## Tips

### Save Response to File

```bash
curl -X GET $API_BASE/api/accounts > accounts.json
```

### Pretty Print with jq

```bash
curl -s -X GET $API_BASE/api/accounts | jq '.'
```

### Extract Specific Field

```bash
# Get just the balance
curl -s -X GET $API_BASE/api/accounts/550e8400-e29b-41d4-a716-446655440000 | jq -r '.balance'
```

### Use Variables

```bash
# Save token from registration
TOKEN=$(curl -s -X POST $API_BASE/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "test@ex.com", "password": "Pass123!"}' | jq -r '.token')

# Use token for subsequent requests
curl -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"name": "Test", "currency": "USD", "initialBalance": 100.0}' | jq
```

### Check HTTP Status Code

```bash
curl -w "\nHTTP Status: %{http_code}\n" -X GET $API_BASE/api/accounts | jq
```

### Verbose Output (Debug)

```bash
curl -v -X GET $API_BASE/api/accounts
```
