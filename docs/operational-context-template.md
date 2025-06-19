# Operational Context Template

**Level 1 Document: This document defines the fundamental operational constraints and context within which the entire system operates. All architectural decisions, implementation choices, and operational procedures must align with this context.**

## 1. Core Operational Model

Define your system's operational model by completing these sections:

### 1.1 State Management
[Identify all sources of persistent state in your system]

*Example:*
- Only two sources of persistent state:
  1. Local filesystem storage (define specific file/directory structures)
  2. External system X as the authoritative source for Y data
- All other state is transient and exists only within a single operation execution

### 1.2 Execution Environment
[Define the operational environment constraints]

*Example:*
- Single user operation
- Specific hardware environment (e.g., personal workstation, server, embedded system)
- Integration with specific external systems
- Local resource access requirements
- Concurrency model (single-threaded, multi-threaded, distributed)
- Process lifecycle (on-demand, continuous, scheduled)
- Persistence requirements (stateless, stateful, temporary state)

### 1.3 Operational Cadence
[Define how and when the system operates]

*Example:*
- Manual or automated execution cycles
- User-initiated vs. system-initiated operations
- Synchronous vs. asynchronous operation flow
- Scheduling parameters (if applicable)
- Triggering mechanisms

## 2. State Management Model

### 2.1 Persisted State
[Define all forms of persisted state in your system]

*Example:*
1. **Primary Data Store**
   - What data is stored
   - Where it is stored
   - Atomicity and consistency guarantees

2. **External Systems**
   - What data is maintained externally
   - How it is accessed
   - Source of truth definitions

### 2.2 Component State Machines

[Define how state is managed within system components]

*Example:*
1. **State Machine Properties**
   - Pure functions transforming immutable states
   - Mathematical verification approach
   - Type safety guarantees
   - Validation requirements

2. **State Machine Boundaries**
   - State lifecycle (creation, transformation, destruction)
   - State sharing model
   - State isolation requirements
   - Error handling with respect to state

3. **State Machine Usage**

   ```math
   operation: (State \times Input) \rightarrow (Result[Output], NewState)
   ```

[Explain your state machine implementation approach]

## 3. System Boundaries

### 3.1 What The System Is
[Define the explicit scope and responsibilities of your system]

*Example:*
1. A [type of application] that:
   - [Primary function 1]
   - [Primary function 2]
   - [Primary function 3]

2. A [framework/methodology] that:
   - [Capability 1]
   - [Capability 2]
   - [Capability 3]

3. An [integration/interface] that:
   - [Integration function 1]
   - [Integration function 2]
   - [Integration function 3]

### 3.2 What The System Is Not
[Define explicit exclusions from scope]

*Example:*
1. Not a [type of system]
   - [Exclusion 1]
   - [Exclusion 2]
   - [Exclusion 3]

2. Not a [type of system]
   - [Exclusion 1]
   - [Exclusion 2]
   - [Exclusion 3]

3. Not a [type of system]
   - [Exclusion 1]
   - [Exclusion 2]
   - [Exclusion 3]

## 4. Implementation Implications

### 4.1 Architectural Requirements
[Define what components must and must not do]

*Example:*
1. Components must:
   - [Requirement 1]
   - [Requirement 2]
   - [Requirement 3]
   - [Requirement 4]

2. Components must not:
   - [Constraint 1]
   - [Constraint 2]
   - [Constraint 3]
   - [Constraint 4]

### 4.2 Operational Requirements
[Define operational behaviors and constraints]

*Example:*
1. All operations must:
   - [Requirement 1]
   - [Requirement 2]
   - [Requirement 3]
   - [Requirement 4]
   - [Requirement 5]

2. All operations must not:
   - [Constraint 1]
   - [Constraint 2]
   - [Constraint 3]
   - [Constraint 4]

## 5. Verification Requirements

Every architectural decision, implementation choice, and operational procedure must be verified against this context:

1. **State Management**
   - [Verification question 1]
   - [Verification question 2]
   - [Verification question 3]

2. **Execution Model**
   - [Verification question 1]
   - [Verification question 2]
   - [Verification question 3]

3. **Operational Simplicity**
   - [Verification question 1]
   - [Verification question 2]
   - [Verification question 3]

## 6. Cross-Reference Requirements

All other system documentation must:

1. Reference this document when describing operational context
2. Maintain consistency with these constraints
3. Avoid duplicating these definitions

## 7. Evolution Requirements

Any proposed changes to this operational context must:

1. Demonstrate clear necessity
2. Preserve system integrity
3. Maintain operational simplicity
4. Update all dependent documentation

---

**Instructions for Using This Template:**

1. Replace all bracketed sections with content specific to your project
2. Provide concrete examples wherever possible
3. Be explicit about boundaries and constraints
4. Ensure all statements are clear, testable, and actionable
5. Validate that this document correctly scopes your project to avoid:
   - Overengineering (building more than needed)
   - Underengineering (building less than required)
   - Misalignment (building the wrong thing)
6. Use this document as a reference point for all architectural and implementation decisions

This document serves as the foundation for understanding the system's operational reality. All development, maintenance, and operational decisions must align with this context to preserve the system's integrity and effectiveness.
