{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.API.PromptAPISpec
-- Description : Decoding tests for the @POST /api/prompt@ request body.
--
-- Locks in the wire contract of 'PromptRequest': the natural-language @text@ is
-- required, while the selected @account@ is optional. A body carrying only
-- @text@ must still decode (with @account = Nothing@) so clients that don't
-- track a selected account keep working; a body with @account@ carries the id
-- through for the resolver to prefer over name-based resolution.
module Web.API.PromptAPISpec (spec) where

import Data.Aeson (eitherDecode, encode)
import Domain.Core.Types (unAccountId)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T
import Test.Hspec
import Web.API.PromptAPI (PromptRequest (..), PromptResponse (..))

spec :: Spec
spec = do
  requestSpec
  responseSpec

responseSpec :: Spec
responseSpec = describe "Web.API.PromptAPI.PromptResponse (ToJSON)"
  $ it "emits kind \"transactions\" with succeeded and failed arrays"
  $ do
    let resp = TransactionsResult {succeeded = [], failed = [(1, "sourceAccount: no account matches 'foo'")]}
        j = decodeUtf8Lenient (BL.toStrict (encode resp))
        has s = s `T.isInfixOf` j
    ( has "\"kind\":\"transactions\""
        && has "\"succeeded\":[]"
        && has "\"failed\":"
        && has "\"index\":1"
      )
      `shouldBe` True

requestSpec :: Spec
requestSpec = describe "Web.API.PromptAPI.PromptRequest (FromJSON)" $ do
  it "decodes a body with only text (account defaults to Nothing)" $ do
    case eitherDecode "{\"text\":\"coffee 4.50\"}" :: Either String PromptRequest of
      Right (PromptRequest {text = t, account = a}) -> do
        t `shouldBe` "coffee 4.50"
        a `shouldBe` Nothing
      Left err -> expectationFailure ("expected a decode, got: " <> err)

  it "decodes a body carrying the selected account" $ do
    case eitherDecode "{\"text\":\"coffee\",\"account\":\"11111111-1111-1111-1111-111111111111\"}" :: Either String PromptRequest of
      Right (PromptRequest {text = t, account = a}) -> do
        t `shouldBe` "coffee"
        fmap (T.pack . show . unAccountId) a
          `shouldBe` Just "11111111-1111-1111-1111-111111111111"
      Left err -> expectationFailure ("expected a decode, got: " <> err)

  it "rejects a body missing the required text field" $ do
    (eitherDecode "{\"account\":null}" :: Either String PromptRequest)
      `shouldSatisfy` isLeft
