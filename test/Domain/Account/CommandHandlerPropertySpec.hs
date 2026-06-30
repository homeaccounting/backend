{-# LANGUAGE OverloadedLabels #-}
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

import qualified Data.Text as T
import Domain.Account
import Domain.Account.Events (AccountClosed (..), AccountCreated (..), AccountRenamed (..))
import Domain.Core.Types
import Eventium (latestProjection)
import Optics ((.~), (?~), (^.))
import RIO hiding ((.~), (^.))
import Test.Hspec
import Test.QuickCheck
import Testkit.Generators
import Testkit.Helpers

spec :: Spec
spec = do
  determinismSpec
  invariantSpec
  businessRuleSpec
  closeReopenSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get account state
applyEvents :: [AccountEvent] -> Account
applyEvents = latestProjection accountProjection

-- | Create an account with given owner and type
createAccountWithOwner :: Text -> Money -> UserId -> AccountType -> Account
createAccountWithOwner acctName balance ownerId accType =
  let limit = case accType of
        Regular _ -> Just (mockMoney 0)
        External -> Nothing
   in applyEvents
        [ AccountCreatedAccountEvent
            $ AccountCreated
              { name = acctName,
                initialBalance = balance,
                by = ownerId,
                accountType = accType,
                overdraftLimit = limit
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
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        let account = applyEvents []
            command =
              CreateAccountAccountCommand
                $ CreateAccount acctName balance ownerId (Regular defaultCash) Nothing
            events1 = handleAccountCommand account command
            events2 = handleAccountCommand account command
         in events1 === events2

    it "Then ShareAccount produces same events for same input"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (targetRole :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId (Regular defaultCash)
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId targetRole ownerId
              events1 = handleAccountCommand account command
              events2 = handleAccountCommand account command
           in events1 === events2

    it "Then RevokeAccountAccess produces same events for same input"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) ->
        ownerId /= targetId ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0)),
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
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId (Regular defaultCash)
           in hasAccess ownerId account

    it "Then owner has Owner role"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId (Regular defaultCash)
           in getUserRole ownerId account === Just Owner

    it "Then Regular account defaults to Just zero overdraft limit"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId (Regular defaultCash)
           in case account ^. #overdraftLimit of
                Just limit -> unMoney limit === 0
                Nothing -> property False

    it "Then External account defaults to Nothing overdraft limit"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId External
           in account ^. #overdraftLimit === Nothing

    it "Then preserves initial balance for regular accounts"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) ==>
          let account = createAccountWithOwner acctName balance ownerId (Regular defaultCash)
           in unMoney (account ^. #balance) === unMoney balance

  describe "When sharing access" $ do
    it "Then target user is added to access list"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (targetRole :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId (Regular defaultCash)
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId targetRole ownerId
              result = handleAccountCommand account command
              baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0))
                ]
              events = fromRight [] result
              newAccount = applyEvents (baseEvents <> events)
           in hasAccess targetId newAccount

    it "Then target user has granted role"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (targetRole :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId (Regular defaultCash)
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId targetRole ownerId
              result = handleAccountCommand account command
              baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0))
                ]
              events = fromRight [] result
              newAccount = applyEvents (baseEvents <> events)
           in getUserRole targetId newAccount === Just targetRole

  describe "When revoking access" $ do
    it "Then owner remains in access list"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) ->
        ownerId /= targetId ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0)),
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
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) && unMoney balance >= 0 ==>
          let account = applyEvents []
              command =
                CreateAccountAccountCommand
                  $ CreateAccount acctName balance ownerId (Regular defaultCash) Nothing
              result = handleAccountCommand account command
              events = fromRight [] result
              newAccount = applyEvents events
           in newAccount ^. #balance === balance

    it "Then sets account name"
      $ property
      $ \(acctName :: Text) (balance :: Money) (ownerId :: UserId) ->
        not (T.null acctName) && unMoney balance >= 0 ==>
          let account = applyEvents []
              command =
                CreateAccountAccountCommand
                  $ CreateAccount acctName balance ownerId (Regular defaultCash) Nothing
              result = handleAccountCommand account command
              events = fromRight [] result
              newAccount = applyEvents events
           in newAccount ^. #name === acctName

    it "Then rejects empty names"
      $ property
      $ \(balance :: Money) (ownerId :: UserId) ->
        let account = applyEvents []
            command =
              CreateAccountAccountCommand
                $ CreateAccount "" balance ownerId (Regular defaultCash) Nothing
            result = handleAccountCommand account command
         in isLeft result

  describe "Access management" $ do
    it "Then only owner can share access"
      $ property
      $ \(ownerId :: UserId) (nonOwnerId :: UserId) (targetId :: UserId) (targetRole :: AccountRole) ->
        ownerId /= nonOwnerId && nonOwnerId /= targetId && ownerId /= targetId ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0)),
                  AccountAccessGrantedAccountEvent
                    $ AccountAccessGranted nonOwnerId Editor ownerId
                ]
              account = applyEvents baseEvents
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId targetRole nonOwnerId -- non-owner trying to share
              result = handleAccountCommand account command
           in isLeft result

    it "Then owner cannot be removed from access list"
      $ property
      $ \(ownerId :: UserId) ->
        let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId (Regular defaultCash)
            command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess ownerId ownerId
            result = handleAccountCommand account command
         in isLeft result

    it "Then external accounts cannot be shared"
      $ property
      $ \(ownerId :: UserId) (targetId :: UserId) (targetRole :: AccountRole) ->
        ownerId /= targetId ==>
          let account = createAccountWithOwner "External" (mockMoney 0) ownerId External
              command =
                ShareAccountAccountCommand
                  $ ShareAccount targetId targetRole ownerId
              result = handleAccountCommand account command
           in isLeft result

  describe "Overdraft enforcement" $ do
    it "Then debit succeeds when within overdraft limit"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn USD) $ \debitAmt ->
          -- Account with balance 0 and overdraft limit >= debit amount
          let account =
                createAccountWithOwner "Test" (mockMoney 0) ownerId (Regular defaultCash)
                  & #overdraftLimit
                  ?~ debitAmt
              command =
                DebitAccountAccountCommand
                  $ DebitAccount debitAmt txId
              result = handleAccountCommand account command
           in result =/= Left InsufficientFunds

    it "Then debit fails when exceeding overdraft limit"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn USD) $ \debitAmt ->
          unMoney debitAmt > 0 ==>
            let account = createAccountWithOwner "Test" (mockMoney 0) ownerId (Regular defaultCash)
                -- Default overdraft is 0, so any positive debit on zero balance fails
                command =
                  DebitAccountAccountCommand
                    $ DebitAccount debitAmt txId
                result = handleAccountCommand account command
             in result === Left InsufficientFunds

    it "Then debit always succeeds with Nothing overdraft limit"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn USD) $ \debitAmt ->
          let account =
                createAccountWithOwner "Test" (mockMoney 0) ownerId (Regular defaultCash)
                  & #overdraftLimit
                  .~ Nothing
              command =
                DebitAccountAccountCommand
                  $ DebitAccount debitAmt txId
              result = handleAccountCommand account command
           in result =/= Left InsufficientFunds

  describe "Overdraft limit management" $ do
    it "Then only owner can set overdraft limit"
      $ property
      $ \(ownerId :: UserId) (nonOwnerId :: UserId) ->
        ownerId /= nonOwnerId ==>
          let account =
                applyEvents
                  [ AccountCreatedAccountEvent
                      $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0)),
                    AccountAccessGrantedAccountEvent
                      $ AccountAccessGranted nonOwnerId Editor ownerId
                  ]
              command =
                SetOverdraftLimitAccountCommand
                  $ SetOverdraftLimit
                    { overdraftLimit = Just (mockMoney 500),
                      setBy = nonOwnerId
                    }
              result = handleAccountCommand account command
           in isLeft result

  describe "Currency enforcement" $ do
    it "Then debit with different currency always returns CurrencyMismatch"
      $ property
      $ \(ownerId :: UserId) (txId :: TransactionId) ->
        forAll (genPositiveMoneyIn EUR) $ \amt ->
          let account = createAccountWithOwner "Test" (mockMoney 1000) ownerId (Regular defaultCash)
              command =
                DebitAccountAccountCommand
                  $ DebitAccount amt txId
              result = handleAccountCommand account command
           in result === Left CurrencyMismatch

-- -----------------------------------------------------------------------------
-- Close / Reopen Properties
-- -----------------------------------------------------------------------------

closeReopenSpec :: Spec
closeReopenSpec = describe "Close / Reopen Properties" $ do
  describe "Round-trip: close then reopen" $ do
    it "Then status returns to Opened for any open regular account"
      $ property
      $ \(ownerId :: UserId) (acctName :: Text) (balance :: Money) ->
        not (T.null acctName) ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated acctName balance ownerId (Regular defaultCash) (Just (mockMoney 0))
                ]
              account = applyEvents baseEvents
              closeCmd = CloseAccountAccountCommand (CloseAccount {by = ownerId})
              closeEvents = fromRight [] (handleAccountCommand account closeCmd)
              accountAfterClose = applyEvents (baseEvents <> closeEvents)
              reopenCmd = ReopenAccountAccountCommand (ReopenAccount {by = ownerId})
              reopenEvents = fromRight [] (handleAccountCommand accountAfterClose reopenCmd)
              finalAccount = applyEvents (baseEvents <> closeEvents <> reopenEvents)
           in finalAccount ^. #status === Opened

  describe "Idempotency-as-rejection: closing an already-closed account" $ do
    it "Then returns AccountAlreadyClosed"
      $ property
      $ \(ownerId :: UserId) ->
        let baseEvents =
              [ AccountCreatedAccountEvent
                  $ AccountCreated "Test" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0)),
                AccountClosedAccountEvent (AccountClosed {by = ownerId})
              ]
            account = applyEvents baseEvents
            closeCmd = CloseAccountAccountCommand (CloseAccount {by = ownerId})
         in handleAccountCommand account closeCmd === Left AccountAlreadyClosed

  describe "Status unaffected by unrelated events" $ do
    it "Then renaming an open account leaves status as Opened"
      $ property
      $ \(ownerId :: UserId) (newName :: Text) ->
        not (T.null newName) ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Original" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0))
                ]
              renameEvent =
                AccountRenamedAccountEvent (AccountRenamed {newName = newName, by = ownerId})
              account = applyEvents (baseEvents <> [renameEvent])
           in account ^. #status === Opened

    it "Then renaming a closed account leaves status as Closed"
      $ property
      $ \(ownerId :: UserId) (newName :: Text) ->
        not (T.null newName) ==>
          let baseEvents =
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Original" (mockMoney 1000) ownerId (Regular defaultCash) (Just (mockMoney 0)),
                  AccountClosedAccountEvent (AccountClosed {by = ownerId})
                ]
              renameEvent =
                AccountRenamedAccountEvent (AccountRenamed {newName = newName, by = ownerId})
              account = applyEvents (baseEvents <> [renameEvent])
           in account ^. #status === Closed

-- -----------------------------------------------------------------------------
-- Arbitrary Instances for Domain Types
-- -----------------------------------------------------------------------------

instance Arbitrary AccountRole where
  arbitrary = elements [Owner, Editor, Viewer]

instance Arbitrary AccountType where
  arbitrary = elements [Regular defaultCash, External]
