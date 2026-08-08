{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.CsvSpec (spec) where

import qualified Data.Csv as Csv
import Data.Time (UTCTime (..), fromGregorian)
import Domain.Banking.Types (unsafeExternalAccountId)
import Domain.Core.Types (unsafeExternalTransactionId)
import Infrastructure.Banking.Csv (comma, csvStatementParser)
import Infrastructure.Banking.Provider (BankTransaction (..), ParseError (..), RowError (..))
import RIO
import Test.Hspec

-- | A minimal decodable raw row for driver tests: one ASCII column @v@.
newtype StubRow = StubRow Text

instance Csv.FromNamedRecord StubRow where
  parseNamedRecord m = StubRow <$> m Csv..: "v"

-- | Any valid 'BankTransaction'; its fields are never asserted in these tests.
stubTx :: Text -> BankTransaction
stubTx v =
  BankTransaction
    { externalId = unsafeExternalTransactionId v,
      externalAccountId = unsafeExternalAccountId "acc",
      time = UTCTime (fromGregorian 2026 1 1) 0,
      amount = 0,
      currencyCode = 980,
      description = v,
      hold = False,
      category = Nothing,
      contact = Nothing,
      originalAmount = Nothing,
      notes = Nothing
    }

spec :: Spec
spec = do
  describe "csvStatementParser" $ do
    let prep = Right
        validate n (StubRow v)
          | even n = Left (RowError n ("even row: " <> v))
          | otherwise = Right (stubTx v)
        parser = csvStatementParser "Stub" comma prep validate
    it "returns Left ParseError when a required column is missing"
      $
      -- header lacks "v", plus one data row so the row decode actually runs
      case parser (encodeUtf8 "x\r\n1\r\n") of
        Left (ParseError _) -> pure () :: IO ()
        other -> expectationFailure ("expected structural ParseError, got " <> show other)
    it "1-indexes per-row results"
      $ case parser (encodeUtf8 "v\r\na\r\nb\r\n") of
        Right [Right _, Left (RowError 2 _)] -> pure () :: IO ()
        other -> expectationFailure ("unexpected: " <> show other)
    it "aborts the whole file when prepare fails, without reaching validate"
      $
      -- 'validate' is 'error'; a Left from 'prepare' must short-circuit before
      -- the driver ever decodes rows or calls it.
      let prepFail = const (Left (ParseError "boom"))
          validateNeverReached :: Int -> StubRow -> Either RowError BankTransaction
          validateNeverReached = error "validate must not run when prepare fails"
          failing = csvStatementParser "Stub" comma prepFail validateNeverReached
       in case failing (encodeUtf8 "v\r\na\r\nb\r\n") of
            Left (ParseError _) -> pure () :: IO ()
            other -> expectationFailure ("expected prepare failure to abort, got " <> show other)
