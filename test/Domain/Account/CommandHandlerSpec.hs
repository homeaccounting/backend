{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Domain.Account.CommandHandlerSpec
-- Description : Unit tests for Account command handler
--
-- This module tests the Account aggregate command handler business logic.
--
-- Test Coverage:
--   - CreateAccount: Creation with owner and account type
--   - ShareAccount: Granting access to other users
--   - RevokeAccountAccess: Removing access from users
--   - State transitions and invariants
--
-- Note: Credit/Debit operations have been removed in favor of the transfer-only
-- model. Balance changes are handled by the transfer process manager.
module Domain.Account.CommandHandlerSpec (spec) where

import Data.Either (isLeft)
import Domain.Account
import Domain.Account.CommandHandler
import Domain.Account.Commands (CreditAccount (..), DebitAccount (..), SetOverdraftLimit (..))
import Domain.Account.Events
  ( AccountAccessGranted (..),
    AccountAccessRevoked (..),
    AccountCreated (..),
  )
import Domain.Core.Types
import Eventium (latestProjection)
import Optics ((^.))
import RIO hiding ((^.))
import Test.Hspec
import Testkit.Generators ()
import Testkit.Helpers
import Prelude (head, read)

spec :: Spec
spec = do
  createAccountSpec
  shareAccountSpec
  revokeAccessSpec
  currencyMismatchSpec
  setOverdraftLimitSpec

-- -----------------------------------------------------------------------------
-- Helper Functions
-- -----------------------------------------------------------------------------

-- | Apply events to get account state
applyEvents :: [AccountEvent] -> Account
applyEvents = latestProjection accountProjection

-- | Create a default empty account (no events applied)
emptyAccount :: Account
emptyAccount = applyEvents []

-- | Test user IDs
testOwnerId :: UserId
testOwnerId = mockUserId (read "11111111-1111-1111-1111-111111111111")

testEditorId :: UserId
testEditorId = mockUserId (read "22222222-2222-2222-2222-222222222222")

testViewerId :: UserId
testViewerId = mockUserId (read "33333333-3333-3333-3333-333333333333")

-- | Create a regular account with an owner
regularAccountWithOwner :: UserId -> Account
regularAccountWithOwner ownerId =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated "Test Account" (mockMoney 1000) ownerId RegularAccount (Just (mockMoney 0))
    ]

-- | Create an external account with an owner
externalAccountWithOwner :: UserId -> Account
externalAccountWithOwner ownerId =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated "External" (mockMoney 0) ownerId ExternalAccount Nothing
    ]

-- | Create an account with shared access
accountWithSharedAccess :: UserId -> UserId -> AccountRole -> Account
accountWithSharedAccess ownerId sharedUserId role =
  applyEvents
    [ AccountCreatedAccountEvent
        $ AccountCreated "Shared Account" (mockMoney 1000) ownerId RegularAccount (Just (mockMoney 0)),
      AccountAccessGrantedAccountEvent
        $ AccountAccessGranted sharedUserId role ownerId
    ]

-- -----------------------------------------------------------------------------
-- CreateAccount Tests
-- -----------------------------------------------------------------------------

createAccountSpec :: Spec
createAccountSpec = describe "CreateAccount Command" $ do
  context "Given empty account" $ do
    describe "When creating regular account with valid data" $ do
      it "Then emits AccountCreated event" $ do
        let account = emptyAccount
        let command =
              CreateAccountAccountCommand
                $ CreateAccount
                  { name = "Savings",
                    initialBalance = mockMoney 1000,
                    createdBy = testOwnerId,
                    accountType = RegularAccount,
                    overdraftLimit = Nothing
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              AccountCreatedAccountEvent created -> do
                created.name `shouldBe` "Savings"
                created.initialBalance `shouldBe` mockMoney 1000
                created.by `shouldBe` testOwnerId
                created.accountType `shouldBe` RegularAccount
              _ -> expectationFailure "Expected AccountCreated event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then created account has correct state" $ do
        let account = emptyAccount
        let command =
              CreateAccountAccountCommand
                $ CreateAccount
                  { name = "Checking",
                    initialBalance = mockMoney 500,
                    createdBy = testOwnerId,
                    accountType = RegularAccount,
                    overdraftLimit = Nothing
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            let newAccount = applyEvents events
            newAccount ^. #name `shouldBe` "Checking"
            newAccount ^. #balance `shouldBe` mockMoney 500
            newAccount ^. #createdBy `shouldBe` testOwnerId
            newAccount ^. #accountType `shouldBe` RegularAccount
            newAccount ^. #overdraftLimit `shouldBe` Just (mockMoney 0)
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then owner is automatically added to access list" $ do
        let account = emptyAccount
        let command =
              CreateAccountAccountCommand
                $ CreateAccount
                  { name = "My Account",
                    initialBalance = mockMoney 0,
                    createdBy = testOwnerId,
                    accountType = RegularAccount,
                    overdraftLimit = Nothing
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            let newAccount = applyEvents events
            let accessList = newAccount ^. #accessList
            length accessList `shouldBe` 1
            let ownerAccess = head accessList
            ownerAccess.userId `shouldBe` testOwnerId
            ownerAccess.role `shouldBe` Owner
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When creating external account" $ do
      it "Then emits AccountCreated event with ExternalAccount type" $ do
        let account = emptyAccount
        let command =
              CreateAccountAccountCommand
                $ CreateAccount
                  { name = "External",
                    initialBalance = mockMoney 0,
                    createdBy = testOwnerId,
                    accountType = ExternalAccount,
                    overdraftLimit = Nothing
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              AccountCreatedAccountEvent created ->
                created.accountType `shouldBe` ExternalAccount
              _ -> expectationFailure "Expected AccountCreated event"
            let newAccount = applyEvents events
            newAccount ^. #overdraftLimit `shouldBe` Nothing
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When creating account with empty name" $ do
      it "Then rejects command (no events)" $ do
        let account = emptyAccount
        let command =
              CreateAccountAccountCommand
                $ CreateAccount
                  { name = "",
                    initialBalance = mockMoney 1000,
                    createdBy = testOwnerId,
                    accountType = RegularAccount,
                    overdraftLimit = Nothing
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

  context "Given existing account" $ do
    describe "When attempting to create account again" $ do
      it "Then ignores command (no events)" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              CreateAccountAccountCommand
                $ CreateAccount
                  { name = "Another Account",
                    initialBalance = mockMoney 500,
                    createdBy = testOwnerId,
                    accountType = RegularAccount,
                    overdraftLimit = Nothing
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- ShareAccount Tests
-- -----------------------------------------------------------------------------

shareAccountSpec :: Spec
shareAccountSpec = describe "ShareAccount Command" $ do
  context "Given regular account with owner" $ do
    describe "When owner shares with another user as Editor" $ do
      it "Then emits AccountAccessGranted event" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testEditorId,
                    role = Editor,
                    grantedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              AccountAccessGrantedAccountEvent granted -> do
                granted.userId `shouldBe` testEditorId
                granted.role `shouldBe` Editor
                granted.by `shouldBe` testOwnerId
              _ -> expectationFailure "Expected AccountAccessGranted event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then user is added to access list with correct role" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testEditorId,
                    role = Editor,
                    grantedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            let baseEvents =
                  [ AccountCreatedAccountEvent
                      $ AccountCreated "Test Account" (mockMoney 1000) testOwnerId RegularAccount (Just (mockMoney 0))
                  ]
            let newAccount = applyEvents (baseEvents <> events)
            getUserRole testEditorId newAccount `shouldBe` Just Editor
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When owner shares with another user as Viewer" $ do
      it "Then emits AccountAccessGranted event with Viewer role" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testViewerId,
                    role = Viewer,
                    grantedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              AccountAccessGrantedAccountEvent granted ->
                granted.role `shouldBe` Viewer
              _ -> expectationFailure "Expected AccountAccessGranted event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When non-owner tries to share" $ do
      it "Then rejects command (no events)" $ do
        let account = accountWithSharedAccess testOwnerId testEditorId Editor
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testViewerId,
                    role = Viewer,
                    grantedBy = testEditorId -- Editor trying to share
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

    describe "When owner tries to share with self" $ do
      it "Then rejects command (no events)" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testOwnerId, -- Sharing with self
                    role = Editor,
                    grantedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

  context "Given external account" $ do
    describe "When owner tries to share external account" $ do
      it "Then rejects command (external accounts cannot be shared)" $ do
        let account = externalAccountWithOwner testOwnerId
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testEditorId,
                    role = Editor,
                    grantedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

  context "Given account doesn't exist" $ do
    describe "When trying to share" $ do
      it "Then rejects command (no events)" $ do
        let account = emptyAccount
        let command =
              ShareAccountAccountCommand
                $ ShareAccount
                  { userId = testEditorId,
                    role = Editor,
                    grantedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- RevokeAccountAccess Tests
-- -----------------------------------------------------------------------------

revokeAccessSpec :: Spec
revokeAccessSpec = describe "RevokeAccountAccess Command" $ do
  context "Given account with shared access" $ do
    describe "When owner revokes Editor's access" $ do
      it "Then emits AccountAccessRevoked event" $ do
        let account = accountWithSharedAccess testOwnerId testEditorId Editor
        let command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess
                  { userId = testEditorId,
                    revokedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            length events `shouldBe` 1
            case head events of
              AccountAccessRevokedAccountEvent revoked -> do
                revoked.userId `shouldBe` testEditorId
                revoked.by `shouldBe` testOwnerId
              _ -> expectationFailure "Expected AccountAccessRevoked event"
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then user is removed from access list" $ do
        let account = accountWithSharedAccess testOwnerId testEditorId Editor
        let command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess
                  { userId = testEditorId,
                    revokedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        case result of
          Right events -> do
            let baseEvents =
                  [ AccountCreatedAccountEvent
                      $ AccountCreated "Shared Account" (mockMoney 1000) testOwnerId RegularAccount (Just (mockMoney 0)),
                    AccountAccessGrantedAccountEvent
                      $ AccountAccessGranted testEditorId Editor testOwnerId
                  ]
            let newAccount = applyEvents (baseEvents <> events)
            hasAccess testEditorId newAccount `shouldBe` False
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

    describe "When non-owner tries to revoke" $ do
      it "Then rejects command (no events)" $ do
        -- Account with Owner and two other users
        let account =
              applyEvents
                [ AccountCreatedAccountEvent
                    $ AccountCreated "Test" (mockMoney 1000) testOwnerId RegularAccount (Just (mockMoney 0)),
                  AccountAccessGrantedAccountEvent
                    $ AccountAccessGranted testEditorId Editor testOwnerId,
                  AccountAccessGrantedAccountEvent
                    $ AccountAccessGranted testViewerId Viewer testOwnerId
                ]
        let command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess
                  { userId = testViewerId,
                    revokedBy = testEditorId -- Editor trying to revoke
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

    describe "When owner tries to revoke their own access" $ do
      it "Then rejects command (owner cannot be removed)" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess
                  { userId = testOwnerId, -- Trying to remove owner
                    revokedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

    describe "When trying to revoke from user without access" $ do
      it "Then rejects command (nothing to revoke)" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess
                  { userId = testEditorId, -- Has no access
                    revokedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

  context "Given account doesn't exist" $ do
    describe "When trying to revoke access" $ do
      it "Then rejects command (no events)" $ do
        let account = emptyAccount
        let command =
              RevokeAccountAccessAccountCommand
                $ RevokeAccountAccess
                  { userId = testEditorId,
                    revokedBy = testOwnerId
                  }
        let result = handleAccountCommand account command

        result `shouldSatisfy` isLeft

-- -----------------------------------------------------------------------------
-- CurrencyMismatch Tests
-- -----------------------------------------------------------------------------

currencyMismatchSpec :: Spec
currencyMismatchSpec = describe "CurrencyMismatch" $ do
  let testTransactionId = mockTransactionId (read "44444444-4444-4444-4444-444444444444")

  context "Given USD account" $ do
    describe "When debiting with EUR" $ do
      it "Then returns CurrencyMismatch error" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              DebitAccountAccountCommand
                $ DebitAccount
                  { amount = mockMoneyWith EUR 100,
                    transactionId = testTransactionId,
                    reason = "Transfer"
                  }
        let result = handleAccountCommand account command
        result `shouldBe` Left CurrencyMismatch

    describe "When crediting with EUR" $ do
      it "Then returns CurrencyMismatch error" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              CreditAccountAccountCommand
                $ CreditAccount
                  { amount = mockMoneyWith EUR 100,
                    transactionId = testTransactionId,
                    reason = "Transfer"
                  }
        let result = handleAccountCommand account command
        result `shouldBe` Left CurrencyMismatch

-- -----------------------------------------------------------------------------
-- SetOverdraftLimit Tests
-- -----------------------------------------------------------------------------

setOverdraftLimitSpec :: Spec
setOverdraftLimitSpec = describe "SetOverdraftLimit Command" $ do
  context "Given regular account with owner" $ do
    describe "When owner sets overdraft limit" $ do
      it "Then emits OverdraftLimitSet event" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoney 500),
                    setBy = testOwnerId
                  }
        let result = handleAccountCommand account command
        case result of
          Right events -> length events `shouldBe` 1
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then overdraft limit is applied to account state" $ do
        let baseEvents =
              [ AccountCreatedAccountEvent
                  $ AccountCreated "Test Account" (mockMoney 1000) testOwnerId RegularAccount (Just (mockMoney 0))
              ]
        let account = applyEvents baseEvents
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoney 500),
                    setBy = testOwnerId
                  }
        case handleAccountCommand account command of
          Right events -> do
            let newAccount = applyEvents (baseEvents <> events)
            newAccount ^. #overdraftLimit `shouldBe` Just (mockMoney 500)
          Left err -> expectationFailure $ "Expected Right, got Left: " ++ show err

      it "Then can set to Nothing for unlimited overdraft" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Nothing,
                    setBy = testOwnerId
                  }
        let result = handleAccountCommand account command
        shouldBeRight result

    describe "When non-owner tries to set overdraft limit" $ do
      it "Then rejects command" $ do
        let account = accountWithSharedAccess testOwnerId testEditorId Editor
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoney 500),
                    setBy = testEditorId
                  }
        let result = handleAccountCommand account command
        result `shouldSatisfy` isLeft

    describe "When setting overdraft with currency mismatch" $ do
      it "Then rejects command" $ do
        let account = regularAccountWithOwner testOwnerId
        let command =
              SetOverdraftLimitAccountCommand
                $ SetOverdraftLimit
                  { overdraftLimit = Just (mockMoneyWith EUR 500),
                    setBy = testOwnerId
                  }
        let result = handleAccountCommand account command
        result `shouldBe` Left CurrencyMismatch
