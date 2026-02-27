{-# LANGUAGE DeriveGeneric #-}

-- |
-- Module      : Domain.User.Errors
-- Description : Error types specific to the User aggregate
--
-- This module defines error types that can occur during user operations.
-- These errors represent business rule violations or invalid states that
-- prevent commands from being executed.
--
-- Error Types:
--   - UserNotFound: User does not exist in the system
--   - EmailAlreadyExists: Email is already registered to another user
--   - TelegramAlreadyLinked: Telegram ID is already linked to another user
--   - OAuthAlreadyLinked: OAuth identity is already linked to another user
--   - InvalidCredentials: Email/password combination is incorrect
--   - NoLoginMethodRemaining: Cannot remove last login method
--   - TelegramNotLinked: User does not have Telegram linked
--   - OAuthNotLinked: User does not have the specified OAuth provider linked
--
-- These errors are used at the API layer to provide meaningful feedback
-- to clients. The command handler itself uses empty event lists to
-- represent business rule violations.
--
-- Usage Context:
--   - API Layer: Convert validation failures to errors for HTTP responses
--   - Query Side: Report errors when users cannot be found
--   - Validation: Pre-validation before sending commands
module Domain.User.Errors
  ( -- * User Error Types
    UserError (..),

    -- * Error Constructors
    mkUserNotFound,
    mkEmailAlreadyExists,
    mkTelegramAlreadyLinked,
    mkOAuthAlreadyLinked,
    mkInvalidCredentials,
    mkNoLoginMethodRemaining,
    mkTelegramNotLinked,
    mkOAuthNotLinked,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import qualified Data.Text as T
import Domain.Core.Types (OAuthProvider, TelegramId, UserId)
import GHC.Generics (Generic)

-- -----------------------------------------------------------------------------
-- User Error Types
-- -----------------------------------------------------------------------------

-- | Errors specific to user operations.
--
-- These errors represent violations of business rules or invalid states
-- in user operations. They are typically used at the API layer to
-- provide meaningful error responses to clients.
data UserError
  = -- | User not found by ID
    UserNotFound
      { -- | The user ID that was not found
        userNotFoundId :: UserId
      }
  | -- | Email is already registered to another user
    EmailAlreadyExists
      { -- | The email that already exists
        emailAlreadyExistsEmail :: Text
      }
  | -- | Telegram ID is already linked to another user
    TelegramAlreadyLinked
      { -- | The Telegram ID that is already linked
        telegramAlreadyLinkedId :: TelegramId
      }
  | -- | OAuth identity is already linked to another user
    OAuthAlreadyLinked
      { -- | The OAuth provider
        oauthAlreadyLinkedProvider :: OAuthProvider,
        -- | The OAuth subject
        oauthAlreadyLinkedSubject :: Text
      }
  | -- | Invalid email/password combination
    InvalidCredentials
      { -- | Description of the error (generic for security)
        invalidCredentialsMessage :: Text
      }
  | -- | Cannot remove last login method
    NoLoginMethodRemaining
      { -- | The user ID
        noLoginMethodRemainingUserId :: UserId,
        -- | Description of what the user tried to remove
        noLoginMethodRemainingAttempted :: Text
      }
  | -- | User does not have Telegram linked
    TelegramNotLinked
      { -- | The user ID
        telegramNotLinkedUserId :: UserId
      }
  | -- | User does not have the specified OAuth provider linked
    OAuthNotLinked
      { -- | The user ID
        oauthNotLinkedUserId :: UserId,
        -- | The OAuth provider that was not linked
        oauthNotLinkedProvider :: OAuthProvider
      }
  deriving (Show, Eq, Generic)

-- JSON instances for API serialization
instance ToJSON UserError

instance FromJSON UserError

-- -----------------------------------------------------------------------------
-- Error Constructors
-- -----------------------------------------------------------------------------

-- | Create a UserNotFound error.
--
-- This error indicates that a user with the given ID does not exist
-- in the system.
--
-- Example:
-- >>> mkUserNotFound userId
-- UserNotFound { userNotFoundId = userId }
mkUserNotFound ::
  -- | User ID that was not found
  UserId ->
  UserError
mkUserNotFound userId =
  UserNotFound
    { userNotFoundId = userId
    }

-- | Create an EmailAlreadyExists error.
--
-- This error indicates that an attempt was made to register with
-- an email that is already in use.
--
-- Example:
-- >>> mkEmailAlreadyExists "user@example.com"
-- EmailAlreadyExists { emailAlreadyExistsEmail = "user@example.com" }
mkEmailAlreadyExists ::
  -- | Email that already exists
  Text ->
  UserError
mkEmailAlreadyExists email =
  EmailAlreadyExists
    { emailAlreadyExistsEmail = email
    }

-- | Create a TelegramAlreadyLinked error.
--
-- This error indicates that an attempt was made to link a Telegram
-- account that is already linked to another user.
--
-- Example:
-- >>> mkTelegramAlreadyLinked telegramId
-- TelegramAlreadyLinked { telegramAlreadyLinkedId = telegramId }
mkTelegramAlreadyLinked ::
  -- | Telegram ID that is already linked
  TelegramId ->
  UserError
mkTelegramAlreadyLinked telegramId =
  TelegramAlreadyLinked
    { telegramAlreadyLinkedId = telegramId
    }

-- | Create an OAuthAlreadyLinked error.
--
-- This error indicates that an attempt was made to link an OAuth
-- account that is already linked to another user.
--
-- Example:
-- >>> mkOAuthAlreadyLinked Google "123456789"
-- OAuthAlreadyLinked { oauthAlreadyLinkedProvider = Google, oauthAlreadyLinkedSubject = "123456789" }
mkOAuthAlreadyLinked ::
  -- | OAuth provider
  OAuthProvider ->
  -- | OAuth subject
  Text ->
  UserError
mkOAuthAlreadyLinked provider subject =
  OAuthAlreadyLinked
    { oauthAlreadyLinkedProvider = provider,
      oauthAlreadyLinkedSubject = subject
    }

-- | Create an InvalidCredentials error.
--
-- This error indicates that the email/password combination is incorrect.
-- The message is intentionally generic for security.
--
-- Example:
-- >>> mkInvalidCredentials
-- InvalidCredentials { invalidCredentialsMessage = "Invalid email or password" }
mkInvalidCredentials :: UserError
mkInvalidCredentials =
  InvalidCredentials
    { invalidCredentialsMessage = T.pack "Invalid email or password"
    }

-- | Create a NoLoginMethodRemaining error.
--
-- This error indicates that an attempt was made to remove a login
-- method that would leave the user without any way to log in.
--
-- Example:
-- >>> mkNoLoginMethodRemaining userId "Telegram"
-- NoLoginMethodRemaining { noLoginMethodRemainingUserId = userId, noLoginMethodRemainingAttempted = "Telegram" }
mkNoLoginMethodRemaining ::
  -- | User ID
  UserId ->
  -- | What the user tried to remove
  Text ->
  UserError
mkNoLoginMethodRemaining userId attempted =
  NoLoginMethodRemaining
    { noLoginMethodRemainingUserId = userId,
      noLoginMethodRemainingAttempted = attempted
    }

-- | Create a TelegramNotLinked error.
--
-- This error indicates that an attempt was made to unlink Telegram
-- from a user who does not have Telegram linked.
--
-- Example:
-- >>> mkTelegramNotLinked userId
-- TelegramNotLinked { telegramNotLinkedUserId = userId }
mkTelegramNotLinked ::
  -- | User ID
  UserId ->
  UserError
mkTelegramNotLinked userId =
  TelegramNotLinked
    { telegramNotLinkedUserId = userId
    }

-- | Create an OAuthNotLinked error.
--
-- This error indicates that an attempt was made to unlink an OAuth
-- provider that is not linked to the user.
--
-- Example:
-- >>> mkOAuthNotLinked userId Google
-- OAuthNotLinked { oauthNotLinkedUserId = userId, oauthNotLinkedProvider = Google }
mkOAuthNotLinked ::
  -- | User ID
  UserId ->
  -- | OAuth provider
  OAuthProvider ->
  UserError
mkOAuthNotLinked userId provider =
  OAuthNotLinked
    { oauthNotLinkedUserId = userId,
      oauthNotLinkedProvider = provider
    }
