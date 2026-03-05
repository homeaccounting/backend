{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module      : Domain.Models
-- Description : Unified domain models for the accounting system
--
-- This module integrates the Account, Transaction, and User aggregates into a unified
-- domain model with combined event and command types. This is the integration
-- layer that enables cross-aggregate operations like the transfer process manager.
--
-- Key Components:
--   - AccountingEvent: Unified event type combining Account, Transaction, and User events
--   - AccountingCommand: Unified command type combining Account, Transaction, and User commands
--   - Event embeddings: TypeEmbeddings between aggregate-specific and unified types
--   - Command embeddings: TypeEmbeddings between aggregate-specific and unified types
--   - Embedded projections: Projections that work with unified event types
--   - Embedded command handlers: Handlers that work with unified types
--
-- This module follows the eventium pattern for multi-aggregate systems,
-- enabling process managers and read models to work across aggregate boundaries.
--
-- Usage:
--
-- With unified types:
-- >>> import Domain.Models
-- >>> -- Use AccountingEvent and AccountingCommand for cross-aggregate operations
-- >>> -- Use embeddings to convert between aggregate-specific and unified types
--
-- With aggregate-specific operations:
-- >>> import Domain.Models
-- >>> -- Access Account, Transaction, and User directly through re-exports
-- >>> issueCommand accountId (AccountCommand someAccountCommand)
-- >>> issueCommand txId (TransactionCommand someTransactionCommand)
-- >>> issueCommand userId (UserCommand someUserCommand)
--
-- Architecture:
--
-- The unified types enable:
--   1. Process managers that listen to events from multiple aggregates
--   2. Read models that project across aggregates
--   3. Sagas that coordinate operations across aggregates
--   4. Unified event store operations
module Domain.Models
  ( -- * Unified Types
    AccountingEvent (..),
    AccountingCommand (..),

    -- * Account Embeddings
    accountEventEmbedding,
    accountCommandEmbedding,

    -- * Transaction Embeddings
    transactionEventEmbedding,
    transactionCommandEmbedding,

    -- * User Embeddings
    userEventEmbedding,
    userCommandEmbedding,

    -- * Embedded Projections
    accountAccountingProjection,
    transactionAccountingProjection,
    userAccountingProjection,

    -- * Embedded Command Handlers
    accountAccountingCommandHandler,
    transactionAccountingCommandHandler,
    userAccountingCommandHandler,

    -- * Re-exports
    module X,
  )
where

import Data.Aeson (Options (constructorTagModifier), defaultOptions)
import Data.Aeson.TH (deriveJSON)
import Domain.Account as X
import Domain.Transaction as X
import Domain.User as X
import Eventium (CommandHandler, Projection, TypeEmbedding (..), embeddedCommandHandler, embeddedProjection)
import Eventium.Json (dropSuffix)
import Eventium.TH (mkSumTypeEmbedding)
import Eventium.TH.SumType (SumTypeTagOptions (ConstructTagName), constructSumType, defaultSumTypeOptions, withTagOptions)

-- -----------------------------------------------------------------------------
-- Unified Event Type
-- -----------------------------------------------------------------------------

-- | Unified event type combining all domain events.
--
-- This sum type includes events from:
--   - Account aggregate (AccountCreated, AccountAccessGranted, AccountAccessRevoked, AccountDebited, AccountCredited)
--   - Transaction aggregate (TransferInitiated, TransferCompleted, TransferFailed)
--   - User aggregate (UserRegistered, UserRegisteredViaTelegram, OAuthAccountLinked, etc.)
--
-- The unified type enables:
--   - Process managers to listen to events from multiple aggregates
--   - Read models to project across aggregates
--   - Event store operations across the entire domain
--
-- The event names are suffixed with "Event" for clarity in the unified context:
--   - AccountCreated becomes AccountCreatedEvent
--   - TransferInitiated becomes TransferInitiatedEvent
--   - UserRegistered becomes UserRegisteredEvent
--   - etc.
--
-- This follows the eventium pattern for multi-aggregate systems.
constructSumType
  "AccountingEvent"
  (withTagOptions (ConstructTagName (++ "Event")) defaultSumTypeOptions)
  (accountEvents ++ transactionEvents ++ userEvents)

-- Derive Show and Eq for the unified event type
deriving instance Show AccountingEvent

deriving instance Eq AccountingEvent

-- Derive JSON instances for the unified event type
-- Constructor tags have "Event" suffix removed for cleaner JSON
deriveJSON (defaultOptions {constructorTagModifier = dropSuffix "Event"}) ''AccountingEvent

-- -----------------------------------------------------------------------------
-- Unified Command Type
-- -----------------------------------------------------------------------------

-- | Unified command type combining all domain commands.
--
-- This sum type includes commands from:
--   - Account aggregate (CreateAccount, ShareAccount, RevokeAccountAccess)
--   - Transaction aggregate (InitiateTransfer, CompleteTransfer, FailTransfer)
--   - User aggregate (RegisterUser, RegisterViaTelegram, LinkOAuthAccount, etc.)
--
-- The unified type enables:
--   - Process managers to issue commands to multiple aggregates
--   - Unified command routing
--   - Cross-aggregate workflows
--
-- The command names are suffixed with "Command" for clarity in the unified context:
--   - CreateAccount becomes CreateAccountCommand
--   - InitiateTransfer becomes InitiateTransferCommand
--   - RegisterUser becomes RegisterUserCommand
--   - etc.
--
-- This follows the eventium pattern for multi-aggregate systems.
constructSumType
  "AccountingCommand"
  (withTagOptions (ConstructTagName (++ "Command")) defaultSumTypeOptions)
  (accountCommands ++ transactionCommands ++ userCommands)

-- Derive Show and Eq for the unified command type
deriving instance Show AccountingCommand

deriving instance Eq AccountingCommand

-- -----------------------------------------------------------------------------
-- Event Embeddings
-- -----------------------------------------------------------------------------

-- | TypeEmbedding for Account events.
--
-- Embeds aggregate-specific AccountEvent into unified AccountingEvent.
-- This enables the Account aggregate to work within the unified domain model.
--
-- Used by embedded projections, embedded command handlers, process managers,
-- and read models.
mkSumTypeEmbedding "accountEventEmbedding" ''AccountEvent ''AccountingEvent

-- | TypeEmbedding for Transaction events.
--
-- Embeds aggregate-specific TransactionEvent into unified AccountingEvent.
-- This enables the Transaction aggregate to work within the unified domain model.
mkSumTypeEmbedding "transactionEventEmbedding" ''TransactionEvent ''AccountingEvent

-- -----------------------------------------------------------------------------
-- Command Embeddings
-- -----------------------------------------------------------------------------

-- | TypeEmbedding for Account commands.
--
-- Embeds aggregate-specific AccountCommand into unified AccountingCommand.
-- This enables process managers to issue Account commands using the unified type.
mkSumTypeEmbedding "accountCommandEmbedding" ''AccountCommand ''AccountingCommand

-- | TypeEmbedding for Transaction commands.
--
-- Embeds aggregate-specific TransactionCommand into unified AccountingCommand.
-- This enables process managers to issue Transaction commands using the unified type.
mkSumTypeEmbedding "transactionCommandEmbedding" ''TransactionCommand ''AccountingCommand

-- -----------------------------------------------------------------------------
-- Embedded Projections
-- -----------------------------------------------------------------------------

-- | Embedded Account projection that works with unified events.
--
-- Wraps the Account projection to work with AccountingEvent instead of
-- AccountEvent. Non-matching events are silently skipped.
accountAccountingProjection :: Projection Account AccountingEvent
accountAccountingProjection = embeddedProjection accountEventEmbedding accountProjection

-- | Embedded Transaction projection that works with unified events.
--
-- Wraps the Transaction projection to work with AccountingEvent instead of
-- TransactionEvent. Non-matching events are silently skipped.
transactionAccountingProjection :: Projection Transaction AccountingEvent
transactionAccountingProjection = embeddedProjection transactionEventEmbedding transactionProjection

-- -----------------------------------------------------------------------------
-- Embedded Command Handlers
-- -----------------------------------------------------------------------------

-- | Embedded Account command handler that works with unified types.
--
-- Non-matching commands return @Right []@ (no events produced), enabling
-- safe multi-aggregate command dispatching.
accountAccountingCommandHandler :: CommandHandler Account AccountingEvent AccountingCommand AccountError
accountAccountingCommandHandler =
  embeddedCommandHandler
    accountEventEmbedding
    accountCommandEmbedding
    accountCommandHandler

-- | Embedded Transaction command handler that works with unified types.
--
-- Non-matching commands return @Right []@ (no events produced), enabling
-- safe multi-aggregate command dispatching.
transactionAccountingCommandHandler :: CommandHandler Transaction AccountingEvent AccountingCommand TransactionError
transactionAccountingCommandHandler =
  embeddedCommandHandler
    transactionEventEmbedding
    transactionCommandEmbedding
    transactionCommandHandler

-- -----------------------------------------------------------------------------
-- User Embeddings
-- -----------------------------------------------------------------------------

-- | TypeEmbedding for User events.
--
-- Embeds aggregate-specific UserEvent into unified AccountingEvent.
mkSumTypeEmbedding "userEventEmbedding" ''UserEvent ''AccountingEvent

-- | TypeEmbedding for User commands.
--
-- Embeds aggregate-specific UserCommand into unified AccountingCommand.
mkSumTypeEmbedding "userCommandEmbedding" ''UserCommand ''AccountingCommand

-- -----------------------------------------------------------------------------
-- Embedded User Projection
-- -----------------------------------------------------------------------------

-- | Embedded User projection that works with unified events.
--
-- Wraps the User projection to work with AccountingEvent instead of
-- UserEvent. Non-matching events are silently skipped.
userAccountingProjection :: Projection User AccountingEvent
userAccountingProjection = embeddedProjection userEventEmbedding userProjection

-- -----------------------------------------------------------------------------
-- Embedded User Command Handler
-- -----------------------------------------------------------------------------

-- | Embedded User command handler that works with unified types.
--
-- Non-matching commands return @Right []@ (no events produced), enabling
-- safe multi-aggregate command dispatching.
userAccountingCommandHandler :: CommandHandler User AccountingEvent AccountingCommand UserError
userAccountingCommandHandler =
  embeddedCommandHandler
    userEventEmbedding
    userCommandEmbedding
    userCommandHandler
