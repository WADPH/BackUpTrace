-- Migration 001: per-job staleness threshold.
--
-- Adds backup_events.stale_after_hours: how long this specific job may go
-- without a new backup before it should be treated as stale. Optional -- a
-- source that doesn't know or care omits it, and consumers (Grafana) fall
-- back to their own global threshold.
--
-- Why a strict column and not `extra`: this is a cross-source field that
-- alerting and dashboards read for every source, which API.md calls out as
-- exactly the case that deserves a deliberate schema change rather than
-- being smuggled into the JSONB payload.
--
-- Safe to re-run. Applies to an already-running stack:
--   docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
--     -p "$POSTGRES_PORT" -f /dev/stdin < db/migrations/001_add_stale_after_hours.sql

BEGIN;

ALTER TABLE backup_events
    ADD COLUMN IF NOT EXISTS stale_after_hours DOUBLE PRECISION;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'backup_events_stale_after_positive'
    ) THEN
        ALTER TABLE backup_events
            ADD CONSTRAINT backup_events_stale_after_positive
            CHECK (stale_after_hours IS NULL OR stale_after_hours > 0);
    END IF;
END $$;

COMMENT ON COLUMN backup_events.stale_after_hours IS
    'Optional per-job staleness threshold in hours, as reported by the source. '
    'NULL means the source expresses no opinion and consumers should apply '
    'their own default.';

-- Recreated (not CREATE OR REPLACE) so the new column can sit next to the
-- other event columns instead of being appended after the computed one.
DROP VIEW IF EXISTS latest_backup_status;

CREATE VIEW latest_backup_status AS
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

COMMIT;
