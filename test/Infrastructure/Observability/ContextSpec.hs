{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Observability.ContextSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.UUID as UUID
import qualified Data.Vault.Lazy as Vault
import Domain.Core.Types (unsafeUserId)
import Eventium (EventMetadata (..), emptyMetadata)
import Infrastructure.Observability.Context
import RIO
import Test.Hspec

spec :: Spec
spec = describe "Observability.Context" $ do
  let cid = UUID.nil
      uid = unsafeUserId UUID.nil
  it "setCorrelationId sets EventMetadata.correlationId" $ do
    let md = setCorrelationId cid (emptyMetadata "E")
    md.correlationId `shouldBe` Just cid
  it "enricherFromContext sets correlationId and userId custom key" $ do
    let md = enricherFromContext (RequestContext cid (Just uid)) (emptyMetadata "E")
    md.correlationId `shouldBe` Just cid
    Map.lookup "userId" md.custom `shouldBe` Just (UUID.toText UUID.nil)
  it "enricherFromContext with no user leaves custom empty" $ do
    let md = enricherFromContext (RequestContext cid Nothing) (emptyMetadata "E")
    md.correlationId `shouldBe` Just cid
    md.custom `shouldBe` mempty
  it "readRequestContext totals to nilRequestContext on empty vault" $ do
    k <- Vault.newKey
    let ctx = readRequestContext k Vault.empty
    ctx.correlationId `shouldBe` nilRequestContext.correlationId
  it "readRequestContext returns the inserted context" $ do
    k <- Vault.newKey
    let v = Vault.insert k (RequestContext cid (Just uid)) Vault.empty
        ctx = readRequestContext k v
    ctx.correlationId `shouldBe` cid
    ctx.userId `shouldBe` Just uid
