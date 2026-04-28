{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Infrastructure.Auth.OAuth
-- Description : OAuth2 provider integration
--
-- This module provides OAuth2 authentication with multiple providers:
--   - Google
--   - GitHub
--   - Microsoft
--
-- Key Functions:
--   - getAuthorizationUrl: Generate URL to redirect user for authentication
--   - handleOAuthCallback: Exchange auth code for user info
--
-- OAuth2 Flow:
--   1. Client requests authorization URL via API
--   2. API generates URL with state parameter and redirects client
--   3. User authenticates with provider
--   4. Provider redirects to callback URL with auth code
--   5. API exchanges code for access token
--   6. API uses access token to fetch user info
--   7. API creates/links user account
--
-- Security:
--   - Uses 'state' parameter to prevent CSRF attacks
--   - Validates state on callback
--   - Access tokens are not stored (only used to fetch user info)
module Infrastructure.Auth.OAuth
  ( -- * Configuration
    OAuthConfig (..),
    OAuthProviderConfig (..),

    -- * OAuth Flow
    getAuthorizationUrl,
    handleOAuthCallback,

    -- * User Info
    OAuthUserInfo (..),
    parseUserInfo,

    -- * Default Configs
    defaultGoogleConfig,
    defaultGitHubConfig,
    defaultMicrosoftConfig,
    applyOAuthDefaults,

    -- * Errors
    OAuthError (..),

    -- * State Management
    generateOAuthState,
    validateOAuthState,
  )
where

import Control.Exception (SomeException, catch)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON (..), ToJSON (..), withObject, (.!=), (.:), (.:?))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as Aeson (lookup)
import Data.Bits (xor, (.|.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base64.URL as B64URL
import qualified Data.ByteString.Lazy as LBS
import qualified Data.List
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Domain.Core.Types (OAuthProvider (..))
import GHC.Generics (Generic)
import Network.HTTP.Client (Request (..), httpLbs, parseRequest, requestHeaders, responseBody, urlEncodedBody)
import Network.HTTP.Client.TLS (newTlsManager)
import qualified Network.HTTP.Types.URI as URI

-- -----------------------------------------------------------------------------
-- Configuration
-- -----------------------------------------------------------------------------

-- | Configuration for a single OAuth provider.
data OAuthProviderConfig = OAuthProviderConfig
  { -- | OAuth client ID
    clientId :: Text,
    -- | OAuth client secret
    clientSecret :: Text,
    -- | Redirect URI for OAuth callback
    redirectUri :: Text,
    -- | Authorization URL (provider-specific)
    authorizeUrl :: Text,
    -- | Token exchange URL (provider-specific)
    tokenUrl :: Text,
    -- | User info URL (provider-specific)
    userInfoUrl :: Text,
    -- | OAuth scopes to request
    scopes :: [Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON OAuthProviderConfig

instance FromJSON OAuthProviderConfig where
  parseJSON = withObject "OAuthProviderConfig" $ \v ->
    OAuthProviderConfig
      <$> v .: "client_id"
      <*> v .: "client_secret"
      <*> v .: "redirect_uri"
      <*> v .:? "authorize_url" .!= ""
      <*> v .:? "token_url" .!= ""
      <*> v .:? "user_info_url" .!= ""
      <*> v .:? "scopes" .!= []

-- | Configuration for all OAuth providers.
data OAuthConfig = OAuthConfig
  { google :: Maybe OAuthProviderConfig,
    gitHub :: Maybe OAuthProviderConfig,
    microsoft :: Maybe OAuthProviderConfig
  }
  deriving (Show, Eq, Generic)

instance ToJSON OAuthConfig

instance FromJSON OAuthConfig where
  parseJSON = withObject "OAuthConfig" $ \v ->
    OAuthConfig
      <$> v .:? "google"
      <*> v .:? "github"
      <*> v .:? "microsoft"

-- | Default OAuth configuration with well-known provider URLs.
--
-- Note: Client IDs and secrets must be provided!
defaultGoogleConfig :: Text -> Text -> Text -> OAuthProviderConfig
defaultGoogleConfig clientId' clientSecret' redirectUri' =
  OAuthProviderConfig
    { clientId = clientId',
      clientSecret = clientSecret',
      redirectUri = redirectUri',
      authorizeUrl = "https://accounts.google.com/o/oauth2/v2/auth",
      tokenUrl = "https://oauth2.googleapis.com/token",
      userInfoUrl = "https://www.googleapis.com/oauth2/v2/userinfo",
      scopes = ["openid", "email", "profile"]
    }

defaultGitHubConfig :: Text -> Text -> Text -> OAuthProviderConfig
defaultGitHubConfig clientId' clientSecret' redirectUri' =
  OAuthProviderConfig
    { clientId = clientId',
      clientSecret = clientSecret',
      redirectUri = redirectUri',
      authorizeUrl = "https://github.com/login/oauth/authorize",
      tokenUrl = "https://github.com/login/oauth/access_token",
      userInfoUrl = "https://api.github.com/user",
      scopes = ["read:user", "user:email"]
    }

defaultMicrosoftConfig :: Text -> Text -> Text -> OAuthProviderConfig
defaultMicrosoftConfig clientId' clientSecret' redirectUri' =
  OAuthProviderConfig
    { clientId = clientId',
      clientSecret = clientSecret',
      redirectUri = redirectUri',
      authorizeUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
      tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token",
      userInfoUrl = "https://graph.microsoft.com/v1.0/me",
      scopes = ["openid", "email", "profile"]
    }

-- | Fill in well-known provider URLs and scopes from the per-provider defaults
-- when the loaded config left them empty. YAML configs only need to carry
-- @client_id@, @client_secret@, and @redirect_uri@; the rest is supplied here.
-- Non-empty YAML values are preserved (in case a deployment needs to override).
applyOAuthDefaults :: OAuthConfig -> OAuthConfig
applyOAuthDefaults cfg =
  cfg
    { google = fmap (applyProviderDefaults Google) cfg.google,
      gitHub = fmap (applyProviderDefaults GitHub) cfg.gitHub,
      microsoft = fmap (applyProviderDefaults Microsoft) cfg.microsoft
    }
  where
    applyProviderDefaults :: OAuthProvider -> OAuthProviderConfig -> OAuthProviderConfig
    applyProviderDefaults provider c =
      let defaults = case provider of
            Google -> defaultGoogleConfig c.clientId c.clientSecret c.redirectUri
            GitHub -> defaultGitHubConfig c.clientId c.clientSecret c.redirectUri
            Microsoft -> defaultMicrosoftConfig c.clientId c.clientSecret c.redirectUri
       in c
            { authorizeUrl = if T.null c.authorizeUrl then defaults.authorizeUrl else c.authorizeUrl,
              tokenUrl = if T.null c.tokenUrl then defaults.tokenUrl else c.tokenUrl,
              userInfoUrl = if T.null c.userInfoUrl then defaults.userInfoUrl else c.userInfoUrl,
              scopes = if null c.scopes then defaults.scopes else c.scopes
            }

-- -----------------------------------------------------------------------------
-- User Info
-- -----------------------------------------------------------------------------

-- | User information returned by OAuth provider.
data OAuthUserInfo = OAuthUserInfo
  { -- | User's unique ID from the provider
    subject :: Text,
    -- | User's email (may be Nothing if not provided)
    email :: Maybe Text,
    -- | Whether the provider asserts the email has been verified.
    -- For Google this is the OIDC `email_verified` claim; for providers
    -- that don't expose verification, defaults to False (do not auto-link).
    emailVerified :: Bool,
    -- | User's display name
    name :: Maybe Text,
    -- | URL to user's profile picture
    picture :: Maybe Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON OAuthUserInfo

instance FromJSON OAuthUserInfo

-- -----------------------------------------------------------------------------
-- Errors
-- -----------------------------------------------------------------------------

-- | Errors that can occur during OAuth flow.
data OAuthError
  = -- | Provider is not configured
    ProviderNotConfigured OAuthProvider
  | -- | State parameter mismatch (potential CSRF)
    InvalidState
  | -- | Failed to exchange auth code for token
    TokenExchangeFailed Text
  | -- | Failed to fetch user info
    UserInfoFetchFailed Text
  | -- | Provider returned an error
    ProviderError Text Text -- error code, description
  | -- | Network error
    NetworkError Text
  deriving (Show, Eq, Generic)

instance ToJSON OAuthError

instance FromJSON OAuthError

-- -----------------------------------------------------------------------------
-- OAuth Flow
-- -----------------------------------------------------------------------------

-- | Generate an authorization URL for a provider.
--
-- The URL includes:
--   - client_id: Application identifier
--   - redirect_uri: Where to send user after authentication
--   - scope: Permissions requested
--   - state: Random string for CSRF protection
--   - response_type: 'code' for authorization code flow
--
-- Example:
-- >>> (url, state) <- getAuthorizationUrl config Google
-- >>> -- Store state in session, redirect user to url
getAuthorizationUrl ::
  (MonadIO m) =>
  OAuthConfig ->
  OAuthProvider ->
  m (Either OAuthError (Text, Text))
getAuthorizationUrl config provider = do
  case getProviderConfig config provider of
    Nothing -> return $ Left $ ProviderNotConfigured provider
    Just providerConfig -> do
      state <- generateOAuthState
      let params =
            [ ("client_id", encodeUtf8 providerConfig.clientId),
              ("redirect_uri", encodeUtf8 providerConfig.redirectUri),
              ("scope", encodeUtf8 $ T.intercalate " " providerConfig.scopes),
              ("state", encodeUtf8 state),
              ("response_type", "code")
            ]
          qs = decodeUtf8 $ URI.renderSimpleQuery True params
          url = providerConfig.authorizeUrl <> qs
      return $ Right (url, state)

-- | Handle OAuth callback and fetch user info.
--
-- This function:
--   1. Validates the state parameter
--   2. Exchanges the auth code for an access token
--   3. Uses the access token to fetch user info
--
-- Example:
-- >>> userInfo <- handleOAuthCallback config Google authCode expectedState actualState
-- >>> case userInfo of
-- >>>   Right info -> createOrLinkUser info
-- >>>   Left err -> handleError err
handleOAuthCallback ::
  (MonadIO m) =>
  OAuthConfig ->
  OAuthProvider ->
  Text -> -- Auth code
  Text -> -- Expected state (from session)
  Text -> -- Actual state (from callback)
  m (Either OAuthError OAuthUserInfo)
handleOAuthCallback config provider authCode expectedState actualState = do
  -- Validate state
  if not (validateOAuthState expectedState actualState)
    then return $ Left InvalidState
    else case getProviderConfig config provider of
      Nothing -> return $ Left $ ProviderNotConfigured provider
      Just providerConfig -> do
        -- Exchange code for token
        tokenResult <- exchangeCodeForToken providerConfig authCode
        case tokenResult of
          Left err -> return $ Left err
          Right accessToken -> do
            -- Fetch user info
            fetchUserInfo provider providerConfig accessToken

-- -----------------------------------------------------------------------------
-- Token Exchange
-- -----------------------------------------------------------------------------

-- | Exchange authorization code for access token.
exchangeCodeForToken ::
  (MonadIO m) =>
  OAuthProviderConfig ->
  Text ->
  m (Either OAuthError Text)
exchangeCodeForToken providerConfig authCode =
  liftIO $
    do
      manager <- newTlsManager
      let params =
            [ ("client_id", encodeUtf8 providerConfig.clientId),
              ("client_secret", encodeUtf8 providerConfig.clientSecret),
              ("code", encodeUtf8 authCode),
              ("redirect_uri", encodeUtf8 providerConfig.redirectUri),
              ("grant_type", "authorization_code")
            ]

      requestResult <- parseRequest $ T.unpack providerConfig.tokenUrl
      case requestResult of
        request -> do
          let postRequest = urlEncodedBody params request
          responseResult <- httpLbs postRequest manager
          let body = responseBody responseResult
          case Aeson.decode body of
            Just obj -> case extractAccessToken obj of
              Just token -> return $ Right token
              Nothing -> return $ Left $ TokenExchangeFailed "No access_token in response"
            Nothing -> return $ Left $ TokenExchangeFailed "Failed to parse token response"
      `catch` \e ->
        return $ Left $ NetworkError $ T.pack $ show (e :: SomeException)

-- | Extract access token from OAuth response.
extractAccessToken :: Aeson.Value -> Maybe Text
extractAccessToken (Aeson.Object obj) = do
  case Aeson.lookup "access_token" obj of
    Just (Aeson.String token) -> Just token
    _ -> Nothing
extractAccessToken _ = Nothing

-- -----------------------------------------------------------------------------
-- User Info Fetching
-- -----------------------------------------------------------------------------

-- | Fetch user info using access token.
fetchUserInfo ::
  (MonadIO m) =>
  OAuthProvider ->
  OAuthProviderConfig ->
  Text ->
  m (Either OAuthError OAuthUserInfo)
fetchUserInfo provider providerConfig accessToken =
  liftIO $
    do
      manager <- newTlsManager
      requestResult <- parseRequest $ T.unpack providerConfig.userInfoUrl
      case requestResult of
        request -> do
          let authRequest =
                request
                  { requestHeaders =
                      [ ("Authorization", "Bearer " <> encodeUtf8 accessToken),
                        ("Accept", "application/json")
                      ]
                  }
          responseResult <- httpLbs authRequest manager
          let body = responseBody responseResult
          case parseUserInfo provider body of
            Just userInfo -> return $ Right userInfo
            Nothing -> return $ Left $ UserInfoFetchFailed "Failed to parse user info"
      `catch` \e ->
        return $ Left $ NetworkError $ T.pack $ show (e :: SomeException)

-- | Parse user info response based on provider.
--
-- Each provider has a different response format.
parseUserInfo :: OAuthProvider -> LBS.ByteString -> Maybe OAuthUserInfo
parseUserInfo provider body =
  case provider of
    Google -> parseGoogleUserInfo body
    GitHub -> parseGitHubUserInfo body
    Microsoft -> parseMicrosoftUserInfo body

parseGoogleUserInfo :: LBS.ByteString -> Maybe OAuthUserInfo
parseGoogleUserInfo body = do
  obj <- Aeson.decode body
  case obj of
    Aeson.Object v -> do
      subjectValue <- Aeson.lookup "id" v
      subjectVal <- case subjectValue of
        Aeson.String s -> Just s
        _ -> Nothing
      let emailVal = case Aeson.lookup "email" v of
            Just (Aeson.String e) -> Just e
            _ -> Nothing
          emailVerifiedVal = case Aeson.lookup "email_verified" v of
            Just (Aeson.Bool b) -> b
            _ -> False
          nameVal = case Aeson.lookup "name" v of
            Just (Aeson.String n) -> Just n
            _ -> Nothing
          pictureVal = case Aeson.lookup "picture" v of
            Just (Aeson.String p) -> Just p
            _ -> Nothing
      return
        OAuthUserInfo
          { subject = subjectVal,
            email = emailVal,
            emailVerified = emailVerifiedVal,
            name = nameVal,
            picture = pictureVal
          }
    _ -> Nothing

parseGitHubUserInfo :: LBS.ByteString -> Maybe OAuthUserInfo
parseGitHubUserInfo body = do
  obj <- Aeson.decode body
  case obj of
    Aeson.Object v -> do
      subjectValue <- Aeson.lookup "id" v
      subjectVal <- case subjectValue of
        Aeson.Number n -> Just $ T.pack $ show (round n :: Integer)
        _ -> Nothing
      let emailVal = case Aeson.lookup "email" v of
            Just (Aeson.String e) -> Just e
            _ -> Nothing
          nameVal = case Aeson.lookup "name" v of
            Just (Aeson.String n) -> Just n
            _ -> case Aeson.lookup "login" v of
              Just (Aeson.String l) -> Just l
              _ -> Nothing
          pictureVal = case Aeson.lookup "avatar_url" v of
            Just (Aeson.String p) -> Just p
            _ -> Nothing
      return
        OAuthUserInfo
          { subject = subjectVal,
            email = emailVal,
            emailVerified = False,
            name = nameVal,
            picture = pictureVal
          }
    _ -> Nothing

parseMicrosoftUserInfo :: LBS.ByteString -> Maybe OAuthUserInfo
parseMicrosoftUserInfo body = do
  obj <- Aeson.decode body
  case obj of
    Aeson.Object v -> do
      subjectValue <- Aeson.lookup "id" v
      subjectVal <- case subjectValue of
        Aeson.String s -> Just s
        _ -> Nothing
      let emailVal = case Aeson.lookup "mail" v of
            Just (Aeson.String e) -> Just e
            _ -> case Aeson.lookup "userPrincipalName" v of
              Just (Aeson.String u) -> Just u
              _ -> Nothing
          nameVal = case Aeson.lookup "displayName" v of
            Just (Aeson.String n) -> Just n
            _ -> Nothing
      return
        OAuthUserInfo
          { subject = subjectVal,
            email = emailVal,
            emailVerified = False,
            name = nameVal,
            picture = Nothing -- Microsoft Graph doesn't return picture URL directly
          }
    _ -> Nothing

-- -----------------------------------------------------------------------------
-- State Management
-- -----------------------------------------------------------------------------

-- | Generate a random state parameter for CSRF protection.
generateOAuthState :: (MonadIO m) => m Text
generateOAuthState = liftIO $ do
  randomBytes <- getRandomBytes 32
  return $ decodeUtf8 $ B64URL.encode randomBytes

-- | Validate state parameter.
--
-- Uses constant-time comparison to prevent timing attacks.
validateOAuthState :: Text -> Text -> Bool
validateOAuthState expected actual =
  let expectedBytes = encodeUtf8 expected
      actualBytes = encodeUtf8 actual
   in BS.length expectedBytes == BS.length actualBytes
        && (0 == Data.List.foldl' xorByte 0 (BS.zipWith xorBytes expectedBytes actualBytes))
  where
    xorByte acc byte = acc .|. byte
    xorBytes x y = x `xor` y

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Get provider-specific configuration.
getProviderConfig :: OAuthConfig -> OAuthProvider -> Maybe OAuthProviderConfig
getProviderConfig config Google = config.google
getProviderConfig config GitHub = config.gitHub
getProviderConfig config Microsoft = config.microsoft
