# Accounting Backend Implementation Plan

## Overview
Implementation plan for the personal accounting backend service rewrite using Domain-Driven Design with CQRS and Event-Sourcing patterns in Haskell.

## Project Structure Target
```
src/
├── Domain/
│   ├── Account/
│   │   ├── Errors.hs         -- Account errors
│   │   ├── Commands.hs       -- Account commands
│   │   ├── Events.hs         -- Account events
│   │   ├── Model.hs          -- Account aggregate
│   │   └── Aggregate.hs      -- Account business logic
│   ├── Transaction/
│   │   ├── Errors.hs        -- Transaction errors
│   │   ├── Commands.hs      -- Transaction commands
│   │   ├── Events.hs        -- Transaction events
│   │   ├── Model.hs         -- Transaction aggregate
│   │   └── Aggregate.hs     -- Transaction business logic
│   └── Core/
│       ├── Errors.hs         -- Core errors
│       ├── Types.hs          -- Core types (Money, UUID, etc.)
│       └── EventBus.hs       -- Cross-aggregate event handling
│
├── Application/
│   ├── CommandHandlers/
│   ├── QueryHandlers/
│   └── EventHandlers/       
│
├── Infrastructure/
│
├── EventSourcing/
│
├── Web/
│   ├── API/
│   │   ├── AccountAPI.hs
│   │   └── TransactionAPI.hs
│   └── Server.hs  
└── Main.hs                   -- Composition root
```

## Implementation Plan

### Phase 1: Foundation (Tasks 1-3)

#### Task 1: Set up foundational types and core infrastructure
- **Status**: Pending
- **Dependencies**: None
- **Description**: Establish basic project structure and foundational types
- **Deliverables**:
  - Core module structure
  - Basic type definitions
  - Project build configuration validation

#### Task 2: Implement custom EventSourcing library module
- **Status**: Pending 
- **Dependencies**: Task 1
- **Description**: Create simplified event-sourcing & CQRS library as separate module
- **Deliverables**:
  - `EventSourcing/Event.hs` - Event type definitions
  - `EventSourcing/EventStore.hs` - Event storage interface
  - `EventSourcing/EventBus.hs` - Event publishing/subscription
  - `EventSourcing/EventStream.hs` - Event stream handling
  - `EventSourcing/EventMetadata.hs` - Event metadata handling

#### Task 3: Create Domain/Core module
- **Status**: Pending
- **Dependencies**: Task 2
- **Description**: Implement shared domain types, errors, and EventBus interface
- **Deliverables**:
  - `Domain/Core/Types.hs` - Money, UUID, common value objects
  - `Domain/Core/Errors.hs` - Core domain errors
  - `Domain/Core/EventBus.hs` - Cross-aggregate event handling interface

### Phase 2: Domain Layer (Tasks 4-5)

#### Task 4: Implement Account domain
- **Status**: Pending
- **Dependencies**: Task 3
- **Description**: Complete Account domain with full DDD patterns
- **Deliverables**:
  - `Domain/Account/Errors.hs` - Account-specific errors
  - `Domain/Account/Commands.hs` - Account commands (CreateAccount, etc.)
  - `Domain/Account/Events.hs` - Account events (AccountCreated, etc.)
  - `Domain/Account/Model.hs` - Account aggregate state
  - `Domain/Account/Aggregate.hs` - Account business logic

#### Task 5: Implement Transaction domain
- **Status**: Pending
- **Dependencies**: Task 3
- **Description**: Complete Transaction domain with full DDD patterns
- **Deliverables**:
  - `Domain/Transaction/Errors.hs` - Transaction-specific errors
  - `Domain/Transaction/Commands.hs` - Transaction commands (TransferMoney, etc.)
  - `Domain/Transaction/Events.hs` - Transaction events (MoneyTransferred, etc.)
  - `Domain/Transaction/Model.hs` - Transaction aggregate state
  - `Domain/Transaction/Aggregate.hs` - Transaction business logic

### Phase 3: Application & Infrastructure (Tasks 6-7)

#### Task 6: Create Application layer
- **Status**: Pending
- **Dependencies**: Tasks 4, 5
- **Description**: Implement application handlers for commands, queries, and events
- **Deliverables**:
  - `Application/CommandHandlers/` - Command handling logic
  - `Application/QueryHandlers/` - Query handling for read models
  - `Application/EventHandlers/` - Cross-aggregate event handling

#### Task 7: Implement Infrastructure layer
- **Status**: Pending
- **Dependencies**: Task 2
- **Description**: Concrete implementations for EventStore and database access
- **Deliverables**:
  - `Infrastructure/EventStore.hs` - PostgreSQL event store implementation
  - `Infrastructure/ReadStore.hs` - Read model storage
  - `Infrastructure/Config.hs` - Configuration loading and management

### Phase 4: Web Layer (Tasks 8-10)

#### Task 8: Create Web layer with REST API
- **Status**: Pending
- **Dependencies**: Tasks 6, 7
- **Description**: REST API using Servant framework
- **Deliverables**:
  - `Web/API/AccountAPI.hs` - Account REST endpoints
  - `Web/API/TransactionAPI.hs` - Transaction REST endpoints  
  - `Web/Server.hs` - Warp server setup
  - `Web/Types.hs` - Web layer types and serialization

#### Task 9: Set up configuration management
- **Status**: Pending
- **Dependencies**: Task 1
- **Description**: YAML configuration management for different environments
- **Deliverables**:
  - Configuration loading logic
  - Validation of existing config files (dev.yaml, local.yaml, prod.yaml)
  - Environment-specific configuration handling

#### Task 10: Implement Main.hs composition root
- **Status**: Pending
- **Dependencies**: Tasks 8, 9
- **Description**: Wire everything together in the main application entry point
- **Deliverables**:
  - `Main.hs` - Application composition and startup
  - Dependency injection setup
  - Application lifecycle management

### Phase 5: Data & Testing (Tasks 11-15)

#### Task 11: Finalize PostgreSQL schema
- **Status**: Pending
- **Dependencies**: Task 2
- **Description**: Complete event storage schema and migration scripts
- **Deliverables**:
  - Updated `database/schema.sql`
  - Event store tables design
  - Read model tables (if needed)
  - Migration scripts

#### Task 12: Write domain unit tests
- **Status**: Pending
- **Dependencies**: Tasks 4, 5
- **Description**: Unit tests for Domain models and business logic
- **Deliverables**:
  - Account aggregate tests
  - Transaction aggregate tests
  - Domain logic validation tests
  - Property-based tests for business rules

#### Task 13: Write integration tests
- **Status**: Pending
- **Dependencies**: Tasks 8, 11
- **Description**: Integration tests accessing the RESTful API
- **Deliverables**:
  - API endpoint tests
  - End-to-end workflow tests
  - Database integration tests
  - Event sourcing integration tests

#### Task 14: Generate OpenAPI specification
- **Status**: Pending
- **Dependencies**: Task 8
- **Description**: OpenAPI specification for the REST API
- **Deliverables**:
  - OpenAPI 3.0 specification
  - API documentation
  - Client generation capabilities

#### Task 15: Verify Docker development environment
- **Status**: Pending
- **Dependencies**: Task 11
- **Description**: Ensure docker-compose.yml works for development database
- **Deliverables**:
  - Updated `docker-compose.yml`
  - Development environment documentation
  - Database initialization scripts

## Technical Requirements

### Language & Tools
- Haskell with hlint for linting
- ormolu for formatting and styles
- Nix flake for development environment

### Architecture Patterns
- Domain-Driven Design (DDD)
- Command Query Responsibility Segregation (CQRS)
- Event-Sourcing
- Clean Architecture layers

### Key Dependencies
- `servant` & `warp` for Web layer
- PostgreSQL for event storage
- Custom EventSourcing library

### Quality Assurance
- Unit tests on Domain models
- Integration tests via REST API
- RESTful API compliant with OpenAPI spec
- Comprehensive error handling
- Configuration management

## Implementation Strategy

1. **Bottom-up approach**: Start with foundational components and work up through architectural layers
2. **Dependency respect**: Each task clearly defines its dependencies to maintain clean architecture
3. **Incremental validation**: Each phase can be tested independently before moving to the next
4. **Domain-first**: Domain logic is implemented before infrastructure concerns
5. **Test-driven**: Tests are planned alongside implementation, not as an afterthought

## Next Steps

1. Start with Task 1 (Setup Foundation) as it has no dependencies
2. Work through tasks in dependency order
3. Validate each phase before proceeding to the next
4. Maintain clean git history with meaningful commits per task
5. Update this plan as requirements evolve or implementation details are refined 