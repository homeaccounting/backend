{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.BooksCloseServiceSpec
-- Description : closeBooksThrough service behaviour (advance-only).
--
-- Covers the four critical paths through 'closeBooksThrough':
--
--   * first-time set succeeds and the read model exposes the new cutoff;
--   * a later cutoff strictly advances the prior one;
--   * a strictly earlier cutoff is rejected with
--     'CannotRewindBooksCloseDate' carrying the existing and attempted values;
--   * an equal cutoff is rejected (the rule is strict, not @>=@).
module Application.Services.BooksCloseServiceSpec (spec) where

import Application.ReadModels.Configuration (ConfigurationData (..))
import Application.Services.ConfigurationService (closeBooksThrough)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (UserId)
import Infrastructure.App (AppEnv, runAppM)
import RIO
import Test.Hspec
import Testkit.Fixtures (seedDefaultAndRegister)
import Testkit.InMemoryEventStore (createTestAppEnv)
import Testkit.Time (utc)

-- -----------------------------------------------------------------------------
-- Fixtures / helpers
-- -----------------------------------------------------------------------------

-- | Register a fresh user in a seeded environment and return both the env
-- and the new user's id.
seededUser :: IO (AppEnv, UserId)
seededUser = do
  env <- createTestAppEnv
  uid <- seedDefaultAndRegister env "booksclose@test.com"
  pure (env, uid)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "ConfigurationService.closeBooksThrough" $ do
  it "first-time set: succeeds and the read model exposes the new cutoff" $ do
    (env, userId) <- seededUser
    let cutoff = utc 2026 3 31
    result <- runAppM env (closeBooksThrough userId cutoff)
    case result of
      Left err -> expectationFailure $ "closeBooksThrough failed: " <> show err
      Right cfg -> cfg.booksClosedThrough `shouldBe` Just cutoff

  it "advance: a later cutoff strictly advances the prior one" $ do
    (env, userId) <- seededUser
    let t1 = utc 2026 3 31
        t2 = utc 2026 4 30
    firstResult <- runAppM env (closeBooksThrough userId t1)
    firstResult `shouldSatisfy` isRight

    secondResult <- runAppM env (closeBooksThrough userId t2)
    case secondResult of
      Left err -> expectationFailure $ "advance closeBooksThrough failed: " <> show err
      Right cfg -> cfg.booksClosedThrough `shouldBe` Just t2

  it "rewind: a strictly earlier cutoff is rejected with CannotRewindBooksCloseDate" $ do
    (env, userId) <- seededUser
    let t1 = utc 2026 4 30
        t0 = utc 2026 3 31
    firstResult <- runAppM env (closeBooksThrough userId t1)
    firstResult `shouldSatisfy` isRight

    rewindResult <- runAppM env (closeBooksThrough userId t0)
    rewindResult
      `shouldBe` Left
        CannotRewindBooksCloseDate
          { current = t1,
            attempted = t0
          }

  it "equal: an equal cutoff is rejected (advance-only is strict)" $ do
    (env, userId) <- seededUser
    let t1 = utc 2026 4 30
    firstResult <- runAppM env (closeBooksThrough userId t1)
    firstResult `shouldSatisfy` isRight

    equalResult <- runAppM env (closeBooksThrough userId t1)
    equalResult
      `shouldBe` Left
        CannotRewindBooksCloseDate
          { current = t1,
            attempted = t1
          }
