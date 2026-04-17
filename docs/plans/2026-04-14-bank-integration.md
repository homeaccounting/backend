# Bank Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import bank transactions automatically from Monobank via webhooks and manual resync, with a provider-agnostic architecture supporting future banks.

**Architecture:** Record-of-functions `BankProvider` abstraction (like `RateProvider`) with Monobank as first implementation. `BankImportService` orchestrates webhook/resync flows, producing `InitiateTransfer` commands. Two new read models track deduplication and bank link state. Resync endpoint is the primary testing flow.

**Tech Stack:** Haskell, Servant, http-client, aeson, STM TVars, eventium event sourcing, HMAC-SHA256 for webhook secrets.

**Spec:** `docs/specs/2026-04-10-bank-integration-design.md`

---

## File Structure

### New Files

| File | Responsibility |
|------|---------------|
| `src/Infrastructure/Banking/Provider.hs` | `BankProvider` record-of-functions, `BankAccount`, `BankTransaction`, `TransactionClassification`, `BankAccountId` types |
| `src/Infrastructure/Banking/Monobank.hs` | Monobank API client, `mkMonobankProvider`, JSON parsing for Mono responses |
| `src/Application/Services/BankImportService.hs` | Orchestration: webhook handling, resync, account matching, dedup check, `InitiateTransfer` command creation |
| `src/Application/ReadModels/BankImportReadModel.hs` | Dedup index: `Map ExternalTransactionId TransactionId`, built from `TransferInitiated` events |
| `src/Application/ReadModels/BankLinkState.hs` | Active bank links: account mappings, webhook secrets, rebuilt from `BankAccountsLinked`/`BankAccountsUnlinked` events |
| `src/Web/API/BankingAPI.hs` | Servant API: webhook endpoints (GET/POST), resync endpoint |
| `test/Domain/Core/CurrencyNumericSpec.hs` | Tests for `currencyNumericCode` / `currencyFromNumericCode` |
| `test/Infrastructure/Banking/ProviderSpec.hs` | Tests for `TransactionClassification` and provider types |
| `test/Application/Services/BankImportServiceSpec.hs` | Tests for import orchestration logic (matching, dedup, classification) |
| `test/Integration/BankImportWorkflowSpec.hs` | End-to-end: mock provider → resync → transfers created |

### Modified Files

| File | Changes |
|------|---------|
| `src/Domain/Core/Types.hs` | Add `currencyNumericCode`, `currencyFromNumericCode`, `ExternalTransactionId` type alias |
| `src/Domain/Core/Errors.hs` | Add `BankingError Text` constructor |
| `src/Domain/Transaction/Commands.hs` | Add `externalTransactionId :: Maybe ExternalTransactionId` to `InitiateTransfer` |
| `src/Domain/Transaction/Events.hs` | Add `externalTransactionId :: Maybe ExternalTransactionId` to `TransferInitiated` |
| `src/Domain/Transaction/CommandHandler.hs` | Pass through `externalTransactionId` from command to event |
| `src/Application/Services/TransactionService.hs` | Pass `Nothing` for `externalTransactionId` in existing transfer functions |
| `src/Infrastructure/Config.hs` | Add `BankingConfig`, `api_base_url` to `ServerConfig`, `bankingWebhookSecret` |
| `src/Infrastructure/App.hs` | Add `BankImportReadModel`, `BankLinkState` TVars, `HasBankingConfig`, `HasBankImportReadModel`, `HasBankLinkState`, `HasHttpManager` |
| `src/Infrastructure/Eventium.hs` | Add `BankImportReadModel` and `BankLinkState` to `ReadModels`, wire event handlers |
| `src/Web/API.hs` | Add `BankingAPI` to combined API |
| `src/Web/ErrorMapping.hs` | Add `BankingError` mapping |
| `config/test.yaml` | Add `banking` and `api_base_url` sections |
| `config/local.yaml` | Add `banking` and `api_base_url` sections |
| `app/Main.hs` | Wire banking config, HTTP manager, read models |
| `test/Testkit/InMemoryEventStore.hs` | Add banking read models and config to test `AppEnv` |
| `package.yaml` | Add `crypton` (HMAC-SHA256) if not already covered by `cryptonite` |

---

## Task 1: Currency Numeric Codes

**Files:**
- Modify: `src/Domain/Core/Types.hs:130-159`
- Test: `test/Domain/Core/CurrencyNumericSpec.hs` (create)

- [ ] **Step 1: Write failing tests for currency numeric codes**

Create `test/Domain/Core/CurrencyNumericSpec.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

module Domain.Core.CurrencyNumericSpec (spec) where

import Data.Either (isLeft)
import Domain.Core.Types
import RIO
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = describe "Currency Numeric Codes" $ do
  describe "currencyNumericCode" $ do
    it "returns 980 for UAH" $
      currencyNumericCode UAH `shouldBe` 980
    it "returns 840 for USD" $
      currencyNumericCode USD `shouldBe` 840
    it "returns 978 for EUR" $
      currencyNumericCode EUR `shouldBe` 978
    it "returns 826 for GBP" $
      currencyNumericCode GBP `shouldBe` 826

  describe "currencyFromNumericCode" $ do
    it "parses 980 to UAH" $
      currencyFromNumericCode 980 `shouldBe` Right UAH
    it "parses 840 to USD" $
      currencyFromNumericCode 840 `shouldBe` Right USD
    it "rejects unknown code" $
      currencyFromNumericCode 999 `shouldSatisfy` isLeft

  describe "roundtrip property" $
    it "fromNumericCode . numericCode == Right for all currencies" $
      property $ \c ->
        currencyFromNumericCode (currencyNumericCode c) === Right c

instance Arbitrary Currency where
  arbitrary = elements [UAH, USD, EUR, GBP]
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cabal test all --test-option='--match' --test-option="/Currency Numeric/"`
Expected: Compilation failure — `currencyNumericCode` not defined

- [ ] **Step 3: Implement currency numeric code functions**

In `src/Domain/Core/Types.hs`, add after the `parseCurrency` function (around line 159), and export them:

```haskell
-- | Convert a Currency to its ISO 4217 numeric code.
currencyNumericCode :: Currency -> Int
currencyNumericCode UAH = 980
currencyNumericCode USD = 840
currencyNumericCode EUR = 978
currencyNumericCode GBP = 826

-- | Parse a Currency from its ISO 4217 numeric code.
currencyFromNumericCode :: Int -> Either Text Currency
currencyFromNumericCode 980 = Right UAH
currencyFromNumericCode 840 = Right USD
currencyFromNumericCode 978 = Right EUR
currencyFromNumericCode 826 = Right GBP
currencyFromNumericCode code = Left $ "Unsupported currency code: " <> T.pack (show code)
```

Add to module exports: `currencyNumericCode`, `currencyFromNumericCode`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cabal test all --test-option='--match' --test-option="/Currency Numeric/"`
Expected: All pass

- [ ] **Step 5: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All existing tests still pass

- [ ] **Step 6: Commit**

```bash
git add src/Domain/Core/Types.hs test/Domain/Core/CurrencyNumericSpec.hs
git commit -m "feat: add ISO 4217 numeric currency code functions"
```

---

## Task 2: ExternalTransactionId Type + Add to Transfer Command/Event

**Files:**
- Modify: `src/Domain/Core/Types.hs`
- Modify: `src/Domain/Transaction/Commands.hs:79-96`
- Modify: `src/Domain/Transaction/Events.hs:64-82`
- Modify: `src/Domain/Transaction/CommandHandler.hs`
- Modify: `src/Application/Services/TransactionService.hs`
- Modify: `test/Testkit/Helpers.hs` (if mock constructors need updating)

This task modifies existing domain types. It must be done carefully to maintain backward compatibility with existing JSON-serialized events.

- [ ] **Step 1: Add ExternalTransactionId type alias to Domain.Core.Types**

In `src/Domain/Core/Types.hs`, add near the other type aliases and export it:

```haskell
-- | Identifier for a transaction in an external system (e.g., Monobank).
-- Plain Text, not a UUID — external systems use their own ID formats.
type ExternalTransactionId = Text
```

- [ ] **Step 2: Add externalTransactionId to InitiateTransfer command**

In `src/Domain/Transaction/Commands.hs`, add import for `ExternalTransactionId` from `Domain.Core.Types`, then add field to `InitiateTransfer`:

```haskell
data InitiateTransfer = InitiateTransfer
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    initiatedBy :: UserId,
    transferType :: TransferType,
    externalTransactionId :: Maybe ExternalTransactionId
  }
```

- [ ] **Step 3: Add externalTransactionId to TransferInitiated event**

In `src/Domain/Transaction/Events.hs`, add import for `ExternalTransactionId`, then add field:

```haskell
data TransferInitiated = TransferInitiated
  { sourceAccountId :: AccountId,
    targetAccountId :: AccountId,
    sourceAmount :: Money,
    targetAmount :: Money,
    exchangeRate :: Maybe ExchangeRate,
    description :: Text,
    by :: UserId,
    transferType :: TransferType,
    externalTransactionId :: Maybe ExternalTransactionId
  }
```

Because `deriveJSON defaultOptions` is used and the field is `Maybe`, existing events that lack this field will deserialize with `Nothing` (aeson's default for `Maybe` fields with `defaultOptions`). **No migration needed.**

- [ ] **Step 4: Update command handler to pass through the field**

In `src/Domain/Transaction/CommandHandler.hs`, find where `TransferInitiated` is constructed from `InitiateTransfer` and add:

```haskell
externalTransactionId = cmd.externalTransactionId
```

- [ ] **Step 5: Update TransactionService to pass Nothing for user-initiated transfers**

In `src/Application/Services/TransactionService.hs`, find all places where `InitiateTransfer` is constructed (in `initiateIncome`, `initiateExpense`, `initiateInternalTransfer`) and add:

```haskell
externalTransactionId = Nothing
```

- [ ] **Step 6: Fix any test compilation errors**

Check `test/Testkit/Helpers.hs` and any test files that construct `InitiateTransfer` or `TransferInitiated` — add `externalTransactionId = Nothing` to each.

- [ ] **Step 7: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All tests pass

- [ ] **Step 8: Commit**

```bash
git add src/Domain/Core/Types.hs src/Domain/Transaction/Commands.hs src/Domain/Transaction/Events.hs src/Domain/Transaction/CommandHandler.hs src/Application/Services/TransactionService.hs test/
git commit -m "feat: add externalTransactionId to transfer command and event"
```

---

## Task 3: BankingError + Error Mapping

**Files:**
- Modify: `src/Domain/Core/Errors.hs:30-53`
- Modify: `src/Web/ErrorMapping.hs`

- [ ] **Step 1: Add BankingError to DomainError**

In `src/Domain/Core/Errors.hs`, add after the `NotFound` constructor:

```haskell
  | -- | Banking integration error
    BankingError Text
```

- [ ] **Step 2: Add BankingError mapping in Web.ErrorMapping**

In `src/Web/ErrorMapping.hs`, add a case in `mapDomainError`:

```haskell
mapDomainError (BankingError msg) =
  err400
    { errBody =
        encode $
          ErrorResponse
            { message = msg,
              code = "BANKING_ERROR",
              details = Nothing
            }
    }
```

- [ ] **Step 3: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add src/Domain/Core/Errors.hs src/Web/ErrorMapping.hs
git commit -m "feat: add BankingError to DomainError and error mapping"
```

---

## Task 4: Banking Config

**Files:**
- Modify: `src/Infrastructure/Config.hs`
- Modify: `config/test.yaml`
- Modify: `config/local.yaml`
- Modify: `config/prod.yaml`

- [ ] **Step 1: Add BankingConfig and api_base_url to Config.hs**

In `src/Infrastructure/Config.hs`, add new config types:

```haskell
data BankingConfig = BankingConfig
  { enabled :: !Bool,
    webhookSecret :: !Text,  -- server-side secret for HMAC derivation
    providers :: !BankingProvidersConfig
  }
  deriving (Show, Eq, Generic)

data BankingProvidersConfig = BankingProvidersConfig
  { monobank :: !MonobankProviderConfig
  }
  deriving (Show, Eq, Generic)

data MonobankProviderConfig = MonobankProviderConfig
  { enabled :: !Bool
  }
  deriving (Show, Eq, Generic)

instance FromJSON BankingConfig where
  parseJSON = withObject "BankingConfig" $ \v ->
    BankingConfig
      <$> v .:? "enabled" .!= False
      <*> v .: "webhook_secret"
      <*> v .:? "providers" .!= defaultBankingProviders

defaultBankingProviders :: BankingProvidersConfig
defaultBankingProviders = BankingProvidersConfig (MonobankProviderConfig False)

instance FromJSON BankingProvidersConfig where
  parseJSON = withObject "BankingProvidersConfig" $ \v ->
    BankingProvidersConfig
      <$> v .:? "monobank" .!= MonobankProviderConfig False

instance FromJSON MonobankProviderConfig where
  parseJSON = withObject "MonobankProviderConfig" $ \v ->
    MonobankProviderConfig <$> v .:? "enabled" .!= False

instance ToJSON BankingConfig
instance ToJSON BankingProvidersConfig
instance ToJSON MonobankProviderConfig
```

Add `apiBaseUrl :: !Text` to `ServerConfig`:

```haskell
data ServerConfig = ServerConfig
  { host :: !Text,
    port :: !Int,
    apiBaseUrl :: !Text
  }
```

Update `ServerConfig`'s `FromJSON`:

```haskell
instance FromJSON ServerConfig where
  parseJSON = withObject "ServerConfig" $ \v ->
    ServerConfig
      <$> v .: "host"
      <*> v .: "port"
      <*> v .:? "api_base_url" .!= "http://localhost:8080"
```

Add `banking :: !BankingConfig` to `AppConfig` and update its `FromJSON`.

- [ ] **Step 2: Update config YAML files**

Add to `config/test.yaml`:

```yaml
server:
  host: "0.0.0.0"
  port: 8080
  api_base_url: "http://localhost:8080"

banking:
  enabled: false
  webhook_secret: "test-webhook-secret-do-not-use-in-prod"
  providers:
    monobank:
      enabled: false
```

Add same to `config/local.yaml` (with `${BANKING_WEBHOOK_SECRET:-...}` env var substitution).

Add to `config/prod.yaml` with full env var substitution:

```yaml
server:
  api_base_url: "${API_BASE_URL}"

banking:
  enabled: ${BANKING_ENABLED:-false}
  webhook_secret: "${BANKING_WEBHOOK_SECRET}"
  providers:
    monobank:
      enabled: ${MONOBANK_ENABLED:-false}
```

- [ ] **Step 3: Update test AppConfig in InMemoryEventStore.hs**

Add the `banking` field to the test `AppConfig` in `test/Testkit/InMemoryEventStore.hs`:

```haskell
banking = BankingConfig
  { enabled = False,
    webhookSecret = "test-secret",
    providers = BankingProvidersConfig (MonobankProviderConfig False)
  }
```

Also add `apiBaseUrl = "http://localhost:8080"` to the test `ServerConfig`.

- [ ] **Step 4: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All pass

- [ ] **Step 5: Commit**

```bash
git add src/Infrastructure/Config.hs config/test.yaml config/local.yaml config/prod.yaml test/Testkit/InMemoryEventStore.hs
git commit -m "feat: add banking config and api_base_url to server config"
```

---

## Task 5: BankProvider Abstraction

**Files:**
- Modify: `package.yaml`
- Create: `src/Infrastructure/Banking/Provider.hs`
- Test: `test/Infrastructure/Banking/ProviderSpec.hs` (create)

- [ ] **Step 1: Update package.yaml dependencies**

Verify `http-client`, `http-client-tls`, and `cryptonite` are already present (they should be from OAuth). If not, add them. Run `hpack` after any changes to regenerate `backend.cabal`.

- [ ] **Step 2: Create BankProvider types**

Create `src/Infrastructure/Banking/Provider.hs`:

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Provider
  ( -- * Provider
    BankProvider (..),
    TransactionClassification (..),

    -- * Types
    BankAccountId,
    BankAccount (..),
    BankTransaction (..),
  )
where

import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Domain.Core.Types (DictionaryEntryId, ExternalTransactionId)
import RIO (IO, Either, Maybe, Bool)

-- | Identifier for an external bank account (provider-specific).
type BankAccountId = Text

-- | Record-of-functions abstraction for bank API providers.
--
-- Each bank (Monobank, PrivatBank, etc.) implements this interface.
-- Ephemeral — constructed per-request from user's token, NOT stored in AppEnv.
data BankProvider = BankProvider
  { providerName :: !Text,
    fetchAccounts :: IO (Either Text [BankAccount]),
    fetchStatements :: BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction]),
    registerWebhook :: Text -> IO (Either Text ()),
    classifyTransaction :: BankTransaction -> TransactionClassification
  }

-- | Provider-contributed classification hint.
-- BankImportService owns the final decision but uses this as a starting point.
data TransactionClassification
  = ClassifiedExpense !(Maybe DictionaryEntryId)
  | ClassifiedIncome !(Maybe DictionaryEntryId)
  | ClassifiedTransfer
  deriving (Show, Eq)

-- | A bank account as reported by the provider.
data BankAccount = BankAccount
  { externalId :: !BankAccountId,
    accountNumber :: !Text,
    currencyCode :: !Int,
    cardMasks :: ![Text],
    balance :: !Int64
  }
  deriving (Show, Eq)

-- | A bank transaction as reported by the provider.
data BankTransaction = BankTransaction
  { externalId :: !ExternalTransactionId,
    accountId :: !BankAccountId,
    time :: !UTCTime,
    amount :: !Int64,
    currencyCode :: !Int,
    description :: !Text,
    hold :: !Bool,
    mcc :: !(Maybe Int32),
    originalAmount :: !(Maybe Int64),
    notes :: !(Maybe Text),
    categoryHint :: !(Maybe Text)
  }
  deriving (Show, Eq)
```

- [ ] **Step 3: Write basic compile test**

Create `test/Infrastructure/Banking/ProviderSpec.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.ProviderSpec (spec) where

import Infrastructure.Banking.Provider
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Banking.Provider" $ do
  describe "TransactionClassification" $ do
    it "shows ClassifiedTransfer" $
      show ClassifiedTransfer `shouldBe` "ClassifiedTransfer"

    it "shows ClassifiedExpense Nothing" $
      show (ClassifiedExpense Nothing) `shouldBe` "ClassifiedExpense Nothing"
```

- [ ] **Step 4: Run tests**

Run: `cabal test all --test-option='--match' --test-option="/Infrastructure.Banking.Provider/"`
Expected: Pass

- [ ] **Step 5: Commit**

```bash
git add package.yaml src/Infrastructure/Banking/Provider.hs test/Infrastructure/Banking/ProviderSpec.hs
git commit -m "feat: add BankProvider abstraction and types"
```

---

## Task 6: Monobank Provider

**Files:**
- Create: `src/Infrastructure/Banking/Monobank.hs`

- [ ] **Step 1: Create Monobank provider implementation**

Create `src/Infrastructure/Banking/Monobank.hs`. This module constructs a `BankProvider` from a Monobank API token and an HTTP Manager.

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Monobank
  ( mkMonobankProvider,
  )
where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?), (.!=))
import qualified Data.Aeson as Aeson
import Data.Int (Int32, Int64)
import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Infrastructure.Banking.Provider
import Network.HTTP.Client
  ( Manager,
    Request,
    httpLbs,
    method,
    parseRequest,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import RIO

-- | Monobank API base URL.
monoApiBase :: String
monoApiBase = "https://api.monobank.ua"

-- | Construct a BankProvider for Monobank from a personal API token.
mkMonobankProvider :: Text -> Manager -> BankProvider
mkMonobankProvider token manager =
  BankProvider
    { providerName = "monobank",
      fetchAccounts = monoFetchAccounts token manager,
      fetchStatements = monoFetchStatements token manager,
      registerWebhook = monoRegisterWebhook token manager,
      classifyTransaction = monoClassifyTransaction
    }

-- Monobank classify: MCC-based logic
monoClassifyTransaction :: BankTransaction -> TransactionClassification
monoClassifyTransaction tx = case tx.mcc of
  Just 4829 -> ClassifiedTransfer
  _ ->
    if tx.amount >= 0
      then ClassifiedIncome Nothing
      else ClassifiedExpense Nothing

-- -----------------------------------------------------------------------------
-- Monobank API Types (internal)
-- -----------------------------------------------------------------------------

data MonoClientInfo = MonoClientInfo
  { accounts :: [MonoAccount]
  }

instance FromJSON MonoClientInfo where
  parseJSON = withObject "MonoClientInfo" $ \v ->
    MonoClientInfo <$> v .: "accounts"

data MonoAccount = MonoAccount
  { monoAccId :: Text,
    monoAccIban :: Text,
    monoAccCurrencyCode :: Int,
    monoAccBalance :: Int64
  }

instance FromJSON MonoAccount where
  parseJSON = withObject "MonoAccount" $ \v ->
    MonoAccount
      <$> v .: "id"
      <*> v .: "iban"
      <*> v .: "currencyCode"
      <*> v .: "balance"

data MonoStatement = MonoStatement
  { stmtId :: Text,
    stmtTime :: Int64,
    stmtDescription :: Text,
    stmtMcc :: Int32,
    stmtAmount :: Int64,
    stmtOperationAmount :: Int64,
    stmtCurrencyCode :: Int,
    stmtHold :: Bool,
    stmtComment :: Maybe Text
  }

instance FromJSON MonoStatement where
  parseJSON = withObject "MonoStatement" $ \v ->
    MonoStatement
      <$> v .: "id"
      <*> v .: "time"
      <*> v .: "description"
      <*> v .: "mcc"
      <*> v .: "amount"
      <*> v .: "operationAmount"
      <*> v .: "currencyCode"
      <*> v .: "hold"
      <*> v .:? "comment"

-- -----------------------------------------------------------------------------
-- API Calls
-- -----------------------------------------------------------------------------

monoFetchAccounts :: Text -> Manager -> IO (Either Text [BankAccount])
monoFetchAccounts token manager = do
  result <- monoGet token manager (monoApiBase <> "/personal/client-info")
  case result of
    Left err -> return (Left err)
    Right body -> case Aeson.eitherDecode body of
      Left err -> return (Left $ "Failed to parse client-info: " <> T.pack err)
      Right (info :: MonoClientInfo) ->
        return $ Right $ map toProviderAccount info.accounts

monoFetchStatements :: Text -> Manager -> BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction])
monoFetchStatements token manager accountId from to = do
  let fromUnix = show @Int (round (utcTimeToPOSIXSeconds from))
      toUnix = show @Int (round (utcTimeToPOSIXSeconds to))
      url = monoApiBase <> "/personal/statement/" <> T.unpack accountId <> "/" <> fromUnix <> "/" <> toUnix
  result <- monoGet token manager url
  case result of
    Left err -> return (Left err)
    Right body -> case Aeson.eitherDecode body of
      Left err -> return (Left $ "Failed to parse statements: " <> T.pack err)
      Right (stmts :: [MonoStatement]) ->
        return $ Right $ map (toProviderTransaction accountId) stmts

monoRegisterWebhook :: Text -> Manager -> Text -> IO (Either Text ())
monoRegisterWebhook token manager webhookUrl = do
  let body = Aeson.encode $ Aeson.object ["webHookUrl" Aeson..= webhookUrl]
  result <- monoPost token manager (monoApiBase <> "/personal/webhook") body
  case result of
    Left err -> return (Left err)
    Right _ -> return (Right ())

-- -----------------------------------------------------------------------------
-- HTTP Helpers
-- -----------------------------------------------------------------------------

monoGet :: Text -> Manager -> String -> IO (Either Text BSL.ByteString)
monoGet token manager url = do
  req <- parseRequest url
  let authedReq = req {requestHeaders = [("X-Token", encodeUtf8 token)]}
  resp <- httpLbs authedReq manager
  let status = statusCode (responseStatus resp)
  if status >= 200 && status < 300
    then return (Right (responseBody resp))
    else return (Left $ "Monobank API error (HTTP " <> tshow status <> ")")

monoPost :: Text -> Manager -> String -> BSL.ByteString -> IO (Either Text BSL.ByteString)
monoPost token manager url body = do
  req <- parseRequest url
  let authedReq =
        req
          { method = "POST",
            requestHeaders =
              [ ("X-Token", encodeUtf8 token),
                ("Content-Type", "application/json")
              ],
            Network.HTTP.Client.requestBody = Network.HTTP.Client.RequestBodyLBS body
          }
  resp <- httpLbs authedReq manager
  let status = statusCode (responseStatus resp)
  if status >= 200 && status < 300
    then return (Right (responseBody resp))
    else return (Left $ "Monobank API error (HTTP " <> tshow status <> ")")

-- -----------------------------------------------------------------------------
-- Conversions
-- -----------------------------------------------------------------------------

toProviderAccount :: MonoAccount -> BankAccount
toProviderAccount ma =
  BankAccount
    { externalId = ma.monoAccId,
      accountNumber = ma.monoAccIban,
      currencyCode = ma.monoAccCurrencyCode,
      balance = ma.monoAccBalance
    }

toProviderTransaction :: BankAccountId -> MonoStatement -> BankTransaction
toProviderTransaction accId ms =
  BankTransaction
    { externalId = ms.stmtId,
      accountId = accId,
      time = posixSecondsToUTCTime (fromIntegral ms.stmtTime),
      amount = ms.stmtAmount,
      currencyCode = ms.stmtCurrencyCode,
      description = ms.stmtDescription,
      hold = ms.stmtHold,
      mcc = Just ms.stmtMcc,
      originalAmount = Just ms.stmtOperationAmount,
      notes = ms.stmtComment,
      categoryHint = Nothing
    }

-- Re-export for use in this module
utcTimeToPOSIXSeconds :: UTCTime -> NominalDiffTime
utcTimeToPOSIXSeconds = Data.Time.Clock.POSIX.utcTimeToPOSIXSeconds
```

Note: The exact imports and body helper may need adjustment during implementation (e.g., `requestBody` field access). The implementer should fix compilation issues.

- [ ] **Step 2: Write tests for Monobank classification and JSON parsing**

Create `test/Infrastructure/Banking/MonobankSpec.hs`:

```haskell
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}

module Infrastructure.Banking.MonobankSpec (spec) where

import Data.Aeson (eitherDecode)
import Infrastructure.Banking.Monobank (mkMonobankProvider)
import Infrastructure.Banking.Provider
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Monobank Provider" $ do
  describe "classifyTransaction" $ do
    let classify = (.classifyTransaction) (mkMonobankProvider "" undefined)

    it "classifies MCC 4829 as Transfer" $
      classify (mkTx {mcc = Just 4829, amount = -1000}) `shouldBe` ClassifiedTransfer

    it "classifies positive amount as Income" $
      classify (mkTx {mcc = Just 5411, amount = 5000}) `shouldBe` ClassifiedIncome Nothing

    it "classifies negative amount as Expense" $
      classify (mkTx {mcc = Just 5411, amount = -3000}) `shouldBe` ClassifiedExpense Nothing

    it "classifies zero MCC negative as Expense" $
      classify (mkTx {mcc = Just 0, amount = -100}) `shouldBe` ClassifiedExpense Nothing

    it "classifies no MCC positive as Income" $
      classify (mkTx {mcc = Nothing, amount = 100}) `shouldBe` ClassifiedIncome Nothing

-- Helper to build a minimal BankTransaction for testing
mkTx :: BankTransaction
mkTx = BankTransaction
  { externalId = "test-tx"
  , accountId = "test-acc"
  , time = undefined  -- not used by classify
  , amount = 0
  , currencyCode = 980
  , description = "test"
  , hold = False
  , mcc = Nothing
  , originalAmount = Nothing
  , notes = Nothing
  , categoryHint = Nothing
  }
```

- [ ] **Step 3: Verify it compiles and tests pass**

Run: `cabal test all --test-option='--match' --test-option="/Monobank Provider/"`
Expected: Pass

- [ ] **Step 4: Commit**

```bash
git add src/Infrastructure/Banking/Monobank.hs test/Infrastructure/Banking/MonobankSpec.hs
git commit -m "feat: add Monobank provider implementation"
```

---

## Task 7: BankImportReadModel (Dedup Index)

**Files:**
- Create: `src/Application/ReadModels/BankImportReadModel.hs`
- Modify: `src/Application/ReadModels/Transaction.hs` (to expose externalTransactionId in TransactionData if needed)

- [ ] **Step 1: Create BankImportReadModel**

Create `src/Application/ReadModels/BankImportReadModel.hs`:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Application.ReadModels.BankImportReadModel
  ( BankImportReadModel (..),
    createBankImportReadModel,
    handleBankImportEvents,
    isImported,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Domain.Core.Types (ExternalTransactionId, TransactionId, mkTransactionIdSafe)
import Domain.Models (AccountingEvent (..))
import Domain.Transaction.Events (TransferInitiated (..))
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import Safe (maximumDef)

data BankImportReadModel = BankImportReadModel
  { latestSequence :: SequenceNumber,
    importedTransactions :: !(Map ExternalTransactionId TransactionId)
  }
  deriving (Show, Eq)

createBankImportReadModel :: (MonadIO m) => m (TVar BankImportReadModel)
createBankImportReadModel =
  liftIO $
    newTVarIO $
      BankImportReadModel
        { latestSequence = -1,
          importedTransactions = Map.empty
        }

isImported :: (MonadIO m) => TVar BankImportReadModel -> ExternalTransactionId -> m Bool
isImported rmTVar extId = do
  rm <- liftIO $ readTVarIO rmTVar
  return $ Map.member extId rm.importedTransactions

handleBankImportEvents ::
  (MonadIO m) =>
  TVar BankImportReadModel ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleBankImportEvents rmTVar events = do
  currentModel <- liftIO $ readTVarIO rmTVar
  let newSeq = maximumDef currentModel.latestSequence ((.position) <$> events)
      updatedMap = foldl processEvent currentModel.importedTransactions events
  liftIO . atomically . writeTVar rmTVar $
    currentModel
      { latestSequence = newSeq,
        importedTransactions = updatedMap
      }

processEvent ::
  Map ExternalTransactionId TransactionId ->
  GlobalStreamEvent AccountingEvent ->
  Map ExternalTransactionId TransactionId
processEvent txMap globalEvent =
  let versionedEvent = globalEvent.payload
      streamUuid = versionedEvent.key
      payload = versionedEvent.payload
   in case payload of
        TransferInitiatedEvent evt ->
          case evt.externalTransactionId of
            Just extId ->
              case mkTransactionIdSafe streamUuid of
                Just txId -> Map.insert extId txId txMap
                Nothing -> txMap
            Nothing -> txMap
        _ -> txMap
```

- [ ] **Step 2: Verify it compiles**

Run: `cabal build`

- [ ] **Step 3: Commit**

```bash
git add src/Application/ReadModels/BankImportReadModel.hs
git commit -m "feat: add BankImportReadModel for dedup index"
```

---

## Task 8: BankLinkState Read Model

**Files:**
- Create: `src/Application/ReadModels/BankLinkState.hs`

The `BankLinkState` tracks active bank links (account mappings, webhook secrets). It is rebuilt from `BankAccountsLinked` / `BankAccountsUnlinked` events. Since these are new event types, they need to be added to the `AccountingEvent` sum type.

**Note:** Adding new events to `AccountingEvent` requires modifying `Domain.Models` (which uses TH to construct the sum type). The new events should be defined as a new "BankLink" event module and wired into the TH machinery, OR emitted as standalone application-level events not part of the eventium aggregate model. Given the spec says these are "application-level events," we will store them as regular `AccountingEvent` entries using a new event module.

- [ ] **Step 1: Create BankLink events module**

Create `src/Domain/BankLink/Events.hs`:

```haskell
{-# LANGUAGE TemplateHaskell #-}

module Domain.BankLink.Events
  ( bankLinkEvents,
    BankAccountsLinked (..),
    AccountMappingData (..),
    BankAccountsUnlinked (..),
  )
where

import Data.Aeson.TH (defaultOptions, deriveJSON)
import Data.Text (Text)
import Domain.Core.Types (AccountId, UserId)
import Language.Haskell.TH (Name)

bankLinkEvents :: [Name]
bankLinkEvents =
  [ ''BankAccountsLinked,
    ''BankAccountsUnlinked
  ]

data AccountMappingData = AccountMappingData
  { externalAccountId :: Text,
    accountNumber :: Text,
    accountId :: AccountId
  }
  deriving (Show, Eq)

data BankAccountsLinked = BankAccountsLinked
  { userId :: UserId,
    bankName :: Text,
    accountMappings :: [AccountMappingData],
    webhookSecret :: Text
  }
  deriving (Show, Eq)

data BankAccountsUnlinked = BankAccountsUnlinked
  { userId :: UserId,
    bankName :: Text
  }
  deriving (Show, Eq)

deriveJSON defaultOptions ''AccountMappingData
deriveJSON defaultOptions ''BankAccountsLinked
deriveJSON defaultOptions ''BankAccountsUnlinked
```

- [ ] **Step 2: Wire BankLink events into Domain.Models**

In `src/Domain/Models.hs`:
- Import `Domain.BankLink.Events` and re-export
- Add `bankLinkEvents` to the `constructSumType "AccountingEvent"` call
- Add `mkSumTypeEmbedding "bankLinkEventEmbedding"` for the new events
- Export `bankLinkEventEmbedding`

The `constructSumType` call becomes:
```haskell
constructSumType
  "AccountingEvent"
  (withTagOptions (ConstructTagName (++ "Event")) defaultSumTypeOptions)
  (accountEvents ++ transactionEvents ++ userEvents ++ configurationEvents ++ bankLinkEvents)
```

**No command handler needed** — these events are emitted directly by the application service, not through an aggregate command handler.

- [ ] **Step 3: Create BankLinkState read model**

Create `src/Application/ReadModels/BankLinkState.hs`:

```haskell
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedRecordDot #-}

module Application.ReadModels.BankLinkState
  ( BankLinkState (..),
    UserBankLink (..),
    AccountMapping (..),
    createBankLinkState,
    handleBankLinkEvents,
    getUserBankLink,
    findUserByWebhookSecret,
    findAccountMapping,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Domain.BankLink.Events (AccountMappingData (..), BankAccountsLinked (..), BankAccountsUnlinked (..))
import Domain.Core.Types (AccountId, UserId)
import Domain.Models (AccountingEvent (..))
import Eventium (GlobalStreamEvent, SequenceNumber, StreamEvent (..))
import Infrastructure.Banking.Provider (BankAccountId)
import Safe (maximumDef)

data AccountMapping = AccountMapping
  { externalAccountId :: !BankAccountId,
    accountNumber :: !Text,
    accountId :: !AccountId
  }
  deriving (Show, Eq)

data UserBankLink = UserBankLink
  { webhookSecret :: !Text,
    accountMappings :: ![AccountMapping],
    bankName :: !Text
  }
  deriving (Show, Eq)

data BankLinkState = BankLinkState
  { latestSequence :: SequenceNumber,
    activeLinks :: !(Map UserId UserBankLink)
  }
  deriving (Show, Eq)

createBankLinkState :: (MonadIO m) => m (TVar BankLinkState)
createBankLinkState =
  liftIO $
    newTVarIO $
      BankLinkState
        { latestSequence = -1,
          activeLinks = Map.empty
        }

getUserBankLink :: (MonadIO m) => TVar BankLinkState -> UserId -> m (Maybe UserBankLink)
getUserBankLink stateTVar userId = do
  state <- liftIO $ readTVarIO stateTVar
  return $ Map.lookup userId state.activeLinks

findUserByWebhookSecret :: (MonadIO m) => TVar BankLinkState -> Text -> m (Maybe (UserId, UserBankLink))
findUserByWebhookSecret stateTVar secret = do
  state <- liftIO $ readTVarIO stateTVar
  let matches = Map.toList $ Map.filter (\l -> l.webhookSecret == secret) state.activeLinks
  return $ case matches of
    [(uid, link)] -> Just (uid, link)
    _ -> Nothing

findAccountMapping :: UserBankLink -> BankAccountId -> Maybe AccountMapping
findAccountMapping link extAccId =
  find (\m -> m.externalAccountId == extAccId) link.accountMappings

handleBankLinkEvents ::
  (MonadIO m) =>
  TVar BankLinkState ->
  [GlobalStreamEvent AccountingEvent] ->
  m ()
handleBankLinkEvents stateTVar events = do
  current <- liftIO $ readTVarIO stateTVar
  let newSeq = maximumDef current.latestSequence ((.position) <$> events)
      updatedLinks = foldl processEvent current.activeLinks events
  liftIO . atomically . writeTVar stateTVar $
    current
      { latestSequence = newSeq,
        activeLinks = updatedLinks
      }

processEvent ::
  Map UserId UserBankLink ->
  GlobalStreamEvent AccountingEvent ->
  Map UserId UserBankLink
processEvent links globalEvent =
  let payload = globalEvent.payload.payload
   in case payload of
        BankAccountsLinkedEvent evt ->
          Map.insert
            evt.userId
            UserBankLink
              { webhookSecret = evt.webhookSecret,
                accountMappings = map toMapping evt.accountMappings,
                bankName = evt.bankName
              }
            links
        BankAccountsUnlinkedEvent evt ->
          Map.delete evt.userId links
        _ -> links

toMapping :: AccountMappingData -> AccountMapping
toMapping amd =
  AccountMapping
    { externalAccountId = amd.externalAccountId,
      accountNumber = amd.accountNumber,
      accountId = amd.accountId
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `cabal build`

- [ ] **Step 5: Commit**

```bash
git add src/Domain/BankLink/Events.hs src/Domain/Models.hs src/Application/ReadModels/BankLinkState.hs
git commit -m "feat: add BankLink events and BankLinkState read model"
```

---

## Task 9: Wire Banking into AppEnv and Infrastructure

**Files:**
- Modify: `src/Infrastructure/App.hs`
- Modify: `src/Infrastructure/Eventium.hs`
- Modify: `app/Main.hs`
- Modify: `test/Testkit/InMemoryEventStore.hs`

- [ ] **Step 1: Add banking fields to AppEnv**

In `src/Infrastructure/App.hs`, add imports and fields to `AppEnv`:

```haskell
-- Add fields:
bankImportReadModel :: !(TVar BankImportReadModel),
bankLinkState :: !(TVar BankLinkState),
httpManager :: !Manager
```

Add Has* type classes:

```haskell
class HasBankImportReadModel env where
  bankImportReadModelL :: Lens' env (TVar BankImportReadModel)

class HasBankLinkState env where
  bankLinkStateL :: Lens' env (TVar BankLinkState)

class HasHttpManager env where
  httpManagerL :: Lens' env Manager
```

With instances for `AppEnv`.

Update `initializeAppEnv` to accept and wire the new fields.

- [ ] **Step 2: Wire read model handlers in Eventium.hs**

In `src/Infrastructure/Eventium.hs`, update `ReadModels` to include `bankImport` and `bankLink` fields. Update `createReadModelHandlers` to create and register handlers for `BankImportReadModel` and `BankLinkState`.

- [ ] **Step 3: Wire in Main.hs**

In `app/Main.hs`, create `Manager` via `newManager tlsManagerSettings` and pass to `initializeAppEnv`. Import `Network.HTTP.Client.TLS`.

- [ ] **Step 4: Update test AppEnv**

In `test/Testkit/InMemoryEventStore.hs`, create banking read models and add them to the test `AppEnv`. Use `error "HTTP manager not available in tests"` for the manager field.

- [ ] **Step 5: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All pass

- [ ] **Step 6: Commit**

```bash
git add src/Infrastructure/App.hs src/Infrastructure/Eventium.hs app/Main.hs test/Testkit/InMemoryEventStore.hs
git commit -m "feat: wire banking read models and HTTP manager into AppEnv"
```

---

## Task 10: BankImportService

**Files:**
- Create: `src/Application/Services/BankImportService.hs`
- Test: `test/Application/Services/BankImportServiceSpec.hs` (create)

This is the main orchestration service. Start with the resync flow since it's the primary testing path.

- [ ] **Step 1: Write tests for import orchestration logic**

Create `test/Application/Services/BankImportServiceSpec.hs` with tests for:
- Skipping hold transactions
- Skipping already-imported transactions (dedup)
- Matching bank account by accountNumber to local AccountId
- Discarding unmatched accounts with warning
- Converting amount from minor units to Rational
- Using classifyTransaction result for transfer type
- Setting occurredAt from bank transaction time

Use the in-memory test environment (`createTestAppEnvWithProcessManager`).

- [ ] **Step 2: Implement BankImportService**

Create `src/Application/Services/BankImportService.hs`:

Key functions:
- `resync :: UserId -> UTCTime -> UTCTime -> AppM (Either DomainError [TransactionId])` — fetch statements and import
- `processWebhookEvent :: UserId -> Text -> BankTransaction -> AppM (Either DomainError (Maybe TransactionId))` — single transaction import
- `importTransaction :: UserId -> BankProvider -> UserBankLink -> AccountId -> BankTransaction -> AppM (Either DomainError (Maybe TransactionId))` — core import logic
- `linkBankAccounts :: UserId -> BankProvider -> AppM (Either DomainError ())` — activation flow
- `unlinkBankAccounts :: UserId -> AppM (Either DomainError ())` — deactivation

The service needs:
- Access to `BankImportReadModel` (dedup check)
- Access to `BankLinkState` (account mappings)
- Access to `AccountReadModel` (External account lookup)
- Access to `UserReadModel` (user's external account ID)
- Access to event store writer/reader (issue InitiateTransfer commands)
- Access to `AppConfig` (banking config, api_base_url)

For the resync flow:
1. Look up user config → get token (for v1, token is passed in the resync request or read from user config; see note below)
2. Create BankProvider via `mkMonobankProvider`
3. Look up UserBankLink from BankLinkState
4. Fetch statements
5. For each: skip holds, check dedup, match account, classify, create InitiateTransfer command

**Category resolution (after classification):**
After `classifyTransaction` returns a `ClassifiedExpense (Maybe DictionaryEntryId)` or `ClassifiedIncome`, the service resolves the final category:
1. If the classification already includes a `Just categoryId`, use it
2. Otherwise, look up user's `category_mappings` by the provider-specific key (e.g., MCC code string for Monobank) from user config
3. If no mapping found, fall back to user's `default_category`
4. If no default configured, use the first category from the user's dictionary (or skip with warning)

**Writing application-level events (`BankAccountsLinked` / `BankAccountsUnlinked`):**
These are NOT aggregate events — they don't go through a command handler. Write them directly to the event store using a dedicated stream key (e.g., the userId UUID) via the tagged event store writer. The event bus will pick them up and update the `BankLinkState` read model. Use the `bankLinkEventEmbedding` to embed them into `AccountingEvent`.

**Note on user banking config:**
For the initial implementation, the user's Monobank token and category mappings are part of the `UserConfiguration` aggregate. Extending `UserConfiguration` with banking fields is tracked as a separate concern — for the initial resync endpoint, the token can be passed directly in the request body to simplify testing. The full user config integration (storing token, category mappings, default_category) should be added when wiring the activation flow.

- [ ] **Step 3: Run tests**

Run: `cabal test all --test-option='--match' --test-option="/BankImportService/"`
Expected: Pass

- [ ] **Step 4: Commit**

```bash
git add src/Application/Services/BankImportService.hs test/Application/Services/BankImportServiceSpec.hs
git commit -m "feat: add BankImportService with resync flow"
```

---

## Task 11: Banking Web API

**Files:**
- Create: `src/Web/API/BankingAPI.hs`
- Modify: `src/Web/API.hs`

- [ ] **Step 1: Create BankingAPI module**

Create `src/Web/API/BankingAPI.hs` with:

```haskell
type BankingAPI =
  -- GET /api/banking/webhook/:userId/:secret — Monobank validation
  "api" :> "banking" :> "webhook" :> Capture "userId" UUID :> Capture "secret" Text :> Get '[JSON] NoContent
  -- POST /api/banking/webhook/:userId/:secret — Monobank webhook event
  :<|> "api" :> "banking" :> "webhook" :> Capture "userId" UUID :> Capture "secret" Text :> ReqBody '[JSON] Value :> Post '[JSON] NoContent
  -- POST /api/banking/resync — manual resync (authenticated)
  :<|> AuthProtect "jwt" :> "api" :> "banking" :> "resync" :> ReqBody '[JSON] ResyncRequest :> Post '[JSON] ResyncResponse

data ResyncRequest = ResyncRequest
  { from :: UTCTime,
    to :: UTCTime
  }

data ResyncResponse = ResyncResponse
  { importedCount :: Int,
    skippedCount :: Int
  }
```

Handlers:
- `webhookValidationHandler` — return 200 (NoContent)
- `webhookEventHandler` — parse payload, validate secret, call `BankImportService.processWebhookEvent`
- `resyncHandler` — validate date range (max 31 days), call `BankImportService.resync`

- [ ] **Step 2: Wire into combined API**

In `src/Web/API.hs`:
- Import `Web.API.BankingAPI`
- Add `BankingAPI` to `type API = ...` union
- Add `bankingServer` to `server = ...`

- [ ] **Step 3: Verify it compiles**

Run: `cabal build`

- [ ] **Step 4: Commit**

```bash
git add src/Web/API/BankingAPI.hs src/Web/API.hs
git commit -m "feat: add banking webhook and resync API endpoints"
```

---

## Task 12: Integration Test

**Files:**
- Create: `test/Integration/BankImportWorkflowSpec.hs`

- [ ] **Step 1: Write integration test for resync flow**

Test end-to-end:
1. Create test AppEnv with process manager
2. Register a user (via `applyUserCommand`)
3. Create a Bank account with `accountNumber` set to an IBAN
4. Emit a `BankAccountsLinked` event manually (or call `linkBankAccounts` with a mock provider)
5. Call `BankImportService.resync` with a mock provider that returns test statements
6. Verify: transactions created in `TransactionReadModel`
7. Verify: dedup — re-running resync with same statements produces no new transactions
8. Verify: hold transactions are skipped

The mock provider can be constructed inline:

```haskell
mockProvider :: BankProvider
mockProvider = BankProvider
  { providerName = "mock",
    fetchAccounts = return $ Right [...],
    fetchStatements = \_ _ _ -> return $ Right [...],
    registerWebhook = \_ -> return $ Right (),
    classifyTransaction = \tx -> if tx.amount >= 0 then ClassifiedIncome Nothing else ClassifiedExpense Nothing
  }
```

- [ ] **Step 2: Run integration test**

Run: `cabal test all --test-option='--match' --test-option="/BankImportWorkflow/"`
Expected: Pass

- [ ] **Step 3: Run full test suite**

Run: `cabal test --test-show-details=direct`
Expected: All pass

- [ ] **Step 4: Commit**

```bash
git add test/Integration/BankImportWorkflowSpec.hs
git commit -m "test: add integration tests for bank import workflow"
```

---

## Task 13: Format, Lint, Final Checks

- [ ] **Step 1: Run formatter**

Run: `just format`

- [ ] **Step 2: Run linter**

Run: `just lint`
Fix any issues.

- [ ] **Step 3: Run full test suite**

Run: `just test`
Expected: All pass

- [ ] **Step 4: Run build with CI flags**

Run: `cabal build -fci`
Expected: No warnings

- [ ] **Step 5: Final commit if needed**

```bash
git add -A
git commit -m "chore: format and lint fixes"
```
