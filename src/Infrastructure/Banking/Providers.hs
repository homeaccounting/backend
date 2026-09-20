{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.Providers
-- Description : Root assembly point for bank providers
--
-- Assembles the bank provider registry from all available providers. The
-- 'buildRegistry' function combines candidate descriptors from every provider
-- and filters them by the @banking.providers@ configuration (see
-- 'assembleRegistry'). Adding a provider is a one-line addition to 'candidates'
-- and its own @*Candidates@ definition — @app/Main.hs@ never changes.
module Infrastructure.Banking.Providers (buildRegistry) where

import qualified Infrastructure.Banking.Monobank as Monobank
import qualified Infrastructure.Banking.PrivatBank as PrivatBank
import qualified Infrastructure.Banking.PrivatBankBusiness as PrivatBankBusiness
import Infrastructure.Banking.Provider (BankProviderDescriptor)
import Infrastructure.Banking.Registry (BankProviderRegistry, assembleRegistry)
import Infrastructure.Config (BankingConfig)
import Network.HTTP.Client (Manager)
import RIO ((<>))

-- | Build the bank provider registry from every provider compiled into this
-- build, keeping only those enabled in config (see 'assembleRegistry').
buildRegistry :: BankingConfig -> Manager -> BankProviderRegistry
buildRegistry cfg manager = assembleRegistry cfg (candidates cfg manager)

-- | Candidate descriptors contributed by all providers, concatenated together.
-- 'assembleRegistry' then keeps only those whose @banking.providers@ entry is
-- enabled in the configuration. The set of providers is fixed at compile time
-- via 'monobankCandidates', 'privatbankCandidates', and
-- 'privatbankBusinessCandidates' below.
candidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
candidates cfg manager =
  monobankCandidates cfg manager <> privatbankCandidates <> privatbankBusinessCandidates

-- | Candidate descriptor from the Monobank provider.
monobankCandidates :: BankingConfig -> Manager -> [BankProviderDescriptor]
monobankCandidates cfg manager = [Monobank.descriptorFromConfig cfg manager]

-- | Candidate descriptor from the PrivatBank provider.
privatbankCandidates :: [BankProviderDescriptor]
privatbankCandidates = [PrivatBank.descriptor]

-- | Candidate descriptor from the PrivatBank business provider.
privatbankBusinessCandidates :: [BankProviderDescriptor]
privatbankBusinessCandidates = [PrivatBankBusiness.descriptor]
