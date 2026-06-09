{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Monobank
  ( mkMonobankProvider,
    mkBankProviderFactory,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import qualified Domain.Banking.Types as Domain
import Infrastructure.App (BankProviderFactory)
import Infrastructure.Banking.Monobank.Internal
  ( MonoAccount (..),
    MonoClientInfo (..),
    MonoStatement (..),
    toProviderTransaction,
  )
import Infrastructure.Banking.Provider
import Infrastructure.Config (AppConfig (..), BankingConfig (..), BankingProvidersConfig (..), MonobankProviderConfig (..))
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
  )
import Network.HTTP.Types.Status (statusCode)
import RIO

-- | Construct a BankProvider for Monobank from a personal API token.
--
-- The @apiBaseUrl@ is injected from configuration so tests and alternate
-- deployments can point the adapter at a mock endpoint.
mkMonobankProvider :: Text -> Text -> Manager -> BankProvider
mkMonobankProvider apiBaseUrl token manager =
  BankProvider
    { providerName = "monobank",
      fetchAccounts = monoFetchAccounts apiBaseUrl token manager,
      fetchStatements = monoFetchStatements apiBaseUrl token manager,
      registerWebhook = monoRegisterWebhook apiBaseUrl token manager,
      classifyTransaction = monoClassifyTransaction
    }

-- | Build the application's 'BankProviderFactory' from the loaded config and
-- shared HTTP 'Manager'.
--
-- This is the single place where provider-specific configuration (the
-- Monobank API base URL) and the constructor are wired together. The returned
-- factory dispatches on the connection's 'Domain.BankProvider' enum and
-- captures @config@/@manager@ in its closure, so callers never see the
-- per-provider config. New providers are added by extending the @case@ here.
mkBankProviderFactory :: AppConfig -> Manager -> BankProviderFactory
mkBankProviderFactory config manager provider token =
  case provider of
    Domain.Monobank ->
      mkMonobankProvider config.banking.providers.monobank.apiBaseUrl token manager

-- | Monobank classify: amount-sign based (direction only).
--
-- Mono outgoing transactions have negative amounts and incoming have positive,
-- so the sign fully determines Expense vs Income. Category resolution via
-- MCC happens in BankImportService using UserConfiguration.
monoClassifyTransaction :: BankTransaction -> TransactionClassification
monoClassifyTransaction tx
  | tx.amount >= 0 = ClassifiedIncome
  | otherwise = ClassifiedExpense

-- API call functions

monoFetchAccounts :: Text -> Text -> Manager -> IO (Either Text [BankAccount])
monoFetchAccounts apiBaseUrl token manager = do
  result <- monoGet token manager (T.unpack apiBaseUrl <> "/personal/client-info")
  case result of
    Left err -> return (Left err)
    Right body -> case Aeson.eitherDecode body of
      Left err -> return (Left $ "Failed to parse client-info: " <> T.pack err)
      Right (info :: MonoClientInfo) ->
        return $ Right $ map toProviderAccount info.accounts

monoFetchStatements :: Text -> Text -> Manager -> BankAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction])
monoFetchStatements apiBaseUrl token manager accountId fromTime toTime = do
  let fromUnix = show @Int (round (utcTimeToPOSIXSeconds fromTime))
      toUnix = show @Int (round (utcTimeToPOSIXSeconds toTime))
      url = T.unpack apiBaseUrl <> "/personal/statement/" <> T.unpack accountId <> "/" <> fromUnix <> "/" <> toUnix
  result <- monoGet token manager url
  case result of
    Left err -> return (Left err)
    Right body -> case Aeson.eitherDecode body of
      Left err -> return (Left $ "Failed to parse statements: " <> T.pack err)
      Right (stmts :: [MonoStatement]) -> do
        let (dropped, txs) = partitionEithers (map (toProviderTransaction accountId) stmts)
        unless (null dropped)
          $ TIO.hPutStrLn stderr
          $ "Monobank: dropped "
          <> tshow (length dropped)
          <> " statement(s) with invalid external ID: "
          <> T.intercalate "; " dropped
        return (Right txs)

monoRegisterWebhook :: Text -> Text -> Manager -> Text -> IO (Either Text ())
monoRegisterWebhook apiBaseUrl token manager webhookUrl = do
  let body = Aeson.encode $ Aeson.object ["webHookUrl" Aeson..= webhookUrl]
  result <- monoPost token manager (T.unpack apiBaseUrl <> "/personal/webhook") body
  case result of
    Left err -> return (Left err)
    Right _ -> return (Right ())

-- HTTP helpers

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
monoPost token manager url reqBody = do
  req <- parseRequest url
  let authedReq =
        req
          { method = "POST",
            requestHeaders =
              [ ("X-Token", encodeUtf8 token),
                ("Content-Type", "application/json")
              ],
            requestBody = RequestBodyLBS reqBody
          }
  resp <- httpLbs authedReq manager
  let status = statusCode (responseStatus resp)
  if status >= 200 && status < 300
    then return (Right (responseBody resp))
    else return (Left $ "Monobank API error (HTTP " <> tshow status <> ")")

-- Conversion helpers

toProviderAccount :: MonoAccount -> BankAccount
toProviderAccount ma =
  BankAccount
    { externalId = ma.monoAccId,
      accountNumber = ma.monoAccIban,
      currencyCode = ma.monoAccCurrencyCode,
      cardMasks = [],
      balance = ma.monoAccBalance
    }
