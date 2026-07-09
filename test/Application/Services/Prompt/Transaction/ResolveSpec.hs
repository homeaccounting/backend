{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.Transaction.ResolveSpec (spec) where

import Application.ReadModels.Account (RegularAccountData (..))
import Application.Services.Prompt.Transaction.Intent
  ( IntentAllocation (..),
    IntentKind (..),
    TransactionIntent (..),
  )
import Application.Services.Prompt.Transaction.Resolve
  ( ResolveContext (..),
    Resolved (..),
    resolveIntent,
  )
import Application.Services.Prompt.Types (ResolveError (..))
import qualified Data.Map.Strict as Map
import Data.Ratio ((%))
import qualified Data.Set as Set
import Data.Time (UTCTime (..), fromGregorian)
import Domain.Configuration.Projection (ConfigurationDefaults (..))
import Domain.Core.Types
  ( AccountId,
    AccountSubtypeKind (..),
    Allocation (..),
    Allocations (..),
    CategoryId,
    Currency (..),
    Money,
    mkMoney,
    unMoney,
  )
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck ((==>))
import Testkit.Helpers (mockAccountIdN, mockCategoryIdN)

-- | Build an @(id, 'RegularAccountData')@ pair with a zero UAH balance (the
-- resolver only reads the currency off the balance). The id is carried
-- outside the record, matching every other read-model @*Data@ convention.
acct :: Word32 -> Text -> AccountSubtypeKind -> (AccountId, RegularAccountData)
acct n nm k =
  (mockAccountIdN n, RegularAccountData {name = nm, balance = uah 0, subtype = k})

-- | Sample context: two accounts (both UAH), one expense category "Food", one
-- income category "Salary", and an "Other" default (id 9) for both categories.
sampleCtx :: ResolveContext
sampleCtx =
  ResolveContext
    { accounts =
        [ acct 1 "Cash" CashKind,
          acct 2 "Card" BankAccountKind
        ],
      incomeCategories = [(mockCategoryIdN 2, "Salary")],
      expenseCategories = [(mockCategoryIdN 1, "Food")],
      labels = [],
      defaults =
        ConfigurationDefaults
          { incomeCategory = Just (mockCategoryIdN 9),
            expenseCategory = Just (mockCategoryIdN 9),
            account = Nothing,
            subtypeAccounts = Map.empty
          },
      selectedAccount = Nothing
    }

-- | The "Food" expense category id and the "Other" default category id used by
-- 'sampleCtx' (Food = id 1; the income/expense default = id 9).
foodId, otherId :: CategoryId
foodId = mockCategoryIdN 1
otherId = mockCategoryIdN 9

-- | A single line item with the given amount, category, and no comment.
line :: Text -> Maybe Text -> IntentAllocation
line amt cat = IntentAllocation {amount = amt, category = cat, comment = Nothing}

-- | Attach a comment to a line item.
withComment :: IntentAllocation -> Text -> IntentAllocation
withComment ia c = ia {comment = Just c}

baseExpense :: TransactionIntent
baseExpense =
  TransactionIntent
    { kind = ExpenseKind,
      amount = Nothing,
      allocations = [line "123" (Just "Food")],
      currency = Nothing,
      sourceAccount = Just "Cash",
      targetAccount = Nothing,
      description = Nothing,
      date = Nothing
    }

baseIncome :: TransactionIntent
baseIncome =
  baseExpense
    { kind = IncomeKind,
      sourceAccount = Nothing,
      targetAccount = Just "Card",
      allocations = [line "123" (Just "Salary")]
    }

baseTransfer :: TransactionIntent
baseTransfer =
  baseExpense
    { kind = TransferKind,
      sourceAccount = Just "Cash",
      targetAccount = Just "Card",
      allocations = [],
      amount = Just "200"
    }

-- | 'baseExpense' with a single allocation whose amount is @amt@ (category "Food").
expAmount :: Text -> TransactionIntent
expAmount amt = baseExpense {allocations = [line amt (Just "Food")]}

-- | 'baseExpense' with a single allocation whose category name is @cat@.
expCategory :: Maybe Text -> TransactionIntent
expCategory cat = baseExpense {allocations = [line "123" cat]}

uah :: Rational -> Money
uah r = case mkMoney UAH r of
  Right m -> m
  Left e -> error (T.unpack e)

errField :: Either ResolveError (Resolved, Text) -> Maybe Text
errField (Left e) = Just e.field
errField (Right _) = Nothing

spec :: Spec
spec = describe "Application.Services.Prompt.Transaction.Resolve" $ do
  describe "expense" $ do
    it "resolves the happy path" $ do
      case resolveIntent sampleCtx "cash 123 food" baseExpense of
        Right (ResolvedExpense aid money allocs lbls _desc mdate, interp) -> do
          aid `shouldBe` mockAccountIdN 1
          money `shouldBe` uah 123
          allocs.expenses `shouldSatisfy` (\es -> length es == 1)
          allocs.incomes `shouldBe` []
          lbls `shouldBe` Set.empty
          mdate `shouldBe` Nothing
          interp `shouldSatisfy` ("Cash" `T.isInfixOf`)
          interp `shouldSatisfy` ("item" `T.isInfixOf`)
        other -> expectationFailure ("unexpected: " <> show other)

  describe "income" $ do
    it "resolves the happy path with the target account" $ do
      case resolveIntent sampleCtx "salary" baseIncome of
        Right (ResolvedIncome aid money allocs _ _ _, _) -> do
          aid `shouldBe` mockAccountIdN 2
          money `shouldBe` uah 123
          allocs.incomes `shouldSatisfy` (\is -> length is == 1)
          allocs.expenses `shouldBe` []
        other -> expectationFailure ("unexpected: " <> show other)

  describe "transfer" $ do
    it "resolves source and target with no category" $ do
      case resolveIntent sampleCtx "move 200" baseTransfer of
        Right (ResolvedTransfer src tgt money _ _ _, interp) -> do
          src `shouldBe` mockAccountIdN 1
          tgt `shouldBe` mockAccountIdN 2
          money `shouldBe` uah 200
          interp `shouldSatisfy` ("Cash" `T.isInfixOf`)
          interp `shouldSatisfy` ("Card" `T.isInfixOf`)
        other -> expectationFailure ("unexpected: " <> show other)

    it "rejects a transfer without a destination" $ do
      errField (resolveIntent sampleCtx "x" baseTransfer {targetAccount = Nothing})
        `shouldBe` Just "targetAccount"

  describe "account errors" $ do
    it "rejects an unknown account" $ do
      errField (resolveIntent sampleCtx "x" baseExpense {sourceAccount = Just "Nope"})
        `shouldBe` Just "sourceAccount"

    it "rejects a missing account" $ do
      errField (resolveIntent sampleCtx "x" baseExpense {sourceAccount = Nothing})
        `shouldBe` Just "sourceAccount"

    it "rejects an ambiguous account" $ do
      let ctx = sampleCtx {accounts = sampleCtx.accounts <> [acct 3 "Cash" CashKind]}
      errField (resolveIntent ctx "x" baseExpense {sourceAccount = Just "Cash"})
        `shouldBe` Just "sourceAccount"

  describe "category" $ do
    it "falls back to the default when the category is unknown" $ do
      case resolveIntent sampleCtx "x" (expCategory (Just "Xyz")) of
        Right (ResolvedExpense _ _ allocs _ _ _, _) ->
          fmap (.categoryId) (headMaybe allocs.expenses) `shouldBe` Just (mockCategoryIdN 9)
        other -> expectationFailure ("unexpected: " <> show other)

    it "errors when no match and no default configured" $ do
      let ctx =
            sampleCtx
              { defaults =
                  ConfigurationDefaults
                    { incomeCategory = Just (mockCategoryIdN 9),
                      expenseCategory = Nothing,
                      account = Nothing,
                      subtypeAccounts = Map.empty
                    }
              }
      errField (resolveIntent ctx "x" (expCategory (Just "Xyz")))
        `shouldBe` Just "category"

  describe "allocations" $ do
    it "resolves the 5-line example: one allocation per line, comment = original text, no merge" $ do
      let ti =
            TransactionIntent
              ExpenseKind
              Nothing
              [ IntentAllocation "200" (Just "Food") (Just "огірки розсада"),
                IntentAllocation "700" Nothing (Just "квіти"), -- no match → default "Other"
                IntentAllocation "200" (Just "Food") (Just "яйця"),
                IntentAllocation "500" (Just "Food") (Just "овочі"),
                IntentAllocation "160" (Just "Food") (Just "огірки зелень")
              ]
              Nothing
              (Just "Cash")
              Nothing
              Nothing
              Nothing
      case resolveIntent sampleCtx "prompt" ti of
        Right (ResolvedExpense _ total allocs _ _ _, interp) -> do
          length allocs.expenses `shouldBe` 5
          map (.comment) allocs.expenses
            `shouldBe` map Just ["огірки розсада", "квіти", "яйця", "овочі", "огірки зелень"]
          map (.categoryId) allocs.expenses
            `shouldBe` [foodId, otherId, foodId, foodId, foodId]
          unMoney total `shouldBe` 1760
          interp `shouldSatisfy` (\t -> "1760" `T.isInfixOf` t && not ("%" `T.isInfixOf` t))
        other -> expectationFailure (show other)

    it "still resolves a transfer via the top-level amount" $ do
      let ti = TransactionIntent TransferKind (Just "200") [] Nothing (Just "Cash") (Just "Card") Nothing Nothing
      resolveIntent sampleCtx "p" ti `shouldSatisfy` isRight

    it "errors when an income/expense has no allocations" $ do
      let ti = TransactionIntent ExpenseKind Nothing [] Nothing (Just "Cash") Nothing Nothing Nothing
      resolveIntent sampleCtx "p" ti `shouldSatisfy` isLeft

  describe "description" $ do
    it "description defaults to a summary of the allocation lines" $ do
      let ti =
            baseExpense
              { description = Nothing,
                allocations =
                  [ line "200" (Just "Food") `withComment` "огірки розсада",
                    line "700" (Just "Food") `withComment` "квіти",
                    line "200" (Just "Food") `withComment` "яйця",
                    line "500" (Just "Food") `withComment` "овочі",
                    line "160" (Just "Food") `withComment` "огірки зелень"
                  ]
              }
      case resolveIntent sampleCtx "the whole raw prompt" ti of
        Right (ResolvedExpense _ _ _ _ desc _, _) ->
          desc `shouldBe` "огірки розсада, квіти, яйця, овочі, огірки зелень"
        other -> expectationFailure ("unexpected: " <> show other)

    it "summary uses the category name when a line has no comment" $ do
      let ti =
            baseExpense
              { description = Nothing,
                allocations =
                  [ line "100" (Just "Food") `withComment` "milk",
                    line "50" (Just "Food")
                  ]
              }
      case resolveIntent sampleCtx "the whole raw prompt" ti of
        Right (ResolvedExpense _ _ _ _ desc _, _) ->
          desc `shouldBe` "milk, Food"
        other -> expectationFailure ("unexpected: " <> show other)

    it "an explicit model description is used verbatim" $ do
      let ti =
            baseExpense
              { description = Just "weekly groceries",
                allocations =
                  [ line "100" (Just "Food") `withComment` "milk",
                    line "50" (Just "Food")
                  ]
              }
      case resolveIntent sampleCtx "the whole raw prompt" ti of
        Right (ResolvedExpense _ _ _ _ desc _, _) ->
          desc `shouldBe` "weekly groceries"
        other -> expectationFailure ("unexpected: " <> show other)

    it "single-allocation description equals that line's item" $ do
      let ti =
            baseExpense
              { description = Nothing,
                allocations = [line "100" (Just "Food") `withComment` "milk"]
              }
      case resolveIntent sampleCtx "the whole raw prompt" ti of
        Right (ResolvedExpense _ _ _ _ desc _, _) ->
          desc `shouldBe` "milk"
        other -> expectationFailure ("unexpected: " <> show other)

    it "labels a default-category line with no comment as \"Other\" (never a UUID)" $ do
      -- category null → default cid (otherId, id 9), comment null, and otherId
      -- is absent from sampleCtx.expenseCategories, so the summary must use the
      -- neutral sentinel "Other" rather than leaking a DictionaryEntryId/UUID.
      let ti =
            baseExpense
              { description = Nothing,
                allocations = [line "100" Nothing]
              }
      case resolveIntent sampleCtx "the whole raw prompt" ti of
        Right (ResolvedExpense _ _ allocs _ desc _, _) -> do
          fmap (.categoryId) (headMaybe allocs.expenses) `shouldBe` Just otherId
          desc `shouldBe` "Other"
          desc `shouldNotSatisfy` ("DictionaryEntryId" `T.isInfixOf`)
        other -> expectationFailure ("unexpected: " <> show other)

    it "a transfer with no description still falls back to the prompt" $ do
      case resolveIntent sampleCtx "move 200 cash to card" baseTransfer {description = Nothing} of
        Right (ResolvedTransfer _ _ _ _ desc _, _) ->
          desc `shouldBe` "move 200 cash to card"
        other -> expectationFailure ("unexpected: " <> show other)

  describe "amount" $ do
    it "accepts a comma decimal separator" $ do
      let comma = resolveIntent sampleCtx "x" (expAmount "123,50")
          dot = resolveIntent sampleCtx "x" (expAmount "123.50")
      fmap (money . fst) comma `shouldBe` fmap (money . fst) dot

    it "rejects zero"
      $ errField (resolveIntent sampleCtx "x" (expAmount "0"))
      `shouldBe` Just "amount"

    it "rejects negative"
      $ errField (resolveIntent sampleCtx "x" (expAmount "-5"))
      `shouldBe` Just "amount"

    it "rejects non-numeric"
      $ errField (resolveIntent sampleCtx "x" (expAmount "abc"))
      `shouldBe` Just "amount"

    it "parses a decimal amount exactly (no binary-float error)" $ do
      -- "0.1" must resolve to the exact Rational 1/10. The old Double path
      -- yields toRational (0.1 :: Double) /= 1 % 10, so this fails there and
      -- passes only with the Scientific parse.
      case resolveIntent sampleCtx "x" (expAmount "0.1") of
        Right (ResolvedExpense _ m _ _ _ _, _) -> unMoney m `shouldBe` 1 % 10
        other -> expectationFailure ("unexpected: " <> show other)

    prop "comma and dot amounts are equivalent" $ \(n :: Int) ->
      n > 0 ==>
        let dotTxt = T.pack (show n) <> ".50"
            commaTxt = T.pack (show n) <> ",50"
            r t = fmap (money . fst) (resolveIntent sampleCtx "x" (expAmount t))
         in r dotTxt == r commaTxt

  describe "currency" $ do
    it "honors an explicit currency over the account native" $ do
      case resolveIntent sampleCtx "x" baseExpense {currency = Just "USD"} of
        Right (ResolvedExpense _ m _ _ _ _, _) -> m `shouldBe` usd 123
        other -> expectationFailure ("unexpected: " <> show other)

    it "uses the account native currency when omitted" $ do
      case resolveIntent sampleCtx "x" baseExpense of
        Right (ResolvedExpense _ m _ _ _ _, _) -> m `shouldBe` uah 123
        other -> expectationFailure ("unexpected: " <> show other)

  describe "date" $ do
    it "parses an ISO date to midnight" $ do
      case resolveIntent sampleCtx "x" baseExpense {date = Just "2026-06-30"} of
        Right (ResolvedExpense _ _ _ _ _ md, _) ->
          md `shouldBe` Just (UTCTime (fromGregorian 2026 6 30) 0)
        other -> expectationFailure ("unexpected: " <> show other)

    it "yields Nothing when omitted" $ do
      case resolveIntent sampleCtx "x" baseExpense of
        Right (ResolvedExpense _ _ _ _ _ md, _) -> md `shouldBe` Nothing
        other -> expectationFailure ("unexpected: " <> show other)

    it "rejects an unparseable date"
      $ errField (resolveIntent sampleCtx "x" baseExpense {date = Just "nope"})
      `shouldBe` Just "date"

  describe "account precedence (#26)" $ do
    it "1. a specific name match wins over a subtype default"
      $
      -- 'Visa' is a BankAccount whose name matches; the BankAccount subtype
      -- default is idBank1, so a name match must beat the subtype default.
      resolvedAccount (expSrc (Just "Visa"))
      `shouldBe` Right (mockAccountIdN 3)

    it "2. a subtype keyword resolves to that subtype's default account"
      $ resolvedAccount (expSrc (Just "from the bank"))
      `shouldBe` Right (mockAccountIdN 2)

    it "3. 'card' aliases the bank subtype default"
      $ resolvedAccount (expSrc (Just "card"))
      `shouldBe` Right (mockAccountIdN 2)

    it "4. a subtype with exactly one account (no default) resolves to it"
      $ resolvedAccount (expSrc (Just "wallet"))
      `shouldBe` Right (mockAccountIdN 4)

    it "5. an omitted account resolves to the global default"
      $ resolvedAccount (expSrc Nothing)
      `shouldBe` Right (mockAccountIdN 9)

    it "6. a specific unknown, non-keyword name is a NoMatch (400)"
      $ errField (expSrc (Just "Groceries"))
      `shouldBe` Just "sourceAccount"

    it "7. with no matches and no defaults, resolution fails"
      $
      -- sampleCtx has no global/subtype defaults; an unknown name fails.
      errField (resolveIntent sampleCtx "x" baseExpense {sourceAccount = Just "Nope"})
      `shouldBe` Just "sourceAccount"

    it "does not fill a transfer's omitted target from the global default"
      $ errField (resolveIntent precedenceCtx "x" baseTransfer {targetAccount = Nothing})
      `shouldBe` Just "targetAccount"

  describe "selected account" $ do
    it "fills an omitted expense source (overriding the global default)"
      $
      -- Without a selection an omitted source resolves to the global default
      -- (id 9); the selection must take that slot instead.
      primaryAccount (resolveIntent (sel 1 precedenceCtx) "x" baseExpense {sourceAccount = Nothing})
      `shouldBe` Right (mockAccountIdN 1)

    it "overrides subtype-keyword inference"
      $
      -- 'from the bank' would infer the BankAccount subtype default (id 2); the
      -- selection (id 1) must win over that inference.
      primaryAccount (resolveIntent (sel 1 precedenceCtx) "x" baseExpense {sourceAccount = Just "from the bank"})
      `shouldBe` Right (mockAccountIdN 1)

    it "an explicit account name in the prompt still beats the selection"
      $
      -- 'Visa' names a real account (id 3); an explicit name outranks the
      -- ambient selection (id 1).
      primaryAccount (resolveIntent (sel 1 precedenceCtx) "x" baseExpense {sourceAccount = Just "Visa"})
      `shouldBe` Right (mockAccountIdN 3)

    it "fills an omitted income target" $ do
      let inc = baseIncome {targetAccount = Nothing, allocations = [line "10" (Just "Salary")]}
      primaryAccount (resolveIntent (sel 1 precedenceCtx) "x" inc)
        `shouldBe` Right (mockAccountIdN 1)

    it "fills a transfer's omitted source but never its target" $ do
      let tr = baseTransfer {sourceAccount = Nothing, targetAccount = Just "Checking"}
      case resolveIntent (sel 1 precedenceCtx) "x" tr of
        Right (ResolvedTransfer src tgt _ _ _ _, _) -> do
          src `shouldBe` mockAccountIdN 1
          tgt `shouldBe` mockAccountIdN 2
        other -> expectationFailure ("unexpected: " <> show other)

    it "does not fill a transfer's omitted target from the selection"
      $ errField (resolveIntent (sel 1 precedenceCtx) "x" baseTransfer {sourceAccount = Just "MyCash", targetAccount = Nothing})
      `shouldBe` Just "targetAccount"

    it "ignores an unknown selected account id (falls back to inference)"
      $
      -- id 777 is not one of the user's accounts, so it is ignored and the
      -- omitted source falls back to the global default (id 9).
      primaryAccount (resolveIntent (sel 777 precedenceCtx) "x" baseExpense {sourceAccount = Nothing})
      `shouldBe` Right (mockAccountIdN 9)

-- | Set the given account (by mock ordinal) as the selected account.
sel :: Word32 -> ResolveContext -> ResolveContext
sel n ctx = ctx {selectedAccount = Just (mockAccountIdN n)}

-- | The primary (own-side) account id of any resolved transaction: source for
-- expense/transfer, target for income.
primaryAccount :: Either ResolveError (Resolved, Text) -> Either ResolveError AccountId
primaryAccount (Right (ResolvedExpense aid _ _ _ _ _, _)) = Right aid
primaryAccount (Right (ResolvedIncome aid _ _ _ _ _, _)) = Right aid
primaryAccount (Right (ResolvedTransfer src _ _ _ _ _, _)) = Right src
primaryAccount (Left e) = Left e

usd :: Rational -> Money
usd r = case mkMoney USD r of
  Right m -> m
  Left e -> error (T.unpack e)

-- Extract the Money out of any Resolved constructor for comparison.
money :: Resolved -> Money
money (ResolvedIncome _ m _ _ _ _) = m
money (ResolvedExpense _ m _ _ _ _) = m
money (ResolvedTransfer _ _ m _ _ _) = m

headMaybe :: [a] -> Maybe a
headMaybe [] = Nothing
headMaybe (x : _) = Just x

-- | Context for the #26 precedence ladder. Two BankAccounts (so a name match
-- can be distinguished from the subtype default), one E-Wallet (single of its
-- kind), and a distinct global-default account (id 9).
--
--   * BankAccount subtype default → id 2 (Checking)
--   * global default account       → id 9 (Fallback, a second cash account)
precedenceCtx :: ResolveContext
precedenceCtx =
  ResolveContext
    { accounts =
        [ acct 1 "MyCash" CashKind,
          acct 2 "Checking" BankAccountKind,
          acct 3 "Visa" BankAccountKind,
          acct 4 "PayPal" EWalletKind,
          acct 9 "Fallback" CashKind
        ],
      incomeCategories = [(mockCategoryIdN 2, "Salary")],
      expenseCategories = [(mockCategoryIdN 1, "Food")],
      labels = [],
      defaults =
        ConfigurationDefaults
          { incomeCategory = Just (mockCategoryIdN 9),
            expenseCategory = Just (mockCategoryIdN 9),
            account = Just (mockAccountIdN 9),
            subtypeAccounts = Map.fromList [(BankAccountKind, mockAccountIdN 2)]
          },
      selectedAccount = Nothing
    }

-- | Resolve 'baseExpense' with the given source account against 'precedenceCtx'.
expSrc :: Maybe Text -> Either ResolveError (Resolved, Text)
expSrc src = resolveIntent precedenceCtx "x" baseExpense {sourceAccount = src}

-- | The resolved expense's source account id (or the error field name via
-- 'errField' at the call site).
resolvedAccount :: Either ResolveError (Resolved, Text) -> Either ResolveError AccountId
resolvedAccount (Right (ResolvedExpense aid _ _ _ _ _, _)) = Right aid
resolvedAccount (Right (r, _)) = Left (ResolveError "unexpected" (T.pack (show r)))
resolvedAccount (Left e) = Left e
