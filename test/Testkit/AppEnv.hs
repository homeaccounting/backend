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
    mkAppBankingEnabledSeededWithFileProvider,
    mkAppSeeded,

    -- * Stub bank provider (for HTTP-level banking specs)
    StubControls (..),
    newStubControls,
    stubPullDescriptor,
    stubFileOnlyDescriptor,
  )
where

import qualified Application.Services.ConfigurationService as ConfigurationService
import Domain.Banking.Types (unExternalAccountId, unsafeBankProviderId)
import Infrastructure.App (AppEnv (..), BankingEnv (..), runAppM)
import Infrastructure.Banking.Provider
  ( BankAccount,
    BankProviderDescriptor (..),
    BankTransaction (..),
    FileImportCapability (..),
    ProviderCoverage (..),
    PullCapability (..),
    StatementFormat (..),
    defaultInterpretation,
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
    -- importing a bank transaction in a currency other than the account's (e.g. UAH) now requires a
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

-- | A pull-capable stub provider (keyed @"monobank"@) whose descriptor serves
-- whatever fixtures the given 'StubControls' currently hold. The @token@
-- passed to the pull constructor is ignored — the stub does no real I/O.
stubPullDescriptor :: StubControls -> BankProviderDescriptor
stubPullDescriptor controls =
  BankProviderDescriptor
    { providerId = unsafeBankProviderId "monobank",
      displayName = "Stub",
      coverage = GlobalCoverage,
      interpretation = defaultInterpretation,
      pull = Just $ \_token ->
        PullCapability
          { fetchAccounts = readIORef controls.stubAccounts,
            fetchStatements = \accId _from _to -> do
              m <- readIORef controls.stubStatements
              pure $ Right (Map.findWithDefault [] (unExternalAccountId accId) m),
            registerWebhook = \_ -> pure (Right ())
          },
      fileImport = Nothing
    }

-- | A file-only stub provider (keyed @"privatbank"@, pre-reserved in
-- @config/test.yaml@ for the real provider): no pull/API transport, so
-- connections to it have no credential. Used to exercise the
-- token-optional-connection behaviour without waiting on the real PrivatBank
-- provider to land, and to exercise 'ConfigurationService.getConnectionFileImport'
-- against a real (if trivial) 'FileImportCapability' without pulling in the
-- real CSV parser.
stubFileOnlyDescriptor :: BankProviderDescriptor
stubFileOnlyDescriptor =
  BankProviderDescriptor
    { providerId = unsafeBankProviderId "privatbank",
      displayName = "Stub File-Only",
      coverage = GlobalCoverage,
      interpretation = defaultInterpretation,
      pull = Nothing,
      fileImport =
        Just
          FileImportCapability
            { parsers = Map.singleton StatementCsv (\_bytes -> Right [])
            }
    }

-- | The registry backing the banking-enabled test harnesses: one pull-capable
-- provider ('stubPullDescriptor') and one file-import-capable provider (keyed
-- @"privatbank"@). The file provider defaults to 'stubFileOnlyDescriptor' but
-- can be substituted — e.g. for the REAL
-- 'Infrastructure.Banking.PrivatBank.descriptor' — by specs that need to
-- exercise actual statement parsing end-to-end over HTTP, rather than
-- 'stubFileOnlyDescriptor'\'s trivial always-empty parser. The substitute
-- must still register under the @"privatbank"@ id (as the real descriptor
-- does) for 'Testkit.HspecWai'/'BankConnectionAPISpec'-style flows that add a
-- connection with @provider: "privatbank"@ to resolve it. Both transport
-- shapes are thus available to any test built on
-- 'mkAppBankingEnabledSeeded' / 'mkAppBankingEnabledSeededWith'.
stubRegistryWith :: StubControls -> BankProviderDescriptor -> BankProviderRegistry
stubRegistryWith controls fileDescriptor =
  registryFromList
    [ stubPullDescriptor controls,
      fileDescriptor
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
mkAppBankingEnabledSeededWith = mkAppBankingEnabledSeededWithFileProvider stubFileOnlyDescriptor

-- | Like 'mkAppBankingEnabledSeededWith' but lets the caller substitute the
-- file-import-capable provider descriptor registered under @"privatbank"@ —
-- e.g. the REAL 'Infrastructure.Banking.PrivatBank.descriptor', so a spec can
-- exercise actual statement parsing (real CSV fixture bytes) end-to-end over
-- HTTP instead of 'stubFileOnlyDescriptor'\'s trivial always-empty parser.
-- The pull-capable stub ("monobank", backed by the returned 'StubControls')
-- is still installed alongside it.
mkAppBankingEnabledSeededWithFileProvider :: BankProviderDescriptor -> IO (StubControls, Application)
mkAppBankingEnabledSeededWithFileProvider fileDescriptor = do
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
        env.bankingEnv {bankProviderRegistry = stubRegistryWith controls fileDescriptor}
      env' = env {config = cfg', bankingEnv = bankingEnv'}
  runAppM env' ConfigurationService.seedDefaultConfiguration
  pure (controls, buildApplication env')
