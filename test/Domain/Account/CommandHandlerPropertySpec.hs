{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Account.CommandHandlerPropertySpec
-- Description : Property-based tests for Account command handler
--
-- This module tests mathematical properties and invariants of the Account
-- aggregate command handler using QuickCheck.
--
-- Test Coverage:
--   - Determinism: Same input produces same output
--   - Idempotency: Event replay produces same state
--   - RBAC invariants: Owner in access list, role validation
--   - Business rules: Account creation, access management
--
-- Note: Credit/Debit tests removed - balance changes are now handled by
-- the transfer process manager via AccountBalanceUpdated events.
module Domain.Account.CommandHandlerPropertySpec (spec) where

import Control.Lens ((^.))
import Data.Either (fromRight, isLeft)
import qualified Data.Text as T
import Domain.Account hiding (accountCreatedBy)
import Domain.Account.CommandHandler
import Domain.Account.Events (AccountAccessGranted (..), AccountAccessRevoked (..), AccountCreated (..))
import Domain.Core.Types
import Eventium (latestProjection)
import RIO hiding ((^.))
import Test.Hspec
import Test.QuickCheck
import TestSupport.Generators ()
import TestSupport.Helpers
import Prelude (read)

spec :: Spec
spec = do
  determinismSpec
  invariantSpec
  businessRuleSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get account state
applyEvents :: [AccountEvent] -> Account
applyEvents = latestProjection accountProjection

-- | Create an account with given owner and type
createAccountWithOwner :: Text -> Money -> UserId -> AccountType -> Account
createAccountWithOwner name balance ownerId accType =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated
          { accountCreatedName = name,
            accountCreatedInitialBalance = balance,
            accountCreatedBy = ownerId,
            accountCreatedType = accType
          }
    ]

-- -----------------------------------------------------------------------------
-- Determinism Properties
-- -----------------------------------------------------------------------------

determinismSpec :: Spec
determinismSpec = describe "Determinism Properties" $ do
  describe "When handling commands" $ do
    it "Then CreateAccount produces same events for same input"
      $ property
      $ \(name :: Text) (balance :: Money) (ownerId :: UserId) ->
        let account = applyEvents []
            command =
              CreateAccountAccountCommand
                $ CreateAccount name balance ownerId RegularAccount
            events1 = handleAccountCommand account command
            events2 = handleAccountCommand account command
         in events1 === events2

    it "Then ShareAccount produces same events for same input"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (role :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId RegularAccount
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId role ownerId
              events1 = handleAccountCommand account command
              events2 = handleAccountCommand account command
           in events1 === events2

    it "Then RevokeAccountAccess produces same events for same input"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) ->
        ownerId /= targetId ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId RegularAccount,
                  AccountAccessGrantedAccountEvent
                    $ AccountAccessGranted targetId Editor ownerId
                ]
              account = applyEvents baseEvents
              command =
                RevokeAccountAccessAccountCommand
                  $ RevokeAccountAccess targetId ownerId
              events1 = handleAccountCommand account command
              events2 = handleAccountCommand account command
           in events1 === events2

-- -----------------------------------------------------------------------------
-- Invariant Properties
-- -----------------------------------------------------------------------------

invariantSpec :: Spec
invariantSpec = describe "Invariant Properties" $ do
  describe "When creating account" $ do
    it "Then owner is always in access list"
      $ property
      $ \(name :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null name) ==>
          let account = createAccountWithOwner name balance ownerId RegularAccount
           in hasAccess ownerId account

    it "Then owner has Owner role"
      $ property
      $ \(name :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null name) ==>
          let account = createAccountWithOwner name balance ownerId RegularAccount
           in getUserRole ownerId account === Just Owner

    it "Then maintains non-negative balance for regular accounts"
      $ property
      $ \(name :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null name) ==>
          let account = createAccountWithOwner name balance ownerId RegularAccount
           in unMoney (account ^. accountBalance) >= 0

  describe "When sharing access" $ do
    it "Then target user is added to access list"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (role :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId RegularAccount
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId role ownerId
              result = handleAccountCommand account command
              baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId RegularAccount
                ]
              events = fromRight [] result
              newAccount = applyEvents (baseEvents <> events)
           in hasAccess targetId newAccount

    it "Then target user has granted role"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (role :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId RegularAccount
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId role ownerId
              result = handleAccountCommand account command
              baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId RegularAccount
                ]
              events = fromRight [] result
              newAccount = applyEvents (baseEvents <> events)
           in getUserRole targetId newAccount === Just role

  describe "When revoking access" $ do
    it "Then owner remains in access list"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) ->
        ownerId /= targetId ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId RegularAccount,
                  AccountAccessGrantedAccountEvent
                    $ AccountAccessGranted targetId Editor ownerId
                ]
              account = applyEvents baseEvents
              command =
                RevokeAccountAccessAccountCommand
                  $ RevokeAccountAccess targetId ownerId
              result = handleAccountCommand account command
              events = fromRight [] result
              newAccount = applyEvents (baseEvents <> events)
           in hasAccess ownerId newAccount

-- -----------------------------------------------------------------------------
-- Business Rule Properties
-- -----------------------------------------------------------------------------

businessRuleSpec :: Spec
businessRuleSpec = describe "Business Rule Properties" $ do
  describe "Account creation" $ do
    it "Then sets initial balance"
      $ property
      $ \(name :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null name) ==>
          let account = applyEvents []
              command =
                CreateAccountAccountCommand
                  $ CreateAccount name balance ownerId RegularAccount
              result = handleAccountCommand account command
              events = fromRight [] result
              newAccount = applyEvents events
           in newAccount ^. accountBalance === balance

    it "Then sets account name"
      $ property
      $ \(name :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null name) ==>
          let account = applyEvents []
              command =
                CreateAccountAccountCommand
                  $ CreateAccount name balance ownerId RegularAccount
              result = handleAccountCommand account command
              events = fromRight [] result
              newAccount = applyEvents events
           in newAccount ^. accountName === name

    it "Then rejects empty names"
      $ property
      $ \(balance :: Money) (ownerId :: UserId) ->
        let account = applyEvents []
            command =
              CreateAccountAccountCommand
                $ CreateAccount "" balance ownerId RegularAccount
            result = handleAccountCommand account command
         in isLeft result

  describe "Access management" $ do
    it "Then only owner can share access"
      $ property
      $ \(ownerId :: UserId) (nonOwnerId :: UserId) (targetId :: UserId) (role :: AccountRole) ->
        ownerId /= nonOwnerId && nonOwnerId /= targetId && ownerId /= targetId ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId RegularAccount,
                  AccountAccessGrantedAccountEvent
                    $ AccountAccessGranted nonOwnerId Editor ownerId
                ]
              account = applyEvents baseEvents
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId role nonOwnerId -- non-owner trying to share
              result = handleAccountCommand account command
           in isLeft result

    it "Then owner cannot be removed from access list"
      $ property
      $ \(ownerId :: UserId) ->
        let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId RegularAccount
            command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess ownerId ownerId
            result = handleAccountCommand account command
         in isLeft result

    it "Then external accounts cannot be shared"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (role :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "External" (mockMoney 0) ownerId ExternalAccount
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId role ownerId
              result = handleAccountCommand account command
           in isLeft result

-- -----------------------------------------------------------------------------
-- Arbitrary Instances for Domain Types
-- -----------------------------------------------------------------------------

instance Arbitrary AccountRole where
  arbitrary = elements [Owner, Editor, Viewer]

instance Arbitrary AccountType where
  arbitrary = elements [RegularAccount, ExternalAccount]
