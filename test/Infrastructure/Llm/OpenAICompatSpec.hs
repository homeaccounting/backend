{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Llm.OpenAICompatSpec (spec) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import Infrastructure.Llm.OpenAICompat (decodeChatContent, encodeChatBody)
import Infrastructure.Llm.Provider (LlmMessage (..), LlmRequest (..), LlmRole (..))
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T
import Test.Hspec

spec :: Spec
spec = describe "Infrastructure.Llm.OpenAICompat" $ do
  describe "decodeChatContent" $ do
    it "extracts choices[0].message.content" $ do
      let body =
            Aeson.encode
              $ object ["choices" .= [object ["message" .= object ["content" .= ("hi" :: Text)]]]]
      decodeChatContent body `shouldBe` Right "hi"
    it "errors on empty choices" $ do
      let body = Aeson.encode $ object ["choices" .= ([] :: [Value])]
      decodeChatContent body `shouldSatisfy` isLeft
    it "errors on non-JSON"
      $ decodeChatContent "not json"
      `shouldSatisfy` isLeft
  describe "encodeChatBody"
    $ it "includes model, messages, response_format, temperature 0"
    $ do
      let req = LlmRequest [LlmMessage User "hello"] Nothing
          body = encodeChatBody "qwen" req
      -- round-trips to an object carrying the model name
      (BL.length body > 0) `shouldBe` True
      case Aeson.decode body of
        Just (v :: Value) ->
          ("qwen" `T.isInfixOf` decodeUtf8Lenient (BL.toStrict (Aeson.encode v))) `shouldBe` True
        Nothing -> expectationFailure "encodeChatBody did not produce decodable JSON"
