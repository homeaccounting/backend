{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Internal
-- Description : Internal helpers for flattened ExceptT-shaped service bodies.
--
-- Used only by the @Application.Services.*@ modules. The four pure lifters
-- ('liftMaybe', 'liftMaybeM', 'liftEitherWith', 'guardE') turn the common
-- "look up / validate / branch on Maybe-or-Either" patterns into single
-- monadic lines inside an @ExceptT DomainError AppM@ block. The four
-- aggregate command runners ('runAccountCmd', 'runUserCmd',
-- 'runConfigurationCmd', 'runTransactionCmd') wrap @apply*Command@ with
-- consistent rejection logging and 'CommandHandlerError' translation.
--
-- Public service signatures stay @AppM (Either DomainError a)@ — these
-- helpers live inside @runExceptT@ blocks, not in the type signatures.
module Application.Services.Internal
  ( -- * Lifting into ExceptT
    liftMaybe,
    liftMaybeM,
    liftEitherWith,
    guardE,

    -- * Read-model helpers
    getUserData,

    -- * Aggregate command runners
    runAccountCmd,
    runUserCmd,
    runConfigurationCmd,
    runTransactionCmd,
  )
where

import Application.ReadModels.User (UserData, getUser)
import Control.Monad.Trans.Except (ExceptT (..), throwE)
import qualified Data.Text as T
import Data.UUID (UUID)
import Domain.Account.CommandHandler (AccountCommand)
import Domain.Configuration.CommandHandler (ConfigurationCommand)
import Domain.Core.Errors (DomainError (..))
import Domain.Core.Types (UserId)
import Domain.Transaction.CommandHandler (TransactionCommand, TransactionError)
import Domain.User.CommandHandler (UserCommand)
import Eventium (CommandHandlerError, MetadataEnricher)
import Infrastructure.App (AppM, HasEventStore (..), HasReadModel (..))
import Infrastructure.Eventium
  ( applyAccountCommand,
    applyConfigurationCommand,
    applyTransactionCommand,
    applyUserCommand,
  )
import RIO

-- -----------------------------------------------------------------------------
-- Read-model helpers
-- -----------------------------------------------------------------------------

-- | Look up a 'UserData' record by 'UserId', throwing 'NotFound' if missing.
getUserData :: UserId -> ExceptT DomainError AppM UserData
getUserData userId = do
  userRM <- lift (view userReadModelL)
  liftMaybeM (NotFound "User" (tshow userId)) (getUser userRM userId)

-- -----------------------------------------------------------------------------
-- Pure Lifters
-- -----------------------------------------------------------------------------

-- | Throw the given error when the value is 'Nothing'; otherwise return it.
liftMaybe :: (Monad m) => e -> Maybe a -> ExceptT e m a
liftMaybe e = ExceptT . pure . maybe (Left e) Right

-- | Run the action, then 'liftMaybe' on its result.
liftMaybeM :: (Monad m) => e -> m (Maybe a) -> ExceptT e m a
liftMaybeM e action = ExceptT (maybe (Left e) Right <$> action)

-- | Adapt an 'Either' with a custom error producer.
liftEitherWith :: (Monad m) => (e1 -> e2) -> Either e1 a -> ExceptT e2 m a
liftEitherWith f = ExceptT . pure . either (Left . f) Right

-- | Throw the given error when the predicate is 'False'.
guardE :: (Monad m) => Bool -> e -> ExceptT e m ()
guardE cond e = unless cond (throwE e)

-- -----------------------------------------------------------------------------
-- Aggregate Command Runners
--
-- Each runner replaces the call-site triplet of:
--   1. read writer/reader from the env,
--   2. liftIO (apply*Command ...),
--   3. case-split + 'logError' + Left wrapping on rejection.
--
-- The canonical "<aggregate> command rejected" log line lives here once,
-- per the logging policy in the design spec.
-- -----------------------------------------------------------------------------

-- | Apply an Account command, logging and translating rejection.
runAccountCmd ::
  MetadataEnricher ->
  UUID ->
  AccountCommand ->
  ExceptT DomainError AppM ()
runAccountCmd enricher accountId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyAccountCommand writer reader enricher accountId cmd
  case result of
    Left err -> do
      lift $ logError $ "Account command rejected: " <> displayShow err
      throwE $ AccountError "Account command rejected by domain"
    Right _events -> pure ()

-- | Apply a User command, logging and translating rejection.
runUserCmd ::
  MetadataEnricher ->
  UUID ->
  UserCommand ->
  ExceptT DomainError AppM ()
runUserCmd enricher userId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyUserCommand writer reader enricher userId cmd
  case result of
    Left err -> do
      lift $ logError $ "User command rejected: " <> displayShow err
      throwE $ UserError "User command rejected by domain"
    Right _events -> pure ()

-- | Apply a Configuration command, logging and translating rejection.
runConfigurationCmd ::
  MetadataEnricher ->
  UUID ->
  ConfigurationCommand ->
  ExceptT DomainError AppM ()
runConfigurationCmd enricher configId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyConfigurationCommand writer reader enricher configId cmd
  case result of
    Left err -> do
      lift $ logError $ "Configuration command rejected: " <> displayShow err
      throwE $ ConfigurationError (T.pack (show err))
    Right _events -> pure ()

-- | Apply a Transaction command, logging and translating rejection.
--
-- Takes an explicit translator so 'TransactionService.translateTransactionError'
-- (which maps 'CannotEditLabelsInCurrentState' and
-- 'CannotChangeCategoryOnUncategorizedTransaction' to dedicated 'DomainError' values)
-- stays local to its service.
runTransactionCmd ::
  (CommandHandlerError TransactionError -> DomainError) ->
  MetadataEnricher ->
  UUID ->
  TransactionCommand ->
  ExceptT DomainError AppM ()
runTransactionCmd translate enricher txId cmd = do
  writer <- lift (view eventStoreWriterL)
  reader <- lift (view eventStoreReaderL)
  result <- liftIO $ applyTransactionCommand writer reader enricher txId cmd
  case result of
    Left err -> do
      lift $ logError $ "Transaction command rejected: " <> displayShow err
      throwE (translate err)
    Right _events -> pure ()
