{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.ReadModels.PersistentUserReadModelSpec
-- Description : Guarantees of the persistent, indexed User read model.
--
-- Exercises the properties the @users@ / @user_oauth@ / @user_telegram@
-- projection exists to provide, seeding synthesized events through the read
-- model's own 'applyUserEvent' (no test-only insertion hole):
--
--   * __Indexed identity lookups__ — by id, email, Telegram id, and OAuth
--     (provider, subject), replacing the in-memory index maps.
--   * __Link / unlink__ — OAuth and Telegram identities are added and removed,
--     and reconstructed onto 'UserData'.
--   * __Multiple NULL emails coexist__ — Telegram-only users (no email) do not
--     collide on the unique email index.
--   * __Idempotency__ — re-applying the same event stream yields the same rows.
--   * __Version from the event__ — each row's @version@ is the event's real
--     per-stream 'EventVersion', not a value derived by incrementing.
module Application.ReadModels.PersistentUserReadModelSpec (spec) where

import Application.ReadModels.User
  ( UserData (..),
    applyUserEvent,
    countUsers,
    emailExists,
    getUser,
    getUserByEmail,
    getUserByOAuthIdentity,
    getUserByTelegramId,
    telegramIdLinked,
    userExists,
  )
import qualified Data.UUID as UUID
import Domain.Core.Types
  ( ConfigurationId,
    OAuthIdentity (..),
    OAuthProvider (..),
    TelegramIdentity (..),
    UserId,
    defaultConfigurationId,
    unUserId,
  )
import Domain.Models (AccountingEvent (..))
import Domain.User.Events
  ( OAuthAccountLinked (..),
    OAuthAccountUnlinked (..),
    PasswordChanged (..),
    TelegramAccountLinked (..),
    TelegramAccountUnlinked (..),
    UserConfigurationAssigned (..),
    UserRegistered (..),
    UserRegisteredViaTelegram (..),
  )
import qualified Eventium
import Infrastructure.App (AppEnv)
import RIO
import Test.Hspec
import Testkit.Helpers
  ( globalEvent,
    mockAccountId,
    mockConfigurationId,
    mockPasswordHash,
    mockTelegramId,
    mockUserId,
  )
import Testkit.InMemoryEventStore (runDbIn, seedGlobals)

-- -----------------------------------------------------------------------------
-- Fixtures
-- -----------------------------------------------------------------------------

user :: Word32 -> UserId
user n = mockUserId (UUID.fromWords n 0 0 0)

-- | 'globalEvent' on @uid@'s stream — the per-stream 'EventVersion' is recorded
-- as the row @version@.
userGlobal ::
  UserId ->
  Eventium.EventVersion ->
  AccountingEvent ->
  Eventium.SequenceNumber ->
  Eventium.GlobalStreamEvent AccountingEvent
userGlobal uid = globalEvent (unUserId uid)

registered :: UserId -> Text -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
registered uid email ver =
  userGlobal
    uid
    ver
    ( UserRegisteredEvent
        UserRegistered
          { email = email,
            passwordHash = mockPasswordHash "hash",
            externalAccountId = mockAccountId (UUID.fromWords 100 0 0 0)
          }
    )

tgIdentity :: Int64 -> TelegramIdentity
tgIdentity n = TelegramIdentity (mockTelegramId n) (Just "uname") "First"

registeredViaTelegram :: UserId -> Int64 -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
registeredViaTelegram uid tg ver =
  userGlobal
    uid
    ver
    ( UserRegisteredViaTelegramEvent
        UserRegisteredViaTelegram
          { identity = tgIdentity tg,
            externalAccountId = mockAccountId (UUID.fromWords 101 0 0 0)
          }
    )

oauthLinked :: UserId -> OAuthProvider -> Text -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
oauthLinked uid p s ver = userGlobal uid ver (OAuthAccountLinkedEvent (OAuthAccountLinked (OAuthIdentity p s)))

oauthUnlinked :: UserId -> OAuthProvider -> Text -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
oauthUnlinked uid p s ver = userGlobal uid ver (OAuthAccountUnlinkedEvent (OAuthAccountUnlinked (OAuthIdentity p s)))

tgLinked :: UserId -> Int64 -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
tgLinked uid tg ver = userGlobal uid ver (TelegramAccountLinkedEvent (TelegramAccountLinked (tgIdentity tg)))

tgUnlinked :: UserId -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
tgUnlinked uid ver = userGlobal uid ver (TelegramAccountUnlinkedEvent TelegramAccountUnlinked)

passwordChanged :: UserId -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
passwordChanged uid ver = userGlobal uid ver (PasswordChangedEvent (PasswordChanged (mockPasswordHash "h2")))

configAssigned :: UserId -> ConfigurationId -> Eventium.EventVersion -> Eventium.SequenceNumber -> Eventium.GlobalStreamEvent AccountingEvent
configAssigned uid cid ver = userGlobal uid ver (UserConfigurationAssignedEvent (UserConfigurationAssigned cid))

seedEnv :: [Eventium.GlobalStreamEvent AccountingEvent] -> IO AppEnv
seedEnv = seedGlobals applyUserEvent

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Persistent User read model" $ do
  describe "registration + identity lookups" $ do
    it "registers a user and finds it by id and email" $ do
      env <- seedEnv [registered (user 1) "alice@test.com" 0 0]
      byId <- runDbIn env (getUser (user 1))
      (.email) <$> byId `shouldBe` Just (Just "alice@test.com")
      (.hasPassword) <$> byId `shouldBe` Just True
      (.configurationId) <$> byId `shouldBe` Just defaultConfigurationId
      byEmail <- runDbIn env (getUserByEmail "alice@test.com")
      fst <$> byEmail `shouldBe` Just (user 1)
      runDbIn env (userExists (user 1)) `shouldReturn` True
      runDbIn env (emailExists "alice@test.com") `shouldReturn` True
      runDbIn env (emailExists "nobody@test.com") `shouldReturn` False

    it "records version from the event's per-stream EventVersion (no +1)" $ do
      env <- seedEnv [registered (user 1) "v@test.com" 0 0, passwordChanged (user 1) 1 1]
      v <- runDbIn env (fmap (fmap (.version)) (getUser (user 1)))
      v `shouldBe` Just 1

  describe "OAuth identities" $ do
    it "links, looks up, and unlinks OAuth identities" $ do
      env <-
        seedEnv
          [ registered (user 1) "o@test.com" 0 0,
            oauthLinked (user 1) Google "sub-g" 1 1,
            oauthLinked (user 1) GitHub "sub-h" 2 2
          ]
      byOAuth <- runDbIn env (getUserByOAuthIdentity Google "sub-g")
      fst <$> byOAuth `shouldBe` Just (user 1)
      ids <- runDbIn env (fmap (fmap (.oauthIdentities)) (getUser (user 1)))
      (length <$> ids) `shouldBe` Just 2

      envAfter <-
        seedEnv
          [ registered (user 1) "o@test.com" 0 0,
            oauthLinked (user 1) Google "sub-g" 1 1,
            oauthUnlinked (user 1) Google "sub-g" 2 2
          ]
      gone <- runDbIn envAfter (getUserByOAuthIdentity Google "sub-g")
      gone `shouldBe` Nothing

  describe "Telegram identities" $ do
    it "links, looks up by telegram id, and unlinks" $ do
      env <-
        seedEnv
          [ registered (user 1) "t@test.com" 0 0,
            tgLinked (user 1) 555 1 1
          ]
      byTg <- runDbIn env (getUserByTelegramId (mockTelegramId 555))
      fst <$> byTg `shouldBe` Just (user 1)
      runDbIn env (telegramIdLinked (mockTelegramId 555)) `shouldReturn` True
      ident <- runDbIn env (fmap (>>= (.telegramIdentity)) (getUser (user 1)))
      ((.firstName) <$> ident) `shouldBe` Just "First"

      envAfter <- seedEnv [registered (user 1) "t@test.com" 0 0, tgLinked (user 1) 555 1 1, tgUnlinked (user 1) 2 2]
      runDbIn envAfter (telegramIdLinked (mockTelegramId 555)) `shouldReturn` False

    it "Telegram-only users have no email and do not collide on the unique email index" $ do
      env <-
        seedEnv
          [ registeredViaTelegram (user 1) 111 0 0,
            registeredViaTelegram (user 2) 222 0 1
          ]
      u1 <- runDbIn env (getUser (user 1))
      u2 <- runDbIn env (getUser (user 2))
      (.email) <$> u1 `shouldBe` Just Nothing
      (.email) <$> u2 `shouldBe` Just Nothing
      (.hasPassword) <$> u1 `shouldBe` Just False
      a <- runDbIn env (getUserByTelegramId (mockTelegramId 111))
      b <- runDbIn env (getUserByTelegramId (mockTelegramId 222))
      fst <$> a `shouldBe` Just (user 1)
      fst <$> b `shouldBe` Just (user 2)

  describe "configuration assignment" $ do
    it "updates configurationId" $ do
      let cid = mockConfigurationId (UUID.fromWords 7 0 0 0)
      env <- seedEnv [registered (user 1) "c@test.com" 0 0, configAssigned (user 1) cid 1 1]
      c <- runDbIn env (fmap (fmap (.configurationId)) (getUser (user 1)))
      c `shouldBe` Just cid

  describe "idempotency (re-apply == apply once)" $ do
    it "re-applying the same stream leaves one user with the same identities" $ do
      let events =
            [ registered (user 1) "i@test.com" 0 0,
              oauthLinked (user 1) Google "sub-g" 1 1,
              tgLinked (user 1) 999 2 2
            ]
      env <- seedEnv (events <> events)
      u <- runDbIn env (getUser (user 1))
      length . (.oauthIdentities) <$> u `shouldBe` Just 1
      ((.firstName) <$> ((.telegramIdentity) =<< u)) `shouldBe` Just "First"

  describe "countUsers" $ do
    it "counts every registered user, both registration paths" $ do
      env <-
        seedEnv
          [ registered (user 1) "a@test.com" 0 0,
            registered (user 2) "b@test.com" 0 1,
            registeredViaTelegram (user 3) 777 0 2
          ]
      runDbIn env countUsers `shouldReturn` 3
