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
    linkOAuth,
    authenticateTelegram,
    linkTelegram,
    refreshToken,
    findOrCreateTelegramBotUser,

    -- * Helpers re-exported for AuthAPI types
    parseOAuthProvider,
  )
where

import Application.ReadModels.User
  ( UserData (..),
    emailExists,
    getUserByEmail,
    getUserByOAuthIdentity,
    getUserByTelegramId,
  )
import qualified Data.UUID.V4 as UUID
import Domain.Account.CommandHandler (AccountCommand (..))
import Domain.Account.Commands (CreateAccount (..))
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types
  ( AccountType (..),
    OAuthIdentity (..),
    OAuthProvider (..),
    TelegramIdentity (..),
    UserId,
    mkAccountId,
    mkUserId,
    unUserId,
    unsafeMoney,
  )
import Domain.User.CommandHandler (UserCommand (..))
import Domain.User.Commands
  ( LinkOAuthAccount (..),
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
import Infrastructure.Eventium (applyAccountCommand, applyUserCommand, loadUserAggregate)
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
register email password = do
  logInfo "Processing registration request"

  -- 1. Check email doesn't exist
  userReadModel <- view userReadModelL
  exists <- emailExists userReadModel email
  if exists
    then do
      logWarn "Email already registered"
      return $ Left $ AccountError "Email already registered"
    else do
      -- 2. Hash password
      passwordHash <- hashPassword password

      -- 3. Generate IDs
      userUuid <- liftIO UUID.nextRandom
      externalAccountUuid <- liftIO UUID.nextRandom

      case mkUserId userUuid of
        Left err -> do
          logError $ "Failed to create UserId: " <> display err
          return $ Left $ AccountError "Internal error"
        Right userId ->
          case mkAccountId externalAccountUuid of
            Left err -> do
              logError $ "Failed to create ExternalAccountId: " <> display err
              return $ Left $ AccountError "Internal error"
            Right externalAccountId -> do
              -- 4. Issue RegisterUser command
              writer <- view eventStoreWriterL
              reader <- view eventStoreReaderL

              let registerCmd =
                    RegisterUserUserCommand
                      RegisterUser
                        { email = email,
                          passwordHash = passwordHash,
                          externalAccountId = externalAccountId
                        }

              result1 <- liftIO $ applyUserCommand writer reader userUuid registerCmd
              case result1 of
                Left err -> do
                  logError $ "User registration rejected: " <> displayShow err
                  return $ Left $ AccountError "User registration rejected by domain"
                Right _ -> do
                  -- 5. Issue CreateAccount command for External account
                  let createAccountCmd =
                        CreateAccountAccountCommand
                          CreateAccount
                            { name = "External",
                              initialBalance = unsafeMoney 0,
                              createdBy = userId,
                              accountType = ExternalAccount
                            }

                  result2 <- liftIO $ applyAccountCommand writer reader externalAccountUuid createAccountCmd
                  case result2 of
                    Left err -> do
                      logError $ "External account creation rejected: " <> displayShow err
                      return $ Left $ AccountError "External account creation rejected by domain"
                    Right _ ->
                      -- 6. Generate JWT token
                      generateAuthResult userId (Just email)

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
login email password = do
  logInfo "Processing login request"

  -- 1. Find user by email
  userReadModel <- view userReadModelL
  maybeUser <- getUserByEmail userReadModel email

  case maybeUser of
    Nothing -> do
      logWarn "User not found for email"
      return $ Left $ NotFound "User" email
    Just (userId, userSummary) ->
      if not userSummary.hasPassword
        then do
          -- 2. Check user has password
          logWarn "User has no password set"
          return $ Left $ AccountError "Invalid email or password"
        else do
          -- 3. Load user aggregate to get password hash
          reader <- view eventStoreReaderL
          let userUuid = unUserId userId
          userAggregate <- liftIO $ loadUserAggregate reader userUuid

          case userAggregate.passwordHash of
            Nothing -> do
              logError "User has password flag but no hash in aggregate"
              return $ Left $ AccountError "Invalid email or password"
            Just storedHash ->
              -- 4. Verify password
              if verifyPassword password storedHash
                then do
                  -- 5. Generate JWT token
                  let userEmail = fromMaybe email userSummary.email
                  generateAuthResult userId (Just userEmail)
                else do
                  logWarn "Password verification failed"
                  return $ Left $ AccountError "Invalid email or password"

-- | Initiate OAuth flow for a provider.
--
-- Orchestrates:
--   1. Get OAuth config
--   2. Generate authorization URL and state
initiateOAuth ::
  OAuthProvider ->
  AppM (Either DomainError OAuthRedirectResult)
initiateOAuth provider = do
  logInfo $ "Initiating OAuth flow for provider: " <> displayShow provider

  oauthConfig <- view oauthConfigL
  result <- OAuth.getAuthorizationUrl oauthConfig provider

  case result of
    Left err -> do
      logError $ "OAuth error: " <> displayShow err
      return $ Left $ AccountError "OAuth configuration error"
    Right (url, state) -> do
      logInfo "OAuth authorization URL generated"
      return $ Right $ OAuthRedirectResult url state

-- | Handle OAuth callback after provider redirect.
--
-- Orchestrates:
--   1. Exchange code for user info
--   2. Find or create user by OAuth identity
--   3. Generate JWT token
handleOAuthCallback ::
  OAuthProvider ->
  Text ->
  Text ->
  AppM (Either DomainError AuthResult)
handleOAuthCallback provider code state = do
  logInfo $ "Processing OAuth callback for provider: " <> displayShow provider

  -- 1. Exchange code for user info
  oauthConfig <- view oauthConfigL
  result <- OAuth.handleOAuthCallback oauthConfig provider code state state

  case result of
    Left err -> do
      logError $ "OAuth callback error: " <> displayShow err
      return $ Left $ AccountError "OAuth authentication failed"
    Right userInfo -> do
      -- 2. Find or create user by OAuth identity
      let oauthIdentity =
            OAuthIdentity
              { provider = provider,
                subject = userInfo.subject
              }

      userReadModel <- view userReadModelL
      maybeUser <- getUserByOAuthIdentity userReadModel provider userInfo.subject

      case maybeUser of
        Just (uid, summary) -> do
          logInfo "Existing user found via OAuth"
          generateAuthResult uid summary.email
        Nothing -> do
          -- Create new user with OAuth identity
          logInfo "Creating new user via OAuth"
          case userInfo.email of
            Just email -> do
              createUserViaOAuth email oauthIdentity
            Nothing -> do
              logError "OAuth provider did not return email"
              return $ Left $ ValidationErr $ mkValidationError "email" "OAuth provider did not return email address" ""

-- | Link an OAuth identity to an existing user.
linkOAuth ::
  UserId ->
  OAuthProvider ->
  Text ->
  AppM (Either DomainError ())
linkOAuth userId provider oauthCode = do
  logInfo "Processing link OAuth request"

  -- Check OAuth not already linked to another user
  userReadModel <- view userReadModelL
  let oauthIdentity = OAuthIdentity provider oauthCode
  maybeExisting <- getUserByOAuthIdentity userReadModel provider oauthIdentity.subject

  case maybeExisting of
    Just _ -> return $ Left $ AccountError "OAuth account already linked to another user"
    Nothing -> do
      let linkCmd = LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity}
      writer <- view eventStoreWriterL
      reader <- view eventStoreReaderL
      let userUuid = unUserId userId
      result <- liftIO $ applyUserCommand writer reader userUuid linkCmd
      case result of
        Left err -> do
          logError $ "Link OAuth rejected: " <> displayShow err
          return $ Left $ AccountError "Link OAuth rejected by domain"
        Right _ -> do
          logInfo "OAuth account linked successfully"
          return $ Right ()

-- | Authenticate via Telegram login widget.
--
-- Orchestrates:
--   1. Verify Telegram auth data
--   2. Find or create user by Telegram ID
--   3. Generate JWT token
authenticateTelegram ::
  TelegramAuth.TelegramAuthData ->
  AppM (Either DomainError AuthResult)
authenticateTelegram authData = do
  logInfo "Processing Telegram authentication"

  -- 1. Verify Telegram auth data
  telegramConfig <- view telegramConfigL
  result <- TelegramAuth.authenticateViaTelegram telegramConfig authData

  case result of
    Left err -> do
      logError $ "Telegram auth verification failed: " <> displayShow err
      return $ Left $ AccountError "Telegram authentication failed"
    Right identity -> do
      -- 2. Find or create user by Telegram ID
      userReadModel <- view userReadModelL
      maybeUser <- getUserByTelegramId userReadModel identity.id

      case maybeUser of
        Just (uid, summary) -> do
          logInfo "Existing user found via Telegram"
          generateAuthResult uid summary.email
        Nothing -> do
          -- Create new user via Telegram
          logInfo "Creating new user via Telegram"
          createUserViaTelegram identity

-- | Link a Telegram identity to an existing user.
linkTelegram ::
  UserId ->
  TelegramAuth.TelegramAuthData ->
  AppM (Either DomainError ())
linkTelegram userId authData = do
  logInfo "Processing link Telegram request"

  -- Verify Telegram auth data
  telegramConfig <- view telegramConfigL
  result <- TelegramAuth.authenticateViaTelegram telegramConfig authData

  case result of
    Left err -> do
      logError $ "Telegram auth verification failed: " <> displayShow err
      return $ Left $ AccountError "Telegram authentication failed"
    Right identity -> do
      -- Check Telegram not already linked to another user
      userReadModel <- view userReadModelL
      maybeExisting <- getUserByTelegramId userReadModel identity.id

      case maybeExisting of
        Just _ -> return $ Left $ AccountError "Telegram account already linked to another user"
        Nothing -> do
          let linkCmd = LinkTelegramAccountUserCommand LinkTelegramAccount {identity = identity}
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL
          let userUuid = unUserId userId
          result' <- liftIO $ applyUserCommand writer reader userUuid linkCmd
          case result' of
            Left err -> do
              logError $ "Link Telegram rejected: " <> displayShow err
              return $ Left $ AccountError "Link Telegram rejected by domain"
            Right _ -> do
              logInfo "Telegram account linked successfully"
              return $ Right ()

-- | Refresh a JWT token.
refreshToken ::
  Text ->
  AppM (Either DomainError AuthResult)
refreshToken token = do
  logInfo "Processing token refresh request"

  jwtConfig <- view jwtConfigL
  result <- JWT.refreshToken jwtConfig token

  case result of
    Left err -> do
      logError $ "Token refresh failed: " <> displayShow err
      return $ Left $ AccountError "Invalid or expired token"
    Right newToken -> do
      maybeClaimsResult <- JWT.verifyToken jwtConfig newToken
      case maybeClaimsResult of
        Nothing -> do
          logError "Failed to verify refreshed token"
          return $ Left $ AccountError "Internal error during token refresh"
        Just claims -> do
          logInfo "Token refreshed successfully"
          return
            $ Right
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
findOrCreateTelegramBotUser tgIdent = do
  userReadModel <- view userReadModelL
  maybeUser <- getUserByTelegramId userReadModel tgIdent.id
  case maybeUser of
    Just (uid, _) -> return $ Right (uid, False)
    Nothing -> do
      logInfo "Creating new user via Telegram bot"
      result <- createUserViaTelegram tgIdent
      case result of
        Left err -> do
          logError $ "findOrCreateTelegramBotUser: failed for TelegramId " <> displayShow tgIdent.id
          return $ Left err
        Right authResult -> return $ Right (authResult.userId, True)

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
generateAuthResult userId email = do
  jwtConfig <- view jwtConfigL
  let emailText = fromMaybe "unknown@example.com" email
  tokenResult <- JWT.generateToken jwtConfig userId emailText
  case tokenResult of
    Left err -> do
      logError $ "Failed to generate JWT: " <> displayShow err
      return $ Left $ AccountError "Failed to generate authentication token"
    Right token -> do
      return
        $ Right
          AuthResult
            { token = token,
              userId = userId,
              email = email,
              expiresIn = jwtConfig.expirySeconds
            }

-- | Create a new user via OAuth (with email + external account + OAuth identity).
createUserViaOAuth :: Text -> OAuthIdentity -> AppM (Either DomainError AuthResult)
createUserViaOAuth email oauthIdentity = do
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom

  case mkUserId userUuid of
    Left _ -> return $ Left $ AccountError "Internal error"
    Right uid ->
      case mkAccountId externalAccountUuid of
        Left _ -> return $ Left $ AccountError "Internal error"
        Right externalAccountId -> do
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL

          -- Register user with placeholder password (OAuth-only)
          pwHash <- hashPassword "OAUTH_USER_NO_PASSWORD"
          let registerCmd =
                RegisterUserUserCommand
                  RegisterUser
                    { email = email,
                      passwordHash = pwHash,
                      externalAccountId = externalAccountId
                    }
          result1 <- liftIO $ applyUserCommand writer reader userUuid registerCmd
          case result1 of
            Left err -> do
              logError $ "OAuth user registration rejected: " <> displayShow err
              return $ Left $ AccountError "User registration rejected by domain"
            Right _ -> do
              -- Create External account
              let createAccountCmd =
                    CreateAccountAccountCommand
                      CreateAccount
                        { name = "External",
                          initialBalance = unsafeMoney 0,
                          createdBy = uid,
                          accountType = ExternalAccount
                        }
              result2 <- liftIO $ applyAccountCommand writer reader externalAccountUuid createAccountCmd
              case result2 of
                Left err -> do
                  logError $ "External account creation rejected: " <> displayShow err
                  return $ Left $ AccountError "External account creation rejected by domain"
                Right _ -> do
                  -- Link OAuth identity
                  let linkCmd = LinkOAuthAccountUserCommand LinkOAuthAccount {identity = oauthIdentity}
                  result3 <- liftIO $ applyUserCommand writer reader userUuid linkCmd
                  case result3 of
                    Left err -> do
                      logError $ "Link OAuth identity rejected: " <> displayShow err
                      return $ Left $ AccountError "Link OAuth identity rejected by domain"
                    Right _ ->
                      generateAuthResult uid (Just email)

-- | Create a new user via Telegram (with external account + Telegram identity).
createUserViaTelegram :: TelegramIdentity -> AppM (Either DomainError AuthResult)
createUserViaTelegram telegramIdentity = do
  userUuid <- liftIO UUID.nextRandom
  externalAccountUuid <- liftIO UUID.nextRandom

  case mkUserId userUuid of
    Left _ -> return $ Left $ AccountError "Internal error"
    Right uid ->
      case mkAccountId externalAccountUuid of
        Left _ -> return $ Left $ AccountError "Internal error"
        Right externalAccountId -> do
          writer <- view eventStoreWriterL
          reader <- view eventStoreReaderL

          -- Register user via Telegram
          let registerCmd =
                RegisterViaTelegramUserCommand
                  RegisterViaTelegram
                    { identity = telegramIdentity,
                      externalAccountId = externalAccountId
                    }
          result1 <- liftIO $ applyUserCommand writer reader userUuid registerCmd
          case result1 of
            Left err -> do
              logError $ "Telegram user registration rejected: " <> displayShow err
              return $ Left $ AccountError "User registration rejected by domain"
            Right _ -> do
              -- Create External account
              let createAccountCmd =
                    CreateAccountAccountCommand
                      CreateAccount
                        { name = "External",
                          initialBalance = unsafeMoney 0,
                          createdBy = uid,
                          accountType = ExternalAccount
                        }
              result2 <- liftIO $ applyAccountCommand writer reader externalAccountUuid createAccountCmd
              case result2 of
                Left err -> do
                  logError $ "External account creation rejected: " <> displayShow err
                  return $ Left $ AccountError "External account creation rejected by domain"
                Right _ ->
                  generateAuthResult uid Nothing
