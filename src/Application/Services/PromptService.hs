{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.PromptService
-- Description : The prompt router: LLM round-trip + intent dispatch.
--
-- 'handlePrompt' is the single entry point behind @POST \/api\/prompt@. It:
--
--   1. requires the LLM feature to be enabled (else 'PromptFeatureDisabled');
--   2. gathers the user's contexts and builds the message list;
--   3. calls the LLM (one retry on a malformed/unparseable body, or when the
--      model returned an empty @transactions@ list);
--   4. decodes the envelope into a 'PromptIntent' and dispatches it, recording
--      each transaction in the list independently. An empty list after the
--      retry is a comprehension miss (→ __400__); an unparseable body is an
--      upstream problem (→ __502__).
--
-- All failures surface as a pure 'PromptError' ADT — this module imports nothing
-- from @Web.*@ and knows no HTTP status codes. The Web boundary maps
-- 'PromptError' to HTTP: 'PromptDomainError' via @throwDomainError@,
-- 'PromptFeatureDisabled' → __503__, 'PromptUpstreamError' → __502__.
module Application.Services.PromptService
  ( handlePrompt,
  )
where

import Application.Services.Prompt.Builder (buildMessages)
import qualified Application.Services.Prompt.Transaction.Handler as Txn
import Application.Services.Prompt.Transaction.Intent
  ( recordTransactionsGuide,
    recordTransactionsIntentName,
  )
import Application.Services.Prompt.Types
  ( PromptDecodeError (..),
    PromptError (..),
    PromptIntent (..),
    PromptResult,
    decodePromptIntent,
  )
import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Data.Time (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import Domain.Core.Types (AccountId, UserId)
import Infrastructure.App (AppM, llmClientL)
import Infrastructure.Llm.Provider
  ( LlmClient (..),
    LlmMessage (..),
    LlmRequest (..),
    LlmResponse (..),
    LlmRole (..),
  )
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

-- | Handle a natural-language prompt for the given user, committing the
-- resulting operation and returning its 'PromptResult'. All failures surface as
-- a pure 'PromptError' for the Web boundary to map to HTTP.
--
-- @selected@ is the account the client currently has selected (issue #28), if
-- any. When present it fills the transaction's primary account slot (source for
-- expense/transfer, target for income), overriding the resolver's inference; an
-- explicit account name in the prompt still wins over it. See
-- 'Application.Services.Prompt.Transaction.Resolve.resolvePrimaryAccount'.
handlePrompt :: UserId -> Maybe AccountId -> Text -> AppM (Either PromptError PromptResult)
handlePrompt uid selected userText
  | T.null (T.strip userText) =
      pure
        ( Left
            ( PromptDomainError
                (ValidationErr (mkValidationError "text" "prompt text cannot be empty" userText))
            )
        )
  | otherwise = runExceptT $ do
      client <- ExceptT (fmap (maybe (Left PromptFeatureDisabled) Right) (view llmClientL))
      (pctx, rctx) <- ExceptT (fmap (first PromptDomainError) (Txn.gatherContext uid selected))
      now <- liftIO getCurrentTime
      let today = T.pack (formatTime defaultTimeLocale "%Y-%m-%d" now)
          baseMsgs = buildMessages today [recordTransactionsIntentName] [recordTransactionsGuide pctx] userText
          -- Request json_object (not json_schema): the transaction shape is
          -- fully described in the prompt guide and we validate defensively, so
          -- json_object works across all OpenAI-compatible providers. Many
          -- models (e.g. Groq's llama-3.3-70b) reject json_schema outright.
          callOnce msgs = liftIO (client.complete (LlmRequest msgs Nothing))
          -- Pass the WHOLE decoded list (including any 'Left RowError' elements)
          -- so malformed rows are reported as per-row failures while the
          -- well-formed rows still commit.
          dispatch rows =
            ExceptT (fmap (first PromptDomainError) (Txn.runRecordTransactions uid rctx userText rows))
          -- At least one usable (decoded) transaction to record.
          hasUsable rows = not (null (rights rows))
          -- The model returned nothing usable to record (empty list, or every
          -- element malformed) even after a retry: a comprehension miss, not an
          -- upstream outage, so a 400.
          emptyErr =
            PromptDomainError
              (ValidationErr (mkValidationError "transactions" "couldn't identify a transaction in that text" userText))
          unknownErr n =
            PromptDomainError
              (ValidationErr (mkValidationError "intent" ("Unsupported request: " <> n) userText))
      resp1 <- ExceptT (fmap (first (const (PromptUpstreamError "LLM request failed"))) (callOnce baseMsgs))
      case decodePromptIntent (toLBS resp1.content) of
        Right (RecordTransactionsIntent rows) | hasUsable rows -> dispatch rows
        Left (UnknownIntent n) -> throwError (unknownErr n)
        -- Malformed body OR no usable transactions (empty list, or every element
        -- malformed): retry once with a JSON-only nudge.
        _ -> do
          let retryMsgs =
                baseMsgs
                  ++ [ LlmMessage
                         User
                         "Return ONLY one valid JSON object matching the schema, with a non-empty \"transactions\" array listing every transaction you find."
                     ]
          resp2 <- ExceptT (fmap (first (const (PromptUpstreamError "LLM request failed"))) (callOnce retryMsgs))
          case decodePromptIntent (toLBS resp2.content) of
            Right (RecordTransactionsIntent rows) | hasUsable rows -> dispatch rows
            Right (RecordTransactionsIntent _) -> throwError emptyErr
            Left (UnknownIntent n) -> throwError (unknownErr n)
            Left _ -> throwError (PromptUpstreamError "LLM returned unparseable output")
  where
    toLBS t = BL.fromStrict (encodeUtf8 t)
