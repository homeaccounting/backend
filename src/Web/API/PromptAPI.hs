{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.PromptAPI
-- Description : REST endpoint for the natural-language prompt feature
--
-- Defines the Servant API for @POST \/api\/prompt@. The handler is a thin HTTP
-- adapter: it delegates all logic to 'PromptService.handlePrompt' and maps the
-- resulting 'PromptError' ADT to HTTP status codes at this (Web) boundary — the
-- only place Servant errors belong.
--
-- Error mapping:
--
--   * 'PromptDomainError' -> via 'throwDomainError' (the 'DomainError' carries
--     its own status; typically 400)
--   * 'PromptFeatureDisabled' -> 503 Service Unavailable
--   * 'PromptUpstreamError'  -> 502 Bad Gateway
--
-- The success response is a kind-tagged JSON object; the @kind@ discriminator is
-- the extensibility seam for future intents (e.g. @kind:"report"@).
module Web.API.PromptAPI
  ( -- * API Type
    PromptAPI,

    -- * Server
    promptServer,

    -- * Handler (exported for testing)
    promptHandler,

    -- * DTOs (exported for testing)
    PromptRequest (..),
  )
where

import Application.Services.Prompt.Types
  ( PromptError (..),
    PromptResult (..),
  )
import qualified Application.Services.PromptService as PromptService
import Data.Aeson (FromJSON, ToJSON (..), object, (.=))
import Domain.Core.Types (AccountId)
import Infrastructure.App (AppM)
import RIO
import Servant
import Web.ErrorMapping (throwDomainError)
import Web.Middleware.Auth (AuthenticatedUser (..))
import Web.Types (TransactionResponse, fromTransactionData)

-- -----------------------------------------------------------------------------
-- API Type Definition
-- -----------------------------------------------------------------------------

-- | Prompt API type-level definition.
--
--   POST /api/prompt - Interpret a natural-language prompt and act on it.
--
-- Requires a valid JWT (@AuthProtect "jwt"@).
type PromptAPI =
  AuthProtect "jwt"
    :> "api"
    :> "prompt"
    :> ReqBody '[JSON] PromptRequest
    :> Post '[JSON] PromptResponse

-- -----------------------------------------------------------------------------
-- DTOs
-- -----------------------------------------------------------------------------

-- | Request body: the raw natural-language prompt text, plus the account the
-- client currently has selected, if any (issue #28). When @account@ is present
-- it fills the transaction's primary account slot, overriding name-based
-- resolution (an explicit account named in @text@ still wins). @account@ is
-- optional: a body carrying only @text@ decodes with @account = Nothing@ and
-- resolution proceeds by the existing rules.
data PromptRequest = PromptRequest
  { text :: Text,
    account :: Maybe AccountId
  }
  deriving (Show, Generic)

instance FromJSON PromptRequest

instance ToJSON PromptRequest

-- | Response body. Kind-tagged for extensibility: future intents add new
-- constructors emitting a different @kind@ discriminator.
data PromptResponse = TransactionResult
  { interpretation :: Text,
    transaction :: TransactionResponse
  }
  deriving (Show, Eq, Generic)

-- | Hand-written to emit the kind-tagged envelope. No 'FromJSON' is required.
instance ToJSON PromptResponse where
  toJSON r =
    object
      [ "kind" .= ("transaction" :: Text),
        "interpretation" .= r.interpretation,
        "transaction" .= r.transaction
      ]

-- -----------------------------------------------------------------------------
-- Server Implementation
-- -----------------------------------------------------------------------------

-- | Prompt API server implementation.
promptServer :: ServerT PromptAPI AppM
promptServer = promptHandler

-- | Handler for POST /api/prompt.
--
-- Delegates to 'PromptService.handlePrompt' and maps the 'PromptError' ADT to
-- HTTP at this boundary.
promptHandler :: AuthenticatedUser -> PromptRequest -> AppM PromptResponse
promptHandler user req = do
  result <- PromptService.handlePrompt user.userId req.account req.text
  case result of
    Right (TransactionCreated interp tid tdata) ->
      pure (TransactionResult interp (fromTransactionData tid tdata))
    Left (PromptDomainError de) -> throwDomainError de
    Left PromptFeatureDisabled -> throwIO (err503 {errBody = "LLM feature disabled"})
    Left (PromptUpstreamError _) -> throwIO (err502 {errBody = "LLM upstream error"})
