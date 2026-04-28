{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.AuthService
-- Description : Authentication use case orchestration
--
-- This module implements the application-level orchestration for authentication
-- operations including registration, login, OAuth, Telegram auth, and token
-- refresh.
--
-- Responsibilities:
--   - User creation (via event store)
--   - External account creation (auto-created on registration)
--   - Password hashing and verification
--   - JWT token generation and refresh
--   - OAuth flow orchestration
--   - Telegram authentication verification
--   - Identity linking (OAuth, Telegram)
--
-- Note: This module handles authentication (identity verification).
-- Authorization (permission checks) is handled by 'AuthorizationService'.
--
-- Usage:
--   Services are called by thin API handlers in @Web.API.AuthAPI@.
module Application.Services.AuthService
  ( -- * Result Types
    AuthResult (..),
    OAuthRedirectResult (..),

    -- * Service Functions
    register,
    login,
    initiateOAuth,
    handleOAuthCallback,
    linkOrSignInWithOAuth,
    linkOAuth,
    linkOAuthIdentityToUser,
    authenticateTelegram,
    linkTelegram,
    refreshToken,
    findOrCreateTelegramBotUser,

    -- * Helpers re-exported for AuthAPI types
    parseOAuthProvider,
  )
where

import Application.ReadModels.Configuration (ConfigurationData (..), getConfiguration)
import Application.ReadModels.User
  ( UserData (..),
    emailExists,
    getUserByEmail,
    getUserByOAuthIdentity,
    getUserByTelegramId,
  )
import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybeM,
    runAccountCmd,
    runUserCmd,
  )
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountType (..),
    Currency (..),
    OAuthIdentity (..),
    OAuthProvider (..),
    TelegramIdentity (..),
    UserId,
    defaultConfigurationId,
    mkAccountId,
    mkUserId,
    unUserId,
    unsafeMoney,
  )
import Domain.User.CommandHandler (UserCommand (..))
import Domain.User.Commands
  ( AssignConfiguration (..),
    LinkOAuthAccount (..),
    LinkTelegramAccount (..),
    RegisterUser (..),
    RegisterViaTelegram (..),
  )
import Domain.User.Projection (User (..))
import Infrastructure.App
  ( AppM,
    HasAuthConfig (..),
    HasEventStore (..),
    HasReadModel (..),
  )
import Infrastructure.Auth.JWT (JWTClaims (..), JWTConfig (..))
import qualified Infrastructure.Auth.JWT as JWT
import Infrastructure.Auth.OAuth
  ( OAuthUserInfo (..),
  )
import qualified Infrastructure.Auth.OAuth as OAuth
import Infrastructure.Auth.Password (hashPassword, verifyPassword)
import qualified Infrastructure.Auth.Telegram as TelegramAuth
import Infrastructure.Eventium (loadUserAggregate)
import RIO hiding (Handler)
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Result Types
-- -----------------------------------------------------------------------------

-- | Result of a successful authentication operation.
data AuthResult = AuthResult
  { token :: Text,
    userId :: UserId,
    email :: Maybe Text,
    expiresIn :: Int
  }

-- | Result of initiating an OAuth flow.
data OAuthRedirectResult = OAuthRedirectResult
  { url :: Text,
    state :: Text
  }

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Register a new user with email and password.
--
-- Orchestrates:
--   1. Check email doesn't already exist
--   2. Hash password
--   3. Generate user ID and external account ID
--   4. Issue RegisterUser command
--   5. Issue CreateAccount command for the External account
--   6. Generate JWT token
register ::
  Text ->
  Text ->
  AppM (Either DomainError AuthResult)
register email password = runExceptT $ do
  lift $ logInfo "Processing registration request"
  userReadModel <- lift (view userReadModelL)
  exists <- lift (emailExists userReadModel email)
  guardE (not exists) (AccountError "Email already registered")
  passwordHash <- lift (hashPassword password)
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom
  userId <- liftEitherWith (\_ -> AccountError "Internal error") (mkUserId userUuid)
  externalAccountId <-
    liftEitherWith (\_ -> AccountError "Internal error") (mkAccountId externalAccountUuid)
  runUserCmd
    id
    userUuid
    ( RegisterUserUserCommand
        RegisterUser
          { email = email,
            passwordHash = passwordHash,
            externalAccountId = externalAccountId
          }
    )
  runUserCmd
    id
    userUuid
    (AssignConfigurationUserCommand (AssignConfiguration {configurationId = defaultConfigurationId}))
  configRM <- lift (view configurationReadModelL)
  maybeConfig <- lift (getConfiguration configRM defaultConfigurationId)
  let baseCur = maybe USD (\c -> c.baseCurrency) maybeConfig
  runAccountCmd
    id
    externalAccountUuid
    ( CreateAccountAccountCommand
        CreateAccount
          { name = "External",
            initialBalance = unsafeMoney baseCur 0,
            createdBy = userId,
            accountType = External,
            overdraftLimit = Nothing
          }
    )
  ExceptT (generateAuthResult userId (Just email))

-- | Login with email and password.
--
-- Orchestrates:
--   1. Find user by email via read model
--   2. Check user has password set
--   3. Load user aggregate to get password hash
--   4. Verify password against stored hash (Argon2)
--   5. Generate JWT token
login ::
  Text ->
  Text ->
  AppM (Either DomainError AuthResult)
login email password = runExceptT $ do
  lift $ logInfo "Processing login request"
  userReadModel <- lift (view userReadModelL)
  (userId, user) <-
    liftMaybeM (NotFound "User" email) (getUserByEmail userReadModel email)
  guardE user.hasPassword (AccountError "Invalid email or password")
  reader <- lift (view eventStoreReaderL)
  userAggregate <- liftIO (loadUserAggregate reader (unUserId userId))
  storedHash <- case userAggregate.passwordHash of
    Just h -> pure h
    Nothing -> do
      lift $ logError "User has password flag but no hash in aggregate"
      throwE (AccountError "Invalid email or password")
  guardE (verifyPassword password storedHash) (AccountError "Invalid email or password")
  let userEmail = fromMaybe email user.email
  ExceptT (generateAuthResult userId (Just userEmail))

-- | Initiate OAuth flow for a provider.
--
-- Orchestrates:
--   1. Get OAuth config
--   2. Generate authorization URL and state
initiateOAuth ::
  OAuthProvider ->
  AppM (Either DomainError OAuthRedirectResult)
initiateOAuth provider = runExceptT $ do
  lift $ logInfo $ "Initiating OAuth flow for provider: " <> displayShow provider
  oauthConfig <- lift (view oauthConfigL)
  result <- lift (OAuth.getAuthorizationUrl oauthConfig provider)
  (url, state) <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "OAuth error: " <> displayShow err
      throwE (AccountError "OAuth configuration error")
  lift $ logInfo "OAuth authorization URL generated"
  pure (OAuthRedirectResult url state)

-- | Handle OAuth callback after provider redirect.
--
-- Orchestrates:
--   1. Exchange code for user info (HTTP — Infrastructure.Auth.OAuth)
--   2. Delegate the find-or-create logic to 'linkOrSignInWithOAuth'.
handleOAuthCallback ::
  OAuthProvider ->
  Text ->
  Text ->
  AppM (Either DomainError AuthResult)
handleOAuthCallback provider code state = runExceptT $ do
  lift $ logInfo $ "Processing OAuth callback for provider: " <> displayShow provider
  oauthConfig <- lift (view oauthConfigL)
  result <- lift (OAuth.handleOAuthCallback oauthConfig provider code state state)
  userInfo <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "OAuth callback error: " <> displayShow err
      throwE (AccountError "OAuth authentication failed")
  ExceptT (linkOrSignInWithOAuth provider userInfo)

-- | Find-or-create a user from an already-resolved 'OAuth.OAuthUserInfo'.
--
-- Decision tree (see docs/specs/2026-04-28-oauth-auto-link-by-email-design.md §6):
--   - If a user already has this @(provider, subject)@ identity → sign in as that user.
--   - Otherwise (auto-link branch implemented in Task 3):
--       - if the provider didn't return an email → ValidationErr.
--       - else create a new user via OAuth.
--
-- Exported for white-box tests in @Application.Services.AuthServiceSpec@.
linkOrSignInWithOAuth ::
  OAuthProvider ->
  OAuth.OAuthUserInfo ->
  AppM (Either DomainError AuthResult)
linkOrSignInWithOAuth provider userInfo = runExceptT $ do
  let oauthIdentity =
        OAuthIdentity
          { provider = provider,
            subject = userInfo.subject
          }
  userReadModel <- lift (view userReadModelL)
  maybeUser <- lift (getUserByOAuthIdentity userReadModel provider userInfo.subject)
  case maybeUser of
    Just (uid, user) -> do
      lift $ logInfo "Existing user found via OAuth"
      ExceptT (generateAuthResult uid user.email)
    Nothing -> case (userInfo.email, userInfo.emailVerified) of
      (Nothing, _) -> do
        lift $ logError "OAuth provider did not return email"
        throwE
          ( ValidationErr
              (mkValidationError "email" "OAuth provider did not return email address" "")
          )
      (Just email, False) -> do
        lift $ logInfo "OAuth email not verified — creating new user without auto-link"
        ExceptT (createUserViaOAuth email oauthIdentity)
      (Just email, True) -> do
        maybeByEmail <- lift (getUserByEmail userReadModel email)
        case maybeByEmail of
          Just (uid, user) -> do
            lift $ logInfo "Auto-linking verified OAuth email to existing user"
            runUserCmd
              id
              (unUserId uid)
              (LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity})
            ExceptT (generateAuthResult uid user.email)
          Nothing -> do
            lift $ logInfo "Creating new user via OAuth (no existing email match)"
            ExceptT (createUserViaOAuth email oauthIdentity)

-- | Link an OAuth identity to an existing user.
--
-- Exchanges the authorization @code@ for an 'OAuth.OAuthUserInfo' (so we
-- key the linked identity on the provider's stable @subject@ — not the
-- one-time auth code) and then delegates to 'linkOAuthIdentityToUser'.
--
-- @state@ is forwarded to the OAuth provider abstraction. CSRF protection
-- already ran at the API boundary; this layer treats received state as
-- both expected and actual (matches the pattern in 'handleOAuthCallback').
linkOAuth ::
  UserId ->
  OAuthProvider ->
  Text -> -- Authorization code
  Text -> -- State (received from provider, validated frontend-side)
  AppM (Either DomainError ())
linkOAuth userId provider code state = runExceptT $ do
  lift $ logInfo "Processing link OAuth request"
  oauthConfig <- lift (view oauthConfigL)
  result <- lift (OAuth.handleOAuthCallback oauthConfig provider code state state)
  userInfo <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "OAuth callback error during link: " <> displayShow err
      throwE (AccountError "OAuth authentication failed")
  ExceptT (linkOAuthIdentityToUser userId provider userInfo)

-- | Attach an already-resolved 'OAuth.OAuthUserInfo' to an existing user.
--
-- Refuses if the @(provider, subject)@ identity is already linked to any
-- user (including this one) — the aggregate's idempotency invariant.
--
-- Exported for white-box tests in @Application.Services.AuthServiceSpec@.
linkOAuthIdentityToUser ::
  UserId ->
  OAuthProvider ->
  OAuth.OAuthUserInfo ->
  AppM (Either DomainError ())
linkOAuthIdentityToUser userId provider userInfo = runExceptT $ do
  let oauthIdentity = OAuthIdentity {provider = provider, subject = userInfo.subject}
  userReadModel <- lift (view userReadModelL)
  maybeExisting <- lift (getUserByOAuthIdentity userReadModel provider userInfo.subject)
  guardE (isNothing maybeExisting) (AccountError "OAuth account already linked to another user")
  let linkCmd = LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity}
  runUserCmd id (unUserId userId) linkCmd
  lift $ logInfo "OAuth account linked successfully"

-- | Authenticate via Telegram login widget.
--
-- Orchestrates:
--   1. Verify Telegram auth data
--   2. Find or create user by Telegram ID
--   3. Generate JWT token
authenticateTelegram ::
  TelegramAuth.TelegramAuthData ->
  AppM (Either DomainError AuthResult)
authenticateTelegram authData = runExceptT $ do
  lift $ logInfo "Processing Telegram authentication"
  telegramConfig <- lift (view telegramConfigL)
  result <- lift (TelegramAuth.authenticateViaTelegram telegramConfig authData)
  identity <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "Telegram auth verification failed: " <> displayShow err
      throwE (AccountError "Telegram authentication failed")
  userReadModel <- lift (view userReadModelL)
  maybeUser <- lift (getUserByTelegramId userReadModel identity.id)
  case maybeUser of
    Just (uid, user) -> do
      lift $ logInfo "Existing user found via Telegram"
      ExceptT (generateAuthResult uid user.email)
    Nothing -> do
      lift $ logInfo "Creating new user via Telegram"
      ExceptT (createUserViaTelegram identity)

-- | Link a Telegram identity to an existing user.
linkTelegram ::
  UserId ->
  TelegramAuth.TelegramAuthData ->
  AppM (Either DomainError ())
linkTelegram userId authData = runExceptT $ do
  lift $ logInfo "Processing link Telegram request"
  telegramConfig <- lift (view telegramConfigL)
  result <- lift (TelegramAuth.authenticateViaTelegram telegramConfig authData)
  identity <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "Telegram auth verification failed: " <> displayShow err
      throwE (AccountError "Telegram authentication failed")
  userReadModel <- lift (view userReadModelL)
  maybeExisting <- lift (getUserByTelegramId userReadModel identity.id)
  guardE (isNothing maybeExisting) (AccountError "Telegram account already linked to another user")
  let linkCmd = LinkTelegramAccountUserCommand LinkTelegramAccount {identity = identity}
  runUserCmd id (unUserId userId) linkCmd
  lift $ logInfo "Telegram account linked successfully"

-- | Refresh a JWT token.
refreshToken ::
  Text ->
  AppM (Either DomainError AuthResult)
refreshToken token = runExceptT $ do
  lift $ logInfo "Processing token refresh request"
  jwtConfig <- lift (view jwtConfigL)
  result <- lift (JWT.refreshToken jwtConfig token)
  newToken <- case result of
    Right ok -> pure ok
    Left err -> do
      lift $ logError $ "Token refresh failed: " <> displayShow err
      throwE (AccountError "Invalid or expired token")
  maybeClaims <- lift (JWT.verifyToken jwtConfig newToken)
  claims <- case maybeClaims of
    Just c -> pure c
    Nothing -> do
      lift $ logError "Failed to verify refreshed token"
      throwE (AccountError "Internal error during token refresh")
  lift $ logInfo "Token refreshed successfully"
  pure
    AuthResult
      { token = newToken,
        userId = claims.userId,
        email = Just claims.email,
        expiresIn = jwtConfig.expirySeconds
      }

-- | Find or create a user from Telegram bot interaction.
--
-- Unlike 'authenticateTelegram', this skips HMAC verification since the
-- bot authenticates via its token. Used by the Telegram bot /start command.
--
-- Returns @(UserId, Bool)@ where the 'Bool' is 'True' when a new user
-- was created and 'False' when an existing user was found.
findOrCreateTelegramBotUser ::
  TelegramIdentity ->
  AppM (Either DomainError (UserId, Bool))
findOrCreateTelegramBotUser tgIdent = runExceptT $ do
  userReadModel <- lift (view userReadModelL)
  maybeUser <- lift (getUserByTelegramId userReadModel tgIdent.id)
  case maybeUser of
    Just (uid, _) -> pure (uid, False)
    Nothing -> do
      lift $ logInfo "Creating new user via Telegram bot"
      result <- lift (createUserViaTelegram tgIdent)
      case result of
        Left err -> do
          lift $ logError $ "findOrCreateTelegramBotUser: failed for TelegramId " <> displayShow tgIdent.id
          throwE err
        Right authResult -> pure (authResult.userId, True)

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Parse OAuth provider from text.
parseOAuthProvider :: Text -> Maybe OAuthProvider
parseOAuthProvider t = case T.toLower t of
  "google" -> Just Google
  "github" -> Just GitHub
  "microsoft" -> Just Microsoft
  _ -> Nothing

-- | Generate an AuthResult with a JWT token.
generateAuthResult :: UserId -> Maybe Text -> AppM (Either DomainError AuthResult)
generateAuthResult userId email = runExceptT $ do
  jwtConfig <- lift (view jwtConfigL)
  let emailText = fromMaybe "unknown@example.com" email
  token <-
    ExceptT
      $ first (\err -> AccountError ("Failed to generate authentication token: " <> tshow err))
      <$> JWT.generateToken jwtConfig userId emailText
  pure
    AuthResult
      { token = token,
        userId = userId,
        email = email,
        expiresIn = jwtConfig.expirySeconds
      }

-- | Create a new user via OAuth (with email + external account + OAuth identity).
createUserViaOAuth :: Text -> OAuthIdentity -> AppM (Either DomainError AuthResult)
createUserViaOAuth email oauthIdentity = runExceptT $ do
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom
  uid <- liftEitherWith (\_ -> AccountError "Internal error") (mkUserId userUuid)
  externalAccountId <-
    liftEitherWith (\_ -> AccountError "Internal error") (mkAccountId externalAccountUuid)
  pwHash <- lift (hashPassword "OAUTH_USER_NO_PASSWORD")
  runUserCmd
    id
    userUuid
    ( RegisterUserUserCommand
        RegisterUser
          { email = email,
            passwordHash = pwHash,
            externalAccountId = externalAccountId
          }
    )
  runUserCmd
    id
    userUuid
    (AssignConfigurationUserCommand (AssignConfiguration {configurationId = defaultConfigurationId}))
  configRM <- lift (view configurationReadModelL)
  maybeConfig <- lift (getConfiguration configRM defaultConfigurationId)
  let baseCur = maybe USD (\c -> c.baseCurrency) maybeConfig
  runAccountCmd
    id
    externalAccountUuid
    ( CreateAccountAccountCommand
        CreateAccount
          { name = "External",
            initialBalance = unsafeMoney baseCur 0,
            createdBy = uid,
            accountType = External,
            overdraftLimit = Nothing
          }
    )
  runUserCmd
    id
    userUuid
    (LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity})
  ExceptT (generateAuthResult uid (Just email))

-- | Create a new user via Telegram (with external account + Telegram identity).
createUserViaTelegram :: TelegramIdentity -> AppM (Either DomainError AuthResult)
createUserViaTelegram telegramIdentity = runExceptT $ do
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom
  uid <- liftEitherWith (\_ -> AccountError "Internal error") (mkUserId userUuid)
  externalAccountId <-
    liftEitherWith (\_ -> AccountError "Internal error") (mkAccountId externalAccountUuid)
  runUserCmd
    id
    userUuid
    ( RegisterViaTelegramUserCommand
        RegisterViaTelegram
          { identity = telegramIdentity,
            externalAccountId = externalAccountId
          }
    )
  runUserCmd
    id
    userUuid
    (AssignConfigurationUserCommand (AssignConfiguration {configurationId = defaultConfigurationId}))
  configRM <- lift (view configurationReadModelL)
  maybeConfig <- lift (getConfiguration configRM defaultConfigurationId)
  let baseCur = maybe USD (\c -> c.baseCurrency) maybeConfig
  runAccountCmd
    id
    externalAccountUuid
    ( CreateAccountAccountCommand
        CreateAccount
          { name = "External",
            initialBalance = unsafeMoney baseCur 0,
            createdBy = uid,
            accountType = External,
            overdraftLimit = Nothing
          }
    )
  ExceptT (generateAuthResult uid Nothing)
