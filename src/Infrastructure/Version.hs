{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Version
-- Description : Application version information
module Infrastructure.Version
  ( VersionInfo (..),
    mkVersionInfo,
    displayVersion,
  )
where

import Data.Version (showVersion)
import Paths_backend (version)
import RIO
import qualified RIO.Text as T
import System.Environment (lookupEnv)

-- | Application version information.
--
-- Note: Constructor is exported for test convenience (creating test fixtures).
-- In production, use 'mkVersionInfo'.
data VersionInfo = VersionInfo
  { -- | Semantic version from package.yaml (e.g., "0.2.0")
    appVersion :: !Text,
    -- | Git commit hash (e.g., "abc123f"), "dev" if unset
    commit :: !Text
  }
  deriving (Show, Eq)

-- | Build VersionInfo by reading APP_COMMIT_HASH env var.
mkVersionInfo :: IO VersionInfo
mkVersionInfo = do
  commitHash <- lookupEnvDefault "APP_COMMIT_HASH" "dev"
  pure
    VersionInfo
      { appVersion = T.pack (showVersion version),
        commit = commitHash
      }

-- | Display version for logging: "v0.2.0 (abc123f)"
displayVersion :: VersionInfo -> Utf8Builder
displayVersion vi =
  "v" <> display vi.appVersion <> " (" <> display vi.commit <> ")"

-- | Lookup an environment variable with a default fallback.
lookupEnvDefault :: String -> Text -> IO Text
lookupEnvDefault key def = do
  val <- lookupEnv key
  pure $ maybe def T.pack val
