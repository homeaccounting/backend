{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.BankImportService
-- Description : Orchestration service for bank transaction imports
--
-- This module implements the core orchestration logic for importing bank
-- transactions into the accounting system. It is transport-neutral: it consumes
-- a list of 'BankTransaction's (pulled by the caller via a 'PullCapability')
-- plus a @classify@ function, and creates 'InitiateTransactionPosting' commands.
--
-- Key Functions:
--   - importConnection: Fetch statements for a date range and import each transaction
--   - importMany: Shared import sink — route a flat list of transactions by
--     externalAccountId and delegate to importTransaction; transport-neutral,
--     used by both the pull path (importConnection) and file import
--   - importTransaction: Core import logic for a single bank transaction
--
-- The service handles:
--   - Deduplication via BankImportReadModel
--   - Account mapping via a caller-supplied [(ExternalAccountId, AccountId)] list
--   - Currency conversion from numeric codes
--   - Transaction classification (income/expense)
--   - MCC→CategoryId resolution from per-user banking configuration
--   - Transfer command creation and delegation to TransactionService
--
-- The 'hold' flag on incoming transactions is intentionally ignored — see
-- 'importTransaction' for details.
module Application.Services.BankImportService
  ( importConnection,
    importMany,
    importTransaction,
    ImportResult (..),
    AccountImportResult (..),
    ImportOutcome (..),
    SkipReason (..),
    renderSkipReason,
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.BankImportReadModel (isImported)
import Application.ReadModels.Configuration (ConfigurationData (..), dictionaryItemIds, dictionaryItems)
import qualified Application.ReadModels.User as UserRM
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Application.Services.TransactionService as TransactionService
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (ToJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text.Match (normalizeName)
import Data.Time (UTCTime, utctDay)
import Domain.Banking.Types (ExternalAccountId, unExternalAccountId)
import Domain.Configuration.Defaults (expenseCategoryDictKind, incomeCategoryDictKind)
import Domain.Configuration.Projection (BankingConfiguration (..), ConfigurationDefaults (..))
import Domain.Core.Errors (DomainError (..), renderDomainError)
import Domain.Core.Types
  ( AccountId,
    CategoryId,
    ContactId,
    ImportInfo (..),
    MCC,
    Money,
    TransactionId,
    TransactionKind (..),
    TransactionType (..),
    UserId,
    currencyFromNumericCode,
    kindOf,
    mkAllocation,
    mkExpenseAllocations,
    mkIncomeAllocations,
    mkMoney,
    moneyCurrency,
    unEntryName,
  )
import Domain.Transaction.Commands (InitiateTransactionPosting (..))
import Infrastructure.App
  ( AppM,
    runDb,
    withUserLock,
  )
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    PullCapability (..),
    TransactionClassification (..),
  )
import RIO
import RIO.List (sortOn)
import qualified RIO.Text as T

-- -----------------------------------------------------------------------------
-- Result Types
-- -----------------------------------------------------------------------------

-- | Why a bank transaction was intentionally not committed (distinct from a
-- write failure). Each constructor carries the human context that was
-- previously discarded to a log line.
data SkipReason
  = -- | Deduplication hit — the transaction is already imported.
    AlreadyImported
  | -- | The transaction's external account has no entry in the caller's link.
    Unmapped
  | -- | The numeric currency code could not be mapped to a known currency.
    UnsupportedCurrency !Text
  | -- | 'mkMoney' rejected the amount (rare).
    InvalidAmount !Text
  | -- | The local account's currency differs from the transaction's currency.
    CurrencyMismatch !Text
  deriving (Show, Eq)

-- | The outcome of attempting to import a single bank transaction.
data ImportOutcome
  = Imported !TransactionId
  | Skipped !SkipReason
  | Failed !DomainError
  deriving (Show, Eq)

-- | Render a skip reason as the user-facing text stored in
-- 'AccountImportResult.skipped' — mirrors how 'failed' renders a 'DomainError'
-- via 'renderDomainError'.
renderSkipReason :: SkipReason -> Text
renderSkipReason = \case
  AlreadyImported -> "already imported"
  Unmapped -> "no local account mapping for this transaction"
  UnsupportedCurrency msg -> "unsupported currency: " <> msg
  InvalidAmount msg -> "invalid amount: " <> msg
  CurrencyMismatch msg -> "currency mismatch: " <> msg

-- | Per-account outcome of an import call.
--
-- Captures the IDs of successfully imported transactions, the per-tx skips
-- (with their reasons), and the per-tx failures. @skipped@ and @failed@ hold
-- human-readable messages (rendered from 'SkipReason' via 'renderSkipReason'
-- and from 'DomainError' via 'renderDomainError' respectively, plus any
-- top-level fetch failure in @failed@). Using 'Text' keeps the type
-- JSON-serializable without dragging 'DomainError' or 'SkipReason' into the
-- response contract.
data AccountImportResult = AccountImportResult
  { externalAccountId :: !ExternalAccountId,
    localAccountId :: !AccountId,
    succeeded :: ![TransactionId],
    skipped :: ![Text],
    failed :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON AccountImportResult

-- | Aggregated result of an import call.
--
-- One 'AccountImportResult' per account in the caller-supplied link that had
-- at least one associated transaction, in the same order as 'importConnection'
-- (or, for 'importMany' called directly, the order accounts first appear
-- among the touched accounts). Failures in one account do not short-circuit
-- the others.
--
-- 'unresolved' is the file-level bucket for external account ids seen on an
-- input transaction but absent from the caller-supplied link — i.e. rows that
-- cannot be attributed to any mapped local account. It is transport-neutral:
-- the pull path ('importConnection') always builds its link from a
-- connection's own mapped accounts, so it stays @[]@; the file-import path
-- surfaces unmapped cards (and, at the Web layer, per-row parse errors) here
-- instead of silently dropping them.
data ImportResult = ImportResult
  { accounts :: ![AccountImportResult],
    unresolved :: ![Text]
  }
  deriving (Show, Eq, Generic)

instance ToJSON ImportResult

-- -----------------------------------------------------------------------------
-- Service Functions
-- -----------------------------------------------------------------------------

-- | Fetch statements for a date range and import each transaction.
--
-- For each account mapping supplied by the caller, fetches statements from
-- the provider and delegates the fetched transactions to 'importMany'. Returns
-- a structured per-account breakdown. A fetch failure for one account does not
-- abort processing of the other accounts; per-tx import failures are
-- collected into 'failures' rather than aborting the fetch's remaining
-- transactions.
--
-- Each account's link is scoped to just that @(externalAccountId,
-- localAccountId)@ pair when calling 'importMany', mirroring how a real
-- provider's @fetchStatements@ is itself scoped to one external account: every
-- returned transaction is expected to belong to it. This keeps
-- 'importConnection'\'s per-account breakdown (one row per link entry, even
-- when a fetch returns zero transactions) and guarantees 'unresolved' stays
-- @[]@ for a well-behaved provider.
importConnection ::
  (BankTransaction -> TransactionClassification) ->
  PullCapability ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  UTCTime ->
  UTCTime ->
  AppM ImportResult
importConnection classify pull userId accountLink fromTime toTime =
  withUserLock userId $ do
    logInfo $ "Importing bank transactions for user " <> displayShow userId
    perAccount <- forM accountLink processAccount
    let accountResults = map fst perAccount
        allUnresolved = Set.toList (Set.fromList (concatMap snd perAccount))
    pure (ImportResult {accounts = accountResults, unresolved = allUnresolved})
  where
    processAccount (extAccId, localAccId) = do
      fetchResult <- liftIO $ pull.fetchStatements extAccId fromTime toTime
      case fetchResult of
        Left err -> fetchFailed extAccId localAccId err
        Right txns -> fetchSucceeded extAccId localAccId txns

    fetchFailed extAccId localAccId err = do
      logWarn
        $ "Failed to fetch statements for account "
        <> display extAccId
        <> ": "
        <> display err
      pure
        ( AccountImportResult
            { externalAccountId = extAccId,
              localAccountId = localAccId,
              succeeded = [],
              skipped = [],
              failed = [err]
            },
          []
        )

    fetchSucceeded extAccId localAccId txns = do
      logInfo
        $ "Fetched "
        <> displayShow (length txns)
        <> " transactions for account "
        <> display extAccId
      result <- importMany classify userId [(extAccId, localAccId)] txns
      -- The scoped link above has exactly one entry, so 'accounts' holds at
      -- most one row; default to a zero-value row when the fetch returned no
      -- (or no matching) transactions, to preserve one row per link entry.
      let accountResult = case result.accounts of
            (a : _) -> a
            [] ->
              AccountImportResult
                { externalAccountId = extAccId,
                  localAccountId = localAccId,
                  succeeded = [],
                  skipped = [],
                  failed = []
                }
      pure (accountResult, result.unresolved)

-- | Shared import sink: route each transaction to its mapped local account
-- via the caller-supplied link and delegate to 'importTransaction'.
-- Transport-neutral — both the pull path ('importConnection') and a future
-- file-import path route their fetched\/parsed transactions through this
-- function.
--
-- A transaction whose 'externalAccountId' has no entry in @accountLink@ is
-- NOT committed; its raw external account id is collected into 'unresolved'
-- (deduplicated) instead. A matched transaction is delegated unchanged to
-- 'importTransaction' (dedup via 'isImported', classification, category
-- resolution — all unchanged), and results are grouped into one
-- 'AccountImportResult' per external account id that had at least one
-- matched transaction, carrying the local account it was routed to.
importMany ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  [BankTransaction] ->
  AppM ImportResult
importMany classify userId accountLink txns = do
  routed <- forM txns $ \tx ->
    case lookup tx.externalAccountId accountLink of
      Nothing -> pure (Left tx.externalAccountId)
      Just localAccId -> do
        outcome <- importTransaction classify userId accountLink tx
        pure (Right (tx.externalAccountId, localAccId, outcome))
  let (unmatched, matched) = partitionEithers routed
  pure
    ImportResult
      { accounts = groupAccountResults matched,
        unresolved = nubOrd (map unExternalAccountId unmatched)
      }

-- | Fold per-transaction outcomes into one 'AccountImportResult' per external
-- account id that had at least one matched transaction, in first-appearance
-- order (matching the 'ImportResult' Haddock contract) rather than the
-- lexicographic-by-id order a plain 'Map.elems' would yield.
groupAccountResults ::
  [(ExternalAccountId, AccountId, ImportOutcome)] ->
  [AccountImportResult]
groupAccountResults entries =
  map (grouped Map.!) orderedKeys
  where
    orderedKeys = nubOrd [extAccId | (extAccId, _, _) <- entries]
    grouped =
      Map.fromListWith
        merge
        [(extAccId, toAccountResult extAccId localAccId outcome) | (extAccId, localAccId, outcome) <- entries]
    toAccountResult extAccId localAccId outcome =
      case outcome of
        Failed err ->
          AccountImportResult
            { externalAccountId = extAccId,
              localAccountId = localAccId,
              succeeded = [],
              skipped = [],
              failed = [renderDomainError err]
            }
        Skipped reason ->
          AccountImportResult
            { externalAccountId = extAccId,
              localAccountId = localAccId,
              succeeded = [],
              skipped = [renderSkipReason reason],
              failed = []
            }
        Imported txId ->
          AccountImportResult
            { externalAccountId = extAccId,
              localAccountId = localAccId,
              succeeded = [txId],
              skipped = [],
              failed = []
            }
    -- 'Map.fromListWith merge' calls @merge new old@ for a colliding key, so
    -- the already-accumulated 'old' value stays first and 'new' is appended,
    -- preserving the transactions' original relative order.
    merge new old =
      old
        { succeeded = old.succeeded ++ new.succeeded,
          skipped = old.skipped ++ new.skipped,
          failed = old.failed ++ new.failed
        }

-- | How the resolver arrived at its 'CategoryId'.
--
-- Exposed alongside the resolved id so the caller can log the provenance
-- (MCC hit vs fallback) without re-deriving it.
data CategoryResolution
  = -- | An MCC present on the transaction matched the user's MCC map.
    MccHit !MCC
  | -- | Fell back to the direction-appropriate default category. Carries
    --   the transaction's MCC (if any) so the caller can spot unmapped
    --   MCCs worth adding to the map.
    DefaultFallback !(Maybe MCC)
  deriving (Show, Eq)

-- | Resolve the category for a transaction from the user's banking configuration.
--
-- Resolution order:
--   1. For expenses: look up tx.mcc in mccExpenseCategoryMap; verify the hit
--      exists in the expense dictionary. Income always skips the MCC map.
--   2. Fall back to the direction-appropriate banking default category.
--   3. If no default is configured, return a 'BankingError'.
resolveCategory ::
  BankingConfiguration ->
  ConfigurationData ->
  TransactionClassification ->
  Maybe MCC ->
  Either DomainError (CategoryId, CategoryResolution)
resolveCategory banking cfg direction maybeMcc =
  let ConfigurationDefaults {incomeCategory = mIncomeDefault, expenseCategory = mExpenseDefault} = cfg.defaults
      (dictKind, deflt) = case direction of
        ClassifiedIncome -> (incomeCategoryDictKind, mIncomeDefault)
        ClassifiedExpense -> (expenseCategoryDictKind, mExpenseDefault)
      dictItemIds =
        maybe Set.empty dictionaryItemIds (Map.lookup dictKind cfg.dictionaries)
      mccHit = case direction of
        ClassifiedExpense -> maybeMcc >>= \m -> (m,) <$> Map.lookup m banking.mccExpenseCategoryMap
        ClassifiedIncome -> Nothing
      existsInDict eid = Set.member eid dictItemIds
   in case mccHit of
        Just (mcc, eid) | existsInDict eid -> Right (eid, MccHit mcc)
        _ -> case deflt of
          Just eid -> Right (eid, DefaultFallback maybeMcc)
          Nothing ->
            Left
              $ BankingError
              $ "No banking "
              <> directionName direction
              <> " category configured"
  where
    directionName ClassifiedIncome = "income"
    directionName ClassifiedExpense = "expense"

-- | How the resolver arrived at its 'ContactId' (or lack thereof).
--
-- Exposed alongside the resolved value so the caller can log the provenance
-- without re-deriving it. There is no "created" case: contact resolution is
-- MATCH-ONLY — an unmatched description never creates a dictionary entry, it
-- simply leaves the transaction without a contact (the raw description
-- remains available as the transaction's memo).
data ContactResolution
  = -- | The normalized description matched an existing contact entry.
    MatchedExisting !ContactId
  | -- | No existing contact entry matched (or contact resolution does not
    --   apply to this transaction's kind).
    NoContactMatch
  deriving (Show, Eq)

-- | Resolve an existing contact for a transaction from the user's contact
-- dictionary, by a two-tier (normalized, case-insensitive) match on the bank
-- statement description: exact match first, substring match as a fallback
-- (see 'matchContact'). MATCH-ONLY: never creates a dictionary entry — a
-- non-matching description simply resolves to 'NoContactMatch' and the
-- transaction is left without a contact.
--
-- Contact resolution only applies to 'IncomeKind' and 'ExpenseKind'
-- transactions; transfers and adjustments never get a contact.
resolveContact :: ConfigurationData -> TransactionKind -> Text -> ContactResolution
resolveContact cfg kind description = case kind of
  TransferKind -> NoContactMatch
  AdjustmentKind -> NoContactMatch
  IncomeKind -> matchContact cfg description
  ExpenseKind -> matchContact cfg description

-- | Two-tier, normalized (trimmed, whitespace-collapsed, case-folded) match
-- of @description@ against the names in the user's contact dictionary:
--
--   1. __Exact match (top priority)__: a contact name equal to the whole
--      normalized description. The first such entry wins.
--   2. __Substring match (fallback, low priority)__: only tried when there is
--      no exact match. A contact name is a candidate when it is non-empty and
--      appears /within/ the normalized description (contact name is the
--      needle, description is the haystack — not the other way around).
--      Among candidates, the /longest/ matching name wins, since a longer
--      name is more specific and less likely to be a false positive. If two
--      or more candidates tie for the longest length, the match is ambiguous
--      and resolves to 'NoContactMatch' rather than guessing.
--
-- An empty normalized description never matches anything.
matchContact :: ConfigurationData -> Text -> ContactResolution
matchContact cfg description
  | T.null normalized = NoContactMatch
  | otherwise = case exactMatches of
      (eid : _) -> MatchedExisting eid
      [] -> case longestSubstringRanked of
        (eid, topLen) : rest
          | not (any ((== topLen) . snd) rest) -> MatchedExisting eid
        _ -> NoContactMatch
  where
    normalized = normalizeName description
    items =
      maybe [] dictionaryItems (Map.lookup ConfigurationService.contactsDictKind cfg.dictionaries)
    normalizedItems = [(eid, normalizeName (unEntryName name)) | (eid, name) <- items]
    exactMatches = [eid | (eid, n) <- normalizedItems, n == normalized]
    substringMatches =
      [ (eid, T.length n)
      | (eid, n) <- normalizedItems,
        not (T.null n),
        n `T.isInfixOf` normalized
      ]
    longestSubstringRanked = sortOn (Down . snd) substringMatches

-- | Emit a grep-friendly structured log line recording how (or whether) a
--   bank transaction was linked to an existing contact: the resolution
--   outcome (matched vs none) and the transaction's raw description, so an
--   operator can grep for @contact=NoContactMatch@ to spot merchants worth
--   adding as contacts.
logContactResolution ::
  BankTransaction ->
  ContactResolution ->
  AppM ()
logContactResolution tx resolution =
  logInfo
    $ "Contact resolved tx="
    <> display tx.externalId
    <> " resolution="
    <> display resolutionTag
    <> " merchant="
    <> display tx.description
  where
    resolutionTag :: Text
    resolutionTag = case resolution of
      MatchedExisting _ -> "MatchedExisting"
      NoContactMatch -> "NoContactMatch"

-- | Emit a grep-friendly structured log line recording how a bank transaction
--   was categorised: its MCC, the resolution path (MCC hit vs default
--   fallback), the resolved category id and its dictionary name.
--
-- Lets an operator grep for @resolution=DefaultFallback:unmapped-mcc@ to
-- surface MCCs worth adding to the user's map, or for a specific @mcc=…@
-- to audit individual decisions.
logCategoryResolution ::
  BankTransaction ->
  TransactionClassification ->
  ConfigurationData ->
  CategoryId ->
  CategoryResolution ->
  AppM ()
logCategoryResolution tx direction cfg categoryId resolution =
  logInfo
    $ "Category resolved tx="
    <> display tx.externalId
    <> " mcc="
    <> display mccField
    <> " resolution="
    <> display resolutionTag
    <> " category="
    <> display categoryName
    <> " merchant="
    <> display tx.description
  where
    dictKind = case direction of
      ClassifiedIncome -> incomeCategoryDictKind
      ClassifiedExpense -> expenseCategoryDictKind
    categoryName =
      maybe "<unknown>" unEntryName
        $ Map.lookup dictKind cfg.dictionaries
        >>= (lookup categoryId . dictionaryItems)
    resolutionTag :: Text
    resolutionTag = case resolution of
      MccHit _ -> "MccHit"
      DefaultFallback (Just _) -> "DefaultFallback:unmapped-mcc"
      DefaultFallback Nothing -> "DefaultFallback:no-mcc"
    mccField :: Text
    mccField = case resolution of
      MccHit m -> m
      DefaultFallback (Just m) -> m
      DefaultFallback Nothing -> "none"

-- | Core import logic for a single bank transaction.
--
-- The 'hold' flag is deliberately ignored: in April 2026 Monobank stopped
-- transitioning many accounts out of hold, so filtering on it caused recent
-- transactions to never reach the read model. The downside is that an
-- amount adjusted at settlement (tip, FX correction) won't update the
-- imported transfer — users can correct those manually.
--
-- Flow:
--   1. Check deduplication via BankImportReadModel
--   2. Match external account to local account via the supplied mappings
--   3. Look up user's External account from the User read model
--   4. Convert currency from numeric code
--   5. Take absolute value of major-unit amount
--   6. Classify transaction (income/expense)
--   7. Resolve category from user's banking configuration
--   8. Create and execute InitiateTransactionPosting command
importTransaction ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  BankTransaction ->
  AppM ImportOutcome
importTransaction classify userId accountLink tx = do
  alreadyImported <- runDb $ isImported tx.externalId
  if alreadyImported
    then do
      logDebug $ "Skipping already-imported transaction: " <> display tx.externalId
      pure (Skipped AlreadyImported)
    else case lookup tx.externalAccountId accountLink of
      Nothing -> do
        logWarn $ "No account mapping for external account: " <> display tx.externalAccountId
        pure (Skipped Unmapped)
      Just localAccId -> importMatchedTransaction classify userId localAccId tx

-- | Continue an import after the cheap dispatcher checks have matched the
-- external account. Handles the two remaining skip-paths (unsupported currency
-- code → 'UnsupportedCurrency', money construction failure → 'InvalidAmount')
-- and the missing-user failure before delegating the genuinely-fallible work to
-- 'commitImport'. A 'Left' from 'commitImport' becomes a 'Failed' outcome.
importMatchedTransaction ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  AccountId ->
  BankTransaction ->
  AppM ImportOutcome
importMatchedTransaction classify userId localAccId tx = do
  maybeUser <- runDb (UserRM.getUser userId)
  case maybeUser of
    Nothing -> do
      logWarn $ "User not found: " <> displayShow userId
      pure (Failed (NotFound "User" (tshow userId)))
    Just userData ->
      case currencyFromNumericCode tx.currencyCode of
        Left err -> do
          logWarn $ "Unsupported currency code " <> displayShow tx.currencyCode <> ": " <> display err
          pure (Skipped (UnsupportedCurrency err))
        Right currency ->
          case mkMoney currency (abs tx.amount) of
            Left err -> do
              logWarn $ "Failed to create money: " <> display err
              pure (Skipped (InvalidAmount err))
            Right money ->
              either Failed id <$> runExceptT (commitImport classify userId userData localAccId tx money)

-- | Commit the genuinely-fallible suffix of the import: configuration lookup,
-- category resolution, and transfer initiation. All errors short-circuit via
-- 'ExceptT', so this layer reads as a flat sequence of binds.
commitImport ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  UserRM.UserData ->
  AccountId ->
  BankTransaction ->
  Money ->
  ExceptT DomainError AppM ImportOutcome
commitImport classify userId userData localAccId tx money = do
  let externalAccId = userData.externalAccountId
      direction = classify tx
      txCurrency = moneyCurrency money
  -- Guard: a card's transactions can only be imported into a local account of
  -- the SAME currency (a UAH card → a UAH account). Mapping a card to a
  -- different-currency local account is unsupported. Detect it up front and
  -- SKIP the transaction with a clear reason, rather than initiating it and
  -- letting the posting saga fail with a cryptic 'CurrencyMismatch'.
  localData <-
    ExceptT
      $ maybe (Left (NotFound "Account" (tshow localAccId))) Right
      <$> runDb (AccountRM.getAccount localAccId)
  let localCurrency = moneyCurrency localData.balance
  if localCurrency /= txCurrency
    then do
      lift
        $ logWarn
        $ "Skipping bank tx "
        <> display tx.externalId
        <> ": account '"
        <> display localData.name
        <> "' is "
        <> displayShow localCurrency
        <> " but the transaction is "
        <> displayShow txCurrency
        <> ". Map this card to a "
        <> displayShow txCurrency
        <> " account."
      pure
        ( Skipped
            ( CurrencyMismatch
                ( "account '"
                    <> localData.name
                    <> "' is "
                    <> tshow localCurrency
                    <> " but the transaction is "
                    <> tshow txCurrency
                )
            )
        )
    else commitMatchingCurrencyImport userId externalAccId localAccId tx money direction

-- | Continue an import once the LOCAL account's currency has been confirmed to
-- match the transaction currency. Handles configuration lookup, category
-- resolution, and transfer initiation. The source/target ACCOUNT currencies may
-- still differ (e.g. local UAH → External USD), which 'resolveAmounts' handles.
commitMatchingCurrencyImport ::
  UserId ->
  AccountId ->
  AccountId ->
  BankTransaction ->
  Money ->
  TransactionClassification ->
  ExceptT DomainError AppM ImportOutcome
commitMatchingCurrencyImport userId externalAccId localAccId tx money direction = do
  cfg <- ExceptT $ do
    result <- ConfigurationService.getConfigurationForUser userId
    case result of
      Left err -> do
        logWarn $ "Failed to load configuration for user " <> displayShow userId <> ": " <> displayShow err
        pure (Left err)
      Right c -> pure (Right c)
  (categoryId, resolution) <- case resolveCategory cfg.banking cfg direction tx.mcc of
    Left err -> do
      lift $ logWarn $ "Category resolution failed for tx " <> display tx.externalId <> ": " <> displayShow err
      throwE err
    Right ok -> pure ok
  lift $ logCategoryResolution tx direction cfg categoryId resolution
  allocation <- case mkAllocation categoryId money Nothing of
    Right a -> pure a
    Left err -> do
      lift $ logWarn $ "Allocation construction failed for tx " <> display tx.externalId <> ": " <> displayShow err
      throwE err
  -- The single resolved allocation goes into the bucket matching the flow
  -- direction: income categories on income, expense categories on expense.
  let allocations = case direction of
        ClassifiedIncome -> mkIncomeAllocations (allocation :| [])
        ClassifiedExpense -> mkExpenseAllocations (allocation :| [])
      (sourceAccId, targetAccId, transactionType) =
        classifyEndpoints localAccId externalAccId direction allocations
      -- Contact resolution runs on the same 'ConfigurationData' already loaded
      -- above (no second config fetch), keyed off the resolved
      -- 'TransactionKind' rather than 'direction' so it stays restricted to
      -- Income/Expense even if a future call site here ever produces a
      -- Transfer/Adjustment 'TransactionType'.
      contactResolution = resolveContact cfg (kindOf transactionType) tx.description
  lift $ logContactResolution tx contactResolution
  -- Resolve per-leg amounts and the historical exchange rate exactly like the
  -- manual income/expense flow ('TransactionService.resolveAmounts'). The
  -- External account is created in the user's BASE currency, which can differ
  -- from the bank transaction's currency; without this, the External leg would
  -- post an amount in the wrong currency and the posting saga would reject it
  -- with 'CurrencyMismatch'. See 'resolveAmounts' for same-currency handling
  -- (returns the amount unchanged with a 'Nothing' rate) and nearest-date
  -- fallback semantics.
  srcData <-
    ExceptT
      $ maybe (Left (NotFound "Account" (tshow sourceAccId))) Right
      <$> runDb (AccountRM.getAccount sourceAccId)
  tgtData <-
    ExceptT
      $ maybe (Left (NotFound "Account" (tshow targetAccId))) Right
      <$> runDb (AccountRM.getAccount targetAccId)
  let srcCurrency = moneyCurrency srcData.balance
      tgtCurrency = moneyCurrency tgtData.balance
      -- The known bank amount 'money' is in the LOCAL account's currency. For
      -- an expense the local account is the source leg; for an income it is
      -- the target leg.
      userAmountIsSource = direction == ClassifiedExpense
      rateDay = utctDay tx.time
  (srcAmt, tgtAmt, rate) <-
    ExceptT (TransactionService.resolveAmounts money srcCurrency tgtCurrency userAmountIsSource Nothing rateDay)
  let cmd = buildTransferCmd userId tx sourceAccId targetAccId srcAmt tgtAmt rate transactionType contactResolution
  (txId, _) <- ExceptT (TransactionService.initiateTransaction cmd)
  lift $ logInfo $ "Imported transaction " <> display tx.externalId <> " as " <> displayShow txId
  pure (Imported txId)
  where
    classifyEndpoints localAcc externalAcc dir allocs =
      case dir of
        ClassifiedExpense ->
          (localAcc, externalAcc, Expense allocs)
        ClassifiedIncome ->
          (externalAcc, localAcc, Income allocs)

    buildTransferCmd uid bankTx sourceAccId targetAccId srcAmt tgtAmt rate transactionType contactResolution =
      InitiateTransactionPosting
        { sourceAccountId = sourceAccId,
          targetAccountId = targetAccId,
          sourceAmount = srcAmt,
          targetAmount = tgtAmt,
          exchangeRate = rate,
          description = bankTx.description,
          initiatedBy = uid,
          at = bankTx.time,
          transactionType = transactionType,
          importInfo =
            Just
              ImportInfo
                { externalTransactionId = bankTx.externalId,
                  mcc = bankTx.mcc
                },
          labels = Set.empty,
          contactId = case contactResolution of
            MatchedExisting cid -> Just cid
            NoContactMatch -> Nothing,
          relation = Nothing
        }
