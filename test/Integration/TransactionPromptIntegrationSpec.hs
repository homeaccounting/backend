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
import Application.Services.AccountService (shareAccount)
import Application.Services.ConfigurationService (seedDefaultConfiguration)
import Application.Services.Prompt.Types
  ( FailedTransaction (..),
    PromptError (..),
    PromptResult (..),
    RecordedTransaction (..),
  )
import Application.Services.PromptService (handlePrompt)
import Data.Ratio ((%))
import Domain.Configuration.Defaults
  ( expenseCategoryDictKind,
    incomeCategoryDictKind,
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
    unAccountId,
    unMoney,
    unUserId,
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
  -- Fund Cash well above every test amount: a Regular account defaults to a
  -- zero overdraft limit, so an unfunded source would make the posting saga
  -- reject every expense/transfer debit (InsufficientFunds) and no happy-path
  -- transaction would actually post.
  cash <- createAccount e uid "Cash" defaultCash Core.UAH 1000000
  pure Harness {env = e, user = uid, cashAccount = cash}

-- | The deterministic id of the default "Groceries" expense category.
groceriesCategoryId :: CategoryId
groceriesCategoryId = mkDeterministicEntryId expenseCategoryDictKind "Groceries"

-- | The deterministic id of the configured default expense category ("Other").
-- 'seedDefaultConfiguration' sets the default expense category to "Other", whose
-- id is deterministic in the expense-category dictionary.
defaultExpenseCategoryId :: CategoryId
defaultExpenseCategoryId = mkDeterministicEntryId expenseCategoryDictKind "Other"

-- | The deterministic id of the default "Salary" income category, seeded by
-- 'seedDefaultConfiguration' in the income-category dictionary.
salaryCategoryId :: CategoryId
salaryCategoryId = mkDeterministicEntryId incomeCategoryDictKind "Salary"

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

-- | The single committed transaction from a one-element, no-failure result.
soleRecorded :: Either PromptError PromptResult -> Either String TransactionData
soleRecorded (Right (TransactionsRecorded [r] [])) = Right r.tx
soleRecorded other = Left ("expected exactly one recorded transaction, got: " <> show other)

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
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Groceries\",\"comment\":\"cash 123 food\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 123 food")
    case result of
      Right (TransactionsRecorded [r] []) -> do
        let td = r.tx
        td.sourceAccountId `shouldBe` h.cashAccount
        unMoney td.sourceAmount `shouldBe` 123
        expenseCategoryOf td `shouldBe` Just groceriesCategoryId
        ("Cash" `T.isInfixOf` r.interpretation) `shouldBe` True
      other -> expectationFailure ("expected one recorded transaction, got: " <> show other)

  it "resolves and commits against an account shared to the user" $ do
    h <- setupHarness "prompt-shared-grantee@example.com"
    -- A second user owns "Joint" (UAH, so the seeded rates cover the
    -- cross-currency counter-leg) and shares it to the harness user as Editor.
    owner <- registerUser h.env "prompt-shared-owner@example.com"
    joint <- createAccount h.env owner "Joint" defaultCash Core.UAH 1000000
    shareRes <-
      runAppM h.env
        $ shareAccount owner (unAccountId joint) (unUserId h.user) "editor"
    shareRes `shouldBe` Right ()

    -- The prompt names the shared account by name; it resolves only because the
    -- prompt context now lists owner+shared accounts, not owner-only.
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Joint\",\"allocations\":[{\"amount\":\"75\",\"category\":\"Groceries\",\"comment\":\"joint 75 food\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "joint 75 food")
    case soleRecorded result of
      Right td -> do
        td.sourceAccountId `shouldBe` joint
        unMoney td.sourceAmount `shouldBe` 75
        expenseCategoryOf td `shouldBe` Just groceriesCategoryId
      Left msg -> expectationFailure msg

  it "falls back to the default category when the named category is unknown" $ do
    h <- setupHarness "prompt-default-cat@example.com"
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"50\",\"category\":\"Xyz\",\"comment\":\"cash 50 xyz\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 50 xyz")
    case soleRecorded result of
      Right td -> do
        unMoney td.sourceAmount `shouldBe` 50
        expenseCategoryOf td `shouldBe` Just defaultExpenseCategoryId
      Left msg -> expectationFailure msg

  it "preserves five per-line allocations (comments + categories) without merging" $ do
    h <- setupHarness "prompt-multi-alloc@example.com"
    -- The issue's example: one expense with five allocation lines; four share
    -- "Groceries", one has a null category (falls back to the default). No merge of
    -- duplicate categories; each line keeps its own comment. Cyrillic comments
    -- must round-trip exactly (Text literal is Unicode, so no truncation).
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[\
          \{\"amount\":\"200\",\"category\":\"Groceries\",\"comment\":\"огірки розсада\"},\
          \{\"amount\":\"700\",\"category\":null,\"comment\":\"квіти\"},\
          \{\"amount\":\"200\",\"category\":\"Groceries\",\"comment\":\"яйця\"},\
          \{\"amount\":\"500\",\"category\":\"Groceries\",\"comment\":\"овочі\"},\
          \{\"amount\":\"160\",\"category\":\"Groceries\",\"comment\":\"огірки зелень\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "огірки розсада 200 квіти 700 яйця 200 овочі 500 огірки зелень 160")
    case soleRecorded result of
      Right td -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        case allocationsOf td.transactionType of
          Just allocs -> do
            length allocs.expenses `shouldBe` 5
            map (.comment) allocs.expenses
              `shouldBe` [ Just "огірки розсада",
                           Just "квіти",
                           Just "яйця",
                           Just "овочі",
                           Just "огірки зелень"
                         ]
            sum (map (unMoney . (.amount)) allocs.expenses) `shouldBe` 1760
            -- The four "Groceries" lines (positions 1,3,4,5) share one category id;
            -- the null-category line (position 2) resolves to the default,
            -- which differs from "Groceries".
            map (.categoryId) allocs.expenses
              `shouldBe` [ groceriesCategoryId,
                           defaultExpenseCategoryId,
                           groceriesCategoryId,
                           groceriesCategoryId,
                           groceriesCategoryId
                         ]
          Nothing -> expectationFailure "expected Expense allocations"
      Left msg -> expectationFailure msg

  it "reports an unresolvable account as a failed row, committing nothing" $ do
    h <- setupHarness "prompt-bad-acct@example.com"
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Nope\",\"allocations\":[{\"amount\":\"10\",\"category\":\"Groceries\",\"comment\":\"nope 10 food\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "nope 10 food")
    case result of
      Right (TransactionsRecorded [] [f]) -> f.index `shouldBe` 0
      other -> expectationFailure ("expected one failed transaction, got: " <> show other)

  it "reports an expense that fails to post (insufficient funds) as a failed row, committing nothing" $ do
    h <- setupHarness "prompt-insufficient@example.com"
    -- A fresh regular account starts at a zero balance with the default zero
    -- overdraft limit, so the synchronous posting saga rejects any expense debit
    -- against it (InsufficientFunds) instead of completing it. Such a row must
    -- surface as a failure — never as a recorded transaction carrying a Failed
    -- status.
    _empty <- createAccount h.env h.user "Empty" defaultCash Core.UAH 0
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Empty\",\"allocations\":[{\"amount\":\"50\",\"category\":\"Groceries\",\"comment\":\"empty 50 food\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "empty 50 food")
    case result of
      Right (TransactionsRecorded [] [f]) -> do
        f.index `shouldBe` 0
        f.reason `shouldBe` "Insufficient funds"
      other -> expectationFailure ("expected one failed (insufficient funds) transaction, got: " <> show other)

  it "yields PromptFeatureDisabled when the LLM feature is disabled (no client injected)" $ do
    h <- setupHarness "prompt-disabled@example.com"
    -- env.llmClient is Nothing on the base test env.
    result <- runAppM h.env (handlePrompt h.user Nothing "cash 123 food")
    case result of
      Left PromptFeatureDisabled -> pure ()
      other -> expectationFailure ("expected Left PromptFeatureDisabled, got: " <> show other)

  it "rejects empty/whitespace prompt text before reaching the LLM (PromptDomainError)" $ do
    h <- setupHarness "prompt-empty@example.com"
    -- Use the disabled (no-client) env: a PromptDomainError here proves the
    -- empty-text guard ran before the client/feature check, so the LLM (absent
    -- anyway) is never consulted.
    result <- runAppM h.env (handlePrompt h.user Nothing "   ")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "retries once on a malformed response then commits on the valid retry" $ do
    h <- setupHarness "prompt-retry-recover@example.com"
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Groceries\",\"comment\":\"cash 123 food\"}]}]}"
    client <- queueLlmClient ["not json", json]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 123 food")
    case soleRecorded result of
      Right td -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        unMoney td.sourceAmount `shouldBe` 123
        expenseCategoryOf td `shouldBe` Just groceriesCategoryId
      Left msg -> expectationFailure msg

  it "surfaces a 502 (PromptUpstreamError) when the retry is also unparseable" $ do
    h <- setupHarness "prompt-retry-exhausted@example.com"
    client <- queueLlmClient ["not json", "still not json"]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 123 food")
    case result of
      Left err | isUpstream err -> pure ()
      other -> expectationFailure ("expected Left (PromptUpstreamError _), got: " <> show other)

  it "surfaces a 502 (PromptUpstreamError) on a transport failure" $ do
    h <- setupHarness "prompt-transport-fail@example.com"
    -- Empty queue: the very first 'complete' returns Left "stub exhausted".
    client <- queueLlmClient []
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 123 food")
    case result of
      Left err | isUpstream err -> pure ()
      other -> expectationFailure ("expected Left (PromptUpstreamError _), got: " <> show other)

  it "rejects an unknown intent with a domain error (400)" $ do
    h <- setupHarness "prompt-unknown-intent@example.com"
    let e = withLlmClient (constLlmClient "{\"intent\":\"build_report\"}") h.env
    result <- runAppM e (handlePrompt h.user Nothing "give me a report")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "commits income into the target account with the resolved income category" $ do
    h <- setupHarness "prompt-income@example.com"
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"income\",\"targetAccount\":\"Cash\",\"allocations\":[{\"amount\":\"5000\",\"category\":\"Salary\",\"comment\":\"salary 5000 to cash\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "salary 5000 to cash")
    case soleRecorded result of
      Right td -> do
        -- Income flows External -> Cash, so Cash is the *target* leg.
        td.targetAccountId `shouldBe` h.cashAccount
        unMoney td.targetAmount `shouldBe` 5000
        incomeCategoryOf td `shouldBe` Just salaryCategoryId
      Left msg -> expectationFailure msg

  it "records against the selected account when the prompt names none" $ do
    h <- setupHarness "prompt-selected-acct@example.com"
    -- A second account so the selection is distinguishable from any inference
    -- default. The LLM returns no sourceAccount; the selection must fill it.
    -- Funded because the selection makes it the debited source.
    card <- createAccount h.env h.user "Card" defaultCash Core.UAH 1000000
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"allocations\":[{\"amount\":\"42\",\"category\":\"Groceries\",\"comment\":\"snack\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user (Just card) "snack 42")
    case soleRecorded result of
      Right td -> do
        td.sourceAccountId `shouldBe` card
        unMoney td.sourceAmount `shouldBe` 42
      Left msg -> expectationFailure msg

  it "lets an account named in the prompt override the selection" $ do
    h <- setupHarness "prompt-selected-override@example.com"
    card <- createAccount h.env h.user "Card" defaultCash Core.UAH 0
    -- The prompt explicitly names "Cash"; even with "Card" selected, the
    -- explicit name must win.
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"10\",\"category\":\"Groceries\",\"comment\":\"cash 10 food\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user (Just card) "cash 10 food")
    case soleRecorded result of
      Right td -> td.sourceAccountId `shouldBe` h.cashAccount
      Left msg -> expectationFailure msg

  it "commits a transfer between two resolved regular accounts" $ do
    h <- setupHarness "prompt-transfer@example.com"
    -- Seed a second UAH regular account so a same-currency transfer resolves
    -- without a cross-currency rate.
    card <- createAccount h.env h.user "Card" defaultCash Core.UAH 0
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"transfer\",\"amount\":\"200\",\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\"}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "move 200 from cash to card")
    case soleRecorded result of
      Right td -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        td.targetAccountId `shouldBe` card
        unMoney td.sourceAmount `shouldBe` 200
      Left msg -> expectationFailure msg

  it "records three distinct transactions from one capture (income + two expenses)" $ do
    h <- setupHarness "prompt-multi@example.com"
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[\
          \{\"kind\":\"income\",\"targetAccount\":\"Cash\",\"allocations\":[{\"amount\":\"5000\",\"category\":\"Salary\",\"comment\":null}]},\
          \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"45\",\"category\":null,\"comment\":\"coffee\"}]},\
          \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"120\",\"category\":null,\"comment\":\"taxi\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "salary 5000 to cash, coffee 45 cash, taxi 120 cash")
    case result of
      Right (TransactionsRecorded succeeded failed) -> do
        length succeeded `shouldBe` 3
        failed `shouldBe` []
      other -> expectationFailure ("expected three recorded, got: " <> show other)

  it "splits one payment across categories as a single transaction with two allocations" $ do
    h <- setupHarness "prompt-split@example.com"
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[\
          \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[\
          \{\"amount\":\"20\",\"category\":\"Groceries\",\"comment\":\"milk\"},\
          \{\"amount\":\"15\",\"category\":\"Groceries\",\"comment\":\"bread\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "milk 20, bread 15 cash")
    case soleRecorded result of
      Right td -> case allocationsOf td.transactionType of
        Just allocs -> length allocs.expenses `shouldBe` 2
        Nothing -> expectationFailure "expected expense allocations"
      Left msg -> expectationFailure msg

  it "commits the good transactions and reports the bad one (partial failure)" $ do
    h <- setupHarness "prompt-partial@example.com"
    -- The second element names an account that does not resolve; it must fail
    -- while the first still commits.
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[\
          \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"10\",\"category\":\"Groceries\",\"comment\":null}]},\
          \{\"kind\":\"expense\",\"sourceAccount\":\"Nope\",\"allocations\":[{\"amount\":\"20\",\"category\":\"Groceries\",\"comment\":null}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 10 food; nope 20 food")
    case result of
      Right (TransactionsRecorded succeeded failed) -> do
        length succeeded `shouldBe` 1
        map (.index) failed `shouldBe` [1]
      other -> expectationFailure ("expected one recorded + one failed, got: " <> show other)

  it "commits the well-formed transactions and reports a malformed element (decode tolerance)" $ do
    h <- setupHarness "prompt-decode-partial@example.com"
    -- The second element omits the required 'kind' field, so it fails to decode;
    -- the batch is no longer rejected wholesale — the first element still commits
    -- and the malformed one is reported at its position.
    let json =
          "{\"intent\":\"record_transactions\",\"transactions\":[\
          \{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"10\",\"category\":\"Groceries\",\"comment\":null}]},\
          \{\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"20\"}]}]}"
        e = withLlmClient (constLlmClient json) h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 10 food; junk")
    case result of
      Right (TransactionsRecorded succeeded failed) -> do
        length succeeded `shouldBe` 1
        map (.index) failed `shouldBe` [1]
      other -> expectationFailure ("expected one recorded + one failed decode, got: " <> show other)

  it "returns a domain error when every transaction element is malformed (after retry)" $ do
    h <- setupHarness "prompt-all-malformed@example.com"
    -- Valid envelope, but every element lacks the required 'kind' — zero usable
    -- rows. Treated like the empty-list case: retry once, then a 400 (not a 502,
    -- since the envelope itself parsed cleanly).
    let bad = "{\"intent\":\"record_transactions\",\"transactions\":[{\"sourceAccount\":\"Cash\"},{\"sourceAccount\":\"Card\"}]}"
    client <- queueLlmClient [bad, bad]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "gibberish")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "returns a domain error when the model identifies no transaction (empty list after retry)" $ do
    h <- setupHarness "prompt-empty-list@example.com"
    client <-
      queueLlmClient
        [ "{\"intent\":\"record_transactions\",\"transactions\":[]}",
          "{\"intent\":\"record_transactions\",\"transactions\":[]}"
        ]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "hello there")
    case result of
      Left err | isDomainErr err -> pure ()
      other -> expectationFailure ("expected Left (PromptDomainError _), got: " <> show other)

  it "retries once on an empty transactions list then commits on the non-empty retry" $ do
    h <- setupHarness "prompt-empty-then-recover@example.com"
    client <-
      queueLlmClient
        [ "{\"intent\":\"record_transactions\",\"transactions\":[]}",
          "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Groceries\",\"comment\":null}]}]}"
        ]
    let e = withLlmClient client h.env
    result <- runAppM e (handlePrompt h.user Nothing "cash 123 food")
    case soleRecorded result of
      Right td -> do
        td.sourceAccountId `shouldBe` h.cashAccount
        unMoney td.sourceAmount `shouldBe` 123
      Left msg -> expectationFailure msg
