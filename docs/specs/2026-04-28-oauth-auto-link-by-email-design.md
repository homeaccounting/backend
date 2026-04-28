---
status: draft
date: 2026-04-28
---

# OAuth auto-link by verified email

## Problem

When a user registers with email + password and later signs in via
Google (or any OAuth provider), `Application.Services.AuthService.handleOAuthCallback`
silently creates a **second** user account for the same human:

- It looks up an existing user by `(provider, subject)` only.
- If that lookup misses, it falls through to `createUserViaOAuth`,
  unconditionally minting a new user record.
- The pre-existing email/password user with the same email address is
  ignored, even though Google verifies the email.

The result is two distinct `UserId`s for one person, with separate
account ownership and transaction history. The user has no way to merge
them after the fact: `linkOAuth` (`POST /api/auth/link-oauth`) refuses to
attach the OAuth identity because it is already attached to the
duplicate user.

## Goals

1. A user who registered with email + password and later signs in via
   Google whose verified email matches an existing user is recognised as
   the **same** user — the OAuth identity is attached to the existing
   user and a JWT is issued for that user.
2. No silent duplicate creation in the case described in (1).
3. Behaviour for genuinely new OAuth users (no pre-existing account with
   the same email) is unchanged: a new user is created.
4. Behaviour for repeated sign-ins of an already-linked OAuth identity
   is unchanged: the existing identity lookup hits, JWT is issued.
5. The change is safe across providers that may not verify emails:
   auto-link only triggers when the provider's response confirms email
   verification.

## Non-Goals

- Merging two pre-existing user records (the data-migration question).
  Out of scope; this spec only prevents new duplicates.
- Auto-linking by **unverified** email. Explicitly refused — that is a
  hijack vector.
- Exposing or changing the `link-oauth` endpoint behaviour.
- Frontend changes — covered by the web MVP spec at
  `web/docs/superpowers/specs/2026-04-28-web-mvp-design.md` (§5.4).

## Design

### 1. Decision tree in `handleOAuthCallback`

Today (simplified):

```haskell
handleOAuthCallback provider code state = ...
  userInfo <- exchangeCodeForUserInfo
  maybeUser <- getUserByOAuthIdentity provider userInfo.subject
  case maybeUser of
    Just (uid, user) -> generateAuthResult uid user.email   -- existing OAuth user
    Nothing -> case userInfo.email of
      Just email -> createUserViaOAuth email oauthIdentity   -- always creates new
      Nothing    -> ValidationErr "OAuth provider did not return email address"
```

Proposed:

```haskell
handleOAuthCallback provider code state = ...
  userInfo <- exchangeCodeForUserInfo
  maybeUser <- getUserByOAuthIdentity provider userInfo.subject
  case maybeUser of
    Just (uid, user) -> generateAuthResult uid user.email   -- unchanged
    Nothing -> case (userInfo.email, userInfo.emailVerified) of
      (Nothing, _) ->
        ValidationErr "OAuth provider did not return email address"
      (Just email, False) ->
        -- email present but not verified: do NOT auto-link. Create new.
        createUserViaOAuth email oauthIdentity
      (Just email, True) -> do
        -- email verified: try to attach to existing user with this email.
        maybeByEmail <- getUserByEmail email
        case maybeByEmail of
          Just (uid, user) -> do
            -- attach identity, then issue JWT for the existing user.
            runUserCmd id (unUserId uid)
              (LinkOAuthAccountUserCommand (LinkOAuthAccount oauthIdentity))
            generateAuthResult uid user.email
          Nothing -> createUserViaOAuth email oauthIdentity
```

### 2. The `email_verified` signal

The OAuth provider abstraction must surface `emailVerified :: Bool`
from the userinfo response. For Google this is the `email_verified`
claim on the ID token / userinfo endpoint — already present, just not
plumbed up. The infrastructure-level `OAuth.handleOAuthCallback` (in
`Infrastructure/Auth/...`) returns a userinfo record; that record gains
an `emailVerified` field, and the Google provider implementation reads
it from the response.

For providers that do not communicate verification (none today, but
for safety), default to `False` — auto-link must not trigger on
implicit trust.

### 3. Read-model lookup by email

`getUserByEmail` already exists on the user read model (used by
`register` to refuse duplicate registrations). Reuse it as-is.

### 4. Event ordering and idempotency

The auto-link path issues a `LinkOAuthAccountUserCommand` against the
existing user aggregate before generating the JWT. The aggregate's
existing invariants apply:

- Refuses to link an `OAuthIdentity` already present on the user
  (idempotency).
- The aggregate's existing duplicate-prevention check is at the
  application level via `getUserByOAuthIdentity`; since we already
  verified that lookup missed, the link command will succeed for
  any user.

If the link command fails for any reason, the failure is surfaced as
`AuthService` `Left` and the JWT is **not** issued — the user gets a
clear error instead of a phantom session.

### 5. Race condition

Two concurrent OAuth callbacks for the same email could both pass the
"no user with this `(provider, subject)`" check and both reach
`createUserViaOAuth` (current code) or one reaches `LinkOAuth` while the
other reaches `createUserViaOAuth` (new code). This race already exists
today. We do not address it in this spec — the simplest mitigation is
the existing unique-index on `users.email` at the persistence layer,
which converts the loser into a domain error at write time, which the
caller sees as a normal failure.

### 6. Behaviour matrix

| Existing user with `(provider, subject)` | Existing user with this email | `email_verified` | Outcome                                      |
|---|---|---|---|
| yes                                        | (n/a)                         | (n/a)            | sign in as that user (unchanged)             |
| no                                         | no                            | true or false    | create new user (unchanged)                  |
| no                                         | yes                           | true             | **attach identity to existing user, sign in**|
| no                                         | yes                           | false            | create new user (auto-link refused)          |
| no                                         | (no email returned)           | (n/a)            | `ValidationErr` (unchanged)                  |

## Tests

1. **Happy path (the bug we're fixing).** Register email/password; sign
   in via Google with the same verified email; assert resulting `userId`
   matches the original; assert the user now has the OAuth identity
   attached.
2. **Unverified email refuses auto-link.** Same setup but
   `email_verified = false` on the OAuth userinfo; assert a new user is
   created (existing behaviour preserved).
3. **No pre-existing user.** Sign in via Google with a fresh email;
   assert a new user is created (existing behaviour preserved).
4. **Repeated OAuth sign-in.** Sign in via Google twice; assert the
   second sign-in resolves via `(provider, subject)` and does not call
   `getUserByEmail` (no extra link command emitted).
5. **OAuth provider returns no email.** Assert `ValidationErr`
   (existing behaviour preserved).

## Risks and tradeoffs

- **Hijack via unverified email.** Mitigated by the `email_verified`
  gate. If a provider in the future returns no verification signal, the
  conservative default (`False`) preserves the create-new behaviour
  rather than silently auto-linking.
- **Behavioural change for in-flight users.** Users who previously hit
  the duplicate path and now have two accounts will not be merged by
  this change — only future first-time-OAuth-after-password sign-ins
  benefit. Backfill / merge is explicitly out of scope.

## Out of scope (will not be implemented in this spec)

- Telegram auto-link by phone or other identifier — symmetrical
  question, deferred.
- A user-facing "merge accounts" flow.
- Backfill of existing duplicate users.
- Rate limiting / abuse controls on OAuth callback. Existing controls
  apply unchanged.
