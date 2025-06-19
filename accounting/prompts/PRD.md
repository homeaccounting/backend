# Accounting

## Overview
This is the backend service for personal accounting system which allows to track personal finances

## Main features
* Create account
* Transfer money from one account to another


# Design
Domain Driven Design should be applied along with CQRS and Event-Sourcing patterns.
The whole app should use hexagonal architecture with layers.


## Project structure

src/
├── Domain/
│   ├── Account/
│   │   ├── Errors.hs           -- Account errors
│   │   ├── Commands.hs         -- Account commands
│   │   ├── CommandHandlers.hs  -- Account command handlers
│   │   ├── Events.hs           -- Account events
│   │   └── Aggregate.hs        -- Account aggregate and business logic
│   ├── Transaction/
│   │   ├── Errors.hs           -- Transaction errors
│   │   ├── Commands.hs         -- Transaction commands
│   │   ├── CommandHandlers.hs  -- Transaction command handlers
│   │   ├── Events.hs           -- Transaction events
│   │   └── Aggregate.hs        -- Transaction aggregate and business logic
│   └── Core/ 
│       ├── Errors.hs           -- Core errors
│       ├── Types.hs            -- Core types (Money, UUID, etc.)
│
├── Application/
│   ├── ProcessManagers/        -- The process-managers/sagas should live there
│   ├── ReadModels/             -- Read-models / query projects
│
├── Infrastructure/
│   ├── Eventium.hs         -- Wiring code for eventium library
│
│
├── Web/
│   ├── API/
│   │   ├── AccountAPI.hs
│   │   └── TransactionAPI.hs
│   └── Server.hs  
└── Main.hs                   -- Composition root

## Implementation Details

### Language
* The service should be written in Haskell.
* Use `hlint` for linting.
* Use `ormolu` for formatting and styles.


### Build 
* Use nix flake for development environment 

### Configuration
Configuration like db name, username etc should be defined in config file in yaml format.

### API
* The API should be RESTFul
* Should be complaint with latest OpenAPI spec

### Testing
* Unit-tests should be written on Domain model
* Integration tests should be written by accessing RESTFull API

### Database
* Use Postgresql as events storage. 
* Use docker-compose to spin up the development database.

### EventSourcing
* The `eventium` CQRS library should be used for event-sourcing routing
* Take the `eventium` example `./lib/eventium/examples/bank` as baseline of it's usage but apply our own structure
    
### Dependencies

* `servant` & `warp` for Web layer

