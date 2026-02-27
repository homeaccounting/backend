# Implementation Plans

This directory contains AI-generated implementation plans that have been reviewed and approved for guiding development work.

## Active Plans

| Plan | Status | Created | Description |
|------|--------|---------|-------------|
| [2025-12-01-account-backend.md](./2025-12-01-account-backend.md) | in-progress | 2025-12-01 | Accounting backend with DDD, CQRS, Event Sourcing |
| [2026-01-30-user-management.md](./2026-01-30-user-management.md) | draft | 2026-01-30 | User management with OAuth2, Telegram, groups, and authorization |

## Archived Plans

See [archive/](./archive/) for completed or superseded plans.

## Creating New Plans

1. Use the `context-capture` rule to generate comprehensive plans
2. Save to `docs/plans/YYYY-MM-DD-feature-name.md`
3. Add required frontmatter (see below)
4. Update this README index
5. Review before committing

## Required Frontmatter

```yaml
---
status: draft | in-progress | completed | superseded
created: YYYY-MM-DD
author: cursor-ai | human
reviewed-by: <reviewer>
supersedes: <path>  # optional
---
```

## Plan Lifecycle

```
draft → in-progress → completed → archive/
                   ↘ superseded → archive/
```

## Related

- [Documentation Management Rule](../../.cursor/rules/documentation-management.mdc)
- [Context Capture Rule](../../.cursor/rules/context-capture.mdc)
- [PRD & Prompts](../prompts/)
