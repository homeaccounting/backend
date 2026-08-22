{-# LANGUAGE OverloadedStrings #-}

module Telegram.TypesSpec (spec) where

import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Domain.Localization.Language (Language (..))
import Telegram.Types (commandMenuNeedsSync)
import Test.Hspec

spec :: Spec
spec = describe "commandMenuNeedsSync" $ do
  let chat = 42 :: Int64

  it "does not sync a fresh English chat (global default is already English)" $
    commandMenuNeedsSync Map.empty chat En `shouldBe` False

  it "syncs a fresh non-English chat" $
    commandMenuNeedsSync Map.empty chat Uk `shouldBe` True

  it "does not re-sync when the memoised language already matches" $
    commandMenuNeedsSync (Map.singleton chat Uk) chat Uk `shouldBe` False

  it "re-syncs when the chat switched back to English" $
    commandMenuNeedsSync (Map.singleton chat Uk) chat En `shouldBe` True

  it "does not sync when a memoised English chat resolves to English" $
    commandMenuNeedsSync (Map.singleton chat En) chat En `shouldBe` False

  it "keys the decision by chat id (other chats do not interfere)" $
    commandMenuNeedsSync (Map.singleton (99 :: Int64) Uk) chat En `shouldBe` False
