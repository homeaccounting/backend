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
    "registerEmail": "user@example.com",
    "registerPassword": "SecurePass123!"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "authToken": "***REMOVED***",
  "authUserId": "550e8400-e29b-41d4-a716-446655440000",
  "authEmail": "user@example.com",
  "authExpiresIn": 3600
}
```

### 2. Login

Authenticate with email and password.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "loginEmail": "user@example.com",
    "loginPassword": "SecurePass123!"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "authToken": "***REMOVED***",
  "authUserId": "550e8400-e29b-41d4-a716-446655440000",
  "authEmail": "user@example.com",
  "authExpiresIn": 3600
}
```

### 3. Refresh Token

Refresh an existing JWT token.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{
    "refreshToken": "***REMOVED***_HERE"
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
  "oauthRedirectUrl": "https://accounts.google.com/o/oauth2/v2/auth?...",
  "oauthState": "random-state-string"
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
    "linkOAuthProvider": "Google",
    "linkOAuthCode": "AUTH_CODE",
    "linkOAuthState": "STATE"
  }' | jq
```

### 7. Telegram Auth

Authenticate via Telegram login widget.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/telegram \
  -H "Content-Type: application/json" \
  -d '{
    "telegramAuthId": 123456789,
    "telegramAuthFirstName": "John",
    "telegramAuthLastName": "Doe",
    "telegramAuthUsername": "johndoe",
    "telegramAuthPhotoUrl": null,
    "telegramAuthAuthDate": 1700000000,
    "telegramAuthHash": "abc123hash"
  }' | jq
```

### 8. Link Telegram (Requires Auth)

Link a Telegram account to an existing user.

**Request:**
```bash
curl -X POST $API_BASE/api/auth/link-telegram \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "linkTelegramAuthData": {
      "telegramAuthId": 123456789,
      "telegramAuthFirstName": "John",
      "telegramAuthLastName": "Doe",
      "telegramAuthUsername": "johndoe",
      "telegramAuthPhotoUrl": null,
      "telegramAuthAuthDate": 1700000000,
      "telegramAuthHash": "abc123hash"
    }
  }' | jq
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
  "profileUserId": "550e8400-e29b-41d4-a716-446655440000",
  "profileEmail": "user@example.com",
  "profileHasPassword": true,
  "profileOAuthIdentities": [],
  "profileTelegramIdentity": null,
  "profileExternalAccountId": "650e8400-e29b-41d4-a716-446655440001"
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
    "updateEmail": "newemail@example.com"
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
    "accountName": "Savings Account",
    "initialBalance": 1000.0
  }' | jq
```

**Expected Response (201 Created):**
```json
{
  "accountId": "550e8400-e29b-41d4-a716-446655440000",
  "accountName": "Savings Account",
  "currentBalance": 1000.0,
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
  "accountId": "550e8400-e29b-41d4-a716-446655440000",
  "accountName": "Savings Account",
  "currentBalance": 1000.0,
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
      "accountId": "550e8400-e29b-41d4-a716-446655440000",
      "accountName": "Savings Account",
      "currentBalance": 1000.0,
      "version": 1
    },
    {
      "accountId": "650e8400-e29b-41d4-a716-446655440001",
      "accountName": "Checking Account",
      "currentBalance": 500.0,
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
    "shareUserId": "TARGET_USER_UUID",
    "shareRole": "editor"
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

## Transaction Endpoints

### 1. Initiate Transfer (Requires Auth)

Transfer money between two accounts. This operation is asynchronous and processed by the TransferManager.

**Request:**
```bash
curl -X POST $API_BASE/api/transactions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***" \
  -d '{
    "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
    "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
    "amount": 300.0,
    "reason": "Rent payment"
  }' | jq
```

**Expected Response (200 OK):**
```json
{
  "transactionId": "750e8400-e29b-41d4-a716-446655440002",
  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 300.0,
  "reason": "Rent payment",
  "status": "Pending",
  "failureReason": null
}
```

### 2. Get Transaction Status

Query the status of a transaction (public).

**Request:**
```bash
# Replace {transaction-id} with actual UUID
curl -X GET $API_BASE/api/transactions/{transaction-id} | jq
```

**Expected Response - Completed (200 OK):**
```json
{
  "transactionId": "750e8400-e29b-41d4-a716-446655440002",
  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 300.0,
  "reason": "Rent payment",
  "status": "Completed",
  "failureReason": null
}
```

**Expected Response - Failed (200 OK):**
```json
{
  "transactionId": "750e8400-e29b-41d4-a716-446655440002",
  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 500.0,
  "reason": "Large transfer",
  "status": "Failed",
  "failureReason": "Insufficient funds in source account"
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
  "errorMessage": "Missing or invalid authentication token"
}
```

**Example Trigger:**
```bash
curl -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -d '{"accountName": "Test", "initialBalance": 100.0}' | jq
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
  "errorMessage": "Account not found",
  "errorCode": "ACCOUNT_NOT_FOUND",
  "details": {
    "accountId": "550e8400-e29b-41d4-a716-446655440000"
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
  "errorMessage": "Internal error",
  "errorCode": "INTERNAL_ERROR",
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
  -d '{"registerEmail": "demo@example.com", "registerPassword": "Demo123!"}')
TOKEN=$(echo $REGISTER | jq -r '.authToken')
USER_ID=$(echo $REGISTER | jq -r '.authUserId')
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
  -d '{"accountName": "Savings", "initialBalance": 1000.0}')
SAVINGS_ID=$(echo $SAVINGS | jq -r '.accountId')
echo "Savings ID: $SAVINGS_ID"

CHECKING=$(curl -s -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"accountName": "Checking", "initialBalance": 500.0}')
CHECKING_ID=$(echo $CHECKING | jq -r '.accountId')
echo "Checking ID: $CHECKING_ID"

# 4. List all accounts
echo -e "\nListing accounts..."
curl -s -X GET $API_BASE/api/accounts | jq

# 5. Transfer money
echo -e "\nInitiating transfer..."
TRANSFER=$(curl -s -X POST $API_BASE/api/transactions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{
    \"fromAccountId\": \"$SAVINGS_ID\",
    \"toAccountId\": \"$CHECKING_ID\",
    \"amount\": 300.0,
    \"reason\": \"Transfer\"
  }")
TX_ID=$(echo $TRANSFER | jq -r '.transactionId')
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
curl -s -X GET $API_BASE/api/accounts/550e8400-e29b-41d4-a716-446655440000 | jq -r '.currentBalance'
```

### Use Variables

```bash
# Save token from registration
TOKEN=$(curl -s -X POST $API_BASE/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"registerEmail": "test@ex.com", "registerPassword": "Pass123!"}' | jq -r '.authToken')

# Use token for subsequent requests
curl -X POST $API_BASE/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"accountName": "Test", "initialBalance": 100.0}' | jq
```

### Check HTTP Status Code

```bash
curl -w "\nHTTP Status: %{http_code}\n" -X GET $API_BASE/api/accounts | jq
```

### Verbose Output (Debug)

```bash
curl -v -X GET $API_BASE/api/accounts
```
