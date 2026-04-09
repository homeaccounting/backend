#!/bin/bash

# Configuration API Testing Script
# Tests all configuration-related endpoints (get config, currencies, dictionary CRUD)
#
# Note: Configuration endpoints require JWT authentication.
# This script will auto-register a test user if no token is saved.
#
# Note: set -e is NOT used so all tests run even when individual assertions fail.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

_resolve_base_url "$@"
ARGS=$(_strip_endpoint_flags "$@")
set -- $ARGS

CONFIG_BASE="${API_BASE_URL}/api/users/me/configuration"

# Test: Get Configuration
test_get_configuration() {
    print_header "TEST: Get Configuration"

    ensure_authenticated

    print_info "Fetching user configuration..."
    RESPONSE=$(curl -s -X GET "${CONFIG_BASE}" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$RESPONSE" | jq '.'

    BASE_CUR=$(echo "$RESPONSE" | jq -r '.baseCurrency')
    DEFAULT_CUR=$(echo "$RESPONSE" | jq -r '.defaultCurrency')
    INCOME_COUNT=$(echo "$RESPONSE" | jq '.dictionaries["income-category"].entries | length')
    EXPENSE_COUNT=$(echo "$RESPONSE" | jq '.dictionaries["expense-category"].entries | length')

    if [ -n "$BASE_CUR" ] && [ "$BASE_CUR" != "null" ]; then
        print_success "Configuration retrieved"
        print_info "Base currency: $BASE_CUR"
        print_info "Default currency: $DEFAULT_CUR"
        print_info "Income categories: $INCOME_COUNT"
        print_info "Expense categories: $EXPENSE_COUNT"
    else
        print_error "Failed to get configuration"
        return 1
    fi
}

# Test: Change Base Currency
test_change_base_currency() {
    print_header "TEST: Change Base Currency"

    ensure_authenticated

    print_info "Changing base currency to EUR..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${CONFIG_BASE}/base-currency" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"currency": "EUR"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Base currency changed to EUR"
    else
        print_error "Failed to change base currency (HTTP $HTTP_CODE)"
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
        return 1
    fi

    # Verify the change
    print_info "Verifying change..."
    VERIFY=$(curl -s -X GET "${CONFIG_BASE}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    NEW_BASE=$(echo "$VERIFY" | jq -r '.baseCurrency')

    if [ "$NEW_BASE" = "EUR" ]; then
        print_success "Verified: base currency is now EUR"
    else
        print_error "Base currency is '$NEW_BASE', expected 'EUR'"
    fi

    # Change back to USD
    print_info "Reverting base currency to USD..."
    curl -s -w "\n%{http_code}" -X PUT "${CONFIG_BASE}/base-currency" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"currency": "USD"}' > /dev/null
    print_info "Reverted to USD"
}

# Test: Change Default Currency
test_change_default_currency() {
    print_header "TEST: Change Default Currency"

    ensure_authenticated

    print_info "Changing default currency to UAH..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${CONFIG_BASE}/default-currency" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"currency": "UAH"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Default currency changed to UAH"
    else
        print_error "Failed to change default currency (HTTP $HTTP_CODE)"
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
        return 1
    fi

    # Verify
    VERIFY=$(curl -s -X GET "${CONFIG_BASE}" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    NEW_DEFAULT=$(echo "$VERIFY" | jq -r '.defaultCurrency')

    if [ "$NEW_DEFAULT" = "UAH" ]; then
        print_success "Verified: default currency is now UAH"
    else
        print_error "Default currency is '$NEW_DEFAULT', expected 'UAH'"
    fi

    # Revert
    curl -s -X PUT "${CONFIG_BASE}/default-currency" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"currency": "USD"}' > /dev/null
    print_info "Reverted to USD"
}

# Test: Change to Invalid Currency (expected 400)
test_invalid_currency() {
    print_header "TEST: Change to Invalid Currency (Expected 400)"

    ensure_authenticated

    print_info "Attempting to set base currency to 'NOPE'..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT "${CONFIG_BASE}/base-currency" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"currency": "NOPE"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ]; then
        print_success "Correctly rejected invalid currency (HTTP $HTTP_CODE)"
    else
        print_info "Got HTTP $HTTP_CODE (expected 400/422)"
    fi
}

# Test: List Dictionary Entries
test_list_dictionary() {
    print_header "TEST: List Dictionary Entries"

    ensure_authenticated

    print_info "Listing income categories..."
    RESPONSE=$(curl -s -X GET "${CONFIG_BASE}/dictionaries/income-category" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    echo "$RESPONSE" | jq '.'

    ENTRY_COUNT=$(echo "$RESPONSE" | jq '.entries | length')

    if [ "$ENTRY_COUNT" -gt 0 ] 2>/dev/null; then
        print_success "Found $ENTRY_COUNT income categories"

        # Save the first entry ID for later tests
        FIRST_ID=$(echo "$RESPONSE" | jq -r '.entries[0].id')
        FIRST_NAME=$(echo "$RESPONSE" | jq -r '.entries[0].name')
        print_info "First entry: $FIRST_NAME ($FIRST_ID)"
    else
        print_error "No income categories found"
        return 1
    fi

    print_info "Listing expense categories..."
    EXPENSE_RESPONSE=$(curl -s -X GET "${CONFIG_BASE}/dictionaries/expense-category" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    EXPENSE_COUNT=$(echo "$EXPENSE_RESPONSE" | jq '.entries | length')
    print_success "Found $EXPENSE_COUNT expense categories"
}

# Test: Add Dictionary Entry
test_add_entry() {
    print_header "TEST: Add Dictionary Entry"

    ensure_authenticated

    print_info "Adding custom income category 'Side Hustle'..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        "${CONFIG_BASE}/dictionaries/income-category/entries" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Side Hustle"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"

    if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
        ENTRY_ID=$(echo "$BODY" | jq -r '.id')
        ENTRY_NAME=$(echo "$BODY" | jq -r '.name')
        print_success "Entry added: $ENTRY_NAME ($ENTRY_ID)"
        echo "$ENTRY_ID" > /tmp/test_config_entry_id.txt
    else
        print_error "Failed to add entry (HTTP $HTTP_CODE)"
        return 1
    fi
}

# Test: Rename Dictionary Entry
test_rename_entry() {
    print_header "TEST: Rename Dictionary Entry"

    ensure_authenticated

    if [ ! -f /tmp/test_config_entry_id.txt ]; then
        print_error "No entry ID found. Run 'add' test first."
        return 1
    fi

    ENTRY_ID=$(cat /tmp/test_config_entry_id.txt)

    print_info "Renaming entry $ENTRY_ID to 'Gig Work'..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        "${CONFIG_BASE}/dictionaries/income-category/entries/${ENTRY_ID}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $AUTH_TOKEN" \
        -d '{"name": "Gig Work"}')

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Entry renamed to 'Gig Work'"
    else
        print_error "Failed to rename entry (HTTP $HTTP_CODE)"
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
        return 1
    fi

    # Verify
    VERIFY=$(curl -s -X GET "${CONFIG_BASE}/dictionaries/income-category" \
        -H "Authorization: Bearer $AUTH_TOKEN")
    FOUND=$(echo "$VERIFY" | jq -r --arg id "$ENTRY_ID" '.entries[] | select(.id == $id) | .name')

    if [ "$FOUND" = "Gig Work" ]; then
        print_success "Verified: entry renamed to 'Gig Work'"
    else
        print_error "Entry name is '$FOUND', expected 'Gig Work'"
    fi
}

# Test: Remove Dictionary Entry
test_remove_entry() {
    print_header "TEST: Remove Dictionary Entry"

    ensure_authenticated

    if [ ! -f /tmp/test_config_entry_id.txt ]; then
        print_error "No entry ID found. Run 'add' test first."
        return 1
    fi

    ENTRY_ID=$(cat /tmp/test_config_entry_id.txt)

    print_info "Removing entry $ENTRY_ID..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X DELETE \
        "${CONFIG_BASE}/dictionaries/income-category/entries/${ENTRY_ID}" \
        -H "Authorization: Bearer $AUTH_TOKEN")

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "200" ]; then
        print_success "Entry removed"
        rm -f /tmp/test_config_entry_id.txt
    else
        print_error "Failed to remove entry (HTTP $HTTP_CODE)"
        echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"
        return 1
    fi
}

# Test: Get Configuration Without Auth (expected 401)
test_get_configuration_unauthorized() {
    print_header "TEST: Get Configuration Without Auth (Expected 401)"

    print_info "Attempting to get configuration without token..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "${CONFIG_BASE}")

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
    echo -e "${GREEN}+=============================================+${NC}"
    echo -e "${GREEN}|   Configuration API Testing Script          |${NC}"
    echo -e "${GREEN}+=============================================+${NC}"

    check_server

    if [ $# -eq 0 ]; then
        echo ""
        echo "Usage: $0 [test_name] [--prod|--local]"
        echo ""
        echo "Available tests:"
        echo "  all              - Run all tests in sequence"
        echo "  get              - Get current configuration"
        echo "  base-currency    - Change base currency"
        echo "  default-currency - Change default currency"
        echo "  invalid-currency - Test invalid currency (expected 400)"
        echo "  list             - List dictionary entries"
        echo "  add              - Add a dictionary entry"
        echo "  rename           - Rename a dictionary entry"
        echo "  remove           - Remove a dictionary entry"
        echo "  unauthorized     - Test without auth (expected 401)"
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
            test_get_configuration
            test_change_base_currency
            test_change_default_currency
            test_invalid_currency
            test_list_dictionary
            test_add_entry
            test_rename_entry
            test_remove_entry
            test_get_configuration_unauthorized
            print_header "ALL TESTS COMPLETED"
            ;;
        get)
            test_get_configuration
            ;;
        base-currency)
            test_change_base_currency
            ;;
        default-currency)
            test_change_default_currency
            ;;
        invalid-currency)
            test_invalid_currency
            ;;
        list)
            test_list_dictionary
            ;;
        add)
            test_add_entry
            ;;
        rename)
            test_rename_entry
            ;;
        remove)
            test_remove_entry
            ;;
        unauthorized)
            test_get_configuration_unauthorized
            ;;
        *)
            print_error "Unknown test: $1"
            echo "Run '$0' without arguments to see available tests."
            exit 1
            ;;
    esac
}

main "$@"
