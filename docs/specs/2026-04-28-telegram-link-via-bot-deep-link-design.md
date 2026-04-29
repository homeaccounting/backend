---
status: draft
date: 2026-04-28
---

# Telegram link via bot deep-link

## Problem

When a user already has an account (e.g. email/password, optionally with
a linked Google identity per the auto-link spec dated 2026-04-28) and
later interacts with the Telegram bot for the first time,
`Telegram.Commands.handleStart` calls
`Application.Services.AuthService.findOrCreateTelegramBotUser`, which
creates a **second** user record:

- Lookup is keyed on Telegram ID alone via `getUserByTelegramId`.
- A miss falls through to `createUserViaTelegram`, unconditionally
  minting a new `UserId` and a new External account.
- The Telegram payload carries no email, so the OAuth-style auto-link
  by verified email (`linkOrSignInWithOAuth`) cannot be reused — there
  is no shared identifier to key on.

The pre-existing user is therefore invisible to the bot. The Telegram
side starts a fresh transaction history and accounts that cannot be
shared with the original identity. The only existing remediation,
`POST /api/auth/link-telegram` (`linkTelegram`), assumes the user is
already authenticated in the web app and submits a verified
`TelegramAuthData` payload from the Telegram **login widget** — which
does not help users whose first contact is the bot itself.

The widget surface itself (`POST /api/auth/telegram` →
`authenticateTelegram`) has the same default-create behaviour as the
bot and the same duplicate-account trap. It is also unused by the
product and not desired going forward — sign-in via the web app
happens through email/password or OAuth.

A naive remedy — accepting `/start <email>` in the bot — is a
hijack vector: email is an identifier, not an authenticator, and the
bot has no way to verify ownership.

## Goals

1. A user with an existing account can attach their Telegram identity
   from inside the bot without typing or revealing any identifier.
2. The bot's `/start` no longer creates duplicate users by accident:
   an unknown Telegram ID that arrives with no link payload is told how
   to link or sign up explicitly.
3. Behaviour for an already-linked Telegram ID is unchanged.
4. Genuinely new users can still create a Telegram-only account, but
   only via an explicit `/signup` command — not as a side effect of
   `/start`.
5. The link credential is unguessable, single-use, and short-lived; the
   server enforces these properties atomically.
6. The web-side Telegram authentication surfaces are removed:
   `POST /auth/telegram` (sign-in via the login widget) and
   `POST /auth/link-telegram` (link via the login widget) both go
   away. After this spec, the bot is the only entry point that
   produces or attaches a Telegram identity.

## Non-Goals

- Merging duplicate users that already exist from prior `/start`
  interactions. Out of scope; this spec only prevents new duplicates.
- Persisting link codes across server restarts. They are short-lived
  (~10 minutes); a restart loss is a regenerate-and-retry, not a data
  loss. (See §Design / Storage for the rationale.)
- Frontend implementation — the web app gains a "Link Telegram" button
  that calls the new endpoint and renders the returned deep-link, and
  removes any UI that posted to the dropped `POST /auth/telegram` and
  `POST /auth/link-telegram` endpoints; visual design is a separate
  frontend spec.
- Rate-limiting the issue endpoint. The token's randomness defeats
  brute-force; spam-issuance is bounded by `O(active users)` because
  each issue replaces the prior code.

## Design

### 1. Decision tree in `Telegram.Commands.handleStart`

Today (simplified):

```haskell
handleStart update =
  let payload = parseStartPayload update
      tgIdent = telegramIdentityFromUpdate update
   in findOrCreateTelegramBotUser tgIdent >>= sendWelcome
```

Proposed:

```haskell
handleStart update =
  let payload = parseStartPayload update
      tgIdent = telegramIdentityFromUpdate update
  in case payload of
       Just t | "LINK_" `T.isPrefixOf` t ->
         redeemTelegramLinkCode (stripLinkPrefix t) tgIdent >>= replyLinkResult
       _ -> do
         existing <- getUserByTelegramId tgIdent.id
         case existing of
           Just _  -> sendWelcome existing       -- unchanged
           Nothing -> sendUnknownUserPrompt      -- new: no implicit create
```

A new command `handleSignup` wraps the previous default branch
(`findOrCreateTelegramBotUser` + welcome) and is invoked only when the
user explicitly sends `/signup`.

### 2. New endpoint `POST /auth/telegram/link-code`

Authenticated. Defined in `Web.API.AuthAPI`. Body: empty.
Returns:

```json
{
  "deepLink":  "https://t.me/<botUsername>?start=LINK_<token>",
  "expiresAt": "2026-04-28T12:34:56Z"
}
```

`<botUsername>` comes from a new `botUsername :: Text` field on the
existing `TelegramConfig` consumed by
`Infrastructure.Auth.Telegram`. It is required configuration; missing
config is a startup-time error consistent with other Telegram fields.

### 3. New service functions in `Application.Services.AuthService`

```haskell
data TelegramLinkCodeResult = TelegramLinkCodeResult
  { deepLink  :: Text
  , expiresAt :: UTCTime
  }

issueTelegramLinkCode  :: UserId -> AppM (Either DomainError TelegramLinkCodeResult)
redeemTelegramLinkCode :: LinkCodeToken -> TelegramIdentity -> AppM (Either DomainError UserId)
```

`issueTelegramLinkCode`:
1. Generate a 32-byte random value via `getEntropy`, base64url-encode
   to ~43 chars (the `LinkCodeToken`).
2. `LinkCodeStore.issue userId ttl` — inserts `(token, userId, now+ttl)`,
   replacing any prior code for the same user. TTL: 10 minutes.
3. Format the deep-link from the configured bot username and return.

`redeemTelegramLinkCode`:
1. `LinkCodeStore.redeem token` — single STM transaction: lookup,
   check expiry, delete, return `Maybe UserId`.
2. `Nothing` ⇒ `NotFound "telegram-link-code" "<token-redacted>"`.
   Bot maps to "link no longer valid" reply.
3. `Just userId` ⇒ guard `getUserByTelegramId tgIdent.id` is `Nothing`
   (the same invariant `linkTelegram` already enforces). On collision
   return `AccountError "Telegram account already linked to another user"`.
4. Run `LinkTelegramAccountUserCommand` on `userId`'s aggregate, reusing
   the existing `LinkTelegramAccount` command and its
   `TelegramAccountLinked` event. No new event types.
5. Return the resolved `userId`.

### 4. Storage: `Application.LinkCodeStore`

In-memory only. `TVar (HashMap LinkCodeToken (UserId, UTCTime))`,
mirroring the existing read-model wiring pattern in
`Application.ReadModels.User`.

API:

```haskell
newtype LinkCodeToken = LinkCodeToken { unToken :: Text }
  deriving (Eq, Show)

instance Hashable LinkCodeToken

data LinkCodeStore  -- opaque

newLinkCodeStore :: IO LinkCodeStore
issue            :: LinkCodeStore -> UserId -> NominalDiffTime -> IO (LinkCodeToken, UTCTime)
redeem           :: LinkCodeStore -> LinkCodeToken -> IO (Maybe UserId)
purgeExpired     :: LinkCodeStore -> IO ()
```

- `issue` calls `purgeExpired` opportunistically before insertion, then
  performs an atomic STM transaction that drops any existing entry for
  the same `UserId` and inserts the new one.
- `redeem` is a single STM transaction: lookup → expiry check → delete →
  return. No race window between check and consume.

The store is added to `AppEnv` and exposed through a
`HasLinkCodeStore env` capability class, alongside `HasReadModel`,
`HasEventStore`, etc.

**Why in-memory and not event-sourced or in Postgres.**
- Codes are transient artefacts of an authentication flow, not facts
  about the domain. Recording `TelegramLinkCodeIssued` /
  `…Redeemed` would bloat the User aggregate's stream with
  authentication minutiae.
- The 10-minute TTL bounds the cost of a restart; users regenerate.
- A new Postgres table would establish a parallel persistence story
  outside the event store, which contradicts the
  "event store is the source of truth" invariant in `CLAUDE.md`.

### 5. Bot-side replies

Wording is illustrative; final copy lives in
`Telegram.Formatting`.

- Unknown Telegram ID, no payload (or non-`LINK_` payload):
  > "I don't recognise this Telegram account. To use it with your
  > existing account, open the web app and tap **Link Telegram**.
  > To create a brand-new account, send `/signup`."

- Valid `/start LINK_<token>` and link succeeded:
  > "Done — this Telegram is now linked to your account. Send /help to
  > get started."

- `/start LINK_<token>` where `redeem` returns `Nothing`
  (unknown / consumed / expired):
  > "That link is no longer valid. Generate a new one in the web app
  > under **Link Telegram**." — followed by the unknown-user prompt
  > so the user has a clear next action.

- `/start LINK_<token>` where the Telegram ID is already linked to a
  different user:
  > "This Telegram account is already linked to a different user.
  > Sign in there or contact support."
  >
  > The token is still consumed (atomic redeem already deleted it),
  > which is fine — it cannot be reused anyway. Logged at `logWarn`.

- `/signup` from an unknown Telegram ID: existing
  `findOrCreateTelegramBotUser` + welcome flow.

- `/signup` from an already-linked Telegram ID: the existing welcome
  flow for the linked user. Idempotent, no error.

### 6. Error handling summary

| Situation | Surface | Behaviour |
|---|---|---|
| Token unknown / consumed / expired | Bot | "link no longer valid" + unknown-user prompt. No state change. |
| Token valid, Telegram ID already linked elsewhere | Bot | "linked to a different user" reply. Token consumed. `logWarn`. |
| Token valid, target user has a *different* Telegram already linked | Bot | Existing `LinkTelegramAccount` aggregate guard rejects. Reply: "Your account is already linked to a different Telegram. Unlink it first in the web app." |
| `/auth/telegram/link-code` unauthenticated | API | 401 via existing JWT middleware. |
| `/start LINK_garbage` | Bot | Same as "token unknown" — do not leak prefix-match information. |

Logging: `logInfo` for redeem success; `logWarn` for cross-user
collision; `logError` only for unexpected aggregate failures. Tokens
are never logged, even truncated.

### 7. Removal of web-side Telegram authentication

After this spec the only Telegram entry point is the bot. The
following surfaces are deleted:

| File | Removal |
|---|---|
| `Web.API.AuthAPI` | The `POST /api/auth/telegram` route, the `POST /api/auth/link-telegram` route, their handlers, the `TelegramAuthRequest` DTO, and the `toTelegramAuthData` helper. |
| `Application.Services.AuthService` | `authenticateTelegram` and `linkTelegram` (the existing widget-driven function — its responsibility moves to `redeemTelegramLinkCode`). |
| `Infrastructure.Auth.Telegram` | `authenticateViaTelegram`, `TelegramAuthData`, `computeTelegramHash`, and any error variants used solely by the widget HMAC verification. The module remains for any future bot-side helpers but loses the widget-only API. |
| Tests | All test cases targeting the removed routes / functions are deleted; remaining Telegram tests focus on the bot path. |

What stays:
- `findOrCreateTelegramBotUser` — now reachable only from the
  `/signup` bot command.
- `Application.Services.UserService.unlinkTelegram` and the
  `POST /api/users/me/telegram` (DELETE) route — orthogonal concern;
  users still need to be able to detach a linked Telegram.
- The `botToken` portion of `telegramConfig` — used by the bot itself,
  unchanged. The HMAC widget secret usage of the same field
  disappears with `authenticateViaTelegram`.

The deletion is a backwards-incompatible API change. Per the project
convention of strict additive change otherwise, this is called out
explicitly: any frontend or external client posting to
`POST /api/auth/telegram` or `POST /api/auth/link-telegram` will start
receiving 404 from the deploy of this spec onward. There is no
deprecation period; the endpoints are unused by the maintained
frontend and the duplicate-account trap is the reason the spec exists.

## Testing

Following the project's three-tier convention.

**Unit — `Application/LinkCodeStoreSpec.hs`**
- `issue` produces a token of expected length, returns the stored
  `expiresAt`, and replaces any prior code for the same user.
- `redeem` returns `Just userId` on first call, `Nothing` on second
  (single-use).
- `redeem` returns `Nothing` for an expired token (clock injected via
  parameter or `IORef`).
- Concurrent `redeem` calls on the same token: exactly one returns
  `Just`. `Control.Concurrent.Async.concurrently_` with N redeemers,
  assert success count is 1.

**Property — `Application/LinkCodeStorePropertySpec.hs`**
- For any sequence of issues for distinct users, the store has one
  entry per user and all tokens are pairwise distinct.
- For any token issued, redeem-then-redeem is observationally
  equivalent to redeem-then-noop.

**Service — `Application/Services/AuthServiceSpec.hs` (extending the
existing white-box block)**
- `issueTelegramLinkCode` returns a deep-link of the form
  `https://t.me/<bot>?start=LINK_<token>` matching the configured bot
  username and a token retrievable from the in-memory store.
- `redeemTelegramLinkCode` happy path: issued token + unused Telegram
  ID + existing user → emits `TelegramAccountLinked`, returns the
  right `userId`.
- `redeemTelegramLinkCode` rejects when Telegram ID is already linked
  to a different user.
- `redeemTelegramLinkCode` rejects when token is unknown / consumed /
  expired — returns the expected `DomainError`, no aggregate command
  issued.

**Integration — `Web/API/AuthAPIIntegrationSpec.hs` (extending it)**
- `POST /auth/telegram/link-code` without JWT → 401.
- Authenticated issue → bot redeem → `getUserByTelegramId` resolves to
  the original user; `getUserByEmail` for that user is unchanged.
- Authenticated issue → wait past TTL → bot redeem fails cleanly.
- Removed `POST /auth/telegram` and `POST /auth/link-telegram` routes
  return 404 (regression guard against an accidental re-introduction).
  Existing tests exercising those endpoints are deleted in the same
  patch as the route removal.

**Bot-command tests — `Telegram/CommandsSpec.hs` (extending it)**
- `/start` with no payload from an unknown Telegram ID → reply
  contains the linking instructions and the `/signup` mention;
  `findOrCreateTelegramBotUser` is not called (assert via spy).
- `/start LINK_<valid-token>` → calls `redeemTelegramLinkCode`, reply
  confirms link.
- `/start LINK_<bad>` → does not create a user, reply matches the
  unknown-token wording.
- `/signup` from an unknown Telegram ID → calls
  `findOrCreateTelegramBotUser`, replies with welcome.
- `/start` with no payload from an already-linked Telegram ID →
  existing welcome (regression guard).

## Open questions

None. Bot copy will be finalised in `Telegram.Formatting` during
implementation; rate-limiting and login-widget hardening are
explicitly deferred (see §Non-Goals).
