{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Banking.Registry
-- Description : Lookup table of known bank provider descriptors
--
-- Wraps a list of 'BankProviderDescriptor's into a map keyed by their
-- stable 'BankProviderId', for lookup by callers (e.g. command handlers
-- resolving a provider from a validated id) and for exposing the known-id
-- set that 'Domain.Banking.Types.mkBankProviderId' validates against.
module Infrastructure.Banking.Registry
  ( BankProviderRegistry,
    registryFromList,
    assembleRegistry,
    lookupProvider,
    registryBankProviderIds,
  )
where

import qualified Data.Map.Strict as Map
import Domain.Banking.Types (BankProviderId)
import Infrastructure.Banking.Provider (BankProviderDescriptor (..))
import Infrastructure.Config (BankingConfig (..), providerEnabled)
import RIO

type BankProviderRegistry = Map BankProviderId BankProviderDescriptor

registryFromList :: [BankProviderDescriptor] -> BankProviderRegistry
registryFromList = Map.fromList . map (\d -> (d.providerId, d))

-- | Assemble a registry from the descriptors contributed by the compiled-in
-- providers, keeping only those whose own 'providerId' has a @providers@
-- entry in the banking config that is 'providerEnabled'.
--
-- The enabled-filter keys strictly off each descriptor's own 'providerId'
-- (the same id 'registryFromList' uses for the map key), so there is a single
-- source of truth for the id — the filter and the registration key can never
-- drift apart.
assembleRegistry :: BankingConfig -> [BankProviderDescriptor] -> BankProviderRegistry
assembleRegistry cfg descriptors =
  registryFromList
    [ d
    | d <- descriptors,
      Just s <- [Map.lookup d.providerId cfg.providers],
      providerEnabled s
    ]

lookupProvider :: BankProviderId -> BankProviderRegistry -> Maybe BankProviderDescriptor
lookupProvider = Map.lookup

registryBankProviderIds :: BankProviderRegistry -> Set BankProviderId
registryBankProviderIds = Map.keysSet
