{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- |
-- Module      : Application.Services.Prompt.Transaction.Intent
-- Description : The @record_transactions@ intent: per-transaction payload type,
--               list decoder, JSON-schema fragment, and multilingual prompt guide.
--
-- This is the parsed shape of external LLM output for the @record_transactions@
-- intent plus the prompt text that instructs the model how to produce it. It is
-- an __application__ concern (parsed external output + prompt text), not domain.
--
-- The module owns everything specific to this one intent:
--
--   * 'TransactionIntent' — the flat per-transaction payload the model returns
--     for one list element (@kind@ is the sub-classification within it);
--   * 'parseTransactionFields' — the reusable per-element Aeson parser;
--   * 'parseRecordTransactionsFields' — the list parser the generic
--     envelope/router calls after it has read the envelope @intent@ field
--     (it reads only the @transactions@ array and __ignores__ @intent@);
--   * 'decodeTransactionIntent' / 'decodeRecordTransactions' — standalone
--     convenience wrappers for tests and isolated reuse;
--   * 'recordTransactionsSchema' — the JSON-schema fragment sent as @response_format@;
--   * 'recordTransactionsGuide' — the guide fragment (schema + the user's real
--     names + multilingual instruction + few-shot examples).
module Application.Services.Prompt.Transaction.Intent
  ( IntentKind (..),
    IntentAllocation (..),
    TransactionIntent (..),
    TransactionDecodeError (..),
    parseTransactionFields,
    parseRecordTransactionsFields,
    decodeTransactionIntent,
    decodeRecordTransactions,
    recordTransactionsSchema,
    recordTransactionsIntentName,
    PromptContext (..),
    recordTransactionsGuide,
  )
where

import Data.Aeson (Object, Value, object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (Parser, parseEither)
import RIO
import qualified RIO.ByteString.Lazy as BL
import qualified RIO.Text as T

-- | The name of this intent, used as the envelope @intent@ discriminator.
recordTransactionsIntentName :: Text
recordTransactionsIntentName = "record_transactions"

-- | One @transactions@ element the model returned that failed to decode.
--
-- Prompt-local and intentionally minimal: it carries only the reason. Its
-- position in the list is the transaction's @index@ (the same zero-based
-- position 'Application.Services.Prompt.Types.FailedTransaction' /
-- 'Application.Services.Prompt.Types.RecordedTransaction' carry), assigned by
-- the consumer's enumeration — so the type needs no index of its own.
--
-- Deliberately NOT the bank statement-import 'RowError': there a file "row" is
-- one transaction, but a prompt transaction spans multiple allocation lines, so
-- "row"/"line" would be the wrong word for a whole-transaction decode failure.
newtype TransactionDecodeError = TransactionDecodeError Text
  deriving (Show, Eq)

-- | The kind of one transaction in the list (income, expense, or transfer).
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

-- | One transaction element of the @record_transactions@ payload. Names and
-- amounts are text (in any language); deterministic code resolves them later.
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

-- | Parse the @record_transactions@ payload: a required @transactions@ array,
-- each element the existing per-transaction shape ('parseTransactionFields').
--
-- This is the reusable parser the generic envelope/router calls __after__ it
-- has read the envelope's @intent@ field; it reads only @transactions@ and
-- deliberately __ignores__ @intent@.
--
-- The parse is __per-element tolerant__: an absent or non-array @transactions@
-- is a structural failure of the whole parse (surfacing as a malformed
-- envelope), but a single element that does not decode becomes a
-- 'Left' 'RowError' at its position rather than failing the batch — the good
-- elements still decode. This lets the router commit the well-formed
-- transactions and report the malformed ones individually.
parseRecordTransactionsFields :: Object -> Parser [Either TransactionDecodeError TransactionIntent]
parseRecordTransactionsFields o = do
  els <- o .: "transactions"
  pure (map decodeElem els)
  where
    decodeElem v =
      case parseEither (withObject "TransactionIntent" parseTransactionFields) v of
        Left err -> Left (TransactionDecodeError (T.pack err))
        Right ti -> Right ti

-- | Standalone convenience decoder for tests and isolated reuse: decode a JSON
-- byte string straight into the @transactions@ list, skipping the generic
-- envelope. The real request path runs through
-- 'Application.Services.Prompt.Types.decodePromptIntent'.
decodeRecordTransactions :: BL.ByteString -> Either Text [Either TransactionDecodeError TransactionIntent]
decodeRecordTransactions bs = case Aeson.eitherDecode bs of
  Left e -> Left ("intent: invalid JSON: " <> T.pack e)
  Right v -> first T.pack (parseEither (withObject "RecordTransactions" parseRecordTransactionsFields) v)

-- | The JSON-schema fragment describing the @record_transactions@ envelope
-- (@intent@ fixed to @record_transactions@, plus a @transactions@ array of the
-- per-transaction shape).
--
-- Kept as documentation of the wire shape and for a future @json_schema@
-- @response_format@; the live request path deliberately sends @json_object@
-- instead (see 'Application.Services.PromptService'), because many
-- OpenAI-compatible providers reject @json_schema@ outright and the shape is
-- already fully described in 'recordTransactionsGuide'. Not currently sent.
recordTransactionsSchema :: Value
recordTransactionsSchema =
  object
    [ "name" .= recordTransactionsIntentName,
      "schema"
        .= object
          [ "type" .= ("object" :: Text),
            "required" .= (["intent", "transactions"] :: [Text]),
            "properties"
              .= object
                [ "intent"
                    .= object
                      [ "type" .= ("string" :: Text),
                        "const" .= recordTransactionsIntentName,
                        "enum" .= ([recordTransactionsIntentName] :: [Text])
                      ],
                  "transactions"
                    .= object
                      [ "type" .= ("array" :: Text),
                        "items" .= transactionObject
                      ]
                ]
          ]
    ]
  where
    strType = object ["type" .= ("string" :: Text)]
    nullableStr = object ["type" .= (["string", "null"] :: [Text])]
    -- The per-transaction element shape (no @intent@ — that is envelope-level).
    transactionObject =
      object
        [ "type" .= ("object" :: Text),
          "required" .= (["kind"] :: [Text]),
          "properties"
            .= object
              [ "kind" .= object ["type" .= ("string" :: Text), "enum" .= (["income", "expense", "transfer"] :: [Text])],
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

-- | Context describing the user's real accounts, categories, and labels,
-- embedded verbatim in the prompt so the model chooses from real values.
data PromptContext = PromptContext
  { accountNames :: ![Text],
    incomeCategoryNames :: ![Text],
    expenseCategoryNames :: ![Text],
    labelNames :: ![Text]
  }
  deriving (Show, Eq)

-- | The @record_transactions@ guide fragment: frames the top-level
-- @{intent, transactions:[...]}@ envelope, states the split-vs-distinct rule
-- (separate list elements = distinct transactions; allocations = split one
-- payment across categories), describes each per-transaction key, embeds the
-- user's real account and category names, states the multilingual "map to the
-- exact names, echo verbatim" instruction, and gives contrasting few-shot
-- examples (single, split-payment, multi, and a Ukrainian case). Pure function
-- of 'PromptContext' — today's date and the user's message are added by the
-- generic Builder/router, not here.
recordTransactionsGuide :: PromptContext -> Text
recordTransactionsGuide ctx =
  T.unlines
    [ "Intent \"" <> recordTransactionsIntentName <> "\": record ONE OR MORE personal-finance transactions from the message.",
      "",
      "Return a JSON object: {\"intent\":\"" <> recordTransactionsIntentName <> "\",\"transactions\":[ <transaction>, ... ]}",
      "Emit ONE list element per DISTINCT transaction. A distinct transaction has",
      "its own kind, account(s), currency, and date. Do NOT decide whether the",
      "message is \"one\" or \"many\" — just list every transaction you find (a single",
      "capture is a list of one).",
      "",
      "Use ALLOCATIONS (within a single transaction) ONLY to split ONE payment",
      "across categories — same account, same kind, same date. Use SEPARATE list",
      "elements for transactions that differ in account, kind, or date (allocations",
      "cannot represent those).",
      "",
      "Each <transaction> has these keys:",
      "  kind: \"income\" | \"expense\" | \"transfer\"",
      "  amount: transfer ONLY — the decimal total as a string, using '.' as the",
      "    decimal separator. Leave null for income/expense (use allocations).",
      "  allocations: income/expense ONLY — an array of line items, one per split",
      "    part, each {\"amount\", \"category\", \"comment\"} where:",
      "      amount: that line's decimal as a string ('.' decimal separator)",
      "      category: the matching category name below, or null (system default)",
      "      comment: the specific item(s) or purpose from that line — the goods",
      "        bought or the reason — with the amount, currency, and account words",
      "        REMOVED. E.g. 'cash milk 120 uah' -> comment \"milk\". Use null when",
      "        the line names nothing beyond the category itself.",
      "  currency: one of UAH,USD,EUR,GBP or null",
      "  sourceAccount: the account money leaves; null when it comes from outside (income)",
      "  targetAccount: the account money enters; null when it goes outside (expense)",
      "  description: a SHORT summary of this transaction — the items across all its",
      "    allocations together (e.g. their names joined), in the user's language; or",
      "    null to let the system summarise the lines.",
      "  date: absolute ISO YYYY-MM-DD (resolve 'yesterday' etc. using today's date), or null",
      "",
      "sourceAccount = the account money leaves; targetAccount = the account money",
      "enters. For expense, sourceAccount is the user's account and targetAccount is",
      "null; for income, targetAccount is the user's account and sourceAccount is",
      "null; for transfer, sourceAccount is the from-account and targetAccount the to.",
      "",
      "The user may write in ANY language.",
      "",
      "Categories: map the user's words to exactly one of the category names listed",
      "below and return that name VERBATIM. If nothing fits, use null (the system",
      "picks the default category).",
      "",
      "sourceAccount / targetAccount: output ONE of —",
      "  * the exact name of a listed account, when the user clearly names one;",
      "  * else, when the user refers to a KIND of account in ANY language, the",
      "    English type word \"cash\", \"card\", \"bank\", or \"wallet\" (e.g. Ukrainian",
      "    готівка->\"cash\", карта->\"card\"; Spanish efectivo->\"cash\"). The system maps",
      "    the type to the user's default account of that kind;",
      "  * else null — the system uses the user's default account.",
      "NEVER echo the user's own word for an account or invent a name: use a listed",
      "name, one of those four type words, or null.",
      "",
      "Accounts: " <> commas ctx.accountNames,
      "Income categories: " <> commas ctx.incomeCategoryNames,
      "Expense categories: " <> commas ctx.expenseCategoryNames,
      labelsLine ctx.labelNames,
      "",
      "Examples (comment carries only the item, not the amount/account; the",
      "category values below are drawn from YOUR listed categories) ->",
      "  'cash 123 food' (one transaction) ->",
      "    {\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"123\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":null}],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null}]}",
      "  'ATB: milk 20, bread 15' (ONE payment split across categories -> one transaction, two allocations) ->",
      "    {\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"20\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"milk\"},{\"amount\":\"15\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"bread\"}],\"currency\":null,\"sourceAccount\":\"ATB\",\"targetAccount\":null,\"description\":null,\"date\":null}]}",
      "  'salary 5000 to bank, coffee 45 cash, taxi 120 cash' (THREE distinct transactions) ->",
      "    {\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"income\",\"amount\":null,\"allocations\":[{\"amount\":\"5000\"," <> quotedCategory exampleIncomeCat <> ",\"comment\":null}],\"currency\":null,\"sourceAccount\":null,\"targetAccount\":\"Bank\",\"description\":null,\"date\":null},{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"45\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"coffee\"}],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null},{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"120\",\"category\":null,\"comment\":\"taxi\"}],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":null,\"description\":null,\"date\":null}]}",
      "  'move 200 from cash to card' (one transfer) ->",
      "    {\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"transfer\",\"amount\":\"200\",\"allocations\":[],\"currency\":null,\"sourceAccount\":\"Cash\",\"targetAccount\":\"Card\",\"description\":null,\"date\":null}]}",
      "  Ukrainian 'готівка 123 їжа' (one transaction; готівка is the CASH type) ->",
      "    {\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"123\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":null}],\"currency\":null,\"sourceAccount\":\"cash\",\"targetAccount\":null,\"description\":null,\"date\":null}]}",
      "  Ukrainian 'готівка 400 молоко, 50 банани; карта 33 кава, 55 хліб'",
      "  (TWO transactions — a cash-type line and a card-type line, each split across items) ->",
      "    {\"intent\":\"record_transactions\",\"transactions\":[{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"400\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"молоко\"},{\"amount\":\"50\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"банани\"}],\"currency\":null,\"sourceAccount\":\"cash\",\"targetAccount\":null,\"description\":null,\"date\":null},{\"kind\":\"expense\",\"amount\":null,\"allocations\":[{\"amount\":\"33\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"кава\"},{\"amount\":\"55\"," <> quotedCategory exampleExpenseCat <> ",\"comment\":\"хліб\"}],\"currency\":null,\"sourceAccount\":\"card\",\"targetAccount\":null,\"description\":null,\"date\":null}]}",
      "",
      "Output only JSON."
    ]
  where
    commas = T.intercalate ", "
    labelsLine [] = "Labels: (none)"
    labelsLine ls = "Labels: " <> commas ls
    -- Few-shot examples must reference categories the user actually has, or the
    -- model imitates a spelling its dictionary lacks and the matcher (no
    -- cross-lingual mapping) silently drops it to the default category — the
    -- localization regression this closes. Draw them from the (already
    -- localized) context, falling back to the English canonical names only when
    -- the user has no categories of that kind.
    exampleExpenseCat = firstOr "Food / Groceries" ctx.expenseCategoryNames
    exampleIncomeCat = firstOr "Salary" ctx.incomeCategoryNames
    firstOr d xs = case xs of
      (x : _) -> x
      [] -> d
    quotedCategory c = "\"category\":\"" <> c <> "\""
