# 009 - Universal account naming

## Status
Accepted

## Context

Accounts are named in several places: the web sidebar and pickers, the mobile app,
Telegram transaction messages and the prompt resolver. Each surface grew its own rule.
Web and mobile qualify a name with the bank, provider, lender or storage place and
append the currency only when two labels collide. Telegram and the prompt resolver use
the bare name, so two "Card" accounts look identical and "card" is ambiguous with no
way to say which one. Users with many accounts across banks and currencies cannot
tell them apart (tracker#97).

## Decision

1. **Full name.** Every account has a full name built from four segments:

   `{Kind} › {Qualifier} › {Name} · {Currency}`

   | Segment | Source | When missing |
   |---|---|---|
   | Kind | subtype type, localized (Cash, Bank account, E-wallet, Asset, Loan) | "Other" |
   | Qualifier | `storageLocation` (cash), `bankName` (bank account), `provider` (e-wallet), `assetType` label (asset), `lender` (loan) | segment omitted |
   | Name | `name` | — |
   | Currency | `currency` | — |

   Examples: `Bank account › PrivatBank › Card · UAH`,
   `Cash › Home safe › Savings · EUR`, `Asset › Property › Flat in Kyiv · UAH`.

   `AccountType` is not a segment: it is `Regular | External`, and the External
   account is never shown. Currency is an attribute, so it is a suffix, not a path
   segment. `›` is used rather than `/` because names may contain `/`.

2. **Short forms.** A surface shows the name, then whichever of qualifier and
   currency its context does not already show. Kind is carried by an icon and never
   appears in a short form. A list under a bank sub-header omits the qualifier; a row
   that shows a formatted balance omits the currency; a surface with no context shows
   the full name.

3. **Search.** A query matches an account when every whitespace-separated token is a
   case- and accent-insensitive substring of its full name.

4. **Clients format locally.** The full name is a localized display string, never a
   key or identifier. The API does not carry a formatted name: kind labels are
   localized, clients switch language live, and the short form depends on context.
   Each client implements this ADR (web `src/features/accounts/accountName.ts`; mobile
   ports it). The backend applies it to its own text: Telegram messages use the short
   form, and the prompt resolver matches on the full name and lists full names in
   ambiguity errors.

5. **No uniqueness constraint.** Full names are not required to be unique. Accounts
   shared by other owners can collide regardless of what one user creates, and
   enforcing uniqueness across event-sourced account aggregates needs a cross-aggregate
   lookup on every create and rename. Qualifier plus currency makes collisions rare;
   clients order ties by id so order stays stable.

## Consequences

- One reference for every client; a change to naming is a change to this ADR first.
- Currency appears in every label unless the context shows it, replacing the
  collision-only currency rule.
- Two accounts with the same full name remain possible and are told apart only by
  balance or position.
