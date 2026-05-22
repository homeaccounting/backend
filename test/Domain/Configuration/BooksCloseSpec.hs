{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Configuration.BooksCloseSpec
-- Description : Unit tests for the CloseBooksThrough command on the Configuration aggregate
--
-- These tests cover the advance-only books-close cutoff:
--
--   * first-time set on a fresh configuration
--   * advancing the cutoff to a later date
--   * rewinding the cutoff (must be rejected)
--   * equal-date rewind (cutoff must strictly increase)
--
-- The pure handler returns the aggregate-local
-- 'Domain.Configuration.CommandHandler.ConfigurationError'; service-layer
-- translation to 'Domain.Core.Errors.DomainError' is covered in a separate
-- task.
module Domain.Configuration.BooksCloseSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Domain.Configuration.CommandHandler
  ( ConfigurationCommand (..),
    ConfigurationError (..),
    handleConfigurationCommand,
  )
import Domain.Configuration.Commands (CloseBooksThrough (..))
import Domain.Configuration.Events (BooksClosedThroughSet (..))
import Domain.Configuration.Projection
  ( ConfigurationEvent (..),
    configurationDefault,
    configurationProjection,
  )
import Eventium (latestProjection)
import RIO
import Test.Hspec

-- | Helper to construct a UTCTime at midnight on the given Gregorian date.
day :: Integer -> Int -> Int -> UTCTime
day y m d = UTCTime (fromGregorian y m d) (secondsToDiffTime 0)

spec :: Spec
spec = describe "CloseBooksThrough" $ do
  it "first-time set: emits BooksClosedThroughSet" $ do
    let cmd =
          CloseBooksThroughConfigurationCommand
            CloseBooksThrough {closedThrough = day 2026 3 31}
    handleConfigurationCommand configurationDefault cmd
      `shouldBe` Right
        [ BooksClosedThroughSetConfigurationEvent
            (BooksClosedThroughSet (day 2026 3 31))
        ]

  it "advance: emits BooksClosedThroughSet with the later date" $ do
    let cfg =
          latestProjection
            configurationProjection
            [ BooksClosedThroughSetConfigurationEvent
                (BooksClosedThroughSet (day 2026 3 31))
            ]
        cmd =
          CloseBooksThroughConfigurationCommand
            CloseBooksThrough {closedThrough = day 2026 4 30}
    handleConfigurationCommand cfg cmd
      `shouldBe` Right
        [ BooksClosedThroughSetConfigurationEvent
            (BooksClosedThroughSet (day 2026 4 30))
        ]

  it "rewind: returns CannotRewindBooksCloseDate" $ do
    let cfg =
          latestProjection
            configurationProjection
            [ BooksClosedThroughSetConfigurationEvent
                (BooksClosedThroughSet (day 2026 4 30))
            ]
        cmd =
          CloseBooksThroughConfigurationCommand
            CloseBooksThrough {closedThrough = day 2026 3 31}
    handleConfigurationCommand cfg cmd
      `shouldBe` Left
        ( CannotRewindBooksCloseDate
            { current = day 2026 4 30,
              attempted = day 2026 3 31
            }
        )

  it "equal: rewind (cutoff must strictly increase)" $ do
    let cfg =
          latestProjection
            configurationProjection
            [ BooksClosedThroughSetConfigurationEvent
                (BooksClosedThroughSet (day 2026 4 30))
            ]
        cmd =
          CloseBooksThroughConfigurationCommand
            CloseBooksThrough {closedThrough = day 2026 4 30}
    handleConfigurationCommand cfg cmd
      `shouldBe` Left
        ( CannotRewindBooksCloseDate
            { current = day 2026 4 30,
              attempted = day 2026 4 30
            }
        )
