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
#ifdef PROVIDER_PRIVATBANK
import qualified Infrastructure.Banking.PrivatBank as PrivatBank
#endif
#ifdef PROVIDER_PRIVATBANK_BUSINESS
import qualified Infrastructure.Banking.PrivatBankBusiness as PrivatBankBusiness
#endif
import Network.HTTP.Client (Manager)
import RIO ((<>))

-- | Build the bank provider registry from every provider compiled into this
-- build, keeping only those enabled in config (see 'assembleRegistry').
buildRegistry :: BankingConfig -> Manager -> BankProviderRegistry
buildRegistry cfg manager = assembleRegistry cfg (candidates cfg manager)

-- | Candidate descriptors contributed by providers compiled into this build:
-- the concatenation of each compiled-in provider's own candidate list.
-- 'assembleRegistry' then keeps only those whose @banking.providers@ entry
-- is present AND enabled. Adding a provider is a one-line addition to this
-- list plus its own @*Candidates@ definition below — existing providers'
-- CPP guards are untouched.
candidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
candidates cfg manager =
  monobankCandidates cfg manager <> privatbankCandidates <> privatbankBusinessCandidates

-- | Each compiled-in provider gets its own CPP-guarded candidate list, so
-- this is the only place that needs a CPP guard per provider.
#ifdef PROVIDER_MONOBANK
monobankCandidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
monobankCandidates cfg manager = [Monobank.descriptorFromConfig cfg manager]
#else
monobankCandidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
monobankCandidates _cfg _manager = []
#endif

#ifdef PROVIDER_PRIVATBANK
privatbankCandidates :: [BankProviderDescriptor]
privatbankCandidates = [PrivatBank.descriptor]
#else
privatbankCandidates :: [BankProviderDescriptor]
privatbankCandidates = []
#endif

#ifdef PROVIDER_PRIVATBANK_BUSINESS
privatbankBusinessCandidates :: [BankProviderDescriptor]
privatbankBusinessCandidates = [PrivatBankBusiness.descriptor]
#else
privatbankBusinessCandidates :: [BankProviderDescriptor]
privatbankBusinessCandidates = []
#endif
