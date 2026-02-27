{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.User.Events
-- Description : Events for the User aggregate
--
-- This module defines all events that can occur in the User aggregate's lifecycle.
-- Events represent immutable facts about state changes that have already occurred.
--
-- Key Events:
--   - UserRegistered: A new user was registered with email/password
--   - UserRegisteredViaTelegram: A new user was registered via Telegram
--   - OAuthAccountLinked: An OAuth identity was linked to the user
--   - TelegramAccountLinked: A Telegram account was linked to the user
--   - OAuthAccountUnlinked: An OAuth identity was removed from the user
--   - TelegramAccountUnlinked: A Telegram account was removed from the user
--   - PasswordChanged: The user's password was changed
--
-- All events use Template Haskell for integration with the eventium library
-- and include JSON serialization instances.
module Domain.User.Events
  ( -- * Event List
    userEvents,

    -- * User Events
    UserRegistered (..),
    UserRegisteredViaTelegram (..),
    OAuthAccountLinked (..),
    TelegramAccountLinked (..),
    OAuthAccountUnlinked (..),
    TelegramAccountUnlinked (..),
    PasswordChanged (..),
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
-- Event List for Template Haskell
-- -----------------------------------------------------------------------------

-- | List of all user event type names for Template Haskell processing.
--
-- This list is used by eventium's Template Haskell machinery to generate
-- the UserEvent sum type and related serialization code.
userEvents :: [Name]
userEvents =
  [ ''UserRegistered,
    ''UserRegisteredViaTelegram,
    ''OAuthAccountLinked,
    ''TelegramAccountLinked,
    ''OAuthAccountUnlinked,
    ''TelegramAccountUnlinked,
    ''PasswordChanged
  ]

-- -----------------------------------------------------------------------------
-- User Events
-- -----------------------------------------------------------------------------

-- | Event emitted when a new user is registered with email and password.
--
-- Contains the initial user configuration including email, password hash,
-- and reference to the auto-created External account.
--
-- Example:
-- >>> UserRegistered "user@example.com" hashedPassword externalAccountId
data UserRegistered = UserRegistered
  { -- | User's email address
    userRegisteredEmail :: Text,
    -- | Hashed password (Argon2)
    userRegisteredPasswordHash :: PasswordHash,
    -- | ID of the auto-created External account
    userRegisteredExternalAccountId :: AccountId
  }
  deriving (Show, Eq)

-- | Event emitted when a new user is registered via Telegram.
--
-- Contains the Telegram identity and reference to the auto-created External account.
--
-- Example:
-- >>> UserRegisteredViaTelegram telegramIdentity externalAccountId
data UserRegisteredViaTelegram = UserRegisteredViaTelegram
  { -- | Telegram identity information
    userRegisteredViaTelegramIdentity :: TelegramIdentity,
    -- | ID of the auto-created External account
    userRegisteredViaTelegramExternalAccountId :: AccountId
  }
  deriving (Show, Eq)

-- | Event emitted when an OAuth account is linked to a user.
--
-- Records the OAuth provider and subject identifier.
--
-- Example:
-- >>> OAuthAccountLinked (OAuthIdentity Google "123456789")
data OAuthAccountLinked = OAuthAccountLinked
  { -- | OAuth identity that was linked
    oAuthAccountLinkedIdentity :: OAuthIdentity
  }
  deriving (Show, Eq)

-- | Event emitted when a Telegram account is linked to a user.
--
-- Records the Telegram identity information.
--
-- Example:
-- >>> TelegramAccountLinked telegramIdentity
data TelegramAccountLinked = TelegramAccountLinked
  { -- | Telegram identity that was linked
    telegramAccountLinkedIdentity :: TelegramIdentity
  }
  deriving (Show, Eq)

-- | Event emitted when an OAuth account is unlinked from a user.
--
-- Records which OAuth identity was removed.
--
-- Example:
-- >>> OAuthAccountUnlinked (OAuthIdentity Google "123456789")
data OAuthAccountUnlinked = OAuthAccountUnlinked
  { -- | OAuth identity that was unlinked
    oAuthAccountUnlinkedIdentity :: OAuthIdentity
  }
  deriving (Show, Eq)

-- | Event emitted when a Telegram account is unlinked from a user.
--
-- Example:
-- >>> TelegramAccountUnlinked
data TelegramAccountUnlinked = TelegramAccountUnlinked
  deriving (Show, Eq)

-- | Event emitted when a user's password is changed.
--
-- Contains the new password hash.
--
-- Example:
-- >>> PasswordChanged newHashedPassword
data PasswordChanged = PasswordChanged
  { -- | New password hash
    passwordChangedNewHash :: PasswordHash
  }
  deriving (Show, Eq)

-- -----------------------------------------------------------------------------
-- JSON Instances
-- -----------------------------------------------------------------------------

-- Derive JSON instances for all events using the unprefixed lowercase pattern
deriveJSONUnPrefixLower ''UserRegistered
deriveJSONUnPrefixLower ''UserRegisteredViaTelegram
deriveJSONUnPrefixLower ''OAuthAccountLinked
deriveJSONUnPrefixLower ''TelegramAccountLinked
deriveJSONUnPrefixLower ''OAuthAccountUnlinked
deriveJSONUnPrefixLower ''TelegramAccountUnlinked
deriveJSONUnPrefixLower ''PasswordChanged
