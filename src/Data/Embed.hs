-- |
-- Module      : Data.Embed
-- Description : Compile-time file embedding.
--
-- A tiny Template Haskell helper that reads a file at build time and splices its
-- contents into the program as a strict 'ByteString', so callers need no runtime
-- file access. Registering the file as a build dependency means editing it
-- triggers recompilation of the embedding module.
--
-- Used by the localization catalogs ("Telegram.I18n",
-- "Domain.Localization.CategoryCatalog") to embed their JSON locale files. Layer-
-- neutral so both the Domain and Telegram layers can use it.
module Data.Embed (embedFileBytes) where

import qualified Data.ByteString as BS
import Language.Haskell.TH (Exp, Q)
import Language.Haskell.TH.Syntax (addDependentFile, lift, runIO)
import Prelude

-- | Read a file at compile time and splice its contents as a strict 'ByteString'.
-- Registers the file as a build dependency so edits trigger recompilation.
embedFileBytes :: FilePath -> Q Exp
embedFileBytes path = do
  addDependentFile path
  bs <- runIO (BS.readFile path)
  lift bs
