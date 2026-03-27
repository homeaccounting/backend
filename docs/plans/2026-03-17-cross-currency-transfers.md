---
status: draft
---

# Cross-Currency Transfer Support Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enable cross-currency transfers by adding ECB exchange rate infrastructure and extending the transfer flow to carry separate source/target amounts.

**Architecture:** Universal cross-currency conversion in TransactionService. When source and target account currencies differ, the service resolves an exchange rate (from ECB cache or user-provided), converts the amount, and populates `sourceAmount`/`targetAmount` on the transfer command. TransferManager passes the correct currency amount to each account. Domain stays pure; conversion logic lives in the application/infrastructure layers.

**Tech Stack:** Haskell, Servant, Eventium (event sourcing), ECB XML feed via `http-client-tls`, `IORef` for rate cache, QuickCheck for property tests.

**Spec:** `docs/specs/2026-03-17-cross-currency-transfers-design.md`

**Prerequisites:**
- Database must be wiped and recreated after implementation (event schema changes are not backward-compatible).
- REST API response for transactions is a breaking change (`amount` → `sourceAmount`/`targetAmount`). Coordinate with frontend if applicable.

**Note on intermediate commits:** Tasks 4-11 modify interdependent types. Individual WIP commits may not compile. Consider squashing Tasks 4-11 into a single commit before pushing (or use a single commit at the end of Chunk 2). The plan uses per-task commits for progress tracking during development.

---

## Chunk 1: Domain Types & Exchange Rate Infrastructure

### Task 1: Add `ExchangeRate` domain type to `Domain.Core.Types`

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Modify: `test/Domain/Core/TypesPropertySpec.hs`
- Modify: `test/Testkit/Generators.hs`
- Modify: `test/Testkit/Helpers.hs`

- [ ] **Step 1: Write property tests for `ExchangeRate`**

Add to `test/Domain/Core/TypesPropertySpec.hs`:

```haskell
-- Generator (local to test file; canonical one added to Testkit in Step 5)
genPositiveRational :: Gen Rational
genPositiveRational = do
  n <- chooseInteger (1, 1000000)
  d <- chooseInteger (1, 1000000)
  pure (n % d)

genCurrency :: Gen Currency
genCurrency = elements [minBound .. maxBound]

genExchangeRate :: Gen ExchangeRate
genExchangeRate = do
  src <- genCurrency
  tgt <- elements [c | c <- [minBound..maxBound], c /= src]
  rate <- genPositiveRational
  pure $ unsafeExchangeRate src tgt rate  -- safe: rate is always positive from genPositiveRational

-- Properties
prop "rejects zero rate" $ do
  src <- forAll genCurrency
  tgt <- forAll $ elements [c | c <- [minBound..maxBound], c /= src]
  mkExchangeRate src tgt 0 `shouldSatisfy` isLeft

prop "rejects negative rate" $ do
  src <- forAll genCurrency
  tgt <- forAll $ elements [c | c <- [minBound..maxBound], c /= src]
  r <- forAll genPositiveRational
  mkExchangeRate src tgt (negate r) `shouldSatisfy` isLeft

prop "rejects same-currency pair" $ do
  c <- forAll genCurrency
  r <- forAll genPositiveRational
  mkExchangeRate c c r `shouldSatisfy` isLeft

prop "convert produces target currency" $ do
  er <- forAll genExchangeRate
  r <- forAll genPositiveRational
  let srcMoney = unsafeMoney (exchangeRateSource er) r
  moneyCurrency (convert er srcMoney) `shouldBe` exchangeRateTarget er

prop "convert preserves amount with rate 1" $ do
  src <- forAll genCurrency
  tgt <- forAll $ elements [c | c <- [minBound..maxBound], c /= src]
  let Right er = mkExchangeRate src tgt 1
  amt <- forAll genPositiveRational
  let srcMoney = unsafeMoney src amt
  unMoney (convert er srcMoney) `shouldBe` amt
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test all --test-option='--match' --test-option='/Domain.Core.Types/'`
Expected: Compilation failure — `ExchangeRate`, `mkExchangeRate`, `convert` not defined.

- [ ] **Step 3: Implement `ExchangeRate` type**

Add to `src/Domain/Core/Types.hs` module exports:
- `ExchangeRate`, `mkExchangeRate`, `unsafeExchangeRate`, `exchangeRateSource`, `exchangeRateTarget`, `exchangeRateValue`, `convert`

Add implementation:

```haskell
data ExchangeRate = ExchangeRate
  { source :: Currency,
    target :: Currency,
    rate :: Rational
  }
  deriving (Show, Eq, Generic)

instance ToJSON ExchangeRate where
  toJSON (ExchangeRate s t r) =
    object ["source" .= s, "target" .= t, "rate" .= (fromRational r :: Double)]

instance FromJSON ExchangeRate where
  parseJSON = withObject "ExchangeRate" $ \o -> do
    s <- o .: "source"
    t <- o .: "target"
    (d :: Double) <- o .: "rate"
    case mkExchangeRate s t (toRational d) of
      Right er -> pure er
      Left err -> fail (T.unpack err)

-- | Smart constructor. Rejects non-positive rates and same-currency pairs.
mkExchangeRate :: Currency -> Currency -> Rational -> Either Text ExchangeRate
mkExchangeRate src tgt r
  | src == tgt = Left "Source and target currencies must differ"
  | r <= 0 = Left "Exchange rate must be positive"
  | otherwise = Right (ExchangeRate src tgt r)

-- | Unsafe constructor for tests. Bypasses validation.
unsafeExchangeRate :: Currency -> Currency -> Rational -> ExchangeRate
unsafeExchangeRate = ExchangeRate

exchangeRateSource :: ExchangeRate -> Currency
exchangeRateSource (ExchangeRate s _ _) = s

exchangeRateTarget :: ExchangeRate -> Currency
exchangeRateTarget (ExchangeRate _ t _) = t

exchangeRateValue :: ExchangeRate -> Rational
exchangeRateValue (ExchangeRate _ _ r) = r

-- | Convert money using an exchange rate.
-- Input money's currency is ignored — the rate determines the conversion.
-- Output is in the rate's target currency.
-- Note: uses direct pattern match on Money since both types are in this module.
convert :: ExchangeRate -> Money -> Money
convert (ExchangeRate _ tgt r) (Money amt _) = Money (amt * r) tgt
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test all --test-option='--match' --test-option='/Domain.Core.Types/'`
Expected: All pass.

- [ ] **Step 5: Add generators and helpers to Testkit**

Add to `test/Testkit/Generators.hs`:

```haskell
genCurrency :: Gen Currency
genCurrency = elements [minBound .. maxBound]

genExchangeRate :: Gen ExchangeRate
genExchangeRate = do
  src <- genCurrency
  tgt <- elements [c | c <- [minBound..maxBound], c /= src]
  r <- genPositiveRational
  pure $ unsafeExchangeRate src tgt r
  where
    genPositiveRational = do
      n <- chooseInteger (1, 1000000)
      d <- chooseInteger (1, 1000000)
      pure (n % d)
```

Add to `test/Testkit/Helpers.hs`:

```haskell
-- | Mock exchange rate for tests. Uses unsafeExchangeRate (no validation).
mockExchangeRate :: Currency -> Currency -> Rational -> ExchangeRate
mockExchangeRate = unsafeExchangeRate
```

- [ ] **Step 6: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All pass.

- [ ] **Step 7: Commit**

```bash
git add src/Domain/Core/Types.hs test/Domain/Core/TypesPropertySpec.hs test/Testkit/Generators.hs test/Testkit/Helpers.hs
git commit -m "feat: add ExchangeRate domain type with smart constructor and convert"
```

---

### Task 2: Add ECB exchange rate client and cache

**Files:**
- Create: `src/Infrastructure/ExchangeRate.hs`
- Modify: `package.yaml` (add `xml-conduit` dependency)
- Create: `test/Infrastructure/ExchangeRateIntegrationSpec.hs`

- [ ] **Step 1: Add `xml-conduit` to `package.yaml` dependencies**

The project already has `http-client` and `http-client-tls`. Add `xml-conduit` for proper XML parsing (ECB returns XML):

```yaml
- xml-conduit >= 1.9 && < 1.10
```

Run `hpack` to regenerate cabal file.

- [ ] **Step 2: Write integration test for ECB client**

Create `test/Infrastructure/ExchangeRateIntegrationSpec.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.ExchangeRateIntegrationSpec (spec) where

import RIO
import Test.Hspec
import Domain.Core.Types (Currency (..), exchangeRateSource, exchangeRateTarget, exchangeRateValue)
import Infrastructure.ExchangeRate (fetchEcbRates, getRate)

spec :: Spec
spec = describe "Infrastructure.ExchangeRate" $ do
  describe "fetchEcbRates" $ do
    it "fetches rates from ECB and contains USD" $ do
      result <- fetchEcbRates
      case result of
        Left err -> pendingWith $ "ECB unavailable: " <> show err
        Right rates -> do
          let usdRate = getRate rates EUR USD
          usdRate `shouldSatisfy` isJust

    it "derives cross-rate UAH/USD" $ do
      result <- fetchEcbRates
      case result of
        Left err -> pendingWith $ "ECB unavailable: " <> show err
        Right rates -> do
          let rate = getRate rates UAH USD
          rate `shouldSatisfy` isJust
          case rate of
            Just er -> do
              exchangeRateSource er `shouldBe` UAH
              exchangeRateTarget er `shouldBe` USD
              exchangeRateValue er `shouldSatisfy` (> 0)
            Nothing -> pure ()
```

- [ ] **Step 3: Implement ECB client and cache**

Create `src/Infrastructure/ExchangeRate.hs`. Use RIO prelude (NoImplicitPrelude) and `xml-conduit` for XML parsing. Wrap `httpLbs` in `try` to catch network exceptions:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.ExchangeRate
  ( -- * Rate Map
    ExchangeRateMap,
    getRate,

    -- * ECB Client
    fetchEcbRates,

    -- * Cache
    ExchangeRateCache,
    newExchangeRateCache,
    getCachedRate,
    refreshCache,
  )
where

import RIO
import qualified RIO.Map as Map
import qualified RIO.Text as T
import Data.Maybe (listToMaybe)
import Data.Time (UTCTime, getCurrentTime, utctDay)
import Domain.Core.Types (Currency (..), ExchangeRate, mkExchangeRate, parseCurrency)
import Network.HTTP.Client (httpLbs, newManager, parseRequest, responseBody)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Text.Read (readMaybe)
import Text.XML (parseLBS, def)
import Text.XML.Cursor (fromDocument, ($//), (&|), attribute, element)

-- | Map of (source, target) -> ExchangeRate
type ExchangeRateMap = Map (Currency, Currency) ExchangeRate

-- | Look up a rate for a given currency pair.
getRate :: ExchangeRateMap -> Currency -> Currency -> Maybe ExchangeRate
getRate rates src tgt
  | src == tgt = Nothing
  | otherwise = Map.lookup (src, tgt) rates

-- | Fetch daily rates from ECB XML feed.
-- Returns EUR-based rates and all derived cross-rates.
-- Catches network exceptions and returns Left on failure.
fetchEcbRates :: IO (Either Text ExchangeRateMap)
fetchEcbRates = do
  result <- try @SomeException $ do
    manager <- newManager tlsManagerSettings
    request <- parseRequest ecbUrl
    responseBody <$> httpLbs request manager
  case result of
    Left ex -> pure $ Left $ "ECB fetch failed: " <> T.pack (show ex)
    Right body ->
      case parseLBS def body of
        Left ex -> pure $ Left $ "ECB XML parse failed: " <> T.pack (show ex)
        Right doc -> pure $ parseEcbDoc doc
  where
    ecbUrl = "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml"

-- | Parse ECB XML document into rate map.
parseEcbDoc :: Text.XML.Document -> Either Text ExchangeRateMap
parseEcbDoc doc =
  let cursor = fromDocument doc
      cubes = cursor $// element "{http://www.ecb.int/vocabulary/2002-08-01/eurofxref}Cube"
      eurRates = mapMaybe parseCube cubes
   in if null eurRates
        then Left "No rates found in ECB response"
        else Right $ buildRateMap eurRates
  where
    parseCube c = do
      curText <- listToMaybe $ attribute "currency" c
      rateText <- listToMaybe $ attribute "rate" c
      cur <- either (const Nothing) Just $ parseCurrency curText
      rate <- readMaybe (T.unpack rateText) :: Maybe Double
      guard (rate > 0)
      pure (cur, toRational rate)

-- | Build full rate map with cross-rates from EUR-based rates.
buildRateMap :: [(Currency, Rational)] -> ExchangeRateMap
buildRateMap eurRates =
  let eurToX = Map.fromList eurRates
      allCurrencies = EUR : map fst eurRates
      pairs = do
        src <- allCurrencies
        tgt <- allCurrencies
        guard (src /= tgt)
        let srcToEur = if src == EUR then 1 else case Map.lookup src eurToX of
              Just r -> 1 / r
              Nothing -> 0
        let eurToTgt = if tgt == EUR then 1 else case Map.lookup tgt eurToX of
              Just r -> r
              Nothing -> 0
        let crossRate = srcToEur * eurToTgt
        guard (crossRate > 0)
        case mkExchangeRate src tgt crossRate of
          Right er -> [((src, tgt), er)]
          Left _ -> []
   in Map.fromList pairs

-- | Exchange rate cache with daily refresh.
data ExchangeRateCache = ExchangeRateCache
  { cacheRef :: !(IORef (Maybe (UTCTime, ExchangeRateMap)))
  }

-- | Create a new empty cache.
newExchangeRateCache :: IO ExchangeRateCache
newExchangeRateCache = ExchangeRateCache <$> newIORef Nothing

-- | Refresh the cache by fetching from ECB.
refreshCache :: ExchangeRateCache -> IO (Either Text ())
refreshCache (ExchangeRateCache ref) = do
  result <- fetchEcbRates
  case result of
    Left err -> pure (Left err)
    Right rates -> do
      now <- getCurrentTime
      writeIORef ref (Just (now, rates))
      pure (Right ())

-- | Get a cached rate. Refreshes if cache is from a previous day.
getCachedRate :: ExchangeRateCache -> Currency -> Currency -> IO (Either Text ExchangeRate)
getCachedRate cache@(ExchangeRateCache ref) src tgt
  | src == tgt = pure $ Left "Same currency, no conversion needed"
  | otherwise = do
      cached <- readIORef ref
      now <- getCurrentTime
      let needsRefresh = case cached of
            Nothing -> True
            Just (fetchTime, _) -> utctDay fetchTime /= utctDay now
      when needsRefresh $ void $ refreshCache cache
      cached' <- readIORef ref
      case cached' of
        Nothing -> pure $ Left "Exchange rates unavailable"
        Just (_, rates) ->
          case getRate rates src tgt of
            Just er -> pure (Right er)
            Nothing -> pure $ Left $ "No rate available for " <> tshow src <> " -> " <> tshow tgt
```

- [ ] **Step 4: Run integration test**

Run: `cabal test all --test-option='--match' --test-option='/Infrastructure.ExchangeRate/'`
Expected: Pass (or pending if ECB is unreachable).

- [ ] **Step 5: Commit**

```bash
git add src/Infrastructure/ExchangeRate.hs test/Infrastructure/ExchangeRateIntegrationSpec.hs package.yaml
git commit -m "feat: add ECB exchange rate client with daily cache"
```

---

### Task 3: Add `ExchangeRateCache` to `AppEnv`

**Files:**
- Modify: `src/Infrastructure/App.hs:148-179` (AppEnv type, add field + HasX typeclass)
- Modify: `app/Main.hs:304-321` (initialize cache, pass to AppEnv)

- [ ] **Step 1: Add field to `AppEnv`**

In `src/Infrastructure/App.hs`, add to the `AppEnv` record:

```haskell
exchangeRateCache :: !ExchangeRateCache
```

Import `ExchangeRateCache` from `Infrastructure.ExchangeRate`.

- [ ] **Step 2: Add `HasExchangeRateCache` typeclass**

In `src/Infrastructure/App.hs`, following the existing `HasX` pattern:

```haskell
class HasExchangeRateCache env where
  getExchangeRateCache :: env -> ExchangeRateCache

instance HasExchangeRateCache AppEnv where
  getExchangeRateCache = (.exchangeRateCache)
```

- [ ] **Step 3: Initialize cache in `Main.hs`**

In `app/Main.hs`, after database initialization and before AppEnv construction:

```haskell
-- Initialize exchange rate cache (best-effort, app starts even if ECB is unreachable)
exchangeRateCache <- newExchangeRateCache
void $ refreshCache exchangeRateCache
```

Pass `exchangeRateCache` to `initializeAppEnv`. Update `initializeAppEnv` signature accordingly.

- [ ] **Step 4: Build to verify compilation**

Run: `cabal build`
Expected: Compiles successfully.

- [ ] **Step 5: Commit**

```bash
git add src/Infrastructure/App.hs app/Main.hs
git commit -m "feat: add ExchangeRateCache to AppEnv"
```

---

## Chunk 2: Transfer Command/Event/Projection/Service Changes

**Important:** Tasks 4-11 modify interdependent types. The project will not compile until all tasks in this chunk are complete. Commit progress per task but do not push until the chunk compiles.

### Task 4: Update `InitiateTransfer` command

**Files:**
- Modify: `src/Domain/Transaction/Commands.hs:79-94`

- [ ] **Step 1: Add `ExchangeRate` to imports**

Add `ExchangeRate` to the import from `Domain.Core.Types`.

- [ ] **Step 2: Replace `amount` with `sourceAmount`/`targetAmount`/`exchangeRate`**

```haskell
data InitiateTransfer = InitiateTransfer
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    reason :: Text,
    initiatedBy :: UserId,
    transferType :: TransferType,
    category :: TransferCategory
  }
  deriving (Show, Eq)
```

- [ ] **Step 3: Commit (WIP, will not compile)**

```bash
git add src/Domain/Transaction/Commands.hs
git commit -m "wip: update InitiateTransfer command with dual amounts"
```

---

### Task 5: Update `TransferInitiated` event

**Files:**
- Modify: `src/Domain/Transaction/Events.hs:64-80`

- [ ] **Step 1: Add `ExchangeRate` to imports**

Add `ExchangeRate` to the import from `Domain.Core.Types`.

- [ ] **Step 2: Replace `amount` with `sourceAmount`/`targetAmount`/`exchangeRate`**

```haskell
data TransferInitiated = TransferInitiated
  { fromAccountId :: AccountId,
    toAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    reason :: Text,
    by :: UserId,
    transferType :: TransferType,
    category :: TransferCategory
  }
  deriving (Show, Eq)
```

- [ ] **Step 3: Commit (WIP)**

```bash
git add src/Domain/Transaction/Events.hs
git commit -m "wip: update TransferInitiated event with dual amounts"
```

---

### Task 6: Update Transaction Projection

**Files:**
- Modify: `src/Domain/Transaction/Projection.hs:122-139` (Transaction state type)
- Modify: `src/Domain/Transaction/Projection.hs:161-178` (default state)
- Modify: `src/Domain/Transaction/Projection.hs:234-265` (event handler)

- [ ] **Step 1: Update `Transaction` state type**

Replace `amount :: Money` with:

```haskell
sourceAmount :: Money,
targetAmount :: Money,
exchangeRate :: Maybe ExchangeRate,
```

Add `ExchangeRate` to imports from `Domain.Core.Types`.

- [ ] **Step 2: Update `transactionDefault`**

Use `unsafeMoney USD 0` for both `sourceAmount` and `targetAmount`, `Nothing` for `exchangeRate`.

- [ ] **Step 3: Update `handleTransactionEvent`**

In the `TransferInitiatedEvent` handler, map the new event fields to the new state fields.

- [ ] **Step 4: Commit (WIP)**

```bash
git add src/Domain/Transaction/Projection.hs
git commit -m "wip: update Transaction projection for dual amounts"
```

---

### Task 7: Update Transaction CommandHandler

**Files:**
- Modify: `src/Domain/Transaction/CommandHandler.hs`

- [ ] **Step 1: Update `handleTransactionCommand` for `InitiateTransfer`**

Where `TransferInitiated` is constructed from `InitiateTransfer`, map the new fields:

```haskell
TransferInitiated
  { fromAccountId = cmd.fromAccountId,
    toAccountId = cmd.toAccountId,
    sourceAmount = cmd.sourceAmount,
    targetAmount = cmd.targetAmount,
    exchangeRate = cmd.exchangeRate,
    reason = cmd.reason,
    by = cmd.initiatedBy,
    transferType = cmd.transferType,
    category = cmd.category
  }
```

- [ ] **Step 2: Commit (WIP)**

```bash
git add src/Domain/Transaction/CommandHandler.hs
git commit -m "wip: update Transaction command handler for dual amounts"
```

---

### Task 8: Update TransferManager

**Files:**
- Modify: `src/Application/ProcessManagers/TransferManager.hs:103-115` (TransferData)
- Modify: `src/Application/ProcessManagers/TransferManager.hs:143-167` (handleTransferEvent)
- Modify: `src/Application/ProcessManagers/TransferManager.hs:193-223` (reactToTransferEvent)

- [ ] **Step 1: Update `TransferData`**

Replace `amount :: Money` with:

```haskell
sourceAmount :: Money,
targetAmount :: Money,
```

- [ ] **Step 2: Update `handleTransferEvent`**

In the `TransferInitiatedEvent` handler, store both amounts:

```haskell
TransferData
  { sourceAccount = evt.fromAccountId,
    targetAccount = evt.toAccountId,
    sourceAmount = evt.sourceAmount,
    targetAmount = evt.targetAmount,
    reason = evt.reason,
    phase = AwaitingDebit
  }
```

- [ ] **Step 3: Update `reactToTransferEvent`**

In the `TransferInitiatedEvent` handler, use `evt.sourceAmount` for DebitAccount:

```haskell
DebitAccount
  { amount = evt.sourceAmount,
    transactionId = txId,
    reason = evt.reason
  }
```

In the `AccountDebitedEvent` handler, use `targetAmount` from `TransferData` for CreditAccount:

```haskell
CreditAccount
  { amount = targetAmount,  -- from TransferData record wildcard match
    transactionId = evt.transactionId,
    reason = reason
  }
```

- [ ] **Step 4: Commit (WIP)**

```bash
git add src/Application/ProcessManagers/TransferManager.hs
git commit -m "wip: TransferManager uses sourceAmount/targetAmount for debit/credit"
```

---

### Task 9: Update Transaction ReadModel

**Files:**
- Modify: `src/Application/ReadModels/Transaction.hs:77-86` (TransactionData type)
- Modify: `src/Application/ReadModels/Transaction.hs:186-195` (processEvent)

- [ ] **Step 1: Update `TransactionData`**

Replace `amount :: Money` with:

```haskell
sourceAmount :: Money,
targetAmount :: Money,
exchangeRate :: Maybe ExchangeRate,
```

Add `ExchangeRate` to imports from `Domain.Core.Types`.

- [ ] **Step 2: Update `processEvent`**

In the `TransferInitiatedEvent` handler, populate the new fields from the event.

- [ ] **Step 3: Commit (WIP)**

```bash
git add src/Application/ReadModels/Transaction.hs
git commit -m "wip: update TransactionData read model for dual amounts"
```

---

### Task 10: Update TransactionService with cross-currency conversion

**Files:**
- Modify: `src/Application/Services/TransactionService.hs:87-114` (initiateTransfer)
- Modify: `src/Application/Services/TransactionService.hs:140-184` (initiateIncome)
- Modify: `src/Application/Services/TransactionService.hs:190-234` (initiateExpense)
- Modify: `src/Application/Services/TransactionService.hs:240-286` (initiateInternalTransfer)
- Modify: `src/Domain/Core/Errors.hs` (add `ExchangeRateUnavailable` variant)

- [ ] **Step 1: Add `ExchangeRateUnavailable` to `DomainError`**

In `src/Domain/Core/Errors.hs`, add a new variant:

```haskell
  | -- | Exchange rate unavailable for currency conversion
    ExchangeRateUnavailable Text
```

- [ ] **Step 2: Add currency conversion helper to TransactionService**

The key insight for rate direction:
- **Income:** user provides amount in **target** (Regular) currency. Need tgt→src rate to compute `sourceAmount`.
- **Expense:** user provides amount in **source** (Regular) currency. Need src→tgt rate to compute `targetAmount`.
- **InternalTransfer:** user provides amount in **source** currency. Need src→tgt rate to compute `targetAmount`.

```haskell
-- | Resolve amounts for a cross-currency transfer.
-- For same-currency: returns identical amounts with Nothing rate.
-- For different currencies: fetches rate and converts.
--
-- Parameters:
--   userAmount: the amount the user provided
--   userCurrency: which side (Source or Target) the user amount refers to
--   srcCurrency: source account currency
--   tgtCurrency: target account currency
--   maybeUserRate: optional user-provided exchange rate override
resolveAmounts ::
  (MonadReader env m, HasExchangeRateCache env, MonadIO m) =>
  Money ->
  Currency ->  -- source account currency
  Currency ->  -- target account currency
  Bool ->      -- True if userAmount is in source currency, False if in target currency
  Maybe Rational ->  -- optional user-provided rate (src -> tgt)
  m (Either DomainError (Money, Money, Maybe ExchangeRate))
resolveAmounts userAmount srcCurrency tgtCurrency userAmountIsSource maybeUserRate
  | srcCurrency == tgtCurrency =
      pure $ Right (userAmount, userAmount, Nothing)
  | otherwise = do
      -- Always resolve src->tgt rate
      rateResult <- case maybeUserRate of
        Just r -> pure $ mkExchangeRate srcCurrency tgtCurrency r
                    & first (ExchangeRateUnavailable)
        Nothing -> do
          cache <- asks getExchangeRateCache
          liftIO $ getCachedRate cache srcCurrency tgtCurrency
            <&> first ExchangeRateUnavailable
      case rateResult of
        Left err -> pure $ Left err
        Right er ->
          if userAmountIsSource
            then -- User gave source amount, compute target
              let tgtAmount = convert er userAmount
               in pure $ Right (userAmount, tgtAmount, Just er)
            else -- User gave target amount, compute source (use inverse rate)
              case mkExchangeRate tgtCurrency srcCurrency (1 / exchangeRateValue er) of
                Left err -> pure $ Left $ ExchangeRateUnavailable err
                Right inverseEr ->
                  let srcAmount = convert inverseEr userAmount
                   in pure $ Right (srcAmount, userAmount, Just er)
```

- [ ] **Step 3: Update `initiateIncome`**

User provides amount in Regular account (target) currency. The function already looks up `externalAccId`. To get currencies, extract from account balances via the read model:

```haskell
-- Get account currencies from read model (AccountData has balance :: Money)
-- externalAccount and targetAccount are already looked up in the current code
let srcCurrency = moneyCurrency (accountBalance externalAccountData)  -- USD
    tgtCurrency = moneyCurrency (accountBalance targetAccountData)    -- e.g., UAH

-- Validate user amount matches target (Regular) account currency
when (moneyCurrency amount /= tgtCurrency) $
  pure $ Left $ ValidationErr $ mkValidationError "amount" "Currency must match account currency" (tshow (moneyCurrency amount))

-- Resolve amounts: user gave target amount, need to compute source
resolveResult <- resolveAmounts amount srcCurrency tgtCurrency False Nothing
case resolveResult of
  Left err -> pure $ Left err
  Right (srcAmt, tgtAmt, rate) ->
    -- Construct InitiateTransfer with sourceAmount=srcAmt, targetAmount=tgtAmt, exchangeRate=rate
```

The function signature stays the same (no `Maybe Rational` parameter — income always uses ECB).

- [ ] **Step 4: Update `initiateExpense`**

User provides amount in Regular account (source) currency. Same pattern, but `userAmountIsSource = True`:

```haskell
let srcCurrency = moneyCurrency (accountBalance sourceAccountData)    -- e.g., UAH
    tgtCurrency = moneyCurrency (accountBalance externalAccountData)  -- USD

when (moneyCurrency amount /= srcCurrency) $
  pure $ Left $ ValidationErr $ mkValidationError "amount" "Currency must match account currency" (tshow (moneyCurrency amount))

resolveResult <- resolveAmounts amount srcCurrency tgtCurrency True Nothing
-- sourceAmount = user amount, targetAmount = converted
```

The function signature stays the same.

- [ ] **Step 5: Update `initiateInternalTransfer`**

Add `Maybe Rational` parameter for optional user-provided exchange rate. User provides amount in source account currency. Pass `userAmountIsSource = True`:

```haskell
initiateInternalTransfer ::
  UserId -> AccountId -> AccountId -> Money ->
  InternalCategory -> Text ->
  Maybe Rational ->  -- NEW: optional exchange rate override
  AppM (Either DomainError (TransactionId, TransactionData))
```

- [ ] **Step 6: Build to verify compilation**

Run: `cabal build`
Expected: May still have Web layer and Telegram errors (next tasks).

- [ ] **Step 7: Commit (WIP)**

```bash
git add src/Domain/Core/Errors.hs src/Application/Services/TransactionService.hs
git commit -m "feat: add cross-currency conversion to TransactionService"
```

---

### Task 11: Update Web Layer and Telegram bot

**Files:**
- Modify: `src/Web/Types.hs:293-306` (InternalTransferRequest — add optional exchangeRate)
- Modify: `src/Web/Types.hs:348-359` (TransactionResponse — replace `amount :: Double`)
- Modify: `src/Web/Types.hs:597-611` (fromTransactionData — map new fields)
- Modify: `src/Web/Types.hs` (fromTransaction — also uses `amount` field)
- Modify: `src/Web/API/TransactionAPI.hs:186-218` (transferHandler — pass exchangeRate)
- Modify: `src/Telegram/Commands.hs` (update calls to service functions)

- [ ] **Step 1: Update `InternalTransferRequest`**

Add optional field:

```haskell
exchangeRate :: Maybe Double  -- optional user-provided rate
```

- [ ] **Step 2: Update `TransactionResponse`**

Replace `amount :: Double` with:

```haskell
sourceAmount :: Double,
sourceCurrency :: Text,
targetAmount :: Double,
targetCurrency :: Text,
exchangeRate :: Maybe Double,
```

Keep using `Double` and `Text` to match existing DTO conventions (domain types are mapped at the boundary).

- [ ] **Step 3: Update `fromTransactionData` and `fromTransaction`**

Both functions convert domain types to DTOs. Map the new fields:

```haskell
fromTransactionData txId TransactionData {..} =
  TransactionResponse
    { ...
      sourceAmount = fromRational (unMoney sourceAmount),
      sourceCurrency = T.pack (show (moneyCurrency sourceAmount)),
      targetAmount = fromRational (unMoney targetAmount),
      targetCurrency = T.pack (show (moneyCurrency targetAmount)),
      exchangeRate = fmap (fromRational . exchangeRateValue) exchangeRate,
      ...
    }
```

Do the same for `fromTransaction`.

- [ ] **Step 4: Update `transferHandler`**

Parse the optional `exchangeRate` from `InternalTransferRequest` and pass to `initiateInternalTransfer`:

```haskell
-- Convert Maybe Double to Maybe Rational
let maybeRate = fmap toRational req.exchangeRate
```

- [ ] **Step 5: Update `src/Telegram/Commands.hs`**

Update all calls to `initiateInternalTransfer` to pass `Nothing` for the new `Maybe Rational` parameter (Telegram bot does not support user-provided rates for internal transfers yet).

Find the calls: `grep -n initiateInternalTransfer src/Telegram/Commands.hs`

- [ ] **Step 6: Build to verify full compilation**

Run: `cabal build`
Expected: Compiles successfully.

- [ ] **Step 7: Commit**

```bash
git add src/Web/Types.hs src/Web/API/TransactionAPI.hs src/Telegram/Commands.hs src/Domain/Core/Errors.hs
git commit -m "feat: update Web DTOs, handlers, and Telegram bot for cross-currency transfers"
```

---

## Chunk 3: Test Updates & Verification

### Task 12: Update existing tests

**Files:**
- Modify: All test files that reference `InitiateTransfer`, `TransferInitiated`, `TransactionData`, or single `amount` field on transfers
- Key files to check: `test/Domain/Transaction/CommandHandlerSpec.hs`, `test/Application/ProcessManagers/TransferManagerSpec.hs`, any integration specs

- [ ] **Step 1: Find all affected test files**

Run: `grep -rl 'InitiateTransfer\|TransferInitiated\|TransactionData' test/`

- [ ] **Step 2: Update each test file**

For each file, replace `amount = someMoney` with:
```haskell
sourceAmount = someMoney,
targetAmount = someMoney,
exchangeRate = Nothing,
```
For same-currency tests, `sourceAmount == targetAmount`.

- [ ] **Step 3: Update Testkit generators if needed**

If generators exist for `InitiateTransfer` or `TransferInitiated` in `test/Testkit/Generators.hs`, update them to generate `sourceAmount`, `targetAmount`, and `exchangeRate`.

- [ ] **Step 4: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add test/
git commit -m "test: update all tests for cross-currency transfer fields"
```

---

### Task 13: Add cross-currency transfer tests

**Files:**
- Create or modify: `test/Application/Services/TransactionServiceSpec.hs`

These tests run the service functions against a test `AppEnv`. The test environment needs an `ExchangeRateCache`.

**Test setup strategy:** Create a helper `mkTestExchangeRateCache` that builds a cache with known deterministic rates (e.g., UAH/USD = 0.025, EUR/USD = 1.08). Use `newExchangeRateCache` and directly write to the `IORef` with known rates — do not call `refreshCache` (avoids network dependency). The existing test infrastructure (e.g., `InMemoryEventStore` from `test/Testkit/InMemoryEventStore.hs`) should be used for event store setup. Add `ExchangeRateCache` to any existing `mkTestAppEnv` or test environment builder.

```haskell
-- Helper for deterministic test cache
mkTestExchangeRateCache :: IO ExchangeRateCache
mkTestExchangeRateCache = do
  cache <- newExchangeRateCache
  now <- getCurrentTime
  let rates = Map.fromList
        [ ((UAH, USD), unsafeExchangeRate UAH USD 0.025)
        , ((USD, UAH), unsafeExchangeRate USD UAH 40.0)
        , ((EUR, USD), unsafeExchangeRate EUR USD 1.08)
        , ((USD, EUR), unsafeExchangeRate USD EUR (1 / 1.08))
        ]
  writeIORef (cacheRef cache) (Just (now, rates))
  pure cache
```

- [ ] **Step 1: Write test for cross-currency income**

```haskell
it "converts UAH income to USD for External account" $ do
  -- Setup: Create test AppEnv with exchange rate cache containing known UAH/USD rate
  -- Create Regular account in UAH, External account in USD
  -- Act: initiateIncome with 1000 UAH
  -- Assert: result is Right, sourceAmount is in USD (converted), targetAmount is 1000 UAH
```

- [ ] **Step 2: Write test for same-currency transfer**

```haskell
it "skips conversion for same-currency transfer" $ do
  -- Setup: Both accounts in USD
  -- Act: initiateInternalTransfer with 100 USD, Nothing rate
  -- Assert: sourceAmount == targetAmount == 100 USD, exchangeRate == Nothing
```

- [ ] **Step 3: Write test for user-provided rate override**

```haskell
it "uses user-provided rate instead of ECB" $ do
  -- Setup: Source UAH account, target USD account
  -- Act: initiateInternalTransfer with 1000 UAH and Just 0.025
  -- Assert: targetAmount is 25 USD, exchangeRate is Just (UAH->USD at 0.025)
```

- [ ] **Step 4: Write test for rate unavailable error**

```haskell
it "returns ExchangeRateUnavailable when cache is empty" $ do
  -- Setup: Empty cache (newExchangeRateCache, no refresh), cross-currency transfer
  -- Act: initiateIncome with UAH amount
  -- Assert: Left (ExchangeRateUnavailable _)
```

- [ ] **Step 5: Run tests**

Run: `cabal test --test-show-details=direct`
Expected: All pass.

- [ ] **Step 6: Commit**

```bash
git add test/
git commit -m "test: add cross-currency transfer conversion tests"
```

---

### Task 14: Format, lint, and final verification

**Files:** All modified files.

- [ ] **Step 1: Format**

Run: `just format`

- [ ] **Step 2: Lint**

Run: `just lint`
Fix any issues.

- [ ] **Step 3: Full test suite**

Run: `just test`
Expected: All pass.

- [ ] **Step 4: Build with CI flags**

Run: `cabal build -fci`
Expected: No warnings (since `-Werror` is active under `-fci`).

- [ ] **Step 5: Commit any formatting/lint fixes**

```bash
git add -A
git commit -m "style: format and lint fixes"
```

- [ ] **Step 6: Squash WIP commits (optional)**

If desired, squash the WIP commits from Chunk 2 into logical commits before pushing.
