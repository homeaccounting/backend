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
--   * 'PromptIntent' — the sum of every supported intent (currently just
--     'RecordTransactionsIntent'). Adding an intent extends this sum, the
--     decoder's name-dispatch, the router, and the response mapping; kept as a
--     sum so a second intent (e.g. a report) slots in without reshaping the
--     pipeline.
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
    TransactionDecodeError (..),
    PromptDecodeError (..),
    decodePromptIntent,
    PromptResult (..),
    RecordedTransaction (..),
    FailedTransaction (..),
    ResolveError (..),
    PromptError (..),
  )
where

import Application.ReadModels.Transaction (TransactionData)
import Application.Services.Prompt.Transaction.Intent
  ( TransactionDecodeError (..),
    TransactionIntent,
    parseRecordTransactionsFields,
    recordTransactionsIntentName,
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
-- of these; the router matches it to act. Currently a single constructor
-- (@record_transactions@, a list of 1..N transactions); future intents add
-- constructors here and extend the decoder, router, and response mapping.
data PromptIntent = RecordTransactionsIntent [Either TransactionDecodeError TransactionIntent]
  deriving (Show, Eq)

-- | Why decoding the LLM body into a 'PromptIntent' failed.
--
--   * 'MalformedResponse' — the model misbehaved at the __envelope__ level: not
--     valid JSON, no usable @intent@ field, or a structural fault in the
--     recognized intent's payload (e.g. @transactions@ absent or not an array).
--     A single @transactions@ element that fails to parse is __not__ a
--     'MalformedResponse' — it is recovered into a 'Left' 'TransactionDecodeError'
--     inside the decoded list (see 'PromptIntent'), so the router can still
--     commit the well-formed elements. The router maps 'MalformedResponse' to
--     __502__ (upstream problem, not the user's).
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
      | name == recordTransactionsIntentName =
          case parsePayload parseRecordTransactionsFields o of
            Left err -> Left (MalformedResponse err)
            Right tis -> Right (RecordTransactionsIntent tis)
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

-- | The outcome of a successfully executed prompt: the transactions that
-- committed and the ones that failed. Per-transaction commit-good/report-bad —
-- one transaction's failure never blocks the others — and there is no dedup, so
-- no @skipped@. The Web layer maps this to the kind-tagged @PromptResponse@ JSON.
data PromptResult = TransactionsRecorded
  { succeeded :: ![RecordedTransaction],
    failed :: ![FailedTransaction]
  }
  deriving (Show, Eq)

-- | One committed transaction: its zero-based position in the request list, the
-- resolver's human-readable interpretation, and the committed id and read-model
-- row. 'RecordedTransaction' and 'FailedTransaction' are the success/failure
-- halves of a transaction's outcome and share the 'index' field.
data RecordedTransaction = RecordedTransaction
  { index :: !Int,
    interpretation :: !Text,
    txId :: !TransactionId,
    tx :: !TransactionData
  }
  deriving (Show, Eq)

-- | One transaction that could not be recorded: its zero-based position in the
-- request list (the same 'index' 'RecordedTransaction' carries) and a
-- human-readable reason.
data FailedTransaction = FailedTransaction
  { index :: !Int,
    reason :: !Text
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
