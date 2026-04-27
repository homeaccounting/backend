{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.AppEnv
-- Description : Shared @hspec-wai@ application bootstrap for HTTP-level specs.
--
-- The 'with mkApp' / 'with mkAppWith' pattern is used by every Web API spec
-- and a few integration specs. This module collapses the per-spec copies of
-- @mkApp = buildApplication \<$\> createTestAppEnv@ into one place and
-- exposes a small set of variants for the cases that need extra wiring
-- (banking enabled, transfer process manager, default configuration seeded).
module Testkit.AppEnv
  ( -- * Application bootstrap
    mkApp,
    mkAppWithProcessManager,
    mkAppBankingEnabled,
    mkAppSeeded,
  )
where

import qualified Application.Services.ConfigurationService as ConfigurationService
import Infrastructure.App (AppEnv (..), runAppM)
import Infrastructure.Config
  ( AppConfig (..),
    BankingConfig (..),
    BankingProvidersConfig (..),
    MonobankProviderConfig (..),
  )
import Network.Wai (Application)
import RIO
import Testkit.InMemoryEventStore
  ( createTestAppEnv,
    createTestAppEnvWithProcessManager,
  )
import Web.Server (buildApplication)

-- | Build a 'Wai.Application' against a fresh in-memory test 'AppEnv'.
--
-- This is the "no surprises" variant: banking is disabled, no process
-- manager, no default configuration seeded. It matches the bootstrap
-- previously copied across @WebAPISpec@, @TransactionAPISpec@,
-- @BankingAPISpec@, and @ConfigurationBankingAPISpec@.
mkApp :: IO Application
mkApp = buildApplication <$> createTestAppEnv

-- | Like 'mkApp' but with the transfer process manager wired into the
-- synchronous event bus, so saga-driven scenarios complete end-to-end.
mkAppWithProcessManager :: IO Application
mkAppWithProcessManager = buildApplication <$> createTestAppEnvWithProcessManager

-- | Like 'mkApp' but with @banking.enabled = True@ and the Monobank provider
-- enabled.
--
-- The Monobank @apiBaseUrl@ is left pointing at @127.0.0.1:1@ so any HTTP
-- call fails fast rather than hanging the test on a real network request.
-- Specs that exercise the feature-flag gate use this to confirm the
-- request crosses the gate; they don't care about the downstream provider
-- response.
mkAppBankingEnabled :: IO Application
mkAppBankingEnabled = do
  env <- createTestAppEnv
  let cfg = env.config
      bankingCfg =
        BankingConfig
          { enabled = True,
            providers =
              BankingProvidersConfig
                ( MonobankProviderConfig
                    True
                    "http://127.0.0.1:1"
                )
          }
      cfg' = cfg {banking = bankingCfg}
  pure $ buildApplication env {config = cfg'}

-- | Build the Wai 'Application' with the default configuration seeded.
--
-- Seeding populates both the income-category and expense-category
-- dictionaries with all default entries, so tests can reference the
-- deterministic UUIDs computed by 'mkDeterministicEntryId'.
mkAppSeeded :: IO Application
mkAppSeeded = do
  env <- createTestAppEnv
  runAppM env ConfigurationService.seedDefaultConfiguration
  pure (buildApplication env)
