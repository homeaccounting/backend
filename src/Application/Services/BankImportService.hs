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
-- a list of 'BankTransaction's plus a provider 'TransactionInterpretation'
-- (a @classify@ direction function + a 'TransferMatcher'), and creates
-- 'InitiateTransactionPosting' commands.
--
-- Key Functions:
--   - importConnection: Fetch every linked account's statements, then import
--     the union in one pass (so an internal transfer between two of the
--     connection's accounts is paired into a single 'Transfer')
--   - importMany: Shared import sink — detect internal transfers via the
--     pairing pre-pass, then route the remaining transactions by
--     externalAccountId to importTransaction; transport-neutral, used by both
--     the pull path (importConnection) and the file-import path
--   - importTransaction: Core import logic for a single bank transaction
--   - importTransferPair: Post one 'Transfer' for a detected internal-transfer pair
--
-- The service handles:
--   - Deduplication via BankImportReadModel
--   - Account mapping via a caller-supplied [(ExternalAccountId, AccountId)] list
--   - Currency conversion from numeric codes
--   - Transaction classification (income/expense)
--   - BankProviderCategory→CategoryId resolution from per-user banking configuration
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

    -- * Category resolution (exposed for unit testing)
    resolveCategory,
    CategoryResolution (..),

    -- * Contact resolution (exposed for unit testing)
    resolveContact,
    ContactResolution (..),
  )
where

import Application.ReadModels.Account (AccountData (..))
import qualified Application.ReadModels.Account as AccountRM
import Application.ReadModels.BankImportReadModel (importAttributionCount, isImported)
import Application.ReadModels.Configuration (ConfigurationData (..), dictionaryItemIds, dictionaryItems)
import Application.ReadModels.Transaction
  ( LegSide (..),
    TransactionData (..),
    findReconciliationCandidates,
    findTransferReconciliationCandidates,
  )
import qualified Application.ReadModels.User as UserRM
import Application.Services.BankImport.TransferPairing
  ( InternalTransfer,
    creditLeg,
    creditLocalAccount,
    debitLeg,
    debitLocalAccount,
    pairInternalTransfers,
  )
import qualified Application.Services.ConfigurationService as ConfigurationService
import qualified Application.Services.TransactionService as TransactionService
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (ToJSON)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text.Match (normalizeName)
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, utctDay)
import Domain.Banking.Import (ExternalTransactionId, ImportInfo (..), importAttributionCapacity)
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact, renderBankProviderCategoryKey, renderBankProviderContactKey)
import Domain.Banking.Types (ExternalAccountId, unExternalAccountId)
import Domain.Configuration.Defaults (expenseCategoryDictKind, incomeCategoryDictKind)
import Domain.Configuration.Projection (BankingConfiguration (..), ConfigurationDefaults (..))
import Domain.Core.Errors (DomainError (..), renderDomainError)
import Domain.Core.Types (AccountId, CategoryId, ContactId, Currency, Money, TransactionId, TransactionKind (..), TransactionType (..), UserId, currencyFromNumericCode, kindOf, mkAllocation, mkExchangeRate, mkExpenseAllocations, mkIncomeAllocations, mkMoney, moneyCurrency, unEntryName, unMoney)
import Domain.Transaction.Commands (InitiateTransactionPosting (..))
import Domain.Transaction.Matching.Leg (Leg (..))
import Domain.Transaction.Matching.Reconciliation (ReconciliationOutcome (..), reconcile)
import Infrastructure.App
  ( AppM,
    runDb,
    withUserLock,
  )
import Infrastructure.Banking.Provider
  ( BankTransaction (..),
    PullCapability (..),
    TransactionClassification (..),
    TransactionInterpretation (..),
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
  | -- | A confident-but-ambiguous match — 2+ manual candidates — so not
    -- auto-reconciled; left for the user to resolve.
    AmbiguousReconciliation
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
  AmbiguousReconciliation -> "ambiguous duplicate; not auto-reconciled"

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
-- Runs in two phases so that internal transfers between two of the
-- connection's OWN accounts are detected and paired:
--
--   1. __Fetch__ every link entry's statements from the provider, keeping each
--      @(externalAccountId, localAccountId, Either err [BankTransaction])@.
--      A fetch failure for one account does not abort the others.
--   2. __Import__ the union of all successfully fetched transactions through a
--      SINGLE 'importMany' call over the full @accountLink@, so its pairing
--      pre-pass can see both legs of a transfer at once (per-account fetches
--      each only cover one side, so the earlier per-account 'importMany' could
--      never pair across accounts).
--
-- Because each account's fetch is scoped to it, every returned transaction
-- belongs to a linked account, so 'importMany' resolves them all and
-- 'unresolved' stays @[]@ for a well-behaved provider.
--
-- Results are then re-grouped back into the caller-facing contract: exactly
-- one 'AccountImportResult' per link entry, in @accountLink@ order (even when a
-- fetch returned zero transactions or failed). A detected transfer between two
-- accounts appears — carrying the same 'TransactionId' — under BOTH link rows.
-- A fetch failure folds its error text into that account's @failed@.
importConnection ::
  TransactionInterpretation ->
  PullCapability ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  UTCTime ->
  UTCTime ->
  AppM ImportResult
importConnection interpretation pull userId accountLink fromTime toTime = do
  logInfo $ "Importing bank transactions for user " <> displayShow userId
  fetched <- forM accountLink fetchOne
  let allTxns = concat [txns | (_, _, Right txns) <- fetched]
  result <- importMany interpretation userId accountLink allTxns
  let byExtId =
        Map.fromList
          [(eid, a) | a@(AccountImportResult {externalAccountId = eid}) <- result.accounts]
      accountResults = map (regroup byExtId) fetched
  pure (ImportResult {accounts = accountResults, unresolved = result.unresolved})
  where
    fetchOne (extAccId, localAccId) = do
      fetchResult <- liftIO $ pull.fetchStatements extAccId fromTime toTime
      case fetchResult of
        Left err ->
          logWarn
            $ "Failed to fetch statements for account "
            <> display extAccId
            <> ": "
            <> display err
        Right txns ->
          logInfo
            $ "Fetched "
            <> displayShow (length txns)
            <> " transactions for account "
            <> display extAccId
      pure (extAccId, localAccId, fetchResult)

    -- Take the imported row for this link entry (a transfer puts a row under
    -- both its accounts), or a zero row when the fetch returned nothing that
    -- resolved to it; then fold any fetch failure into that row's 'failed'.
    regroup byExtId (extAccId, localAccId, fetchResult) =
      let base@(AccountImportResult {failed = existing}) =
            fromMaybe (zeroRow extAccId localAccId) (Map.lookup extAccId byExtId)
       in case fetchResult of
            Left err -> base {failed = existing ++ [err]}
            Right _ -> base

    zeroRow extAccId localAccId =
      AccountImportResult
        { externalAccountId = extAccId,
          localAccountId = localAccId,
          succeeded = [],
          skipped = [],
          failed = []
        }

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
  TransactionInterpretation ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  [BankTransaction] ->
  AppM ImportResult
importMany interpretation userId accountLink txns =
  withUserLock userId $ do
    let classify = interpretation.classify
        routed =
          [ (tx.externalAccountId, localAccId, tx)
          | tx <- txns,
            Just localAccId <- [lookup tx.externalAccountId accountLink]
          ]
        unmatched = [tx.externalAccountId | tx <- txns, isNothing (lookup tx.externalAccountId accountLink)]
        (pairs, unorderedLeftovers) = pairInternalTransfers interpretation.transferMatcher routed
        -- 'pairInternalTransfers' sorts its input internally for deterministic
        -- pairing; restore the caller's original transaction order for the
        -- unpaired remainder so 'ImportResult' stays input-ordered (exactly as it
        -- was before pairing was introduced) — the per-account breakdown and its
        -- consumers rely on that order.
        leftoverIds = Set.fromList [tx.externalId | (_, _, tx) <- unorderedLeftovers]
        leftovers = [entry | entry@(_, _, tx) <- routed, tx.externalId `Set.member` leftoverIds]
    pairEntries <- concat <$> forM pairs (importTransferPair classify userId accountLink)
    leftoverEntries <- forM leftovers $ \(extAccId, localAccId, tx) -> do
      outcome <- importTransaction classify userId accountLink tx
      pure (extAccId, localAccId, outcome)
    pure
      ImportResult
        { accounts = groupAccountResults (pairEntries <> leftoverEntries),
          unresolved = nubOrd (map unExternalAccountId unmatched)
        }

-- | Import a detected internal-transfer pair.
--
-- If EITHER leg is already imported (dedup hit), the pair is unwound and each
-- leg is imported individually via 'importTransaction' — the already-imported
-- leg falls through to 'Skipped AlreadyImported' and its partner is booked as a
-- plain income/expense, preserving the pre-pairing behaviour when one side was
-- synced earlier. Otherwise both fresh legs are collapsed into a single
-- 'Transfer' via 'postInternalTransfer', with the SAME 'ImportOutcome' reported
-- against both external account ids so the caller's per-account breakdown shows
-- the transfer on both sides.
importTransferPair ::
  (BankTransaction -> TransactionClassification) ->
  UserId ->
  [(ExternalAccountId, AccountId)] ->
  InternalTransfer ->
  AppM [(ExternalAccountId, AccountId, ImportOutcome)]
importTransferPair classify userId accountLink transfer = do
  let dLeg = debitLeg transfer
      cLeg = creditLeg transfer
      dLocal = debitLocalAccount transfer
      cLocal = creditLocalAccount transfer
      bothLegs out = pure [(dLeg.externalAccountId, dLocal, out), (cLeg.externalAccountId, cLocal, out)]
      postFresh = postInternalTransfer userId dLocal cLocal dLeg cLeg >>= bothLegs
  dImported <- runDb (isImported dLeg.externalId)
  cImported <- runDb (isImported cLeg.externalId)
  if dImported || cImported
    then do
      dOut <- importTransaction classify userId accountLink dLeg
      cOut <- importTransaction classify userId accountLink cLeg
      pure [(dLeg.externalAccountId, dLocal, dOut), (cLeg.externalAccountId, cLocal, cOut)]
    else case currencyFromNumericCode dLeg.currencyCode >>= \c -> mkMoney c (abs dLeg.amount) of
      -- Currency/amount resolution failure: let postInternalTransfer produce the
      -- proper Skip (UnsupportedCurrency / InvalidAmount) — don't duplicate that here.
      Left _ -> postFresh
      -- Reconciliation keys on the DEBIT leg's 'Money' only (matched against a
      -- manually-entered transfer's source amount, within the window). This is
      -- deliberately the debit leg alone: a cross-currency conversion still
      -- reconciles onto a manual transfer whose source (debit) leg matches, and
      -- otherwise falls through to 'postFresh'. (The candidate query does not
      -- inspect the credit leg's currency, so the debit-side match is the sole
      -- reconciliation key regardless of same- vs cross-currency.)
      Right money -> do
        let fromT = addUTCTime (negate reconciliationWindow) dLeg.time
            toT = addUTCTime reconciliationWindow dLeg.time
            importedLeg = Leg (unMoney money) (moneyCurrency money) dLeg.time
            label = textDisplay dLeg.externalId <> "/" <> textDisplay cLeg.externalId
        candidates <- runDb (findTransferReconciliationCandidates dLocal cLocal money fromT toT)
        result <-
          -- The full 'reconciliationWindow': this is a detected transfer pair
          -- matching a manually-entered transfer — same-kind reconciliation of
          -- the same movement, not the single-leg cross-kind attach that
          -- 'transferLegReconciliationWindow' tightens.
          attemptReconcile reconciliationWindow userId label importedLeg candidates (legOf SourceLeg) (dLeg.externalId :| [cLeg.externalId]) Nothing Nothing
        case result of
          ReconciledOnto tid -> bothLegs (Imported tid)
          ReconcileAmbiguous -> bothLegs (Skipped AmbiguousReconciliation)
          ReconcileNoMatch -> postFresh

-- | Post a fresh internal transfer between two of the user's own local accounts
-- as a single 'Transfer' (rather than double-booking an income + expense).
--
-- The two legs need NOT share a currency or a magnitude: a currency conversion
-- (a debit on one account + a credit on another, in different currencies)
-- posts as an ASYMMETRIC cross-currency 'Transfer' whose @sourceAmount@ is the
-- debit leg's money, @targetAmount@ is the credit leg's money, and
-- @exchangeRate@ is the implied rate (target magnitude / source magnitude).
-- When both legs happen to be the same currency the rate is 'Nothing' and the
-- two amounts are equal — the original same-currency internal transfer.
--
-- Mirrors the skip/failure vocabulary of the single-transaction path, applied
-- to BOTH legs: an unsupported currency code → 'Skipped UnsupportedCurrency';
-- money construction failure (or a non-positive implied rate) → 'Skipped
-- InvalidAmount'; a missing local account → 'Failed NotFound'; a local
-- account whose currency differs from its OWN leg → 'Skipped CurrencyMismatch'.
-- The command carries 'importInfo' with BOTH legs' external ids, which both
-- bypasses the overdraft guard and records the two-leg dedup mapping, so a
-- well-funded transfer between two real accounts posts.
--
-- Note: a currency mismatch on either account skips both legs (not just the
-- mismatched one); skips are not dedup-recorded, so fixing the account mapping
-- and re-importing recovers.
postInternalTransfer ::
  UserId ->
  AccountId ->
  AccountId ->
  BankTransaction ->
  BankTransaction ->
  AppM ImportOutcome
postInternalTransfer userId dLocal cLocal dLeg cLeg =
  either id id <$> runExceptT go
  where
    go :: ExceptT ImportOutcome AppM ImportOutcome
    go = do
      srcMoney <- resolveLegMoney dLeg
      tgtMoney <- resolveLegMoney cLeg
      dData <- loadAccount dLocal
      cData <- loadAccount cLocal
      -- Each account is guarded against its OWN leg's currency (the source
      -- account against the debit leg, the target against the credit leg),
      -- so a cross-currency conversion is valid as long as each side moves in
      -- its account's currency.
      guardCurrency dData srcMoney
      guardCurrency cData tgtMoney
      let srcCur = moneyCurrency srcMoney
          tgtCur = moneyCurrency tgtMoney
          srcMag = abs dLeg.amount
          tgtMag = abs cLeg.amount
      -- Same currency → symmetric transfer, no rate. Different currency → the
      -- implied rate (target magnitude / source magnitude); 'mkExchangeRate'
      -- rejects a non-positive rate as an invalid amount. The 'srcMag <= 0'
      -- guard keeps the division total on its own terms (the sign-opposing
      -- matcher already precludes a zero debit leg, but the function should not
      -- rely on that caller invariant for totality).
      rate <-
        if srcCur == tgtCur
          then pure Nothing
          else
            if srcMag <= 0
              then throwE (Skipped (InvalidAmount "source leg amount is zero; cannot derive exchange rate"))
              else case mkExchangeRate srcCur tgtCur (tgtMag / srcMag) of
                Left e -> throwE (Skipped (InvalidAmount e))
                Right r -> pure (Just r)
      let cmd =
            InitiateTransactionPosting
              { sourceAccountId = dLocal,
                targetAccountId = cLocal,
                sourceAmount = srcMoney,
                targetAmount = tgtMoney,
                exchangeRate = rate,
                description = dLeg.description,
                initiatedBy = userId,
                at = dLeg.time,
                transactionType = Transfer,
                importInfo =
                  Just
                    ImportInfo
                      { externalTransactionIds = dLeg.externalId :| [cLeg.externalId],
                        category = Nothing,
                        contact = Nothing
                      },
                labels = Set.empty,
                contactId = Nothing,
                relation = Nothing
              }
      result <- lift (TransactionService.initiateTransaction cmd)
      case result of
        Left err -> do
          lift $ logWarn $ "Internal transfer posting failed: " <> displayShow err
          pure (Failed err)
        Right (txId, _) -> do
          lift $ logInfo $ "Imported internal transfer " <> display dLeg.externalId <> "/" <> display cLeg.externalId <> " as " <> displayShow txId
          pure (Imported txId)

    -- Resolve a single leg's absolute amount into 'Money' in the leg's own
    -- currency, reusing the single-transaction path's skip vocabulary.
    resolveLegMoney leg = do
      currency <- case currencyFromNumericCode leg.currencyCode of
        Left err -> do
          lift $ logWarn $ "Unsupported currency code " <> displayShow leg.currencyCode <> ": " <> display err
          throwE (Skipped (UnsupportedCurrency err))
        Right c -> pure c
      case mkMoney currency (abs leg.amount) of
        Left err -> do
          lift $ logWarn $ "Failed to create money for internal transfer: " <> display err
          throwE (Skipped (InvalidAmount err))
        Right m -> pure m

    loadAccount accId =
      ExceptT $ do
        maybeData <- runDb (AccountRM.getAccount accId)
        case maybeData of
          Nothing -> pure (Left (Failed (NotFound "Account" (tshow accId))))
          Just d -> pure (Right d)

    guardCurrency accData money =
      let accCurrency = moneyCurrency accData.balance
          txCurrency = moneyCurrency money
       in when (accCurrency /= txCurrency) $ do
            lift
              $ logWarn
              $ "Skipping internal transfer: account '"
              <> display accData.name
              <> "' is "
              <> displayShow accCurrency
              <> " but the transfer is "
              <> displayShow txCurrency
            throwE
              ( Skipped
                  ( CurrencyMismatch
                      ( "account '"
                          <> accData.name
                          <> "' is "
                          <> tshow accCurrency
                          <> " but the transaction is "
                          <> tshow txCurrency
                      )
                  )
              )

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
-- (provider-category map hit vs fallback) without re-deriving it.
data CategoryResolution
  = -- | The transaction's provider category matched the user's category map.
    MapHit !BankProviderCategory
  | -- | Fell back to the direction-appropriate default category. Carries
    --   the transaction's provider category (if any) so the caller can spot
    --   unmapped categories worth adding to the map.
    DefaultFallback !(Maybe BankProviderCategory)
  deriving (Show, Eq)

-- | Resolve the category for a transaction from the user's banking configuration.
--
-- The provider-category → category matching is PER-DIRECTION: income consults
-- 'incomeCategoryMap' and expense consults
-- 'expenseCategoryMap'. Each direction looks up the transaction's
-- own provider category (MCC / label / counterparty) in its own map, so the
-- same signal can map to different categories depending on money direction.
--
-- Resolution is a SINGLE lookup: provider label defaults are baked into the
-- user's direction map at configuration-seed time, so the resolver needs only
-- the transaction's own provider category.
--
-- Resolution ladder (per direction):
--   1. Look up tx.category in the direction's category map and verify the hit is
--      an assignable item in the direction's dictionary. A future
--      description-keyword matcher slots in as an additional rung here.
--   2. Fall back to the direction-appropriate banking default category — for an
--      unmapped/absent category, or a hit whose target is not in the dictionary.
--   3. If no default is configured, return a 'BankingError'.
resolveCategory ::
  BankingConfiguration ->
  ConfigurationData ->
  TransactionClassification ->
  Maybe BankProviderCategory ->
  Either DomainError (CategoryId, CategoryResolution)
resolveCategory banking cfg direction maybeCategory =
  let ConfigurationDefaults {incomeCategory = mIncomeDefault, expenseCategory = mExpenseDefault} = cfg.defaults
      (dictKind, deflt, directionMap) = case direction of
        ClassifiedIncome -> (incomeCategoryDictKind, mIncomeDefault, banking.incomeCategoryMap)
        ClassifiedExpense -> (expenseCategoryDictKind, mExpenseDefault, banking.expenseCategoryMap)
      dictItemIds =
        maybe Set.empty dictionaryItemIds (Map.lookup dictKind cfg.dictionaries)
      -- Rung 1: the provider signal (MCC / label / counterparty) mapped in the
      -- direction's category map. A future description-keyword matcher slots in
      -- as an additional rung between here and the default fallback.
      mapHit = maybeCategory >>= \pc -> (pc,) <$> Map.lookup pc directionMap
      existsInDict eid = Set.member eid dictItemIds
   in case mapHit of
        Just (pc, eid) | existsInDict eid -> Right (eid, MapHit pc)
        _ -> case deflt of
          Just eid -> Right (eid, DefaultFallback maybeCategory)
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
  = -- | Resolved via the user's 'contactMap' (the provider
    --   signal). Takes priority over name matching.
    MatchedByMap !ContactId
  | -- | Resolved via description name matching against the contact
    --   dictionary (fallback — see 'matchContact').
    MatchedByName !ContactId
  | -- | No existing contact entry matched (or contact resolution does not
    --   apply to this transaction's kind).
    NoContactMatch
  deriving (Show, Eq)

-- | Resolve a contact for a transaction, layering the user's
-- 'contactMap' (the provider signal) over the description-based
-- name match ('matchContact'):
--
--   1. __Map hit (top priority)__: when @signal@ is present, mapped in
--      'contactMap', and the mapped 'ContactId' still exists in
--      the contact dictionary, that contact wins — even if the description
--      would otherwise name-match a /different/ contact.
--   2. __Name-match fallback__: when there is no signal, the signal is
--      unmapped, or the mapped id has since been removed from the
--      dictionary, fall back to 'matchContact' on the description. This is
--      the only path when 'contactMap' is empty, so today's
--      behaviour is preserved unchanged for providers/users without the map.
--
-- MATCH-ONLY: never creates a dictionary entry — an unresolved transaction
-- simply resolves to 'NoContactMatch' and is left without a contact.
--
-- Contact resolution only applies to 'IncomeKind' and 'ExpenseKind'
-- transactions; transfers and adjustments never get a contact, regardless of
-- signal.
resolveContact ::
  BankingConfiguration ->
  ConfigurationData ->
  TransactionKind ->
  Maybe BankProviderContact ->
  Text ->
  ContactResolution
resolveContact banking cfg kind signal description = case kind of
  TransferKind -> NoContactMatch
  AdjustmentKind -> NoContactMatch
  IncomeKind -> resolve
  ExpenseKind -> resolve
  where
    resolve = case mapHit of
      Just cid -> MatchedByMap cid
      Nothing -> matchContact cfg description
    -- A map hit only counts when the signal is present, mapped, AND the
    -- mapped contact is still a dictionary entry (a value removed from the
    -- dictionary after being mapped must not resolve to a dangling id).
    mapHit = do
      sig <- signal
      cid <- Map.lookup sig banking.contactMap
      if existsInContactDict cfg cid then Just cid else Nothing

-- | Whether a 'ContactId' is still present in the user's contact dictionary.
-- Mirrors the in-dictionary check 'resolveCategory' performs against the
-- expense-category dictionary, but against 'ConfigurationService.contactsDictKind'.
existsInContactDict :: ConfigurationData -> ContactId -> Bool
existsInContactDict cfg cid =
  Set.member cid (maybe Set.empty dictionaryItemIds (Map.lookup ConfigurationService.contactsDictKind cfg.dictionaries))

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
      (eid : _) -> MatchedByName eid
      [] -> case longestSubstringRanked of
        (eid, topLen) : rest
          | not (any ((== topLen) . snd) rest) -> MatchedByName eid
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
--   outcome (map hit vs name match vs none), the provider contact signal (or
--   @none@), and the transaction's raw description, so an operator can grep
--   for @resolution=NoMatch@ to spot merchants worth adding as contacts, or
--   for @contact=…@ to audit individual decisions.
logContactResolution ::
  BankTransaction ->
  ContactResolution ->
  AppM ()
logContactResolution tx resolution =
  logInfo
    $ "Contact resolved tx="
    <> display tx.externalId
    <> " contact="
    <> display contactField
    <> " resolution="
    <> display resolutionTag
    <> " merchant="
    <> display tx.description
  where
    resolutionTag :: Text
    resolutionTag = case resolution of
      MatchedByMap _ -> "MapHit"
      MatchedByName _ -> "NameMatch"
      NoContactMatch -> "NoMatch"
    contactField :: Text
    contactField = maybe "none" renderBankProviderContactKey tx.contact

-- | Emit a grep-friendly structured log line recording how a bank transaction
--   was categorised: its provider category, the resolution path (map hit vs
--   default fallback), the resolved category id and its dictionary name.
--
-- Lets an operator grep for @resolution=DefaultFallback:unmapped-category@ to
-- surface provider categories worth adding to the user's map, or for a specific
-- @category=…@ to audit individual decisions.
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
    <> " category="
    <> display categoryField
    <> " resolution="
    <> display resolutionTag
    <> " resolvedCategory="
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
      MapHit _ -> "MapHit"
      DefaultFallback (Just _) -> "DefaultFallback:unmapped-category"
      DefaultFallback Nothing -> "DefaultFallback:no-category"
    categoryField :: Text
    categoryField = case resolution of
      MapHit pc -> renderBankProviderCategoryKey pc
      DefaultFallback (Just pc) -> renderBankProviderCategoryKey pc
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
    else do
      let legSide = case direction of
            ClassifiedExpense -> SourceLeg
            ClassifiedIncome -> TargetLeg
          kind = case direction of
            ClassifiedExpense -> ExpenseKind
            ClassifiedIncome -> IncomeKind
          importedLeg = Leg (unMoney money) (moneyCurrency money) tx.time
      -- Same-kind candidates first; a Transfer leg only if none matched. A
      -- user-converted (or hand-entered) transfer carries the matching leg on
      -- this account, but its kind is TransferKind, so a single-leg import
      -- could never see it and posted a duplicate (backend#3).
      --
      -- Ordering the passes only DEFERS the transfer pass: no same-kind
      -- candidate is the common case (most imported rows have no hand-entered
      -- counterpart), so an ordinary expense routinely reaches the transfer
      -- pass and a lone same-amount transfer leg there is a UniqueMatch, not
      -- Ambiguous. The transfer pass therefore runs on the much tighter
      -- 'transferLegReconciliationWindow' — both for the SQL date bounds and
      -- for the pure matcher, or the tightening would be cosmetic — and every
      -- attach it makes is logged ('warnCrossKindReconcile'), because the
      -- window alone cannot separate a real transfer leg from an unrelated
      -- same-amount spend on the same day.
      let tryKind window k = do
            let fromT = addUTCTime (negate window) tx.time
                toT = addUTCTime window tx.time
            candidates <- runDb (findReconciliationCandidates localAccId legSide money k fromT toT)
            attemptReconcile window userId (textDisplay tx.externalId) importedLeg candidates (legOf legSide) (tx.externalId :| []) tx.category tx.contact
      sameKind <- lift (tryKind reconciliationWindow kind)
      result <- case sameKind of
        ReconcileNoMatch -> do
          crossKind <- lift (tryKind transferLegReconciliationWindow TransferKind)
          case crossKind of
            ReconciledOnto tid -> lift (warnCrossKindReconcile tx money tid)
            _ -> pure ()
          pure crossKind
        matched -> pure matched
      case result of
        ReconciledOnto tid -> pure (Imported tid)
        ReconcileAmbiguous -> pure (Skipped AmbiguousReconciliation)
        ReconcileNoMatch -> commitMatchingCurrencyImport userId externalAccId localAccId tx money direction

-- | Fuzzy-match window for manual↔import reconciliation: ±3 days (spec §1).
-- Wide on purpose: it reconciles an import against the SAME transaction entered
-- by hand, and a hand-entered date is approximate (a receipt typed in over the
-- weekend).
reconciliationWindow :: NominalDiffTime
reconciliationWindow = 3 * 86400

-- | Fuzzy-match window for attaching a single-leg import onto an existing
-- 'Transfer' leg: ±1 day.
--
-- Deliberately much tighter than 'reconciliationWindow'. That window exists for
-- date imprecision in a hand-entered copy of the same transaction; the transfer
-- pass is a different problem — the bank leg IS the movement the user recorded,
-- so a day is ample. The extra slack is pure risk there, because the transfer
-- pass runs whenever no same-kind candidate matched (the common case) and a lone
-- same-amount transfer leg is then a unique match: a genuinely unrelated spend
-- of a round amount would attach to the transfer, never post, and — dedup being
-- permanent by design — bind its external id to the transfer for good, leaving
-- the balance understated. ±1 day bounds how far that can reach
-- (ADR 006 "Out of scope").
transferLegReconciliationWindow :: NominalDiffTime
transferLegReconciliationWindow = 86400

-- | Record a cross-kind attach: an income/expense import that matched no
-- same-kind candidate and was attributed to an existing 'Transfer' leg instead.
--
-- Usually right — it is the transfer leg the user recorded by hand, which is
-- what the second pass exists for (backend#3). But it is also the one shape in
-- which an unrelated same-amount spend gets absorbed: it never posts, the
-- balance is understated by its amount, and bank-import dedup is permanent by
-- design, so its external id stays bound to the transfer. The window cannot
-- separate the two cases (a midnight-dated manual transfer and an evening bank
-- leg on the same day are already ~24h apart), so the trace is what makes the
-- residual risk discoverable instead of invisible. Grep @cross-kind reconcile@.
--
-- Not emitted for a same-kind reconcile, nor for the whole-pair transfer route:
-- those match like for like, and warning on the normal path would train the
-- operator to ignore the line.
warnCrossKindReconcile :: BankTransaction -> Money -> TransactionId -> AppM ()
warnCrossKindReconcile tx money tid =
  logWarn
    $ "cross-kind reconcile: import "
    <> display tx.externalId
    <> " ("
    <> displayShow (unMoney money)
    <> " "
    <> displayShow (moneyCurrency money)
    <> ") attached onto transfer "
    <> displayShow tid
    <> " — expected for a hand-entered transfer's leg, but an unrelated"
    <> " same-amount transaction would be absorbed the same way and never"
    <> " posted; check this transfer if a balance looks understated"

-- | Project a matched candidate's local leg into a 'Leg' for the pure matcher.
legOf :: LegSide -> TransactionData -> Leg Currency
legOf SourceLeg td = Leg (unMoney td.sourceAmount) (moneyCurrency td.sourceAmount) td.date
legOf TargetLeg td = Leg (unMoney td.targetAmount) (moneyCurrency td.targetAmount) td.date

-- | Outcome of the shared reconcile step, which each caller maps onto its own
-- 'ImportOutcome' shape.
data ReconcileResult
  = -- | Unique match — attribution attached onto this manual transaction.
    ReconciledOnto !TransactionId
  | -- | Two or more candidates matched — not auto-reconciled.
    ReconcileAmbiguous
  | -- | No candidate matched (or the attach itself failed) — import fresh.
    ReconcileNoMatch

-- | The shared reconcile step for both import paths (single transaction and
-- whole-pair transfer): exclude candidates without room for this attach, run
-- the pure matcher, and on a unique match attach the incoming external id(s)
-- + category + contact onto the matched manual transaction. Returns a 'ReconcileResult' the caller turns
-- into its own outcome. @label@ is a grep-friendly tag for the log lines (the
-- transaction's external id, or @"d/c"@ for a transfer pair).
--
-- @window@ is the caller's fuzzy-match tolerance, and must be the same value
-- the caller used for its SQL date bounds — the query narrows the candidates,
-- this matcher decides among them, and a mismatch would make the narrower of
-- the two the only one that counts.
attemptReconcile ::
  NominalDiffTime ->
  UserId ->
  Text ->
  Leg Currency ->
  [(TransactionId, TransactionData)] ->
  (TransactionData -> Leg Currency) ->
  NonEmpty ExternalTransactionId ->
  Maybe BankProviderCategory ->
  Maybe BankProviderContact ->
  AppM ReconcileResult
attemptReconcile window userId label importedLeg candidates projectLeg extIds category contact = do
  fresh <- filterM hasSpareAttribution candidates
  case reconcile window importedLeg [(tid, projectLeg td) | (tid, td) <- fresh] of
    NoMatch -> pure ReconcileNoMatch
    Ambiguous tids -> do
      logInfo $ "Ambiguous reconciliation for import " <> display label <> " (" <> displayShow (length tids) <> " candidates); skipping"
      pure ReconcileAmbiguous
    UniqueMatch tid -> do
      reconResult <- TransactionService.reconcileTransactionImport userId tid extIds category contact
      case reconResult of
        Right _ -> do
          logInfo $ "Reconciled import " <> display label <> " onto manual tx " <> displayShow tid
          pure (ReconciledOnto tid)
        Left err -> do
          logWarn $ "Reconcile of " <> display label <> " onto " <> displayShow tid <> " failed (" <> displayShow err <> "); importing fresh"
          pure ReconcileNoMatch
  where
    -- A candidate is eligible while this attach still fits its
    -- 'importAttributionCapacity': an income/expense holds one external id, a
    -- transfer two (one per leg), so a transfer that already absorbed one leg
    -- can still absorb the other. A boolean "already reconciled" test blocked
    -- that second leg and let it post a duplicate instead. It counts the ids
    -- THIS attach carries, so the whole-pair route (two ids at once) rules out
    -- a partly-attributed transfer here rather than being rejected by the
    -- aggregate afterwards and losing the other candidates with it. A leg
    -- re-arriving under its own id never reaches here — 'isImported' skips it
    -- first.
    --
    -- What this predicate shares with the transaction aggregate's reconcile
    -- guard is the CAPACITY rule ('importAttributionCapacity'), not the count:
    -- the two deliberately count from different sources. 'importAttributionCount'
    -- reads @imported_transactions@, which the projection fills from
    -- 'TransactionPostingInitiated'-with-importInfo AS WELL AS
    -- 'TransactionImportReconciled'; the aggregate folds only the latter. So an
    -- import-CREATED transaction has read-model count 1 and aggregate count 0.
    -- The read-model count is a superset, hence always the safe side — this
    -- filter is strictly more conservative than the aggregate, and for an
    -- import-created transaction the stricter answer is also the correct one
    -- (it already carries its own bank id; a second unrelated id has no
    -- business attaching). Do NOT "fix" the asymmetry by counting the
    -- aggregate's ids here: that would re-open a duplicate-posting path.
    hasSpareAttribution (tid, td) = do
      attributed <- runDb (importAttributionCount tid)
      pure (attributed + length extIds <= importAttributionCapacity td.transactionType)

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
  (categoryId, resolution) <- case resolveCategory cfg.banking cfg direction tx.category of
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
      contactResolution = resolveContact cfg.banking cfg (kindOf transactionType) tx.contact tx.description
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
                { externalTransactionIds = bankTx.externalId :| [],
                  category = bankTx.category,
                  contact = bankTx.contact
                },
          labels = Set.empty,
          contactId = case contactResolution of
            MatchedByMap cid -> Just cid
            MatchedByName cid -> Just cid
            NoContactMatch -> Nothing,
          relation = Nothing
        }
