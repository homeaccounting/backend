# Plan: Unify Configuration & Environment Variables

**Date**: 2026-02-09  
**Status**: Executed  

## Goal

Centralise all application configuration so that:

1. `.env` is the **single source of truth** for environment variables.
2. `.envrc` loads the Nix flake and sources `.env` via `dotenv` — nothing else.
3. `config/test.yaml` and `config/prod.yaml` consume environment variables through `${VAR:-default}` substitution.
4. `config/local.yaml` uses plain hardcoded values (no substitution) for fully offline development.
5. Haskell code **never** reads environment variables directly — everything comes from the parsed `AppConfig`.

## Changes

### Configuration Files

| File | Change |
|------|--------|
| `.envrc` | Replaced hardcoded `POSTGRES_*` exports with `use flake` + `dotenv .env` |
| `.env` | Rewritten with `DB_*` prefix, `JWT_SECRET`, and commented-out OAuth/Telegram vars |
| `config/test.yaml` | Database values now use `${DB_*:-default}` substitution; added `auth`, `oauth`, `telegram` sections |
| `config/prod.yaml` | Rewritten with `${VAR}` (required, no defaults); added `auth`, `oauth`, `telegram` sections matching `test.yaml` structure |
| `config/local.yaml` | Added `auth`, `oauth`, `telegram` sections with hardcoded local-appropriate values |

### Haskell Source

| File | Change |
|------|--------|
| `src/Infrastructure/Config.hs` | Added `appAuth`, `appOAuth`, `appTelegram` fields to `AppConfig`; re-exported `JWTConfig`, `OAuthConfig`, `TelegramConfig`; enhanced `substituteEnvVars` with `${VAR:-default}` support and `coerceValue` (auto-converts substituted strings to Number/Bool/Null) |
| `src/Infrastructure/Auth/JWT.hs` | Changed `jwtSecret :: ByteString` → `Text`, `jwtExpirySeconds :: NominalDiffTime` → `Int`; added custom `FromJSON` (snake_case keys); updated `generateToken`/`verifyToken` to `encodeUtf8`/`secondsToNominalDiffTime` at call sites |
| `src/Infrastructure/Auth/OAuth.hs` | Added custom `FromJSON` for `OAuthConfig` and `OAuthProviderConfig` (snake_case keys, optional defaults) |
| `src/Infrastructure/Auth/Telegram.hs` | Added custom `FromJSON` for `TelegramConfig` (snake_case keys, `NominalDiffTime` from `Int`) |
| `src/Application/Services/AuthService.hs` | Removed `round` calls on `jwtExpirySeconds` (now `Int`) |
| `app/Main.hs` | Switched from `loadConfig` → `loadConfigWithEnv`; replaced hardcoded auth config initialisation with `appAuth config` / `appOAuth config` / `appTelegram config` |
| `src/Infrastructure/Database.hs` | Removed `loadDatabaseConfig`, `databaseConfigFromEnv`, `getEnvText`, `getEnvInt` (dead code) |
| `test/TestSupport/InMemoryEventStore.hs` | Updated test `AppConfig` construction to include `appAuth`, `appOAuth`, `appTelegram` fields |

### CI

| File | Change |
|------|--------|
| `.github/workflows/ci.yml` | Removed unused `POSTGRES_*` env vars from the "Run test suites" step |

## Verification

- `cabal build all` — **passed**
- `cabal test all` — **226 examples, 0 failures**
