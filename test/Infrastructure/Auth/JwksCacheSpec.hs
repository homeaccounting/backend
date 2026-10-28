{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Infrastructure.Auth.JwksCacheSpec (spec) where

import Crypto.JOSE (JWKSet (..))
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Domain.Core.Types (OAuthProvider (..))
import Infrastructure.Auth.JwksCache
import RIO
import Test.Hspec
import Testkit.IdTokens (testJwkSet, testRsaKey)

-- | A fetcher that counts calls and answers from a mutable script.
scripted :: IORef (Either Text (JWKSet, Maybe NominalDiffTime)) -> IORef Int -> Fetcher
scripted answer calls _ = modifyIORef' calls (+ 1) >> readIORef answer

setup :: Maybe NominalDiffTime -> IO (KeySource, IORef UTCTime, IORef (Either Text (JWKSet, Maybe NominalDiffTime)), IORef Int, JWKSet)
setup maxAge = do
  k <- testRsaKey
  t0 <- getCurrentTime
  clock <- newIORef t0
  let set = testJwkSet k
  answer <- newIORef (Right (set, maxAge))
  calls <- newIORef 0
  src <- newCachingKeySource (readIORef clock) (scripted answer calls)
  pure (src, clock, answer, calls, set)

advance :: IORef UTCTime -> NominalDiffTime -> IO ()
advance clock d = modifyIORef' clock (addUTCTime d)

spec :: Spec
spec = describe "newCachingKeySource" $ do
  it "fetches once and serves from cache within max-age" $ do
    (src, clock, _, calls, set) <- setup (Just 300)
    getKeys src Google False `shouldReturn` Right set
    advance clock 299
    getKeys src Google False `shouldReturn` Right set
    readIORef calls `shouldReturn` 1

  it "refetches after max-age, defaulting to 3600 s" $ do
    (src, clock, _, calls, _) <- setup Nothing
    _ <- getKeys src Google False
    advance clock 3599
    _ <- getKeys src Google False
    readIORef calls `shouldReturn` 1
    advance clock 2
    _ <- getKeys src Google False
    readIORef calls `shouldReturn` 2

  it "keeps providers separate" $ do
    (src, _, _, calls, _) <- setup (Just 300)
    _ <- getKeys src Google False
    _ <- getKeys src Apple False
    readIORef calls `shouldReturn` 2

  it "honours a forced refetch at most once per 60 s" $ do
    (src, clock, _, calls, _) <- setup (Just 3600)
    _ <- getKeys src Google False
    advance clock 10
    _ <- getKeys src Google True
    readIORef calls `shouldReturn` 1
    advance clock 51
    _ <- getKeys src Google True
    readIORef calls `shouldReturn` 2
    _ <- getKeys src Google True
    readIORef calls `shouldReturn` 2

  it "serves the stale set when a refetch fails, and fails without one" $ do
    (src, clock, answer, _, set) <- setup (Just 60)
    _ <- getKeys src Google False
    writeIORef answer (Left "boom")
    advance clock 61
    getKeys src Google False `shouldReturn` Right set
    getKeys src Apple False >>= (`shouldSatisfy` isLeft)

  it "does not retry a failed first fetch within 60 s" $ do
    (src, clock, answer, calls, _) <- setup (Just 60)
    writeIORef answer (Left "boom")
    getKeys src Google False >>= (`shouldSatisfy` isLeft)
    advance clock 59
    getKeys src Google False >>= (`shouldSatisfy` isLeft)
    readIORef calls `shouldReturn` 1

  it "serves the stale set when a forced refetch fails" $ do
    (src, clock, answer, calls, set) <- setup (Just 60)
    _ <- getKeys src Google False
    writeIORef answer (Left "boom")
    advance clock 61
    getKeys src Google True `shouldReturn` Right set
    readIORef calls `shouldReturn` 2

  it "moves the expiry forward after a successful forced refetch" $ do
    (src, clock, _, calls, _) <- setup (Just 300)
    _ <- getKeys src Google False
    advance clock 100
    _ <- getKeys src Google True
    readIORef calls `shouldReturn` 2
    -- Past the first set's expiry (300 s), within the refetched one's (400 s).
    advance clock 250
    _ <- getKeys src Google False
    readIORef calls `shouldReturn` 2

  it "runs one fetch for concurrent first requests" $ do
    k <- testRsaKey
    t0 <- getCurrentTime
    started <- newEmptyMVar
    release <- newEmptyMVar
    calls <- newIORef (0 :: Int)
    let fetcher _ = do
          modifyIORef' calls (+ 1)
          _ <- tryPutMVar started ()
          readMVar release
          pure (Right (testJwkSet k, Nothing))
    src <- newCachingKeySource (pure t0) fetcher
    callers <- mapM (const (async (getKeys src Google False))) [1 .. 8 :: Int]
    takeMVar started
    -- Give the other callers time to reach the cache while the fetch is in flight.
    threadDelay 100000
    putMVar release ()
    results <- mapM wait callers
    results `shouldBe` replicate 8 (Right (testJwkSet k))
    readIORef calls `shouldReturn` 1

  it "releases the provider when the fetcher throws" $ do
    k <- testRsaKey
    t0 <- getCurrentTime
    clock <- newIORef t0
    failing <- newIORef True
    let fetcher _ = do
          f <- readIORef failing
          if f then throwString "fetcher crashed" else pure (Right (testJwkSet k, Nothing))
    src <- newCachingKeySource (readIORef clock) fetcher
    (getKeys src Google False :: IO (Either Text JWKSet)) `shouldThrow` anyException
    writeIORef failing False
    advance clock 61
    timeout 1000000 (getKeys src Google False) `shouldReturn` Just (Right (testJwkSet k))

  describe "fixedKeySource"
    $ it "always returns its set"
    $ do
      k <- testRsaKey
      getKeys (fixedKeySource (testJwkSet k)) Apple True `shouldReturn` Right (testJwkSet k)
