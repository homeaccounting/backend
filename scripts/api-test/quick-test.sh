#!/bin/bash

# Quick API Testing Helper
# Provides quick commands for common API operations
#
# Auth token management:
#   - Protected endpoints require a JWT token
#   - Use 'register' or 'login' to obtain and save a token
#   - Token is saved to /tmp/test_auth_token.txt and reused automatically

API_BASE_URL="http://localhost:8080"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

print_usage() {
    echo -e "${BLUE}Quick API Test Helper${NC}"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Authentication Commands:"
    echo "  register <email> <password>  - Register a new user"
    echo "  login <email> <password>     - Login and save token"
    echo "  token                        - Show current saved token"
    echo ""
    echo "Account Commands:"
    echo "  create <name> <bal>          - Create account (requires auth)"
    echo "  list                         - List all accounts"
    echo "  get <id>                     - Get account by ID"
    echo "  share <acct-id> <user-id> <role> - Share account (requires auth)"
    echo "  revoke <acct-id> <user-id>   - Revoke access (requires auth)"
    echo ""
    echo "Transaction Commands:"
    echo "  transfer <from> <to> <amt>   - Transfer money (requires auth)"
    echo "  tx <id>                      - Get transaction status"
    echo ""
    echo "User Profile Commands:"
    echo "  profile                      - Get current user profile (requires auth)"
    echo "  change-password <old> <new>  - Change password (requires auth)"
    echo ""
    echo "Other Commands:"
    echo "  health                       - Check if server is running"
    echo ""
    echo "Examples:"
    echo "  $0 register user@example.com MyPassword123"
    echo "  $0 login user@example.com MyPassword123"
    echo "  $0 create \"My Account\" 1000"
    echo "  $0 list"
    echo "  $0 transfer <from-id> <to-id> 300"
    echo "  $0 profile"
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "$@"
        return
    fi
    echo "$@" | jq '.'
}

# Get saved auth token
get_token() {
    if [ -f /tmp/test_auth_token.txt ]; then
        cat /tmp/test_auth_token.txt
    else
        echo ""
    fi
}

# Auth header for protected endpoints
auth_header() {
    local token
    token=$(get_token)
    if [ -z "$token" ]; then
        echo -e "${RED}No auth token found. Run '$0 register' or '$0 login' first.${NC}" >&2
        exit 1
    fi
    echo "Authorization: Bearer $token"
}

case "${1:-help}" in
    health)
        echo -e "${YELLOW}Checking server health...${NC}"
        if curl -s "${API_BASE_URL}/api/accounts" > /dev/null 2>&1; then
            echo -e "${GREEN}✓ Server is running at ${API_BASE_URL}${NC}"
        else
            echo -e "${RED}✗ Server is not running at ${API_BASE_URL}${NC}"
            exit 1
        fi
        ;;

    # --- Authentication ---

    register)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 register <email> <password>"
            exit 1
        fi
        EMAIL="$2"
        PASSWORD="$3"
        echo -e "${YELLOW}Registering user: $EMAIL${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
            -H "Content-Type: application/json" \
            -d "{\"registerEmail\": \"$EMAIL\", \"registerPassword\": \"$PASSWORD\"}")
        check_jq "$RESPONSE"
        TOKEN=$(echo "$RESPONSE" | jq -r '.authToken' 2>/dev/null)
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
            echo "$TOKEN" > /tmp/test_auth_token.txt
            echo "$EMAIL" > /tmp/test_auth_email.txt
            echo "$PASSWORD" > /tmp/test_auth_password.txt
            echo -e "${GREEN}✓ Token saved to /tmp/test_auth_token.txt${NC}"
        fi
        ;;

    login)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 login <email> <password>"
            exit 1
        fi
        EMAIL="$2"
        PASSWORD="$3"
        echo -e "${YELLOW}Logging in as: $EMAIL${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/login" \
            -H "Content-Type: application/json" \
            -d "{\"loginEmail\": \"$EMAIL\", \"loginPassword\": \"$PASSWORD\"}")
        check_jq "$RESPONSE"
        TOKEN=$(echo "$RESPONSE" | jq -r '.authToken' 2>/dev/null)
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
            echo "$TOKEN" > /tmp/test_auth_token.txt
            echo "$EMAIL" > /tmp/test_auth_email.txt
            echo "$PASSWORD" > /tmp/test_auth_password.txt
            echo -e "${GREEN}✓ Token saved to /tmp/test_auth_token.txt${NC}"
        fi
        ;;

    token)
        TOKEN=$(get_token)
        if [ -n "$TOKEN" ]; then
            echo -e "${YELLOW}Current auth token:${NC}"
            echo "$TOKEN"
            if [ -f /tmp/test_auth_email.txt ]; then
                echo -e "${YELLOW}Email: $(cat /tmp/test_auth_email.txt)${NC}"
            fi
        else
            echo -e "${RED}No auth token saved. Run '$0 register' or '$0 login' first.${NC}"
        fi
        ;;

    # --- Accounts ---

    create)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 create <name> <balance>"
            exit 1
        fi
        NAME="$2"
        BALANCE="$3"
        echo -e "${YELLOW}Creating account: $NAME with balance \$$BALANCE${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"accountName\": \"$NAME\", \"initialBalance\": $BALANCE}")
        check_jq "$RESPONSE"
        ;;

    list)
        echo -e "${YELLOW}Listing all accounts...${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts")
        check_jq "$RESPONSE"
        ;;

    get)
        if [ -z "$2" ]; then
            echo "Usage: $0 get <account-id>"
            exit 1
        fi
        ACCOUNT_ID="$2"
        echo -e "${YELLOW}Getting account: $ACCOUNT_ID${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}")
        check_jq "$RESPONSE"
        ;;

    share)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Usage: $0 share <account-id> <user-id> <role>"
            echo "  Roles: owner, editor, viewer"
            exit 1
        fi
        ACCOUNT_ID="$2"
        TARGET_USER_ID="$3"
        ROLE="$4"
        echo -e "${YELLOW}Sharing account $ACCOUNT_ID with user $TARGET_USER_ID (role: $ROLE)${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}/share" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"shareUserId\": \"$TARGET_USER_ID\", \"shareRole\": \"$ROLE\"}")
        if [ -z "$RESPONSE" ]; then
            echo -e "${GREEN}✓ Account shared (204 No Content)${NC}"
        else
            check_jq "$RESPONSE"
        fi
        ;;

    revoke)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 revoke <account-id> <user-id>"
            exit 1
        fi
        ACCOUNT_ID="$2"
        TARGET_USER_ID="$3"
        echo -e "${YELLOW}Revoking access for user $TARGET_USER_ID from account $ACCOUNT_ID${NC}"
        RESPONSE=$(curl -s -X DELETE \
            "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}/access/${TARGET_USER_ID}" \
            -H "$(auth_header)")
        if [ -z "$RESPONSE" ]; then
            echo -e "${GREEN}✓ Access revoked (204 No Content)${NC}"
        else
            check_jq "$RESPONSE"
        fi
        ;;

    # --- Transactions ---

    transfer)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Usage: $0 transfer <from-id> <to-id> <amount>"
            exit 1
        fi
        FROM_ID="$2"
        TO_ID="$3"
        AMOUNT="$4"
        echo -e "${YELLOW}Transferring \$$AMOUNT from $FROM_ID to $TO_ID${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"fromAccountId\": \"$FROM_ID\", \"toAccountId\": \"$TO_ID\", \"amount\": $AMOUNT, \"reason\": \"Quick transfer\"}")
        check_jq "$RESPONSE"
        ;;

    tx)
        if [ -z "$2" ]; then
            echo "Usage: $0 tx <transaction-id>"
            exit 1
        fi
        TRANSACTION_ID="$2"
        echo -e "${YELLOW}Getting transaction: $TRANSACTION_ID${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions/${TRANSACTION_ID}")
        check_jq "$RESPONSE"
        ;;

    # --- User Profile ---

    profile)
        echo -e "${YELLOW}Getting user profile...${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/users/me" \
            -H "$(auth_header)")
        check_jq "$RESPONSE"
        ;;

    change-password)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 change-password <current-password> <new-password>"
            exit 1
        fi
        CURRENT="$2"
        NEW="$3"
        echo -e "${YELLOW}Changing password...${NC}"
        RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/users/me/change-password" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"currentPassword\": \"$CURRENT\", \"newPassword\": \"$NEW\"}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | head -n -1)
        if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
            echo -e "${GREEN}✓ Password changed successfully${NC}"
            echo "$NEW" > /tmp/test_auth_password.txt
        else
            check_jq "$BODY"
        fi
        ;;

    help|*)
        print_usage
        ;;
esac
