---
status: draft
---

# Banking API Test Script — Design

## Goal

Provide a manual, repeatable way to smoke-test the Monobank resync feature
(merged in #39, amended 2026-04-16 to be resync-only) against a running
backend using a real Monobank personal token. The script lives alongside
the existing developer helpers in `scripts/api-test/` and follows the same
conventions.

## Non-goals

- Automated CI integration — this is a manual dev script, matching
  `test-accounts.sh`, `test-transactions.sh`, etc.
- Webhook testing — Phase 2, not merged.
- Any changes to production code (backend handlers, services,
  configuration, Telegram bot).
- New product endpoints. A gap on listing transactions by account is
  filed separately as issue #47 and is explicitly out of scope here.

## User model

The primary user is the bot-registered account (authenticated via
`/start` on the Telegram bot). The script must also work for
password-registered users and for users who already hold a JWT from
some other source. No new auth code is required:

- Bot-registered users: authenticate via `test-telegram.sh login
  <TELEGRAM_ID> <FirstName> <username>`. The widget endpoint
  `/api/auth/telegram` resolves the existing user by `TelegramId`
  (`Application.Services.AuthService.findOrCreateTelegramUser` at
  `src/Application/Services/AuthService.hs:382`) and returns a JWT
  matching the same user the bot created. No link step needed.
- Password users: `test-auth.sh` / `quick-test.sh login` as today.
- Pre-obtained token: `TEST_AUTH_TOKEN` env var is written directly
  to `/tmp/test_auth_token.txt`.

All three paths converge on the shared cache `/tmp/test_auth_token.txt`,
which the banking script reads via the existing `common.sh` helpers
(`get_saved_token`, `auth_header`). If no token is cached or the cached
one is expired, the script exits with instructions listing the three
entry points — it does not silently register a throwaway user.

## Script shape

One new executable: `scripts/api-test/test-banking.sh`, plus two JSON
payload templates under `scripts/api-test/payloads/banking/`. Style
matches `test-accounts.sh`: subcommand dispatch, `jq`-formatted output,
sourcing `common.sh`, respecting `--prod` / `--local` / `API_BASE_URL`.

### Subcommands

| Subcommand | Purpose                                                                                          |
| ---------- | ------------------------------------------------------------------------------------------------ |
| `setup`    | Find-or-create the BankAccount-typed local account for the supplied IBAN; print its id           |
| `resync`   | POST `/api/banking/resync` for the resolved account; pretty-print the per-account response       |
| `verify`   | Re-fetch the account and print balance + resync-response counts to confirm the import took hold  |
| `all`      | `setup` → `resync` → `verify`                                                                    |

### Inputs (env vars + flags)

| Name               | Required for            | Default              | Notes                                                           |
| ------------------ | ----------------------- | -------------------- | --------------------------------------------------------------- |
| `MONOBANK_TOKEN`   | `resync`, `all`         | —                    | Personal token from `api.monobank.ua`. Sent as `X-Banking-Token` |
| `MONOBANK_IBAN`    | `setup`, `all`          | —                    | Must exactly match the IBAN Monobank returns for the account    |
| `ACCOUNT_ID`       | optional                | —                    | Skip setup and reuse an existing local account id               |
| `FROM`             | `resync`, `all`         | now - 7 days (ISO-8601) | Inclusive start of import range                                 |
| `TO`               | `resync`, `all`         | now (ISO-8601)       | Inclusive end; backend enforces a 31-day max range at `src/Web/API/BankingAPI.hs:216-220` |
| `CATEGORY_ID`      | optional                | first expense-category entry | `defaultCategory` UUID sent in the request body          |
| `CURRENCY`         | `setup`                 | `UAH`                | Currency of the created BankAccount                              |
| `BANK_NAME`        | `setup`                 | `Monobank`           | Stored in `BankAccount.bankName`                                 |
| `ACCOUNT_NAME`     | `setup`                 | `Mono <CURRENCY>`    | Display name of the created account                              |
| `TEST_AUTH_TOKEN`  | optional                | —                    | Seeds `/tmp/test_auth_token.txt` before running                  |

IBAN is supplied explicitly — the script does **not** call Monobank's
`/personal/client-info` to discover it. This keeps the script decoupled
from Monobank's public surface and makes the inputs predictable.

### Find-or-create (`setup`)

Goal: idempotent. Running `setup` twice should not create two accounts.

1. If `ACCOUNT_ID` is set, short-circuit and cache it.
2. Otherwise, `GET /api/accounts`, then on the client side keep only
   entries whose `subtype.type == "bankAccount"` and whose
   `accountNumber == $MONOBANK_IBAN`. Pick the first match.
3. Otherwise, `POST /api/accounts` with:

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

4. Cache the resolved account id at `/tmp/test_banking_account_id.txt`
   so subsequent subcommands can reuse it without a list call.

The subtype payload round-trips fully on `GET /api/accounts`
(`Web.Types.fromAccountData` at `src/Web/Types.hs:663` routes
`BankAccountProperties.accountNumber` through `fromAccountSubtype`),
so client-side filtering on `subtype.accountNumber` works without
any backend change. This
assumption is verified at script-run time: if the field is absent, the
script logs a clear error telling the user to pass `ACCOUNT_ID`
explicitly rather than silently mis-behaving.

### Resync

1. Resolve `CATEGORY_ID`: if unset, `GET /api/users/me/configuration`
   and pick the first entry in the `expense-category` dictionary
   via the existing `first_category_id` helper in `common.sh`.
2. Fill `payloads/banking/resync.template.json` via `envsubst` with
   `FROM`, `TO`, `CATEGORY_ID`.
3. `POST /api/banking/resync`:
   - `Authorization: Bearer <jwt>`
   - `X-Banking-Token: $MONOBANK_TOKEN`
   - body as above
4. Pretty-print the response JSON. Surface HTTP status codes:
   - 200 → print response (callers inspect per-account `failureCount`)
   - 400 → print validation error body
   - 404 → hint that `banking.enabled` / `monobank.enabled` may be off
   - 401 → hint to re-authenticate (token expired)

### Verify

Since there is no list-transactions-by-account endpoint today
(homeaccounting/backend#47 tracks adding one), verification is
limited to:

1. Snapshot the account balance **before** `resync` is called (from
   `setup` or by explicit `GET /api/accounts/:id`), write it to
   `/tmp/test_banking_balance_before.txt`.
2. After `resync`, `GET /api/accounts/:id` and print:
   - balance before → balance after (delta)
   - per-account `importedCount` / `skippedCount` / `failureCount`
     from the resync response (cached in
     `/tmp/test_banking_last_resync.json`)
3. Exit non-zero if `failureCount > 0` for the target account.
   If `importedCount > 0` but the balance delta is 0, emit a warning
   rather than failing — a zero net delta can legitimately occur when
   the imported batch includes offsetting transactions (e.g. a
   same-day payment and reversal). The warning flags the case for
   manual inspection without blocking the script on a false positive.

This verify story is deliberately thin. Once issue #47 lands, a
follow-up can replace the balance-diff heuristic with an explicit
transaction enumeration.

## Payload templates

`scripts/api-test/payloads/banking/create-account.template.json`:

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

`scripts/api-test/payloads/banking/resync.template.json`:

```json
{
  "from": "${FROM}",
  "to": "${TO}",
  "defaultCategory": "${CATEGORY_ID}"
}
```

Rendered via `envsubst` at script-run time; the rendered files are
**not** committed.

## Documentation

Append a "Banking" section to `scripts/api-test/README.md` and add
`test-banking.sh` to the "Directory Structure" listing at the top of
that file. The new section covers:

- The three auth entry points (password, Telegram widget login for an
  existing bot-registered user, pasted JWT via `TEST_AUTH_TOKEN`).
- How to obtain a Monobank personal token (`api.monobank.ua`) and its
  caveats: 60-second rate limit between `/personal/statement` calls;
  revocable from the user's Monobank profile.
- The IBAN-match requirement (local BankAccount `accountNumber` must
  match the Monobank-reported IBAN verbatim).
- The 31-day max window on the resync range.
- A pointer to homeaccounting/backend#47 for the verify-by-listing
  follow-up.

## Risks & mitigations

- **Leaking the Monobank token into shell history or logs.** The
  script accepts `MONOBANK_TOKEN` via env var only (never an argument),
  never echoes it, and passes it through `curl -H` so it does not
  appear in the command line of child processes. The same convention
  is already used for `TELEGRAM_BOT_TOKEN`.
- **Monobank rate limit (1 request / 60 s for `/personal/statement`).**
  The script makes at most one `/resync` call per run and documents
  the cooldown. Users running `all` repeatedly will hit it; the script
  surfaces any 429 from the backend with a clear message.
- **IBAN mismatch silently creating orphan local accounts.** Running
  `setup` with a wrong IBAN will create a BankAccount that never
  matches the Monobank one, leading to a 400 "No bank accounts could
  be matched" from `/resync`. Mitigation: README documents this; the
  find-or-create step always logs the IBAN it is using.
- **Balance-delta heuristic is coarse.** See verify-step limitations
  above; deliberately accepted trade-off pending #47.

## Acceptance criteria

- `./scripts/api-test/test-banking.sh setup` on a fresh DB creates
  exactly one `BankAccount` with the supplied IBAN and prints its id.
- Running `setup` again is a no-op and returns the same id.
- `./scripts/api-test/test-banking.sh resync` with a valid token and
  IBAN returns a 200 response whose per-account entry has non-zero
  `importedCount` for at least the non-empty date range used.
- `./scripts/api-test/test-banking.sh verify` prints before/after
  balances and non-zero imported counts, and exits 0 when everything
  matched.
- All three auth entry points (password, Telegram widget, pasted JWT)
  unlock the flow without further code changes.
- `scripts/api-test/README.md` explains setup, env vars, and caveats;
  references issue #47.

## Future work

- homeaccounting/backend#47: list transactions by account with date
  filters. Once merged, `verify` switches from balance-delta +
  counts to explicit per-transaction assertions.
- Telegram bot UX for bank-account creation and transaction browsing
  (options 2 and 3 in the original brainstorm). Not blocked by this
  spec; can be taken up independently.
