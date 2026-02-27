-- |
-- Module      : Domain.User
-- Description : Public API for the User aggregate
--
-- This module re-exports all User aggregate components, providing a single
-- import point for working with users.
--
-- Usage:
-- >>> import Domain.User
--
-- This gives you access to:
--   - Events: UserRegistered, UserRegisteredViaTelegram, OAuthAccountLinked, etc.
--   - Commands: RegisterUser, RegisterViaTelegram, LinkOAuthAccount, etc.
--   - Projection: User, userProjection, UserEvent
--   - Command Handler: userCommandHandler, UserCommand
--   - Errors: UserError, UserNotFound, EmailAlreadyExists, etc.
--
-- The User aggregate represents a user account with authentication methods.
-- It follows event sourcing and CQRS patterns:
--   - Commands express user intent
--   - Command handler validates commands against current state
--   - Events represent facts about state changes
--   - Projection rebuilds state from events
--
-- Example Usage:
--
-- Registering a user:
-- >>> let cmd = RegisterUser "user@example.com" hashedPassword externalAccountId
-- >>> let events = handleUserCommand userDefault cmd
-- >>> events
-- [UserRegisteredUserEvent (UserRegistered "user@example.com" hashedPassword externalAccountId)]
--
-- Processing events:
-- >>> let user = latestProjection userProjection events
-- >>> user ^. userEmail
-- "user@example.com"
--
-- Business Rules:
--   - Users must have at least one login method
--   - Email is unique across all users (validated via read model)
--   - Telegram ID is unique across all users (validated via read model)
--   - OAuth identities are unique across all users (validated via read model)
--   - External account is auto-created on registration
module Domain.User
  ( module X,
  )
where

import Domain.User.CommandHandler as X
import Domain.User.Commands as X
import Domain.User.Events as X
import Domain.User.Projection as X
