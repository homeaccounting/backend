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
    mkAppBankingEnabledSeeded,
    mkAppBankingEnabledSeededWith,
    mkAppSeeded,

    -- * Stub bank provider (for HTTP-level banking specs)
    StubControls (..),
    newStubControls,
  )
where

import qualified Application.Services.ConfigurationService as ConfigurationService
import Domain.Banking.Types (unsafeBankProviderId)
import Infrastructure.App (AppEnv (..), BankingEnv (..), runAppM)
import Infrastructure.Banking.Provider
  ( BankAccount,
    BankProviderDescriptor (..),
    BankTransaction (..),
    PullCapability (..),
    TransactionClassification (..),
  )
import Infrastructure.Banking.Registry (BankProviderRegistry, registryFromList)
import Infrastructure.Config
  ( AppConfig (..),
    BankingConfig (..),
  )
import Network.Wai (Application)
import RIO
import qualified RIO.Map as Map
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
            -- The runtime feature gate keys off the provider registry (already
            -- non-empty in the base env), not this map; only 'Main' reads it.
            providers = Map.empty,
            -- Preserve the deterministic test key ring already built into the
            -- base env; flipping the feature flag only touches the config,
            -- not the key ring on 'bankingEnv'.
            tokenEncKey = cfg.banking.tokenEncKey
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

-- -----------------------------------------------------------------------------
-- Stub bank provider
-- -----------------------------------------------------------------------------

-- | Mutable fixtures backing the in-memory stub 'BankProviderDescriptor'.
--
-- A test obtains a 'StubControls' from 'mkAppBankingEnabledSeededWith',
-- pre-sets the external accounts that 'fetchAccounts' should return and/or
-- the per-external-id statements that 'fetchStatements' should return, and
-- then drives the HTTP layer. The same 'StubControls' is closed over by the
-- stub descriptor's 'PullCapability' in the registry installed on the env, so
-- updates are visible to handlers.
data StubControls = StubControls
  { -- | What 'fetchAccounts' returns. Defaults to @Right []@.
    stubAccounts :: !(IORef (Either Text [BankAccount])),
    -- | Per-external-account-id statements 'fetchStatements' returns. A
    -- missing key yields @Right []@ (no statements for that account).
    stubStatements :: !(IORef (Map.Map Text [BankTransaction])),
    -- | The env, exposed so a test can seed historical rates into the
    -- persistent @exchange_rates@ read model. The user's auto-created External
    -- account is denominated in the configuration base currency (USD), so
    -- importing a foreign-currency (e.g. UAH) bank transaction now requires a
    -- published rate for the pair — see 'Application.Services.BankImportService'.
    stubEnv :: !AppEnv
  }

-- | Allocate fresh, empty stub controls (no accounts, no statements) bound to
-- the supplied env (used to seed the persistent exchange-rate read model).
newStubControls :: AppEnv -> IO StubControls
newStubControls env =
  StubControls
    <$> newIORef (Right [])
    <*> newIORef Map.empty
    <*> pure env

-- | A single-provider 'BankProviderRegistry' (keyed @"monobank"@) whose
-- descriptor serves whatever fixtures the given 'StubControls' currently hold.
-- The @token@ passed to the pull constructor is ignored — the stub does no
-- real I/O.
stubRegistry :: StubControls -> BankProviderRegistry
stubRegistry controls =
  registryFromList
    [ BankProviderDescriptor
        { providerId = unsafeBankProviderId "monobank",
          displayName = "Stub",
          classify = \tx ->
            if tx.amount >= 0 then ClassifiedIncome else ClassifiedExpense,
          pull = Just $ \_token ->
            PullCapability
              { fetchAccounts = readIORef controls.stubAccounts,
                fetchStatements = \accId _from _to -> do
                  m <- readIORef controls.stubStatements
                  pure $ Right (Map.findWithDefault [] accId m),
                registerWebhook = \_ -> pure (Right ())
              },
          fileImport = Nothing
        }
    ]

-- -----------------------------------------------------------------------------
-- Banking-enabled + seeded harness
-- -----------------------------------------------------------------------------

-- | Build a banking-enabled, default-configuration-seeded 'Application'
-- wired to an in-memory stub provider.
--
-- This is the harness Tasks 7–9 use: it satisfies all three needs at once
-- that no existing helper does —
--
--   * @banking.enabled = True@ and the Monobank provider enabled
--     (unlike 'mkAppSeeded', which leaves banking disabled);
--   * the default configuration seeded so dictionaries/UUIDs exist
--     (unlike 'mkAppBankingEnabled', which is unseeded); and
--   * a stub provider factory installed so handlers never touch the network
--     (unlike 'mkAppBankingEnabled', which points at a dead @127.0.0.1:1@).
--
-- The deterministic test key ring already built into the base env is
-- preserved. Use 'mkAppBankingEnabledSeededWith' when a test needs to
-- pre-set the stub fixtures.
mkAppBankingEnabledSeeded :: IO Application
mkAppBankingEnabledSeeded = snd <$> mkAppBankingEnabledSeededWith

-- | Like 'mkAppBankingEnabledSeeded' but also returns the 'StubControls'
-- backing the installed provider so a test can pre-set the external accounts
-- and per-account statements the stub should serve.
mkAppBankingEnabledSeededWith :: IO (StubControls, Application)
mkAppBankingEnabledSeededWith = do
  env <- createTestAppEnv
  controls <- newStubControls env
  let cfg = env.config
      bankingCfg =
        BankingConfig
          { enabled = True,
            -- The runtime feature gate keys off the provider registry, not this
            -- map; only 'Main' reads it.
            providers = Map.empty,
            -- Preserve the deterministic test key ring already built into the
            -- base env; flipping the feature flag only touches the config.
            tokenEncKey = cfg.banking.tokenEncKey
          }
      cfg' = cfg {banking = bankingCfg}
      bankingEnv' =
        env.bankingEnv {bankProviderRegistry = stubRegistry controls}
      env' = env {config = cfg', bankingEnv = bankingEnv'}
  runAppM env' ConfigurationService.seedDefaultConfiguration
  pure (controls, buildApplication env')
