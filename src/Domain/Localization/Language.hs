{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Localization.Language
-- Description : UI language signal (closed locale set).
--
-- A shared value type in the 'Domain.Localization' namespace (parallel to
-- 'Domain.Banking'), keyed off by both the personalization and localization
-- epics. Closed sum because every locale is a real code change (a new catalog).
--
-- JSON is pinned to the lowercase ISO 639-1 code ("en"/"uk") by a hand-written
-- single-shape instance, mirroring 'Domain.Core.Types.Currency'. NOT derived —
-- 'deriveJSON' would emit the constructor names ("En"/"Uk"), which is the wrong
-- wire contract and would break the ConfigurationCreated upcaster.
module Domain.Localization.Language
  ( Language (..),
    languageCode,
    parseLanguage,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import qualified Data.Text as T
import RIO

-- | Supported UI languages. 'En' is the default and fallback.
data Language = En | Uk
  deriving (Show, Eq, Ord, Generic, Enum, Bounded)

-- | The lowercase ISO 639-1 wire code. Note 'Uk' -> "uk" (not "ua").
languageCode :: Language -> Text
languageCode En = "en"
languageCode Uk = "uk"

-- | Parse a language from its ISO 639-1 code (case-insensitive, trimmed).
-- Mirrors 'Domain.Core.Types.parseCurrency' in returning 'Either Text'.
parseLanguage :: Text -> Either Text Language
parseLanguage raw = case T.toLower (T.strip raw) of
  "en" -> Right En
  "uk" -> Right Uk
  other -> Left ("Unsupported language: " <> other)

instance ToJSON Language where
  toJSON = toJSON . languageCode

instance FromJSON Language where
  parseJSON = withText "Language" $ \t ->
    case parseLanguage t of
      Right l -> pure l
      Left err -> fail (T.unpack err)
