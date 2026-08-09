{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Domain.Banking.Signal
-- Description : Provider category/contact signals for the banking subdomain
--
-- Shared value types for the provider-supplied signals attached to imported
-- transactions: the merchant category code ('MCC'), the unified provider
-- category signal ('BankProviderCategory'), and the counterparty contact token
-- ('BankProviderContact'). These are also the map keys of the Configuration
-- category/contact maps.
--
-- There is __no Banking aggregate__: banking has no lifecycle of its own. The
-- category/contact maps are 'Domain.Configuration' events, and import
-- provenance carrying these signals rides on 'Domain.Transaction' events. These
-- are shared value types used across aggregates, so they live in a dedicated
-- value-type namespace (the same shape as "Domain.Core.Types") rather than in
-- an aggregate module.
module Domain.Banking.Signal
  ( -- * Merchant Category Code
    MCC,
    mkMcc,
    unsafeMcc,
    renderMcc,
    parseMcc,
    mccInt,

    -- * Provider category signal
    BankProviderCategory,
    mkByMcc,
    mkByLabel,
    mkByCounterparty,
    bankProviderCategory,
    bankProviderCategoryMcc,
    renderBankProviderCategoryKey,
    parseBankProviderCategoryKey,

    -- * Provider contact signal
    BankProviderContact,
    mkBankProviderContact,
    unsafeBankProviderContact,
    bankProviderContactText,
    renderBankProviderContactKey,
    parseBankProviderContactKey,
  )
where

import Data.Aeson (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..), object, withObject, withText, (.:), (.=))
import Data.Aeson.Types (FromJSONKeyFunction (FromJSONKeyTextParser), toJSONKeyText)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Domain.Core.Errors (DomainError (..), mkValidationError)
import GHC.Generics (Generic)
import RIO (Display (..))

-- -----------------------------------------------------------------------------
-- Merchant Category Code
-- -----------------------------------------------------------------------------

-- | ISO 18245 Merchant Category Code: a validated 4-digit numeric code in
-- the range @0..9999@.
--
-- On the wire and in storage an MCC is the zero-padded 4-digit text form
-- (e.g. @\"0742\"@, @\"5411\"@) via 'renderMcc' / 'parseMcc', so JSON and
-- persisted representations are unchanged from the earlier @type MCC = Text@.
newtype MCC = MCC Int
  deriving (Show, Eq, Ord, Generic)

-- | Extract the raw integer code from an 'MCC'.
mccInt :: MCC -> Int
mccInt (MCC n) = n

-- | Render an 'MCC' as its canonical zero-padded 4-digit text form.
renderMcc :: MCC -> Text
renderMcc (MCC n) = T.justifyRight 4 '0' (T.pack (show n))

-- | Smart constructor for an 'MCC'. Enforces @0 <= v && v <= 9999@.

{-@ mkMcc :: Int -> Either DomainError {v:MCC | 0 <= mccInt v && mccInt v <= 9999} @-}
mkMcc :: Int -> Either DomainError MCC
mkMcc n
  | n >= 0 && n <= 9999 = Right (MCC n)
  | otherwise =
      Left . ValidationErr $
        mkValidationError
          "mcc"
          "MCC must be a 4-digit code in the range 0..9999"
          (T.pack (show n))

-- | Construct an 'MCC' from a known-good literal, bypassing validation. For
-- test fixtures and compile-time constants only; mirrors
-- 'unsafeExternalTransactionId'.
unsafeMcc :: Int -> MCC
unsafeMcc = MCC

-- | Parse an 'MCC' from its text form (digits only). 'Nothing' on non-digit
-- input or an out-of-range value. Round-trips with 'renderMcc' for zero-padded
-- forms such as @\"0742\"@.
parseMcc :: Text -> Maybe MCC
parseMcc t = case TR.decimal t of
  Right (n, rest) | T.null rest -> either (const Nothing) Just (mkMcc (n :: Int))
  _ -> Nothing

instance ToJSON MCC where
  toJSON = toJSON . renderMcc

instance FromJSON MCC where
  parseJSON = withText "MCC" $ \t ->
    maybe (fail ("Invalid MCC: " <> T.unpack t)) pure (parseMcc t)

instance ToJSONKey MCC where
  toJSONKey = toJSONKeyText renderMcc

instance FromJSONKey MCC where
  fromJSONKey =
    FromJSONKeyTextParser $ \t ->
      maybe (fail ("Invalid MCC: " <> T.unpack t)) pure (parseMcc t)

instance Display MCC where
  display = display . renderMcc

-- -----------------------------------------------------------------------------
-- Provider category signal
-- -----------------------------------------------------------------------------

-- | A provider-supplied category signal attached to an imported transaction.
--
-- Bank providers surface a category hint in one of three mutually exclusive
-- forms: a numeric ISO 18245 merchant category code ('ByMcc', e.g. PrivatBank),
-- a free-text provider label ('ByLabel', e.g. Monzo/Monzo-style enum words
-- such as @\"eating_out\"@), or a universal counterparty token
-- ('ByCounterparty', an EDRPOU/IBAN/stable descriptor — the same signal used
-- for contact resolution). This type unifies them so downstream category
-- mapping can key on a single value.
--
-- The value JSON form is a tagged object
-- @{ \"kind\": \"mcc\" | \"label\" | \"counterparty\", \"value\": \<string\> }@
-- (the mcc value is the zero-padded 'renderMcc' text). The map-key JSON form is
-- the tagged text @\"mcc:0742\"@ / @\"label:eating_out\"@ /
-- @\"counterparty:12345678\"@ (split on the first @\':\'@ only, so values
-- containing colons survive).
data BankProviderCategory
  = ByMcc MCC
  | ByLabel Text
  | ByCounterparty Text -- universal counterparty token (EDRPOU / IBAN / stable descriptor)
  deriving (Eq, Ord, Show)

-- | Build a 'BankProviderCategory' from a validated merchant category code.
mkByMcc :: MCC -> BankProviderCategory
mkByMcc = ByMcc

-- | Smart constructor for a label-based 'BankProviderCategory'. Trims surrounding
-- whitespace and rejects an empty or blank label.
mkByLabel :: Text -> Maybe BankProviderCategory
mkByLabel t
  | T.null trimmed = Nothing
  | otherwise = Just (ByLabel trimmed)
  where
    trimmed = T.strip t

-- | Smart constructor for a counterparty-token 'BankProviderCategory'. Trims and
-- rejects blank. The token is the same universal counterparty signal used for
-- contact resolution (an EDRPOU/IBAN); it is persisted verbatim.
mkByCounterparty :: Text -> Maybe BankProviderCategory
mkByCounterparty t
  | T.null trimmed = Nothing
  | otherwise = Just (ByCounterparty trimmed)
  where
    trimmed = T.strip t

-- | Fold over the cases of a 'BankProviderCategory'.
bankProviderCategory :: (MCC -> a) -> (Text -> a) -> (Text -> a) -> BankProviderCategory -> a
bankProviderCategory onMcc _ _ (ByMcc m) = onMcc m
bankProviderCategory _ onLabel _ (ByLabel t) = onLabel t
bankProviderCategory _ _ onCounterparty (ByCounterparty t) = onCounterparty t

-- | Extract the merchant category code, if this is an mcc-based category.
bankProviderCategoryMcc :: BankProviderCategory -> Maybe MCC
bankProviderCategoryMcc = bankProviderCategory Just (const Nothing) (const Nothing)

-- | Tagged text key form: @\"mcc:0742\"@ / @\"label:eating_out\"@ /
-- @\"counterparty:12345678\"@.
renderBankProviderCategoryKey :: BankProviderCategory -> Text
renderBankProviderCategoryKey =
  bankProviderCategory
    (\m -> "mcc:" <> renderMcc m)
    ("label:" <>)
    ("counterparty:" <>)

-- | Parse the tagged text key form, splitting on the first @\':\'@ only so that
-- labels containing colons round-trip.
parseBankProviderCategoryKey :: Text -> Maybe BankProviderCategory
parseBankProviderCategoryKey t =
  case T.stripPrefix ":" rest of
    Just suffix -> case prefix of
      "mcc" -> mkByMcc <$> parseMcc suffix
      "label" -> mkByLabel suffix
      "counterparty" -> mkByCounterparty suffix
      _ -> Nothing
    Nothing -> Nothing
  where
    (prefix, rest) = T.breakOn ":" t

instance ToJSON BankProviderCategory where
  toJSON =
    bankProviderCategory
      (\m -> object ["kind" .= ("mcc" :: Text), "value" .= renderMcc m])
      (\t -> object ["kind" .= ("label" :: Text), "value" .= t])
      (\t -> object ["kind" .= ("counterparty" :: Text), "value" .= t])

instance FromJSON BankProviderCategory where
  parseJSON = withObject "BankProviderCategory" $ \o -> do
    kind <- o .: "kind"
    value <- o .: "value"
    case kind :: Text of
      "mcc" ->
        maybe
          (fail ("Invalid BankProviderCategory mcc value: " <> T.unpack value))
          (pure . mkByMcc)
          (parseMcc value)
      "label" ->
        maybe
          (fail "BankProviderCategory label must not be blank")
          pure
          (mkByLabel value)
      "counterparty" ->
        maybe
          (fail "BankProviderCategory counterparty must not be blank")
          pure
          (mkByCounterparty value)
      other -> fail ("Unknown BankProviderCategory kind: " <> T.unpack other)

instance ToJSONKey BankProviderCategory where
  toJSONKey = toJSONKeyText renderBankProviderCategoryKey

instance FromJSONKey BankProviderCategory where
  fromJSONKey =
    FromJSONKeyTextParser $ \t ->
      maybe
        (fail ("Invalid BankProviderCategory key: " <> T.unpack t))
        pure
        (parseBankProviderCategoryKey t)

-- -----------------------------------------------------------------------------
-- Provider contact signal
-- -----------------------------------------------------------------------------

-- | The name-agnostic token a provider reports to identify a transaction's
-- counterparty (a merchant/counterparty descriptor as the provider reports it,
-- e.g. @MagazinREMONTI@ / @Магазин РЕМОНТІ@, or a more stable id such as a
-- counterparty IBAN / EDRPOU where a provider exposes one). Persisted verbatim;
-- the key of the user contact map ('contactMap').
--
-- Universal keyspace (not provider-scoped): the map is many-to-one, so token
-- collisions are harmless — colliding tokens simply point at the same contact.
-- JSON value form is the plain trimmed string; the map-key form is the same
-- token verbatim.
newtype BankProviderContact = BankProviderContact Text
  deriving (Eq, Ord, Show)

-- | Smart constructor: trims surrounding whitespace and rejects a blank token.
mkBankProviderContact :: Text -> Maybe BankProviderContact
mkBankProviderContact t
  | T.null trimmed = Nothing
  | otherwise = Just (BankProviderContact trimmed)
  where
    trimmed = T.strip t

-- | Bypass validation. For known-good literals / tests / wiring only.
unsafeBankProviderContact :: Text -> BankProviderContact
unsafeBankProviderContact = BankProviderContact

-- | The underlying token.
bankProviderContactText :: BankProviderContact -> Text
bankProviderContactText (BankProviderContact t) = t

-- | Map-key text form. Single case → the token itself.
renderBankProviderContactKey :: BankProviderContact -> Text
renderBankProviderContactKey = bankProviderContactText

-- | Parse the map-key text form, re-validating non-blank.
parseBankProviderContactKey :: Text -> Maybe BankProviderContact
parseBankProviderContactKey = mkBankProviderContact

instance ToJSON BankProviderContact where
  toJSON = toJSON . bankProviderContactText

instance FromJSON BankProviderContact where
  parseJSON = withText "BankProviderContact" $ \t ->
    maybe (fail "BankProviderContact must not be blank") pure (mkBankProviderContact t)

instance ToJSONKey BankProviderContact where
  toJSONKey = toJSONKeyText renderBankProviderContactKey

instance FromJSONKey BankProviderContact where
  fromJSONKey =
    FromJSONKeyTextParser $ \t ->
      maybe (fail ("Invalid BankProviderContact key: " <> T.unpack t)) pure (parseBankProviderContactKey t)
