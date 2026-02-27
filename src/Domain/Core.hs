-- |
-- Module      : Domain.Core
-- Description : Core domain types and errors
--
-- This module re-exports all core domain types and errors, providing a single
-- import point for the fundamental domain concepts used throughout the system.
--
-- Usage:
--   import Domain.Core
--
-- This gives access to Money, AccountId, TransactionId, and all error types.
module Domain.Core
  ( module X,
  )
where

import Domain.Core.Errors as X
import Domain.Core.Types as X
