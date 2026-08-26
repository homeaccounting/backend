{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Llm.OpenAICompat
-- Description : OpenAI-compatible /chat/completions client (Ollama, vLLM, …).
module Infrastructure.Llm.OpenAICompat
  ( mkOpenAICompatClient,
    -- exported for tests
    encodeChatBody,
    decodeChatContent,
    httpErrorText,
  )
where

import Data.Aeson (object, withObject, (.:), (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import Infrastructure.Llm.Provider
  ( LlmClient (..),
    LlmMessage (..),
    LlmRequest (..),
    LlmResponse (..),
    LlmRole (..),
  )
import Network.HTTP.Client
  ( Manager,
    RequestBody (RequestBodyLBS),
    httpLbs,
    method,
    parseRequest,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
  )
import qualified Network.HTTP.Client as HC
import Network.HTTP.Types.Status (statusCode)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

roleText :: LlmRole -> Text
roleText = \case
  System -> "system"
  User -> "user"
  Assistant -> "assistant"

-- | Build the /chat/completions request body (pure; deterministic).
encodeChatBody :: Text -> LlmRequest -> BL.ByteString
encodeChatBody model req =
  Aeson.encode
    $ object
      [ "model" .= model,
        "temperature" .= (0 :: Int),
        "stream" .= False,
        "messages" .= map msg req.messages,
        "response_format" .= responseFormat
      ]
  where
    msg m = object ["role" .= roleText m.role, "content" .= m.content]
    responseFormat = case req.jsonSchema of
      Nothing -> object ["type" .= ("json_object" :: Text)]
      Just sch -> object ["type" .= ("json_schema" :: Text), "json_schema" .= sch]

-- | Extract choices[0].message.content from a chat-completions response body.
decodeChatContent :: BL.ByteString -> Either Text Text
decodeChatContent body =
  case Aeson.eitherDecode body of
    Left e -> Left ("LLM: invalid JSON response: " <> T.pack e)
    Right v -> first (\e -> "LLM: unexpected response shape: " <> T.pack e) (parseEither parse v)
  where
    parse = withObject "ChatResponse" $ \o -> do
      choices <- o .: "choices"
      case choices of
        [] -> fail "no choices"
        (c : _) -> do
          m <- withObject "choice" (.: "message") c
          withObject "message" (.: "content") m

-- | Build the error text for a non-2xx @/chat/completions@ response. Carries a
-- bounded prefix of the response body so the provider's own explanation (e.g. a
-- decommissioned-model message) survives into the caller's error and the log —
-- without a bare @"HTTP 400"@ the root cause is invisible. The body is trimmed
-- and length-capped so a large error payload cannot flood a log line.
httpErrorText :: Int -> BL.ByteString -> Text
httpErrorText code body
  | T.null trimmed = prefix
  | otherwise = prefix <> " - " <> trimmed
  where
    prefix = "LLM: HTTP " <> T.pack (show code)
    trimmed = T.strip (T.take 500 (decodeUtf8Lenient (BL.toStrict body)))

-- | Construct an 'LlmClient' backed by an OpenAI-compatible endpoint.
mkOpenAICompatClient :: Text -> Text -> Text -> Int -> Manager -> LlmClient
mkOpenAICompatClient baseUrl model apiKey timeoutMs manager =
  LlmClient
    { modelName = model,
      complete = \req -> tryAsEither $ do
        initReq <- parseRequest (T.unpack (T.dropSuffix "/" baseUrl <> "/chat/completions"))
        let httpReq =
              initReq
                { method = "POST",
                  requestBody = RequestBodyLBS (encodeChatBody model req),
                  requestHeaders =
                    ("Content-Type", "application/json")
                      : [("Authorization", encodeUtf8 ("Bearer " <> apiKey)) | not (T.null apiKey)],
                  HC.responseTimeout = responseTimeoutMicro (timeoutMs * 1000)
                }
        resp <- httpLbs httpReq manager
        let code = statusCode (responseStatus resp)
        pure
          $ if code >= 200 && code < 300
            then LlmResponse <$> decodeChatContent (responseBody resp)
            else Left (httpErrorText code (responseBody resp))
    }
  where
    tryAsEither io = do
      r <- tryAny io
      pure $ case r of
        Left ex -> Left ("LLM: request failed: " <> T.pack (show ex))
        Right e -> e
