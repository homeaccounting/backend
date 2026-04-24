{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Infrastructure.Bootstrap
-- Description : Process-level runtime setup shared across entry points.
--
-- Collects the one-shot IO initialisation that must run before anything
-- else touches process-global resources: stdout/stderr encoding today,
-- and any future locale, signal, or RTS-knob fiddling. Every executable
-- entry point should call 'configureProcess' first thing in @main@.
module Infrastructure.Bootstrap
  ( configureProcess,
  )
where

import RIO
import System.IO (hSetEncoding, utf8)

-- | Configure process-global handles before any logger or handle write.
--
-- Forces UTF-8 on 'stdout' and 'stderr' so log lines carrying non-ASCII
-- merchant names (Cyrillic, Kanji, emoji, …) don't crash the server on
-- hosts whose default locale is POSIX/C. Idempotent — safe to call more
-- than once, but the intent is "first thing in @main@".
configureProcess :: IO ()
configureProcess = do
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
