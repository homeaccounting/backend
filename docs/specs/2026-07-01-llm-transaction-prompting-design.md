---
status: draft
date: 2026-07-01
issue: homeaccounting/backend#86
---

# LLM Transaction Prompting (backend)

## Problem

Creating a transaction today requires a structured request: the client must
know account UUIDs, category dictionary UUIDs, currency, and the correct
endpoint (`/api/transactions/{income,expense,transfer}`). That is fine for a
form-driven UI but hostile to fast capture. The product goal (issue #86) is:

> As a User I want to send a text prompt to the API which is parsed by an LLM;
> the result is a new transaction. Example: `cash 123 food` → an expense from
> the Cash account in category Food.

The backend has no natural-language entry point. We want one that is:

- **Free to run** — the product is free of charge, so no paid per-token API.
  We target free open-weights models (see below).
- **Safe** — a weak open model must not be able to commit garbage; every field
  is validated through the existing domain smart constructors before anything
  is written.
- **Client-agnostic** — the web app, Telegram bot, and future mobile client all
  reach it over one REST call.

## Goals

1. Add a single authenticated endpoint `POST /api/prompt` that turns free text
   into a committed income / expense / transfer transaction.
2. Use a **free, open-weights model** through an **OpenAI-compatible
   `/chat/completions`** interface, with base URL / model / key entirely in
   config (works unchanged with Ollama, vLLM, llama.cpp, LM Studio, or a free
   hosted tier).
3. Keep the model's job to **extraction only**; do all **resolution**
   (name → `AccountId` / `CategoryId`, currency, amount, date) in deterministic,
   testable code against the user's real accounts and category dictionary.
4. Reuse the existing `TransactionService` write path and all its validation —
   no new events, no new commands, no new write-side invariants.
5. Build the pipeline around an **intent architecture** (§2a): the endpoint is a
   general assistant entry point and `create_transaction` is the first intent.
   Adding future intents (reports, account ops) must be **additive and
   compiler-guided**, with no new endpoint or client-facing URL rename. Only
   `create_transaction` is implemented now (seams, not speculative intents).
6. Support **multilingual prompts** (e.g. Ukrainian text against English account
   / category names) — the model maps the user's words to the user's canonical
   names; deterministic resolution stays exact-match.

## Non-Goals

- **Report / query intents** ("how much on food last month"). Deferred to a
  follow-up; the response union reserves a `report` variant for it.
- **MCP server.** Deferred; `PromptService` is factored so an MCP
  adapter or Telegram free-text handler can reuse it later.
- **Propose-then-confirm / conversational multi-turn.** The endpoint
  auto-commits in one shot (or returns 400). No server-side proposal state.
- **New domain events, commands, or read models.** This is a read-context +
  write-orchestration feature only.
- **Pushing anything into eventium.** NL→transaction is domain/app-specific;
  the LLM client is an infrastructure provider like `RateProvider` /
  `BankProvider`, nothing generic to lift.
- **Web/client work** (separate PR in the `monorepo`).
- **LLM orchestration frameworks** (LangChain et al.). This is a single-shot
  extraction call; `http-client` + `aeson` (already used by every outbound
  integration in the repo) covers it. No mature Haskell equivalent exists and a
  framework would fight the record-of-functions provider style. Agentic
  tool-calling / RAG, if ever needed, would be hand-rolled over `LlmClient`.

## Design

### 1. HTTP surface

```
POST /api/prompt                         (AuthProtect "jwt")
  ReqBody '[JSON] PromptRequest
  Post    '[JSON] PromptResponse
```

```jsonc
// PromptRequest
{ "text": "cash 123 food" }

// PromptResponse — a tagged union; only "transaction" exists in this feature
{ "kind": "transaction",
  "interpretation": "Expense 123 UAH from ‘Cash’, category Food",
  "transaction": <TransactionResponse> }     // existing DTO, unchanged

// reserved for the future reporting feature (documented, not implemented):
// { "kind": "report", "interpretation": "...", "report": <...> }
```

`kind` is a discriminator that is always `"transaction"` today. The handler
returns `201`-style success via the existing `TransactionResponse` embedding
(the created transaction), wrapped with a short human-readable
`interpretation` so a chat UI can echo how the text was understood.

`PromptResponse` is a Haskell sum type with a `kind` tag in its JSON encoding;
adding the `report` case later touches only the encoder and the router branch.

When `llm.enabled = false` (or `llmClient = Nothing`), the endpoint returns
**503** (feature disabled).

### 2. End-to-end flow

```
POST /api/prompt { text }                          [PromptService router]
  1. Handler       → extract UserId from JWT; reject empty text (400).
  2. Build prompt  → describe the AVAILABLE INTENTS + each intent's fields
                     (§2a); embeds the user's real account/category names;
                     user message = the raw text.
  3. LLM classify+extract → LlmClient.complete (JSON mode) → decode an
                     IntentEnvelope {intent, ...fields} → PromptIntent sum.
                     One retry if the body is not valid JSON. Unknown intent
                     name → 400 ("unsupported request"); malformed → 502.
  4. Dispatch      → exhaustive case on PromptIntent to the matching intent
                     handler. Today the only arm is CreateTransactionIntent →
                     the Transaction handler:
     4a. Gather transaction context (regular accounts + currencies; income/
         expense categories + default "Other"; labels).
     4b. Resolve  → pure functions turn the intent's text fields into a
                    concrete, validated create request (§5). Any hard failure
                    short-circuits to a 400 ValidationErr.
     4c. Commit   → delegate to TransactionService.initiate{Income,Expense,
                    Transfer}; return a PromptResult.
  5. Respond       → Web maps the PromptResult to the kind-tagged PromptResponse.
```

Effectful steps (`AppM`): 1, 4a, 4c; `IO` behind the client interface: 3;
**pure** (accuracy-critical): 4b resolution and all decoding. The router
(steps 1–3, 5) is intent-agnostic; per-intent logic lives in the intent's
own module.

### 2a. Intent architecture (extensibility)

`POST /api/prompt` is a general assistant entry point. "Create a transaction" is
the **first of many intents** (reports, account operations, …). The pipeline is
built around intents so adding one is additive and compiler-guided.

- **Envelope.** The model returns `{ "intent": "<name>", ...intent-fields }`.
  `intent` selects the operation; `create_transaction` is the only value today.
  (`kind` = income/expense/transfer is a *sub*-classification **within**
  create_transaction, not a top-level intent.)
- **`PromptIntent` (compile-time sum type).** Decoding the envelope yields
  `data PromptIntent = CreateTransactionIntent TransactionIntent | …`. The router
  dispatches with an **exhaustive `case`**, so a new constructor forces handling
  in the decoder, the router, and the response mapping — no half-wired intent can
  ship. Chosen over a runtime handler registry because all intents are known at
  compile time and exhaustiveness > open-world flexibility here.
- **`PromptResult` (sum).** Each intent produces a result variant
  (`TransactionCreated {…}` today); the Web layer maps each to the corresponding
  `kind`-tagged `PromptResponse` JSON.
- **Per-intent module.** Each intent owns its payload type + decoder, its
  prompt-guide fragment (schema + examples), its context-gathering, resolution,
  and execution. The router imports these; it contains no intent-specific logic.
- **Prompt assembly.** `Builder` concatenates the envelope instructions with each
  intent's guide fragment. One-phase today (single call returns intent + fields).
  When many intents make the prompt large, this can evolve to **two-phase**
  (a cheap classify call, then a focused per-intent extract) without changing the
  router's shape — documented, not built (YAGNI).

**Adding an intent later (e.g. `build_report`) — purely additive:**
1. new module `Application.Services.Prompt.Report.*` with its payload type +
   decoder, `promptGuide`, context, and `run`;
2. add `BuildReportIntent ReportIntent` to `PromptIntent` + its envelope-decoder
   arm;
3. add a `ReportBuilt {…}` arm to `PromptResult` + its `kind:"report"` Web
   mapping;
4. add one dispatch branch in the router and register its guide in `Builder`.

The compiler flags every step 2–4 site until complete. Only
`create_transaction` is implemented now; the report/account intents are **not**
built here.

### 3. LLM provider abstraction (Infrastructure)

Record-of-functions, mirroring `Infrastructure.ExchangeRate.Provider.RateProvider`:

```haskell
-- Infrastructure.Llm.Provider
data LlmMessage = LlmMessage { role :: !LlmRole, content :: !Text }
data LlmRole = System | User | Assistant

data LlmRequest = LlmRequest
  { messages    :: ![LlmMessage]
  , jsonSchema  :: !(Maybe Value)   -- sent as response_format when supported
  }

data LlmResponse = LlmResponse { content :: !Text }   -- raw assistant text (expected JSON)

data LlmClient = LlmClient
  { modelName :: !Text
  , complete  :: LlmRequest -> IO (Either Text LlmResponse) }
```

- **`Infrastructure.Llm.OpenAICompat`** — the concrete client over `http-client`
  (`newManager tlsManagerSettings` shared at startup, `parseRequest`, `httpLbs`,
  `tryAny`, JSON encode/decode via Aeson). Posts to
  `{base_url}/chat/completions` with `model`, `messages`, and
  `response_format: {type:"json_object"}` (or `json_schema` when a schema is
  supplied). Bearer `api_key` header only when non-empty. Honours `timeout_ms`.
  Maps transport / non-2xx / decode failures to `Left Text`.

The client is constructed in `app/Main.hs` from config, exactly like the
exchange-rate provider dispatch, and stored as `Maybe LlmClient` in `AppEnv`.

### 4. Config (Infrastructure.Config)

```haskell
data LlmConfig = LlmConfig
  { enabled   :: !Bool
  , baseUrl   :: !Text
  , model     :: !Text
  , apiKey    :: !Text       -- may be empty for local servers
  , timeoutMs :: !Int
  }
```

Added as `llm :: !LlmConfig` on `AppConfig`. YAML (env-substituted, following
the existing `${VAR:-default}` convention):

```yaml
llm:
  enabled:    ${LLM_ENABLED:-true}
  base_url:   ${LLM_BASE_URL:-http://localhost:11434/v1}
  model:      ${LLM_MODEL:-qwen2.5:7b-instruct}
  api_key:    ${LLM_API_KEY:-}
  timeout_ms: ${LLM_TIMEOUT_MS:-20000}
```

`config/test.yaml` sets `enabled: false` (tests inject a stub client directly).

### 5. Extraction schema and resolution (the core)

**Division of labor.** The LLM classifies + extracts strings/numbers; it never
emits UUIDs. Deterministic code resolves everything against ground truth. This
is the accuracy lever for a weak open model and the safety boundary.

#### 5.1 `TransactionIntent` (Application.Services.Prompt.Transaction.Intent, pure)

The exact JSON the model must return for the `create_transaction` intent (also
described verbatim in the prompt for servers that ignore `response_format`). The
`intent` discriminator (§2a) sits alongside the transaction fields:

```jsonc
{ "intent":      "create_transaction",  // the only intent today (§2a)
  "kind":        "expense" | "income" | "transfer",
  "amount":      "123",                 // decimal string, '.' separator
  "currency":    "UAH"|"USD"|"EUR"|"GBP"|null,
  "account":     "Cash",                // verbatim canonical name from the provided list
                                        //   (expense: source; income: target)
  "toAccount":   "Card"|null,           // transfer only; verbatim canonical name
  "category":    "Food"|null,           // verbatim canonical name; ignored for transfer
  "description": null|"...",            // user's original language, verbatim
  "date":        null|"2026-06-30" }    // absolute ISO YYYY-MM-DD, else null
```

The envelope decoder reads `intent` first (§2a) and, for `create_transaction`,
decodes the remaining fields into a `TransactionIntent` (a sum type with one
constructor per `kind`, carrying only that kind's fields). This is the parsed
shape of external LLM output — an **application** concern, not domain (cf.
`BankTransaction` living in `Infrastructure.Banking`, not `Domain`). The module
exports the decoder and this intent's JSON-schema fragment; no field selectors
leaked (smart accessors per house style).

#### 5.2 Name matching (Data.Text.Match, pure)

A generic text utility beside `Data.Text.Display` — zero domain semantics, so it
lives in the shared `Data.Text.*` layer rather than `Domain.*`.

```haskell
data MatchResult a = Matched a | Ambiguous [a] | NoMatch
matchByName :: (a -> Text) -> Text -> [a] -> MatchResult a
```

Normalize (trim, case-fold) → exact match → unambiguous prefix/substring match.
`Ambiguous` when more than one candidate ties. Pure and property-tested.

#### 5.3 Resolution rules

| Field | Rule | On failure |
|-------|------|-----------|
| `kind` | part of decode (always one of the three enum values) | invalid / undecodable JSON → **502** (§Failure modes), not 400 |
| account(s) | `matchByName` over the user's **regular** accounts | `NoMatch`/`Ambiguous` → **400** listing the user's account names |
| amount | normalize `,`→`.` decimal separator, then parse a **positive** `Decimal` | missing / non-positive / unparseable → **400** |
| currency | explicit → `parseCurrency`; else the resolved account's **native currency** (source for expense, target for income; per-leg for transfer) | invalid token → **400** |
| category | `matchByName` over the kind's dictionary (income vs expense) | **no confident match → default "Other" category from the user's configuration** (see below) |
| description | model value if present, else the original prompt text | — |
| date | parse the model's **ISO `YYYY-MM-DD`** → `UTCTime`; else now (model resolves relative/localized expressions itself using the current date in the prompt) | future date → **400** (relies on the existing write-path date check) |
| labels | best-effort `matchByName`; unmatched dropped | never fails |

Account and amount are strict because there is no safe default. Transfers carry
no category.

**Category default.** Every user's configuration is seeded with an **"Other"**
entry for both income and expense (`Domain.Configuration.Defaults`), so the
fallback is available in practice. The read model exposes it as
`defaultIncomeCategory` / `defaultExpenseCategory :: Maybe CategoryId`; if it is
somehow `Nothing`, resolution returns **400** rather than committing without a
category. So "graceful in practice, safe if absent."

**Amount + category → `Allocations`.** The write path does not take a bare
amount/category pair: `initiateIncome` / `initiateExpense` take both the total
`Money` *and* an `Allocations` value, where each `Allocation` carries its own
`Money`. Resolution assembles the resolved `(category, amount)` into a
**single-entry `Allocations`** (in the income or expense bucket per `kind`) via
`mkAllocation` / `mkAllocations`, whose total equals the resolved amount. Both
`mkAllocation` and `mkAllocations` return `Either DomainError`, so their
rejection is a further **400** path. Transfers take the amount only (no
allocations).

Resolution failures **reuse the existing `mkValidationError`** (field / message /
value) — no new `DomainError` constructor and no other `Domain.*` change. The
existing web error mapper already renders validation errors as **400** with the
human-readable clarification.

**Domain layer: untouched.** This feature adds no aggregates, commands, events,
projections, or domain types, and no new `DomainError` case. It is pure
orchestration over the existing transaction write path — consistent with your
observation that it introduces no new domain logic.

### 6. Prompt construction (Application.Services.Prompt.Builder + per-intent guides)

`Builder` is the intent-agnostic assembler: it emits the envelope instructions
(the `intent` discriminator and the list of available intents, §2a) and then
concatenates each registered intent's **guide fragment**. The
`create_transaction` guide lives in the transaction intent module
(`Application.Services.Prompt.Transaction.Intent`), keeping the intent's schema
and its prompt text in one place. Isolated so the template is easy to tune
without touching orchestration. The transaction guide:

- states the task and the required JSON shape (schema inline);
- lists the user's **actual** regular-account names and income/expense category
  names, so the model chooses from real values;
- states **the user may write in any language** and must map their words to one
  of the exact names provided, returning the chosen name **verbatim** (see §6.1);
- provides **today's date** so the model can resolve relative/localized date
  expressions to an absolute ISO date;
- instructs: amount as a plain decimal with `.` separator; date as ISO
  `YYYY-MM-DD` or null; `description` left in the user's original language;
- gives 3–4 few-shot examples covering the three kinds, the
  no-currency / no-category cases, **and a non-English prompt**;
- instructs "output only JSON".

#### 6.1 Localization (multilingual prompting)

The prompt text may be in any language (e.g. Ukrainian) while the user's
account and category names are in another (e.g. English): `готівка 123 їжа` →
expense from **Cash**, category **Food**. This is handled by the same
extract-vs-resolve split, with the **model** doing the cross-lingual mapping:

- **Names** — because the user's real names are in the prompt, the model maps
  the user's words to one of them and echoes the canonical name; `matchByName`
  then matches **exactly**. `matchByName` is *not* expected to bridge languages —
  that is the model's job. A hallucinated name still fails resolution
  (account → 400; category → "Other" default), so localization cannot widen the
  safety boundary.
- **Currency** — localized words (`грн`, `доларів`) are mapped by the model to
  the ISO enum it already emits (`UAH`/`USD`/…); `parseCurrency` is unchanged.
- **Amount** — model emits a `.`-decimal; resolution also normalizes a `,`
  decimal separator (`123,50` → `123.50`) as a safety net.
- **Date** — model resolves relative/localized expressions (`вчора`,
  `yesterday`) against the supplied current date and emits ISO `YYYY-MM-DD`;
  code parses ISO only (no relative-date parser needed).
- **Description** — stored **verbatim** in the original language.
- **`interpretation`** (echoed back) — built deterministically; contains the
  real (English) names plus English template words. A fully localized summary is
  a possible later enhancement, out of scope here.

### 7. Orchestration (router + intent handler)

**Router** — `Application.Services.PromptService`:

```haskell
handlePrompt ::
  ( MonadReader env m, MonadIO m, MonadError DomainError m
  , HasLlmClient env, HasDbPool env, HasEventStore env, ... ) =>
  UserId -> Text -> m PromptResult
```

Intent-agnostic: builds the prompt via `Builder`, calls the injected
`LlmClient` (with one retry), decodes the `IntentEnvelope` → `PromptIntent`, and
**dispatches with an exhaustive `case`** to the matching intent handler. Unknown
intent name → 400; malformed/failed LLM → 502/`err502`; disabled → 503/`err503`.

**Transaction handler** — `Application.Services.Prompt.Transaction.Handler`:
loads context (Account / Configuration read models), resolves the
`TransactionIntent` (pure, §5), then delegates to the existing
`TransactionService.initiate{Income,Expense,Transfer}` and returns
`TransactionCreated {…} :: PromptResult`. No new write-side logic — orchestration
over existing services. Each future intent adds its own handler module; the
router gains one `case` arm.

### 8. AppEnv wiring (Infrastructure.App)

```haskell
-- new field
llmClient :: !(Maybe LlmClient)

class HasLlmClient env where
  llmClientL :: Lens' env (Maybe LlmClient)
instance HasLlmClient AppEnv where ...
```

`app/Main.hs` builds `Just (mkOpenAICompatClient config.llm manager)` when
`config.llm.enabled`, else `Nothing`, reusing the shared HTTP `Manager`.

### 9. Testing

- **Pure / property (primary):**
  - `Data.Text.Match` — exact beats prefix; `Ambiguous` on ties; case/whitespace
    insensitivity; `NoMatch` empties. QuickCheck invariants.
  - `TransactionIntent` decoding — golden fixtures for each kind + null fields;
    malformed JSON rejected.
  - Resolution — category-default fallback, currency defaulting to account
    currency, positive-amount enforcement, `,`→`.` decimal normalization, ISO
    date parsing, ambiguity → 400 mapping. Pure inputs.
- **Integration (`*IntegrationSpec`):** a **stub `LlmClient`** returning canned
  JSON drives the full service → event-store path. Cases: each of
  income/expense/transfer commits correctly; unknown account → 400; ambiguous
  account → 400; unknown category → committed with "Other"; `llm.enabled=false`
  → 503. No network in tests.
- **Localization:** true cross-lingual mapping (`готівка`→`Cash`) is a *model*
  behavior, so it is not unit-testable with the stub. Deterministic tests assert
  only that (a) prompt construction includes the "any language" instruction +
  current date, and (b) resolution commits correctly given canonical-name JSON
  regardless of input language. End-to-end cross-lingual behavior is covered by
  an **optional manual integration test** against a local Ollama, skipped in CI.
- No LiquidHaskell obligations beyond reusing existing refined domain types
  (amount via `mkMoney`, etc.).

## Cross-Cutting Concerns

- **Security / RBAC:** context gathering and the commit both run as the JWT
  user; account resolution only ever sees the user's own accounts, so the model
  cannot address someone else's account by name. All writes go through the
  existing authorization checks in `TransactionService`.
- **Prompt injection:** the model output is *never* trusted as an
  authorization or identity signal — it only proposes names/amounts that must
  resolve against the user's own data and pass domain validation. Worst case is
  a wrong-but-owned transaction, which the existing delete/amend flows recover.
- **Failure modes (status-code split, decisive).** The codebase maps
  `ValidationErr` → **400** and reserves 422 for domain business-rule violations;
  it has no 502/503 mapping. To keep `Domain.*` untouched we therefore use:
  - **503** — feature disabled (`llm.enabled=false` / `llmClient=Nothing`).
    Thrown at the **Web handler** as a Servant `err503` (not a `DomainError`);
    `appMToHandler` re-throws `ServerError`s as-is.
  - **502** — the LLM *service* failed us: unreachable, timeout, non-2xx, or a
    body that is not valid schema JSON after one retry. Also thrown at the Web
    handler as `err502`. Upstream problem, not the user's.
  - **400** — the model returned a valid intent but it could not be mapped to a
    committable transaction (unknown/ambiguous account, non-positive/unparseable
    amount, invalid currency, missing category default, future date,
    `mkAllocations` rejection). Signalled via the existing
    `ValidationErr`/`mkValidationError` → 400 path — **no new `DomainError`
    constructor**.
  - There are **no partial writes**: the commit is a single existing
    `TransactionService` call made only after full resolution succeeds.
- **Cost / rate:** free open model; no per-token budgeting needed. (Rate
  limiting can be added later at the middleware layer if abuse appears — out of
  scope here.)
- **Future extension:** the intent architecture (§2a) turns this into a general
  assistant endpoint — new intents (report, account ops) are additive, the URL is
  stable, and `PromptService` + the per-intent handlers are reusable from an MCP
  adapter or a Telegram free-text handler.
