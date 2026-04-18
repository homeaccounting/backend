#!/bin/bash

# Banking API Testing Script
# Smoke-tests the Monobank resync feature against a running backend.
#
# Prerequisites:
#   - Server running (use --prod or --local to select endpoint)
#   - A cached JWT at /tmp/test_auth_token.txt (obtained via test-auth.sh,
#     test-telegram.sh login <YOUR_TG_ID>, or by seeding TEST_AUTH_TOKEN)
#   - MONOBANK_TOKEN env var (personal token from api.monobank.ua)
#   - MONOBANK_IBAN env var (must match the IBAN Monobank returns for
#     the account you want to import)
#
# Subcommands:
#   setup   - Find-or-create a BankAccount-typed local account for $MONOBANK_IBAN
#   resync  - POST /api/banking/resync for the resolved account
#   verify  - Diff account balance before/after and print import counts
#   all     - setup -> resync -> verify
#
# Note: set -e is NOT used so individual assertion failures do not
# short-circuit the remainder of the script, matching sibling scripts.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAYLOADS_DIR="${SCRIPT_DIR}/payloads/banking"

load_env "$PROJECT_ROOT"

# Seed the shared token cache from TEST_AUTH_TOKEN when present, so a
# user can run this script with a pasted JWT and no prior login step.
if [ -n "$TEST_AUTH_TOKEN" ]; then
    echo "$TEST_AUTH_TOKEN" > /tmp/test_auth_token.txt
fi

# Defaults
CURRENCY="${CURRENCY:-UAH}"
BANK_NAME="${BANK_NAME:-Monobank}"
ACCOUNT_NAME="${ACCOUNT_NAME:-Mono ${CURRENCY}}"
# Overdraft limit for the created BankAccount. Bank imports emit transfers
# from the BankAccount to the user's External account; without enough
# overdraft room the first expense hits "Insufficient funds" and the
# TransferFailed poisons BankImportReadModel's dedup index.
OVERDRAFT_LIMIT="${OVERDRAFT_LIMIT:-100000}"

# Default date window: last 30 days, ISO-8601 with Z suffix.
# Backend caps the range at 31 days (src/Web/API/BankingAPI.hs:216-220),
# so 30 leaves a safety margin for clock skew.
# `date -u -v` is BSD (macOS); `date -u -d` is GNU (Linux).
_default_dates() {
    if date -u -v-30d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
        FROM_DEFAULT=$(date -u -v-30d +%Y-%m-%dT%H:%M:%SZ)
    else
        FROM_DEFAULT=$(date -u -d "30 days ago" +%Y-%m-%dT%H:%M:%SZ)
    fi
    TO_DEFAULT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
}
_default_dates
FROM="${FROM:-$FROM_DEFAULT}"
TO="${TO:-$TO_DEFAULT}"

# State files (banking-specific cache)
ACCOUNT_ID_CACHE="/tmp/test_banking_account_id.txt"
RESYNC_RESPONSE_CACHE="/tmp/test_banking_last_resync.json"
BALANCE_BEFORE_CACHE="/tmp/test_banking_balance_before.txt"

# --- Prereqs ------------------------------------------------------------------

check_prerequisites() {
    local missing=0
    for bin in curl jq envsubst; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            print_error "$bin is required but not found"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

require_auth_token() {
    if [ ! -s /tmp/test_auth_token.txt ]; then
        print_error "No cached JWT found at /tmp/test_auth_token.txt"
        echo ""
        echo "Obtain a token using one of:"
        echo "  1. Password login:    ./scripts/api-test/test-auth.sh login"
        echo "  2. Telegram widget:   ./scripts/api-test/test-telegram.sh login <YOUR_TG_ID> <FirstName> <username>"
        echo "  3. Pasted JWT:        export TEST_AUTH_TOKEN='...' and re-run"
        exit 1
    fi
    AUTH_TOKEN=$(cat /tmp/test_auth_token.txt)
}

require_iban() {
    if [ -z "$MONOBANK_IBAN" ]; then
        print_error "MONOBANK_IBAN is not set (exact IBAN Monobank returns for the account)"
        exit 1
    fi
}

require_token() {
    if [ -z "$MONOBANK_TOKEN" ]; then
        print_error "MONOBANK_TOKEN is not set (personal token from api.monobank.ua)"
        exit 1
    fi
}

# --- Subcommand stubs (filled in by later tasks) ------------------------------

test_setup() {
    print_header "TEST: Banking setup (find-or-create BankAccount)"

    require_auth_token

    # Short-circuit on ACCOUNT_ID override
    if [ -n "$ACCOUNT_ID" ]; then
        print_info "ACCOUNT_ID override: $ACCOUNT_ID"
        echo "$ACCOUNT_ID" > "$ACCOUNT_ID_CACHE"
        print_success "Cached account id at $ACCOUNT_ID_CACHE"
        return 0
    fi

    require_iban

    print_info "Listing accounts and matching bankAccount/accountNumber=$MONOBANK_IBAN..."
    LIST_RESPONSE=$(curl -s -X GET "${API_BASE_URL}/api/accounts" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    # Defensive check: if the DTO does not expose subtype.accountNumber,
    # bail out loudly rather than silently creating duplicates.
    if ! echo "$LIST_RESPONSE" | jq -e '[.accounts[] | select(.subtype != null)] | length >= 0' >/dev/null 2>&1; then
        print_error "Unexpected /api/accounts response shape"
        echo "$LIST_RESPONSE" | jq '.' 2>/dev/null || echo "$LIST_RESPONSE"
        exit 1
    fi

    MATCH_ID=$(echo "$LIST_RESPONSE" | jq -r \
        --arg iban "$MONOBANK_IBAN" \
        '[.accounts[] | select(.subtype.type == "bankAccount" and .subtype.accountNumber == $iban)][0].id // empty')

    if [ -n "$MATCH_ID" ]; then
        print_success "Reusing existing BankAccount: $MATCH_ID (IBAN $MONOBANK_IBAN)"
        echo "$MATCH_ID" > "$ACCOUNT_ID_CACHE"
        return 0
    fi

    print_info "No match. Creating BankAccount name=\"$ACCOUNT_NAME\" currency=$CURRENCY iban=$MONOBANK_IBAN overdraftLimit=$OVERDRAFT_LIMIT..."

    local body
    body=$(MONOBANK_IBAN="$MONOBANK_IBAN" ACCOUNT_NAME="$ACCOUNT_NAME" \
           CURRENCY="$CURRENCY" BANK_NAME="$BANK_NAME" \
           OVERDRAFT_LIMIT="$OVERDRAFT_LIMIT" \
           envsubst < "${PAYLOADS_DIR}/create-account.template.json")

    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/accounts" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d "$body")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')
    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    NEW_ID=$(echo "$BODY" | jq -r '.id // empty')
    if [ "$HTTP_CODE" = "201" ] && [ -n "$NEW_ID" ]; then
        print_success "BankAccount created: $NEW_ID (HTTP $HTTP_CODE)"
        echo "$NEW_ID" > "$ACCOUNT_ID_CACHE"
    else
        print_error "Failed to create BankAccount (HTTP $HTTP_CODE)"
        exit 1
    fi
}

test_resync() {
    print_header "TEST: Banking resync"

    require_auth_token
    require_token

    if [ ! -s "$ACCOUNT_ID_CACHE" ]; then
        print_error "No cached account id. Run 'setup' first or export ACCOUNT_ID."
        exit 1
    fi
    local account_id
    account_id=$(cat "$ACCOUNT_ID_CACHE")

    # Snapshot balance BEFORE resync so verify can diff.
    print_info "Snapshotting balance of $account_id before resync..."
    local acc_before
    acc_before=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${account_id}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    local balance_before
    balance_before=$(echo "$acc_before" | jq -r '.balance // empty')
    if [ -z "$balance_before" ]; then
        print_error "Could not read balance of $account_id before resync"
        echo "$acc_before" | jq '.' 2>/dev/null || echo "$acc_before"
        exit 1
    fi
    echo "$balance_before" > "$BALANCE_BEFORE_CACHE"
    print_balance "Balance before: $balance_before"

    # Resolve CATEGORY_ID from configuration if not supplied.
    if [ -z "$CATEGORY_ID" ]; then
        print_info "CATEGORY_ID unset; resolving first expense-category entry..."
        fetch_configuration
        CATEGORY_ID=$(first_category_id "expense-category")
        if [ -z "$CATEGORY_ID" ]; then
            print_error "Could not resolve a default expense-category id from /api/users/me/configuration"
            exit 1
        fi
        print_info "Using CATEGORY_ID=$CATEGORY_ID"
    fi

    local body
    body=$(FROM="$FROM" TO="$TO" CATEGORY_ID="$CATEGORY_ID" \
           envsubst < "${PAYLOADS_DIR}/resync.template.json")

    print_info "POST /api/banking/resync  from=$FROM  to=$TO"
    local response
    # Use a separate variable so the curl -w suffix does not pollute the JSON body.
    response=$(curl -s -w "\n%{http_code}" -X POST "${API_BASE_URL}/api/banking/resync" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -H "X-Banking-Token: $MONOBANK_TOKEN" \
        -d "$body")

    local http_code body_json
    http_code=$(echo "$response" | tail -n1)
    body_json=$(echo "$response" | sed '$d')

    case "$http_code" in
        200)
            echo "$body_json" | jq '.' 2>/dev/null || echo "$body_json"
            echo "$body_json" > "$RESYNC_RESPONSE_CACHE"
            print_success "Resync OK (HTTP 200) — response cached at $RESYNC_RESPONSE_CACHE"
            ;;
        400)
            print_error "Bad request (HTTP 400)"
            echo "$body_json" | jq '.' 2>/dev/null || echo "$body_json"
            exit 1
            ;;
        401)
            print_error "Unauthorized (HTTP 401) — JWT missing or expired. Re-authenticate and retry."
            exit 1
            ;;
        404)
            print_error "Not found (HTTP 404). The banking feature may be disabled:"
            print_info "Check AppConfig.banking.enabled and providers.monobank.enabled in your config"
            echo "$body_json" | jq '.' 2>/dev/null || echo "$body_json"
            exit 1
            ;;
        *)
            print_error "Unexpected HTTP $http_code"
            echo "$body_json" | jq '.' 2>/dev/null || echo "$body_json"
            exit 1
            ;;
    esac
}

test_verify() {
    print_header "TEST: Banking verify"

    require_auth_token

    if [ ! -s "$ACCOUNT_ID_CACHE" ]; then
        print_error "No cached account id. Run 'setup' first."
        exit 1
    fi
    if [ ! -s "$RESYNC_RESPONSE_CACHE" ]; then
        print_error "No cached resync response at $RESYNC_RESPONSE_CACHE. Run 'resync' first."
        exit 1
    fi
    if [ ! -s "$BALANCE_BEFORE_CACHE" ]; then
        print_error "No cached before-balance at $BALANCE_BEFORE_CACHE. Run 'resync' first."
        exit 1
    fi

    local account_id balance_before resync_json acc_after balance_after
    account_id=$(cat "$ACCOUNT_ID_CACHE")
    balance_before=$(cat "$BALANCE_BEFORE_CACHE")
    resync_json=$(cat "$RESYNC_RESPONSE_CACHE")

    acc_after=$(curl -s -X GET "${API_BASE_URL}/api/accounts/${account_id}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    balance_after=$(echo "$acc_after" | jq -r '.balance // empty')
    if [ -z "$balance_after" ]; then
        print_error "Could not read balance of $account_id after resync"
        echo "$acc_after" | jq '.' 2>/dev/null || echo "$acc_after"
        exit 1
    fi

    print_balance "Balance before: $balance_before"
    print_balance "Balance after:  $balance_after"

    # Locate the per-account summary for this local account id
    local summary imported skipped failures
    summary=$(echo "$resync_json" | jq -c \
        --arg id "$account_id" \
        '.accounts[] | select(.localAccountId == $id)')
    if [ -z "$summary" ] || [ "$summary" = "null" ]; then
        print_error "Resync response has no summary for account $account_id"
        echo "$resync_json" | jq '.'
        exit 1
    fi

    imported=$(echo "$summary" | jq -r '.importedCount')
    skipped=$(echo "$summary" | jq -r '.skippedCount')
    failures=$(echo "$summary" | jq -r '.failureCount')

    print_info "importedCount=$imported  skippedCount=$skipped  failureCount=$failures"

    local fail=0
    if [ "$failures" != "0" ]; then
        print_error "failureCount > 0 — see server logs for details"
        fail=1
    fi

    # Warn (do not fail) when imports happened but balance did not move.
    # Rationale: reversals within the range can net to zero.
    if [ "$imported" != "0" ] && [ "$balance_before" = "$balance_after" ]; then
        print_info "WARNING: importedCount > 0 but balance unchanged ($balance_before -> $balance_after). Check server logs / read-model for same-day reversals."
    fi

    if [ "$fail" -eq 0 ]; then
        print_success "Verify passed"
    else
        exit 1
    fi
}

test_all() {
    test_setup
    test_resync
    test_verify
    print_header "BANKING TESTS COMPLETED"
}

usage() {
    cat <<EOF
Usage: $0 [--prod|--local] <subcommand>

Subcommands:
  setup    Find-or-create a BankAccount-typed local account for \$MONOBANK_IBAN
  resync   POST /api/banking/resync for the resolved account
  verify   Diff account balance before/after and print import counts
  all      setup -> resync -> verify

Required env vars (per subcommand):
  MONOBANK_TOKEN   resync, all
  MONOBANK_IBAN    setup, all
  FROM, TO         resync, all (ISO-8601; default last 30 days / now; max span 31 days)

Optional:
  ACCOUNT_ID       short-circuit setup
  CATEGORY_ID      defaultCategory UUID; default = first expense-category entry
  CURRENCY         default UAH
  BANK_NAME        default Monobank
  ACCOUNT_NAME     default "Mono \${CURRENCY}"
  TEST_AUTH_TOKEN  seed /tmp/test_auth_token.txt with a pasted JWT

Auth: see require_auth_token() in this script.
EOF
}

main() {
    check_prerequisites
    check_server

    if [ -z "$1" ]; then
        usage
        exit 0
    fi

    case "$1" in
        setup)   test_setup ;;
        resync)  test_resync ;;
        verify)  test_verify ;;
        all)     test_all ;;
        -h|--help|help)
            usage
            ;;
        *)
            print_error "Unknown subcommand: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
