-- BackUpTrace core schema
--
-- Design principle: exactly ONE generic facts table (backup_events) for every
-- backup source that will ever exist, plus a registry table (backup_sources).
-- Anything source-specific (vmid, git commit hash, device model, rclone exit
-- code, ...) goes into the `extra` JSONB column. Adding a new backup source
-- type must NEVER require a new table, a new column, or a schema migration --
-- only a new row in backup_sources (see scripts/manage_sources.py) and that
-- source POSTing to the existing /api/v1/backup-events endpoint.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- backup_sources: registry of who is allowed to report data
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS backup_sources (
    id              BIGSERIAL PRIMARY KEY,
    source_name     TEXT NOT NULL UNIQUE,
    display_name    TEXT,
    api_key_hash    TEXT NOT NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,

    CONSTRAINT source_name_format CHECK (source_name ~ '^[a-zA-Z0-9_.-]{1,100}$')
);

COMMENT ON TABLE backup_sources IS
    'Registry of backup sources allowed to POST to /api/v1/backup-events. '
    'Never deleted (only deactivated via is_active) to preserve FK integrity '
    'and historical event data.';
COMMENT ON COLUMN backup_sources.api_key_hash IS
    'SHA-256 hex digest of the plaintext API key. Plaintext is shown once at '
    'creation time (see scripts/manage_sources.py) and never stored.';

-- ---------------------------------------------------------------------------
-- backup_events: the single generic facts table for every source type
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS backup_events (
    id                  BIGSERIAL PRIMARY KEY,
    source_name         TEXT NOT NULL REFERENCES backup_sources (source_name)
                            ON UPDATE CASCADE,
    job_name            TEXT,
    status              TEXT NOT NULL,
    file_name           TEXT,
    file_size_bytes     BIGINT,
    duration_seconds    DOUBLE PRECISION,
    stale_after_hours   DOUBLE PRECISION,
    event_timestamp     TIMESTAMPTZ NOT NULL DEFAULT now(),
    received_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    extra               JSONB NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT backup_events_status_check
        CHECK (status IN ('success', 'failed', 'warning')),
    CONSTRAINT backup_events_file_size_nonneg
        CHECK (file_size_bytes IS NULL OR file_size_bytes >= 0),
    CONSTRAINT backup_events_duration_nonneg
        CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    CONSTRAINT backup_events_stale_after_positive
        CHECK (stale_after_hours IS NULL OR stale_after_hours > 0)
);

COMMENT ON TABLE backup_events IS
    'Generic append-only facts table for every backup source. One row per '
    'reported backup event. No retention/cleanup policy is enforced here by '
    'design -- do not assume this table stays small.';
COMMENT ON COLUMN backup_events.extra IS
    'Arbitrary source-specific payload (vmid, git commit hash, device model, '
    'rclone exit code, etc). Indexed with GIN for future ad-hoc querying.';
COMMENT ON COLUMN backup_events.event_timestamp IS
    'When the backup actually happened, as reported by the caller. Defaults '
    'to now() if the caller omits it.';
COMMENT ON COLUMN backup_events.received_at IS
    'When the API received the event. Always server-set, never trusted from '
    'the caller.';
COMMENT ON COLUMN backup_events.stale_after_hours IS
    'Optional per-job staleness threshold in hours, as reported by the source. '
    'NULL means the source expresses no opinion and consumers should apply '
    'their own default.';

-- ---------------------------------------------------------------------------
-- Indexes
-- ---------------------------------------------------------------------------

-- Speeds up "latest event per source_name + job_name" (DISTINCT ON / window
-- queries) as well as most Grafana panel queries that filter by source/job
-- and order by recency.
CREATE INDEX IF NOT EXISTS idx_backup_events_source_job_ts
    ON backup_events (source_name, job_name, event_timestamp DESC);

-- General time-range queries (dashboards, GET /api/v1/backup-events).
CREATE INDEX IF NOT EXISTS idx_backup_events_event_timestamp
    ON backup_events (event_timestamp DESC);

-- Filtering by status (e.g. "failures over time" dashboard).
CREATE INDEX IF NOT EXISTS idx_backup_events_status
    ON backup_events (status);

-- Flexible querying against the JSONB payload (vmid lookups, git commit
-- hash lookups, etc) without needing new columns or tables later.
CREATE INDEX IF NOT EXISTS idx_backup_events_extra_gin
    ON backup_events USING GIN (extra);

CREATE INDEX IF NOT EXISTS idx_backup_sources_is_active
    ON backup_sources (is_active);

-- ---------------------------------------------------------------------------
-- latest_backup_status: most recent event per (source_name, job_name)
-- ---------------------------------------------------------------------------
-- Base view for most Grafana panels and future alerting. Uses PostgreSQL's
-- native DISTINCT ON rather than a window-function workaround.
CREATE OR REPLACE VIEW latest_backup_status AS
SELECT DISTINCT ON (be.source_name, be.job_name)
    be.source_name,
    bs.display_name,
    be.job_name,
    be.status,
    be.file_name,
    be.file_size_bytes,
    be.duration_seconds,
    be.stale_after_hours,
    be.event_timestamp,
    be.received_at,
    be.extra,
    EXTRACT(EPOCH FROM (now() - be.event_timestamp)) / 3600.0 AS hours_since_backup
FROM backup_events be
JOIN backup_sources bs ON bs.source_name = be.source_name
ORDER BY be.source_name, be.job_name, be.event_timestamp DESC;

COMMENT ON VIEW latest_backup_status IS
    'Most recent backup_events row per (source_name, job_name), with a '
    'computed hours_since_backup column and the per-job stale_after_hours '
    'threshold the source last reported. Base view for Grafana dashboards '
    'and future staleness alerting.';
