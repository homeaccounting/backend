{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.TransactionPromptIntegrationSpec
-- Description : End-to-end proof of the natural-language prompt pipeline.
--
-- Drives 'handlePrompt' through the whole stack with in-memory event stores
-- and the transfer process manager enabled, using a stub 'LlmClient' that
-- returns a fixed JSON envelope. Verifies that a happy-path expense actually
-- commits (asserted against the transaction read model), that an unresolvable
-- account is rejected ('PromptDomainError'), that an unknown category falls back
-- to the configured default, and that a disabled LLM feature yields
-- 'PromptFeatureDisabled'. The Web boundary (a later task) maps 'PromptError' to
-- HTTP; this spec asserts on the pure 'Either PromptError PromptResult'.
module Integration.TransactionPromptIntegrationSpec (spec) where

import Application.ReadModels.Transaction (TransactionData (..))
import Application.Services.ConfigurationService (seedDefaultConfiguration)
import Application.Services.Prompt.Types (PromptError (..), PromptResult (..))
import Application.Services.PromptService (handlePrompt)
import Data.Ratio ((%))
import Domain.Configuration.Defaults
  ( expenseCategoryDictId,
    incomeCategoryDictId,
    mkDeterministicEntryId,
  )
import Domain.Core.Types
  ( AccountId,
    Allocation (..),
    Allocations (..),
    CategoryId,
    UserId,
    allocationsOf,
    defaultCash,
    unMoney,
  )
import qualified Domain.Core.Types as Core (Currency (..))
import Infrastructure.App (AppEnv, runAppM)
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Testkit.Fixtures (createAccount, registerUser, seedExchangeRates)
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Llm (constLlmClient, queueLlmClient, withLlmClient)

-- -----------------------------------------------------------------------------
-- Harness
-- -----------------------------------------------------------------------------

data Harness = Harness
  { env :: !AppEnv,
    user :: !UserId,
    cashAccount :: !AccountId
  }

-- | Seed a user with the default configuration and a UAH "Cash" regular
-- account, plus a UAH<->USD rate so the (USD External) counter-leg resolves.
setupHarness :: Text -> IO Harness
setupHarness email = do
  e <- createTestAppEnvWithProcessManager
  runAppM e seedDefaultConfiguration
  uid <- registerUser e email
  -- Default base currency is USD, so the auto-created External account is USD.
  -- A UAH Cash account makes the expense cross-currency; seed both rate legs.
  seedExchangeRates e [(Core.UAH, Core.USD, 1 % 40), (Core.USD, Core.UAH, 40 % 1)]
  cash <- createAccount e uid "Cash" defaultCash Core.UAH 0
  pure Harness {env = e, user = uid, cashAccount = cash}

-- | The deterministic id of the default "Food" expense category.
foodCategoryId :: CategoryId
foodCategoryId = mkDeterministicEntryId expenseCategoryDictId "Food"

-- | The deterministic id of the configured default expense category ("Other").
-- 'seedDefaultConfiguration' sets the default expense category to "Other", whose
-- id is deterministic in the expense-category dictionary.
defaultExpenseCategoryId :: CategoryId
defaultExpenseCategoryId = mkDeterministicEntryId expenseCategoryDictId "Other"

-- | The deterministic id of the default "Salary" income category, seeded by
-- 'seedDefaultConfiguration' in the income-category dictionary.
salaryCategoryId :: CategoryId
salaryCategoryId = mkDeterministicEntryId incomeCategoryDictId "Salary"

-- | The single expense allocation's category id on a committed transaction.
expenseCategoryOf :: TransactionData -> Maybe CategoryId
expenseCategoryOf td = case allocationsOf td.transactionType of
  Just allocs -> case allocs.expenses of
    (a : _) -> Just a.categoryId
    [] -> Nothing
  Nothing -> Nothing

-- | The single income allocation's category id on a committed transaction.
incomeCategoryOf :: TransactionData -> Maybe CategoryId
incomeCategoryOf td = case allocationsOf td.transactionType of
  Just allocs -> case allocs.incomes of
    (a : _) -> Just a.categoryId
    [] -> Nothing
  Nothing -> Nothing

-- | 'True' iff the error is a 502-mapped upstream failure.
isUpstream :: PromptError -> Bool
isUpstream (PromptUpstreamError _) = True
isUpstream _ = False

-- | 'True' iff the error is a domain/validation failure (400-mapped).
isDomainErr :: PromptError -> Bool
isDomainErr (PromptDomainError _) = True
isDomainErr _ = False

-- -----------------------------------------------------------------------------
-- Specs
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration.TransactionPrompt / handlePrompt" $ do
  it "commits an expense from a resolved account and category (happy path)" $ do
    h <- setupHarness "prompt-expense@example.com"
    let json =
          "{\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":\"123\",\"sourceAccount\":\"Cash\",\"category\":\"Food\"}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user "cash 123 food")
    case result of
      Right (TransactionCreated interp _ td) -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        unMoney td.sourceAmount `shouldBe` 123
        expenseCategoryOf td `shouldBe` Just foodCategoryId
        ("Cash" `T.isInfixOf` interp) `shouldBe` True
      other -> expectationFailure ("expected TransactionCreated, got: " <> show other)

  it "falls back to the default category when the named category is unknown" $ do
    h <- setupHarness "prompt-default-cat@example.com"
    let json =
          "{\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":\"50\",\"sourceAccount\":\"Cash\",\"category\":\"Xyz\"}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user "cash 50 xyz")
    case result of
      Right (TransactionCreated _ _ td) -> do
        unMoney td.sourceAmount `shouldBe` 50
        expenseCategoryOf td `shouldBe` Just defaultExpenseCategoryId
      other -> expectationFailure ("expected TransactionCreated, got: " <> show other)

  it "rejects an unresolvable account (PromptDomainError)" $ do
    h <- setupHarness "prompt-bad-acct@example.com"
    let json =
          "{\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":\"10\",\"sourceAccount\":\"Nope\",\"category\":\"Food\"}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user "nope 10 food")
    case result of
      Left (PromptDomainError _) -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "yields PromptFeatureDisabled when the LLM feature is disabled (no client injected)" $ do
    h <- setupHarness "prompt-disabled@example.com"
    -- env.llmClient is Nothing on the base test env.
    result <- runAppM h.env (handlePrompt h.user "cash 123 food")
    case result of
      Left PromptFeatureDisabled -> pure ()
      other -> expectationFailure ("expected Left PromptFeatureDisabled, got: " <> show other)

  it "rejects empty/whitespace prompt text before reaching the LLM (PromptDomainError)" $ do
    h <- setupHarness "prompt-empty@example.com"
    -- Use the disabled (no-client) env: a PromptDomainError here proves the
    -- empty-text guard ran before the client/feature check, so the LLM (absent
    -- anyway) is never consulted.
    result <- runAppM h.env (handlePrompt h.user "   ")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "retries once on a malformed response then commits on the valid retry" $ do
    h <- setupHarness "prompt-retry-recover@example.com"
    let json =
          "{\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":\"123\",\"sourceAccount\":\"Cash\",\"category\":\"Food\"}"
    client <- queueLlmClient ["not json", json]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user "cash 123 food")
    case result of
      Right (TransactionCreated _ _ td) -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        unMoney td.sourceAmount `shouldBe` 123
        expenseCategoryOf td `shouldBe` Just foodCategoryId
      other -> expectationFailure ("expected TransactionCreated after retry, got: " <> show other)

  it "surfaces a 502 (PromptUpstreamError) when the retry is also unparseable" $ do
    h <- setupHarness "prompt-retry-exhausted@example.com"
    client <- queueLlmClient ["not json", "still not json"]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user "cash 123 food")
    case result of
      Left err | isUpstream err -> pure ()
      other -> expectationFailure ("expected Left (PromptUpstreamError _), got: " <> show other)

  it "surfaces a 502 (PromptUpstreamError) on a transport failure" $ do
    h <- setupHarness "prompt-transport-fail@example.com"
    -- Empty queue: the very first 'complete' returns Left "stub exhausted".
    client <- queueLlmClient []
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user "cash 123 food")
    case result of
      Left err | isUpstream err -> pure ()
      other -> expectationFailure ("expected Left (PromptUpstreamError _), got: " <> show other)

  it "rejects an unknown intent with a domain error (400)" $ do
    h <- setupHarness "prompt-unknown-intent@example.com"
    let e = withLlmClient (constLlmClient "{\"intent\":\"build_report\"}") h.env
    result <- runAppM e (handlePrompt h.user "give me a report")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "commits income into the target account with the resolved income category" $ do
    h <- setupHarness "prompt-income@example.com"
    let json =
          "{\"intent\":\"transaction\",\"kind\":\"income\",\"amount\":\"5000\",\"targetAccount\":\"Cash\",\"category\":\"Salary\"}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user "salary 5000 to cash")
    case result of
      Right (TransactionCreated _ _ td) -> do
        -- Income flows External -> Cash, so Cash is the *target* leg.
        td.targetAccountId `shouldBe` h.cashAccount
        unMoney td.targetAmount `shouldBe` 5000
        incomeCategoryOf td `shouldBe` Just salaryCategoryId
      other -> expectationFailure ("expected TransactionCreated (income), got: " <> show other)

  it "commits a transfer between two resolved regular accounts" $ do
    h <- setupHarness "prompt-transfer@example.com"
    -- Seed a second UAH regular account so a same-currency transfer resolves
    -- without a cross-currency rate.
    card <- createAccount h.env h.user "Card" defaultCash Core.UAH 0
    let json =
          "{\"intent\":\"transaction\",\"kind\":\"transfer\",\"amount\":\"200\",\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\"}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user "move 200 from cash to card")
    case result of
      Right (TransactionCreated _ _ td) -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        td.targetAccountId `shouldBe` card
        unMoney td.sourceAmount `shouldBe` 200
      other -> expectationFailure ("expected TransactionCreated (transfer), got: " <> show other)
