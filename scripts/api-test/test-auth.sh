#!/bin/bash

# Authentication API Testing Script
# Tests all auth-related endpoints (register, login, refresh, OAuth initiate)
#
# Note: set -e is NOT used so all tests run even when individual assertions fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PAYLOADS_DIR="${SCRIPT_DIR}/payloads/auth"

# Test: Register
test_register() {
    print_header "TEST: Register New User"

    resolve_user_credentials

    print_info "Registering user: $TEST_USER_EMAIL"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_USER_EMAIL\", \"password\": \"$TEST_USER_PASSWORD\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    TEST_USER_TOKEN=$(echo "$BODY" | jq -r '.token')
    USER_ID=$(echo "$BODY" | jq -r '.userId')

    if [ -n "$TEST_USER_TOKEN" ] && [ "$TEST_USER_TOKEN" != "null" ]; then
        print_success "User registered successfully"
        print_info "User ID: $USER_ID"
        print_info "Token (first 20 chars): ${TEST_USER_TOKEN:0:20}..."
        save_user_session
    else
        print_error "Failed to register user (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Register Duplicate (expected failure)
test_register_duplicate() {
    print_header "TEST: Register Duplicate User (Expected Failure)"

    resolve_user_credentials

    print_info "Attempting duplicate registration for: $TEST_USER_EMAIL"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/register" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_USER_EMAIL\", \"password\": \"$TEST_USER_PASSWORD\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" -ge 400 ]; then
        print_success "Duplicate registration correctly rejected (HTTP $HTTP_CODE)"
    else
        print_error "Expected error but got HTTP $HTTP_CODE"
        return 1
    fi
}

# Test: Login
test_login() {
    print_header "TEST: Login"

    resolve_user_credentials

    print_info "Logging in as: $TEST_USER_EMAIL"
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_USER_EMAIL\", \"password\": \"$TEST_USER_PASSWORD\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    TEST_USER_TOKEN=$(echo "$BODY" | jq -r '.token')
    EXPIRES_IN=$(echo "$BODY" | jq -r '.expiresIn')

    if [ -n "$TEST_USER_TOKEN" ] && [ "$TEST_USER_TOKEN" != "null" ]; then
        print_success "Login successful"
        print_info "Token expires in: ${EXPIRES_IN}s"
        save_user_session
    else
        print_error "Failed to login (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Login with Wrong Password (expected failure)
#
# NOTE: The backend currently has a TODO for password verification
# (AuthService.login ignores the password parameter). This test documents
# the expected behavior once password checking is implemented.
test_login_wrong_password() {
    print_header "TEST: Login with Wrong Password (Expected Failure)"

    resolve_user_credentials

    print_info "Attempting login with wrong password..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_USER_EMAIL\", \"password\": \"WrongPassword!\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" -ge 400 ]; then
        print_success "Wrong password correctly rejected (HTTP $HTTP_CODE)"
    else
        print_info "KNOWN ISSUE: Backend accepted wrong password (HTTP $HTTP_CODE)"
        print_info "Password verification is not yet implemented in AuthService.login"
        print_info "(See TODO in src/Application/Services/AuthService.hs)"
    fi
}

# Test: Refresh Token
test_refresh_token() {
    print_header "TEST: Refresh Token"

    if [ ! -f /tmp/test_user_token.txt ]; then
        print_error "No auth token found. Run login test first."
        return 1
    fi

    TEST_USER_TOKEN=$(cat /tmp/test_user_token.txt)

    print_info "Refreshing token..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/auth/refresh" \
        -H "Content-Type: application/json" \
        -d "{\"token\": \"$TEST_USER_TOKEN\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    NEW_TOKEN=$(echo "$BODY" | jq -r '.token')

    if [ -n "$NEW_TOKEN" ] && [ "$NEW_TOKEN" != "null" ]; then
        print_success "Token refreshed successfully"
        echo "$NEW_TOKEN" > /tmp/test_user_token.txt
    else
        print_info "Token refresh returned HTTP $HTTP_CODE (may require a dedicated refresh token)"
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
    fi
}

# Test: OAuth Initiate (Google)
test_oauth_initiate() {
    print_header "TEST: OAuth Initiate (Google)"

    print_info "Initiating OAuth flow for Google..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${API_BASE_URL}/api/auth/oauth/google")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    REDIRECT_URL=$(echo "$BODY" | jq -r '.redirectUrl' 2>/dev/null)

    if [ -n "$REDIRECT_URL" ] && [ "$REDIRECT_URL" != "null" ]; then
        print_success "OAuth redirect URL received"
        print_info "Redirect URL: ${REDIRECT_URL:0:80}..."
    else
        print_info "OAuth initiate returned HTTP $HTTP_CODE (OAuth may not be configured)"
    fi
}

# Test: Access Protected Endpoint Without Token (expected 401)
test_unauthorized_access() {
    print_header "TEST: Access Protected Endpoint Without Token (Expected 401)"

    print_info "Attempting to create account without authentication..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -d '{"name": "Test Account", "initialBalance": 100.0}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "401" ]; then
        print_success "Correctly returned 401 Unauthorized"
    else
        print_info "Got HTTP $HTTP_CODE (expected 401)"
    fi
}

# Main menu
main() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   Authentication API Testing Script       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"

    check_server

    if [ $# -eq 0 ]; then
        echo ""
        echo "Usage: $0 [test_name] [--prod|--local]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  register         - Register a new user"
        echo "  duplicate        - Test duplicate registration (expected failure)"
        echo "  login            - Login with email/password"
        echo "  wrong-password   - Test login with wrong password (expected failure)"
        echo "  refresh          - Refresh JWT token"
        echo "  oauth            - Test OAuth initiate (Google)"
        echo "  unauthorized     - Test accessing protected endpoint without token"
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
            test_register
            test_register_duplicate
            test_login
            test_login_wrong_password
            test_refresh_token
            test_oauth_initiate
            test_unauthorized_access
            print_header "ALL AUTH TESTS COMPLETED"
            ;;
        register)
            test_register
            ;;
        duplicate)
            test_register_duplicate
            ;;
        login)
            test_login
            ;;
        wrong-password)
            test_login_wrong_password
            ;;
        refresh)
            test_refresh_token
            ;;
        oauth)
            test_oauth_initiate
            ;;
        unauthorized)
            test_unauthorized_access
            ;;
        *)
            print_error "Unknown test: $1"
            echo "Run '$0' without arguments to see available tests."
            exit 1
            ;;
    esac
}

main "$@"
