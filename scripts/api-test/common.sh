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

# Source two .env files in order:
#   1. <project_root>/.env             — app runtime (DB, JWT, OAuth, ...)
#   2. <project_root>/scripts/api-test/.env — test fixtures (TEST_USER_*,
#      TELEGRAM_USER_*, MONOBANK_*); shadows root for any overlap.
# The nested file is what isolates test fixtures from `cabal run` / `just run`.
load_env() {
    local project_root="${1:-$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)}"
    if [ -n "$_API_TEST_ENV_LOADED" ]; then
        return
    fi
    local f
    for f in "${project_root}/.env" "${project_root}/scripts/api-test/.env"; do
        if [ -f "$f" ]; then
            set -a
            # shellcheck disable=SC1090
            source "$f"
            set +a
        fi
    done
    export _API_TEST_ENV_LOADED=1
}

# Auto-load .env when common.sh is sourced so every test script has access to
# TEST_USER_*, TELEGRAM_*, MONOBANK_*, etc. without explicit setup.
load_env "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- Test credentials ---------------------------------------------------------

# Resolve primary test user email/password into TEST_USER_EMAIL / TEST_USER_PASSWORD.
# Priority: existing env vars (from .env) > saved /tmp credentials > generated.
resolve_user_credentials() {
    if [ -z "$TEST_USER_EMAIL" ] \
        && [ -f /tmp/test_user_email.txt ] \
        && [ -f /tmp/test_user_password.txt ]; then
        TEST_USER_EMAIL=$(cat /tmp/test_user_email.txt)
        TEST_USER_PASSWORD=$(cat /tmp/test_user_password.txt)
    fi
    : "${TEST_USER_EMAIL:=testuser-$(date +%s)@example.com}"
    : "${TEST_USER_PASSWORD:=SecurePass123!}"
}

# Resolve secondary test user email/password into TEST_USER2_EMAIL / TEST_USER2_PASSWORD.
# Priority: existing env vars (from .env) > generated.
resolve_user2_credentials() {
    : "${TEST_USER2_EMAIL:=seconduser-$(date +%s)@example.com}"
    : "${TEST_USER2_PASSWORD:=SecurePass456!}"
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

# Persist resolved primary credentials and token to /tmp for cross-script reuse.
save_user_session() {
    echo "$TEST_USER_TOKEN"    > /tmp/test_user_token.txt
    echo "$TEST_USER_EMAIL"    > /tmp/test_user_email.txt
    echo "$TEST_USER_PASSWORD" > /tmp/test_user_password.txt
}

# Populate TEST_USER_TOKEN from the /tmp cache if it isn't already set.
# Env-provided tokens take precedence — the cache is only a cross-process bridge.
load_user_token() {
    if [ -z "$TEST_USER_TOKEN" ] && [ -s /tmp/test_user_token.txt ]; then
        TEST_USER_TOKEN=$(cat /tmp/test_user_token.txt)
    fi
}

# Echo the resolved token (loading from cache if needed). Empty string if none.
get_user_token() {
    load_user_token
    echo "$TEST_USER_TOKEN"
}

# Ensure TEST_USER_TOKEN is populated. Tries (in order):
#   1. existing env var / cached token (load_user_token)
#   2. login with resolved credentials
#   3. register with resolved credentials
ensure_user_auth() {
    load_user_token
    if [ -n "$TEST_USER_TOKEN" ]; then
        print_info "Using saved auth token"
        return
    fi

    resolve_user_credentials

    print_info "Attempting login as: $TEST_USER_EMAIL"
    local response
    response=$(curl -s -X POST "${API_BASE_URL}/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"email\": \"$TEST_USER_EMAIL\", \"password\": \"$TEST_USER_PASSWORD\"}")
    TEST_USER_TOKEN=$(echo "$response" | jq -r '.token')

    if [ -z "$TEST_USER_TOKEN" ] || [ "$TEST_USER_TOKEN" = "null" ]; then
        print_info "Login failed; registering new user..."
        response=$(curl -s -X POST "${API_BASE_URL}/api/auth/register" \
            -H "Content-Type: application/json" \
            -d "{\"email\": \"$TEST_USER_EMAIL\", \"password\": \"$TEST_USER_PASSWORD\"}")
        TEST_USER_TOKEN=$(echo "$response" | jq -r '.token')
    fi

    if [ -n "$TEST_USER_TOKEN" ] && [ "$TEST_USER_TOKEN" != "null" ]; then
        save_user_session
        print_success "Authenticated as: $TEST_USER_EMAIL"
    else
        print_error "Failed to authenticate"
        echo "$response" | jq '.' 2>/dev/null || echo "$response"
        exit 1
    fi
}

# Print Authorization header value (exits if no token).
user_auth_header() {
    load_user_token
    if [ -z "$TEST_USER_TOKEN" ]; then
        echo -e "${RED}No auth token found. Register or login first.${NC}" >&2
        exit 1
    fi
    echo "Authorization: Bearer $TEST_USER_TOKEN"
}

# --- Configuration helpers ----------------------------------------------------

# Fetch the current user's configuration JSON.
# Requires TEST_USER_TOKEN to be set. Stores result in CONFIG_JSON.
fetch_configuration() {
    CONFIG_JSON=$(curl -s -X GET "${API_BASE_URL}/api/users/me/configuration" \
        -H "Authorization: Bearer $TEST_USER_TOKEN")
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
