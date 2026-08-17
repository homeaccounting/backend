{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.PrivatBank
  ( descriptor,
    labelExpenseCategories,
    ownCardCounterpartLast4,
    privatBankInterpretation,
    privatBankTransferMatcher,
  )
where

import qualified Data.Map.Strict as Map
import Data.Time (NominalDiffTime)
import Domain.Banking.Types (unExternalAccountId)
import qualified Domain.Banking.Types as Domain
import Domain.Configuration.Defaults (DefaultEntry (entryId), ExpenseDefaults (..), expense)
import Domain.Core.Types (CategoryId)
import Infrastructure.Banking.PrivatBank.Internal (parsePrivatBankCsv, parsePrivatBankXlsx)
import Infrastructure.Banking.Provider
import RIO
import RIO.Char (isDigit)
import qualified RIO.Text as T

-- | Expose PrivatBank as a 'BankProviderDescriptor' with a file-import-only
-- transport: PrivatBank has no public statement API, so 'pull' is 'Nothing'
-- and 'fileImport' offers both export formats of the same @Історія операцій@
-- statement — the CSV parser under 'StatementCsv' and the native (default) XLSX
-- parser under 'StatementXlsx'. Unlike Monobank, there is no config/manager to
-- thread through — the descriptor is a pure value.
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
            { parsers =
                Map.fromList
                  [ (StatementCsv, parsePrivatBankCsv),
                    (StatementXlsx, parsePrivatBankXlsx)
                  ]
            }
    }

-- | Extract the last-4 digits of the counterpart card named in a PrivatBank
-- self-transfer row's description (e.g. @На свою картку *2222@ or @Зі своєї
-- картки *1111@). 'Nothing' for any row that is not a self-transfer.
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
  TransactionInterpretation
    { classify = defaultClassify,
      transferMatcher = privatBankTransferMatcher defaultTransferPairingWindow,
      labelExpenseCategories = labelExpenseCategories
    }

-- | PrivatBank's default mapping from its Ukrainian statement category labels
-- to expense category ids (spec §7). This is the single source of truth for the
-- provider's label defaults: it is both baked into a user's category map at
-- configuration-seed time (via 'Infrastructure.Banking.CategoryDefaults') and
-- exposed on the descriptor's 'TransactionInterpretation'. Only
-- expense-meaningful labels are mapped; transfer/income/cash-withdrawal labels
-- are omitted and fall through to the direction default at resolution time.
labelExpenseCategories :: Map Text CategoryId
labelExpenseCategories =
  Map.fromList
    [ ("Дім та ремонт", expense.household.entryId),
      ("Побутова техніка", expense.household.entryId),
      ("Комуналка та Інтернет", expense.utilities.entryId),
      ("Поповнення мобільного", expense.utilities.entryId),
      ("Супермаркети та продукти", expense.groceries.entryId),
      ("Ресторани, кафе, бари", expense.dining.entryId),
      ("Розваги", expense.entertainment.entryId),
      ("Кіно", expense.entertainment.entryId),
      ("Авто", expense.transport.entryId),
      ("Медичні послуги", expense.health.entryId),
      ("Краса", expense.beauty.entryId),
      ("Одяг та взуття", expense.clothing.entryId),
      ("Цифрові товари", expense.electronics.entryId),
      ("Інтернет-магазини", expense.shopping.entryId),
      ("Квіти", expense.gifts.entryId),
      ("Освіта", expense.education.entryId),
      ("Страхування", expense.insurance.entryId),
      ("Платежі до бюджету", expense.taxesFees.entryId),
      ("Інше", expense.other.entryId)
    ]
