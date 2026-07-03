{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Application.Services.Prompt.Transaction.ResolveSpec (spec) where

import Application.ReadModels.Account (RegularAccountData (..))
import Application.Services.Prompt.Transaction.Intent
  ( IntentKind (..),
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

-- | Build a 'RegularAccountData' with a zero UAH balance (the resolver only
-- reads the currency off the balance).
acct :: Word32 -> Text -> AccountSubtypeKind -> RegularAccountData
acct n nm k =
  RegularAccountData {accountId = mockAccountIdN n, name = nm, balance = uah 0, subtype = k}

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
          }
    }

baseExpense :: TransactionIntent
baseExpense =
  TransactionIntent
    { kind = ExpenseKind,
      amount = "123",
      currency = Nothing,
      sourceAccount = Just "Cash",
      targetAccount = Nothing,
      category = Just "Food",
      description = Nothing,
      date = Nothing
    }

baseIncome :: TransactionIntent
baseIncome =
  baseExpense
    { kind = IncomeKind,
      sourceAccount = Nothing,
      targetAccount = Just "Card",
      category = Just "Salary"
    }

baseTransfer :: TransactionIntent
baseTransfer =
  baseExpense
    { kind = TransferKind,
      sourceAccount = Just "Cash",
      targetAccount = Just "Card",
      category = Nothing,
      amount = "200"
    }

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
          interp `shouldSatisfy` ("Food" `T.isInfixOf`)
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
      case resolveIntent sampleCtx "x" baseExpense {category = Just "Xyz"} of
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
      errField (resolveIntent ctx "x" baseExpense {category = Just "Xyz"})
        `shouldBe` Just "category"

  describe "amount" $ do
    it "accepts a comma decimal separator" $ do
      let comma = resolveIntent sampleCtx "x" baseExpense {amount = "123,50"}
          dot = resolveIntent sampleCtx "x" baseExpense {amount = "123.50"}
      fmap (money . fst) comma `shouldBe` fmap (money . fst) dot

    it "rejects zero"
      $ errField (resolveIntent sampleCtx "x" baseExpense {amount = "0"})
      `shouldBe` Just "amount"

    it "rejects negative"
      $ errField (resolveIntent sampleCtx "x" baseExpense {amount = "-5"})
      `shouldBe` Just "amount"

    it "rejects non-numeric"
      $ errField (resolveIntent sampleCtx "x" baseExpense {amount = "abc"})
      `shouldBe` Just "amount"

    it "parses a decimal amount exactly (no binary-float error)" $ do
      -- "0.1" must resolve to the exact Rational 1/10. The old Double path
      -- yields toRational (0.1 :: Double) /= 1 % 10, so this fails there and
      -- passes only with the Scientific parse.
      case resolveIntent sampleCtx "x" baseExpense {amount = "0.1"} of
        Right (ResolvedExpense _ m _ _ _ _, _) -> unMoney m `shouldBe` 1 % 10
        other -> expectationFailure ("unexpected: " <> show other)

    prop "comma and dot amounts are equivalent" $ \(n :: Int) ->
      n > 0 ==>
        let dotTxt = T.pack (show n) <> ".50"
            commaTxt = T.pack (show n) <> ",50"
            r t = fmap (money . fst) (resolveIntent sampleCtx "x" baseExpense {amount = t})
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
          }
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
