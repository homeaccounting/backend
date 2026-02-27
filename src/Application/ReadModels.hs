-- |
-- Module      : Application.ReadModels
-- Description : Re-exports for all read models
--
-- This module provides a single import point for all read models in the application.
-- Read models provide optimized query interfaces over the event-sourced data.
--
-- Re-exported Modules:
--   - Application.ReadModels.AccountSummary: Account query projections (with RBAC)
--   - Application.ReadModels.TransactionSummary: Transaction query projections
--   - Application.ReadModels.UserSummary: User query projections
module Application.ReadModels
  ( module X,
  )
where

import Application.ReadModels.AccountSummary as X
import Application.ReadModels.TransactionSummary as X
import Application.ReadModels.UserSummary as X
