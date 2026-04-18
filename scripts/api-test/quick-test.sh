#!/bin/bash

# Quick API Testing Helper
# Provides quick commands for common API operations
#
# Auth token management:
#   - Protected endpoints require a JWT token
#   - Use 'register' or 'login' to obtain and save a token
#   - Token is saved to /tmp/test_auth_token.txt and reused automatically

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

load_env "$PROJECT_ROOT"

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo "$@"
        return
    fi
    echo "$@" | jq '.'
}

print_usage() {
    echo -e "${BLUE}Quick API Test Helper${NC}"
    echo ""
    echo "Usage: $0 <command> [args] [--prod|--local]"
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
    echo "  income <acct-id> <amt> <cat-uuid>  - Record income (requires auth)"
    echo "  expense <acct-id> <amt> <cat-uuid> - Record expense (requires auth)"
    echo "  transfer <from> <to> <amt>         - Transfer money (requires auth)"
    echo "  tx <id>                             - Get transaction status"
    echo "  list-tx [account-id] [from] [to]    - List transactions (filters optional; ISO-8601 UTC)"
    echo ""
    echo "Configuration Commands:"
    echo "  config                              - Get current configuration"
    echo "  config-dict <dict-id>               - List dictionary entries"
    echo "  config-add <dict-id> <name>         - Add dictionary entry"
    echo "  config-rename <dict-id> <id> <name> - Rename entry"
    echo "  config-remove <dict-id> <id>        - Remove entry"
    echo "  config-base-currency <cur>          - Change base currency"
    echo "  config-default-currency <cur>       - Change default currency"
    echo ""
    echo "User Profile Commands:"
    echo "  profile                      - Get current user profile (requires auth)"
    echo "  change-password <old> <new>  - Change password (requires auth)"
    echo ""
    echo "Other Commands:"
    echo "  health                       - Check if server is running"
    echo ""
    echo "Endpoint flags:"
    echo "  --local          - Use http://localhost:8080 (default)"
    echo "  --prod           - Use https://homeaccounting.com"
    echo "  API_BASE_URL=... - Override with any URL"
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
    echo "  $0 list --prod"
    echo "  $0 telegram-login                          # Uses env var defaults"
    echo "  $0 telegram-login 12345 John johndoe       # Override with args"
    echo "  $0 create \"My Account\" 1000"
    echo "  $0 config"
    echo "  $0 config-dict income-category"
    echo "  $0 income <account-id> 500 <category-uuid>"
    echo "  $0 expense <account-id> 100 <category-uuid>"
    echo "  $0 transfer <from-id> <to-id> 300"
    echo "  $0 list-tx"
    echo "  $0 list-tx <account-id>"
    echo "  $0 list-tx <account-id> 2026-01-01T00:00:00Z 2026-12-31T23:59:59Z"
    echo "  $0 profile"
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
        TOKEN=$(get_saved_token)
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
            echo "Usage: $0 income <account-id> <amount> <category-uuid>"
            echo "  Category must be a UUID from your configuration."
            echo "  Use '$0 config-dict income-category' to list available categories."
            exit 1
        fi
        ACCOUNT_ID="$2"
        AMOUNT="$3"
        CATEGORY="$4"
        if [ -z "$CATEGORY" ]; then
            echo -e "${YELLOW}No category UUID provided. Fetching first income category...${NC}"
            AUTH_TOKEN=$(get_saved_token)
            fetch_configuration
            CATEGORY=$(first_category_id "income-category")
            if [ -z "$CATEGORY" ]; then
                echo -e "${RED}Could not find any income categories in configuration${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Using category: $CATEGORY${NC}"
        fi
        echo -e "${YELLOW}Recording income of \$$AMOUNT to $ACCOUNT_ID${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/income" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"accountId\": \"$ACCOUNT_ID\", \"amount\": $AMOUNT, \"currency\": \"USD\", \"category\": \"$CATEGORY\", \"description\": \"Quick income\"}")
        check_jq "$RESPONSE"
        ;;

    expense)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 expense <account-id> <amount> <category-uuid>"
            echo "  Category must be a UUID from your configuration."
            echo "  Use '$0 config-dict expense-category' to list available categories."
            exit 1
        fi
        ACCOUNT_ID="$2"
        AMOUNT="$3"
        CATEGORY="$4"
        if [ -z "$CATEGORY" ]; then
            echo -e "${YELLOW}No category UUID provided. Fetching first expense category...${NC}"
            AUTH_TOKEN=$(get_saved_token)
            fetch_configuration
            CATEGORY=$(first_category_id "expense-category")
            if [ -z "$CATEGORY" ]; then
                echo -e "${RED}Could not find any expense categories in configuration${NC}"
                exit 1
            fi
            echo -e "${YELLOW}Using category: $CATEGORY${NC}"
        fi
        echo -e "${YELLOW}Recording expense of \$$AMOUNT from $ACCOUNT_ID${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/expense" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"accountId\": \"$ACCOUNT_ID\", \"amount\": $AMOUNT, \"currency\": \"USD\", \"category\": \"$CATEGORY\", \"description\": \"Quick expense\"}")
        check_jq "$RESPONSE"
        ;;

    transfer)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Usage: $0 transfer <from-id> <to-id> <amount>"
            exit 1
        fi
        FROM_ID="$2"
        TO_ID="$3"
        AMOUNT="$4"
        echo -e "${YELLOW}Transferring \$$AMOUNT from $FROM_ID to $TO_ID${NC}"
        RESPONSE=$(curl -s -X POST "${API_BASE_URL}/api/transactions/transfer" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"sourceAccountId\": \"$FROM_ID\", \"targetAccountId\": \"$TO_ID\", \"amount\": $AMOUNT, \"currency\": \"USD\", \"description\": \"Quick transfer\"}")
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

    list-tx)
        ACCOUNT_ID="$2"
        FROM_DATE="$3"
        TO_DATE="$4"
        QS=""
        SEP="?"
        if [ -n "$ACCOUNT_ID" ]; then
            QS="${QS}${SEP}accountId=${ACCOUNT_ID}"
            SEP="&"
        fi
        if [ -n "$FROM_DATE" ]; then
            QS="${QS}${SEP}from=${FROM_DATE}"
            SEP="&"
        fi
        if [ -n "$TO_DATE" ]; then
            QS="${QS}${SEP}to=${TO_DATE}"
            SEP="&"
        fi
        echo -e "${YELLOW}Listing transactions${QS:+ (}${QS}${QS:+)}...${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/transactions${QS}" \
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

    # --- Configuration ---

    config)
        echo -e "${YELLOW}Getting configuration...${NC}"
        RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/users/me/configuration" \
            -H "$(auth_header)")
        check_jq "$RESPONSE"
        ;;

    config-dict)
        if [ -z "$2" ]; then
            echo "Usage: $0 config-dict <dict-id>"
            echo "  Dict IDs: income-category, expense-category"
            exit 1
        fi
        DICT_ID="$2"
        echo -e "${YELLOW}Listing dictionary entries for: $DICT_ID${NC}"
        RESPONSE=$(curl -s -X GET \
            "${API_BASE_URL}/api/users/me/configuration/dictionaries/${DICT_ID}" \
            -H "$(auth_header)")
        check_jq "$RESPONSE"
        ;;

    config-add)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 config-add <dict-id> <name>"
            exit 1
        fi
        DICT_ID="$2"
        ENTRY_NAME="$3"
        echo -e "${YELLOW}Adding entry '$ENTRY_NAME' to $DICT_ID...${NC}"
        RESPONSE=$(curl -s -X POST \
            "${API_BASE_URL}/api/users/me/configuration/dictionaries/${DICT_ID}/entries" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"name\": \"$ENTRY_NAME\"}")
        check_jq "$RESPONSE"
        ;;

    config-rename)
        if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]; then
            echo "Usage: $0 config-rename <dict-id> <entry-id> <new-name>"
            exit 1
        fi
        DICT_ID="$2"
        ENTRY_ID="$3"
        NEW_NAME="$4"
        echo -e "${YELLOW}Renaming entry $ENTRY_ID to '$NEW_NAME'...${NC}"
        RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
            "${API_BASE_URL}/api/users/me/configuration/dictionaries/${DICT_ID}/entries/${ENTRY_ID}" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"name\": \"$NEW_NAME\"}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')
        if [ "$HTTP_CODE" = "204" ]; then
            echo -e "${GREEN}Entry renamed (204 No Content)${NC}"
        else
            check_jq "$BODY"
        fi
        ;;

    config-remove)
        if [ -z "$2" ] || [ -z "$3" ]; then
            echo "Usage: $0 config-remove <dict-id> <entry-id>"
            exit 1
        fi
        DICT_ID="$2"
        ENTRY_ID="$3"
        echo -e "${YELLOW}Removing entry $ENTRY_ID from $DICT_ID...${NC}"
        RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
            "${API_BASE_URL}/api/users/me/configuration/dictionaries/${DICT_ID}/entries/${ENTRY_ID}" \
            -H "$(auth_header)")
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')
        if [ "$HTTP_CODE" = "204" ]; then
            echo -e "${GREEN}Entry removed (204 No Content)${NC}"
        else
            check_jq "$BODY"
        fi
        ;;

    config-base-currency)
        if [ -z "$2" ]; then
            echo "Usage: $0 config-base-currency <currency>"
            exit 1
        fi
        CURRENCY="$2"
        echo -e "${YELLOW}Changing base currency to $CURRENCY...${NC}"
        RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
            "${API_BASE_URL}/api/users/me/configuration/base-currency" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"currency\": \"$CURRENCY\"}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')
        if [ "$HTTP_CODE" = "204" ]; then
            echo -e "${GREEN}Base currency changed to $CURRENCY (204 No Content)${NC}"
        else
            check_jq "$BODY"
        fi
        ;;

    config-default-currency)
        if [ -z "$2" ]; then
            echo "Usage: $0 config-default-currency <currency>"
            exit 1
        fi
        CURRENCY="$2"
        echo -e "${YELLOW}Changing default currency to $CURRENCY...${NC}"
        RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
            "${API_BASE_URL}/api/users/me/configuration/default-currency" \
            -H "Content-Type: application/json" \
            -H "$(auth_header)" \
            -d "{\"currency\": \"$CURRENCY\"}")
        HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
        BODY=$(echo "$RESPONSE" | sed '$d')
        if [ "$HTTP_CODE" = "204" ]; then
            echo -e "${GREEN}Default currency changed to $CURRENCY (204 No Content)${NC}"
        else
            check_jq "$BODY"
        fi
        ;;

    help|*)
        print_usage
        ;;
esac
