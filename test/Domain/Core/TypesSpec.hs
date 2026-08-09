{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Core.TypesSpec
-- Description : Unit tests for Domain.Core.Types
--
-- This module tests the core domain types with validation, business rules,
-- and error handling.
--
-- Test Coverage:
--   - Money: Smart constructor validation, arithmetic operations
--   - AccountId: Smart constructor validation
--   - TransactionId: Smart constructor validation
module Domain.Core.TypesSpec (spec) where

import Data.Aeson (Result (..), fromJSON, toJSON)
import qualified Data.Aeson as Aeson
import qualified Data.Map.Strict as Map
import Data.Text (isInfixOf)
import qualified Data.Text as T
import Data.UUID (nil)
import qualified Data.UUID.V4 as UUID
import Domain.Banking.Import (ExternalTransactionId, mkExternalTransactionId, unExternalTransactionId)
import Domain.Banking.Signal (BankProviderCategory, BankProviderContact, bankProviderCategory, bankProviderCategoryMcc, bankProviderContactText, mkBankProviderContact, mkByCounterparty, mkByLabel, mkByMcc, mkMcc, parseBankProviderCategoryKey, parseBankProviderContactKey, parseMcc, renderBankProviderCategoryKey, renderBankProviderContactKey, renderMcc, unsafeBankProviderContact, unsafeMcc)
import Domain.Core.Types
import RIO
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (NonEmptyList (..))
import Testkit.Helpers

spec :: Spec
spec = do
  moneySpec
  accountIdSpec
  transactionIdSpec
  externalTransactionIdSpec
  mccSpec
  bankProviderCategorySpec
  bankProviderCategoryByCounterpartySpec
  bankProviderContactSpec
  transactionTypeSpec
  roleToTextSpec

-- -----------------------------------------------------------------------------
-- Money Tests
-- -----------------------------------------------------------------------------

moneySpec :: Spec
moneySpec = describe "Money" $ do
  describe "mkMoney" $ do
    context "Given valid amount" $ do
      it "Then creates Money value" $ do
        let result = mkMoney USD 100
        shouldBeRight result
        case result of
          Right money -> do
            unMoney money `shouldBe` 100
            moneyCurrency money `shouldBe` USD
          Left _ -> expectationFailure "Expected Right"

      it "Then accepts zero" $ do
        let result = mkMoney USD 0
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 0
          Left _ -> expectationFailure "Expected Right"

      it "Then preserves currency" $ do
        let result = mkMoney USD 100
        shouldBeRight result
        case result of
          Right money -> moneyCurrency money `shouldBe` USD
          Left _ -> expectationFailure "Expected Right"

    context "Given negative amount" $ do
      it "Then accepts negative amounts" $ do
        let result = mkMoney USD (-10)
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` (-10)
          Left _ -> expectationFailure "Expected Right"

  describe "addMoney" $ do
    it "Then adds two amounts correctly" $ do
      let m1 = mockMoney 100
      let m2 = mockMoney 50
      let result = addMoney m1 m2
      shouldBeRight result
      case result of
        Right money -> unMoney money `shouldBe` 150
        Left _ -> expectationFailure "Expected Right"

    it "Then is commutative" $ do
      let m1 = mockMoney 100
      let m2 = mockMoney 50
      addMoney m1 m2 `shouldBe` addMoney m2 m1

    it "Then zero is identity element" $ do
      let m = mockMoney 100
      let zero = mockMoney 0
      addMoney m zero `shouldBe` Right m

    context "Given currency mismatch" $ do
      it "Then returns error" $ do
        let m1 = unsafeMoney USD 100
        let m2 = unsafeMoney EUR 50
        let result = addMoney m1 m2
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "Currency mismatch" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

  describe "subtractMoney" $ do
    context "Given sufficient funds" $ do
      it "Then subtracts correctly" $ do
        let m1 = mockMoney 100
        let m2 = mockMoney 50
        let result = subtractMoney m1 m2
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 50
          Left _ -> expectationFailure "Expected Right"

      it "Then handles exact match" $ do
        let m1 = mockMoney 100
        let m2 = mockMoney 100
        let result = subtractMoney m1 m2
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` 0
          Left _ -> expectationFailure "Expected Right"

    context "Given larger subtrahend" $ do
      it "Then succeeds with negative result" $ do
        let m1 = mockMoney 50
        let m2 = mockMoney 100
        let result = subtractMoney m1 m2
        shouldBeRight result
        case result of
          Right money -> unMoney money `shouldBe` (-50)
          Left _ -> expectationFailure "Expected Right"

    context "Given currency mismatch" $ do
      it "Then returns error" $ do
        let m1 = unsafeMoney USD 100
        let m2 = unsafeMoney EUR 50
        let result = subtractMoney m1 m2
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "Currency mismatch" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

  describe "Currency" $ do
    it "Then JSON roundtrips correctly" $ do
      let currencies = [UAH, USD, EUR, GBP]
      forM_ currencies $ \cur -> do
        let encoded = toJSON cur
        fromJSON encoded `shouldBe` Success cur

-- -----------------------------------------------------------------------------
-- AccountId Tests
-- -----------------------------------------------------------------------------

accountIdSpec :: Spec
accountIdSpec = describe "AccountId" $ do
  describe "mkAccountId" $ do
    context "Given valid UUID" $ do
      it "Then creates AccountId" $ do
        uuid <- UUID.nextRandom
        let result = mkAccountId uuid
        shouldBeRight result
        case result of
          Right accountId -> unAccountId accountId `shouldBe` uuid
          Left _ -> expectationFailure "Expected Right"

    context "Given nil UUID" $ do
      it "Then rejects with error message" $ do
        let result = mkAccountId nil
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "cannot be nil" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

-- -----------------------------------------------------------------------------
-- TransactionId Tests
-- -----------------------------------------------------------------------------

transactionIdSpec :: Spec
transactionIdSpec = describe "TransactionId" $ do
  describe "mkTransactionId" $ do
    context "Given valid UUID" $ do
      it "Then creates TransactionId" $ do
        uuid <- UUID.nextRandom
        let result = mkTransactionId uuid
        shouldBeRight result
        case result of
          Right txId -> unTransactionId txId `shouldBe` uuid
          Left _ -> expectationFailure "Expected Right"

    context "Given nil UUID" $ do
      it "Then rejects with error message" $ do
        let result = mkTransactionId nil
        shouldBeLeft result
        case result of
          Left err -> err `shouldSatisfy` (\msg -> "cannot be nil" `isInfixOf` msg)
          Right _ -> expectationFailure "Expected Left"

-- -----------------------------------------------------------------------------
-- ExternalTransactionId Tests
-- -----------------------------------------------------------------------------

externalTransactionIdSpec :: Spec
externalTransactionIdSpec = describe "ExternalTransactionId" $ do
  it "rejects empty text"
    $ mkExternalTransactionId ""
    `shouldSatisfy` isLeft

  prop "accepts any non-empty text" $ \(NonEmpty cs) ->
    let txt = T.pack cs
     in case mkExternalTransactionId txt of
          Right eid -> unExternalTransactionId eid == txt
          Left _ -> False

  it "FromJSON rejects empty string"
    $ (Aeson.eitherDecode "\"\"" :: Either String ExternalTransactionId)
    `shouldSatisfy` isLeft

  it "FromJSON accepts non-empty string"
    $ (Aeson.eitherDecode "\"tx-123\"" :: Either String ExternalTransactionId)
    `shouldSatisfy` isRight

-- -----------------------------------------------------------------------------
-- MCC Tests
-- -----------------------------------------------------------------------------

mccSpec :: Spec
mccSpec = describe "MCC" $ do
  it "mkMcc accepts a 4-digit code and renders zero-padded" $ do
    fmap renderMcc (mkMcc 742) `shouldBe` Right "0742"
    fmap renderMcc (mkMcc 5411) `shouldBe` Right "5411"
  it "mkMcc rejects out-of-range codes" $ do
    mkMcc (-1) `shouldSatisfy` isLeft
    mkMcc 10000 `shouldSatisfy` isLeft
  it "parseMcc round-trips the zero-padded text form"
    $ (parseMcc "0742" >>= \m -> Just (renderMcc m))
    `shouldBe` Just "0742"

-- -----------------------------------------------------------------------------
-- BankProviderCategory Tests
-- -----------------------------------------------------------------------------

bankProviderCategorySpec :: Spec
bankProviderCategorySpec = describe "BankProviderCategory" $ do
  it "value JSON round-trips ByMcc, including leading-zero codes" $ do
    Aeson.decode (Aeson.encode (mkByMcc (unsafeMcc 5411)))
      `shouldBe` Just (mkByMcc (unsafeMcc 5411))
    Aeson.decode (Aeson.encode (mkByMcc (unsafeMcc 742)))
      `shouldBe` Just (mkByMcc (unsafeMcc 742))
  it "value JSON round-trips ByLabel" $ do
    let cat = mkByLabel "eating_out"
    (Aeson.decode . Aeson.encode <$> cat) `shouldBe` Just cat
  it "encodes ByMcc value form as a tagged object with zero-padded code"
    $ Aeson.encode (mkByMcc (unsafeMcc 742))
    `shouldBe` "{\"kind\":\"mcc\",\"value\":\"0742\"}"
  it "encodes ByLabel value form as a tagged object"
    $ (Aeson.encode <$> mkByLabel "eating_out")
    `shouldBe` Just "{\"kind\":\"label\",\"value\":\"eating_out\"}"
  it "map-key JSON uses tagged text form and round-trips" $ do
    let cid = unsafeDictionaryEntryId nil
        m = Map.fromList [(mkByMcc (unsafeMcc 742), cid)] :: Map.Map BankProviderCategory DictionaryEntryId
    Aeson.encode m `shouldBe` "{\"mcc:0742\":\"00000000-0000-0000-0000-000000000000\"}"
    Aeson.decode (Aeson.encode m) `shouldBe` Just m
  it "map-key JSON round-trips ByLabel keys" $ do
    let cid = unsafeDictionaryEntryId nil
    case mkByLabel "eating_out" of
      Nothing -> expectationFailure "mkByLabel rejected a valid label"
      Just cat -> do
        let m = Map.fromList [(cat, cid)] :: Map.Map BankProviderCategory DictionaryEntryId
        Aeson.encode m `shouldBe` "{\"label:eating_out\":\"00000000-0000-0000-0000-000000000000\"}"
        Aeson.decode (Aeson.encode m) `shouldBe` Just m
  it "mkByLabel rejects empty and whitespace-only labels" $ do
    mkByLabel "" `shouldSatisfy` isNothing
    mkByLabel "   " `shouldSatisfy` isNothing
  it "bankProviderCategory folds over all cases" $ do
    bankProviderCategory (const True) (const False) (const False) (mkByMcc (unsafeMcc 742)) `shouldBe` True
    (bankProviderCategory (const 'm') (const 'l') (const 'c') <$> mkByLabel "x") `shouldBe` Just 'l'
    (bankProviderCategory (const 'm') (const 'l') (const 'c') <$> mkByCounterparty "12345678") `shouldBe` Just 'c'
  it "bankProviderCategoryMcc extracts only the ByMcc code" $ do
    bankProviderCategoryMcc (mkByMcc (unsafeMcc 5411)) `shouldBe` Just (unsafeMcc 5411)
    (bankProviderCategoryMcc <$> mkByLabel "x") `shouldBe` Just Nothing

-- -----------------------------------------------------------------------------
-- BankProviderCategory ByCounterparty Tests
-- -----------------------------------------------------------------------------

bankProviderCategoryByCounterpartySpec :: Spec
bankProviderCategoryByCounterpartySpec = describe "BankProviderCategory ByCounterparty" $ do
  it "mkByCounterparty trims and rejects blank" $ do
    renderBankProviderCategoryKey <$> mkByCounterparty "  12345678 "
      `shouldBe` Just "counterparty:12345678"
    mkByCounterparty "   " `shouldBe` Nothing

  it "key form round-trips (including a token containing a colon)"
    $ case mkByCounterparty "UA:1234" of
      Nothing -> expectationFailure "mkByCounterparty rejected a valid token"
      Just pc -> parseBankProviderCategoryKey (renderBankProviderCategoryKey pc) `shouldBe` Just pc

  it "value JSON round-trips"
    $ case mkByCounterparty "12345678" of
      Nothing -> expectationFailure "mkByCounterparty rejected a valid token"
      Just pc -> Aeson.decode (Aeson.encode pc) `shouldBe` Just pc

  it "value JSON is the tagged counterparty object"
    $ (Aeson.encode <$> mkByCounterparty "12345678")
    `shouldBe` Just "{\"kind\":\"counterparty\",\"value\":\"12345678\"}"

-- -----------------------------------------------------------------------------
-- BankProviderContact Tests
-- -----------------------------------------------------------------------------

bankProviderContactSpec :: Spec
bankProviderContactSpec = describe "BankProviderContact" $ do
  it "trims and rejects a blank token" $ do
    fmap bankProviderContactText (mkBankProviderContact "  Магазин РЕМОНТІ  ")
      `shouldBe` Just "Магазин РЕМОНТІ"
    mkBankProviderContact "   " `shouldBe` Nothing
    mkBankProviderContact "" `shouldBe` Nothing
  it "value JSON round-trips as a plain string"
    $ Aeson.decode (Aeson.encode (unsafeBankProviderContact "Магазин РЕМОНТІ"))
    `shouldBe` Just (unsafeBankProviderContact "Магазин РЕМОНТІ")
  it "encodes the value form as a plain string, not a tagged object"
    $ Aeson.encode (unsafeBankProviderContact "IVAN")
    `shouldBe` "\"IVAN\""
  it "map-key JSON round-trips the token verbatim" $ do
    let cid = unsafeDictionaryEntryId nil
        m = Map.fromList [(unsafeBankProviderContact "IVAN", cid)] :: Map.Map BankProviderContact DictionaryEntryId
    Aeson.decode (Aeson.encode m) `shouldBe` Just m
  it "encodes the map key as the token verbatim, unprefixed" $ do
    let cid = unsafeDictionaryEntryId nil
        m = Map.fromList [(unsafeBankProviderContact "IVAN", cid)] :: Map.Map BankProviderContact DictionaryEntryId
    Aeson.encode m `shouldBe` "{\"IVAN\":\"00000000-0000-0000-0000-000000000000\"}"
  it "key render/parse round-trips a token containing a colon"
    $ parseBankProviderContactKey (renderBankProviderContactKey (unsafeBankProviderContact "a:b"))
    `shouldBe` Just (unsafeBankProviderContact "a:b")

-- -----------------------------------------------------------------------------
-- TransactionType Tests
-- -----------------------------------------------------------------------------

transactionTypeSpec :: Spec
transactionTypeSpec = describe "TransactionType JSON" $ do
  it "round-trips Adjustment via Aeson Generic encoding" $ do
    let encoded = Aeson.encode Adjustment
    Aeson.decode encoded `shouldBe` Just Adjustment
  it "encodes Adjustment with a tag-only object (no category)"
    $ Aeson.encode Adjustment
    `shouldBe` "{\"tag\":\"Adjustment\"}"

-- -----------------------------------------------------------------------------
-- roleToText Tests
-- -----------------------------------------------------------------------------

roleToTextSpec :: Spec
roleToTextSpec = describe "roleToText" $ do
  it "renders Owner as lowercase owner" $ roleToText Owner `shouldBe` ("owner" :: Text)
  it "renders Editor as lowercase editor" $ roleToText Editor `shouldBe` ("editor" :: Text)
  it "renders Viewer as lowercase viewer" $ roleToText Viewer `shouldBe` ("viewer" :: Text)
