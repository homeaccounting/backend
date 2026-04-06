#!/bin/bash

# Telegram Authentication API Testing Script
# Tests Telegram login/auth flow: authenticate via Telegram, then use JWT for account operations
#
# Prerequisites:
#   - Server running (use --prod or --local to select endpoint)
#   - TELEGRAM_BOT_TOKEN env var set (same token the server uses)
#   - openssl installed (for HMAC-SHA256 hash computation)
#
# The script computes a valid Telegram auth hash so you can test the full flow
# without needing the actual Telegram Login Widget.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

load_env "$PROJECT_ROOT"

# Check prerequisites
check_prerequisites() {
    if ! command -v openssl &> /dev/null; then
        print_error "openssl is required for hash computation but not found"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        print_error "jq is required for JSON parsing but not found"
        exit 1
    fi

    if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
        print_error "TELEGRAM_BOT_TOKEN environment variable is not set"
        echo ""
        echo "Set it to the same bot token your server uses:"
        echo "  export TELEGRAM_BOT_TOKEN='your-bot-token-here'"
        echo ""
        echo "You can find it in your .env file or config."
        exit 1
    fi

    print_success "Prerequisites OK (openssl, jq, TELEGRAM_BOT_TOKEN)"
}

# Compute Telegram auth hash (matching server's HMAC-SHA256 verification)
#
# Algorithm (from Telegram docs & server implementation):
#   1. Build data-check-string: sorted key=value pairs joined by newlines
#   2. secret_key = SHA256(bot_token)  (raw bytes)
#   3. hash = HMAC-SHA256(data_check_string, secret_key)  (hex encoded)
compute_telegram_hash() {
    local telegram_id="$1"
    local first_name="$2"
    local auth_date="$3"
    local username="$4"      # optional
    local last_name="$5"     # optional
    local photo_url="$6"     # optional

    # Build key=value pairs (only non-empty values, sorted alphabetically)
    local pairs=()
    pairs+=("auth_date=${auth_date}")
    pairs+=("first_name=${first_name}")
    pairs+=("id=${telegram_id}")
    [ -n "$last_name" ] && pairs+=("last_name=${last_name}")
    [ -n "$photo_url" ] && pairs+=("photo_url=${photo_url}")
    [ -n "$username" ] && pairs+=("username=${username}")

    # Sort alphabetically and join with newlines
    local data_check_string
    data_check_string=$(printf '%s\n' "${pairs[@]}" | sort | tr '\n' $'\n')
    # Remove trailing newline
    data_check_string="${data_check_string%$'\n'}"

    # Compute secret key: SHA256(bot_token) as hex
    local secret_key_hex
    secret_key_hex=$(printf '%s' "$TELEGRAM_BOT_TOKEN" | openssl dgst -sha256 -binary | xxd -p | tr -d '\n')

    # Compute HMAC-SHA256(data_check_string, secret_key)
    local hash
    hash=$(printf '%s' "$data_check_string" | openssl dgst -sha256 -mac hmac -macopt "hexkey:${secret_key_hex}" -binary | xxd -p | tr -d '\n')

    echo "$hash"
}

# Generate Telegram auth payload with valid hash
generate_telegram_payload() {
    local telegram_id="$1"
    local first_name="$2"
    local username="$3"      # optional, pass "" for none
    local last_name="$4"     # optional, pass "" for none

    local auth_date
    auth_date=$(date +%s)

    local hash
    hash=$(compute_telegram_hash "$telegram_id" "$first_name" "$auth_date" "$username" "$last_name")

    # Build JSON payload
    local username_json="null"
    local last_name_json="null"
    [ -n "$username" ] && username_json="\"$username\""
    [ -n "$last_name" ] && last_name_json="\"$last_name\""

    cat <<EOF
{
  "id": $telegram_id,
  "firstName": "$first_name",
  "lastName": $last_name_json,
  "username": $username_json,
  "photoUrl": null,
  "authDate": $auth_date,
  "hash": "$hash"
}
EOF
}

# Test: Telegram Login (new user registration via Telegram)
test_telegram_login() {
    print_header "TEST: Telegram Login (Register/Login via Telegram)"

    local TELEGRAM_ID="${1:-${TELEGRAM_USER_ID:-$(( RANDOM * 10000 + RANDOM ))}}"
    local FIRST_NAME="${2:-${TELEGRAM_FIRST_NAME:-TestUser}}"
    local USERNAME="${3:-${TELEGRAM_USERNAME:-testuser_$(date +%s)}}"

    print_info "Telegram ID: $TELEGRAM_ID"
    print_info "Name: $FIRST_NAME"
    print_info "Username: @$USERNAME"

    PAYLOAD=$(generate_telegram_payload "$TELEGRAM_ID" "$FIRST_NAME" "$USERNAME")

    print_info "Sending Telegram auth request..."
    echo "$PAYLOAD" | jq '.'

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/telegram" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo ""
    print_info "Response (HTTP $HTTP_CODE):"
    echo "$BODY" | jq '.'

    AUTH_TOKEN=$(echo "$BODY" | jq -r '.token')
    AUTH_USER_ID=$(echo "$BODY" | jq -r '.userId')

    if [ -n "$AUTH_TOKEN" ] && [ "$AUTH_TOKEN" != "null" ]; then
        print_success "Telegram login successful!"
        print_info "User ID: $AUTH_USER_ID"
        print_info "Token (first 20 chars): ${AUTH_TOKEN:0:20}..."

        # Save for subsequent tests
        echo "$AUTH_TOKEN" > /tmp/test_auth_token.txt
        echo "$AUTH_USER_ID" > /tmp/test_auth_user_id.txt
        echo "$TELEGRAM_ID" > /tmp/test_telegram_id.txt
        echo "$USERNAME" > /tmp/test_telegram_username.txt
    else
        print_error "Telegram login failed (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Telegram Login Again (same user, should return same user ID)
test_telegram_login_same_user() {
    print_header "TEST: Telegram Login Same User (Idempotent)"

    if [ ! -f /tmp/test_telegram_id.txt ]; then
        print_error "No Telegram test data found. Run 'login' test first."
        return 1
    fi

    local TELEGRAM_ID
    TELEGRAM_ID=$(cat /tmp/test_telegram_id.txt)
    local USERNAME
    USERNAME=$(cat /tmp/test_telegram_username.txt 2>/dev/null || echo "testuser")
    local ORIGINAL_USER_ID
    ORIGINAL_USER_ID=$(cat /tmp/test_auth_user_id.txt)

    print_info "Logging in again with same Telegram ID: $TELEGRAM_ID"

    PAYLOAD=$(generate_telegram_payload "$TELEGRAM_ID" "TestUser" "$USERNAME")

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/telegram" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    AUTH_USER_ID=$(echo "$BODY" | jq -r '.userId')
    AUTH_TOKEN=$(echo "$BODY" | jq -r '.token')

    if [ "$AUTH_USER_ID" = "$ORIGINAL_USER_ID" ]; then
        print_success "Same user returned (idempotent login)"
        print_info "User ID: $AUTH_USER_ID"
        echo "$AUTH_TOKEN" > /tmp/test_auth_token.txt
    else
        print_error "Different user ID returned!"
        print_info "Expected: $ORIGINAL_USER_ID"
        print_info "Got: $AUTH_USER_ID"
        return 1
    fi
}

# Test: View Profile After Telegram Login
test_telegram_profile() {
    print_header "TEST: View Profile After Telegram Login"

    if [ ! -f /tmp/test_auth_token.txt ]; then
        print_error "No auth token found. Run 'login' test first."
        return 1
    fi

    AUTH_TOKEN=$(cat /tmp/test_auth_token.txt)

    print_info "Fetching user profile..."
    RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/users/me" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$RESPONSE" | jq '.'

    HAS_PASSWORD=$(echo "$RESPONSE" | jq -r '.hasPassword')
    TELEGRAM_IDENTITY=$(echo "$RESPONSE" | jq -r '.telegramIdentity')
    EXTERNAL_ACCOUNT=$(echo "$RESPONSE" | jq -r '.externalAccountId')

    if [ "$TELEGRAM_IDENTITY" != "null" ]; then
        print_success "Telegram identity linked to profile"
    else
        print_info "No Telegram identity on profile (may be expected)"
    fi

    if [ "$HAS_PASSWORD" = "false" ]; then
        print_success "No password set (Telegram-only user)"
    else
        print_info "User has a password set"
    fi

    if [ "$EXTERNAL_ACCOUNT" != "null" ]; then
        print_success "External account created: $EXTERNAL_ACCOUNT"
        echo "$EXTERNAL_ACCOUNT" > /tmp/test_external_account_id.txt
    else
        print_info "No external account ID in profile"
    fi
}

# Test: Create Account After Telegram Login
test_create_account() {
    print_header "TEST: Create Account After Telegram Login"

    if [ ! -f /tmp/test_auth_token.txt ]; then
        print_error "No auth token found. Run 'login' test first."
        return 1
    fi

    AUTH_TOKEN=$(cat /tmp/test_auth_token.txt)

    local ACCOUNT_NAME="${1:-My Savings}"
    local INITIAL_BALANCE="${2:-1000.0}"

    print_info "Creating account: $ACCOUNT_NAME with balance \$$INITIAL_BALANCE"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "{\"name\": \"$ACCOUNT_NAME\", \"currency\": \"USD\", \"initialBalance\": $INITIAL_BALANCE}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    ACCOUNT_ID=$(echo "$BODY" | jq -r '.id')

    if [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "null" ]; then
        print_success "Account created: $ACCOUNT_ID"
        echo "$ACCOUNT_ID" > /tmp/test_telegram_account_id.txt
    else
        print_error "Failed to create account (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: List Accounts After Telegram Login
test_list_accounts() {
    print_header "TEST: List Accounts After Telegram Login"

    if [ ! -f /tmp/test_auth_token.txt ]; then
        print_error "No auth token found. Run 'login' test first."
        return 1
    fi

    AUTH_TOKEN=$(cat /tmp/test_auth_token.txt)

    print_info "Listing accounts..."
    RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$RESPONSE" | jq '.'

    TOTAL=$(echo "$RESPONSE" | jq -r '.totalCount')
    print_success "Found $TOTAL account(s)"
}

# Test: Telegram Login with Invalid Hash (expected failure)
test_invalid_hash() {
    print_header "TEST: Telegram Login with Invalid Hash (Expected Failure)"

    local auth_date
    auth_date=$(date +%s)

    PAYLOAD=$(cat <<EOF
{
  "id": 999999999,
  "firstName": "Hacker",
  "lastName": null,
  "username": "hacker",
  "photoUrl": null,
  "authDate": $auth_date,
  "hash": "0000000000000000000000000000000000000000000000000000000000000000"
}
EOF
)

    print_info "Sending request with forged hash..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/telegram" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" -ge 400 ]; then
        print_success "Invalid hash correctly rejected (HTTP $HTTP_CODE)"
    else
        print_error "Expected rejection but got HTTP $HTTP_CODE"
        return 1
    fi
}

# Test: Telegram Login with Expired Auth Date (expected failure)
test_expired_auth() {
    print_header "TEST: Telegram Login with Expired Auth Date (Expected Failure)"

    # Auth date 2 days ago (server allows max 24 hours)
    local expired_date
    expired_date=$(( $(date +%s) - 172800 ))

    local hash
    hash=$(compute_telegram_hash "888888888" "Expired" "$expired_date" "expired_user")

    PAYLOAD=$(cat <<EOF
{
  "id": 888888888,
  "firstName": "Expired",
  "lastName": null,
  "username": "expired_user",
  "photoUrl": null,
  "authDate": $expired_date,
  "hash": "$hash"
}
EOF
)

    print_info "Sending request with expired auth date (2 days ago)..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/telegram" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" -ge 400 ]; then
        print_success "Expired auth data correctly rejected (HTTP $HTTP_CODE)"
    else
        print_error "Expected rejection but got HTTP $HTTP_CODE"
        return 1
    fi
}

# Full workflow: Telegram login -> profile -> create accounts -> transfer
test_full_workflow() {
    print_header "FULL WORKFLOW: Telegram Login -> Create Accounts -> Transfer"

    local TELEGRAM_ID="${TELEGRAM_USER_ID:-$(( RANDOM * 10000 + RANDOM ))}"
    local FIRST_NAME="${TELEGRAM_FIRST_NAME:-TelegramUser}"
    local USERNAME="${TELEGRAM_USERNAME:-tg_workflow_$(date +%s)}"

    # Step 1: Login via Telegram
    print_step "Step 1: Login via Telegram"
    PAYLOAD=$(generate_telegram_payload "$TELEGRAM_ID" "$FIRST_NAME" "$USERNAME")
    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/telegram" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD")

    AUTH_TOKEN=$(echo "$RESPONSE" | jq -r '.token')
    USER_ID=$(echo "$RESPONSE" | jq -r '.userId')

    if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; then
        print_error "Telegram login failed"
        echo "$RESPONSE" | jq '.'
        return 1
    fi
    print_success "Logged in as $USER_ID"
    echo "$RESPONSE" | jq '.'

    # Step 2: View profile
    print_step "Step 2: View Profile"
    PROFILE=$(curl -s -X GET "${API_BASE_URL}/api/users/me" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    echo "$PROFILE" | jq '.'
    print_success "Profile retrieved"

    # Step 3: Create Savings account
    print_step "Step 3: Create Savings Account (\$1000)"
    SAVINGS_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Savings", "currency": "USD", "initialBalance": 1000.0}')

    SAVINGS_ID=$(echo "$SAVINGS_RESPONSE" | jq -r '.id')
    echo "$SAVINGS_RESPONSE" | jq '.'

    if [ -z "$SAVINGS_ID" ] || [ "$SAVINGS_ID" = "null" ]; then
        print_error "Failed to create Savings account"
        return 1
    fi
    print_success "Savings account: $SAVINGS_ID"

    # Step 4: Create Checking account
    print_step "Step 4: Create Checking Account (\$500)"
    CHECKING_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Checking", "currency": "USD", "initialBalance": 500.0}')

    CHECKING_ID=$(echo "$CHECKING_RESPONSE" | jq -r '.id')
    echo "$CHECKING_RESPONSE" | jq '.'

    if [ -z "$CHECKING_ID" ] || [ "$CHECKING_ID" = "null" ]; then
        print_error "Failed to create Checking account"
        return 1
    fi
    print_success "Checking account: $CHECKING_ID"

    # Step 5: Transfer money
    print_step "Step 5: Transfer \$200 (Savings -> Checking)"
    TRANSFER_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/transfer" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "{\"fromAccountId\": \"$SAVINGS_ID\", \"toAccountId\": \"$CHECKING_ID\", \"amount\": 200.0, \"currency\": \"USD\", \"category\": \"other\", \"reason\": \"Telegram test transfer\"}")

    TRANSACTION_ID=$(echo "$TRANSFER_RESPONSE" | jq -r '.id')
    echo "$TRANSFER_RESPONSE" | jq '.'
    print_success "Transfer initiated: $TRANSACTION_ID"

    # Step 6: Poll for completion
    print_step "Step 6: Wait for Transfer Completion"
    for i in {1..10}; do
        sleep 1
        STATUS_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions/${TRANSACTION_ID}" \
            -H "Authorization: Bearer $AUTH_TOKEN")
        STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')

        if [ "$STATUS" = "Completed" ]; then
            print_success "Transfer completed!"
            break
        elif [ "$STATUS" = "Failed" ]; then
            REASON=$(echo "$STATUS_RESPONSE" | jq -r '.failureReason')
            print_error "Transfer failed: $REASON"
            break
        fi
        print_info "Status: $STATUS (attempt $i/10)..."
    done

    # Step 7: Verify balances
    print_step "Step 7: Verify Final Balances"
    FINAL_SAVINGS=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${SAVINGS_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    FINAL_CHECKING=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${CHECKING_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    SAVINGS_BALANCE=$(echo "$FINAL_SAVINGS" | jq -r '.balance')
    CHECKING_BALANCE=$(echo "$FINAL_CHECKING" | jq -r '.balance')

    echo ""
    echo -e "${CYAN}Summary:${NC}"
    echo "  User:     $USER_ID (Telegram @$USERNAME)"
    echo "  Savings:  \$$SAVINGS_BALANCE (expected: \$800)"
    echo "  Checking: \$$CHECKING_BALANCE (expected: \$700)"
    echo ""

    print_success "Full Telegram workflow completed!"
}

# Main menu
main() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Telegram Auth API Testing Script        ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"

    check_server
    check_prerequisites

    if [ $# -eq 0 ]; then
        echo ""
        echo "Usage: $0 [test_name] [--prod|--local]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  login            - Login/register via Telegram"
        echo "  login-same       - Login again with same Telegram ID (idempotent)"
        echo "  profile          - View profile after Telegram login"
        echo "  create-account   - Create an account after Telegram login"
        echo "  list-accounts    - List accounts"
        echo "  invalid-hash     - Test with forged hash (expected failure)"
        echo "  expired          - Test with expired auth date (expected failure)"
        echo "  workflow         - Full workflow: login -> accounts -> transfer"
        echo ""
        echo "Endpoint flags:"
        echo "  --local          - Use http://localhost:8080 (default)"
        echo "  --prod           - Use https://homeaccounting.com"
        echo "  API_BASE_URL=... - Override with any URL"
        echo ""
        echo "Environment variables:"
        echo "  TELEGRAM_BOT_TOKEN   - Required. Must match the server's bot token."
        echo "  TELEGRAM_USER_ID     - Your real Telegram user ID (used as default for login)"
        echo "  TELEGRAM_FIRST_NAME  - Your first name (used as default for login)"
        echo "  TELEGRAM_USERNAME    - Your Telegram username without @ (used as default for login)"
        echo ""
        echo "Examples:"
        echo "  $0 login                           # Login with your real Telegram identity"
        echo "  $0 workflow --prod                  # Full end-to-end against production"
        echo "  $0 login 99999 Other otheruser      # Override with specific values"
        echo ""
        exit 0
    fi

    case "$1" in
        all)
            test_telegram_login
            test_telegram_login_same_user
            test_telegram_profile
            test_create_account "Test Account" "500"
            test_list_accounts
            test_invalid_hash
            test_expired_auth
            print_header "ALL TELEGRAM TESTS COMPLETED"
            ;;
        login)
            test_telegram_login "$2" "$3" "$4"
            ;;
        login-same)
            test_telegram_login_same_user
            ;;
        profile)
            test_telegram_profile
            ;;
        create-account)
            test_create_account "$2" "$3"
            ;;
        list-accounts)
            test_list_accounts
            ;;
        invalid-hash)
            test_invalid_hash
            ;;
        expired)
            test_expired_auth
            ;;
        workflow)
            test_full_workflow
            ;;
        *)
            print_error "Unknown test: $1"
            echo "Run '$0' without arguments to see available tests."
            exit 1
            ;;
    esac
}

main "$@"
