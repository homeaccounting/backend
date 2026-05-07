#!/bin/bash

# Account API Testing Script
# Tests all account-related endpoints (create, get, list, share, revoke access)
#
# Note: Account creation and sharing require JWT authentication.
# This script will auto-register a test user if no token is saved.
#
# Note: set -e is NOT used so all tests run even when individual assertions fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PAYLOADS_DIR="${SCRIPT_DIR}/payloads/accounts"

# Register (or log in) a second user and capture their ID into TEST_USER2_ID.
# Honors TEST_USER2_EMAIL/TEST_USER2_PASSWORD from .env when set.
register_second_user() {
    resolve_user2_credentials

    local response token
    response=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_USER2_EMAIL\", \"password\": \"$TEST_USER2_PASSWORD\"}")

    token=$(echo "$response" | jq -r '.token')
    TEST_USER2_ID=$(echo "$response" | jq -r '.userId')

    # If the second user already exists (fixed email from .env), fall back to login.
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        response=$(curl -s -X POST "${API_BASE_URL}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"email\": \"$TEST_USER2_EMAIL\", \"password\": \"$TEST_USER2_PASSWORD\"}")
        token=$(echo "$response" | jq -r '.token')
        TEST_USER2_ID=$(echo "$response" | jq -r '.userId')
    fi

    if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo "$TEST_USER2_ID" > /tmp/test_user2_id.txt
        print_success "Second user ready: $TEST_USER2_EMAIL (ID: $TEST_USER2_ID)"
    else
        print_error "Failed to register/login second user"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
        return 1
    fi
}

# Test: Create Account
test_create_account() {
    print_header "TEST: Create Account"

    ensure_user_auth

    print_info "Creating Savings Account (requires auth)..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TEST_USER_TOKEN" \
        -d @"${PAYLOADS_DIR}/create-savings.json")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    ACCOUNT_ID=$(echo "$BODY" | jq -r '.id')

    if [ -n "$ACCOUNT_ID" ] && [ "$ACCOUNT_ID" != "null" ]; then
        print_success "Account created with ID: $ACCOUNT_ID (HTTP $HTTP_CODE)"
        echo "$ACCOUNT_ID" > /tmp/test_account_id.txt
    else
        print_error "Failed to create account (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Create Account Without Auth (expected 401)
test_create_account_unauthorized() {
    print_header "TEST: Create Account Without Auth (Expected 401)"

    print_info "Attempting to create account without token..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -d '{"name": "Unauthorized Account", "currency": "USD", "initialBalance": 100.0}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "401" ]; then
        print_success "Correctly returned 401 Unauthorized"
    else
        print_info "Got HTTP $HTTP_CODE (expected 401)"
    fi
}

# Test: Get Account by ID
test_get_account() {
    print_header "TEST: Get Account by ID"

    ensure_user_auth

    if [ ! -f /tmp/test_account_id.txt ]; then
        print_error "No account ID found. Run create test first."
        return 1
    fi

    ACCOUNT_ID=$(cat /tmp/test_account_id.txt)
    print_info "Getting account: $ACCOUNT_ID"

    RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}" \
        -H "Authorization: Bearer $TEST_USER_TOKEN")
    echo "$RESPONSE" | jq '.'

    if echo "$RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
        print_success "Account retrieved successfully"
    else
        print_error "Failed to retrieve account"
        return 1
    fi
}

# Test: List All Accounts
test_list_accounts() {
    print_header "TEST: List All Accounts"

    ensure_user_auth

    print_info "Listing all accounts..."
    RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts" \
        -H "Authorization: Bearer $TEST_USER_TOKEN")
    echo "$RESPONSE" | jq '.'

    TOTAL_COUNT=$(echo "$RESPONSE" | jq -r '.totalCount')
    print_success "Found $TOTAL_COUNT account(s)"
}

# Test: Share Account
test_share_account() {
    print_header "TEST: Share Account"

    ensure_user_auth

    if [ ! -f /tmp/test_account_id.txt ]; then
        print_error "No account ID found. Run create test first."
        return 1
    fi

    ACCOUNT_ID=$(cat /tmp/test_account_id.txt)

    # Register a second user to share with
    print_info "Creating a second user to share the account with..."
    register_second_user

    if [ ! -f /tmp/test_user2_id.txt ]; then
        print_error "Failed to create second user for sharing."
        return 1
    fi

    TEST_USER2_ID=$(cat /tmp/test_user2_id.txt)

    print_info "Sharing account $ACCOUNT_ID with user $TEST_USER2_ID (role: editor)..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}/share" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TEST_USER_TOKEN" \
        -d "{\"userId\": \"$TEST_USER2_ID\", \"role\": \"editor\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Account shared successfully"
    else
        print_error "Failed to share account (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Revoke Account Access
test_revoke_access() {
    print_header "TEST: Revoke Account Access"

    ensure_user_auth

    if [ ! -f /tmp/test_account_id.txt ] || [ ! -f /tmp/test_user2_id.txt ]; then
        print_error "No account ID or second user ID found. Run share test first."
        return 1
    fi

    ACCOUNT_ID=$(cat /tmp/test_account_id.txt)
    TEST_USER2_ID=$(cat /tmp/test_user2_id.txt)

    print_info "Revoking access for user $TEST_USER2_ID from account $ACCOUNT_ID..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
        "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}/access/${TEST_USER2_ID}" \
        -H "Authorization: Bearer $TEST_USER_TOKEN")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Access revoked successfully"
    else
        print_error "Failed to revoke access (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Main menu
main() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Account API Testing Script           ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"

    check_server

    if [ $# -eq 0 ]; then
        echo ""
        echo "Usage: $0 [test_name] [--prod|--local]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  create           - Create a new account (requires auth)"
        echo "  unauthorized     - Test creating without auth (expected 401)"
        echo "  get              - Get account by ID"
        echo "  list             - List all accounts"
        echo "  share            - Share account with another user"
        echo "  revoke           - Revoke account access"
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
            test_create_account
            test_create_account_unauthorized
            test_get_account
            test_list_accounts
            test_share_account
            test_revoke_access
            print_header "ALL TESTS COMPLETED"
            ;;
        create)
            test_create_account
            ;;
        unauthorized)
            test_create_account_unauthorized
            ;;
        get)
            test_get_account
            ;;
        list)
            test_list_accounts
            ;;
        share)
            test_share_account
            ;;
        revoke)
            test_revoke_access
            ;;
        *)
            print_error "Unknown test: $1"
            echo "Run '$0' without arguments to see available tests."
            exit 1
            ;;
    esac
}

main "$@"
