# Contributing to HomeAccounting Backend

Thanks for considering a contribution. This repository is the Haskell backend —
the event-sourced core, the REST API, and the bank providers.

## Where things go

HomeAccounting is split across several repositories, and **issues belong to the
repository you are using**:

| What | Where |
| --- | --- |
| Backend bug, API behaviour, bank provider | this repository's [Issues](https://github.com/homeaccounting/backend/issues) |
| Web UI bug or UX problem | [homeaccounting/web](https://github.com/homeaccounting/web/issues) |
| Website / docs content | [homeaccounting/site](https://github.com/homeaccounting/site/issues) |
| Questions, ideas, bank-provider requests | [Discussions](https://github.com/homeaccounting/backend/discussions) |
| **Security vulnerabilities** | **Never an issue** — see [SECURITY.md](SECURITY.md) |

## Before you write code

For anything beyond a small fix, **open an issue or a discussion first.** This is
a finance application with a strict architecture (CQRS + event sourcing, four
layers, an append-only event log that is never mutated in place), so a change
that looks small can carry constraints that are not obvious from the diff. A
short conversation up front saves a rewrite.

Good first contributions are labelled
[`good first issue`](https://github.com/homeaccounting/backend/labels/good%20first%20issue).
Adding a new bank provider is the most valuable contribution you can make — each
one opens a new market — and the provider interface is designed for it.

## Development setup

Tooling is managed with Nix, so you do not install GHC or Cabal yourself:

```bash
nix develop        # GHC 9.10.3, Cabal, hpack, ormolu, hlint, just
just docker-up     # PostgreSQL 15
just build
just test
```

`just --list` shows every recipe. The ones you need most:

| Command | What it does |
| --- | --- |
| `just build` | hpack + `cabal build` (warnings are errors, via `-fci`) |
| `just test` | full test suite |
| `just check` | format + lint (`ormolu` + `hlint`) |
| `just run` | run the API against `config/test.yaml` |
| `just watch` | continuous compilation with ghcid |

Start with [`docs/architecture.md`](docs/architecture.md) and `CLAUDE.md` — the
latter is written for AI assistants but is the most complete statement of the
project's conventions, and it applies to humans identically.

## The rules that actually block a merge

- **Layering.** `Domain` imports nothing from the project; `Infrastructure` may
  import `Domain`; `Application` may import `Domain` and `Infrastructure`; `Web`
  may import anything. `app/Main.hs` is the only exempt module.
- **Domain logic is pure.** No `IO` in `Domain.*`, ever. Validation returns
  `Either DomainError a`.
- **No partial functions.** No `error`, no `undefined`, no incomplete patterns.
- **Stored events are versioned data.** The project is in production and
  self-hosters own their event store. A change to the shape of a persisted event
  needs an upcaster, not a permissive `FromJSON`. `CLAUDE.md` explains the
  distinction and why the shortcut is banned.
- **Tests.** Property-based tests are primary; unit and integration tests
  supplement them. New domain invariants need QuickCheck properties.
- **Formatting and linting.** `ormolu` is mandatory and `hlint` suppressions
  need an explicit rationale. Run `just check` before pushing.

## Commits and branches

We follow [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>[(scope)][!]: <description>
```

Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `style`, `ci`, `perf`,
`build`. Breaking changes take `!` or a `BREAKING CHANGE:` footer.

Branches follow `<type>/<kebab-case-description>`, named after the goal of the
work rather than the individual commits — `feat/add-monzo-provider`, not
`fix/pr-feedback`.

## Pull requests

1. Branch off `master`.
2. Keep the PR focused on one goal; unrelated cleanups belong in their own PR.
3. Make sure `just check` and `just test` pass locally — CI runs the same gates
   with `-Werror`, and the incremental object cache can hide a warning that CI
   will catch, so use `just rebuild` if a warning looks suspicious.
4. Title the PR in Conventional Commits form; describe what changed and why.
5. Sign the CLA — see below.

Maintainer review is usually quick. If a PR sits for more than a few days,
please nudge it; that is a lapse on our side, not impatience on yours.

## Contributor Licence Agreement

Before your first pull request can be merged you will be asked to sign the
[Contributor Licence Agreement](CLA.md). A bot comments on the PR with a
one-line statement to post; that signature is recorded and you will not be asked
again.

The CLA exists so the project can keep its licensing options open — for example,
relicensing the whole codebase if the community ever needs it. It does not take
your copyright away: you keep it, and you grant HomeAccounting a licence to use
your contribution.

## Code of Conduct

Participation is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). Reports
go to `conduct@homeaccounting.com`.

## Licence

Contributions are licensed under [AGPL-3.0](LICENSE), the licence of this
repository. The HomeAccounting name and logo are not covered by that licence —
see [TRADEMARK.md](TRADEMARK.md).
