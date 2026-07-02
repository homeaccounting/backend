{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.Llm
-- Description : In-memory 'LlmClient' stubs for prompt-pipeline tests.
--
-- The provider is a record of functions, so a test stub is just an 'LlmClient'
-- whose 'complete' returns canned content. Two flavours:
--
--   * 'constLlmClient' — always returns the same JSON body;
--   * 'queueLlmClient' — returns successive bodies from a queue (for the
--     router's retry path); once drained it returns @Left@ so an over-eager
--     retry surfaces as a transport failure rather than silently reusing input.
--
-- 'withLlmClient' injects a stub into an 'AppEnv'.
module Testkit.Llm
  ( constLlmClient,
    queueLlmClient,
    withLlmClient,
  )
where

import Infrastructure.App (AppEnv (..))
import Infrastructure.Llm.Provider
  ( LlmClient (..),
    LlmResponse (..),
  )
import RIO

-- | A client that always succeeds with the given JSON content.
constLlmClient :: Text -> LlmClient
constLlmClient c =
  LlmClient
    { modelName = "stub-const",
      complete = \_ -> pure (Right (LlmResponse c))
    }

-- | A client that returns each queued content in order; once the queue is
-- exhausted every further call returns @Left "stub exhausted"@.
queueLlmClient :: [Text] -> IO LlmClient
queueLlmClient contents = do
  ref <- newIORef contents
  pure
    LlmClient
      { modelName = "stub-queue",
        complete = \_ -> do
          remaining <- readIORef ref
          case remaining of
            [] -> pure (Left "stub exhausted")
            (c : rest) -> do
              writeIORef ref rest
              pure (Right (LlmResponse c))
      }

-- | Inject an 'LlmClient' into an 'AppEnv', enabling the prompt feature.
withLlmClient :: LlmClient -> AppEnv -> AppEnv
withLlmClient c env = env {llmClient = Just c}
