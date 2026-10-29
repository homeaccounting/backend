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
   `POST /api/auth/oauth/:provider/id-token` with `{idToken, rawNonce}`, where
   `:provider` is `google` or `apple`; any other name is a 400
   `Unknown OAuth provider`. A valid token goes through the existing
   `linkOrSignInWithOAuth`, so find-or-create and auto-link by verified email behave
   as in the web callback, and the response is the usual `AuthResponse`.
   `Infrastructure.Auth.IdToken` verifies; `AuthService.signInWithIdToken`
   orchestrates.

2. **Verification rules.** The header is checked before jose sees the token:
   RS256 only, so `none` and `HS256` are rejected before key lookup. Only the key
   whose `kid` matches the header is used. The token must carry `iss`, `aud` and
   `exp`, a non-empty `sub`, and a `nonce` bound to this server (decision 4).
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
   is the token `aud`; the Android client ID only appears as `azp`) plus the iOS OAuth
   client ID (the iOS SDK signs in as that client, so it is the `aud`), and
   `APPLE_ID_TOKEN_AUDIENCES` to the iOS bundle ID. All are
   public identifiers, so a self-hosted server accepts the official app with no
   Google or Apple setup. Values are comma-separated, trimmed, with empty entries
   dropped. Setting a variable to an empty string disables that provider; an unset
   variable, or a config without the `id_token` block, takes the default. A disabled
   provider, and `github` or `microsoft`, return 400 `OAuth configuration error`.

4. **The nonce is bound to the server URL.** Every server accepts the official
   app's audiences, so a token minted for one server would otherwise work on all of
   them: a malicious self-hosted server the user signs in to could replay the
   (token, nonce) pair to the hosted server, or any other, and get a 60-day refresh
   token for that user. The client therefore picks a random `rawNonce` of at least
   16 characters, gives the provider
   `nonce = base64url_unpadded(SHA-256(UTF-8(serverUrl + "\n" + rawNonce)))`, where
   `serverUrl` is the canonical URL it is talking to (`scheme://host[:port][/path]`,
   scheme and host lower-cased, default port and trailing slash dropped), and sends
   `rawNonce` to us. The server recomputes the hash for each of its own accepted
   URLs (canonical `api_base_url` plus `oauth.id_token.server_urls`, resolved once
   at startup) and accepts the token only if the claim matches one. It never derives
   the URL from the request (`Host`, `X-Forwarded-*`), which the attacker controls.
   A shorter `rawNonce` is a 401. Nothing is stored. Server-issued nonces would not
   help against the cross-server case: a malicious server can fetch one from the
   real server and relay it to the user's app. What remains is same-server replay:
   a captured (token, rawNonce) pair works on its own server until the token expires,
   about an hour. Server-issued single-use nonces for that stay deferred.

5. **Keys are cached in memory per provider.** JWKS are fetched lazily from
   `https://www.googleapis.com/oauth2/v3/certs` and
   `https://appleid.apple.com/auth/keys` with the shared HTTP manager, and cached
   until `Cache-Control: max-age` expires (1 h if absent). An unknown `kid` forces a
   refetch, at most once per 60 s per provider, so key rotation is picked up without
   letting forged `kid`s hammer the provider. One fetch per provider runs at a time
   (concurrent callers wait for it or use a stale set), with a 5 s timeout, so a slow
   provider can't pile up requests. If a fetch fails, the cached set is
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
- **Replay within the token lifetime is possible on the same server.** An attacker
  who captures both the ID token and its raw nonce can sign in to that server until
  the token expires; the binding stops the pair working on any other server. TLS and
  `exp` are the only protection until server-issued nonces exist.
- **`API_BASE_URL` must match what users type.** A server reached by several URLs
  (LAN IP and hostname) lists the others in `ID_TOKEN_SERVER_URLS`; otherwise
  sign-in from those URLs fails with 401.
- **Docker needs a follow-up.** `homeaccounting/docker` must pass
  `GOOGLE_ID_TOKEN_AUDIENCES`, `APPLE_ID_TOKEN_AUDIENCES` and
  `ID_TOKEN_SERVER_URLS` through. Until then the defaults apply.
- **Google accounts are shared across web and mobile.** Google's `sub` is per
  account, not per client ID, so both flows reach the same user.
- **Apple names are not stored.** Apple sends the name only to the client, once, so
  only `sub` and `email` are mapped. A token without an email is rejected by the
  existing validation.
- **Out of scope.** Web Sign in with Apple, linking an ID-token identity to a
  signed-in account (`link-oauth` stays redirect-only) and listing web providers in
  `/api/auth/providers`.
