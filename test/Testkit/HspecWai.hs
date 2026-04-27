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
  )
where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Network.HTTP.Types (Header, hAuthorization, hContentType)
import Network.Wai.Test (SResponse)
import RIO
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
