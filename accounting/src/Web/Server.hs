{-# LANGUAGE OverloadedStrings #-}

module Web.Server
  ( runServer
  , app
  ) where

import Network.Wai
import Network.Wai.Handler.Warp
import Network.Wai.Middleware.Cors
import Servant

import Web.API
import Infrastructure.EventStore

-- CORS policy
corsPolicy :: CorsResourcePolicy
corsPolicy = simpleCorsResourcePolicy
  { corsRequestHeaders = ["content-type"]
  , corsMethods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
  }

-- Create Servant application
app :: AppState -> Application
app appState = cors (const $ Just corsPolicy) $ serve (Proxy :: Proxy API) (server appState)

-- Run the server
runServer :: Int -> AppState -> IO ()
runServer port appState = do
  putStrLn $ "Starting accounting system server on port " ++ show port
  putStrLn "Available endpoints:"
  putStrLn "  GET    /accounts           - List all accounts"
  putStrLn "  POST   /accounts           - Create new account"
  putStrLn "  GET    /accounts/{id}      - Get account by ID"
  putStrLn "  GET    /accounts/{id}/balance - Get account balance"
  putStrLn "  POST   /transfer           - Transfer money between accounts"
  putStrLn "  GET    /events             - List all events (debug)"
  run port (app appState) 