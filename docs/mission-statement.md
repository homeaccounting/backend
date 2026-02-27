# Mission Statement

**Level 1 Document: This document is the ultimate source of truth, driving every decision made within the project. It supersedes any derived document in the case of conflict.**

## Core Purpose

To provide a secure, reliable, and auditable personal finance tracking system through a mathematically verified Haskell implementation using event sourcing. The system enables individuals to manage multiple financial accounts and track money transfers with complete historical traceability and data integrity guarantees.

## Strategic Approach

Our approach leverages Haskell's strong type system, pure functional paradigm, and event sourcing architecture to implement a personal accounting system that is:

- **Correct by construction** — Domain logic encoded in types prevents invalid states
- **Auditable** — Event sourcing provides complete history of all financial operations
- **Recoverable** — Any state can be reconstructed from the event log
- **Performant** — CQRS separation enables optimized read and write paths

Key principles guiding decision-making:

1. **Domain purity** — Business logic remains pure and testable, with effects pushed to boundaries
2. **Explicit errors** — All failure modes encoded in types, no runtime surprises
3. **Event-first design** — State changes expressed as immutable facts, not mutations
4. **Hexagonal architecture** — Clear layer separation enables testing and evolution

## Execution Framework

The system is implemented within a focused, systematic framework:

1. **Domain-Driven Design** — Ubiquitous language shared between domain experts and code
2. **CQRS** — Commands mutate state via events; queries read from optimized projections
3. **Event Sourcing** — All state changes stored as immutable events in PostgreSQL
4. **RIO Application Monad** — Structured effects, logging, and resource management

Development follows:
- Nix flakes for reproducible builds
- `hlint` for idiomatic Haskell
- `ormolu` for consistent formatting
- Property-based testing for domain invariants

## Formal Verification

We employ formal methods to mathematically verify the correctness of our system. This ensures that all operations:

* Adhere to predefined specifications through Haskell's type system
* Maintain the integrity of the system's state through event sourcing invariants
* Align with our rigorous, domain-specific requirements:
  - Account balances never go negative
  - Transfers are atomic (debit and credit succeed together or both fail)
  - All state transitions are traceable to explicit events

## Commitment

This commitment to formal verification underpins our project's sophistication and ensures responsible implementation of mission-critical functionality through a demonstrably correct and reliable system. All decisions regarding the system's architecture, implementation, and operation must demonstrably align with and support this mission.

The system prioritizes:
1. **Correctness** over convenience
2. **Auditability** over performance
3. **Explicitness** over brevity
4. **Type safety** over runtime flexibility

---

## Related

- [Operational Context](./operational-context.md)
- [User Experience Specification](./user-experience-spec.md)
- [PRD](./prompts/2025-12-01-account-backend.md)
