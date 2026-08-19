{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Banking.Monobank
  ( descriptor,
    descriptorFromConfig,
  )
where

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import qualified Domain.Banking.Types as Domain
import Domain.Localization.Country (unsafeCountry)
import Infrastructure.Banking.Monobank.Internal
  ( MonoAccount (..),
    MonoClientInfo (..),
    MonoStatement (..),
    toProviderTransaction,
  )
import Infrastructure.Banking.Provider
import Infrastructure.Config (BankingConfig (..), providerTextSetting)
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
import qualified RIO.Map as Map
import qualified RIO.Set as Set

-- | Upstream Monobank API base URL, used as the fallback when no override is
-- supplied under the @api_base_url@ key of @banking.providers.monobank@. This
-- provider-specific default lives with the provider, not in the generic config
-- module.
defaultMonoApiBaseUrl :: Text
defaultMonoApiBaseUrl = "https://api.monobank.ua"

-- | Expose Monobank as a 'BankProviderDescriptor' with a pull-only transport.
--
-- The @apiBaseUrl@ is injected explicitly (rather than read from 'AppConfig')
-- so this adapter is decoupled from the config shape: @Main@ parses the base
-- URL from the provider's raw settings and passes it here, and tests point the
-- adapter at a mock endpoint. The three 'PullCapability' fields wrap the
-- @mono*@ request helpers, closing over the token supplied per request.
descriptor :: Text {- api base URL -} -> Manager -> BankProviderDescriptor
descriptor apiBaseUrl manager =
  BankProviderDescriptor
    { providerId = Domain.unsafeBankProviderId "monobank",
      displayName = "Monobank",
      coverage = RegionalCoverage (Set.singleton (unsafeCountry "UA")),
      -- 'defaultClassify' treats non-negative amounts as income and negative
      -- amounts as expense, which is exactly Monobank's sign convention:
      -- outgoing transactions have negative amounts, incoming positive. Category
      -- resolution via MCC happens in BankImportService using UserConfiguration.
      interpretation = defaultInterpretation,
      pull = Just $ \(Domain.StaticSecret token) ->
        PullCapability
          { fetchAccounts = monoFetchAccounts apiBaseUrl token manager,
            fetchStatements = monoFetchStatements apiBaseUrl token manager,
            registerWebhook = monoRegisterWebhook apiBaseUrl token manager
          },
      fileImport = Nothing
    }

-- | Build the Monobank descriptor straight from the app's 'BankingConfig',
-- looking up this provider's own settings entry (keyed by its stable slug)
-- and pulling the @api_base_url@ override out of the raw settings, falling
-- back to 'defaultMonoApiBaseUrl' when the entry or key is absent. This is
-- the only place that needs to know both Monobank's slug and its raw config
-- shape, keeping callers (e.g. the root providers module) config-agnostic.
descriptorFromConfig :: BankingConfig -> Manager -> BankProviderDescriptor
descriptorFromConfig cfg =
  descriptor apiBaseUrl
  where
    monobankId = Domain.unsafeBankProviderId "monobank"
    apiBaseUrl =
      maybe
        defaultMonoApiBaseUrl
        (providerTextSetting "api_base_url" defaultMonoApiBaseUrl)
        (Map.lookup monobankId cfg.providers)

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

monoFetchStatements :: Text -> Text -> Manager -> Domain.ExternalAccountId -> UTCTime -> UTCTime -> IO (Either Text [BankTransaction])
monoFetchStatements apiBaseUrl token manager accountId fromTime toTime = do
  let fromUnix = show @Int (round (utcTimeToPOSIXSeconds fromTime))
      toUnix = show @Int (round (utcTimeToPOSIXSeconds toTime))
      url = T.unpack apiBaseUrl <> "/personal/statement/" <> T.unpack (Domain.unExternalAccountId accountId) <> "/" <> fromUnix <> "/" <> toUnix
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
    { externalAccountId = Domain.unsafeExternalAccountId ma.monoAccId,
      accountNumber = ma.monoAccIban,
      currencyCode = ma.monoAccCurrencyCode,
      cardMasks = [],
      balance = ma.monoAccBalance
    }
