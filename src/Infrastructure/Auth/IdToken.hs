{-# LANGUAGE LambdaCase #-}
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
-- See docs/decisions/008-native-id-token-sign-in.md.
module Infrastructure.Auth.IdToken
  ( IdTokenRejection (..),
    idTokenIssuers,
    tokenKeyId,
    jwkSetHasKeyId,
    verifyIdToken,
  )
where

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
import qualified Data.ByteString.Base64.URL as B64URL
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.OAuth (IdTokenConfig, OAuthUserInfo (..), idTokenAudiences)
import RIO
import qualified RIO.ByteString.Lazy as BL
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

-- | Verify a compact ID token against the provider's keys at time @now@, and
-- check its nonce against the one the app sent with the request.
verifyIdToken ::
  IdTokenConfig -> OAuthProvider -> JWKSet -> UTCTime -> Text -> Text -> Either IdTokenRejection OAuthUserInfo
verifyIdToken cfg provider (JWKSet ks) now token nonce = do
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
  unless (not (T.null nonce) && textClaim "nonce" raw == Just nonce) (Left NonceMismatch)
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
