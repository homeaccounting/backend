#!/bin/bash

# User Profile API Testing Script
# Tests all user profile endpoints (get, update, change password, unlink)
#
# Prerequisites: Run test-auth.sh first to create a user and save the JWT token.
#
# Note: set -e is NOT used so all tests run even when individual assertions fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PAYLOADS_DIR="${SCRIPT_DIR}/payloads/user"

# Test: Get User Profile
test_get_profile() {
    print_header "TEST: Get User Profile"

    ensure_authenticated

    print_info "Fetching current user profile..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${API_BASE_URL}/api/users/me" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.'

    PROFILE_EMAIL=$(echo "$BODY" | jq -r '.email')
    HAS_PASSWORD=$(echo "$BODY" | jq -r '.hasPassword')

    if [ "$HTTP_CODE" = "200" ]; then
        print_success "Profile retrieved successfully"
        print_info "Email: $PROFILE_EMAIL"
        print_info "Has Password: $HAS_PASSWORD"
    else
        print_error "Failed to get profile (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Get Profile Without Auth (expected 401)
test_get_profile_unauthorized() {
    print_header "TEST: Get Profile Without Auth (Expected 401)"

    print_info "Attempting to access profile without token..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${API_BASE_URL}/api/users/me")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "401" ]; then
        print_success "Correctly returned 401 Unauthorized"
    else
        print_info "Got HTTP $HTTP_CODE (expected 401)"
    fi
}

# Test: Update Profile
test_update_profile() {
    print_header "TEST: Update Profile"

    ensure_authenticated

    print_info "Updating profile (email change)..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${API_BASE_URL}/api/users/me" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"email": "newemail@example.com"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "200" ]; then
        print_success "Profile updated successfully"
    else
        print_info "Profile update returned HTTP $HTTP_CODE (email update may not be implemented yet)"
    fi
}

# Test: Change Password
test_change_password() {
    print_header "TEST: Change Password"

    ensure_authenticated

    if [ ! -f /tmp/test_auth_password.txt ]; then
        print_error "No saved password found. Cannot test password change."
        return 1
    fi

    CURRENT_PASSWORD=$(cat /tmp/test_auth_password.txt)
    NEW_PASSWORD="NewSecurePass789!"

    print_info "Changing password..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/users/me/change-password" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"currentPassword\": \"$CURRENT_PASSWORD\", \"newPassword\": \"$NEW_PASSWORD\"}")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Password changed successfully"
        echo "$NEW_PASSWORD" > /tmp/test_auth_password.txt
    else
        print_error "Failed to change password (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Change Password with Wrong Current Password (expected failure)
test_change_password_wrong() {
    print_header "TEST: Change Password with Wrong Current (Expected Failure)"

    ensure_authenticated

    print_info "Attempting password change with wrong current password..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/users/me/change-password" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"currentPassword": "WrongPassword!", "newPassword": "ShouldNotWork123!"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" -ge 400 ]; then
        print_success "Wrong password correctly rejected (HTTP $HTTP_CODE)"
    else
        print_error "Expected error but got HTTP $HTTP_CODE"
        return 1
    fi
}

# Test: Unlink OAuth Provider
test_unlink_oauth() {
    print_header "TEST: Unlink OAuth Provider"

    ensure_authenticated

    print_info "Attempting to unlink Google OAuth..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${API_BASE_URL}/api/users/me/oauth/google" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "OAuth provider unlinked"
    else
        print_info "Unlink OAuth returned HTTP $HTTP_CODE (provider may not be linked)"
    fi
}

# Test: Unlink Telegram
test_unlink_telegram() {
    print_header "TEST: Unlink Telegram"

    ensure_authenticated

    print_info "Attempting to unlink Telegram..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE "${API_BASE_URL}/api/users/me/telegram" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Telegram unlinked"
    else
        print_info "Unlink Telegram returned HTTP $HTTP_CODE (Telegram may not be linked)"
    fi
}

# Main menu
main() {
    echo -e "${GREEN}╔═══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     User Profile API Testing Script       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════╝${NC}"

    check_server

    if [ $# -eq 0 ]; then
        echo ""
        echo "Usage: $0 [test_name] [--prod|--local]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  profile          - Get current user profile"
        echo "  unauthorized     - Test profile access without token (expected 401)"
        echo "  update           - Update user profile"
        echo "  change-password  - Change password"
        echo "  wrong-password   - Test wrong current password (expected failure)"
        echo "  unlink-oauth     - Unlink OAuth provider"
        echo "  unlink-telegram  - Unlink Telegram"
        echo ""
        echo "Endpoint flags:"
        echo "  --local          - Use http://localhost:8080 (default)"
        echo "  --prod           - Use https://homeaccounting.com"
        echo "  API_BASE_URL=... - Override with any URL"
        echo ""
        echo "Prerequisites: Run test-auth.sh first to create a user."
        echo ""
        echo "Example: $0 all --prod"
        exit 0
    fi

    case "$1" in
        all)
            test_get_profile
            test_get_profile_unauthorized
            test_update_profile
            test_change_password
            test_change_password_wrong
            test_unlink_oauth
            test_unlink_telegram
            print_header "ALL USER PROFILE TESTS COMPLETED"
            ;;
        profile)
            test_get_profile
            ;;
        unauthorized)
            test_get_profile_unauthorized
            ;;
        update)
            test_update_profile
            ;;
        change-password)
            test_change_password
            ;;
        wrong-password)
            test_change_password_wrong
            ;;
        unlink-oauth)
            test_unlink_oauth
            ;;
        unlink-telegram)
            test_unlink_telegram
            ;;
        *)
            print_error "Unknown test: $1"
            echo "Run '$0' without arguments to see available tests."
            exit 1
            ;;
    esac
}

main "$@"
