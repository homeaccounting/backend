{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.EventDispatch
-- Description : Read-model registry and event-handler bundle construction
--
-- Owns 'ReadModels' and provides 'fromReadModels' to build a single composite
-- 'AccountingReadModelHandler m' for 'Infrastructure.Eventium'.
-- This is the only module that imports concrete @Application.ReadModels.*@
-- handler functions; Infrastructure depends only on the abstract handler type.
module Application.EventDispatch
  ( ReadModels (..),
    createReadModels,
    fromReadModels,
  )
where

import Application.ReadModels.Configuration
  ( ConfigurationReadModel,
    createConfigurationReadModel,
    handleConfigurationEvents,
  )
import Application.ReadModels.ExchangeRate
  ( ExchangeRateReadModel,
    createExchangeRateReadModel,
    handleExchangeRateEvents,
  )
import Infrastructure.Eventium (AccountingReadModelHandler)
import RIO

-- | Combined in-memory read-model state for the bounded contexts that are still
-- projected into memory. BankImport, Account, and Transaction have migrated to
-- persistent (SQL) read models and are wired separately (see
-- 'Application.ReadModels.Persist' and the event-store writer in @app/Main.hs@).
data ReadModels = ReadModels
  { configuration :: TVar ConfigurationReadModel,
    exchangeRate :: TVar ExchangeRateReadModel
  }

-- | Allocate fresh TVars for every read model.
createReadModels :: (MonadIO m) => m ReadModels
createReadModels = do
  configRM <- createConfigurationReadModel
  exchangeRateRM <- createExchangeRateReadModel
  pure
    ReadModels
      { configuration = configRM,
        exchangeRate = exchangeRateRM
      }

-- | Build a composite read-model handler from concrete read-model TVars.
--
-- Each per-context handler is composed via 'Monoid'; all receive the full
-- event list and filter internally by event type.
fromReadModels :: (MonadIO m) => ReadModels -> AccountingReadModelHandler m
fromReadModels rms =
  mconcat
    [ handleConfigurationEvents rms.configuration,
      handleExchangeRateEvents rms.exchangeRate
    ]
