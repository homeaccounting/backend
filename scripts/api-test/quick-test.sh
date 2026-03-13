#!/bin/bash

# Quick API Testing Helper
# Provides quick commands for common API operations
#
# Auth token management:
#   - Protected endpoints require a JWT token
#   - Use 'register' or 'login' to obtain and save a token
#   - Token is saved to /tmp/test_auth_token.txt and reused automatically

API_BASE_URL="http://localhost:8080"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Load .env if Telegram env vars are missing (direnv may not have reloaded)
if [ -z "$TELEGRAM_USER_ID" ] && [ -f "${PROJECT_ROOT}/.env" ]; then
    set -a
    source "${PROJECT_ROOT}/.env"
    set +a
fi

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
    echo "  telegram-login [id] [name] [username] - Login via Telegram (requires TELEGRAM_BOT_TOKEN)"
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
    echo "  income <acct-id> <amt> <cat> - Record income (requires auth)"
    echo "  expense <acct-id> <amt> <cat> - Record expense (requires auth)"
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
    echo "Environment variables (for Telegram):"
    echo "  TELEGRAM_BOT_TOKEN   - Required for telegram-login"
    echo "  TELEGRAM_USER_ID     - Default Telegram user ID"
    echo "  TELEGRAM_FIRST_NAME  - Default first name"
    echo "  TELEGRAM_USERNAME    - Default username (without @)"
    echo ""
    echo "Examples:"
    echo "  $0 register user@example.com MyPassword123"
    echo "  $0 login user@example.com MyPassword123"
    echo "  $0 telegram-login                          # Uses env var defaults"
    echo "  $0 telegram-login 12345 John johndoe       # Override with args"
    echo "  $0 create \"My Account\" 1000"
    echo "  $0 list"
    echo "  $0 income <account-id> 500 salary"
    echo "  $0 expense <account-id> 100 food"
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
        if curl -s -o /dev/null -w "%{http_code}" "${API_BASE_URL}/api/nonexistent" 2>&1 | grep -q "404"; then
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
            -d "{\"email\": \"$EMAIL\", \"password\": \"$PASSWORD\"}")
        check_jq "$RESPONSE"
        TOKEN=$(echo "$RESPONSE" | jq -r '.token' 2>/dev/null)
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
            -d "{\"email\": \"$EMAIL\", \"password\": \"$PASSWORD\"}")
        check_jq "$RESPONSE"
        TOKEN=$(echo "$RESPONSE" | jq -r '.token' 2>/dev/null)
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
            echo "$TOKEN" > /tmp/test_auth_token.txt
            echo "$EMAIL" > /tmp/test_auth_email.txt
            echo "$PASSWORD" > /tmp/test_auth_password.txt
            echo -e "${GREEN}✓ Token saved to /tmp/test_auth_token.txt${NC}"
        fi
        ;;

    telegram-login)
        # Compute Telegram auth hash and login
        # Uses env vars as defaults: TELEGRAM_BOT_TOKEN (required),
        # TELEGRAM_USER_ID, TELEGRAM_FIRST_NAME, TELEGRAM_USERNAME (optional)
        if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
            echo -e "${RED}TELEGRAM_BOT_TOKEN env var is required${NC}"
            echo "  export TELEGRAM_BOT_TOKEN='your-bot-token'"
            exit 1
        fi
        if ! command -v openssl &> /dev/null; then
            echo -e "${RED}openssl is required for hash computation${NC}"
            exit 1
        fi
        TG_ID="${2:-${TELEGRAM_USER_ID:-$(( RANDOM * 10000 + RANDOM ))}}"
        TG_NAME="${3:-${TELEGRAM_FIRST_NAME:-TestUser}}"
        TG_USERNAME="${4:-${TELEGRAM_USERNAME:-tguser_$(date +%s)}}"
        TG_AUTH_DATE=$(date +%s)

        # Build data-check-string (sorted key=value pairs)
        DATA_CHECK="auth_date=${TG_AUTH_DATE}\nfirst_name=${TG_NAME}\nid=${TG_ID}\nusername=${TG_USERNAME}"
        DATA_CHECK_SORTED=$(printf '%b' "$DATA_CHECK" | sort | tr '\n' $'\n')
        DATA_CHECK_SORTED="${DATA_CHECK_SORTED%$'\n'}"

        # secret_key = SHA256(bot_token), hash = HMAC-SHA256(data, secret_key)
        SECRET_HEX=$(printf '%s' "$TELEGRAM_BOT_TOKEN" | openssl dgst -sha256 -binary | xxd -p | tr -d '\n')
        TG_HASH=$(printf '%s' "$DATA_CHECK_SORTED" | openssl dgst -sha256 -mac hmac -macopt "hexkey:${SECRET_HEX}" -binary | xxd -p | tr -d '\n')

        echo -e "${YELLOW}Logging in via Telegram (ID: $TG_ID, @$TG_USERNAME)${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/auth/telegram" \
            -H "Content-Type: application/json" \
            -d "{\"id\": $TG_ID, \"firstName\": \"$TG_NAME\", \"lastName\": null, \"username\": \"$TG_USERNAME\", \"photoUrl\": null, \"authDate\": $TG_AUTH_DATE, \"hash\": \"$TG_HASH\"}")
        check_jq "$RESPONSE"
        TOKEN=$(echo "$RESPONSE" | jq -r '.token' 2>/dev/null)
        if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
            echo "$TOKEN" > /tmp/test_auth_token.txt
            echo "$TG_ID" > /tmp/test_telegram_id.txt
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
            -d "{\"name\": \"$NAME\", \"currency\": \"USD\", \"initialBalance\": $BALANCE}")
        check_jq "$RESPONSE"
        ;;

    list)
        echo -e "${YELLOW}Listing all accounts...${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts" \
            -H "$(auth_header)")
        check_jq "$RESPONSE"
        ;;

    get)
        if [ -z "$2" ]; then
            echo "Usage: $0 get <account-id>"
            exit 1
        fi
        ACCOUNT_ID="$2"
        echo -e "${YELLOW}Getting account: $ACCOUNT_ID${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${ACCOUNT_ID}" \
            -H "$(auth_header)")
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
            -d "{\"userId\": \"$TARGET_USER_ID\", \"role\": \"$ROLE\"}")
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

    income)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 income <account-id> <amount> [category]"
            echo "  Categories: salary, freelance, investment, gift, other"
            exit 1
        fi
        ACCOUNT_ID="$2"
        AMOUNT="$3"
        CATEGORY="${4:-salary}"
        echo -e "${YELLOW}Recording income of \$$AMOUNT to $ACCOUNT_ID (category: $CATEGORY)${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/income" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"accountId\": \"$ACCOUNT_ID\", \"amount\": $AMOUNT, \"currency\": \"USD\", \"category\": \"$CATEGORY\", \"reason\": \"Quick income\"}")
        check_jq "$RESPONSE"
        ;;

    expense)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 expense <account-id> <amount> [category]"
            echo "  Categories: food, transport, utilities, rent, entertainment, other"
            exit 1
        fi
        ACCOUNT_ID="$2"
        AMOUNT="$3"
        CATEGORY="${4:-other}"
        echo -e "${YELLOW}Recording expense of \$$AMOUNT from $ACCOUNT_ID (category: $CATEGORY)${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/expense" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"accountId\": \"$ACCOUNT_ID\", \"amount\": $AMOUNT, \"currency\": \"USD\", \"category\": \"$CATEGORY\", \"reason\": \"Quick expense\"}")
        check_jq "$RESPONSE"
        ;;

    transfer)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Usage: $0 transfer <from-id> <to-id> <amount> [category]"
            echo "  Categories: rebalance, savings, other"
            exit 1
        fi
        FROM_ID="$2"
        TO_ID="$3"
        AMOUNT="$4"
        CATEGORY="${5:-other}"
        echo -e "${YELLOW}Transferring \$$AMOUNT from $FROM_ID to $TO_ID (category: $CATEGORY)${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/transfer" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"fromAccountId\": \"$FROM_ID\", \"toAccountId\": \"$TO_ID\", \"amount\": $AMOUNT, \"currency\": \"USD\", \"category\": \"$CATEGORY\", \"reason\": \"Quick transfer\"}")
        check_jq "$RESPONSE"
        ;;

    tx)
        if [ -z "$2" ]; then
            echo "Usage: $0 tx <transaction-id>"
            exit 1
        fi
        TRANSACTION_ID="$2"
        echo -e "${YELLOW}Getting transaction: $TRANSACTION_ID${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions/${TRANSACTION_ID}" \
            -H "$(auth_header)")
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
        BODY=$(echo "$RESPONSE" | sed '$d')
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
