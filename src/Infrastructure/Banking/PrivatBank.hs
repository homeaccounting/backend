{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBank
  ( descriptor,
    ownCardCounterpartLast4,
    privatBankInterpretation,
    privatBankTransferMatcher,
  )
where

import qualified Data.Map.Strict as Map
import Data.Time (NominalDiffTime)
import Domain.Banking.Types (unExternalAccountId)
import qualified Domain.Banking.Types as Domain
import Infrastructure.Banking.PrivatBank.Internal (parsePrivatBankCsv)
import Infrastructure.Banking.Provider
import RIO
import RIO.Char (isDigit)
import qualified RIO.Text as T

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
      interpretation = privatBankInterpretation,
      pull = Nothing,
      fileImport =
        Just
          FileImportCapability
            { parsers = Map.singleton StatementCsv parsePrivatBankCsv
            }
    }

-- | Extract the last-4 digits of the counterpart card named in a PrivatBank
-- self-transfer row's description (e.g. @На свою картку *9713@ or @Зі своєї
-- картки *1440@). 'Nothing' for any row that is not a self-transfer.
ownCardCounterpartLast4 :: BankTransaction -> Maybe Text
ownCardCounterpartLast4 tx =
  listToMaybe
    [ d
    | marker <- ["На свою картку *", "Зі своєї картки *"],
      Just rest <- [T.stripPrefix marker (T.strip tx.description)],
      let d = T.takeWhile isDigit rest,
      not (T.null d)
    ]

-- | PrivatBank transfer matcher: the generic amount/sign/currency/time checks,
-- plus a self-label check that one leg names the other leg's card by its
-- last-4 digits. This avoids pairing two unrelated equal-and-opposite legs.
privatBankTransferMatcher :: NominalDiffTime -> TransferMatcher
privatBankTransferMatcher window =
  TransferMatcher $ \a b ->
    (defaultTransferMatcher window).matchesTransfer a b
      && (namesOther a b || namesOther b a)
  where
    last4 = T.takeEnd 4 . T.filter isDigit . unExternalAccountId
    namesOther x y = ownCardCounterpartLast4 x == Just (last4 y.externalAccountId)

privatBankInterpretation :: TransactionInterpretation
privatBankInterpretation =
  TransactionInterpretation defaultClassify (privatBankTransferMatcher defaultTransferPairingWindow)
