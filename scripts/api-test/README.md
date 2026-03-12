# API Testing Scripts

This directory contains curl scripts and JSON payloads for testing the Accounting Backend API on a local development PC.

## Prerequisites

- The backend server must be running on `http://localhost:8080`
- `curl` and `jq` (for pretty JSON output) should be installed

## Directory Structure

```
scripts/api-test/
├── README.md              # This file
├── QUICK_START.md         # Quick reference guide
├── CURL_REFERENCE.md      # Complete curl command reference
├── quick-test.sh          # Quick helper commands
├── test-auth.sh           # Authentication tests (register, login, refresh, telegram)
├── test-telegram.sh       # Telegram-specific auth tests and workflows
├── test-user.sh           # User profile tests (get, update, change password)
├── test-accounts.sh       # Account operations tests (create, share, revoke)
├── test-transactions.sh   # Transaction operations tests (transfer, status)
├── test-full-workflow.sh  # Complete workflow demonstration
└── payloads/
    ├── auth/              # Authentication payloads
    │   ├── register.json
    │   ├── register-second.json
    │   ├── login.json
    │   └── refresh.json
    ├── user/              # User profile payloads
    │   ├── update-profile.json
    │   └── change-password.json
    ├── accounts/          # Account operation payloads
    │   ├── create-savings.json
    │   ├── create-checking.json
    │   └── share-account.json
    └── transactions/      # Transaction operation payloads
        ├── income-500.json
        ├── expense-100.json
        ├── transfer-300.json
        └── transfer-500.json
```

## Authentication

Most endpoints now require JWT authentication. The typical flow is:

1. **Register** a new user → receive a JWT token
2. **Login** with email/password → receive a JWT token
3. Use the token in the `Authorization: Bearer <token>` header for protected endpoints

The test scripts automatically manage token storage in `/tmp/test_auth_token.txt`.

## Usage

### Quick Start - Full Workflow Test

Run the complete workflow test that demonstrates all API functionality:

```bash
./scripts/api-test/test-full-workflow.sh
```

This will:
1. Register a new user
2. Login with credentials
3. Get user profile
4. Create two accounts (Savings and Checking)
5. List all accounts
6. Transfer money between accounts
7. Poll transaction status
8. Share an account with another user
9. Verify final balances

### Individual Test Scripts

#### Test Authentication

```bash
./scripts/api-test/test-auth.sh all
```

Available operations:
- Register a new user
- Test duplicate registration (expected failure)
- Login with email/password
- Test wrong password (expected failure)
- Refresh JWT token
- Test OAuth initiate
- Test accessing protected endpoint without token

#### Test User Profile

```bash
./scripts/api-test/test-user.sh all
```

Available operations:
- Get current user profile
- Update profile
- Change password
- Unlink OAuth provider
- Unlink Telegram

#### Test Account Operations

```bash
./scripts/api-test/test-accounts.sh all
```

Available operations:
- Create account (requires auth)
- Test creating without auth (expected 401)
- Get account by ID
- List all accounts
- Share account with another user
- Revoke account access

#### Test Transaction Operations

```bash
./scripts/api-test/test-transactions.sh all
```

Available operations:
- Setup test accounts
- Record income (requires auth)
- Record expense (requires auth)
- Initiate transfer (requires auth)
- Test transfer without auth (expected 401)
- Get transaction status
- Verify balances
- Test insufficient funds

#### Test Telegram Authentication

```bash
# Requires TELEGRAM_BOT_TOKEN env var (same token the server uses)
export TELEGRAM_BOT_TOKEN='your-bot-token'

./scripts/api-test/test-telegram.sh all        # All Telegram tests
./scripts/api-test/test-telegram.sh login       # Login via Telegram
./scripts/api-test/test-telegram.sh workflow    # Full workflow: login → accounts → transfer
```

### Quick Commands

```bash
# Authentication
./scripts/api-test/quick-test.sh register user@example.com MyPassword123
./scripts/api-test/quick-test.sh login user@example.com MyPassword123
./scripts/api-test/quick-test.sh telegram-login                     # Login via Telegram (random ID)
./scripts/api-test/quick-test.sh telegram-login 12345 John johndoe  # Login with specific Telegram ID
./scripts/api-test/quick-test.sh token

# Accounts (create/share/revoke require auth)
./scripts/api-test/quick-test.sh create "My Account" 1000
./scripts/api-test/quick-test.sh list
./scripts/api-test/quick-test.sh get <account-id>
./scripts/api-test/quick-test.sh share <account-id> <user-id> editor

# Transactions (requires auth)
./scripts/api-test/quick-test.sh income <account-id> 500 salary
./scripts/api-test/quick-test.sh expense <account-id> 100 food
./scripts/api-test/quick-test.sh transfer <from-id> <to-id> 300
./scripts/api-test/quick-test.sh tx <transaction-id>

# User Profile (requires auth)
./scripts/api-test/quick-test.sh profile
./scripts/api-test/quick-test.sh change-password OldPass123 NewPass456
```

## API Endpoints Reference

### Authentication Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/auth/register` | No | Register with email + password |
| POST | `/api/auth/login` | No | Login with email + password |
| GET | `/api/auth/oauth/:provider` | No | Initiate OAuth flow |
| GET | `/api/auth/oauth/:provider/callback` | No | OAuth callback |
| POST | `/api/auth/link-oauth` | JWT | Link OAuth to existing account |
| POST | `/api/auth/telegram` | No | Telegram login widget auth |
| POST | `/api/auth/link-telegram` | JWT | Link Telegram to existing account |
| POST | `/api/auth/refresh` | No | Refresh JWT token |

### User Profile Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| GET | `/api/users/me` | JWT | Get current user profile |
| PUT | `/api/users/me` | JWT | Update profile |
| POST | `/api/users/me/change-password` | JWT | Change password |
| DELETE | `/api/users/me/oauth/:provider` | JWT | Unlink OAuth provider |
| DELETE | `/api/users/me/telegram` | JWT | Unlink Telegram |

### Account Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/accounts` | JWT | Create a new account |
| GET | `/api/accounts/:id` | No | Get account by ID |
| GET | `/api/accounts` | No | List all accounts |
| POST | `/api/accounts/:id/share` | JWT | Share account with another user |
| DELETE | `/api/accounts/:id/access/:userId` | JWT | Revoke user's access |

### Transaction Endpoints

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/transactions/income` | JWT | Record income to an account |
| POST | `/api/transactions/expense` | JWT | Record an expense from an account |
| POST | `/api/transactions/transfer` | JWT | Transfer money between accounts |
| GET | `/api/transactions/:id` | No | Get transaction status |

### Telegram Webhook

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/telegram/webhook` | No | Receive Telegram bot updates |

## Expected Responses

### Successful Registration/Login

```json
{
  "token": "***REMOVED***",
  "userId": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "expiresIn": 3600
}
```

### Successful Account Creation (201 Created)

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Savings Account",
  "balance": 1000.0,
  "version": 1
}
```

### Successful Transfer Initiation

```json
{
  "id": "750e8400-e29b-41d4-a716-446655440002",
  "transferType": "transfer",
  "fromAccountId": "550e8400-e29b-41d4-a716-446655440000",
  "toAccountId": "650e8400-e29b-41d4-a716-446655440001",
  "amount": 300.0,
  "category": "rebalance",
  "reason": "Rent payment",
  "status": "Pending",
  "failureReason": null
}
```

### User Profile

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

### Error Response (401 Unauthorized)

```json
{
  "message": "Missing or invalid authentication token"
}
```

### Error Response (400 Bad Request)

```json
{
  "validationMessage": "Invalid request",
  "fieldErrors": {
    "error": "Account name must not be empty"
  }
}
```

### Error Response (404 Not Found)

```json
{
  "message": "Account not found",
  "code": "ACCOUNT_NOT_FOUND",
  "details": {
    "id": "550e8400-e29b-41d4-a716-446655440000"
  }
}
```

## Troubleshooting

### Server Not Running

If you get connection errors, ensure the backend is running:

```bash
# Start the backend (from project root)
cabal run accounting
```

### 401 Unauthorized Errors

Protected endpoints require a JWT token. Register or login first:

```bash
# Register a new user
./scripts/api-test/quick-test.sh register user@example.com MyPassword123

# Or login with existing credentials
./scripts/api-test/quick-test.sh login user@example.com MyPassword123
```

### Invalid UUID Errors

The test scripts generate new UUIDs for each run. If you need to test with specific account IDs, extract them from the response and pass them as arguments.

### Pretty JSON Output

If `jq` is not installed, responses will still work but won't be formatted:

```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq
```

## Notes

- All amounts are in dollars (decimal format)
- Account IDs, User IDs, and Transaction IDs are UUIDs
- Transactions (income, expense, transfer) are processed asynchronously by the TransferManager process
- Transaction status will be "Pending" initially, then "Completed" or "Failed"
- You may need to poll the transaction status endpoint to see the final result
- JWT tokens expire after the configured duration (check `expiresIn` in the response)
- Test scripts store credentials and tokens in `/tmp/test_*.txt` files for reuse
