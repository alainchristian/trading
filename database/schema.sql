-- Phase 0 minimal schema
-- Extend this in later phases; do not pre-build tables for features that don't exist yet.

CREATE TABLE IF NOT EXISTS system_events (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT NOT NULL,           -- 'bridge', 'ea', etc.
    event_type      TEXT NOT NULL,           -- 'heartbeat', 'startup', 'error', etc.
    payload         JSONB,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_system_events_created_at ON system_events (created_at);
CREATE INDEX IF NOT EXISTS idx_system_events_source ON system_events (source);
