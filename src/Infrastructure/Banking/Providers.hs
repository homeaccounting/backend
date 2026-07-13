{-# LANGUAGE CPP #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.Providers
-- Description : Root assembly point for compiled-in bank providers
--
-- The single place in the codebase that enumerates which bank providers are
-- compiled into this build and knows the 'PROVIDER_MONOBANK' CPP flag. Adding
-- or removing a provider is a one-line change to 'candidates' plus its Cabal
-- flag — @app/Main.hs@ never changes.
module Infrastructure.Banking.Providers (buildRegistry) where

import Infrastructure.Banking.Provider (BankProviderDescriptor)
import Infrastructure.Banking.Registry (BankProviderRegistry, assembleRegistry)
import Infrastructure.Config (BankingConfig)
#ifdef PROVIDER_MONOBANK
import qualified Infrastructure.Banking.Monobank as Monobank
#endif
import Network.HTTP.Client (Manager)

-- | Build the bank provider registry from every provider compiled into this
-- build, keeping only those enabled in config (see 'assembleRegistry').
buildRegistry :: BankingConfig -> Manager -> BankProviderRegistry
buildRegistry cfg manager = assembleRegistry cfg (candidates cfg manager)

-- | Candidate descriptors contributed by providers compiled into this build.
-- Each compiled-in provider (gated by its own Cabal flag, e.g. @monobank@)
-- builds one descriptor from the raw banking config here; 'assembleRegistry'
-- then keeps only those whose @banking.providers@ entry is present AND
-- enabled. This is the only place that needs a CPP guard per provider.
#ifdef PROVIDER_MONOBANK
candidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
candidates cfg manager = [Monobank.descriptorFromConfig cfg manager]
#else
candidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
candidates _cfg _manager = []
#endif
