{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.Auth
-- Description : Shared JWT helpers for HTTP integration tests
--
-- Consolidates the @generateTestToken@ helper that several spec modules
-- previously carried their own copy of. Failures from the "impossible"
-- paths (a random UUID rejected by 'mkUserIdSafe', or JWT signing going
-- wrong) surface through 'throwString' — still total at the type level,
-- and Hspec renders them as an explicit test failure.
module Testkit.Auth
  ( generateTestToken,
  )
where

import qualified Data.UUID.V4 as UUID
import Domain.Core.Types (mkUserIdSafe)
import Infrastructure.Auth.JWT (defaultJWTConfig, generateToken)
import RIO

-- | Produce a signed JWT suitable for @Authorization: Bearer@ in tests.
generateTestToken :: IO Text
generateTestToken = do
  uuid <- UUID.nextRandom
  uid <- case mkUserIdSafe uuid of
    Nothing -> throwString "generateTestToken: random UUID rejected by mkUserIdSafe"
    Just u -> pure u
  r <- generateToken defaultJWTConfig uid "test@example.com"
  case r of
    Left err -> throwString $ "generateTestToken: JWT signing failed: " <> show err
    Right tok -> pure tok
