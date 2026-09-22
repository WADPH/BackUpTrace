# BackUpTrace API

Generic ingestion + query API for backup job results. There is exactly **one**
ingestion endpoint and **one** facts table for every backup source that
exists now or will exist later (Proxmox, Oxidized, ad-hoc rclone scripts,
whatever comes next). Adding a new source type never requires API changes --
only a new row in `backup_sources` (see [`scripts/manage_sources.py`](scripts/manage_sources.py)) and that
source POSTing here.

Interactive OpenAPI/Swagger docs are also available for free at
`http://<host>:8000/docs` (and `/redoc`) once the stack is running.

## Authentication

Every source has its own API key, issued by `manage_sources.py create` and
sent once, in plaintext. Only its SHA-256 hash is stored server-side (see
[`api/app/auth.py`](api/app/auth.py) for why SHA-256 rather than bcrypt is the
right choice here). Send the key in the `X-API-Key` header on every request.

A key is only valid for the exact `source_name` it was issued for -- the API
verifies this on every write, so a compromised or misconfigured integration
for one source can never post events under another source's name.

## Endpoints

### `GET /health`

No auth required. Checks the container and its DB connection are alive.

```bash
curl http://localhost:8000/health
```

```json
{"status": "ok"}
```

### `POST /api/v1/backup-events`

The main ingestion endpoint. Every backup mechanism reports its outcome here.

**Headers**

| Header | Required | Description |
|---|---|---|
| `X-API-Key` | yes | The API key issued for `source_name` |
| `Content-Type` | yes | `application/json` |

**Body**

| Field | Type | Required | Notes |
|---|---|---|---|
| `source_name` | string | yes | Must match a registered, active source. `^[a-zA-Z0-9_.-]{1,100}$` |
| `job_name` | string | no | The specific thing within the source (VM name, device hostname, config name, ...). Max 200 chars. |
| `status` | string | yes | One of `success`, `failed`, `warning` |
| `file_name` | string | no | Max 500 chars |
| `file_size_bytes` | integer | no | >= 0 |
| `duration_seconds` | number | no | >= 0 |
| `stale_after_hours` | number | no | > 0. How long **this job** may go without a new backup before it counts as stale. See below. |
| `event_timestamp` | string (ISO 8601) | no | When the backup actually happened. Defaults to `now()` server-side if omitted. |
| `extra` | object | no | Arbitrary source-specific JSON (vmid, git commit hash, device model, rclone exit code, ...). Limited to 16 KB serialized (configurable via `MAX_EXTRA_BYTES`). |

`received_at` is always set server-side and cannot be supplied by the caller.

### `stale_after_hours` — per-job staleness

Different jobs of the same source can run on different schedules: a nightly
VM dump is broken after 2 days of silence, while a weekly one is perfectly
healthy at day 5. So the schedule is declared by the side that actually knows
it — the source — per `job_name`, on every event:

- **Send it with each event, per job.** A source that backs up daily and
  weekly jobs sends e.g. `60` (2.5 days) for the daily ones and `192`
  (8 days) for the weekly ones. The value is in **hours** (the name carries
  the unit deliberately, like `file_size_bytes` and `duration_seconds`).
- **It applies to the latest event of that job.** `latest_backup_status`
  exposes the threshold reported by the most recent event, so changing a
  schedule just means sending a new value from then on — no migration, no
  dashboard edit.
- **Omitting it is fine and means "no opinion".** The column stays `NULL` and
  consumers apply their own default; the bundled Grafana dashboard falls back
  to its `Stale after (hours)` variable. Use this when a source's cadence is
  irregular or unknown.

A value of `0` or a negative number is rejected (`422`) — it would mean
"stale immediately", which is never what a caller means.

**Example: Proxmox VE backup job**

```bash
curl -X POST http://localhost:8000/api/v1/backup-events \
  -H "Content-Type: application/json" \
  -H "X-API-Key: bkt_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  -d '{
    "source_name": "proxmox-host-2",
    "job_name": "vm-101-webserver",
    "status": "success",
    "file_name": "vzdump-qemu-101-2026_09_17-02_00_01.vma.zst",
    "file_size_bytes": 8589934592,
    "duration_seconds": 612.4,
    "stale_after_hours": 60,
    "extra": {
      "vmid": 101,
      "storage": "pbs-main",
      "proxmox_task_id": "UPID:host2:00001A2B:..."
    }
  }'
```

**Example: Oxidized (git-based config backup)**

```bash
curl -X POST http://localhost:8000/api/v1/backup-events \
  -H "Content-Type: application/json" \
  -H "X-API-Key: bkt_yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy" \
  -d '{
    "source_name": "oxidized",
    "job_name": "core-switch-01.corp.local",
    "status": "success",
    "extra": {
      "git_commit": "a1b2c3d4",
      "device_model": "cisco_ios",
      "changed": true
    }
  }'
```

Note this one sends no `stale_after_hours`: Oxidized only stores a new version
when a config actually changed, so there is no fixed interval to promise. It
therefore falls back to the consumer's default threshold.

**Example: custom bash + rclone script, reporting a failure**

```bash
curl -X POST http://localhost:8000/api/v1/backup-events \
  -H "Content-Type: application/json" \
  -H "X-API-Key: bkt_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" \
  -d '{
    "source_name": "custom-rclone-configs",
    "job_name": "sharepoint-finance-configs",
    "status": "failed",
    "file_name": "finance-configs-2026-09-17.tar.gz",
    "file_size_bytes": 0,
    "duration_seconds": 3.1,
    "extra": {
      "rclone_exit_code": 1,
      "error": "connection reset by peer"
    }
  }'
```

**Responses**

| Status | Meaning |
|---|---|
| `201` | Event stored. Returns the created row (including server-assigned `id` and `received_at`). |
| `400` | Validation error (bad type, invalid `status`, `extra` too large, etc). Body has a `detail` explaining exactly what's wrong. |
| `401` | Missing or invalid `X-API-Key` for the given `source_name`. |
| `403` | `source_name` exists but has been deactivated (`is_active = false`). |
| `404` | `source_name` is not registered -- register it first with `manage_sources.py create`. |

### `GET /api/v1/backup-events`

Query stored events, primarily for debugging/verification while building new
integrations.

**Headers**: `X-API-Key` required. A per-source key may only query its own
`source_name` (pass `source_name` as a filter). Set `ADMIN_API_KEY` in `.env`
to allow one key to query across all sources.

**Query parameters** (all optional except as noted for non-admin keys):

| Param | Type | Notes |
|---|---|---|
| `source_name` | string | Required unless using the admin key |
| `job_name` | string | Exact match |
| `status` | string | One of `success`, `failed`, `warning` |
| `start_date` | ISO 8601 | Inclusive lower bound on `event_timestamp` |
| `end_date` | ISO 8601 | Inclusive upper bound on `event_timestamp` |
| `limit` | integer | Default 100, max 1000 |
| `offset` | integer | Default 0 |

```bash
curl -G http://localhost:8000/api/v1/backup-events \
  -H "X-API-Key: bkt_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  --data-urlencode "source_name=proxmox-host-2" \
  --data-urlencode "status=failed" \
  --data-urlencode "limit=20"
```

## Notes for future integrations

- Never invent a new endpoint or table for a new source type. If you find
  yourself wanting one, put the extra fields in `extra` instead.
- `job_name` is optional -- a source that only ever backs up "itself" (no
  sub-jobs) can omit it.
- **Report one event per backup run, not one per artifact you can see.** A
  scanner-style integration that re-POSTs every file it finds on every poll
  makes `backup_events` grow without bound and inflates every count-based
  panel (the dashboard's "Events" vs "Distinct files" tiles exist to expose
  exactly that). Keep track of what you have already reported, or report only
  files newer than your last run.
- `stale_after_hours` is per `job_name`, sent on every event -- it is how a
  source tells consumers what "late" means for that particular job. It became
  a strict column rather than an `extra` key precisely because dashboards and
  alerting read it for every source (see the note below).
- `extra` is unindexed beyond a GIN index on the whole column; do not rely on
  it for values you'll need strict typing or foreign keys on later. If a
  field becomes a first-class citizen for querying/alerting across all
  sources, that's a deliberate schema change, not something to smuggle into
  `extra`.
