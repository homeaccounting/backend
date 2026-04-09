#!/bin/bash

# Shared configuration and helpers for API test scripts.
#
# Usage (source at the top of each test script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/common.sh"
#
# Endpoint selection (highest priority wins):
#   1. API_BASE_URL env var       — use any custom URL
#   2. --prod / --local flag      — preset shortcuts
#   3. Default                    — http://localhost:8080

# --- Endpoint configuration ---------------------------------------------------

_resolve_base_url() {
    # Already set by caller — honour it
    if [ -n "$API_BASE_URL" ]; then
        return
    fi

    # Scan remaining script args for --prod / --local
    for arg in "$@"; do
        case "$arg" in
            --prod)
                API_BASE_URL="https://homeaccounting.com"
                return
                ;;
            --local)
                API_BASE_URL="http://localhost:8080"
                return
                ;;
        esac
    done

    # Default
    API_BASE_URL="http://localhost:8080"
}

# Strip --prod / --local from the argument list so individual scripts
# don't need to handle them in their case statements.
_strip_endpoint_flags() {
    local filtered=()
    for arg in "$@"; do
        case "$arg" in
            --prod|--local) ;;
            *) filtered+=("$arg") ;;
        esac
    done
    echo "${filtered[@]}"
}

# --- .env loader --------------------------------------------------------------

load_env() {
    local project_root="${1:-$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)}"
    if [ -z "$TELEGRAM_USER_ID" ] && [ -f "${project_root}/.env" ]; then
        set -a
        # shellcheck disable=SC1091
        source "${project_root}/.env"
        set +a
    fi
}

# --- Colors -------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- Print helpers ------------------------------------------------------------

print_header() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}\n"
}

print_step() {
    echo -e "\n${CYAN}▶ $1${NC}\n"
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

print_balance() {
    echo -e "${MAGENTA}💰 $1${NC}"
}

# --- Server check -------------------------------------------------------------

check_server() {
    print_info "Checking if server is running at ${API_BASE_URL}..."
    if curl -s -o /dev/null -w "%{http_code}" "${API_BASE_URL}/api/nonexistent" 2>&1 | grep -q "404"; then
        print_success "Server is running at ${API_BASE_URL}"
    else
        print_error "Server is not running at ${API_BASE_URL}"
        echo "Please start the server with: just run"
        exit 1
    fi
}

# --- Auth helpers -------------------------------------------------------------

# Get saved auth token (returns empty string if none)
get_saved_token() {
    if [ -f /tmp/test_auth_token.txt ]; then
        cat /tmp/test_auth_token.txt
    else
        echo ""
    fi
}

# Ensure a valid auth token exists; registers a new test user if needed.
# Sets AUTH_TOKEN in the caller's scope.
ensure_authenticated() {
    if [ -f /tmp/test_auth_token.txt ]; then
        AUTH_TOKEN=$(cat /tmp/test_auth_token.txt)
        print_info "Using saved auth token"
    else
        print_info "No saved token found. Registering a new test user..."
        local test_email="autotest-$(date +%s)@example.com"
        local test_password="SecurePass123!"

        local response
        response=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
            -H "Content-Type: application/json" \
            -d "{\"email\": \"$test_email\", \"password\": \"$test_password\"}")

        AUTH_TOKEN=$(echo "$response" | jq -r '.token')

        if [ -n "$AUTH_TOKEN" ] && [ "$AUTH_TOKEN" != "null" ]; then
            echo "$AUTH_TOKEN" > /tmp/test_auth_token.txt
            echo "$test_email" > /tmp/test_auth_email.txt
            echo "$test_password" > /tmp/test_auth_password.txt
            print_success "Test user registered: $test_email"
        else
            print_error "Failed to register test user"
            echo "$response" | jq '.' 2>/dev/null || echo "$response"
            exit 1
        fi
    fi
}

# Print Authorization header value (exits if no token)
auth_header() {
    local token
    token=$(get_saved_token)
    if [ -z "$token" ]; then
        echo -e "${RED}No auth token found. Register or login first.${NC}" >&2
        exit 1
    fi
    echo "Authorization: Bearer $token"
}

# --- Configuration helpers ----------------------------------------------------

# Fetch the current user's configuration JSON.
# Requires AUTH_TOKEN to be set. Stores result in CONFIG_JSON.
fetch_configuration() {
    CONFIG_JSON=$(curl -s -X GET "${API_BASE_URL}/api/users/me/configuration" \
        -H "Authorization: Bearer $AUTH_TOKEN")
}

# Look up a category entry UUID by name from a dictionary.
# Usage: lookup_category_id <dict-id> <entry-name>
# Requires CONFIG_JSON to be set (call fetch_configuration first).
# Returns the UUID or empty string if not found.
lookup_category_id() {
    local dict_id="$1"
    local entry_name="$2"
    echo "$CONFIG_JSON" | jq -r \
        --arg d "$dict_id" --arg n "$entry_name" \
        '.dictionaries[$d].entries[] | select(.name == $n) | .id // empty'
}

# Look up the first category entry UUID in a dictionary.
# Usage: first_category_id <dict-id>
first_category_id() {
    local dict_id="$1"
    echo "$CONFIG_JSON" | jq -r \
        --arg d "$dict_id" \
        '.dictionaries[$d].entries[0].id // empty'
}
