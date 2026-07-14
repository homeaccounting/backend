{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.BankConnectionAPISpec
-- Description : HTTP-level tests for the bank-connection CRUD + set-accounts endpoints
--
-- Exercises the connection endpoints under
-- @\/api\/users\/me\/configuration\/banking\/connections@ through the full
-- Servant stack via hspec-wai, using the banking-enabled seeded test harness
-- ('mkAppBankingEnabledSeeded').
--
-- Test matrix:
--   1. POST a connection → 201 with @tokenSet == true@, a @tokenHint@, and
--      NO @token@ field in the JSON body.
--   2. GET /configuration lists the connection and reports
--      @bankingFeatureEnabled == true@.
--   3. PUT rename / enable → 204.
--   4. DELETE → 204; the connection disappears from GET.
--   5. PUT set-accounts with an OWNED account → 204; GET shows the map.
--   6. PUT set-accounts with a foreign/unowned account → 400 with an
--      @accountMap@ field error.
--   7. Mapping an account already used by another connection → 409.
module Web.API.BankConnectionAPISpec (spec) where

import Data.Aeson
  ( Value (..),
    eitherDecode,
    encode,
    object,
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Domain.Banking.Types (unsafeExternalAccountId)
import Infrastructure.Banking.Provider (BankAccount (..))
import Network.HTTP.Types (status200, status201, status204, status400, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import qualified RIO.Text as T
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (StubControls (..), mkAppBankingEnabledSeeded, mkAppBankingEnabledSeededWith)
import Testkit.HspecWai (IdResponse (..), createAccount, jsonAuthHeaders, registerAndGetToken)

-- -----------------------------------------------------------------------------
-- Auth + small JSON helpers
-- -----------------------------------------------------------------------------

-- | Add a connection over HTTP and return its @id@ (UUID text).
addConnection :: Text -> Text -> WaiSession st Text
addConnection tok name = do
  let body =
        encode
          $ object
            [ "provider" .= ("monobank" :: Text),
              "name" .= name,
              "token" .= ("super-secret-token-123" :: Text),
              "enabled" .= True
            ]
  resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
  case eitherDecode (simpleBody resp) :: Either String IdResponse of
    Left err -> liftIO $ throwString $ "addConnection: " <> err
    Right r -> pure r.id

-- | Decode a JSON object body to an aeson 'KeyMap.KeyMap'.
asObject :: SResponse -> IO (KeyMap.KeyMap Value)
asObject resp =
  case eitherDecode (simpleBody resp) :: Either String Value of
    Right (Object o) -> pure o
    other -> throwString $ "expected JSON object, got: " <> show other

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = do
  connectionCrudSpec
  tokenOptionalSpec
  externalAccountsSpec

connectionCrudSpec :: Spec
connectionCrudSpec =
  describe "/api/users/me/configuration/banking/connections"
    $ with mkAppBankingEnabledSeeded
    $ do
      it "POST creates a connection: 201, tokenSet=true, tokenHint, NO token field" $ do
        tok <- registerAndGetToken
        let body =
              encode
                $ object
                  [ "provider" .= ("monobank" :: Text),
                    "name" .= ("My Mono" :: Text),
                    "token" .= ("super-secret-token-123" :: Text),
                    "enabled" .= True
                  ]
        resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
        liftIO $ do
          o <- asObject resp
          KeyMap.lookup "tokenSet" o `shouldBe` Just (Bool True)
          KeyMap.lookup "provider" o `shouldBe` Just (String "monobank")
          KeyMap.lookup "name" o `shouldBe` Just (String "My Mono")
          KeyMap.lookup "enabled" o `shouldBe` Just (Bool True)
          KeyMap.member "token" o `shouldBe` False
          case KeyMap.lookup "tokenHint" o of
            Just (String h) -> T.null h `shouldBe` False
            other -> expectationFailure $ "expected tokenHint string, got: " <> show other

      it "GET /configuration lists the connection and bankingFeatureEnabled == true" $ do
        tok <- registerAndGetToken
        connId <- addConnection tok "Listed"
        resp <- request "GET" "/api/users/me/configuration" (jsonAuthHeaders tok) ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          o <- asObject resp
          KeyMap.lookup "bankingFeatureEnabled" o `shouldBe` Just (Bool True)
          case KeyMap.lookup "banking" o of
            Just (Object b) -> case KeyMap.lookup "connections" b of
              Just (Array conns) -> do
                let ids = [i | Object c <- toList conns, Just (String i) <- [KeyMap.lookup "id" c]]
                ids `shouldContain` [connId]
              other -> expectationFailure $ "expected connections array, got: " <> show other
            other -> expectationFailure $ "expected banking object, got: " <> show other

      it "PUT rename + enable returns 204" $ do
        tok <- registerAndGetToken
        connId <- addConnection tok "Before"
        let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId)
        r1 <- request "PUT" path (jsonAuthHeaders tok) (encode $ object ["name" .= ("After" :: Text)])
        liftIO $ simpleStatus r1 `shouldBe` status204
        r2 <- request "PUT" path (jsonAuthHeaders tok) (encode $ object ["enabled" .= False])
        liftIO $ simpleStatus r2 `shouldBe` status204

      it "PUT token returns 204" $ do
        tok <- registerAndGetToken
        connId <- addConnection tok "TokenChange"
        let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/token")
        r <- request "PUT" path (jsonAuthHeaders tok) (encode $ object ["token" .= ("new-token-xyz" :: Text)])
        liftIO $ simpleStatus r `shouldBe` status204

      it "DELETE returns 204 and removes the connection" $ do
        tok <- registerAndGetToken
        connId <- addConnection tok "ToDelete"
        let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId)
        r <- request "DELETE" path (jsonAuthHeaders tok) ""
        liftIO $ simpleStatus r `shouldBe` status204
        resp <- request "GET" "/api/users/me/configuration" (jsonAuthHeaders tok) ""
        liftIO $ do
          o <- asObject resp
          case KeyMap.lookup "banking" o of
            Just (Object b) -> case KeyMap.lookup "connections" b of
              Just (Array conns) -> do
                let ids = [i | Object c <- toList conns, Just (String i) <- [KeyMap.lookup "id" c]]
                ids `shouldNotContain` [connId]
              _ -> expectationFailure "expected connections array"
            _ -> expectationFailure "expected banking object"

      it "PUT set-accounts with an owned account returns 204 and GET shows the map" $ do
        tok <- registerAndGetToken
        connId <- addConnection tok "Mapped"
        accId <- createAccount tok "Wallet"
        let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/accounts")
            body = encode $ object ["accountMap" .= object [Key.fromText "ext-1" .= accId]]
        r <- request "PUT" path (jsonAuthHeaders tok) body
        liftIO $ simpleStatus r `shouldBe` status204
        resp <- request "GET" "/api/users/me/configuration" (jsonAuthHeaders tok) ""
        liftIO $ do
          o <- asObject resp
          case KeyMap.lookup "banking" o of
            Just (Object b) -> case KeyMap.lookup "connections" b of
              Just (Array conns) -> do
                let mapsFor =
                      [ am
                      | Object c <- toList conns,
                        KeyMap.lookup "id" c == Just (String connId),
                        Just am <- [KeyMap.lookup "accountMap" c]
                      ]
                case mapsFor of
                  [Object am] -> KeyMap.lookup "ext-1" am `shouldBe` Just (String accId)
                  other -> expectationFailure $ "expected single accountMap, got: " <> show other
              _ -> expectationFailure "expected connections array"
            _ -> expectationFailure "expected banking object"

      it "PUT set-accounts with a foreign/unowned account returns 400 with an accountMap field error" $ do
        tok <- registerAndGetToken
        connId <- addConnection tok "BadMap"
        -- A syntactically valid, non-nil UUID that the user does not own.
        foreign_ <- liftIO UUID.nextRandom
        let foreignUuid = T.pack (UUID.toString foreign_)
            path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/accounts")
            body = encode $ object ["accountMap" .= object [Key.fromText "ext-1" .= foreignUuid]]
        r <- request "PUT" path (jsonAuthHeaders tok) body
        liftIO $ do
          simpleStatus r `shouldBe` status400
          o <- asObject r
          case KeyMap.lookup "fieldErrors" o of
            Just (Object fe) -> KeyMap.member "accountMap" fe `shouldBe` True
            other -> expectationFailure $ "expected fieldErrors object, got: " <> show other

      it "mapping an account already used by another connection returns 409" $ do
        tok <- registerAndGetToken
        conn1 <- addConnection tok "Conn1"
        conn2 <- addConnection tok "Conn2"
        accId <- createAccount tok "Shared"
        let mapBody = encode $ object ["accountMap" .= object [Key.fromText "ext-1" .= accId]]
            path1 = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> conn1 <> "/accounts")
            path2 = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> conn2 <> "/accounts")
        r1 <- request "PUT" path1 (jsonAuthHeaders tok) mapBody
        liftIO $ simpleStatus r1 `shouldBe` status204
        r2 <- request "PUT" path2 (jsonAuthHeaders tok) mapBody
        liftIO $ simpleStatus r2 `shouldBe` status409

-- -----------------------------------------------------------------------------
-- Token-optional connections (file-only providers have no credential)
-- -----------------------------------------------------------------------------

-- | The registry backing 'mkAppBankingEnabledSeeded' carries both a
-- pull-capable stub ("monobank") and a file-only stub ("privatbank" — see
-- 'Testkit.AppEnv.stubFileOnlyDescriptor'). The token is required only for
-- the former.
tokenOptionalSpec :: Spec
tokenOptionalSpec =
  describe "token-optional connections"
    $ with mkAppBankingEnabledSeeded
    $ do
      it "POST for a pull-capable provider with no token is rejected with a token field error" $ do
        tok <- registerAndGetToken
        let body =
              encode
                $ object
                  [ "provider" .= ("monobank" :: Text),
                    "name" .= ("No Token Mono" :: Text),
                    "enabled" .= True
                  ]
        resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
        liftIO $ do
          simpleStatus resp `shouldBe` status400
          o <- asObject resp
          case KeyMap.lookup "fieldErrors" o of
            Just (Object fe) -> KeyMap.member "token" fe `shouldBe` True
            other -> expectationFailure $ "expected fieldErrors object, got: " <> show other

      it "POST for a file-only provider with no token is accepted: 201, tokenSet=false" $ do
        tok <- registerAndGetToken
        let body =
              encode
                $ object
                  [ "provider" .= ("privatbank" :: Text),
                    "name" .= ("Privat File Import" :: Text),
                    "enabled" .= True
                  ]
        resp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) body
        liftIO $ do
          simpleStatus resp `shouldBe` status201
          o <- asObject resp
          KeyMap.lookup "tokenSet" o `shouldBe` Just (Bool False)
          KeyMap.lookup "provider" o `shouldBe` Just (String "privatbank")

      it "PUT token on a file-only connection is rejected" $ do
        tok <- registerAndGetToken
        let addBody =
              encode
                $ object
                  [ "provider" .= ("privatbank" :: Text),
                    "name" .= ("Privat" :: Text),
                    "enabled" .= True
                  ]
        addResp <- request "POST" "/api/users/me/configuration/banking/connections" (jsonAuthHeaders tok) addBody
        connId <- case eitherDecode (simpleBody addResp) :: Either String IdResponse of
          Left err -> liftIO $ throwString $ "add file-only connection: " <> err
          Right r -> pure r.id
        let path = encodeUtf8 ("/api/users/me/configuration/banking/connections/" <> connId <> "/token")
        r <- request "PUT" path (jsonAuthHeaders tok) (encode $ object ["token" .= ("new-token" :: Text)])
        liftIO $ simpleStatus r `shouldBe` status400

-- -----------------------------------------------------------------------------
-- External-accounts endpoint (live provider list via the stub factory)
-- -----------------------------------------------------------------------------

-- | Two fixture accounts the stub provider returns for the external-accounts
-- test. @currencyCode@ values are ISO-4217 numeric (980 = UAH, 840 = USD) so
-- the handler's numeric→alpha conversion is exercised.
fixtureAccounts :: [BankAccount]
fixtureAccounts =
  [ BankAccount
      { externalAccountId = unsafeExternalAccountId "ext-acc-1",
        accountNumber = "UA111111111111111111111111111",
        currencyCode = 980,
        cardMasks = [],
        balance = 12345
      },
    BankAccount
      { externalAccountId = unsafeExternalAccountId "ext-acc-2",
        accountNumber = "UA222222222222222222222222222",
        currencyCode = 840,
        cardMasks = [],
        balance = 67890
      }
  ]

externalAccountsSpec :: Spec
externalAccountsSpec =
  describe "/api/banking/connections/:id/external-accounts"
    $ withState mkAppBankingEnabledSeededWith
    $ do
      it "GET returns 200 with the provider's external accounts" $ do
        controls <- getState
        liftIO $ writeIORef controls.stubAccounts (Right fixtureAccounts)
        tok <- registerAndGetToken
        connId <- addConnection tok "Live"
        let path = encodeUtf8 ("/api/banking/connections/" <> connId <> "/external-accounts")
        resp <- request "GET" path (jsonAuthHeaders tok) ""
        liftIO $ do
          simpleStatus resp `shouldBe` status200
          case eitherDecode (simpleBody resp) :: Either String Value of
            Right (Array items) -> do
              length (toList items) `shouldBe` 2
              let objs = [o | Object o <- toList items]
                  extIds = [i | o <- objs, Just (String i) <- [KeyMap.lookup "externalId" o]]
                  ibans = [i | o <- objs, Just (String i) <- [KeyMap.lookup "iban" o]]
                  currencies = [c | o <- objs, Just (String c) <- [KeyMap.lookup "currency" o]]
              extIds `shouldBe` ["ext-acc-1", "ext-acc-2"]
              ibans
                `shouldBe` [ "UA111111111111111111111111111",
                             "UA222222222222222222222222222"
                           ]
              currencies `shouldBe` ["UAH", "USD"]
              -- monobank hardcodes cardMasks = [], so maskedPan is null
              [KeyMap.lookup "maskedPan" o | o <- objs] `shouldBe` [Just Null, Just Null]
            other -> expectationFailure $ "expected JSON array, got: " <> show other
