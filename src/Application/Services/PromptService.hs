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
--   3. calls the LLM (one retry, __only__ on a malformed/unparseable body);
--   4. decodes the envelope into a 'PromptIntent' and dispatches with an
--      __exhaustive__ @case@ — the compile-time seam that forces every new
--      intent to be wired end-to-end before it can ship.
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
  ( transactionGuide,
    transactionIntentName,
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
          baseMsgs = buildMessages today [transactionIntentName] [transactionGuide pctx] userText
          -- Request json_object (not json_schema): the transaction shape is
          -- fully described in the prompt guide and we validate defensively, so
          -- json_object works across all OpenAI-compatible providers. Many
          -- models (e.g. Groq's llama-3.3-70b) reject json_schema outright.
          callOnce msgs = liftIO (client.complete (LlmRequest msgs Nothing))
          dispatch pintent = case pintent of
            CreateTransactionIntent ti ->
              ExceptT (fmap (first PromptDomainError) (Txn.runCreateTransaction uid rctx userText ti))
      resp1 <- ExceptT (fmap (first (const (PromptUpstreamError "LLM request failed"))) (callOnce baseMsgs))
      case decodePromptIntent (toLBS resp1.content) of
        Right pintent -> dispatch pintent
        Left (UnknownIntent n) ->
          throwError
            ( PromptDomainError
                (ValidationErr (mkValidationError "intent" ("Unsupported request: " <> n) userText))
            )
        Left (MalformedResponse _) -> do
          let retryMsgs =
                baseMsgs
                  ++ [LlmMessage User "Return ONLY a single valid JSON object matching the schema."]
          resp2 <- ExceptT (fmap (first (const (PromptUpstreamError "LLM request failed"))) (callOnce retryMsgs))
          case decodePromptIntent (toLBS resp2.content) of
            Right pintent -> dispatch pintent
            Left _ -> throwError (PromptUpstreamError "LLM returned unparseable output")
  where
    toLBS t = BL.fromStrict (encodeUtf8 t)
