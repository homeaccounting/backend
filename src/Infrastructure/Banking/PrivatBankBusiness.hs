{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBankBusiness (descriptor) where

import qualified Domain.Banking.Types as Domain
import Domain.Localization.Country (unsafeCountry)
import Infrastructure.Banking.PrivatBankBusiness.Internal (fxSignal, parsePrivatBankBusinessXlsx)
import Infrastructure.Banking.Provider
import RIO
import qualified RIO.Map as Map
import qualified RIO.Set as Set

-- | PrivatBank business statement-file provider: file-import only (no public
-- pull API in this increment), XLSX format (the default Автоклієнт export),
-- sign-based classification and no label→category defaults. The transfer
-- matcher OR-composes the generic same-currency matcher with the FX
-- conversion matcher (via 'fxSignal'), so a currency conversion posts as one
-- cross-currency transfer.
descriptor :: BankProviderDescriptor
descriptor =
  BankProviderDescriptor
    { providerId = Domain.unsafeBankProviderId "privatbank-business",
      displayName = "PrivatBank (Business)",
      coverage = RegionalCoverage (Set.singleton (unsafeCountry "UA")),
      interpretation =
        TransactionInterpretation
          { classify = defaultClassify,
            transferMatcher =
              defaultTransferMatcher defaultTransferPairingWindow
                <> fxTransferMatcher fxSignal defaultFxPairingWindow,
            labelExpenseCategories = Map.empty
          },
      pull = Nothing,
      fileImport =
        Just
          FileImportCapability
            { parsers = Map.singleton StatementXlsx parsePrivatBankBusinessXlsx
            }
    }
