{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Web.ErrorMappingSpec (spec) where

import Data.Aeson (Value (..), decode)
import qualified Data.Aeson.KeyMap as KM
import Domain.Core.Errors (DomainError (..), renderDomainError)
import RIO
import Servant (ServerError (..))
import Test.Hspec
import Web.ErrorMapping (mapDomainError)

spec :: Spec
spec = describe "mapDomainError Unauthenticated" $ do
  it "maps to 401 with code UNAUTHENTICATED" $ do
    let e = mapDomainError (Unauthenticated "Invalid refresh token")
    errHTTPCode e `shouldBe` 401
    case decode (errBody e) of
      Just (Object o) -> do
        KM.lookup "code" o `shouldBe` Just (String "UNAUTHENTICATED")
        KM.lookup "message" o `shouldBe` Just (String "Invalid refresh token")
      other -> expectationFailure ("unexpected body: " <> show other)
  it "renders as prose"
    $ renderDomainError (Unauthenticated "x")
    `shouldBe` "Unauthenticated: x"
