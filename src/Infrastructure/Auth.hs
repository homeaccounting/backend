-- |
-- Module      : Infrastructure.Auth
-- Description : Authentication infrastructure modules
--
-- This module re-exports all authentication infrastructure components,
-- providing a single import point for authentication functionality.
--
-- Available Modules:
--   - Password: Argon2 password hashing
--   - JWT: JSON Web Token generation and verification
--   - OAuth: OAuth2 provider integration (Google, GitHub, Microsoft)
--   - Telegram: Telegram Login Widget and Bot authentication
--
-- Usage:
-- >>> import Infrastructure.Auth
module Infrastructure.Auth
  ( -- * Password Hashing
    module Infrastructure.Auth.Password,

    -- * JWT Tokens
    module Infrastructure.Auth.JWT,

    -- * OAuth2
    module Infrastructure.Auth.OAuth,

    -- * Telegram
    module Infrastructure.Auth.Telegram,
  )
where

import Infrastructure.Auth.JWT
import Infrastructure.Auth.OAuth
import Infrastructure.Auth.Password
import Infrastructure.Auth.Telegram
