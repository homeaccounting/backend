# 008 - Native ID-token sign-in for Google and Apple

## Status
Accepted

## Context

The web OAuth flow redirects to the web frontend and exchanges the code with our
client secret. The mobile app (tracker#84, #86) can't use it: the redirect lands on
the web frontend, not in the app, and every redirect URI and the client secret
would have to belong to our Google console, so a self-hosted server could not serve
the official app. App Store guideline 4.8 also requires Sign in with Apple because
we offer Google.

The native SDKs sign the user in on the device and hand the app an ID token: a JWT
signed by Google or Apple that names the subject, the email and the app it was
issued for. The backend can verify it with the provider's public keys, with no
redirect, code or client secret.

## Decision

1. **ID tokens over the redirect flow.** Native apps send the provider's ID token to
   `POST /api/auth/oauth/:provider/id-token` with `{idToken, nonce}`, where
   `:provider` is `google` or `apple`. A valid token goes through the existing
   `linkOrSignInWithOAuth`, so find-or-create and auto-link by verified email behave
   as in the web callback, and the response is the usual `AuthResponse`.
   `Infrastructure.Auth.IdToken` verifies; `AuthService.signInWithIdToken`
   orchestrates.

2. **Verification rules.** The header is checked before jose sees the token:
   RS256 only, so `none` and `HS256` are rejected before key lookup. Only the key
   whose `kid` matches the header is used. The token must carry `iss`, `aud` and
   `exp`, a non-empty `sub`, and a `nonce` equal to the request nonce byte for byte.
   `iss` is `accounts.google.com` or `https://accounts.google.com` for Google and
   `https://appleid.apple.com` for Apple; `aud` must be a configured audience;
   `exp` allows 60 s of clock skew; `iat` is not checked. Any failure is a 401
   `UNAUTHENTICATED` with one generic message; the reason is logged, the token and
   nonce never are. JWS and JWK handling use `jose` 0.12. `jose` 0.13 needs
   crypton >= 1.1 and `ram`, which would move `tls`, so it is not used. Hand-written
   RS256 was rejected: it would put algorithm confusion, `kid` and JWK parsing in
   our code, on a login path.

3. **Audiences default to the official app.** `GOOGLE_ID_TOKEN_AUDIENCES` defaults
   to the official web OAuth client ID (Android passes it as `serverClientId`, so it
   is the token `aud`) and `APPLE_ID_TOKEN_AUDIENCES` to the iOS bundle ID. Both are
   public identifiers, so a self-hosted server accepts the official app with no
   Google or Apple setup. Values are comma-separated, trimmed, with empty entries
   dropped. Setting a variable to an empty string disables that provider; an unset
   variable, or a config without the `id_token` block, takes the default. A disabled
   provider, and `github` or `microsoft`, return 400 `OAuth configuration error`.

4. **The nonce is client-generated and not stored.** The client passes it to the
   provider SDK and sends the same value to us (the hashed value, if the client
   hashes it for Apple). This proves the token was requested for this sign-in by the
   client. It does not prevent replay of a captured (token, nonce) pair within the
   token's lifetime of about an hour. Server-issued single-use nonces are deferred.

5. **Keys are cached in memory per provider.** JWKS are fetched lazily from
   `https://www.googleapis.com/oauth2/v3/certs` and
   `https://appleid.apple.com/auth/keys` with the shared HTTP manager, and cached
   until `Cache-Control: max-age` expires (1 h if absent). An unknown `kid` forces a
   refetch, at most once per 60 s per provider, so key rotation is picked up without
   letting forged `kid`s hammer the provider. If a fetch fails, the cached set is
   used; with none cached, the response is 503 `Sign-in provider unavailable`.
   The cache is `Infrastructure.Auth.JwksCache`; the verifier takes the key source
   as a parameter, so tests never touch the network.

6. **`GET /api/auth/providers` for client buttons.** It is public and returns
   `{password, google, apple}`. `password` is always true; `google` and `apple` are
   true when that provider's audience list is non-empty. It reports native
   providers only: GitHub, Microsoft and the Google redirect flow are not listed,
   because nothing consumes them.

7. **`Apple` is an `OAuthProvider` without a redirect flow.** It is stored as its
   JSON token, so no migration is needed. `OAuthConfig` has no Apple field, and
   `initiateOAuth`, `handleOAuthCallback` and `linkOAuth` treat Apple as not
   configured.

## Consequences

- **Self-hosted servers gain native sign-in by default.** Operators who don't want
  it set the variables to empty.
- **Replay within the token lifetime is possible.** An attacker who captures both
  the ID token and its nonce can sign in until the token expires. TLS and `exp` are
  the only protection until server-issued nonces exist.
- **Docker needs a follow-up.** `homeaccounting/docker` must pass
  `GOOGLE_ID_TOKEN_AUDIENCES` and `APPLE_ID_TOKEN_AUDIENCES` through. Until then
  the defaults apply.
- **Google accounts are shared across web and mobile.** Google's `sub` is per
  account, not per client ID, so both flows reach the same user.
- **Apple names are not stored.** Apple sends the name only to the client, once, so
  only `sub` and `email` are mapped. A token without an email is rejected by the
  existing validation.
- **Out of scope.** Web Sign in with Apple, linking an ID-token identity to a
  signed-in account (`link-oauth` stays redirect-only) and listing web providers in
  `/api/auth/providers`.
