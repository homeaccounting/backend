{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Description : Text display utilities for RIO logging and encoding
--
-- This module provides reusable text display utilities for converting various
-- types to RIO's Utf8Builder for logging, as well as JSON encoding helpers.
--
-- These utilities are designed to work with RIO's structured logging system
-- and provide consistent text formatting across the application.
--
-- Usage Example:
--
-- >>> logInfo $ "User: " <> displayText userName
-- >>> logInfo $ "Port: " <> displayShow port
-- >>> logInfo $ "Status: " <> displayText statusText
module Data.Text.Display
  ( -- * Display Utilities
    displayText,
    displayShow,

    -- * JSON Encoding Helpers
    encodingError,
  )
where

import Data.Aeson (ToJSON, encode)
import qualified Data.ByteString.Lazy as LBS
import RIO

-- | Display helper for Text values.
--
-- Converts a Text value to Utf8Builder for use in RIO logging.
--
-- Example:
-- >>> logInfo $ "Processing: " <> displayText accountName
displayText :: Text -> Utf8Builder
displayText = displayBytesUtf8 . encodeUtf8

-- | JSON encoding helper for error responses.
--
-- Converts any ToJSON instance to a lazy ByteString.
-- Commonly used for encoding error responses in HTTP handlers.
--
-- Example:
-- >>> encodingError errorResponse
encodingError :: (ToJSON a) => a -> LBS.ByteString
encodingError = encode
