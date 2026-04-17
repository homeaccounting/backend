---
status: completed
issue: https://github.com/homeaccounting/backend/issues/42
---

# API_BASE_URL as single source of URL truth

## Context

`API_BASE_URL` is declared in `config/local.yaml` and `config/prod.yaml` under
`server.api_base_url`, but no production consumer exists for it. In parallel,
several other environment variables describe URLs that point back at our own
service and are therefore derivable from `API_BASE_URL`:

- `TELEGRAM_WEBHOOK_URL` (e.g. `https://homeaccounting.com/api/telegram/webhook`)
- `GOOGLE_REDIRECT_URI`, `GITHUB_REDIRECT_URI`, `MICROSOFT_REDIRECT_URI`
  (e.g. `https://homeaccounting.com/api/auth/oauth/<provider>/callback`)

These redundant variables exist today in `infra/.env`,
`infra/docker/docker-compose.yaml`, and both YAML config files. Keeping them
independent creates drift risk: a production move to a new domain requires
updating five environment variables instead of one.

This spec refactors the configuration so that `API_BASE_URL` is the single
source of truth for every URL that targets our own API. Derived URLs live in
the YAML configs as concatenations of `${API_BASE_URL}` and the static path
the service exposes.

## Goals

- `API_BASE_URL` is the only URL-shaped environment variable that operators
  need to supply for the API's own endpoints.
- `telegram.webhook_url`, `oauth.google.redirect_uri`,
  `oauth.github.redirect_uri`, and `oauth.microsoft.redirect_uri` in
  `config/prod.yaml` and `config/local.yaml` are derived via string
  concatenation from `${API_BASE_URL}`.
- `TELEGRAM_WEBHOOK_URL`, `GOOGLE_REDIRECT_URI`, `GITHUB_REDIRECT_URI`,
  `MICROSOFT_REDIRECT_URI` are removed from `infra/.env` and the
  `docker-compose.yaml` `api` service env block.
- Existing behaviour of the env-var substituter (whole-string substitution,
  `${VAR:-default}`, numeric/boolean coercion for whole-string results) is
  preserved.

## Non-goals

- Wiring `server.apiBaseUrl` into any downstream Haskell consumer. The field
  already exists in `Infrastructure.Config.ServerConfig` and will be reused
  later; this refactor does not add new consumers.
- Introducing a new derivation mechanism that lives in Haskell. Derivation
  happens in YAML so the final, resolved URL remains visible in config.
- Changing Telegram's polling-vs-webhook mode in local development; local
  config continues to use polling with `webhook_url: null`.

## Design

### 1. Extend env-var substitution to support in-string concatenation

**File:** `src/Infrastructure/Config.hs`, function `substituteEnvVars.go` for
the `String` case.

Today `substituteText` only handles strings that are entirely wrapped in
`${...}`. Replace it with a scan that walks the text and resolves every
`${...}` occurrence in place, returning the concatenated result.

Semantics preserved:

- `${VAR}` — required; if unset, return `Left "Environment variable not set:
  VAR"`.
- `${VAR:-default}` — if `VAR` is unset, substitute the literal `default`
  (may be empty).
- `${VAR:-}` — if `VAR` is unset, substitute an empty string.

New semantics:

- Any number of `${...}` occurrences per string are resolved and the results
  concatenated with the surrounding literal text.
- `coerceValue` continues to run on the final resulting text. A string that
  resolves to a pure number/bool/null (because it was a whole-string
  substitution) still coerces as it does today; a string that contained any
  literal characters around the substitution remains a `String` value.

The scanner handles these cases:

| Input                                   | `X=`       | Result                  |
| --------------------------------------- | ---------- | ----------------------- |
| `${X}`                                  | `7`        | `Number 7`              |
| `${X}`                                  | `true`     | `Bool True`             |
| `port-${X}`                             | `7`        | `String "port-7"`       |
| `${X}/api/telegram/webhook`             | `https://h`| `String "https://h/...` |
| `${A}-${B}`                             | `A=1 B=2`  | `String "1-2"`          |
| `${MISSING:-fallback}/path`             | (unset)    | `String "fallback/path"`|
| `plain text no vars`                    |  —         | `String "plain text…"`  |
| `${REQUIRED}/x` (unset, no default)     |  —         | `Left "Environment ...` |

### 2. YAML config updates

**`config/prod.yaml`:**

```yaml
oauth:
  google:
    redirect_uri: "${API_BASE_URL}/api/auth/oauth/google/callback"
  github:
    redirect_uri: "${API_BASE_URL}/api/auth/oauth/github/callback"
  microsoft:
    redirect_uri: "${API_BASE_URL}/api/auth/oauth/microsoft/callback"

telegram:
  webhook_url: "${API_BASE_URL}/api/telegram/webhook"
```

**`config/local.yaml`:**

```yaml
oauth:
  google:
    redirect_uri: "${API_BASE_URL:-http://localhost:8080}/api/auth/oauth/google/callback"
  github:
    redirect_uri: "${API_BASE_URL:-http://localhost:8080}/api/auth/oauth/github/callback"
  microsoft:
    redirect_uri: "${API_BASE_URL:-http://localhost:8080}/api/auth/oauth/microsoft/callback"

telegram:
  webhook_url: null # Use polling in development
```

This makes `API_BASE_URL` override reach OAuth redirects locally too
(e.g. for ngrok-backed OAuth callbacks during development).

### 3. `.env` and docker-compose cleanup

**`infra/.env`:**

- Add: `API_BASE_URL=https://homeaccounting.com`
- Remove: `TELEGRAM_WEBHOOK_URL`
- The three `*_REDIRECT_URI` entries are already empty; nothing to remove
  there (they are only present in `docker-compose.yaml`).

**`infra/docker/docker-compose.yaml`** (`api` service environment block):

- Add: `- API_BASE_URL=${API_BASE_URL}`
- Remove:
  - `- TELEGRAM_WEBHOOK_URL=${TELEGRAM_WEBHOOK_URL:-}`
  - `- GOOGLE_REDIRECT_URI=${GOOGLE_REDIRECT_URI:-}`
  - `- GITHUB_REDIRECT_URI=${GITHUB_REDIRECT_URI:-}`
  - `- MICROSOFT_REDIRECT_URI=${MICROSOFT_REDIRECT_URI:-}`

### 4. Testing

Add Hspec unit tests for `substituteEnvVars` in the existing Config test
module (or a new `ConfigSpec.hs` if one does not exist) covering:

- Whole-string substitution still works for Text, Number, Bool, Null,
  and empty-string/`null` special cases (regression coverage for
  `coerceValue`).
- In-string substitution: `${X}/path` with `X=https://host` yields
  `String "https://host/path"`.
- Multiple substitutions: `${A}-${B}`.
- In-string with default: `${MISSING:-fallback}/path` yields
  `String "fallback/path"` when `MISSING` is unset.
- Required-but-missing variable inside a larger string returns
  `Left` with the variable name.
- Literal text around substitutions preserved verbatim.

## Risks

- **Substitution scanner correctness.** An incorrect scan (e.g. greedy match
  over multiple `${...}` blocks, or mishandling of `:-` inside a larger
  string) could break existing configs. Mitigation: preserve the existing
  `${VAR}` and `${VAR:-default}` behaviour via tests before changing logic,
  then add new in-string cases.
- **Operator confusion.** Operators used to setting `TELEGRAM_WEBHOOK_URL`
  directly must now set `API_BASE_URL`. Mitigation: docker-compose no longer
  accepts the old variables, so forgetting to migrate fails loudly at config
  load rather than silently running with an empty webhook URL.

## Branch and commit plan

- Branch: `refactor/use-api-base-url-for-derived-urls` (off `master`).
- Commits:
  1. `refactor(config): support in-string env var substitution` — extend
     substituter, add tests.
  2. `refactor(config): derive service URLs from API_BASE_URL` — YAML,
     `.env`, and docker-compose updates.
