import logging
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Optional

from fastapi import Depends, FastAPI, Header, HTTPException, Query, status
from psycopg.rows import dict_row

from . import auth, config, db
from .models import BackupEventIn, BackupEventOut, HealthOut, STATUS_VALUES

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("backuptrace.api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await db.open_pool()
    yield
    await db.close_pool()


app = FastAPI(
    title="BackUpTrace API",
    description=(
        "Generic ingestion + query API for backup job results. Any backup "
        "mechanism (Proxmox, Oxidized, rclone scripts, or anything added "
        "later) reports its outcome here via a single generic endpoint -- "
        "no source-specific endpoints or tables exist by design."
    ),
    version="1.0.0",
    lifespan=lifespan,
)


async def _fetch_source(source_name: str) -> Optional[dict]:
    async with db.pool.connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute(
                "SELECT source_name, api_key_hash, is_active FROM backup_sources "
                "WHERE source_name = %s",
                (source_name,),
            )
            return await cur.fetchone()


async def require_source_api_key(
    source_name: str, x_api_key: Optional[str] = Header(None, alias="X-API-Key")
) -> dict:
    """Validate that x_api_key is the correct, active key for source_name."""
    if not x_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Missing X-API-Key header",
        )

    source = await _fetch_source(source_name)
    if source is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"unknown source_name '{source_name}' - register it first via manage_sources.py",
        )

    if not auth.verify_api_key(x_api_key, source["api_key_hash"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="invalid api key for this source_name",
        )

    if not source["is_active"]:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=f"source_name '{source_name}' is deactivated",
        )

    return source


@app.get("/health", response_model=HealthOut, tags=["health"])
async def health():
    try:
        async with db.pool.connection() as conn:
            async with conn.cursor() as cur:
                await cur.execute("SELECT 1")
                await cur.fetchone()
    except Exception as exc:  # pragma: no cover - defensive
        logger.error("Health check failed: %s", exc)
        raise HTTPException(status_code=503, detail="database unavailable")
    return HealthOut(status="ok")


@app.post(
    "/api/v1/backup-events",
    response_model=BackupEventOut,
    status_code=status.HTTP_201_CREATED,
    tags=["backup-events"],
)
async def create_backup_event(
    event: BackupEventIn,
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
):
    """Ingest a single backup event. Requires the X-API-Key header that was
    issued for `source_name` at provisioning time (see scripts/manage_sources.py).
    A key valid for one source_name can never be used to post as another
    source_name."""
    await require_source_api_key(event.source_name, x_api_key)

    async with db.pool.connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute(
                """
                INSERT INTO backup_events
                    (source_name, job_name, status, file_name, file_size_bytes,
                     duration_seconds, event_timestamp, extra)
                VALUES
                    (%(source_name)s, %(job_name)s, %(status)s, %(file_name)s,
                     %(file_size_bytes)s, %(duration_seconds)s,
                     COALESCE(%(event_timestamp)s, now()), %(extra)s)
                RETURNING id, source_name, job_name, status, file_name,
                          file_size_bytes, duration_seconds, event_timestamp,
                          received_at, extra
                """,
                {
                    "source_name": event.source_name,
                    "job_name": event.job_name,
                    "status": event.status,
                    "file_name": event.file_name,
                    "file_size_bytes": event.file_size_bytes,
                    "duration_seconds": event.duration_seconds,
                    "event_timestamp": event.event_timestamp,
                    "extra": db.Jsonb(event.extra),
                },
            )
            row = await cur.fetchone()

    return BackupEventOut(**row)


@app.get(
    "/api/v1/backup-events",
    response_model=list[BackupEventOut],
    tags=["backup-events"],
)
async def list_backup_events(
    source_name: Optional[str] = Query(None),
    job_name: Optional[str] = Query(None),
    status_filter: Optional[str] = Query(None, alias="status"),
    start_date: Optional[datetime] = Query(None),
    end_date: Optional[datetime] = Query(None),
    limit: int = Query(100, ge=1, le=1000),
    offset: int = Query(0, ge=0),
    x_api_key: Optional[str] = Header(None, alias="X-API-Key"),
):
    """Query stored backup events, for debugging/verification. A per-source
    API key may only view its own source_name. Set ADMIN_API_KEY on the
    server to allow an admin key to query across all sources."""
    if not x_api_key:
        raise HTTPException(status_code=401, detail="Missing X-API-Key header")

    is_admin = bool(config.ADMIN_API_KEY) and x_api_key == config.ADMIN_API_KEY
    if not is_admin:
        if not source_name:
            raise HTTPException(
                status_code=400,
                detail="source_name filter is required unless using an admin API key",
            )
        await require_source_api_key(source_name, x_api_key)

    if status_filter is not None and status_filter not in STATUS_VALUES:
        raise HTTPException(
            status_code=400,
            detail=f"invalid status filter, must be one of {STATUS_VALUES}",
        )

    conditions = []
    params: dict = {"limit": limit, "offset": offset}
    if source_name:
        conditions.append("source_name = %(source_name)s")
        params["source_name"] = source_name
    if job_name:
        conditions.append("job_name = %(job_name)s")
        params["job_name"] = job_name
    if status_filter:
        conditions.append("status = %(status)s")
        params["status"] = status_filter
    if start_date:
        conditions.append("event_timestamp >= %(start_date)s")
        params["start_date"] = start_date
    if end_date:
        conditions.append("event_timestamp <= %(end_date)s")
        params["end_date"] = end_date

    where_clause = f"WHERE {' AND '.join(conditions)}" if conditions else ""

    async with db.pool.connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute(
                f"""
                SELECT id, source_name, job_name, status, file_name,
                       file_size_bytes, duration_seconds, event_timestamp,
                       received_at, extra
                FROM backup_events
                {where_clause}
                ORDER BY event_timestamp DESC
                LIMIT %(limit)s OFFSET %(offset)s
                """,
                params,
            )
            rows = await cur.fetchall()

    return [BackupEventOut(**row) for row in rows]
