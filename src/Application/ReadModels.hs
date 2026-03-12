-- |
-- Module      : Application.ReadModels
-- Description : Re-exports for all read models
--
-- This module provides a single import point for all read models in the application.
-- Read models provide optimized query interfaces over the event-sourced data.
--
-- Re-exported Modules:
--   - Application.ReadModels.Account: Account query projections (with RBAC)
--   - Application.ReadModels.Transaction: Transaction query projections
--   - Application.ReadModels.User: User query projections
module Application.ReadModels
  ( module X,
  )
where

import Application.ReadModels.Account as X
import Application.ReadModels.Transaction as X
import Application.ReadModels.User as X
