{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.InfoAPI
-- Description : Unauthenticated application info endpoint
module Web.API.InfoAPI
  ( InfoAPI,
    infoAPI,
    InfoResponse (..),
    infoHandler,
  )
where

import Data.Aeson (ToJSON)
import Infrastructure.App (AppM, HasAppConfig (..), HasVersionInfo (..))
import Infrastructure.Config (AppConfig (..), Environment (..))
import Infrastructure.Version (VersionInfo (..))
import RIO
import Servant

-- | Info endpoint type: GET /api/info (no auth)
type InfoAPI = "api" :> "info" :> Get '[JSON] InfoResponse

-- | Proxy for InfoAPI.
infoAPI :: Proxy InfoAPI
infoAPI = Proxy

-- | Info response DTO.
data InfoResponse = InfoResponse
  { status :: Text,
    version :: Text,
    commit :: Text,
    environment :: Text
  }
  deriving (Show, Eq, Generic)

instance ToJSON InfoResponse

-- | Handler for GET /api/info.
infoHandler :: AppM InfoResponse
infoHandler = do
  vi <- view versionInfoL
  AppConfig {environment = env} <- view appConfigL
  pure
    InfoResponse
      { status = "ok",
        version = vi.appVersion,
        commit = vi.commit,
        environment = environmentToText env
      }

-- | Convert Environment to text for JSON response.
environmentToText :: Environment -> Text
environmentToText EnvLocal = "local"
environmentToText EnvTest = "test"
environmentToText EnvProd = "prod"
