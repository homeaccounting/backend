{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.BaseCurrencyEditableIntegrationSpec
-- Description : End-to-end coverage of the @baseCurrencyEditable@ flag.
--
-- Verifies that GET @\/api\/users\/me\/configuration@ exposes the flag as
-- 'True' for a freshly-registered user (no transactions touching the
-- External account) and that it flips to 'False' after the first income or
-- expense posts. The flag mirrors the domain @AccountCurrencyLocked@
-- precondition that gates 'ChangeAccountCurrency' on the External account,
-- which is itself the gate for 'ChangeBaseCurrency'.
module Integration.BaseCurrencyEditableIntegrationSpec (spec) where

import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Time (UTCTime)
import Domain.Core.Types
  ( unAccountId,
    unDictionaryEntryId,
  )
import Network.HTTP.Types (status200)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    uuidText,
  )
import Web.API.ConfigurationAPI (ConfigurationResponse (..))

configPath :: ByteString
configPath = "/api/users/me/configuration"

decodeConfig :: SResponse -> IO ConfigurationResponse
decodeConfig resp = case eitherDecode (simpleBody resp) :: Either String ConfigurationResponse of
  Left err -> fail $ "expected ConfigurationResponse body, got: " <> err
  Right cfg -> pure cfg

incomeBody :: Seed -> Text -> UTCTime -> LBS.ByteString
incomeBody seed description at =
  encode
    $ object
      [ "accountId" .= uuidText (unAccountId seed.seedAccount),
        "currency" .= ("USD" :: Text),
        "allocations"
          .= object
            [ "incomes"
                .= [ object
                       [ "category" .= uuidText (unDictionaryEntryId seed.seedCategory),
                         "amount" .= (25 :: Double)
                       ]
                   ],
              "expenses" .= ([] :: [Value])
            ],
        "description" .= description,
        "date" .= at,
        "labels" .= ([] :: [Text])
      ]

freshSeed :: Text -> IO (Seed, Text)
freshSeed email = do
  seed <- mkSeed createTestAppEnvWithProcessManager email
  token <- seedToken seed
  pure (seed, token)

spec :: Spec
spec = describe "Integration / BaseCurrencyEditable" $ do
  it "is True for a freshly-registered user (External account has no transactions)" $ do
    (seed, token) <- freshSeed "base-currency-editable-fresh@test.com"
    resp <- httpRequest seed.seedApp "GET" configPath (authHeaders token) ""
    simpleStatus resp `shouldBe` status200
    cfg <- decodeConfig resp
    cfg.baseCurrencyEditable `shouldBe` True

  it "flips to False after the first income posts against the External account" $ do
    (seed, token) <- freshSeed "base-currency-editable-after-income@test.com"

    -- Sanity: starts True.
    beforeResp <- httpRequest seed.seedApp "GET" configPath (authHeaders token) ""
    simpleStatus beforeResp `shouldBe` status200
    beforeCfg <- decodeConfig beforeResp
    beforeCfg.baseCurrencyEditable `shouldBe` True

    -- Post an income. Income flows External -> Regular, which credits the
    -- External account and flips its hasTransactions flag.
    incomeResp <-
      httpRequest
        seed.seedApp
        "POST"
        "/api/transactions/income"
        (authHeaders token)
        (incomeBody seed "Seed income" (utc 2026 4 1))
    simpleStatus incomeResp `shouldBe` status200

    afterResp <- httpRequest seed.seedApp "GET" configPath (authHeaders token) ""
    simpleStatus afterResp `shouldBe` status200
    afterCfg <- decodeConfig afterResp
    afterCfg.baseCurrencyEditable `shouldBe` False
