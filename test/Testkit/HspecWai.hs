{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.HspecWai
-- Description : Shared @hspec-wai@ request helpers.
--
-- Every Web API spec used to define its own @postJSON@ / @getJSONAuth@ /
-- @deleteAuth@ trio inline. This module consolidates the variants and the
-- @Authorization: Bearer@ header construction so the specs can stay
-- focused on assertions.
--
-- The 'WaiSession'-flavoured helpers here pair with @Test.Hspec.Wai@'s
-- @with mkApp@ pattern. Specs that drive a freshly-seeded 'Application'
-- per scenario (see 'Testkit.TransactionEditFixture') use the
-- 'Network.Wai.Test'-flavoured helpers from that module instead.
module Testkit.HspecWai
  ( -- * Request helpers
    postJSON,
    getJSON,
    postJSONAuth,
    putJSONAuth,
    getJSONAuth,
    deleteAuth,

    -- * Header helpers
    jsonAuthHeaders,
    bearerHeader,
    invalidToken,

    -- * Auth helpers
    registerAndGetToken,

    -- * Account helpers
    createAccount,
    createAccountWith,
    IdResponse (..),
  )
where

import Data.Aeson (FromJSON (..), eitherDecode, encode, object, withObject, (.:), (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.UUID as UUID
import qualified Data.UUID.V4 as UUID
import Network.HTTP.Types (Header, hAuthorization, hContentType, statusCode)
import Network.Wai.Test (SResponse, simpleBody, simpleStatus)
import RIO
import qualified RIO.Text as T
import Test.Hspec (shouldBe)
import Test.Hspec.Wai (WaiSession, request)

-- | A literal "this is not a JWT" string useful for asserting the auth
-- middleware rejects junk Bearer values with 401.
invalidToken :: Text
invalidToken = "invalid.jwt.token"

-- | @Authorization: Bearer ...@ header for the given token.
bearerHeader :: Text -> Header
bearerHeader token = (hAuthorization, "Bearer " <> encodeUtf8 token)

-- | @Content-Type: application/json@ + @Authorization: Bearer ...@ header
-- pair, suitable as the @headers@ argument to 'request'.
jsonAuthHeaders :: Text -> [Header]
jsonAuthHeaders token =
  [ (hContentType, "application/json"),
    bearerHeader token
  ]

-- | POST a JSON body to a path with no auth header.
postJSON :: BS.ByteString -> LBS.ByteString -> WaiSession st SResponse
postJSON path = request "POST" path [(hContentType, "application/json")]

-- | GET a path with no auth header (sets @Content-Type: application/json@).
getJSON :: BS.ByteString -> WaiSession st SResponse
getJSON path = request "GET" path [(hContentType, "application/json")] ""

-- | POST a JSON body with an @Authorization: Bearer@ header.
postJSONAuth :: BS.ByteString -> Text -> LBS.ByteString -> WaiSession st SResponse
postJSONAuth path token = request "POST" path (jsonAuthHeaders token)

-- | PUT a JSON body with an @Authorization: Bearer@ header.
putJSONAuth :: BS.ByteString -> Text -> LBS.ByteString -> WaiSession st SResponse
putJSONAuth path token = request "PUT" path (jsonAuthHeaders token)

-- | GET a path with an @Authorization: Bearer@ header.
getJSONAuth :: BS.ByteString -> Text -> WaiSession st SResponse
getJSONAuth path token =
  request "GET" path (jsonAuthHeaders token) ""

-- | DELETE a path with an @Authorization: Bearer@ header.
deleteAuth :: BS.ByteString -> Text -> WaiSession st SResponse
deleteAuth path token =
  request "DELETE" path [bearerHeader token] ""

-- | Register a fresh user (unique random email) via @POST /api/auth/register@
-- and return the issued JWT token. Throws via 'throwString' if the response
-- body cannot be decoded.
registerAndGetToken :: WaiSession st Text
registerAndGetToken = do
  uid <- liftIO UUID.nextRandom
  let email = "test+" <> T.pack (UUID.toString uid) <> "@example.com" :: Text
      body =
        encode
          $ object
            [ "email" .= email,
              "password" .= ("testpassword123" :: Text)
            ]
  resp <- request "POST" "/api/auth/register" [(hContentType, "application/json")] body
  case eitherDecode (simpleBody resp) :: Either String TokenResponse of
    Left err -> liftIO $ throwString $ "registerAndGetToken: " <> err
    Right r -> pure r.token

-- | Minimal decoder to extract the @token@ field from the registration
-- response. Private to this module.
newtype TokenResponse = TokenResponse {token :: Text}
  deriving (Show)

instance FromJSON TokenResponse where
  parseJSON = withObject "TokenResponse" $ \o -> TokenResponse <$> o .: "token"

-- | Create an account owned by the caller and return its @id@ (UUID text).
-- POSTs @{name, initialBalance: 0, currency}@ to @\/api\/accounts@, asserts
-- 201, and decodes the @id@ field. Throws via 'throwString' on decode failure.
createAccountWith :: Text -> Text -> Text -> WaiSession st Text
createAccountWith tok name currency = do
  let body =
        encode
          $ object
            [ "name" .= name,
              "initialBalance" .= (0 :: Double),
              "currency" .= currency
            ]
  resp <- request "POST" "/api/accounts" (jsonAuthHeaders tok) body
  liftIO $ statusCode (simpleStatus resp) `shouldBe` 201
  case eitherDecode (simpleBody resp) :: Either String IdResponse of
    Left err -> liftIO $ throwString $ "createAccount: " <> err
    Right r -> pure r.id

-- | 'createAccountWith' defaulting the currency to @USD@.
createAccount :: Text -> Text -> WaiSession st Text
createAccount tok name = createAccountWith tok name "USD"

-- | Minimal decoder to extract the @id@ field from a created-resource
-- response (accounts, connections, …).
newtype IdResponse = IdResponse {id :: Text}
  deriving (Show)

instance FromJSON IdResponse where
  parseJSON = withObject "IdResponse" $ \o -> IdResponse <$> o .: "id"
