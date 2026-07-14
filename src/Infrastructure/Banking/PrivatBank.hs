{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBank (descriptor) where

import qualified Data.Map.Strict as Map
import qualified Domain.Banking.Types as Domain
import Infrastructure.Banking.PrivatBank.Internal (parsePrivatBankCsv)
import Infrastructure.Banking.Provider
import RIO

-- | Expose PrivatBank as a 'BankProviderDescriptor' with a file-import-only
-- transport: PrivatBank has no public statement API, so 'pull' is 'Nothing'
-- and 'fileImport' wraps the CSV parser under 'StatementCsv'. Unlike
-- Monobank, there is no config/manager to thread through — the descriptor is
-- a pure value.
descriptor :: BankProviderDescriptor
descriptor =
  BankProviderDescriptor
    { providerId = Domain.unsafeBankProviderId "privatbank",
      displayName = "PrivatBank",
      classify = defaultClassify,
      pull = Nothing,
      fileImport =
        Just
          FileImportCapability
            { parsers = Map.singleton StatementCsv parsePrivatBankCsv
            }
    }
