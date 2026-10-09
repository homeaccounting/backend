# 007 - Rotating refresh tokens live in Infrastructure tables

## Status
Accepted

## Context

The access JWT lives one hour (`jwt_expiry_seconds: 3600`), and `/api/auth/refresh`
only re-signed a JWT that was still valid. Nothing outlived the access token, so a
client away for more than an hour had to sign in again. The mobile app (tracker#84,
#88) has to stay signed in across days, so the backend needs a longer-lived
credential that can be rotated, detected when stolen, and revoked.

## Decision

1. **Token format and storage.** A refresh token is an opaque random value, not a
   JWT: 32 bytes from `Crypto.Random.getRandomBytes`, base64url-encoded without
   padding (43 characters). Only its SHA-256 hex hash is stored. The plaintext
   type has no `Show` instance and is never logged.

2. **Families and strict reuse revocation.** Each sign-in (one per device) starts a
   *family*; every rotation stays in it. Presenting a token that was already
   rotated or revoked revokes the whole family and returns 401 (OAuth 2.1 /
   RFC 9700 rotation). A token that has merely expired is rejected without
   revoking, so reuse detection for expired tokens is best-effort.

3. **Sliding 60-day expiry, prune on write.** Each rotation issues a token valid
   for `jwt_refresh_expiry_seconds` (default 5184000, 60 days) from now, with no
   absolute cap. Whenever a token is issued for a user, that user's expired token
   rows are deleted. There is no background job and no session cap.

4. **Public logout.** `POST /api/auth/logout` takes the refresh token, revokes its
   family and always returns 204, including for unknown tokens. It is public so a
   client can sign out with an expired access token.

5. **Lock order.** Rotation and revocation contend on the family row
   (`refresh_token_families`). Every path locks the family row before any token
   row: refresh calls `claimFamily` before `markRotated`, and `revokeFamily`
   updates the family row first. With the opposite orders (refresh token to
   family, revoke family to token) PostgreSQL deadlocks and the aborted revoke
   rolls the revocation back. Reject branches inside the transaction return
   `Left` instead of throwing, for the same reason: `runSqlPool` rolls back on
   exceptions. The JWT is signed after the transaction commits.

6. **Tables live in Infrastructure.** `Infrastructure.Auth.RefreshToken` holds the
   types and the pure decision, `Infrastructure.Auth.RefreshTokenStore` owns the
   tables `refresh_tokens` and `refresh_token_families`, and
   `Application.Services.AuthService` orchestrates. Infrastructure already owns
   the event-store tables via `Infrastructure.Database.runMigrations`, which now
   also calls `migrateRefreshTokens` (so no composition-root hook is needed).
   Application tables are read models: event projections with checkpoints and
   rebuilds. These tables project nothing, so they do not belong there. Nothing
   goes in `Domain`: sessions are auth mechanics, not accounting concepts.

7. **Not event-sourced.** A token rotates at least hourly per device. Logging each
   rotation would fill the store with session churn that has no history worth
   replaying.

8. **Documented exception to "no mutable state tables".** AGENTS.md's rule governs
   *domain* state. Refresh-token state is auth-session state that must survive
   restarts, so an in-memory store like `LinkCodeStore` is not an option. These
   two tables are the recorded exception. They are never rebuilt.

9. **Breaking `{token}` to `{refreshToken}`.** `RefreshTokenRequest` is replaced,
   not extended. No client calls refresh today (web's `authApi.refresh` is defined
   and mocked only), so nothing breaks. `AuthResponse` gains `refreshToken`.

10. **Telegram bot sign-ups mint no token.** `createUserViaTelegram` returns only
    the `UserId`, because the bot discards the `AuthResult`; minting would store
    60-day families that nobody receives.

## Consequences

- **Concurrent refreshes from one device sign it out.** The loser of a race
  presents an already-rotated token, which revokes the family. Clients must
  single-flight refresh.
- **Two 401 shapes.** The auth middleware's 401s are plain text
  (`Web/Middleware/Auth.hs`); 401s from `/refresh` are a JSON `ErrorResponse` with
  `code: UNAUTHENTICATED`. Clients must handle both.
- **Web mints families it discards.** Web sign-ins create families that web never
  uses; their tokens are pruned after expiry. Updating web's stale
  `RefreshTokenRequest` type (`{token}`) is a follow-up.
- **Family rows are never pruned.** Only expired token rows are deleted, so
  `refresh_token_families` grows by one row per sign-in. Pruning it is a known
  follow-up.
- **Request bodies are logged in text mode.** `logStdoutDev` logs request bodies
  and is installed only when `logging.format` is `text` (local and test).
  Production uses `json`, which disables it. Local and test logs therefore show
  passwords and refresh tokens, as they already showed passwords before this
  change.
- **Out of scope.** An absolute session lifetime, a per-user session cap and
  "sign out everywhere" are not implemented.
