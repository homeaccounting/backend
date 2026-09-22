## What and why

<!-- What does this change, and what problem does it solve? Link the issue or
     discussion it comes from: "Closes #123". -->

## How it was verified

<!-- The commands you ran and what they printed. "Should work" is not
     verification. -->

- [ ] `just check` (ormolu + hlint) passes
- [ ] `just test` passes
- [ ] New or changed domain logic is covered by a property test

## Event-sourcing impact

<!-- Delete this section if the change touches no persisted event. -->

- [ ] No stored event changed shape
- [ ] Or: a shape change ships with a registered upcaster and a legacy-decode
      test against a committed fixture

## Checklist

- [ ] The layering rules hold (`Domain` imports nothing from the project;
      `Infrastructure` → `Domain`; `Application` → `Domain`/`Infrastructure`)
- [ ] No `error`, `undefined`, or partial functions
- [ ] No secrets, tokens, or real financial data in the diff or test fixtures
- [ ] Title follows Conventional Commits
- [ ] I have signed the [CLA](https://github.com/homeaccounting/backend/blob/master/CLA.md) (a bot will ask on your first PR)
