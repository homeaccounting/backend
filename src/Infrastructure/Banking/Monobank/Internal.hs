{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- This module is __not part of the public API__. It declares the internal
-- Monobank JSON types and adapter helpers so that 'Infrastructure.Banking.Monobank'
-- and tests can share them. Production code should depend on
-- 'Infrastructure.Banking.Monobank' instead.
module Infrastructure.Banking.Monobank.Internal
  ( MonoClientInfo (..),
    MonoAccount (..),
    MonoStatement (..),
    toProviderTransaction,
  )
where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Int (Int32, Int64)
import Data.Ratio ((%))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Domain.Core.Types (mkExternalTransactionId)
import Infrastructure.Banking.Provider
import RIO

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
      <$> v
      .: "id"
      <*> v
      .: "iban"
      <*> v
      .: "currencyCode"
      <*> v
      .: "balance"

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
      <$> v
      .: "id"
      <*> v
      .: "time"
      <*> v
      .: "description"
      <*> v
      .: "mcc"
      <*> v
      .: "amount"
      <*> v
      .: "operationAmount"
      <*> v
      .: "currencyCode"
      <*> v
      .: "hold"
      <*> v
      .:? "comment"

-- | Convert a Monobank statement to a provider-level 'BankTransaction'.
--
-- Returns 'Left reason' when the statement cannot be represented (currently
-- only when 'mkExternalTransactionId' rejects 'stmtId'). The caller surfaces
-- the reason via stderr so silent drops are visible in logs.
--
-- Amounts are scaled from minor units (kopiykas) to major units here so the
-- application layer works in a single representation. 'originalAmount' is
-- populated only when the transaction's operation amount differs from the
-- account amount (i.e. a cross-currency transaction).
toProviderTransaction :: BankAccountId -> MonoStatement -> Either Text BankTransaction
toProviderTransaction accId ms =
  case mkExternalTransactionId ms.stmtId of
    Left err ->
      Left $ "stmtId=" <> tshow ms.stmtId <> " rejected: " <> err
    Right extId ->
      let accountAmount = fromIntegral ms.stmtAmount % 100
          operationAmount = fromIntegral ms.stmtOperationAmount % 100
          maybeOriginal =
            if accountAmount == operationAmount
              then Nothing
              else Just operationAmount
       in Right
            BankTransaction
              { externalId = extId,
                accountId = accId,
                time = posixSecondsToUTCTime (fromIntegral ms.stmtTime),
                amount = accountAmount,
                currencyCode = ms.stmtCurrencyCode,
                description = ms.stmtDescription,
                hold = ms.stmtHold,
                mcc = if ms.stmtMcc == 0 then Nothing else Just ms.stmtMcc,
                originalAmount = maybeOriginal,
                notes = ms.stmtComment,
                categoryHint = Nothing
              }
