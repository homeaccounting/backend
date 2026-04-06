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

# Register a second user and return their ID and token
register_second_user() {
    SECOND_EMAIL="seconduser-$(date +%s)@example.com"
    SECOND_PASSWORD="SecurePass456!"

    RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$SECOND_EMAIL\", \"password\": \"$SECOND_PASSWORD\"}")

    SECOND_TOKEN=$(echo "$RESPONSE" | jq -r '.token')
    SECOND_USER_ID=$(echo "$RESPONSE" | jq -r '.userId')

    if [ -n "$SECOND_TOKEN" ] && [ "$SECOND_TOKEN" != "null" ]; then
        echo "$SECOND_USER_ID" > /tmp/test_second_user_id.txt
        echo "$SECOND_TOKEN" > /tmp/test_second_auth_token.txt
        print_success "Second user registered: $SECOND_EMAIL (ID: $SECOND_USER_ID)"
    else
        print_error "Failed to register second user"
        echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
        return 1
    fi
}

# Test: Create Account
test_create_account() {
    print_header "TEST: Create Account"

    ensure_authenticated

    print_info "Creating Savings Account (requires auth)..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
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

    ensure_authenticated

    if [ ! -f /tmp/test_account_id.txt ]; then
        print_error "No account ID found. Run create test first."
        return 1
    fi

    ACCOUNT_ID=$(cat /tmp/test_account_id.txt)
    print_info "Getting account: $ACCOUNT_ID"

    RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
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

    ensure_authenticated

    print_info "Listing all accounts..."
    RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    echo "$RESPONSE" | jq '.'

    TOTAL_COUNT=$(echo "$RESPONSE" | jq -r '.totalCount')
    print_success "Found $TOTAL_COUNT account(s)"
}

# Test: Share Account
test_share_account() {
    print_header "TEST: Share Account"

    ensure_authenticated

    if [ ! -f /tmp/test_account_id.txt ]; then
        print_error "No account ID found. Run create test first."
        return 1
    fi

    ACCOUNT_ID=$(cat /tmp/test_account_id.txt)

    # Register a second user to share with
    print_info "Creating a second user to share the account with..."
    register_second_user

    if [ ! -f /tmp/test_second_user_id.txt ]; then
        print_error "Failed to create second user for sharing."
        return 1
    fi

    SECOND_USER_ID=$(cat /tmp/test_second_user_id.txt)

    print_info "Sharing account $ACCOUNT_ID with user $SECOND_USER_ID (role: editor)..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}/share" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "{\"userId\": \"$SECOND_USER_ID\", \"role\": \"editor\"}")

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

    ensure_authenticated

    if [ ! -f /tmp/test_account_id.txt ] || [ ! -f /tmp/test_second_user_id.txt ]; then
        print_error "No account ID or second user ID found. Run share test first."
        return 1
    fi

    ACCOUNT_ID=$(cat /tmp/test_account_id.txt)
    SECOND_USER_ID=$(cat /tmp/test_second_user_id.txt)

    print_info "Revoking access for user $SECOND_USER_ID from account $ACCOUNT_ID..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
        "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}/access/${SECOND_USER_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")

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
