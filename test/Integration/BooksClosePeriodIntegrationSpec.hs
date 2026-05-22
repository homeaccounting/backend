{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Integration.BooksClosePeriodIntegrationSpec
-- Description : End-to-end HTTP coverage of the books-close cutoff + period gating.
--
-- Drives the @PUT \/api\/users\/me\/configuration\/books-close@ endpoint
-- together with the transaction creation and edit endpoints to verify
-- the period guard works through the full HTTP stack:
--
--   * advancing the cutoff is accepted, rewinding is rejected with
--     @CANNOT_REWIND_BOOKS_CLOSE@,
--   * creating a backdated transaction in a closed period is rejected
--     with @CANNOT_EDIT_CLOSED_PERIOD@,
--   * moving an existing TX's date into a closed period is rejected,
--   * description edits remain allowed on TX whose @at@ falls in the
--     closed period — only dates are gated per the spec.
--
-- See @docs\/plans\/2026-05-20-editable-transaction-metadata.md@ Task 10.
module Integration.BooksClosePeriodIntegrationSpec (spec) where

import Data.Aeson (eitherDecode, encode, object, (.=))
import qualified Data.ByteString.Lazy as LBS
import Data.Time (UTCTime)
import Domain.Core.Types
  ( unAccountId,
    unDictionaryEntryId,
  )
import Network.HTTP.Types (status200, status409)
import Network.Wai.Test (SResponse (..))
import RIO
import Test.Hspec
import Testkit.InMemoryEventStore (createTestAppEnvWithProcessManager)
import Testkit.Time (utc)
import Testkit.TransactionEditFixture
  ( Seed (..),
    authHeaders,
    httpRequest,
    mkSeed,
    seedToken,
    uuidText,
  )
import Web.API.ConfigurationAPI (ConfigurationResponse (..))
import Web.Types (ErrorResponse (..), TransactionResponse (..))

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------

booksClosePath :: ByteString
booksClosePath = "/api/users/me/configuration/books-close"

configPath :: ByteString
configPath = "/api/users/me/configuration"

decodeTx :: SResponse -> IO TransactionResponse
decodeTx resp = case eitherDecode (simpleBody resp) :: Either String TransactionResponse of
  Left err -> fail $ "expected TransactionResponse body, got: " <> err
  Right tr -> pure tr

decodeError :: SResponse -> IO ErrorResponse
decodeError resp = case eitherDecode (simpleBody resp) :: Either String ErrorResponse of
  Left err -> fail $ "expected ErrorResponse body, got: " <> err
  Right er -> pure er

decodeConfig :: SResponse -> IO ConfigurationResponse
decodeConfig resp = case eitherDecode (simpleBody resp) :: Either String ConfigurationResponse of
  Left err -> fail $ "expected ConfigurationResponse body, got: " <> err
  Right cfg -> pure cfg

incomeBody :: Seed -> Text -> UTCTime -> LBS.ByteString
incomeBody seed description at =
  encode
    $ object
      [ "accountId" .= uuidText (unAccountId seed.seedAccount),
        "amount" .= (25 :: Double),
        "currency" .= ("USD" :: Text),
        "category" .= uuidText (unDictionaryEntryId seed.seedCategory),
        "description" .= description,
        "date" .= at,
        "labels" .= ([] :: [Text])
      ]

closeBooks :: Seed -> Text -> UTCTime -> IO SResponse
closeBooks seed token at =
  httpRequest
    seed.seedApp
    "PUT"
    booksClosePath
    (authHeaders token)
    (encode $ object ["closedThrough" .= at])

freshSeed :: Text -> IO (Seed, Text)
freshSeed email = do
  seed <- mkSeed createTestAppEnvWithProcessManager email
  token <- seedToken seed
  pure (seed, token)

-- -----------------------------------------------------------------------------
-- Spec
-- -----------------------------------------------------------------------------

spec :: Spec
spec = describe "Integration / BooksClosePeriod" $ do
  it "PUT /books-close sets the cutoff and GET /configuration reflects it" $ do
    (seed, token) <- freshSeed "books-close-set@test.com"
    let cutoff = utc 2026 3 31
    putResp <- closeBooks seed token cutoff
    simpleStatus putResp `shouldBe` status200
    putCfg <- decodeConfig putResp
    putCfg.booksClosedThrough `shouldBe` Just cutoff

    getResp <- httpRequest seed.seedApp "GET" configPath (authHeaders token) ""
    simpleStatus getResp `shouldBe` status200
    getCfg <- decodeConfig getResp
    getCfg.booksClosedThrough `shouldBe` Just cutoff

  it "POST /income with a backdated 'at' in a closed period returns 409 CANNOT_EDIT_CLOSED_PERIOD" $ do
    (seed, token) <- freshSeed "books-close-create-backdated@test.com"
    closeResp <- closeBooks seed token (utc 2026 3 31)
    simpleStatus closeResp `shouldBe` status200

    resp <-
      httpRequest
        seed.seedApp
        "POST"
        "/api/transactions/income"
        (authHeaders token)
        (incomeBody seed "Backdated" (utc 2026 3 15))
    simpleStatus resp `shouldBe` status409
    err <- decodeError resp
    err.code `shouldBe` "CANNOT_EDIT_CLOSED_PERIOD"

  it "POST /income with an 'at' after the cutoff succeeds" $ do
    (seed, token) <- freshSeed "books-close-create-open@test.com"
    closeResp <- closeBooks seed token (utc 2026 3 31)
    simpleStatus closeResp `shouldBe` status200

    resp <-
      httpRequest
        seed.seedApp
        "POST"
        "/api/transactions/income"
        (authHeaders token)
        (incomeBody seed "Open period" (utc 2026 4 15))
    simpleStatus resp `shouldBe` status200
    tr <- decodeTx resp
    tr.description `shouldBe` "Open period"

  it "PUT /:id/date moving a TX into the closed period returns 409 CANNOT_EDIT_CLOSED_PERIOD" $ do
    (seed, token) <- freshSeed "books-close-date-into-closed@test.com"
    closeResp <- closeBooks seed token (utc 2026 3 31)
    simpleStatus closeResp `shouldBe` status200

    -- Seed a TX in the open period so the edit's current-date guard passes.
    createResp <-
      httpRequest
        seed.seedApp
        "POST"
        "/api/transactions/income"
        (authHeaders token)
        (incomeBody seed "Open" (utc 2026 4 15))
    simpleStatus createResp `shouldBe` status200
    created <- decodeTx createResp
    let path = encodeUtf8 $ "/api/transactions/" <> uuidText created.id

    resp <-
      httpRequest
        seed.seedApp
        "PUT"
        (path <> "/date")
        (authHeaders token)
        (encode $ object ["at" .= utc 2026 3 30])
    simpleStatus resp `shouldBe` status409
    err <- decodeError resp
    err.code `shouldBe` "CANNOT_EDIT_CLOSED_PERIOD"

  it "PUT /books-close with an earlier cutoff returns 409 CANNOT_REWIND_BOOKS_CLOSE" $ do
    (seed, token) <- freshSeed "books-close-rewind@test.com"
    firstResp <- closeBooks seed token (utc 2026 3 31)
    simpleStatus firstResp `shouldBe` status200

    rewindResp <- closeBooks seed token (utc 2026 2 28)
    simpleStatus rewindResp `shouldBe` status409
    err <- decodeError rewindResp
    err.code `shouldBe` "CANNOT_REWIND_BOOKS_CLOSE"

  it "PUT /books-close advancing the cutoff returns 200 and the new cutoff" $ do
    (seed, token) <- freshSeed "books-close-advance@test.com"
    firstResp <- closeBooks seed token (utc 2026 3 31)
    simpleStatus firstResp `shouldBe` status200

    let later = utc 2026 4 30
    advanceResp <- closeBooks seed token later
    simpleStatus advanceResp `shouldBe` status200
    cfg <- decodeConfig advanceResp
    cfg.booksClosedThrough `shouldBe` Just later

  it "PUT /:id/description succeeds even when the TX falls in the closed period" $ do
    -- Descriptions carry no period information and are intentionally not
    -- gated by books-close. Set up a TX dated 2026-04-15 in the open
    -- period, then advance the cutoff to 2026-04-30 so the TX is now
    -- inside the closed period, and confirm the description PUT still
    -- returns 200.
    (seed, token) <- freshSeed "books-close-description-after@test.com"

    createResp <-
      httpRequest
        seed.seedApp
        "POST"
        "/api/transactions/income"
        (authHeaders token)
        (incomeBody seed "Initial" (utc 2026 4 15))
    simpleStatus createResp `shouldBe` status200
    created <- decodeTx createResp
    let path = encodeUtf8 $ "/api/transactions/" <> uuidText created.id

    advanceResp <- closeBooks seed token (utc 2026 4 30)
    simpleStatus advanceResp `shouldBe` status200

    descResp <-
      httpRequest
        seed.seedApp
        "PUT"
        (path <> "/description")
        (authHeaders token)
        (encode $ object ["description" .= ("Edited after close" :: Text)])
    simpleStatus descResp `shouldBe` status200
    descTx <- decodeTx descResp
    descTx.description `shouldBe` "Edited after close"
