---
status: draft
---

# Banking API Test Script — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `scripts/api-test/test-banking.sh` plus its two JSON payload templates and a README section so that a developer with a real Monobank personal token can smoke-test the resync feature (`POST /api/banking/resync`) end-to-end against a running backend.

**Architecture:** One new bash script under `scripts/api-test/` following the style already established by `test-accounts.sh`, `test-telegram.sh`, etc. — `common.sh` is sourced for endpoint flags, colour helpers, token cache, and configuration lookups. Two tiny JSON payload templates under `scripts/api-test/payloads/banking/` are rendered with `envsubst` at run time. No backend or production code is touched. The script has four subcommands (`setup`, `resync`, `verify`, `all`) driven by a `case` dispatch matching the sibling scripts.

**Tech Stack:** bash 3.2+ (macOS default), `curl`, `jq`, `envsubst` (from `gettext`; already assumed present by other scripts). No Haskell changes.

**Testing posture:** These API test scripts are themselves the test harness — there is no unit test suite for them (mirror the convention in `test-accounts.sh`, `test-transactions.sh`). Verification for each task is executing the script against a local backend started via `just docker-up` + `just run` and inspecting the output / cached files. Automated unit coverage is explicitly out of scope; the spec's acceptance criteria are the contract.

**Spec reference:** `docs/specs/2026-04-18-banking-api-test-script-design.md`

---

## File Structure

- **Create** `scripts/api-test/test-banking.sh` — the new executable. Sole responsibility: drive resync end-to-end for one user + one BankAccount.
- **Create** `scripts/api-test/payloads/banking/create-account.template.json` — templated body for `POST /api/accounts` with a `BankAccount` subtype.
- **Create** `scripts/api-test/payloads/banking/resync.template.json` — templated body for `POST /api/banking/resync`.
- **Modify** `scripts/api-test/README.md` — add `test-banking.sh` to the "Directory Structure" listing and append a "Banking" section documenting env vars, auth entry points, Monobank caveats, and the IBAN-match requirement.

No other files are touched.

---

## Task 1: Scaffold `test-banking.sh`

**Files:**
- Create: `scripts/api-test/test-banking.sh`

Goal: a runnable skeleton with prerequisites checks, endpoint-flag handling, a `case` dispatch, and stub subcommands that each log "not implemented yet". The first `chmod +x` + commit happens here so every subsequent task can focus on one subcommand.

- [ ] **Step 1: Create the skeleton file**

Write the following at `scripts/api-test/test-banking.sh`:

```bash
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

# Default date window: last 7 days, ISO-8601 with Z suffix.
# `date -u -v` is BSD (macOS); `date -u -d` is GNU (Linux).
_default_dates() {
    if date -u -v-7d +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
        FROM_DEFAULT=$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)
    else
        FROM_DEFAULT=$(date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ)
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
    print_info "not implemented yet"
}

test_resync() {
    print_header "TEST: Banking resync"
    print_info "not implemented yet"
}

test_verify() {
    print_header "TEST: Banking verify"
    print_info "not implemented yet"
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
  FROM, TO         resync, all (ISO-8601; default last 7 days / now; max span 31 days)

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
```

- [ ] **Step 2: Make executable**

Run: `chmod +x scripts/api-test/test-banking.sh`

- [ ] **Step 3: Smoke-test the skeleton**

Run (backend must be up via `just docker-up && just run`):

```
./scripts/api-test/test-banking.sh
./scripts/api-test/test-banking.sh help
./scripts/api-test/test-banking.sh all
```

Expected:
- No-arg and `help` print the usage block.
- `all` prints three "not implemented yet" info lines and "BANKING TESTS COMPLETED". No HTTP calls are made yet (subcommands are stubs). The initial `check_server` must succeed against `http://localhost:8080`.

- [ ] **Step 4: Commit**

```
git add scripts/api-test/test-banking.sh
git commit -m "feat(scripts): scaffold banking API test script"
git push
```

---

## Task 2: Payload templates

**Files:**
- Create: `scripts/api-test/payloads/banking/create-account.template.json`
- Create: `scripts/api-test/payloads/banking/resync.template.json`

- [ ] **Step 1: Create the payloads directory and `create-account.template.json`**

Write `scripts/api-test/payloads/banking/create-account.template.json`:

```json
{
  "name": "${ACCOUNT_NAME}",
  "initialBalance": 0,
  "currency": "${CURRENCY}",
  "subtype": {
    "type": "bankAccount",
    "bankName": "${BANK_NAME}",
    "accountNumber": "${MONOBANK_IBAN}"
  }
}
```

- [ ] **Step 2: Create `resync.template.json`**

Write `scripts/api-test/payloads/banking/resync.template.json`:

```json
{
  "from": "${FROM}",
  "to": "${TO}",
  "defaultCategory": "${CATEGORY_ID}"
}
```

- [ ] **Step 3: Sanity-check rendering**

Run:

```
MONOBANK_IBAN=UA000000000000000000000000000 \
ACCOUNT_NAME="Mono UAH" CURRENCY=UAH BANK_NAME=Monobank \
envsubst < scripts/api-test/payloads/banking/create-account.template.json | jq .
```

Expected: pretty-printed JSON with the env values substituted and no `${…}` placeholders remaining.

- [ ] **Step 4: Commit**

```
git add scripts/api-test/payloads/banking/
git commit -m "feat(scripts): add banking request payload templates"
git push
```

---

## Task 3: Implement `setup` subcommand (find-or-create BankAccount)

**Files:**
- Modify: `scripts/api-test/test-banking.sh` — replace the `test_setup` stub

Responsibility: resolve the local account id for `$MONOBANK_IBAN`, creating one if needed. Idempotent — a second call returns the same id without a second `POST`.

- [ ] **Step 1: Replace `test_setup` with the real implementation**

Replace the stub body (`print_info "not implemented yet"`) of `test_setup` with:

```bash
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
    if ! echo "$LIST_RESPONSE" | jq -e '[.[] | select(.subtype != null)] | length >= 0' >/dev/null 2>&1; then
        print_error "Unexpected /api/accounts response shape"
        echo "$LIST_RESPONSE" | jq '.' 2>/dev/null || echo "$LIST_RESPONSE"
        exit 1
    fi

    MATCH_ID=$(echo "$LIST_RESPONSE" | jq -r \
        --arg iban "$MONOBANK_IBAN" \
        '[.[] | select(.subtype.type == "bankAccount" and .subtype.accountNumber == $iban)][0].id // empty')

    if [ -n "$MATCH_ID" ]; then
        print_success "Reusing existing BankAccount: $MATCH_ID (IBAN $MONOBANK_IBAN)"
        echo "$MATCH_ID" > "$ACCOUNT_ID_CACHE"
        return 0
    fi

    print_info "No match. Creating BankAccount name=\"$ACCOUNT_NAME\" currency=$CURRENCY iban=$MONOBANK_IBAN..."

    local body
    body=$(MONOBANK_IBAN="$MONOBANK_IBAN" ACCOUNT_NAME="$ACCOUNT_NAME" \
           CURRENCY="$CURRENCY" BANK_NAME="$BANK_NAME" \
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
```

- [ ] **Step 2: Run against a local backend — first run creates**

Set up:

```
just docker-up    # if not already up
just run          # in another shell
./scripts/api-test/test-telegram.sh login <YOUR_TG_ID> <First> <username>
```

Then:

```
export MONOBANK_IBAN=UA000000000000000000000000000
./scripts/api-test/test-banking.sh setup
```

Expected: a new BankAccount is created, its id printed, and `/tmp/test_banking_account_id.txt` contains that id.

- [ ] **Step 3: Run again — idempotent**

```
./scripts/api-test/test-banking.sh setup
cat /tmp/test_banking_account_id.txt
```

Expected: second run reports "Reusing existing BankAccount" with the **same id** as the first run. No new account was created on the server.

- [ ] **Step 4: Verify `ACCOUNT_ID` override short-circuits**

```
ACCOUNT_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee ./scripts/api-test/test-banking.sh setup
cat /tmp/test_banking_account_id.txt
```

Expected: prints "ACCOUNT_ID override" and the cache file now contains that placeholder id (no HTTP calls made).

- [ ] **Step 5: Commit**

```
git add scripts/api-test/test-banking.sh
git commit -m "feat(scripts): implement banking setup (find-or-create BankAccount)"
git push
```

---

## Task 4: Implement `resync` subcommand

**Files:**
- Modify: `scripts/api-test/test-banking.sh` — replace the `test_resync` stub

Responsibility: snapshot the account balance (for the later `verify` step), resolve the `defaultCategory` UUID, render the resync body, POST it with the `X-Banking-Token` header, and cache the response.

- [ ] **Step 1: Replace `test_resync` with the real implementation**

```bash
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
```

- [ ] **Step 2: Run against a local backend with a real token**

Pre-requirements: `setup` has been run so the cached account id exists, and `$MONOBANK_TOKEN` / `$MONOBANK_IBAN` are set with real values.

```
./scripts/api-test/test-banking.sh resync
```

Expected: HTTP 200 body with an `accounts` array; at least one entry should have `externalAccountId`, `localAccountId` matching the cached id, and non-negative counts. The file `/tmp/test_banking_last_resync.json` exists and contains the full response. `/tmp/test_banking_balance_before.txt` contains a decimal.

- [ ] **Step 3: Verify feature-flag 404 path**

Temporarily flip `banking.enabled` or `providers.monobank.enabled` to `false` in the local config, restart the server, and re-run:

```
./scripts/api-test/test-banking.sh resync
```

Expected: prints the "banking feature may be disabled" hint and exits non-zero. Flip the config back before continuing.

- [ ] **Step 4: Commit**

```
git add scripts/api-test/test-banking.sh
git commit -m "feat(scripts): implement banking resync subcommand"
git push
```

---

## Task 5: Implement `verify` subcommand

**Files:**
- Modify: `scripts/api-test/test-banking.sh` — replace the `test_verify` stub

Responsibility: re-fetch the account and print before/after balances plus the cached per-account counts from the last resync response. Exit non-zero when any `failureCount > 0`; warn (do not fail) when `importedCount > 0` and the delta is 0 (same-day reversals can net to zero).

- [ ] **Step 1: Replace `test_verify` with the real implementation**

```bash
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
```

- [ ] **Step 2: Run against a local backend**

With a prior `setup` + `resync` in the same shell session:

```
./scripts/api-test/test-banking.sh verify
```

Expected: prints both balances, the three counts, and "Verify passed" when `failureCount == 0`. If no transactions exist for the date window, `importedCount == 0` is fine and is not a failure.

- [ ] **Step 3: Commit**

```
git add scripts/api-test/test-banking.sh
git commit -m "feat(scripts): implement banking verify subcommand"
git push
```

---

## Task 6: Wire `all` + end-to-end run

**Files:**
- Modify: `scripts/api-test/test-banking.sh` — confirm `test_all` orchestrates correctly (already wired at scaffolding) and run the composed flow.

`test_all` was wired in Task 1. No new code here — this task's purpose is to run the whole pipeline against a real backend to confirm the three subcommands compose cleanly.

- [ ] **Step 1: Full end-to-end run**

Pre-req:
- Backend running locally (`just docker-up && just run`)
- Authenticated as your bot-registered user (`./scripts/api-test/test-telegram.sh login <TG_ID> …`)
- `export MONOBANK_TOKEN=... MONOBANK_IBAN=UA...`

Then:

```
./scripts/api-test/test-banking.sh all
```

Expected output, in order:
1. "TEST: Banking setup" — prints new or reused account id
2. "TEST: Banking resync" — prints HTTP 200 JSON with counts
3. "TEST: Banking verify" — prints balances + counts + "Verify passed"
4. "BANKING TESTS COMPLETED"

No commit here unless the run revealed a bug — if it did, fix in the relevant task's subcommand and commit under that task's scope.

---

## Task 7: README update

**Files:**
- Modify: `scripts/api-test/README.md` — add `test-banking.sh` to the Directory Structure block and append a new "Banking" section.

- [ ] **Step 1: Update the Directory Structure listing**

In the code block under "## Directory Structure" (around line 12 of the current README), add a new line for `test-banking.sh`. Place it after `test-transactions.sh` so the listing stays roughly in subcommand-complexity order:

```
├── test-transactions.sh   # Transaction operations tests (transfer, status)
├── test-banking.sh        # Monobank resync smoke test (setup, resync, verify)
```

And add a `banking/` subdirectory entry under `payloads/`:

```
├── transactions/         # Transaction operation payloads
│   ├── income-500.json
│   ├── expense-100.json
│   ├── transfer-300.json
│   └── transfer-500.json
└── banking/              # Banking payload templates (rendered via envsubst)
    ├── create-account.template.json
    └── resync.template.json
```

- [ ] **Step 2: Append a "Banking" section**

Append immediately after the "Test Telegram Authentication" section (before the "Quick Commands" block):

```markdown
#### Test Banking (Monobank resync)

Smoke-tests `POST /api/banking/resync` end-to-end with a real Monobank
personal token.

**Prerequisites**

1. A cached JWT in `/tmp/test_auth_token.txt`. Three ways to obtain one:
   - **Password user:** `./scripts/api-test/test-auth.sh login`
   - **Bot-registered Telegram user:** `./scripts/api-test/test-telegram.sh login <YOUR_TG_ID> <FirstName> <username>` — the widget endpoint resolves your existing bot-registered user by `TelegramId` and returns a matching JWT.
   - **Pasted JWT:** `export TEST_AUTH_TOKEN='<jwt>'` and the script will seed the cache on the next run.
2. A Monobank personal token from <https://api.monobank.ua/>. Export as `MONOBANK_TOKEN`.
3. The exact IBAN Monobank reports for the account you want to import. Export as `MONOBANK_IBAN`.

**Caveats**

- Monobank enforces a **60-second rate limit** between `/personal/statement` calls. Running `resync` or `all` repeatedly will start failing until the cooldown elapses.
- The local `BankAccount.accountNumber` must match the Monobank-reported IBAN **verbatim** — the backend matches on string equality (see `src/Web/API/BankingAPI.hs:327`).
- The resync date range must not exceed **31 days** (enforced at `src/Web/API/BankingAPI.hs:216-220`).
- A future endpoint for listing transactions by account is tracked in homeaccounting/backend#47. Until that ships, `verify` relies on balance diffs + response counts.

**Usage**

```bash
export MONOBANK_TOKEN='your-personal-token'
export MONOBANK_IBAN='UA000000000000000000000000000'

./scripts/api-test/test-banking.sh setup    # find-or-create a BankAccount
./scripts/api-test/test-banking.sh resync   # import statements
./scripts/api-test/test-banking.sh verify   # balance diff + counts
./scripts/api-test/test-banking.sh all      # setup -> resync -> verify
```

**Optional env vars**

| Variable       | Default                | Notes                                                |
| -------------- | ---------------------- | ---------------------------------------------------- |
| `ACCOUNT_ID`   | —                      | Skip `setup` and reuse an existing local account id  |
| `CATEGORY_ID`  | first expense-category | `defaultCategory` UUID sent in the request body      |
| `CURRENCY`     | `UAH`                  | Currency of the created BankAccount                  |
| `BANK_NAME`    | `Monobank`             | Stored in `BankAccount.bankName`                     |
| `ACCOUNT_NAME` | `Mono <CURRENCY>`      | Display name of the created account                  |
| `FROM`, `TO`   | last 7 days / now      | ISO-8601 UTC. Max range is 31 days                   |
```

- [ ] **Step 3: Render-check**

Run:

```
grep -n "test-banking.sh" scripts/api-test/README.md
grep -n "## Test Banking" -i scripts/api-test/README.md
```

Expected: at least two hits for `test-banking.sh` (directory listing + section) and one hit for the Banking section header.

- [ ] **Step 4: Commit**

```
git add scripts/api-test/README.md
git commit -m "docs(scripts): document banking API test script"
git push
```

---

## Final verification checklist

Do these before declaring the work done; each maps to the spec's acceptance criteria.

- [ ] Fresh-DB run: `./scripts/api-test/test-banking.sh setup` creates exactly one `BankAccount` with the supplied IBAN and prints its id.
- [ ] Re-run of `setup` prints "Reusing existing BankAccount" with the same id; no new account is created.
- [ ] `./scripts/api-test/test-banking.sh resync` returns HTTP 200; the target account has a non-zero `importedCount` for a date range known to contain transactions.
- [ ] `./scripts/api-test/test-banking.sh verify` prints before/after balances, counts, and exits 0 when everything matched. Prints a warning (not a failure) when `importedCount > 0` with a zero balance delta.
- [ ] All three auth paths (password, Telegram widget, pasted JWT) produce a usable cached token without further code changes.
- [ ] `scripts/api-test/README.md` lists `test-banking.sh` in the directory structure and has a "Test Banking" section referencing issue homeaccounting/backend#47.
- [ ] No Haskell source files were modified.
