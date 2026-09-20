# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records documenting significant technical decisions made in this project.

## Decisions

| ID | Title | Status | Date |
|----|-------|--------|------|
| [001](./001-event-field-naming.md) | Event field naming convention | Accepted | 2026-06-13 |
| [002](./002-structural-group-item-dictionary-entries.md) | Structural group/item dictionary entries | Accepted | 2026-07-20 |
| [003](./003-process-manager-snapshot-caching.md) | Process managers project through a snapshot cache | Accepted | 2026-08-21 |
| [004](./004-synthesized-external-ids-are-pinned-idempotency-keys.md) | Provider-synthesized external ids are pinned idempotency keys | Accepted | 2026-09-15 |
| [005](./005-statement-times-are-provider-local.md) | Statement wall-clock times are provider-local | Accepted | 2026-09-15 |
| [006](./006-import-attribution-capacity-replaces-boolean-reconciled.md) | Import attribution is capacity-limited, not once-only | Accepted | 2026-09-16 |

## ADR Format

Each ADR follows this structure:

```markdown
# NNN - Title

## Status
Proposed | Accepted | Deprecated | Superseded by [NNN](./NNN-title.md)

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult because of this change?
```

## Creating a New ADR

1. Copy the template above
2. Name the file `NNN-short-title.md` (e.g., `001-event-sourcing.md`)
3. Fill in all sections
4. Update this README index
5. Submit for review

## Numbering

- Use sequential three-digit numbers: `001`, `002`, `003`
- Never reuse numbers, even for superseded decisions

## Related

- [Documentation Management Rule](../../.cursor/rules/documentation-management.mdc)
- [Implementation Plans](../plans/)
