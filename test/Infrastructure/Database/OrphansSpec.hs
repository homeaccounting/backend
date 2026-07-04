{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Database.OrphansSpec
-- Description : Round-trip properties for read-model id 'PersistField' instances.
--
-- A persisted read model is only correct if the ids it stores in columns
-- decode back to the exact value that was written. These properties pin that
-- invariant for the id types used as columns.
module Infrastructure.Database.OrphansSpec (spec) where

import Data.Aeson (Value, encode, object, (.=))
import qualified Data.Map.Strict as Map
import Data.UUID (fromWords)
import Database.Persist (PersistField (..), PersistValue (..))
import Domain.Core.Types
  ( AccountRole (..),
    AccountStatus (..),
    AccountSubtypeKind (..),
    AccountType (..),
    Allocation (..),
    Allocations (..),
    Currency (..),
    DefaultSubtypeAccounts (..),
    ExternalTransactionId,
    TransactionType (..),
    defaultBankAccount,
    mkAllocation,
    mkAllocations,
    mkIncome,
    unsafeDictionaryEntryId,
    unsafeExternalTransactionId,
    unsafeMoney,
  )
import Domain.ExchangeRate.Events (Provider (..))
import Domain.Transaction.Projection (StatusKind (..))
import Infrastructure.Database.Orphans ()
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, arbitrary, forAll, listOf1, suchThat)
import Testkit.Generators
  ( genAccountId,
    genConfigurationId,
    genDictionaryEntryId,
    genExchangeRate,
    genMoney,
    genOAuthProvider,
    genTelegramId,
    genTransactionId,
    genTransactionType,
    genUserId,
  )

-- | Generate a non-empty 'ExternalTransactionId' (the smart constructor rejects
-- empty text).
genExternalTransactionId :: Gen ExternalTransactionId
genExternalTransactionId =
  unsafeExternalTransactionId
    . T.pack
    <$> listOf1 (suchThat arbitrary (/= '\NUL'))

-- | Generate a non-empty 'Provider' name.
genProvider :: Gen Provider
genProvider = Provider . T.pack <$> listOf1 (suchThat arbitrary (/= '\NUL'))

spec :: Spec
spec = describe "Infrastructure.Database.Orphans" $ do
  prop "ExternalTransactionId round-trips through PersistValue"
    $ forAll genExternalTransactionId
    $ \extId ->
      fromPersistValue (toPersistValue extId) `shouldBe` Right extId

  prop "TransactionId round-trips through PersistValue"
    $ forAll genTransactionId
    $ \txId ->
      fromPersistValue (toPersistValue txId) `shouldBe` Right txId

  prop "AccountId round-trips through PersistValue"
    $ forAll genAccountId
    $ \accId ->
      fromPersistValue (toPersistValue accId) `shouldBe` Right accId

  prop "UserId round-trips through PersistValue"
    $ forAll genUserId
    $ \uid ->
      fromPersistValue (toPersistValue uid) `shouldBe` Right uid

  prop "Money round-trips through PersistValue (JSON column)"
    $ forAll genMoney
    $ \m ->
      fromPersistValue (toPersistValue m) `shouldBe` Right m

  it "AccountRole / AccountStatus / AccountType round-trip through PersistValue" $ do
    let roundTrips x = fromPersistValue (toPersistValue x) `shouldBe` Right x
    mapM_ roundTrips [Owner, Editor, Viewer]
    mapM_ roundTrips [Opened, Closed]
    roundTrips External
    roundTrips (Regular defaultBankAccount)

  it "AccountSubtypeKind round-trips through PersistValue" $ do
    let roundTrips x = fromPersistValue (toPersistValue x) `shouldBe` Right x
    mapM_ roundTrips [minBound .. maxBound :: AccountSubtypeKind]

  prop "DefaultSubtypeAccounts round-trips through PersistValue (JSON column)"
    $ forAll genAccountId
    $ \a ->
      let m = DefaultSubtypeAccounts (Map.fromList [(CashKind, a), (BankAccountKind, a)])
       in fromPersistValue (toPersistValue m) `shouldBe` Right m

  it "empty DefaultSubtypeAccounts round-trips through PersistValue"
    $ fromPersistValue (toPersistValue (DefaultSubtypeAccounts Map.empty))
    `shouldBe` Right (DefaultSubtypeAccounts Map.empty)

  prop "DictionaryEntryId round-trips through PersistValue"
    $ forAll genDictionaryEntryId
    $ \deId ->
      fromPersistValue (toPersistValue deId) `shouldBe` Right deId

  prop "ExchangeRate round-trips through PersistValue (JSON column)"
    $ forAll genExchangeRate
    $ \er ->
      fromPersistValue (toPersistValue er) `shouldBe` Right er

  prop "TransactionType round-trips through PersistValue (JSON column)"
    $ forAll genTransactionType
    $ \tt ->
      fromPersistValue (toPersistValue tt) `shouldBe` Right tt

  it "StatusKind round-trips through PersistValue (text token)" $ do
    let roundTrips x = fromPersistValue (toPersistValue x) `shouldBe` Right x
    mapM_ roundTrips [PendingKind, CompletedKind, FailedKind, CancelledKind]

  prop "ConfigurationId round-trips through PersistValue"
    $ forAll genConfigurationId
    $ \cid ->
      fromPersistValue (toPersistValue cid) `shouldBe` Right cid

  prop "TelegramId round-trips through PersistValue (integer column)"
    $ forAll genTelegramId
    $ \tid ->
      fromPersistValue (toPersistValue tid) `shouldBe` Right tid

  prop "OAuthProvider round-trips through PersistValue (JSON token)"
    $ forAll genOAuthProvider
    $ \p ->
      fromPersistValue (toPersistValue p) `shouldBe` Right p

  it "Currency round-trips through PersistValue (JSON token)" $ do
    let roundTrips x = fromPersistValue (toPersistValue x) `shouldBe` Right x
    mapM_ roundTrips [UAH, USD, EUR, GBP]

  prop "Provider round-trips through PersistValue (text column)"
    $ forAll genProvider
    $ \p ->
      fromPersistValue (toPersistValue p) `shouldBe` Right p

  -- Allocation comment codec — tested via TransactionType PersistField
  -- (allocToValue / allocParser are module-private; TransactionType is the
  -- public surface that exercises them end-to-end).

  it "allocation comment round-trips through TransactionType PersistValue" $ do
    let cid = unsafeDictionaryEntryId (fromWords 1 0 0 0)
        amt = unsafeMoney USD 5
        alloc = either (error . show) id (mkAllocation cid amt (Just "квіти"))
        allocs = either (error . show) id (mkAllocations [alloc] [])
        total = amt
        tt = either (error . show) id (mkIncome total allocs)
    fromPersistValue (toPersistValue tt) `shouldBe` Right tt

  it "allocation with Nothing comment round-trips through TransactionType PersistValue" $ do
    let cid = unsafeDictionaryEntryId (fromWords 3 0 0 0)
        amt = unsafeMoney USD 7
        alloc = either (error . show) id (mkAllocation cid amt Nothing)
        allocs = either (error . show) id (mkAllocations [alloc] [])
        total = amt
        tt = either (error . show) id (mkIncome total allocs)
    fromPersistValue (toPersistValue tt) `shouldBe` Right tt

  it "allocation without comment key is tolerated by TransactionType codec (legacy)" $ do
    -- Construct the old wire format (no "comment" key) by hand and feed it
    -- into fromPersistValue; result must decode with comment = Nothing.
    let cid = unsafeDictionaryEntryId (fromWords 2 0 0 0)
        amt = unsafeMoney USD 10
        -- Build the legacy JSON object the old codec would have produced:
        -- amount encoded as toJSON (show rational, currency)
        legacyAllocObj :: Value
        legacyAllocObj =
          object
            [ "categoryId" .= cid,
              -- moneyToValue encodes Money as (show rational, currency); "10 % 1" is the 'show' of the Rational 10.
              "amount" .= (["10 % 1", "USD"] :: [Text])
            ]
        legacyJson :: Value
        legacyJson =
          object
            [ "kind" .= ("income" :: Text),
              "allocations"
                .= object
                  [ "incomes" .= ([legacyAllocObj] :: [Value]),
                    "expenses" .= ([] :: [Value])
                  ]
            ]
        persistVal = PersistText (decodeUtf8Lenient . BL.toStrict . encode $ legacyJson)
        result = fromPersistValue persistVal :: Either Text TransactionType
    case result of
      Left err -> expectationFailure ("decode failed: " <> T.unpack err)
      Right (Income (Allocations [decoded] [])) -> do
        decoded.comment `shouldBe` Nothing
        decoded.categoryId `shouldBe` cid
        decoded.amount `shouldBe` amt
      Right other -> expectationFailure ("unexpected TransactionType shape: " <> show other)
