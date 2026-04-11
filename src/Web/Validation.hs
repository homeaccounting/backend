{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Web.Validation
-- Description : Shared validation helpers for API handlers
--
-- Eliminates repeated @throwDomainError . ValidationErr . mkValidationError@
-- boilerplate across handler modules.
module Web.Validation
  ( validateField,
    validateFieldCtx,
    validateDateNotInFuture,
  )
where

import Data.Time (UTCTime, getCurrentTime)
import Domain.Core.Errors (DomainError (..), mkValidationError)
import RIO
import Web.ErrorMapping (throwDomainError)

-- | Validate a field parse result, throwing a 'ValidationErr' on 'Left'.
-- Uses the error text as both message and context.
validateField :: (MonadIO m) => Text -> Either Text a -> m a
validateField _ (Right a) = pure a
validateField field (Left err) =
  throwDomainError $ ValidationErr $ mkValidationError field err err

-- | Like 'validateField' but with a custom context value for the error.
validateFieldCtx :: (MonadIO m) => Text -> Text -> Either Text a -> m a
validateFieldCtx _ _ (Right a) = pure a
validateFieldCtx field ctx (Left err) =
  throwDomainError $ ValidationErr $ mkValidationError field err ctx

-- | Validate that an optional date is not in the future.
validateDateNotInFuture :: (MonadIO m) => Maybe UTCTime -> m ()
validateDateNotInFuture maybeDate = do
  now <- liftIO getCurrentTime
  forM_ maybeDate $ \d ->
    when (d > now)
      $ throwDomainError
      $ ValidationErr
      $ mkValidationError "date" "Date cannot be in the future" "date"
