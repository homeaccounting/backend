#!/bin/bash

# Transaction API Testing Script
# Tests transaction-related endpoints (income, expense, transfers)
#
# Note: Transaction endpoints require JWT authentication.
# This script will auto-register a test user if no token is saved.
#
# Note: set -e is NOT used so all tests run even when individual assertions fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PAYLOADS_DIR="${SCRIPT_DIR}/payloads/transactions"

# Setup: Create two accounts for transfer testing
setup_accounts() {
    print_header "SETUP: Creating Test Accounts"

    ensure_authenticated

    # Create source account
    print_info "Creating source account (Savings, \$1000)..."
    SOURCE_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Transfer Test - Source", "currency": "USD", "initialBalance": 1000.0}')

    SOURCE_ACCOUNT_ID=$(echo "$SOURCE_RESPONSE" | jq -r '.id')
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
        -d '{"name": "Transfer Test - Target", "currency": "USD", "initialBalance": 500.0}')

    TARGET_ACCOUNT_ID=$(echo "$TARGET_RESPONSE" | jq -r '.id')
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

# Test: Initiate Income
test_initiate_income() {
    print_header "TEST: Initiate Income"

    ensure_authenticated

    if [ ! -f /tmp/test_source_account_id.txt ]; then
        print_error "Accounts not set up. Run setup first."
        return 1
    fi

    SOURCE_ACCOUNT_ID=$(cat /tmp/test_source_account_id.txt)

    print_info "Recording income of \$500 to $SOURCE_ACCOUNT_ID"

    INCOME_PAYLOAD=$(cat <<EOF
{
  "accountId": "$SOURCE_ACCOUNT_ID",
  "amount": 500.0,
  "currency": "USD",
  "category": "salary",
  "reason": "Test income - Monthly salary"
}
EOF
)

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/income" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$INCOME_PAYLOAD")

    echo "$RESPONSE" | jq '.'

    TRANSACTION_ID=$(echo "$RESPONSE" | jq -r '.id')
    TRANSACTION_STATUS=$(echo "$RESPONSE" | jq -r '.status')

    if [ -n "$TRANSACTION_ID" ] && [ "$TRANSACTION_ID" != "null" ]; then
        print_success "Income recorded. Transaction ID: $TRANSACTION_ID"
        print_info "Initial status: $TRANSACTION_STATUS"
        echo "$TRANSACTION_ID" > /tmp/test_income_transaction_id.txt
    else
        print_error "Failed to record income"
        return 1
    fi
}

# Test: Initiate Expense
test_initiate_expense() {
    print_header "TEST: Initiate Expense"

    ensure_authenticated

    if [ ! -f /tmp/test_source_account_id.txt ]; then
        print_error "Accounts not set up. Run setup first."
        return 1
    fi

    SOURCE_ACCOUNT_ID=$(cat /tmp/test_source_account_id.txt)

    print_info "Recording expense of \$100 from $SOURCE_ACCOUNT_ID"

    EXPENSE_PAYLOAD=$(cat <<EOF
{
  "accountId": "$SOURCE_ACCOUNT_ID",
  "amount": 100.0,
  "currency": "USD",
  "category": "food",
  "reason": "Test expense - Groceries"
}
EOF
)

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/expense" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$EXPENSE_PAYLOAD")

    echo "$RESPONSE" | jq '.'

    TRANSACTION_ID=$(echo "$RESPONSE" | jq -r '.id')
    TRANSACTION_STATUS=$(echo "$RESPONSE" | jq -r '.status')

    if [ -n "$TRANSACTION_ID" ] && [ "$TRANSACTION_ID" != "null" ]; then
        print_success "Expense recorded. Transaction ID: $TRANSACTION_ID"
        print_info "Initial status: $TRANSACTION_STATUS"
        echo "$TRANSACTION_ID" > /tmp/test_expense_transaction_id.txt
    else
        print_error "Failed to record expense"
        return 1
    fi
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
  "currency": "USD",
  "category": "other",
  "reason": "Test transfer - Rent payment"
}
EOF
)

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/transfer" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$TRANSFER_PAYLOAD")

    echo "$RESPONSE" | jq '.'

    TRANSACTION_ID=$(echo "$RESPONSE" | jq -r '.id')
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
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/transactions/transfer" \
        -H "Content-Type: application/json" \
        -d '{
            "fromAccountId": "00000000-0000-0000-0000-000000000001",
            "toAccountId": "00000000-0000-0000-0000-000000000002",
            "amount": 100.0,
            "currency": "USD",
            "category": "other",
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
    SOURCE_BALANCE=$(echo "$SOURCE_RESPONSE" | jq -r '.balance')
    echo "$SOURCE_RESPONSE" | jq '.'
    print_info "Source account balance: \$${SOURCE_BALANCE}"

    # Check target account
    print_info "Checking target account balance..."
    TARGET_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${TARGET_ACCOUNT_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    TARGET_BALANCE=$(echo "$TARGET_RESPONSE" | jq -r '.balance')
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
  "currency": "USD",
  "category": "other",
  "reason": "Test transfer - Should fail"
}
EOF
)

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/transfer" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$TRANSFER_PAYLOAD")

    echo "$RESPONSE" | jq '.'

    TRANSACTION_ID=$(echo "$RESPONSE" | jq -r '.id')

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
        echo "Usage: $0 [test_name] [--prod|--local]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  setup            - Create test accounts (requires auth)"
        echo "  income           - Record an income transaction (requires auth)"
        echo "  expense          - Record an expense transaction (requires auth)"
        echo "  initiate         - Initiate a transfer (requires auth)"
        echo "  unauthorized     - Test transfer without auth (expected 401)"
        echo "  status           - Get transaction status"
        echo "  verify           - Verify account balances"
        echo "  insufficient     - Test insufficient funds scenario"
        echo ""
        echo "Endpoint flags:"
        echo "  --local          - Use http://localhost:8080 (default)"
        echo "  --prod           - Use https://homeaccounting.com"
        echo "  API_BASE_URL=... - Override with any URL"
        echo ""
        echo "Example: $0 all --prod"
        exit 0
    fi

    case "$1" in
        all)
            setup_accounts
            test_initiate_income
            test_initiate_expense
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
        income)
            test_initiate_income
            ;;
        expense)
            test_initiate_expense
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
