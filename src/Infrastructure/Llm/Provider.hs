{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Llm.Provider
-- Description : LLM provider interface (record-of-functions), like RateProvider.
module Infrastructure.Llm.Provider
  ( LlmRole (..),
    LlmMessage (..),
    LlmRequest (..),
    LlmResponse (..),
    LlmClient (..),
  )
where

import Data.Aeson (Value)
import RIO

data LlmRole = System | User | Assistant
  deriving (Show, Eq)

data LlmMessage = LlmMessage
  { role :: !LlmRole,
    content :: !Text
  }
  deriving (Show, Eq)

-- | A single structured completion request. @jsonSchema@, when present, is sent
-- as an OpenAI @response_format@ json_schema; otherwise json_object is requested.
data LlmRequest = LlmRequest
  { messages :: ![LlmMessage],
    jsonSchema :: !(Maybe Value)
  }
  deriving (Show, Eq)

-- | The assistant's raw text content (expected to be JSON).
newtype LlmResponse = LlmResponse
  { content :: Text
  }
  deriving (Show, Eq)

-- | Provider interface. One value per configured backend.
data LlmClient = LlmClient
  { modelName :: !Text,
    complete :: LlmRequest -> IO (Either Text LlmResponse)
  }
