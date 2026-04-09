#!/bin/bash

# Full API Workflow Testing Script
# Demonstrates complete lifecycle: register, login, create accounts, transfer, profile

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

# Check if jq is installed
check_jq() {
    if ! command -v jq &> /dev/null; then
        print_error "jq is not installed. Install it for pretty JSON output:"
        echo "    macOS:        brew install jq"
        echo "    Ubuntu/Debian: sudo apt-get install jq"
        exit 1
    fi
}

# Wait for async operations
wait_for_completion() {
    local message=$1
    local duration=${2:-2}
    print_info "$message"
    sleep $duration
}

# Main workflow
main() {
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                                                        ║${NC}"
    echo -e "${GREEN}║        Accounting Backend - Full API Workflow          ║${NC}"
    echo -e "${GREEN}║                                                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"

    check_jq
    check_server

    # Generate unique test credentials
    TEST_EMAIL="fulltest-$(date +%s)@example.com"
    TEST_PASSWORD="SecurePass123!"

    # ============================================================
    # Step 1: Register a New User
    # ============================================================
    print_step "Step 1: Register a New User"

    print_info "Registering user: $TEST_EMAIL"
    REGISTER_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_EMAIL\", \"password\": \"$TEST_PASSWORD\"}")

    AUTH_TOKEN=$(echo "$REGISTER_RESPONSE" | jq -r '.token')
    USER_ID=$(echo "$REGISTER_RESPONSE" | jq -r '.userId')
    EXPIRES_IN=$(echo "$REGISTER_RESPONSE" | jq -r '.expiresIn')

    echo "$REGISTER_RESPONSE" | jq '.'

    if [ -z "$AUTH_TOKEN" ] || [ "$AUTH_TOKEN" = "null" ]; then
        print_error "Registration failed"
        exit 1
    fi

    print_success "User registered successfully"
    print_info "User ID: $USER_ID"
    print_info "Token expires in: ${EXPIRES_IN}s"

    # ============================================================
    # Step 2: Login with Credentials
    # ============================================================
    print_step "Step 2: Login with Credentials"

    print_info "Logging in as: $TEST_EMAIL"
    LOGIN_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_EMAIL\", \"password\": \"$TEST_PASSWORD\"}")

    AUTH_TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

    echo "$LOGIN_RESPONSE" | jq '.'
    print_success "Login successful"

    # ============================================================
    # Step 3: Get User Profile
    # ============================================================
    print_step "Step 3: Get User Profile"

    print_info "Fetching user profile..."
    PROFILE_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/users/me" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$PROFILE_RESPONSE" | jq '.'

    PROFILE_EMAIL=$(echo "$PROFILE_RESPONSE" | jq -r '.email')
    HAS_PASSWORD=$(echo "$PROFILE_RESPONSE" | jq -r '.hasPassword')

    print_success "Profile retrieved"
    print_info "Email: $PROFILE_EMAIL"
    print_info "Has Password: $HAS_PASSWORD"

    # ============================================================
    # Step 4: Check User Configuration
    # ============================================================
    print_step "Step 4: Check User Configuration"

    print_info "Fetching user configuration..."
    CONFIG_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/users/me/configuration" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$CONFIG_RESPONSE" | jq '.'

    BASE_CUR=$(echo "$CONFIG_RESPONSE" | jq -r '.baseCurrency')
    INCOME_COUNT=$(echo "$CONFIG_RESPONSE" | jq '.dictionaries["income-category"].entries | length')
    EXPENSE_COUNT=$(echo "$CONFIG_RESPONSE" | jq '.dictionaries["expense-category"].entries | length')

    print_success "Configuration loaded"
    print_info "Base currency: $BASE_CUR"
    print_info "Income categories: $INCOME_COUNT"
    print_info "Expense categories: $EXPENSE_COUNT"

    # Save a category UUID for later income/expense tests
    CONFIG_JSON="$CONFIG_RESPONSE"
    SALARY_CAT_ID=$(echo "$CONFIG_JSON" | jq -r '.dictionaries["income-category"].entries[] | select(.name == "Salary") | .id')
    FOOD_CAT_ID=$(echo "$CONFIG_JSON" | jq -r '.dictionaries["expense-category"].entries[] | select(.name == "Food") | .id')
    print_info "Salary category ID: $SALARY_CAT_ID"
    print_info "Food category ID: $FOOD_CAT_ID"

    # ============================================================
    # Step 5: Create Savings Account
    # ============================================================
    print_step "Step 5: Create Savings Account"

    print_info "Creating Savings Account with initial balance of \$1000..."
    SAVINGS_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Savings Account", "currency": "USD", "initialBalance": 1000.0}')

    SAVINGS_ID=$(echo "$SAVINGS_RESPONSE" | jq -r '.id')
    SAVINGS_BALANCE=$(echo "$SAVINGS_RESPONSE" | jq -r '.balance')

    echo "$SAVINGS_RESPONSE" | jq '.'
    print_success "Savings Account created"
    print_balance "Account ID: $SAVINGS_ID"
    print_balance "Initial Balance: \$${SAVINGS_BALANCE}"

    # ============================================================
    # Step 6: Create Checking Account
    # ============================================================
    print_step "Step 6: Create Checking Account"

    print_info "Creating Checking Account with initial balance of \$500..."
    CHECKING_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Checking Account", "currency": "USD", "initialBalance": 500.0}')

    CHECKING_ID=$(echo "$CHECKING_RESPONSE" | jq -r '.id')
    CHECKING_BALANCE=$(echo "$CHECKING_RESPONSE" | jq -r '.balance')

    echo "$CHECKING_RESPONSE" | jq '.'
    print_success "Checking Account created"
    print_balance "Account ID: $CHECKING_ID"
    print_balance "Initial Balance: \$${CHECKING_BALANCE}"

    # ============================================================
    # Step 7: List All Accounts
    # ============================================================
    print_step "Step 7: List All Accounts"

    print_info "Retrieving list of all accounts..."
    LIST_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$LIST_RESPONSE" | jq '.'

    TOTAL_ACCOUNTS=$(echo "$LIST_RESPONSE" | jq -r '.totalCount')
    print_success "Found $TOTAL_ACCOUNTS account(s)"

    # ============================================================
    # Step 8: Initiate Transfer (Savings -> Checking)
    # ============================================================
    print_step "Step 8: Initiate Transfer (Savings -> Checking)"

    print_info "Transferring \$300 from Savings to Checking..."

    TRANSFER_PAYLOAD=$(cat <<EOF
{
  "sourceAccountId": "$SAVINGS_ID",
  "targetAccountId": "$CHECKING_ID",
  "amount": 300.0,
  "currency": "USD",
  "description": "Transfer to checking for bills"
}
EOF
)

    TRANSFER_RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/transfer" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$TRANSFER_PAYLOAD")

    TRANSACTION_ID=$(echo "$TRANSFER_RESPONSE" | jq -r '.id')
    TRANSACTION_STATUS=$(echo "$TRANSFER_RESPONSE" | jq -r '.status')

    echo "$TRANSFER_RESPONSE" | jq '.'
    print_success "Transfer initiated"
    print_info "Transaction ID: $TRANSACTION_ID"
    print_info "Initial Status: $TRANSACTION_STATUS"

    # ============================================================
    # Step 9: Poll Transaction Status
    # ============================================================
    print_step "Step 9: Monitor Transaction Status"

    print_info "Polling for transaction completion..."

    for i in {1..10}; do
        wait_for_completion "Checking status (attempt $i/10)..." 1

        STATUS_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions/${TRANSACTION_ID}" \
            -H "Authorization: Bearer $AUTH_TOKEN")
        STATUS=$(echo "$STATUS_RESPONSE" | jq -r '.status')

        echo "$STATUS_RESPONSE" | jq '.'

        if [ "$STATUS" = "Completed" ]; then
            print_success "Transaction completed successfully!"
            break
        elif [ "$STATUS" = "Failed" ]; then
            FAILURE_REASON=$(echo "$STATUS_RESPONSE" | jq -r '.failureReason')
            print_error "Transaction failed: $FAILURE_REASON"
            exit 1
        elif [ "$STATUS" = "Pending" ]; then
            print_info "Transaction still pending..."
        fi

        if [ $i -eq 10 ]; then
            print_error "Transaction did not complete within timeout"
            exit 1
        fi
    done

    # ============================================================
    # Step 10: Share Account with Another User
    # ============================================================
    print_step "Step 10: Share Account with Another User"

    SECOND_EMAIL="second-$(date +%s)@example.com"
    SECOND_PASSWORD="SecurePass456!"

    print_info "Registering a second user: $SECOND_EMAIL"
    SECOND_REGISTER=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$SECOND_EMAIL\", \"password\": \"$SECOND_PASSWORD\"}")

    SECOND_USER_ID=$(echo "$SECOND_REGISTER" | jq -r '.userId')
    print_success "Second user registered: $SECOND_USER_ID"

    print_info "Sharing Savings Account with second user (role: viewer)..."
    SHARE_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        "${API_BASE_URL}/api/accounts/${SAVINGS_ID}/share" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "{\"userId\": \"$SECOND_USER_ID\", \"role\": \"viewer\"}")

    SHARE_CODE=$(echo "$SHARE_RESPONSE" | tail -n1)
    SHARE_BODY=$(echo "$SHARE_RESPONSE" | sed '$d')

    echo "$SHARE_BODY" | jq '.' 2>/dev/null || echo "$SHARE_BODY"

    if [ "$SHARE_CODE" = "204" ] || [ "$SHARE_CODE" = "200" ]; then
        print_success "Account shared successfully"
    else
        print_info "Share returned HTTP $SHARE_CODE"
    fi

    # ============================================================
    # Step 11: Verify Final Balances
    # ============================================================
    print_step "Step 11: Verify Final Account Balances"

    print_info "Retrieving final Savings Account balance..."
    FINAL_SAVINGS=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${SAVINGS_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    FINAL_SAVINGS_BALANCE=$(echo "$FINAL_SAVINGS" | jq -r '.balance')
    echo "$FINAL_SAVINGS" | jq '.'

    print_info "Retrieving final Checking Account balance..."
    FINAL_CHECKING=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${CHECKING_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    FINAL_CHECKING_BALANCE=$(echo "$FINAL_CHECKING" | jq -r '.balance')
    echo "$FINAL_CHECKING" | jq '.'

    # ============================================================
    # Summary
    # ============================================================
    print_header "WORKFLOW SUMMARY"

    echo -e "${CYAN}User:${NC}"
    echo -e "  Email:                  $TEST_EMAIL"
    echo -e "  User ID:                $USER_ID"
    echo ""

    echo -e "${CYAN}Savings Account Journey:${NC}"
    echo -e "  1. Created with:        \$1000.00"
    echo -e "  2. Transferred out:     -\$300.00"
    echo -e "${GREEN}  Final Balance:          \$${FINAL_SAVINGS_BALANCE}${NC}"
    echo ""

    echo -e "${CYAN}Checking Account Journey:${NC}"
    echo -e "  1. Created with:        \$500.00"
    echo -e "  2. Transferred in:      +\$300.00"
    echo -e "${GREEN}  Final Balance:          \$${FINAL_CHECKING_BALANCE}${NC}"
    echo ""

    echo -e "${CYAN}Transaction Summary:${NC}"
    echo -e "  Transaction ID:         $TRANSACTION_ID"
    echo -e "  Status:                 ${GREEN}Completed${NC}"
    echo -e "  Amount Transferred:     \$300.00"
    echo ""

    echo -e "${CYAN}Sharing:${NC}"
    echo -e "  Shared Savings with:    $SECOND_USER_ID (viewer)"
    echo ""

    # Verify conservation of money
    TOTAL_INITIAL=$((1000 + 500))
    EXPECTED_TOTAL=$TOTAL_INITIAL

    ACTUAL_TOTAL=$(echo "$FINAL_SAVINGS_BALANCE + $FINAL_CHECKING_BALANCE" | bc)

    echo -e "${CYAN}Money Conservation Check:${NC}"
    echo -e "  Expected Total:         \$${EXPECTED_TOTAL}.00"
    echo -e "  Actual Total:           \$${ACTUAL_TOTAL}"

    if [ "$ACTUAL_TOTAL" = "${EXPECTED_TOTAL}.0" ] || [ "$ACTUAL_TOTAL" = "${EXPECTED_TOTAL}" ]; then
        print_success "Money conservation verified!"
    else
        print_error "Money conservation check failed!"
    fi

    echo ""
    print_header "ALL TESTS COMPLETED SUCCESSFULLY"
    echo ""

    print_info "Test accounts created:"
    echo "  Savings:  $SAVINGS_ID"
    echo "  Checking: $CHECKING_ID"
    echo ""
    print_info "You can query these accounts anytime with:"
    echo "  curl ${API_BASE_URL}/api/accounts/${SAVINGS_ID} | jq"
    echo ""
}

main "$@"
