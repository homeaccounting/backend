# Quick Start Guide - API Testing

## Getting Started in 60 Seconds

### 1. Start the Server

```bash
# From project root
cabal run accounting
```

### 2. Run the Full Workflow Test

```bash
# From project root
./scripts/api-test/test-full-workflow.sh
```

This will register a user, login, create accounts, transfer money, share accounts, and verify everything works!

---

## What You Can Do

### Quick Commands (Easiest)

```bash
# Check server status
./scripts/api-test/quick-test.sh health

# Register and login (saves token automatically)
./scripts/api-test/quick-test.sh register user@example.com MyPassword123
./scripts/api-test/quick-test.sh login user@example.com MyPassword123

# View saved token
./scripts/api-test/quick-test.sh token

# Create an account (requires auth)
./scripts/api-test/quick-test.sh create "My Account" 1000

# List all accounts
./scripts/api-test/quick-test.sh list

# Get account by ID
./scripts/api-test/quick-test.sh get <account-id>

# Share an account with another user
./scripts/api-test/quick-test.sh share <account-id> <user-id> editor

# Record income (requires auth)
./scripts/api-test/quick-test.sh income <account-id> 500 salary

# Record expense (requires auth)
./scripts/api-test/quick-test.sh expense <account-id> 100 food

# Transfer money (requires auth)
./scripts/api-test/quick-test.sh transfer <from-id> <to-id> 300

# Check transaction status
./scripts/api-test/quick-test.sh tx <transaction-id>

# View your profile (requires auth)
./scripts/api-test/quick-test.sh profile

# Change password (requires auth)
./scripts/api-test/quick-test.sh change-password OldPass123 NewPass456
```

### Comprehensive Tests

```bash
# Test all authentication operations
./scripts/api-test/test-auth.sh all

# Test all user profile operations
./scripts/api-test/test-user.sh all

# Test all account operations
./scripts/api-test/test-accounts.sh all

# Test all transaction operations
./scripts/api-test/test-transactions.sh all

# Full end-to-end workflow
./scripts/api-test/test-full-workflow.sh
```

### Individual Tests

```bash
# Auth tests
./scripts/api-test/test-auth.sh register
./scripts/api-test/test-auth.sh login
./scripts/api-test/test-auth.sh refresh
./scripts/api-test/test-auth.sh unauthorized

# User profile tests
./scripts/api-test/test-user.sh profile
./scripts/api-test/test-user.sh change-password
./scripts/api-test/test-user.sh unlink-oauth

# Account tests
./scripts/api-test/test-accounts.sh create
./scripts/api-test/test-accounts.sh list
./scripts/api-test/test-accounts.sh share
./scripts/api-test/test-accounts.sh revoke

# Transaction tests
./scripts/api-test/test-transactions.sh setup
./scripts/api-test/test-transactions.sh income
./scripts/api-test/test-transactions.sh expense
./scripts/api-test/test-transactions.sh initiate
./scripts/api-test/test-transactions.sh status
```

### Raw Curl Commands

Use the JSON payloads directly:

```bash
# Register a user
curl -X POST http://localhost:8080/api/auth/register \
  -H "Content-Type: application/json" \
  -d @scripts/api-test/payloads/auth/register.json | jq

# Login
curl -X POST http://localhost:8080/api/auth/login \
  -H "Content-Type: application/json" \
  -d @scripts/api-test/payloads/auth/login.json | jq

# Create account (with token)
curl -X POST http://localhost:8080/api/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ***REMOVED***_HERE" \
  -d @scripts/api-test/payloads/accounts/create-savings.json | jq
```

---

## File Organization

```
scripts/api-test/
├── README.md                    # Comprehensive documentation
├── QUICK_START.md               # This file
├── CURL_REFERENCE.md            # Complete curl command reference
├── quick-test.sh                # Quick helper commands
├── test-auth.sh                 # Authentication tests
├── test-user.sh                 # User profile tests
├── test-accounts.sh             # Account operations tests
├── test-transactions.sh         # Transaction operations tests
├── test-full-workflow.sh        # Complete workflow demonstration
└── payloads/
    ├── auth/                    # Authentication JSON payloads
    │   ├── register.json
    │   ├── register-second.json
    │   ├── login.json
    │   └── refresh.json
    ├── user/                    # User profile JSON payloads
    │   ├── update-profile.json
    │   └── change-password.json
    ├── accounts/                # Account JSON payloads
    │   ├── create-savings.json
    │   ├── create-checking.json
    │   └── share-account.json
    └── transactions/            # Transaction JSON payloads
        ├── income-500.json
        ├── expense-100.json
        ├── transfer-300.json
        └── transfer-500.json
```

---

## Common Workflows

### Register, Create Account, and Transact

```bash
# 1. Register a user (token saved automatically)
./scripts/api-test/quick-test.sh register user@example.com MyPassword123

# 2. Create two accounts
./scripts/api-test/quick-test.sh create "Savings" 1000
./scripts/api-test/quick-test.sh create "Checking" 500

# 3. List accounts to get IDs
./scripts/api-test/quick-test.sh list

# 4. Record income
./scripts/api-test/quick-test.sh income <savings-id> 500 salary

# 5. Record expense
./scripts/api-test/quick-test.sh expense <checking-id> 100 food

# 6. Transfer money between accounts
./scripts/api-test/quick-test.sh transfer <savings-id> <checking-id> 300

# 7. Check transaction status
./scripts/api-test/quick-test.sh tx <transaction-id>
```

### Test Authentication Flow

```bash
# 1. Register
./scripts/api-test/quick-test.sh register test@example.com Pass123!

# 2. View profile
./scripts/api-test/quick-test.sh profile

# 3. Change password
./scripts/api-test/quick-test.sh change-password Pass123! NewPass456!

# 4. Login with new password
./scripts/api-test/quick-test.sh login test@example.com NewPass456!
```

---

## Tips

1. **Auth First**: Always register or login before using protected endpoints. The scripts save the token automatically.

2. **Check Server First**: Run `./scripts/api-test/quick-test.sh health` to verify the server is running.

3. **Install jq**: For pretty JSON output
   ```bash
   # macOS
   brew install jq

   # Ubuntu/Debian
   sudo apt-get install jq
   ```

4. **Use the Full Workflow**: If you're new to the API, start with `test-full-workflow.sh` to see everything in action.

5. **Token Storage**: Test scripts save auth tokens and credentials to `/tmp/test_*.txt` for reuse across scripts.

6. **Check Logs**: If something fails, check the server logs for detailed error information.

---

## Example Session

```bash
# Terminal 1: Start the server
cabal run accounting

# Terminal 2: Test the API
./scripts/api-test/quick-test.sh health
./scripts/api-test/test-full-workflow.sh

# Or test specific areas
./scripts/api-test/test-auth.sh all
./scripts/api-test/test-user.sh all
./scripts/api-test/test-accounts.sh all
./scripts/api-test/test-transactions.sh all
```

---

## Need Help?

- Check **README.md** for detailed documentation
- Check **CURL_REFERENCE.md** for complete curl examples
- Run test scripts without arguments to see available options:
  ```bash
  ./scripts/api-test/test-auth.sh
  ./scripts/api-test/test-user.sh
  ./scripts/api-test/test-accounts.sh
  ./scripts/api-test/test-transactions.sh
  ./scripts/api-test/quick-test.sh
  ```
