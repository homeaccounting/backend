#!/bin/bash

# Transaction API Testing Script
# Tests transaction-related endpoints (money transfers)
#
# Note: Transfer initiation requires JWT authentication.
# This script will auto-register a test user if no token is saved.
#
# Note: set -e is NOT used so all tests run even when individual assertions fail.

# Configuration
API_BASE_URL="http://localhost:8080"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOADS_DIR="${SCRIPT_DIR}/payloads/transactions"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}→ $1${NC}"
}

# Check if server is running
check_server() {
    print_info "Checking if server is running..."
    if curl -s -o /dev/null -w "%{http_code}" "${API_BASE_URL}/api/nonexistent" 2>&1 | grep -q "404"; then
        print_success "Server is running at ${API_BASE_URL}"
    else
        print_error "Server is not running at ${API_BASE_URL}"
        echo "Please start the server with: cabal run accounting"
        exit 1
    fi
}

# Ensure we have a valid auth token
ensure_authenticated() {
    if [ -f /tmp/test_auth_token.txt ]; then
        AUTH_TOKEN=$(cat /tmp/test_auth_token.txt)
        print_info "Using saved auth token"
    else
        print_info "No saved token found. Registering a new test user..."
        TEST_EMAIL="txtest-$(date +%s)@example.com"
        TEST_PASSWORD="SecurePass123!"

        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
            -H "Content-Type: application/json" \
            -d "{\"registerEmail\": \"$TEST_EMAIL\", \"registerPassword\": \"$TEST_PASSWORD\"}")

        AUTH_TOKEN=$(echo "$RESPONSE" | jq -r '.authToken')

        if [ -n "$AUTH_TOKEN" ] && [ "$AUTH_TOKEN" != "null" ]; then
            echo "$AUTH_TOKEN" > /tmp/test_auth_token.txt
            echo "$TEST_EMAIL" > /tmp/test_auth_email.txt
            echo "$TEST_PASSWORD" > /tmp/test_auth_password.txt
            print_success "Test user registered: $TEST_EMAIL"
        else
            print_error "Failed to register test user"
            echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
            exit 1
        fi
    fi
}

# Setup: Create two accounts for transfer testing
setup_accounts() {
    print_header "SETUP: Creating Test Accounts"

    ensure_authenticated

    # Create source account
    print_info "Creating source account (Savings, \$1000)..."
    SOURCE_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"accountName": "Transfer Test - Source", "initialBalance": 1000.0}')

    SOURCE_ACCOUNT_ID=$(echo "$SOURCE_RESPONSE" | jq -r '.accountId')
    echo "$SOURCE_RESPONSE" | jq '.'

    if [ -n "$SOURCE_ACCOUNT_ID" ] && [ "$SOURCE_ACCOUNT_ID" != "null" ]; then
        print_success "Source account created: $SOURCE_ACCOUNT_ID"
    else
        print_error "Failed to create source account"
        return 1
    fi

    # Create target account
    print_info "Creating target account (Checking, \$500)..."
    TARGET_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"accountName": "Transfer Test - Target", "initialBalance": 500.0}')

    TARGET_ACCOUNT_ID=$(echo "$TARGET_RESPONSE" | jq -r '.accountId')
    echo "$TARGET_RESPONSE" | jq '.'

    if [ -n "$TARGET_ACCOUNT_ID" ] && [ "$TARGET_ACCOUNT_ID" != "null" ]; then
        print_success "Target account created: $TARGET_ACCOUNT_ID"
    else
        print_error "Failed to create target account"
        return 1
    fi

    # Save IDs for subsequent tests
    echo "$SOURCE_ACCOUNT_ID" > /tmp/test_source_account_id.txt
    echo "$TARGET_ACCOUNT_ID" > /tmp/test_target_account_id.txt
}

# Test: Initiate Transfer
test_initiate_transfer() {
    print_header "TEST: Initiate Transfer"

    ensure_authenticated

    if [ ! -f /tmp/test_source_account_id.txt ] || [ ! -f /tmp/test_target_account_id.txt ]; then
        print_error "Accounts not set up. Run setup first."
        return 1
    fi

    SOURCE_ACCOUNT_ID=$(cat /tmp/test_source_account_id.txt)
    TARGET_ACCOUNT_ID=$(cat /tmp/test_target_account_id.txt)

    print_info "Initiating transfer of \$300 from $SOURCE_ACCOUNT_ID to $TARGET_ACCOUNT_ID"

    TRANSFER_PAYLOAD=$(cat <<EOF
{
  "fromAccountId": "$SOURCE_ACCOUNT_ID",
  "toAccountId": "$TARGET_ACCOUNT_ID",
  "amount": 300.0,
  "reason": "Test transfer - Rent payment"
}
EOF
)

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$TRANSFER_PAYLOAD")

    echo "$RESPONSE" | jq '.'

    TRANSACTION_ID=$(echo "$RESPONSE" | jq -r '.transactionId')
    TRANSACTION_STATUS=$(echo "$RESPONSE" | jq -r '.status')

    if [ -n "$TRANSACTION_ID" ] && [ "$TRANSACTION_ID" != "null" ]; then
        print_success "Transfer initiated. Transaction ID: $TRANSACTION_ID"
        print_info "Initial status: $TRANSACTION_STATUS"
        echo "$TRANSACTION_ID" > /tmp/test_transaction_id.txt
    else
        print_error "Failed to initiate transfer"
        return 1
    fi
}

# Test: Initiate Transfer Without Auth (expected 401)
test_transfer_unauthorized() {
    print_header "TEST: Initiate Transfer Without Auth (Expected 401)"

    print_info "Attempting to create transfer without token..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/transactions" \
        -H "Content-Type: application/json" \
        -d '{
            "fromAccountId": "00000000-0000-0000-0000-000000000001",
            "toAccountId": "00000000-0000-0000-0000-000000000002",
            "amount": 100.0,
            "reason": "Unauthorized transfer"
        }')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "401" ]; then
        print_success "Correctly returned 401 Unauthorized"
    else
        print_info "Got HTTP $HTTP_CODE (expected 401)"
    fi
}

# Test: Get Transaction Status
test_get_transaction() {
    print_header "TEST: Get Transaction Status"

    ensure_authenticated

    if [ ! -f /tmp/test_transaction_id.txt ]; then
        print_error "No transaction ID found. Run initiate test first."
        return 1
    fi

    TRANSACTION_ID=$(cat /tmp/test_transaction_id.txt)
    print_info "Getting transaction status: $TRANSACTION_ID"

    # Poll for transaction completion (max 5 attempts)
    for i in {1..5}; do
        print_info "Polling attempt $i/5..."

        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions/${TRANSACTION_ID}" \
            -H "Authorization: Bearer $AUTH_TOKEN")
        echo "$RESPONSE" | jq '.'

        STATUS=$(echo "$RESPONSE" | jq -r '.status')

        if [ "$STATUS" = "Completed" ]; then
            print_success "Transaction completed successfully!"
            return 0
        elif [ "$STATUS" = "Failed" ]; then
            FAILURE_REASON=$(echo "$RESPONSE" | jq -r '.failureReason')
            print_error "Transaction failed: $FAILURE_REASON"
            return 1
        elif [ "$STATUS" = "Pending" ]; then
            print_info "Transaction still pending..."
            if [ $i -lt 5 ]; then
                sleep 2
            fi
        fi
    done

    print_error "Transaction did not complete within timeout"
    return 1
}

# Test: Verify Account Balances After Transfer
test_verify_balances() {
    print_header "TEST: Verify Account Balances"

    ensure_authenticated

    if [ ! -f /tmp/test_source_account_id.txt ] || [ ! -f /tmp/test_target_account_id.txt ]; then
        print_error "Accounts not set up."
        return 1
    fi

    SOURCE_ACCOUNT_ID=$(cat /tmp/test_source_account_id.txt)
    TARGET_ACCOUNT_ID=$(cat /tmp/test_target_account_id.txt)

    # Check source account
    print_info "Checking source account balance..."
    SOURCE_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${SOURCE_ACCOUNT_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    SOURCE_BALANCE=$(echo "$SOURCE_RESPONSE" | jq -r '.currentBalance')
    echo "$SOURCE_RESPONSE" | jq '.'
    print_info "Source account balance: \$${SOURCE_BALANCE}"

    # Check target account
    print_info "Checking target account balance..."
    TARGET_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${TARGET_ACCOUNT_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    TARGET_BALANCE=$(echo "$TARGET_RESPONSE" | jq -r '.currentBalance')
    echo "$TARGET_RESPONSE" | jq '.'
    print_info "Target account balance: \$${TARGET_BALANCE}"

    print_success "Balance verification complete"
}

# Test: Transfer with Insufficient Funds
test_insufficient_funds_transfer() {
    print_header "TEST: Transfer with Insufficient Funds (Expected Failure)"

    ensure_authenticated

    if [ ! -f /tmp/test_source_account_id.txt ] || [ ! -f /tmp/test_target_account_id.txt ]; then
        print_error "Accounts not set up. Run setup first."
        return 1
    fi

    SOURCE_ACCOUNT_ID=$(cat /tmp/test_source_account_id.txt)
    TARGET_ACCOUNT_ID=$(cat /tmp/test_target_account_id.txt)

    print_info "Attempting transfer of \$10000 (should fail)..."

    TRANSFER_PAYLOAD=$(cat <<EOF
{
  "fromAccountId": "$SOURCE_ACCOUNT_ID",
  "toAccountId": "$TARGET_ACCOUNT_ID",
  "amount": 10000.0,
  "reason": "Test transfer - Should fail"
}
EOF
)

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$TRANSFER_PAYLOAD")

    echo "$RESPONSE" | jq '.'

    TRANSACTION_ID=$(echo "$RESPONSE" | jq -r '.transactionId')

    if [ -n "$TRANSACTION_ID" ] && [ "$TRANSACTION_ID" != "null" ]; then
        print_info "Transfer initiated (will fail). Transaction ID: $TRANSACTION_ID"

        # Poll for failure
        for i in {1..5}; do
            sleep 1
            STATUS_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions/${TRANSACTION_ID}" \
                -H "Authorization: Bearer $AUTH_TOKEN")
            STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')

            if [ "$STATUS" = "Failed" ]; then
                FAILURE_REASON=$(echo "$STATUS_RESPONSE" | jq -r '.failureReason')
                echo "$STATUS_RESPONSE" | jq '.'
                print_success "Transfer correctly failed: $FAILURE_REASON"
                return 0
            fi
        done

        print_error "Transfer did not fail as expected"
    fi
}

# Main menu
main() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Transaction API Testing Script         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"

    check_server

    if [ $# -eq 0 ]; then
        echo ""
        echo "Usage: $0 [test_name]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  setup            - Create test accounts (requires auth)"
        echo "  initiate         - Initiate a transfer (requires auth)"
        echo "  unauthorized     - Test transfer without auth (expected 401)"
        echo "  status           - Get transaction status"
        echo "  verify           - Verify account balances"
        echo "  insufficient     - Test insufficient funds scenario"
        echo ""
        echo "Example: $0 all"
        exit 0
    fi

    case "$1" in
        all)
            setup_accounts
            test_initiate_transfer
            test_transfer_unauthorized
            test_get_transaction
            test_verify_balances
            test_insufficient_funds_transfer
            print_header "ALL TESTS COMPLETED"
            ;;
        setup)
            setup_accounts
            ;;
        initiate)
            test_initiate_transfer
            ;;
        unauthorized)
            test_transfer_unauthorized
            ;;
        status)
            test_get_transaction
            ;;
        verify)
            test_verify_balances
            ;;
        insufficient)
            test_insufficient_funds_transfer
            ;;
        *)
            print_error "Unknown test: $1"
            echo "Run '$0' without arguments to see available tests."
            exit 1
            ;;
    esac
}

main "$@"
