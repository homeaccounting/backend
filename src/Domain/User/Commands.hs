{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.User.Commands
-- Description : Commands for the User aggregate
--
-- This module defines all commands that can be issued to the User aggregate.
-- Commands represent intentions to perform actions that may succeed or fail based
-- on the current aggregate state and business rules.
--
-- Key Commands:
--   - RegisterUser: Register a new user with email and password
--   - RegisterViaTelegram: Register a new user via Telegram bot
--   - LinkOAuthAccount: Link an OAuth identity to an existing user
--   - LinkTelegramAccount: Link a Telegram account to an existing user
--   - UnlinkOAuthAccount: Remove an OAuth identity from a user
--   - UnlinkTelegramAccount: Remove Telegram account from a user
--   - ChangePassword: Change user's password
--
-- All commands use Template Haskell for integration with the eventium library
-- and include JSON serialization instances for API integration.
module Domain.User.Commands
  ( -- * Command List
    userCommands,

    -- * User Commands
    RegisterUser (..),
    RegisterViaTelegram (..),
    LinkOAuthAccount (..),
    LinkTelegramAccount (..),
    UnlinkOAuthAccount (..),
    UnlinkTelegramAccount (..),
    ChangePassword (..),
  )
where

import Data.Text (Text)
import Domain.Core.Types
  ( AccountId,
    OAuthIdentity,
    PasswordHash,
    TelegramIdentity,
  )
import Infrastructure.Json (deriveJSONUnPrefixLower)
import Language.Haskell.TH (Name)

-- -----------------------------------------------------------------------------
-- Command List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all user command type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the UserCommand sum type and related serialization code.
userCommands :: [Name]
userCommands =
  [ ''RegisterUser,
    ''RegisterViaTelegram,
    ''LinkOAuthAccount,
    ''LinkTelegramAccount,
    ''UnlinkOAuthAccount,
    ''UnlinkTelegramAccount,
    ''ChangePassword
  ]

-- -----------------------------------------------------------------------------
-- User Commands
-- -----------------------------------------------------------------------------

-- | Command to register a new user with email and password.
--
-- Represents the intent to create a new user account with email/password
-- authentication. The user ID is determined by the aggregate ID when the
-- command is processed.
--
-- If accepted, produces a UserRegistered event, which should trigger
-- auto-creation of the user's External account for income/expense tracking.
--
-- Business Rules:
--   - Email must be valid and not already registered
--   - Password must meet minimum requirements (validated by API layer)
--   - External account ID must be provided for auto-creation
--
-- Example:
-- >>> RegisterUser "user@example.com" hashedPassword externalAccountId
data RegisterUser = RegisterUser
  { -- | User's email address (primary identifier for web login)
    registerUserEmail :: Text,
    -- | Hashed password (Argon2)
    registerUserPasswordHash :: PasswordHash,
    -- | ID for the auto-created External account
    registerUserExternalAccountId :: AccountId
  }
  deriving (Show, Eq)

-- | Command to register a new user via Telegram.
--
-- Represents the intent to create a new user account through the Telegram bot.
-- This registration path does not require a password initially.
--
-- If accepted, produces a UserRegisteredViaTelegram event.
--
-- Business Rules:
--   - Telegram ID must not be already linked to another user
--   - External account ID must be provided for auto-creation
--
-- Example:
-- >>> RegisterViaTelegram telegramIdentity externalAccountId
data RegisterViaTelegram = RegisterViaTelegram
  { -- | Telegram identity information
    registerViaTelegramIdentity :: TelegramIdentity,
    -- | ID for the auto-created External account
    registerViaTelegramExternalAccountId :: AccountId
  }
  deriving (Show, Eq)

-- | Command to link an OAuth account to an existing user.
--
-- Represents the intent to add an OAuth identity (Google, GitHub, Microsoft)
-- to an existing user account.
--
-- If accepted, produces an OAuthAccountLinked event.
--
-- Business Rules:
--   - User must exist
--   - OAuth identity must not be linked to another user
--   - Multiple OAuth accounts from different providers can be linked
--
-- Example:
-- >>> LinkOAuthAccount oauthIdentity
data LinkOAuthAccount = LinkOAuthAccount
  { -- | OAuth identity to link
    linkOAuthAccountIdentity :: OAuthIdentity
  }
  deriving (Show, Eq)

-- | Command to link a Telegram account to an existing user.
--
-- Represents the intent to add Telegram login capability to an existing user.
--
-- If accepted, produces a TelegramAccountLinked event.
--
-- Business Rules:
--   - User must exist
--   - User must not already have a Telegram account linked
--   - Telegram ID must not be linked to another user
--
-- Example:
-- >>> LinkTelegramAccount telegramIdentity
data LinkTelegramAccount = LinkTelegramAccount
  { -- | Telegram identity to link
    linkTelegramAccountIdentity :: TelegramIdentity
  }
  deriving (Show, Eq)

-- | Command to unlink an OAuth account from a user.
--
-- Represents the intent to remove an OAuth identity from a user account.
--
-- If accepted, produces an OAuthAccountUnlinked event.
--
-- Business Rules:
--   - User must exist
--   - The OAuth identity must be linked to the user
--   - User must have at least one other login method remaining
--
-- Example:
-- >>> UnlinkOAuthAccount Google
data UnlinkOAuthAccount = UnlinkOAuthAccount
  { -- | OAuth identity to unlink
    unlinkOAuthAccountIdentity :: OAuthIdentity
  }
  deriving (Show, Eq)

-- | Command to unlink a Telegram account from a user.
--
-- Represents the intent to remove Telegram login capability from a user.
--
-- If accepted, produces a TelegramAccountUnlinked event.
--
-- Business Rules:
--   - User must exist
--   - User must have Telegram linked
--   - User must have at least one other login method remaining
--
-- Example:
-- >>> UnlinkTelegramAccount
data UnlinkTelegramAccount = UnlinkTelegramAccount
  deriving (Show, Eq)

-- | Command to change a user's password.
--
-- Represents the intent to update the user's password.
--
-- If accepted, produces a PasswordChanged event.
--
-- Business Rules:
--   - User must exist
--   - Old password must match current password (validated at API layer)
--   - New password must meet minimum requirements (validated at API layer)
--
-- Example:
-- >>> ChangePassword newHashedPassword
data ChangePassword = ChangePassword
  { -- | New password hash
    changePasswordNewHash :: PasswordHash
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all commands using the unprefixed lowercase pattern
deriveJSONUnPrefixLower ''RegisterUser
deriveJSONUnPrefixLower ''RegisterViaTelegram
deriveJSONUnPrefixLower ''LinkOAuthAccount
deriveJSONUnPrefixLower ''LinkTelegramAccount
deriveJSONUnPrefixLower ''UnlinkOAuthAccount
deriveJSONUnPrefixLower ''UnlinkTelegramAccount
deriveJSONUnPrefixLower ''ChangePassword
