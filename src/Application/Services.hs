-- |
-- Module      : Application.Services
-- Description : Application services for cross-cutting concerns
--
-- This module re-exports all application services, providing a single
-- import point for business logic that spans multiple aggregates.
--
-- Available Services:
--   - AuthorizationService: RBAC-based access control (pure)
--   - AuthService: User authentication orchestration (effectful)
--   - AccountService: Account use case orchestration (effectful)
--   - TransactionService: Transaction use case orchestration (effectful)
--   - UserService: User profile orchestration (effectful)
--
-- Usage:
-- >>> import Application.Services
module Application.Services
  ( module X,
  )
where

import Application.Services.AccountService as X
import Application.Services.AuthService as X
import Application.Services.AuthorizationService as X
import Application.Services.TransactionService as X
import Application.Services.UserService as X
