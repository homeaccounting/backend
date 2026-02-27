-- |
-- Module      : Infrastructure.Json
-- Description : Utilities for JSON serialization
--
-- This module provides Template Haskell helpers for deriving JSON instances
-- with consistent field naming conventions across the accounting system.
-- Follows the eventium pattern used in the bank example.
module Infrastructure.Json
  ( -- * JSON Derivation Helpers
    deriveJSONUnPrefixLower,
    unPrefixLower,

    -- * String Utilities
    dropPrefix,
    dropSuffix,
  )
where

import Data.Aeson (Options (..), defaultOptions)
import Data.Aeson.TH (deriveJSON)
import Data.Char (toLower)
import Language.Haskell.TH (Dec, Name, Q, nameBase)

-- -----------------------------------------------------------------------------
-- JSON Derivation
-- -----------------------------------------------------------------------------

-- | Derives JSON instances with field labels unprefixed and lowercased.
--
-- For a data type like:
-- @
-- data AccountCreated = AccountCreated
--  { accountCreatedName :: Text
--  , accountCreatedBalance :: Money
--  }
-- @
--
-- This will generate JSON with field names "name" and "balance".
--
-- Example:
-- >>> deriveJSONUnPrefixLower ''AccountCreated
deriveJSONUnPrefixLower :: Name -> Q [Dec]
deriveJSONUnPrefixLower name =
  deriveJSON (unPrefixLower $ firstCharToLower $ nameBase name) name

-- | Aeson Options that unprefix and lowercase field names.
--
-- Takes a prefix (typically the lowercased type name) and removes it from
-- field labels, then uncapitalizes the first character.
--
-- Example:
-- >>> let opts = unPrefixLower "accountCreated"
-- >>> fieldLabelModifier opts "accountCreatedName"
-- "name"
unPrefixLower :: String -> Options
unPrefixLower prefix =
  defaultOptions
    { fieldLabelModifier = unCapitalize . dropPrefix prefix
    }

-- -----------------------------------------------------------------------------
-- String Utilities
-- -----------------------------------------------------------------------------

-- | Convert first character to lowercase.
--
-- >>> firstCharToLower "AccountCreated"
-- "accountCreated"
--
-- >>> firstCharToLower ""
-- ""
firstCharToLower :: String -> String
firstCharToLower [] = []
firstCharToLower (x : xs) = toLower x : xs

-- | Uncapitalize first character.
--
-- >>> unCapitalize "Name"
-- "name"
--
-- >>> unCapitalize ""
-- ""
unCapitalize :: String -> String
unCapitalize [] = []
unCapitalize (c : cs) = toLower c : cs

-- | Remove prefix from a string.
--
-- Throws an error if the prefix doesn't match.
--
-- >>> dropPrefix "account" "accountName"
-- "Name"
dropPrefix :: String -> String -> String
dropPrefix = dropPrefix' "dropPrefix" id

-- | Remove suffix from a string.
--
-- Throws an error if the suffix doesn't match.
--
-- >>> dropSuffix "Event" "AccountCreatedEvent"
-- "AccountCreated"
dropSuffix :: String -> String -> String
dropSuffix prefix input =
  reverse $ dropPrefix' "dropSuffix" reverse (reverse prefix) (reverse input)

-- Internal helper for prefix/suffix removal
dropPrefix' :: String -> (String -> String) -> String -> String -> String
dropPrefix' fnName strTrans prefix input = go prefix input
  where
    go pre [] = error $ contextual $ "prefix leftover: " ++ strTrans pre
    go [] (c : cs) = c : cs
    go (p : preRest) (c : cRest)
      | p == c = go preRest cRest
      | otherwise =
          error $
            contextual $
              "not equal: " ++ strTrans (p : preRest) ++ " " ++ strTrans (c : cRest)
    contextual msg = fnName ++ ": " ++ msg ++ ". " ++ strTrans prefix ++ " " ++ strTrans input
