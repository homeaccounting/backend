{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Builder
-- Description : Intent-agnostic assembler of the LLM message list.
--
-- The Builder frames the request envelope shared by every intent — it states
-- the "respond with one JSON object naming the operation" contract, lists the
-- available intents, injects today's date (so relative dates resolve), and then
-- appends each intent's own guide fragment. It knows nothing intent-specific
-- beyond stitching the guides together; the per-intent text lives in the
-- intent's module (e.g. @Application.Services.Prompt.Transaction.Intent@).
module Application.Services.Prompt.Builder
  ( buildMessages,
  )
where

import Infrastructure.Llm.Provider (LlmMessage (..), LlmRole (..))
import RIO
import qualified RIO.Text as T

-- | Assemble the @[LlmMessage]@ for a completion request.
--
-- @buildMessages todayIso intentNames intentGuides userText@ returns exactly two
-- messages:
--
--   * a 'System' message: the envelope framing (contract + available intents +
--     today's date + "output only JSON") followed by the joined intent guides;
--   * a 'User' message carrying the raw user text verbatim.
--
-- @intentNames@ is the list of intent discriminator values the router accepts;
-- the "Available intents" line is built from it rather than a hardcoded literal.
buildMessages :: Text -> [Text] -> [Text] -> Text -> [LlmMessage]
buildMessages todayIso intentNames intentGuides userText =
  [ LlmMessage System systemContent,
    LlmMessage User userText
  ]
  where
    envelope =
      T.intercalate
        "\n"
        [ "You translate a personal-finance instruction into a single JSON object.",
          "Respond with ONE JSON object containing an \"intent\" field naming the operation, plus that operation's fields.",
          "Available intents: " <> T.intercalate ", " intentNames,
          "Today's date is " <> todayIso <> ".",
          "Output only JSON."
        ]
    systemContent =
      T.intercalate "\n\n" (envelope : intentGuides)
