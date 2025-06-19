# Accounting System Backend

A REST API for an accounting system built with Haskell using CQRS (Command Query Responsibility Segregation) and Event Sourcing patterns.

## Architecture

This system implements a clean architecture with the following components:

### Domain Layer (`src/Domain/`)
- **Events.hs**: Domain events (AccountCreated, MoneyTransferred)
- **Account.hs**: Account aggregate root with business logic
- **Commands.hs**: Command definitions for CQRS pattern

### Infrastructure Layer (`src/Infrastructure/`)
- **EventStore.hs**: In-memory event store implementation

### Application Layer (`src/Application/`)
- **CommandHandlers.hs**: Handlers for processing commands
- **QueryHandlers.hs**: Handlers for read operations

### Web Layer (`src/Web/`)
- **API.hs**: REST API definitions using Servant
- **Server.hs**: Web server configuration

## Features

- **Create Account**: Create new accounts with initial balance
- **Transfer Money**: Transfer money between accounts with validation
- **Query Accounts**: Get account information and balances
- **Event Sourcing**: All state changes are stored as events
- **CQRS**: Separate command and query responsibilities

## API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/accounts` | List all accounts |
| POST | `/accounts` | Create new account |
| GET | `/accounts/{id}` | Get account by ID |
| GET | `/accounts/{id}/balance` | Get account balance |
| POST | `/transfer` | Transfer money between accounts |
| GET | `/events` | List all events (debug) |

## Building and Running

### Prerequisites
- GHC (Glasgow Haskell Compiler) 9.2+
- Cabal 3.6+

### Build
```bash
cabal build
```

### Run
```bash
cabal run accounts
```

The server will start on port 8080.

## API Usage Examples

### Create Account
```bash
curl -X POST http://localhost:8080/accounts \
  -H "Content-Type: application/json" \
  -d '{
    "requestAccountName": "John Doe",
    "requestInitialBalance": 1000
  }'
```

### List All Accounts
```bash
curl http://localhost:8080/accounts
```

### Get Account Balance
```bash
curl http://localhost:8080/accounts/{account-id}/balance
```

### Transfer Money
```bash
curl -X POST http://localhost:8080/transfer \
  -H "Content-Type: application/json" \
  -d '{
    "requestFromAccountId": "source-account-uuid",
    "requestToAccountId": "target-account-uuid",
    "requestAmount": 100
  }'
```

### View Events (Debug)
```bash
curl http://localhost:8080/events
```

## Domain Model

### Account
- **AccountId**: Unique identifier (UUID)
- **AccountName**: Display name
- **Balance**: Current balance (Integer, representing cents)
- **Version**: For optimistic concurrency control

### Events
- **AccountCreated**: Fired when a new account is created
- **MoneyTransferred**: Fired when money is transferred between accounts

### Commands
- **CreateAccount**: Command to create a new account
- **TransferMoney**: Command to transfer money between accounts

## CQRS & Event Sourcing Implementation

The system separates read and write operations:

1. **Commands** modify state by generating events
2. **Events** are stored in the event store
3. **Read models** (projections) are updated from events
4. **Queries** read from the projections

This approach provides:
- Complete audit trail
- Ability to replay events
- Separation of concerns
- Scalability potential

## Development

The codebase follows Domain-Driven Design principles:
- Domain logic is isolated from infrastructure concerns
- Business rules are enforced in the domain layer
- Clear separation between commands and queries

## Testing

To test the system manually:

1. Start the server: `cabal run accounts`
2. Create two accounts using the create account endpoint
3. Transfer money between them
4. Check balances and events

## Future Enhancements

- Persistent event store (PostgreSQL, etc.)
- Snapshots for performance
- Authentication and authorization
- Websocket notifications
- Comprehensive test suite
- Monitoring and logging 