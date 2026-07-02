{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Types
-- Description : Generic intent envelope decoder plus the compile-time
--               sum types the prompt router dispatches over.
--
-- @POST \/api\/prompt@ returns an envelope @{ "intent": "<name>", ...fields }@.
-- This module owns the __intent-agnostic__ pieces of that pipeline:
--
--   * 'PromptIntent' — the sum of every supported intent. The router dispatches
--     with an exhaustive @case@, so adding an intent forces handling here, in
--     the router, and in the response mapping (no half-wired intent can ship).
--   * 'decodePromptIntent' — decodes the raw LLM body into a 'PromptIntent',
--     reading the envelope @intent@ discriminator first and only then choosing
--     the matching per-intent payload parser.
--   * 'PromptResult' — the sum of intent outcomes the Web layer maps to the
--     kind-tagged @PromptResponse@ JSON.
--   * 'ResolveError' — the shared resolver/handler failure (→ 400 ValidationErr).
--
-- Per-intent payload types, parsers, guides, resolution, and execution live in
-- the intent's own module (e.g. @Application.Services.Prompt.Transaction.*@);
-- this module contains no intent-specific logic beyond the dispatch table.
module Application.Services.Prompt.Types
  ( PromptIntent (..),
    PromptDecodeError (..),
    decodePromptIntent,
    PromptResult (..),
    ResolveError (..),
    PromptError (..),
  )
where

import Application.ReadModels.Transaction (TransactionData)
import Application.Services.Prompt.Transaction.Intent
  ( TransactionIntent,
    parseTransactionFields,
    transactionIntentName,
  )
import Data.Aeson (Object, Value (..), withObject, (.:))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Domain.Core.Errors (DomainError)
import Domain.Core.Types (TransactionId)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

-- | The sum of every supported prompt intent. Decoding the envelope yields one
-- of these; the router dispatches with an exhaustive @case@. Future intents add
-- constructors here (and are then forced into the decoder, router, and mapping).
data PromptIntent = CreateTransactionIntent TransactionIntent
  deriving (Show, Eq)

-- | Why decoding the LLM body into a 'PromptIntent' failed.
--
--   * 'MalformedResponse' — the model misbehaved: not valid JSON, no usable
--     @intent@ field, or a recognized intent whose payload fields do not parse.
--     The router maps this to __502__ (upstream problem, not the user's).
--   * 'UnknownIntent' — a valid envelope naming an intent we do not support.
--     The router maps this to __400__ (unsupported request).
data PromptDecodeError = MalformedResponse Text | UnknownIntent Text
  deriving (Show, Eq)

-- | Decode a raw LLM response body into a 'PromptIntent'.
--
-- Reads the envelope's @intent@ discriminator first, then dispatches to the
-- matching per-intent payload parser. A malformed body or an intent whose
-- payload fails to parse yields 'MalformedResponse'; a valid envelope naming an
-- unsupported intent yields 'UnknownIntent'. Total.
decodePromptIntent :: BL.ByteString -> Either PromptDecodeError PromptIntent
decodePromptIntent bs = case Aeson.eitherDecode bs of
  Left e -> Left (MalformedResponse ("intent: invalid JSON: " <> T.pack e))
  Right v -> dispatch v
  where
    dispatch :: Value -> Either PromptDecodeError PromptIntent
    dispatch (Object o) = case readIntentName o of
      Left err -> Left (MalformedResponse err)
      Right name -> dispatchName name o
    dispatch _ = Left (MalformedResponse "intent: expected a JSON object")

    dispatchName :: Text -> Object -> Either PromptDecodeError PromptIntent
    dispatchName name o
      | name == transactionIntentName =
          case parsePayload parseTransactionFields o of
            Left err -> Left (MalformedResponse err)
            Right ti -> Right (CreateTransactionIntent ti)
      | otherwise = Left (UnknownIntent name)

-- | Read a non-blank text @intent@ field from the envelope object.
readIntentName :: Object -> Either Text Text
readIntentName o = case parseEither reader o of
  Left _ -> Left "missing 'intent' field"
  Right name
    | T.null (T.strip name) -> Left "missing 'intent' field"
    | otherwise -> Right name
  where
    reader :: Object -> Parser Text
    reader obj = obj .: "intent"

-- | Run a per-intent payload parser over the envelope object, tagging failures.
parsePayload :: (Object -> Parser a) -> Object -> Either Text a
parsePayload p o = first T.pack (parseEither (withObject "PromptIntent" p) (Object o))

-- | The outcome of a successfully executed intent. The Web layer maps each
-- variant to its kind-tagged @PromptResponse@ JSON. Future intents add variants.
data PromptResult = TransactionCreated
  { interpretation :: !Text,
    txId :: !TransactionId,
    tx :: !TransactionData
  }
  deriving (Show, Eq)

-- | A resolution failure shared by the resolver and handler; the Web layer maps
-- it to a __400__ @ValidationErr@ carrying the offending @field@ and @message@.
data ResolveError = ResolveError
  { field :: !Text,
    message :: !Text
  }
  deriving (Show, Eq)

-- | The Application-layer error result of running a prompt. The Web boundary
-- maps each variant to an HTTP status — the Application layer never touches
-- Servant or HTTP concerns.
--
--   * 'PromptDomainError' — a resolution, validation, or write-path failure. Web
--     maps it via @throwDomainError@ (the 'DomainError' carries its own status;
--     typically __400__).
--   * 'PromptFeatureDisabled' — the LLM feature is not enabled. Web maps to
--     __503__.
--   * 'PromptUpstreamError' — the LLM was unreachable, or returned unparseable
--     output after a retry. Web maps to __502__.
data PromptError
  = PromptDomainError DomainError
  | PromptFeatureDisabled
  | PromptUpstreamError Text
  deriving (Show, Eq)
