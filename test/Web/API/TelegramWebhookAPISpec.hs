{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.TelegramWebhookAPISpec
-- Description : The webhook only accepts updates carrying the registered secret
module Web.API.TelegramWebhookAPISpec (spec) where

import Infrastructure.Auth.Telegram (webhookSecret)
import Network.HTTP.Types (HeaderName, methodPost)
import Network.Wai.Test (SResponse)
import RIO
import Test.Hspec
import Test.Hspec.Wai
import Testkit.AppEnv (mkApp)

-- | Matches the bot token in the test 'AppEnv'.
testBotToken :: Text
testBotToken = "test_token"

update :: LByteString
update = "{\"update_id\": 1}"

postUpdate :: [(HeaderName, ByteString)] -> WaiSession st SResponse
postUpdate headers =
  request methodPost "/api/telegram/webhook" (("Content-Type", "application/json") : headers) update

secretHeader :: Text -> (HeaderName, ByteString)
secretHeader s = ("X-Telegram-Bot-Api-Secret-Token", encodeUtf8 s)

spec :: Spec
spec = with mkApp $ describe "POST /api/telegram/webhook" $ do
  it "rejects an update without the secret header" $
    postUpdate [] `shouldRespondWith` 401

  it "rejects an update with a wrong secret" $
    postUpdate [secretHeader "forged"] `shouldRespondWith` 401

  it "accepts an update with the registered secret" $
    case webhookSecret testBotToken of
      Nothing -> liftIO (expectationFailure "test bot token yields no secret")
      Just s -> postUpdate [secretHeader s] `shouldRespondWith` 200
