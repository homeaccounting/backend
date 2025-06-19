module Main where

import Infrastructure.EventStore
import Web.Server

main :: IO ()
main = do
  appState <- newAppState
  runServer 8080 appState 