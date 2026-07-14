---
status: in-progress
date: 2026-07-14
---

# Provider credential extensibility (`ProviderCredential`)

Follow-up to tracker#38 / PR #132. Removes the hardcoded single-static-secret assumption
from the banking credential model so a future OAuth2 provider can be added without
churning the event schema or the provider seam. **Shape-only**: no OAuth flow, no token
refresh, no OAuth provider, no web change — those are provider-specific and deferred.

## Problem

The credential is a bare `type PlainToken = Text` (`Domain.Banking.Types`): one opaque
static secret. It is injected purely into the provider seam
`pull :: Maybe (PlainToken -> PullCapability)` and used by Monobank as a static `X-Token`
header. OAuth2 needs *multiple* fields (access + refresh token + expiry) and periodic
effectful refresh — a single static `Text` injected purely cannot represent it. The
hardcoded `Text` sits in two otherwise-expensive-to-change places: the persisted secret
and the provider seam.

## Key insight (why the event schema is untouched)

The secret is encrypted in the **service layer** (`ConfigurationService.addBankConnection`,
`encryptSecret ring token`) *before* the command is built, and decrypted *after* reading
the projection (`getDecryptedConnectionToken`, `decryptSecret ring enc`). The
command/event/projection records only ever carry `EncryptedSecret` (nonce + ciphertext,
opaque) + `tokenHint :: Maybe Text`. The credential's plaintext structure never appears in
the event schema. So generalizing the credential = changing **what plaintext we encrypt**,
not any persisted record type.

## Design

### 1. `ProviderCredential` (Domain.Banking.Types)

Replace `type PlainToken = Text` with a tagged sum:

```haskell
data ProviderCredential
  = StaticSecret Text
  -- Future, additive (no event-schema change): a variant carrying OAuth2
  --   material, e.g. OAuth2 { accessToken, refreshToken, expiresAt, scopes }.
  deriving (Show, Eq, Generic)
```

- **Explicitly tagged JSON** chosen now (e.g. `{"kind":"static","secret":"…"}`), so adding
  a variant later is purely additive to the plaintext format and `StaticSecret`'s encoding
  stays stable. Export `ProviderCredential (..)` — providers pattern-match it (like
  `StatementFormat (..)`, `TransactionClassification (..)`).
- Remove `type PlainToken = Text` (only the banking layer used it).

### 2. Storage — event schema unchanged

- `addBankConnection` / `changeBankConnectionToken` take a `ProviderCredential` and encrypt
  `encode credential` via the unchanged `encryptSecret :: KeyRing -> Text -> IO
  EncryptedSecret` (we hand it the JSON text). `EncryptedSecret`, the commands
  (`AddBankConnection`, `ChangeBankConnectionToken`), the events, and the projection are
  all byte-identical in shape and JSON.
- Reads: `getDecryptedConnectionToken` → `getDecryptedConnectionCredential :: UserId ->
  BankConnectionId -> AppM (Either DomainError ProviderCredential)` — decrypt, then
  `eitherDecode`; a decode failure → `BankingError "…corrupt credential…"` (should not
  happen under no-backcompat, but handled totally, no partial functions).
- `tokenHint` derives from the credential (`StaticSecret` → masked tail); stays
  `Maybe Text`.
- No-backcompat: already-persisted raw-token plaintext will not decode as the new tagged
  JSON, so pre-existing connection secrets become unreadable. Acceptable per
  [[project_no_backcompat_phase]] (no upcasters); no migration. (No decode-fallback — the
  user chose strict shape-only.)

### 3. Seam (Infrastructure.Banking.Provider)

`pull :: Maybe (ProviderCredential -> PullCapability)`. Monobank:
`pull = Just $ \(StaticSecret t) -> PullCapability { … X-Token = t … }` — **exhaustive
today**; when an `OAuth2` variant is added the match becomes non-exhaustive and the
compiler flags every provider that must decide how to handle it. That compiler-enforced
fan-out is the extensibility guarantee.

### 4. Web — no change

`addConnectionHandler` wraps the existing `AddConnectionRequest.token :: Maybe Text` as
`StaticSecret <$> token`. The web (PR #58) still sends a token string for pull providers.
OAuth connection *creation* (an authorization-code redirect flow) is a separate future
concern, explicitly out of scope.

## Out of scope (deferred)

- Any `OAuth2` variant (would be dead code with no provider — a doc comment marks the slot).
- Token-refresh / effectful credential-acquire seam (provider-specific; risks a wrong
  contract with no concrete OAuth provider).
- Decode fallback for old raw-token rows.
- Web credential-input changes / OAuth connect flow.

## Testing

- `ProviderCredential` tagged-JSON round-trip; `encrypt(encode) → decrypt(decode)` identity.
- Monobank `pull` still authenticates using the `StaticSecret`.
- `getDecryptedConnectionCredential` returns the stored `StaticSecret`; a corrupt/
  undecodable decrypted plaintext → `DomainError` (not a crash).
- Existing banking tests updated for the `PlainToken → ProviderCredential` type change (a
  token literal becomes `StaticSecret "…"`).

## Lands as

A few commits on `feat/privatbank-file-import`, extending PR #132.
