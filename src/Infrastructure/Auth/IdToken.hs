{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Auth.IdToken
-- Description : Verify Google/Apple ID tokens for native sign-in
--
-- Native apps sign in with the provider's SDK and send us its ID token: an RS256
-- JWT signed with a key from the provider's published JWK set. We verify the
-- signature, issuer, audience (the official app's IDs), expiry and nonce, then
-- map the claims to 'OAuthUserInfo' for the shared find-or-create logic.
--
-- Every server accepts the same audiences, so the nonce is bound to the server
-- URL ('bindNonce'): a token minted for one server fails on any other.
-- See docs/decisions/008-native-id-token-sign-in.md.
module Infrastructure.Auth.IdToken
  ( IdTokenRejection (..),
    idTokenIssuers,
    tokenKeyId,
    jwkSetHasKeyId,
    verifyIdToken,
    bindNonce,
    canonicalServerUrl,
    acceptedServerUrls,
  )
where

import Crypto.Hash (Digest, SHA256, hash)
import Crypto.JWT
  ( Alg (RS256),
    ClaimsSet,
    Error (..),
    HasAllowedSkew (..),
    HasCheckIssuedAt (..),
    HasClaimsSet (..),
    HasIssuerPredicate (..),
    HasValidationSettings (..),
    JWK,
    JWKSet (..),
    JWTError (..),
    SignedJWT,
    StringOrURI,
    decodeCompact,
    defaultJWTValidationSettings,
    jwkKid,
    stringOrUri,
    verifyJWTAt,
  )
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteArray as BA
import qualified Data.ByteString.Base64.URL as B64URL
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (IdTokenConfig (..), OAuthUserInfo (..), idTokenAudiences)
import RIO
import qualified RIO.ByteString.Lazy as BL
import RIO.Char (isAlphaNum, isAscii, isDigit, isHexDigit, isSpace)
import qualified RIO.List as L
import qualified RIO.Set as Set
import qualified RIO.Text as T
import RIO.Time (UTCTime)

-- | Why a token was refused. Never carries token text, so it is safe to log.
data IdTokenRejection
  = UnsupportedAlgorithm
  | MalformedToken Text
  | UnknownKeyId
  | BadSignature
  | WrongIssuer
  | WrongAudience
  | Expired
  | NonceMismatch
  | NonceTooShort
  | MissingSubject
  deriving (Show, Eq)

idTokenIssuers :: OAuthProvider -> [Text]
idTokenIssuers Google = ["accounts.google.com", "https://accounts.google.com"]
idTokenIssuers Apple = ["https://appleid.apple.com"]
idTokenIssuers GitHub = []
idTokenIssuers Microsoft = []

-- | jose's registered claims plus the raw verified payload, from which we read
-- the OIDC claims (nonce, email, email_verified) jose doesn't model.
data IdTokenClaims = IdTokenClaims ClaimsSet Aeson.Object

instance HasClaimsSet IdTokenClaims where
  claimsSet f (IdTokenClaims c o) = (`IdTokenClaims` o) <$> f c

instance Aeson.FromJSON IdTokenClaims where
  parseJSON = Aeson.withObject "IdTokenClaims" $ \o ->
    (`IdTokenClaims` o) <$> Aeson.parseJSON (Aeson.Object o)

-- | Header-only inspection, done by hand so that a non-RS256 token (including
-- @alg: none@) is refused before jose sees it. Returns the kid so the caller
-- can refetch keys when it is unknown.
tokenKeyId :: Text -> Either IdTokenRejection (Maybe Text)
tokenKeyId t = case T.split (== '.') t of
  [h, _, _] -> do
    hdr <- headerObject h
    case KM.lookup "alg" hdr of
      Just (Aeson.String "RS256") -> case KM.lookup "kid" hdr of
        Nothing -> Right Nothing
        Just (Aeson.String k) -> Right (Just k)
        Just _ -> Left (MalformedToken "kid is not a string")
      _ -> Left UnsupportedAlgorithm
  _ -> Left (MalformedToken "not a compact JWS")
  where
    malformed = MalformedToken "header is not base64url JSON"
    headerObject h =
      first (const malformed) (B64URL.decodeUnpadded (encodeUtf8 h))
        >>= maybe (Left malformed) Right
        . Aeson.decodeStrict

hasKeyId :: Text -> JWK -> Bool
hasKeyId k j = j ^. jwkKid == Just k

jwkSetHasKeyId :: JWKSet -> Text -> Bool
jwkSetHasKeyId (JWKSet ks) k = any (hasKeyId k) ks

-- | Verify a compact ID token against the provider's keys at time @now@. Its
-- nonce claim must be the app's @rawNonce@ bound to one of @serverUrls@ (this
-- server's canonical URLs, never taken from the request).
verifyIdToken ::
  IdTokenConfig -> OAuthProvider -> JWKSet -> UTCTime -> [Text] -> Text -> Text -> Either IdTokenRejection OAuthUserInfo
verifyIdToken cfg provider (JWKSet ks) now serverUrls token rawNonce = do
  when (T.length rawNonce < minRawNonceLength) (Left NonceTooShort)
  keyId <- tokenKeyId token >>= maybe (Left UnknownKeyId) Right
  -- Only the key the header names may verify the signature.
  let candidates = filter (hasKeyId keyId) ks
  when (null candidates) (Left UnknownKeyId)
  IdTokenClaims claims raw <- first rejection $ do
    jwt <- decodeCompact (BL.fromStrict (encodeUtf8 token))
    verifyJWTAt settings (JWKSet candidates) now (jwt :: SignedJWT)
  -- jose only checks iss, aud and exp when present; an ID token must carry them.
  when (isNothing (claims ^. claimIss)) (Left WrongIssuer)
  when (isNothing (claims ^. claimAud)) (Left WrongAudience)
  when (isNothing (claims ^. claimExp)) (Left Expired)
  subj <- maybe (Left MissingSubject) Right (mfilter (not . T.null) (textClaim "sub" raw))
  let expected = map (`bindNonce` rawNonce) serverUrls
  unless (maybe False (`elem` expected) (textClaim "nonce" raw)) (Left NonceMismatch)
  pure
    OAuthUserInfo
      { subject = subj,
        email = textClaim "email" raw,
        -- Apple sends email_verified as the string "true"/"false".
        emailVerified = case KM.lookup "email_verified" raw of
          Just (Aeson.Bool b) -> b
          Just (Aeson.String s) -> T.toLower s == "true"
          _ -> False,
        name = Nothing,
        picture = Nothing
      }
  where
    settings =
      defaultJWTValidationSettings (matchesAny (idTokenAudiences cfg provider))
        & issuerPredicate
        .~ matchesAny (idTokenIssuers provider)
          & allowedSkew
        .~ 60
          & checkIssuedAt
        .~ False
          & validationSettingsAlgorithms
        .~ Set.singleton RS256

minRawNonceLength :: Int
minRawNonceLength = 16

-- | The nonce the app gives the provider for a server:
-- @base64url_unpadded(SHA-256(UTF-8(serverUrl <> "\\n" <> rawNonce)))@.
-- @serverUrl@ must be canonical ('canonicalServerUrl'); the mobile app computes
-- the same value (spec known-answer vectors in IdTokenSpec).
bindNonce :: Text -> Text -> Text
bindNonce serverUrl rawNonce =
  decodeUtf8Lenient (B64URL.encodeUnpadded (BA.convert digest))
  where
    digest = hash (encodeUtf8 (serverUrl <> "\n" <> rawNonce)) :: Digest SHA256

-- | @scheme://host[:port][/path]@: scheme and host lower-cased, the default
-- port dropped, trailing slashes stripped. Matches the mobile app's
-- @parseServerUrl@, so both sides bind the nonce to the same string. Only
-- http(s); userinfo, query and fragment are refused rather than dropped.
canonicalServerUrl :: Text -> Either Text Text
canonicalServerUrl input = do
  (scheme, rest) <- case T.break (== ':') raw of
    (sch, r) | Just after <- T.stripPrefix "://" r -> Right (T.toLower sch, after)
    _ -> invalid "missing scheme"
  defaultPort <- case scheme of
    "http" -> Right 80
    "https" -> Right 443
    _ -> invalid "scheme must be http or https"
  when (T.any isSpace raw) (invalid "contains whitespace")
  when (T.any (`elem` ['?', '#']) rest) (invalid "has a query or fragment")
  let (authority, path) = T.break (== '/') rest
  when (T.any (== '@') authority) (invalid "has userinfo")
  (host, mPort) <- splitHostPort authority
  unless (validHost host) (invalid "bad host")
  port <- traverse parsePort mPort
  let portPart = case port of
        Just p | p /= defaultPort -> ":" <> tshow p
        _ -> ""
  pure (scheme <> "://" <> T.toLower host <> portPart <> T.dropWhileEnd (== '/') path)
  where
    raw = T.strip input
    invalid :: Text -> Either Text a
    invalid why = Left ("invalid server URL " <> tshow raw <> ": " <> why)
    splitHostPort a
      | "[" `T.isPrefixOf` a = case T.break (== ']') a of
          (h, r) | Just after <- T.stripPrefix "]" r -> (,) (h <> "]") <$> portSuffix after
          _ -> invalid "unterminated IPv6 address"
      | otherwise = case T.split (== ':') a of
          [h] -> Right (h, Nothing)
          [h, p] -> Right (h, Just p)
          _ -> invalid "bad authority"
    portSuffix r
      | T.null r = Right Nothing
      | Just p <- T.stripPrefix ":" r = Right (Just p)
      | otherwise = invalid "bad authority"
    validHost h = case T.stripPrefix "[" h >>= T.stripSuffix "]" of
      Just v6 -> not (T.null v6) && T.all (\c -> isHexDigit c || c == ':' || c == '.') v6
      Nothing -> not (T.null h) && T.all (\c -> isAscii c && (isAlphaNum c || c == '-' || c == '.')) h
    parsePort p = case readMaybe (T.unpack p) :: Maybe Int of
      Just n | T.all isDigit p, n >= 1, n <= 65535 -> Right n
      _ -> invalid "bad port"

-- | The canonical URLs a nonce may be bound to on this server: @api_base_url@
-- plus the configured extras. 'Left' names the first invalid one.
acceptedServerUrls :: Text -> IdTokenConfig -> Either Text [Text]
acceptedServerUrls apiBaseUrl cfg = L.nub <$> traverse canonicalServerUrl (apiBaseUrl : cfg.serverUrls)

matchesAny :: [Text] -> StringOrURI -> Bool
matchesAny xs v = any (\x -> x ^? stringOrUri == Just v) xs

textClaim :: Aeson.Key -> Aeson.Object -> Maybe Text
textClaim k o = case KM.lookup k o of
  Just (Aeson.String s) -> Just s
  _ -> Nothing

rejection :: JWTError -> IdTokenRejection
rejection = \case
  JWTExpired -> Expired
  JWTNotInIssuer -> WrongIssuer
  JWTNotInAudience -> WrongAudience
  JWSError e -> case e of
    JWSInvalidSignature -> BadSignature
    JWSNoValidSignatures -> BadSignature
    JWSNoSignatures -> UnsupportedAlgorithm
    AlgorithmNotImplemented -> UnsupportedAlgorithm
    AlgorithmMismatch _ -> UnsupportedAlgorithm
    NoUsableKeys -> UnknownKeyId
    other -> MalformedToken (constructorName other)
  other -> MalformedToken (constructorName other)
  where
    -- Only the constructor: some error payloads quote decoded token content.
    constructorName :: (Show a) => a -> Text
    constructorName = T.takeWhile (/= ' ') . tshow
