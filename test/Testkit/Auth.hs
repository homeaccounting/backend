{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Testkit.Auth
-- Description : Shared JWT helpers for HTTP integration tests
--
-- Consolidates JWT helpers that several spec modules previously carried
-- their own copy of. Failures from the "impossible" paths (a random UUID
-- rejected by 'mkUserIdSafe', or JWT signing going wrong) surface through
-- 'throwString' — still total at the type level, and Hspec renders them
-- as an explicit test failure.
module Testkit.Auth
  ( generateTestToken,
    generateExpiredToken,
  )
where

import qualified Data.UUID.V4 as UUID
import Domain.Core.Types (mkUserIdSafe)
import Infrastructure.Auth.JWT (JWTConfig (..), defaultJWTConfig, generateToken)
import RIO

-- | Produce a signed JWT suitable for @Authorization: Bearer@ in tests.
generateTestToken :: IO Text
generateTestToken = mkToken defaultJWTConfig

-- | Produce a JWT that is already past its expiry — for asserting that the
-- auth middleware rejects expired tokens with 401.
generateExpiredToken :: IO Text
generateExpiredToken = mkToken defaultJWTConfig {expirySeconds = -3600}

mkToken :: JWTConfig -> IO Text
mkToken cfg = do
  uuid <- UUID.nextRandom
  uid <- case mkUserIdSafe uuid of
    Nothing -> throwString "Testkit.Auth: random UUID rejected by mkUserIdSafe"
    Just u -> pure u
  r <- generateToken cfg uid "test@example.com"
  case r of
    Left err -> throwString $ "Testkit.Auth: JWT signing failed: " <> show err
    Right tok -> pure tok
