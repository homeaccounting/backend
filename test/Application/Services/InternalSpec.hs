{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.InternalSpec
-- Description : Unit tests for the service helper module.
--
-- Covers the four pure lifters: 'liftMaybe', 'liftMaybeM', 'liftEitherWith',
-- 'guardE'. The aggregate command runners ('runAccountCmd' etc.) are
-- exercised transitively by the per-service specs and are not unit-tested
-- here.
module Application.Services.InternalSpec (spec) where

import Application.Services.Internal
  ( guardE,
    liftEitherWith,
    liftMaybe,
    liftMaybeM,
  )
import Control.Monad.Trans.Except (runExceptT)
import RIO
import Test.Hspec

spec :: Spec
spec = do
  describe "liftMaybe" $ do
    it "returns Right a when given Just a" $ do
      result <- runExceptT (liftMaybe @IO ("err" :: Text) (Just (42 :: Int)))
      result `shouldBe` Right 42

    it "returns Left e when given Nothing" $ do
      result <- runExceptT (liftMaybe @IO ("err" :: Text) (Nothing :: Maybe Int))
      result `shouldBe` Left "err"

  describe "liftMaybeM" $ do
    it "returns Right a when the action yields Just a" $ do
      result <-
        runExceptT (liftMaybeM ("err" :: Text) (pure (Just (7 :: Int)) :: IO (Maybe Int)))
      result `shouldBe` Right 7

    it "returns Left e when the action yields Nothing" $ do
      result <-
        runExceptT (liftMaybeM ("err" :: Text) (pure (Nothing :: Maybe Int) :: IO (Maybe Int)))
      result `shouldBe` Left "err"

  describe "liftEitherWith" $ do
    it "returns Right a when given Right a, ignoring the mapper" $ do
      result <-
        runExceptT
          (liftEitherWith @IO @Text @Text (\_ -> "boom") (Right (1 :: Int)))
      result `shouldBe` Right 1

    it "applies the mapper to a Left e1" $ do
      result <-
        runExceptT
          (liftEitherWith @IO @Text @Text ("mapped: " <>) (Left "raw" :: Either Text Int))
      result `shouldBe` Left "mapped: raw"

  describe "guardE" $ do
    it "returns Right () when the predicate is True" $ do
      result <- runExceptT (guardE @IO True ("err" :: Text))
      result `shouldBe` Right ()

    it "returns Left e when the predicate is False" $ do
      result <- runExceptT (guardE @IO False ("err" :: Text))
      result `shouldBe` Left "err"
