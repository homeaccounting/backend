---
status: completed
date: 2026-04-09
---

# Backend Versioning

## Problem

The backend has no version visibility: no version in startup logs, no info endpoint, and no connection between the semver in `package.yaml` and the deployed Docker image. Operators cannot tell which version is running without checking the deployment pipeline manually.

## Goals

1. Log the app version, commit hash, and environment on startup
2. Expose an unauthenticated `GET /api/info` endpoint reporting version info
3. Tag Docker images with the semver from `package.yaml` in addition to existing SHA/branch tags

## Design

### Version Info Module

New module `Infrastructure/Version.hs`:

```haskell
data VersionInfo = VersionInfo
  { appVersion :: Text    -- from Paths_backend (package.yaml)
  , commit :: Text         -- from APP_COMMIT_HASH env var, default "dev"
  }
```

- `appVersion` is derived from the auto-generated `Paths_backend.version` (Cabal provides this from `package.yaml`'s `version: 0.2.0`)
- `commit` is read from the `APP_COMMIT_HASH` environment variable at startup; defaults to `"dev"` when unset (local development)
- `environment` is **not** part of `VersionInfo` — it belongs in `AppConfig` as a config concern. A new `Environment` type (`EnvLocal | EnvTest | EnvProd`) is added to `Infrastructure.Config` with a new `environment` field in `AppConfig`. Values: `local`, `test`, `prod`. Each config file declares its own. The existing `appEnvironment` helper in `Main.hs` is removed.

`VersionInfo` is constructed once in `Main.hs` and stored in `AppEnv` with a corresponding `HasVersionInfo` lens class following the existing `HasX` capability pattern.

### Startup Logging

In `Main.hs`, log after the existing banner:

```
Starting Accounting Backend v0.2.0 (abc123f) [Production]
```

Replaces the current generic `"Starting Accounting Backend..."` message.

### Info Endpoint

`GET /api/info` — unauthenticated, mounted outside the JWT-protected API tree.

Response `200 OK`:

```json
{
  "status": "ok",
  "version": "0.2.0",
  "commit": "abc123f",
  "environment": "production"
}
```

New files:
- `Web/API/InfoAPI.hs` — Servant type definition, `InfoResponse` DTO with `ToJSON`, and handler
- Composed in `Web/Server.hs` as a top-level `FullAPI = InfoAPI :<|> API` type, with `InfoAPI` served outside the auth context and `API` served inside it as before

### CI Changes

In `.github/workflows/ci.yml`, `build-image` job:

1. Extract version from `package.yaml` using `grep`
2. Add version as a Docker image tag: `ghcr.io/homeaccounting/backend:0.2.0`
3. Pass commit SHA as Docker build arg: `--build-arg APP_COMMIT_HASH=$SHA_SHORT`

Resulting image tags on master push:
- `{sha_short}` (existing)
- `{branch_slug}` (existing)
- `{version}` (new — e.g., `0.2.0`)
- `latest` (existing, master only)

### Dockerfile Changes

In `infra/docker/Dockerfile`:

```dockerfile
ARG APP_COMMIT_HASH=dev
ENV APP_COMMIT_HASH=${APP_COMMIT_HASH}
```

Added in the runtime stage so the env var is available to the running binary.

### Testing

- Unit test for `InfoAPI` handler verifying it returns 200 with expected JSON fields
- No property tests needed (no domain logic)

### What's NOT Included

- No database connectivity check (keep it simple; add a separate `/api/health` later if needed)
- No readiness/liveness split (single endpoint suffices for current Docker Compose deployment)
- No LiquidHaskell refinements (infrastructure-only, no domain types)
- No changes to production `docker-compose.yaml` image tag (can be updated manually when pinning to a version)
