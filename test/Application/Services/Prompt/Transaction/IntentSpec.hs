{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.Transaction.IntentSpec (spec) where

import Application.Services.Prompt.Transaction.Intent
  ( IntentAllocation (..),
    IntentKind (..),
    PromptContext (..),
    TransactionDecodeError (..),
    TransactionIntent (..),
    decodeRecordTransactions,
    decodeTransactionIntent,
    recordTransactionsGuide,
  )
import qualified Data.Text as DT
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T
import Test.Hspec

-- | Encode a JSON 'Text' as a UTF-8 lazy 'ByteString'. Necessary for the
-- Cyrillic examples: an 'IsString' 'ByteString' literal truncates each char to
-- a byte (Latin1), corrupting multibyte text; going through 'encodeUtf8' keeps
-- the bytes correct.
utf8 :: T.Text -> BL.ByteString
utf8 = BL.fromStrict . T.encodeUtf8

sampleContext :: PromptContext
sampleContext =
  PromptContext
    { accountNames = ["Cash", "Card"],
      incomeCategoryNames = ["Salary"],
      expenseCategoryNames = ["Food", "Transport"],
      labelNames = []
    }

-- | A localized (Ukrainian) context: category names are Cyrillic, none of the
-- historical English literals ("Food / Groceries", "Salary") appear. Mirrors a
-- user whose default categories were relocalized to their app language.
ukContext :: PromptContext
ukContext =
  PromptContext
    { accountNames = ["Готівка", "Картка"],
      incomeCategoryNames = ["Дохід / Зарплата"],
      expenseCategoryNames = ["Їжа / Продукти", "Транспорт"],
      labelNames = []
    }

-- | Every quoted @"category":"X"@ value appearing in the guide's examples.
-- @"category":null@ (no opening quote after the colon) is deliberately skipped.
exampleCategories :: T.Text -> [T.Text]
exampleCategories g = [T.takeWhile (/= '"') after | after <- drop 1 (DT.splitOn marker g)]
  where
    marker = "\"category\":\""

spec :: Spec
spec = describe "Application.Services.Prompt.Transaction.Intent" $ do
  describe "decodeTransactionIntent" $ do
    it "decodes an expense with a single allocation" $ do
      let j = "{\"kind\":\"expense\",\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null,\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` ExpenseKind
          i.sourceAccount `shouldBe` Just "Cash"
          map (.amount) i.allocations `shouldBe` ["123"]
          map (.category) i.allocations `shouldBe` [Just "Food"]
        Left e -> expectationFailure (T.unpack e)
    it "decodes a transfer" $ do
      let j = "{\"kind\":\"transfer\",\"amount\":\"200\",\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\"}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` TransferKind
          i.amount `shouldBe` Just "200"
        Left e -> expectationFailure (T.unpack e)
    it "ignores the envelope intent field when present" $ do
      let j = "{\"intent\":\"record_transactions\",\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"5\",\"category\":null,\"comment\":null}]}"
      case decodeTransactionIntent j of
        Right i -> do
          i.kind `shouldBe` ExpenseKind
          map (.amount) i.allocations `shouldBe` ["5"]
        Left e -> expectationFailure (T.unpack e)
    it "decodes the 5-line issue example: each line is one allocation with its comment" $ do
      let js =
            "{\"intent\":\"record_transactions\",\"kind\":\"expense\",\"currency\":null,\
            \\"sourceAccount\":null,\"targetAccount\":null,\"description\":null,\"date\":null,\
            \\"allocations\":[\
            \{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"огірки розсада\"},\
            \{\"amount\":\"700\",\"category\":null,\"comment\":\"квіти\"},\
            \{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"яйця\"},\
            \{\"amount\":\"500\",\"category\":\"Food\",\"comment\":\"овочі\"},\
            \{\"amount\":\"160\",\"category\":\"Food\",\"comment\":\"огірки зелень\"}]}"
      case decodeTransactionIntent (utf8 js) of
        Right ti -> do
          ti.kind `shouldBe` ExpenseKind
          length ti.allocations `shouldBe` 5
          map (.amount) ti.allocations `shouldBe` ["200", "700", "200", "500", "160"]
          map (.comment) ti.allocations
            `shouldBe` map Just ["огірки розсада", "квіти", "яйця", "овочі", "огірки зелень"]
        Left e -> expectationFailure (T.unpack e)
    it "decodes a transfer with a top-level amount and no allocations" $ do
      let js =
            "{\"intent\":\"record_transactions\",\"kind\":\"transfer\",\"amount\":\"200\",\
            \\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\",\"currency\":null,\
            \\"description\":null,\"date\":null}"
      case decodeTransactionIntent js of
        Right ti -> do
          ti.kind `shouldBe` TransferKind
          ti.amount `shouldBe` Just "200"
        Left e -> expectationFailure (T.unpack e)
    it "rejects an unknown kind"
      $ decodeTransactionIntent "{\"kind\":\"nonsense\",\"amount\":\"1\",\"sourceAccount\":\"x\"}"
      `shouldSatisfy` isLeft
    it "rejects non-JSON"
      $ decodeTransactionIntent "oops"
      `shouldSatisfy` isLeft
  describe "decodeRecordTransactions" $ do
    it "decodes a single-element transactions list" $ do
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}]}]}"
      case decodeRecordTransactions j of
        Right [Right ti] -> do
          ti.kind `shouldBe` ExpenseKind
          map (.amount) ti.allocations `shouldBe` ["123"]
        other -> expectationFailure ("expected one transaction, got: " <> show other)
    it "decodes a split-payment (one transaction, two allocations)" $ do
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"20\",\"category\":\"Food\",\"comment\":null},{\"amount\":\"15\",\"category\":\"Food\",\"comment\":null}]}]}"
      case decodeRecordTransactions j of
        Right [Right ti] -> map (.amount) ti.allocations `shouldBe` ["20", "15"]
        other -> expectationFailure ("expected one transaction, got: " <> show other)
    it "decodes a mixed multi-transaction list (distinct kinds/accounts)" $ do
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"income\",\"targetAccount\":\"Bank\",\"amount\":null,\"allocations\":[{\"amount\":\"5000\",\"category\":\"Salary\",\"comment\":null}]},{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"45\",\"category\":null,\"comment\":\"coffee\"}]},{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"120\",\"category\":null,\"comment\":\"taxi\"}]}]}"
      case decodeRecordTransactions j of
        Right rows -> do
          length rows `shouldBe` 3
          map (.kind) (rights rows) `shouldBe` [IncomeKind, ExpenseKind, ExpenseKind]
        other -> expectationFailure ("expected three transactions, got: " <> show other)
    it "recovers a malformed element as a Left, keeping the good ones" $ do
      -- One good expense followed by an element missing the required 'kind'.
      let j = "{\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"sourceAccount\":\"Cash\",\"allocations\":[{\"amount\":\"10\"}]},{\"sourceAccount\":\"Cash\"}]}"
      case decodeRecordTransactions j of
        Right [Right ti, Left (TransactionDecodeError _)] -> ti.kind `shouldBe` ExpenseKind
        other -> expectationFailure ("expected one good then one bad element, got: " <> show other)
    it "rejects a payload missing the transactions array"
      $ decodeRecordTransactions "{\"intent\":\"record_transactions\"}"
      `shouldSatisfy` isLeft
    it "recovers a single bad element (no kind) as a Left rather than failing the parse" $ do
      case decodeRecordTransactions "{\"transactions\":[{\"sourceAccount\":\"Cash\"}]}" of
        Right [Left (TransactionDecodeError _)] -> pure ()
        other -> expectationFailure ("expected one recovered bad element, got: " <> show other)
    it "rejects non-JSON"
      $ decodeRecordTransactions "oops"
      `shouldSatisfy` isLeft
  describe "recordTransactionsGuide" $ do
    let guide = recordTransactionsGuide sampleContext
    it "embeds account names" $ ("Cash" `T.isInfixOf` guide) `shouldBe` True
    it "embeds category names" $ ("Food" `T.isInfixOf` guide) `shouldBe` True
    it "mentions multilingual mapping" $ ("language" `T.isInfixOf` T.toLower guide) `shouldBe` True
    it "names the record_transactions intent" $ ("record_transactions" `T.isInfixOf` guide) `shouldBe` True
    it "states the split-vs-distinct rule" $ do
      ("allocation" `T.isInfixOf` T.toLower guide) `shouldBe` True
      ("transactions" `T.isInfixOf` guide) `shouldBe` True
    it "instructs mapping account type-words (any language) to a subtype keyword" $ do
      all (`T.isInfixOf` guide) ["\"cash\"", "\"card\"", "\"bank\"", "\"wallet\""] `shouldBe` True
      ("готівка" `T.isInfixOf` guide) `shouldBe` True
    it "draws every example category from the listed categories (no hardcoded names)" $ do
      -- The few-shot examples must never teach a category spelling the user's
      -- dictionary does not contain, or the model echoes it and the matcher
      -- (no cross-lingual mapping) drops it to the default category. For a
      -- localized user, that means the examples must use their localized names.
      let ukGuide = recordTransactionsGuide ukContext
          listed = ukContext.incomeCategoryNames <> ukContext.expenseCategoryNames
          used = exampleCategories ukGuide
      used `shouldSatisfy` (not . null)
      used `shouldSatisfy` all (`elem` listed)
    it "does not leak English default category names into a localized guide" $ do
      let ukGuide = recordTransactionsGuide ukContext
      ("Food / Groceries" `T.isInfixOf` ukGuide) `shouldBe` False
      ("\"category\":\"Salary\"" `T.isInfixOf` ukGuide) `shouldBe` False
