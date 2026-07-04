{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Transaction.Intent
-- Description : The @transaction@ intent: payload type, decoder,
--               JSON-schema fragment, and multilingual prompt guide.
--
-- This is the parsed shape of external LLM output for the @transaction@
-- intent plus the prompt text that instructs the model how to produce it. It is
-- an __application__ concern (parsed external output + prompt text), not domain.
--
-- The module owns everything specific to this one intent:
--
--   * 'TransactionIntent' — the flat payload the model returns
--     (@kind@ is the sub-classification /within/ @transaction@);
--   * 'parseTransactionFields' — the reusable Aeson parser the generic
--     envelope/router calls after it has read the envelope @intent@ field
--     (it reads only the transaction fields and __ignores__ @intent@);
--   * 'decodeTransactionIntent' — a standalone convenience wrapper for tests
--     and isolated reuse;
--   * 'transactionSchema' — the JSON-schema fragment sent as @response_format@;
--   * 'transactionGuide' — the transaction guide fragment (schema +
--     the user's real names + multilingual instruction + few-shot examples).
module Application.Services.Prompt.Transaction.Intent
  ( IntentKind (..),
    IntentAllocation (..),
    TransactionIntent (..),
    parseTransactionFields,
    decodeTransactionIntent,
    transactionSchema,
    transactionIntentName,
    PromptContext (..),
    transactionGuide,
  )
where

import Data.Aeson (Object, Value, object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser, parseEither)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

-- | The name of this intent, used as the envelope @intent@ discriminator.
transactionIntentName :: Text
transactionIntentName = "transaction"

-- | The sub-classification within @transaction@.
data IntentKind = IncomeKind | ExpenseKind | TransferKind
  deriving (Show, Eq)

-- | One line item the model returns for income/expense: an amount (text,
-- any decimal separator), an optional category name, and the original
-- source line as a free-text comment.
data IntentAllocation = IntentAllocation
  { amount :: !Text,
    category :: !(Maybe Text),
    comment :: !(Maybe Text)
  }
  deriving (Show, Eq)

-- | The payload the model returns for @transaction@. Names and amounts are
-- text (in any language); deterministic code resolves them later.
data TransactionIntent = TransactionIntent
  { kind :: !IntentKind,
    -- | Transfer total. Income/expense derive their total from 'allocations';
    -- stays 'Nothing' for them.
    amount :: !(Maybe Text),
    -- | Line items for income/expense (empty for transfer).
    allocations :: ![IntentAllocation],
    currency :: !(Maybe Text),
    sourceAccount :: !(Maybe Text),
    targetAccount :: !(Maybe Text),
    description :: !(Maybe Text),
    date :: !(Maybe Text)
  }
  deriving (Show, Eq)

parseKind :: Text -> Parser IntentKind
parseKind t = case T.toLower t of
  "income" -> pure IncomeKind
  "expense" -> pure ExpenseKind
  "transfer" -> pure TransferKind
  other -> fail ("unknown kind: " <> T.unpack other)

-- | Parse a single line item out of a JSON object.
parseAllocation :: Value -> Parser IntentAllocation
parseAllocation = withObject "IntentAllocation" $ \o ->
  IntentAllocation
    <$> o
    .: "amount"
    <*> o
    .:? "category"
    <*> o
    .:? "comment"

-- | Parse the @transaction@ fields out of a JSON object.
--
-- This is the reusable parser the generic envelope/router calls __after__ it
-- has read the envelope's @intent@ field; it reads only the transaction fields
-- and deliberately __ignores__ @intent@. Only @kind@ is required; the transfer
-- total lives in @amount@ while income/expense line items live in
-- @allocations@; all other fields are optional.
parseTransactionFields :: Object -> Parser TransactionIntent
parseTransactionFields o =
  TransactionIntent
    <$> (o .: "kind" >>= parseKind)
    <*> o
    .:? "amount"
    <*> (fromMaybe [] <$> parseAllocs)
    <*> o
    .:? "currency"
    <*> o
    .:? "sourceAccount"
    <*> o
    .:? "targetAccount"
    <*> o
    .:? "description"
    <*> o
    .:? "date"
  where
    -- o .:? "allocations" :: Parser (Maybe [Value]); outer traverse handles the absent key (→ []), inner parses each element.
    parseAllocs = o .:? "allocations" >>= traverse (traverse parseAllocation)

-- | Standalone convenience decoder for tests and isolated reuse: decode a JSON
-- byte string straight into a 'TransactionIntent'. The real request path runs
-- through the generic envelope, which reads @intent@ then calls
-- 'parseTransactionFields'; this wrapper skips the envelope so the transaction
-- decoder can be unit-tested on its own.
decodeTransactionIntent :: BL.ByteString -> Either Text TransactionIntent
decodeTransactionIntent bs = case Aeson.eitherDecode bs of
  Left e -> Left ("intent: invalid JSON: " <> T.pack e)
  Right v -> first T.pack (parseEither (withObject "TransactionIntent" parseTransactionFields) v)

-- | The JSON-schema fragment for the @transaction@ fields, sent as
-- @response_format.json_schema@ (best-effort; servers that ignore it still get
-- the shape from the prompt text). The @intent@ property is fixed to
-- @transaction@.
transactionSchema :: Value
transactionSchema =
  object
    [ "name" .= transactionIntentName,
      "schema"
        .= object
          [ "type" .= ("object" :: Text),
            "required" .= (["intent", "kind"] :: [Text]),
            "properties"
              .= object
                [ "intent"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "const" .= transactionIntentName,
                        "enum" .= ([transactionIntentName] :: [Text])
                      ],
                  "kind" .= object ["type" .= ("string" :: Text), "enum" .= (["income", "expense", "transfer"] :: [Text])],
                  "amount" .= nullableStr,
                  "allocations"
                    .= object
                      [ "type" .= ("array" :: Text),
                        "items"
                          .= object
                            [ "type" .= ("object" :: Text),
                              "required" .= (["amount"] :: [Text]),
                              "properties"
                                .= object
                                  [ "amount" .= strType,
                                    "category" .= nullableStr,
                                    "comment" .= nullableStr
                                  ]
                            ]
                      ],
                  "currency" .= nullableStr,
                  "sourceAccount" .= nullableStr,
                  "targetAccount" .= nullableStr,
                  "description" .= nullableStr,
                  "date" .= nullableStr
                ]
          ]
    ]
  where
    strType = object ["type" .= ("string" :: Text)]
    nullableStr = object ["type" .= (["string", "null"] :: [Text])]

-- | Context describing the user's real accounts, categories, and labels,
-- embedded verbatim in the prompt so the model chooses from real values.
data PromptContext = PromptContext
  { accountNames :: ![Text],
    incomeCategoryNames :: ![Text],
    expenseCategoryNames :: ![Text],
    labelNames :: ![Text]
  }
  deriving (Show, Eq)

-- | The @transaction@ guide fragment: describes the required JSON keys
-- (including the @intent@ discriminator), embeds the user's real account and
-- category names, states the multilingual "map to the exact names, echo
-- verbatim" instruction, and gives a few-shot examples set (including a
-- Ukrainian case). Pure function of 'PromptContext' — today's date and the
-- user's message are added by the generic Builder/router, not here.
transactionGuide :: PromptContext -> Text
transactionGuide ctx =
  T.unlines
    [ "Intent \"" <> transactionIntentName <> "\": record a single personal-finance transaction.",
      "",
      "Return a JSON object with these keys:",
      "  intent: always \"" <> transactionIntentName <> "\"",
      "  kind: \"income\" | \"expense\" | \"transfer\"",
      "  amount: transfer ONLY — the decimal total as a string, using '.' as the",
      "    decimal separator. Leave null for income/expense (use allocations).",
      "  allocations: income/expense ONLY — an array of line items, one per input",
      "    line, each {\"amount\", \"category\", \"comment\"} where:",
      "      amount: that line's decimal as a string ('.' decimal separator)",
      "      category: the matching category name below, or null (system default)",
      "      comment: the specific item(s) or purpose from that line — the goods",
      "        bought or the reason — with the amount, currency, and account words",
      "        REMOVED. E.g. 'cash milk 120 uah' -> comment \"milk\". Use null when",
      "        the line names nothing beyond the category itself.",
      "  currency: one of UAH,USD,EUR,GBP or null",
      "  sourceAccount: the account money leaves; null when it comes from outside (income)",
      "  targetAccount: the account money enters; null when it goes outside (expense)",
      "  description: a SHORT summary of the whole transaction — the items across all",
      "    allocations together (e.g. their names joined), in the user's language; or",
      "    null to let the system summarise the lines.",
      "  date: absolute ISO YYYY-MM-DD (resolve 'yesterday' etc. using today's date), or null",
      "",
      "sourceAccount = the account money leaves; targetAccount = the account money",
      "enters. For expense, sourceAccount is the user's account and targetAccount is",
      "null; for income, targetAccount is the user's account and sourceAccount is",
      "null; for transfer, sourceAccount is the from-account and targetAccount the to.",
      "",
      "For a multi-line expense/income, produce ONE allocation per line; set that",
      "line's comment to the item/purpose it describes (goods bought, reason),",
      "stripped of the amount, currency, and account words — NOT the raw line. The",
      "total is the sum of the line amounts (do NOT output a top-level amount for",
      "income/expense).",
      "",
      "The user may write in ANY language. Map their words to exactly one of the",
      "names listed below and return that name VERBATIM as shown. If nothing fits a",
      "category, use null (the system will pick a default).",
      "",
      "Accounts: " <> commas ctx.accountNames,
      "Income categories: " <> commas ctx.incomeCategoryNames,
      "Expense categories: " <> commas ctx.expenseCategoryNames,
      labelsLine ctx.labelNames,
      "",
      "Examples (note how comment carries only the item, not the amount/account):",
      "  'cash milk 120 uah' -> {\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"120\",\"category\":\"Food\",\"comment\":\"milk\"}],\"currency\":\"UAH\",\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null}",
      "  'cash 123 food' -> {\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null}",
      "  'salary 5000 to bank' -> {\"intent\":\"transaction\",\"kind\":\"income\",\"amount\":null,\"allocations\":[{\"amount\":\"5000\",\"category\":\"Salary\",\"comment\":null}],\"currency\":null,\"sourceAccount\":null,\"targetAccount\":\"Bank\",\"description\":null,\"date\":null}",
      "  'move 200 from cash to card' -> {\"intent\":\"transaction\",\"kind\":\"transfer\",\"amount\":\"200\",\"allocations\":[],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\",\"description\":null,\"date\":null}",
      "  'готівка 123 їжа' -> {\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"123\",\"category\":\"Food\",\"comment\":null}],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null}",
      "  multi-line 'огірки розсада 200\\nквіти 700\\nяйця 200\\nовочі 500\\nогірки зелень 160' ->",
      "    {\"intent\":\"transaction\",\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"огірки розсада\"},{\"amount\":\"700\",\"category\":null,\"comment\":\"квіти\"},{\"amount\":\"200\",\"category\":\"Food\",\"comment\":\"яйця\"},{\"amount\":\"500\",\"category\":\"Food\",\"comment\":\"овочі\"},{\"amount\":\"160\",\"category\":\"Food\",\"comment\":\"огірки зелень\"}],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":\"огірки розсада, квіти, яйця, овочі, огірки зелень\",\"date\":null}",
      "",
      "Output only JSON."
    ]
  where
    commas = T.intercalate ", "
    labelsLine [] = "Labels: (none)"
    labelsLine ls = "Labels: " <> commas ls
