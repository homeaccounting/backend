-- ============================================================================
-- Event Store Schema Documentation for Accounting System
-- ============================================================================
-- 
-- IMPORTANT: This file is DOCUMENTATION ONLY.
-- 
-- The database schema is automatically created and managed by eventium-postgresql
-- when the application or tests call initializeEventStore. There is no need to
-- manually run SQL scripts to set up the event store.
--
-- This file documents:
--   1. Event Store tables (managed by eventium-postgresql)
--   2. Read Models (custom query tables - currently in-memory)
--   3. Performance indexes and configuration recommendations
--
-- CI/CD Note:
--   The GitHub Actions CI workflow does NOT execute this file. The test suite
--   automatically initializes the event store when needed.
--
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Event Store Tables (Managed by eventium-postgresql)
-- ----------------------------------------------------------------------------
--
-- The following tables are automatically created by eventium-postgresql
-- when initializeEventStore is called from Infrastructure.Database.
--
-- The SQL shown below is what Persistent generates from the eventium-postgresql
-- entity definitions. This is for documentation purposes only - DO NOT execute
-- these statements manually.
--
-- Source: lib/eventium/eventium-sql-common/src/Eventium/Store/Sql/DefaultEntity.hs

-- ============================================================================
-- Table: events
-- ============================================================================
-- Stores all domain events with versioning for optimistic concurrency control.
--
-- CREATE TABLE events (
--     id      SERIAL PRIMARY KEY,
--     uuid    TEXT NOT NULL,
--     version INTEGER NOT NULL,
--     event   TEXT NOT NULL,
--     CONSTRAINT unique_uuid_version UNIQUE (uuid, version)
-- );
--
-- CREATE INDEX IF NOT EXISTS idx_events_uuid ON events (uuid);
-- CREATE INDEX IF NOT EXISTS idx_events_version ON events (version);
-- 
-- Columns:
--   - id: Sequence number (auto-increment) for global event ordering
--   - uuid: Stream identifier (aggregate ID) as text
--   - version: Event version within the stream (starts at 1)
--   - event: Serialized event data (JSON stored as TEXT)
--
-- Constraints:
--   - PRIMARY KEY (id): Ensures global unique sequence for all events
--   - UNIQUE (uuid, version): Prevents duplicate events in a stream
--                             Enables optimistic concurrency control
--
-- Indexes:
--   - idx_events_uuid: Fast lookup of all events in a stream
--   - idx_events_version: Fast filtering by version
--
-- Notes:
--   - The 'id' column serves as a global sequence number across all streams
--   - The UNIQUE constraint on (uuid, version) ensures:
--     * No duplicate events in a stream
--     * Optimistic locking works correctly
--     * Concurrent writes to the same stream fail properly
--   - Event data is stored as JSON text for flexibility
--   - UUIDs are stored as TEXT (not native UUID type) for portability

-- ============================================================================
-- How eventium-postgresql uses this schema:
-- ============================================================================
--
-- Writing Events:
--   1. Begin transaction
--   2. Lock the events table (LOCK TABLE events IN EXCLUSIVE MODE)
--   3. Get max version for stream: SELECT MAX(version) FROM events WHERE uuid = ?
--   4. Insert new events with incremented versions
--   5. Commit transaction
--
-- Reading Events:
--   - Get stream: SELECT * FROM events WHERE uuid = ? ORDER BY version
--   - Get stream from version: SELECT * FROM events WHERE uuid = ? AND version >= ?
--   - Get all events: SELECT * FROM events ORDER BY id
--   - Get global stream: SELECT * FROM events WHERE id >= ? ORDER BY id
--
-- Concurrency Control:
--   - The UNIQUE constraint prevents concurrent writes to the same aggregate
--   - Table lock ensures global sequence (id) is strictly increasing
--   - Failed writes raise a unique violation exception
--
-- ============================================================================
-- Additional Notes:
-- ============================================================================
--
-- Persistent Migration:
--   The schema is created by: runMigration migrateSqlEvent
--   Migrations are idempotent and safe to run multiple times.
--
-- Global Event Ordering:
--   The 'id' column provides a global sequence across all streams.
--   This allows projections to process events in the order they were committed.
--
-- Storage Size:
--   - UUID as TEXT: ~36 bytes per event
--   - Event JSON: varies by event size
--   - Typical event: 100-500 bytes
--   - 1 million events: ~100-500 MB
--
-- Performance Characteristics:
--   - Write throughput: ~1000-5000 events/sec (single connection)
--   - Read throughput: ~10000-50000 events/sec
--   - Stream lookup: O(log n) due to index
--   - Global scan: O(n) but fast with sequential reads

-- ----------------------------------------------------------------------------
-- Read Model Tables (Custom Query Optimization)
-- ----------------------------------------------------------------------------
--
-- Read models are denormalized views optimized for queries.
-- They are built by projecting from the event stream.
--
-- These tables will be added as the application evolves.
-- They are separate from the event store and can be rebuilt at any time
-- by replaying events.

-- Account Summary Read Model (Task 5.3 - Currently In-Memory)
--
-- Note: The AccountSummary read model is currently implemented using an in-memory
-- TVar for simplicity and performance. For production with multiple instances,
-- consider implementing a PostgreSQL-backed version using the schema below.
--
-- The in-memory implementation is defined in:
--   Application/ReadModels/AccountSummary.hs
--
-- To enable persistent read model storage, uncomment the following:
--
-- CREATE TABLE IF NOT EXISTS account_summary (
--     account_id UUID PRIMARY KEY,
--     account_name TEXT NOT NULL,
--     current_balance NUMERIC(15,2) NOT NULL CHECK (current_balance >= 0),
--     event_version INTEGER NOT NULL DEFAULT 0,
--     -- ^ Version from event stream for optimistic concurrency
--     last_updated_sequence BIGINT NOT NULL,
--     -- ^ Tracks which global event was last applied
--     created_at TIMESTAMP NOT NULL DEFAULT NOW(),
--     updated_at TIMESTAMP NOT NULL DEFAULT NOW()
-- );
--
-- CREATE INDEX IF NOT EXISTS idx_account_summary_name 
--     ON account_summary(account_name);
--
-- CREATE INDEX IF NOT EXISTS idx_account_summary_balance 
--     ON account_summary(current_balance DESC);
--
-- CREATE INDEX IF NOT EXISTS idx_account_summary_sequence
--     ON account_summary(last_updated_sequence DESC);

-- Example: Transaction Summary Read Model
--
-- CREATE TABLE IF NOT EXISTS transaction_summary (
--     transaction_id UUID PRIMARY KEY,
--     from_account_id UUID NOT NULL,
--     to_account_id UUID NOT NULL,
--     amount NUMERIC(15,2) NOT NULL CHECK (amount > 0),
--     reason TEXT NOT NULL,
--     status TEXT NOT NULL CHECK (status IN ('Pending', 'Completed', 'Failed')),
--     failure_reason TEXT,
--     created_at TIMESTAMP NOT NULL DEFAULT NOW(),
--     completed_at TIMESTAMP
-- );
--
-- CREATE INDEX IF NOT EXISTS idx_transaction_summary_from_account 
--     ON transaction_summary(from_account_id);
--
-- CREATE INDEX IF NOT EXISTS idx_transaction_summary_to_account 
--     ON transaction_summary(to_account_id);
--
-- CREATE INDEX IF NOT EXISTS idx_transaction_summary_status 
--     ON transaction_summary(status);
--
-- CREATE INDEX IF NOT EXISTS idx_transaction_summary_created 
--     ON transaction_summary(created_at DESC);

-- ----------------------------------------------------------------------------
-- Performance Indexes (Optional Optimizations)
-- ----------------------------------------------------------------------------
--
-- Additional indexes can be added based on query patterns.
--
-- Default indexes created by eventium-postgresql:
--   - PRIMARY KEY (id): Global sequence number
--   - UNIQUE (uuid, version): Stream uniqueness and optimistic locking
--   - INDEX (uuid): Fast stream lookup
--
-- Custom indexes you might want to add (commented out SQL in DDL section below):
--
-- For combined lookups:
--   CREATE INDEX idx_events_id_uuid ON events (id, uuid);
--   - Useful for: Global stream queries that also filter by uuid
--
-- For version range queries:
--   CREATE INDEX idx_events_uuid_version ON events (uuid, version);
--   - Useful for: Getting specific version ranges efficiently
--   - Note: The UNIQUE constraint already provides most of this benefit
--
-- Event store tables have all necessary indexes by default. Only add custom
-- indexes if you have specific query patterns that would benefit from them.

-- ----------------------------------------------------------------------------
-- Database Configuration
-- ----------------------------------------------------------------------------
--
-- Recommended PostgreSQL settings for event sourcing:
--
-- Connection pooling:
--   max_connections = 100
--   shared_buffers = 256MB
--
-- Write-ahead logging (for point-in-time recovery):
--   wal_level = replica
--   archive_mode = on
--
-- Query performance:
--   effective_cache_size = 4GB
--   random_page_cost = 1.1  (for SSD)
--
-- Monitoring:
--   log_min_duration_statement = 1000  (log queries > 1s)
--   log_checkpoints = on

-- ----------------------------------------------------------------------------
-- Backup & Recovery
-- ----------------------------------------------------------------------------
--
-- Event sourcing provides natural backup capabilities:
--
-- 1. Event Stream Backup:
--    pg_dump accounting > backup.sql
--
-- 2. Point-in-time Recovery:
--    Enable WAL archiving and use pg_basebackup
--
-- 3. Event Replay:
--    Read models can be rebuilt from events at any time
--
-- 4. Snapshot Strategy:
--    Consider periodic snapshots for large aggregates

-- ----------------------------------------------------------------------------
-- Migration History
-- ----------------------------------------------------------------------------
--
-- Migrations are managed by persistent-postgresql via Infrastructure.Database.
--
-- Migration 001: Initial event store schema (eventium-postgresql)
--   - Created by: runMigration migrateSqlEvent (via initializeEventStore)
--   - Tables: events (with id, uuid, version, event columns)
--   - Indexes: PRIMARY KEY (id), UNIQUE (uuid, version), INDEX (uuid)
--   - Date: 2025-12-18
--   - Source: eventium-sql-common/src/Eventium/Store/Sql/DefaultEntity.hs
--
-- Future migrations will be documented here as they are added.

-- ============================================================================
-- SQL DDL Reference (For Documentation Only)
-- ============================================================================
-- 
-- The following is the exact SQL that Persistent generates from eventium's
-- entity definitions. These statements are commented out and provided for
-- reference only. DO NOT execute them manually - let eventium handle schema
-- creation via runMigration migrateSqlEvent.
--
-- To view the actual schema in your database:
--   \d events         -- Describe events table
--   \di               -- List all indexes
--
-- ============================================================================

/*
-- Event Store Table
-- Generated from: eventium-sql-common/src/Eventium/Store/Sql/DefaultEntity.hs
-- Persistent definition:
--   SqlEvent sql=events
--       uuid UUID
--       version EventVersion
--       event JSONString
--       UniqueUuidVersion uuid version

CREATE TABLE IF NOT EXISTS events (
    id      SERIAL PRIMARY KEY,
    uuid    TEXT NOT NULL,
    version INTEGER NOT NULL CHECK (version >= 0),
    event   TEXT NOT NULL,
    CONSTRAINT unique_uuid_version UNIQUE (uuid, version)
);

-- Indexes (created automatically by Persistent)
CREATE INDEX IF NOT EXISTS idx_events_uuid ON events (uuid);

-- Optional performance indexes (not created by default)
-- Uncomment these if you need specific query patterns:
-- CREATE INDEX IF NOT EXISTS idx_events_id_uuid ON events (id, uuid);
-- CREATE INDEX IF NOT EXISTS idx_events_uuid_version ON events (uuid, version);

-- ============================================================================
-- Example Queries
-- ============================================================================

-- Get all events for a specific aggregate (stream)
SELECT id, version, event 
FROM events 
WHERE uuid = '123e4567-e89b-12d3-a456-426614174000' 
ORDER BY version;

-- Get latest version for an aggregate
SELECT COALESCE(MAX(version), -1) 
FROM events 
WHERE uuid = '123e4567-e89b-12d3-a456-426614174000';

-- Get global event stream from a specific sequence number
SELECT id, uuid, version, event 
FROM events 
WHERE id >= 100 
ORDER BY id 
LIMIT 1000;

-- Count events per aggregate
SELECT uuid, 
       COUNT(*) as event_count, 
       MAX(version) as latest_version,
       MIN(id) as first_sequence,
       MAX(id) as last_sequence
FROM events 
GROUP BY uuid;

-- Get events by version range for an aggregate
SELECT id, version, event
FROM events
WHERE uuid = '123e4567-e89b-12d3-a456-426614174000'
  AND version BETWEEN 5 AND 10
ORDER BY version;

-- Find aggregates with more than N events
SELECT uuid, COUNT(*) as event_count
FROM events
GROUP BY uuid
HAVING COUNT(*) > 100
ORDER BY event_count DESC;

-- Get recent events (last N events globally)
SELECT id, uuid, version, event
FROM events
ORDER BY id DESC
LIMIT 100;

-- ============================================================================
-- Maintenance Queries
-- ============================================================================

-- Check table size
SELECT pg_size_pretty(pg_total_relation_size('events')) as total_size,
       pg_size_pretty(pg_table_size('events')) as table_size,
       pg_size_pretty(pg_indexes_size('events')) as indexes_size;

-- Get event count and version stats
SELECT 
    COUNT(*) as total_events,
    COUNT(DISTINCT uuid) as unique_aggregates,
    AVG(version) as avg_version,
    MAX(version) as max_version
FROM events;

-- Check for gaps in global sequence (should be none)
SELECT id + 1 as gap_start
FROM events
WHERE NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.id = events.id + 1)
  AND id < (SELECT MAX(id) FROM events)
ORDER BY id;

-- Analyze index usage
SELECT schemaname, tablename, indexname, idx_scan, idx_tup_read, idx_tup_fetch
FROM pg_stat_user_indexes
WHERE tablename = 'events'
ORDER BY idx_scan DESC;

*/

-- ============================================================================
-- End of Schema Documentation
-- ============================================================================

