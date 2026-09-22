# BackUpTrace

A small, self-hosted, centralized monitoring platform for otherwise
unrelated backup mechanisms (Proxmox VE, Oxidized, ad-hoc bash/rclone
scripts, and anything added later). Every backup job reports its outcome to
one generic HTTP API; results are stored in PostgreSQL and visualized in
Grafana.

## Architecture

```
 Proxmox VE  ---\
 Oxidized     ----> POST /api/v1/backup-events ---> FastAPI ---> PostgreSQL <--- Grafana
 rclone/bash ---/        (X-API-Key per source)      (backuptrace-api)   (backuptrace-postgres)
```

**Core design principle: flexibility without code changes.** There is
exactly one facts table (`backup_events`) and one ingestion endpoint
(`POST /api/v1/backup-events`) for every source type, now or in the future.
A handful of common fields (status, file name, size, timestamps, ...) are
strict columns; anything source-specific (VM id, git commit hash, device
model, rclone exit code, ...) goes into a single `extra` JSONB column.
Adding a brand-new backup source later requires **zero** changes to the API
code, the database schema, or the Grafana dashboards -- only:

1. Registering the new source with `manage_sources.py create` (below), and
2. That source POSTing to the existing API.

See [API.md](API.md) for the full API contract and [`db/init/01_schema.sql`](db/init/01_schema.sql)
for the schema.

### Components

| Component | Image | Role |
|---|---|---|
| `backuptrace-postgres` | `postgres:16-alpine` | Stores `backup_sources` (who can report) and `backup_events` (what happened) |
| `backuptrace-api` | custom (FastAPI, built from [`api/`](api/)) | Ingestion + query API, auth, validation |
| `backuptrace-grafana` | `grafana/grafana-oss:latest` | **Optional**, commented out by default -- see below |

## Quick start

1. Copy the example env file and edit the secrets:

   ```bash
   cp .env.example .env
   $EDITOR .env   # set POSTGRES_PASSWORD at minimum
   ```

2. Bring up the stack:

   ```bash
   docker compose up -d
   ```

   This starts Postgres (schema is applied automatically on first start via
   `docker-entrypoint-initdb.d`, from [`db/init/01_schema.sql`](db/init/01_schema.sql)) and the API.

3. Confirm the API is healthy:

   ```bash
   curl http://localhost:8000/health
   # {"status":"ok"}
   ```

   Interactive API docs are at `http://localhost:8000/docs`.

4. Register your first backup source (see next section), then send a test
   event, then point Grafana (built-in or external) at Postgres.

No sources exist yet, and the API refuses events for unregistered sources on
purpose -- step 4 is required before anything can ingest data.

## Provisioning a new backup source

Sources are managed with [`api/manage_sources.py`](api/manage_sources.py),
run inside the API container (it already has network access to Postgres and
the required Python dependencies) via `docker compose run`:

```bash
# Interactive (prompts for source name + display name)
docker compose run --rm api python manage_sources.py create

# Non-interactive / scripted
docker compose run --rm api python manage_sources.py create \
  --source-name proxmox-host-2 \
  --display-name "Proxmox Host 2" \
  --non-interactive
```

This prints the **plaintext API key exactly once** -- it is never stored or
retrievable again, only its SHA-256 hash is kept in `backup_sources.api_key_hash`
(see [`api/app/auth.py`](api/app/auth.py) for why SHA-256 rather than
bcrypt was chosen here). Save the key immediately and hand it to whoever is
integrating that source. The command also prints a ready-to-use `curl`
example for that specific source.

Other subcommands:

```bash
# List all registered sources and their active/inactive state
docker compose run --rm api python manage_sources.py list

# Disable a source without deleting its history (FK-safe)
docker compose run --rm api python manage_sources.py deactivate --source-name proxmox-host-2

# Re-enable it later
docker compose run --rm api python manage_sources.py activate --source-name proxmox-host-2
```

Sources are never deleted by this tool -- only deactivated -- so historical
`backup_events` rows and foreign-key integrity are preserved.

## Sending a test event via curl

```bash
curl -X POST http://localhost:8000/api/v1/backup-events \
  -H "Content-Type: application/json" \
  -H "X-API-Key: <the key printed by manage_sources.py>" \
  -d '{
    "source_name": "proxmox-host-2",
    "job_name": "vm-101-webserver",
    "status": "success",
    "file_name": "vzdump-qemu-101.vma.zst",
    "file_size_bytes": 8589934592,
    "duration_seconds": 612.4,
    "extra": {"vmid": 101}
  }'
```

Then verify it was stored:

```bash
curl -G http://localhost:8000/api/v1/backup-events \
  -H "X-API-Key: <the same key>" \
  --data-urlencode "source_name=proxmox-host-2"
```

Full API contract, all fields, and error responses: [API.md](API.md).

## Grafana

### Option A: use the built-in Grafana (self-hosted)

The `grafana` service in [`docker-compose.yml`](docker-compose.yml) is
**commented out by default**. To enable it:

1. Uncomment the `grafana:` service block (and the `grafana-data:` volume at
   the bottom of the file).
2. Set `GRAFANA_ADMIN_PASSWORD` (and optionally `GRAFANA_ADMIN_USER`,
   `GRAFANA_PORT`) in `.env`.
3. `docker compose up -d`

On first start, Grafana automatically provisions:

- A **Postgres datasource** pointing at `backuptrace-postgres`
  ([`grafana/provisioning/datasources/datasource.yml`](grafana/provisioning/datasources/datasource.yml)) --
  no manual datasource setup needed.
- **Dashboards** in a "BackUpTrace" folder
  ([`grafana/provisioning/dashboards/`](grafana/provisioning/dashboards/)).
  Start with the unified one; the other three are the original single-purpose
  starters, kept as smaller examples to copy from:
  - **BackUpTrace — Backup Monitoring**
    ([`backuptrace-overview.json`](grafana/provisioning/dashboards/json/backuptrace-overview.json))
    -- the main dashboard, see "The main dashboard" below.
  - **BackUpTrace: Latest Backup Status** -- table of the most recent event
    per `(source_name, job_name)`, from the `latest_backup_status` view, with
    threshold-based coloring (green = recent success, red/yellow = failed,
    warning, or stale).
  - **BackUpTrace: Backup Size Trend** -- `file_size_bytes` over time,
    filterable by source/job.
  - **BackUpTrace: Failures Over Time** -- count of `failed`/`warning`
    events grouped by day and source.

Log in at `http://localhost:3000` with the admin credentials from `.env`.

### Option B: use your own external Grafana

Leave the `grafana` service commented out.

**1. Make Postgres reachable from your Grafana host.**

By default `docker-compose.yml` does **not** publish Postgres to the host at
all -- only the `api` container can reach it, over the internal `backuptrace`
Docker network. If your external Grafana is not on the same Docker host /
network, uncomment the `ports:` block under the `postgres` service:

```yaml
    ports:
      - "${POSTGRES_PORT:-5432}:${POSTGRES_PORT:-5432}"
```

`POSTGRES_PORT` in `.env` is the single source of truth for this port --
Postgres is started with `-p ${POSTGRES_PORT}`, so it's what it actually
listens on inside the container too, not just the host-side mapping. Then:

- If Grafana runs on the **same machine** as this stack, `localhost:<POSTGRES_PORT>`
  from Grafana's perspective is enough.
- If Grafana is on a **different machine/network**, you must open that port
  through your firewall/security group -- but restrict it to Grafana's IP
  specifically. Postgres has no TLS configured here, so exposing this port to
  the open internet is not recommended; prefer a VPN, SSH tunnel, or a firewall
  rule scoped to Grafana's IP over a public port.
- Backup sources (Proxmox/Oxidized/rclone) never need direct Postgres
  access -- they only ever talk to the API, so this port only matters for
  Grafana.

**1b. Alternative: reach Postgres through a Cloudflare Tunnel.**

If a VPN/firewall rule isn't an option, a Cloudflare Tunnel works too, but
Postgres speaks a raw TCP protocol, not HTTP -- so this needs a **TCP**
public hostname on the Cloudflare side (Service URL `tcp://localhost:<POSTGRES_PORT>`
pointing at this Docker host), not the plain HTTP type. On the Grafana host,
run:

```bash
cloudflared access tcp --hostname backuptrace-sql.example.com --url 127.0.0.1:<local-port>
```

**Why this second command is needed, and how it works:** a Cloudflare
Tunnel's *HTTP* hostnames can be hit directly by any HTTP client (curl, a
browser, Grafana itself) because Cloudflare's edge terminates and proxies
HTTP/HTTPS natively. A *TCP* hostname is different -- Cloudflare's edge
doesn't expose an arbitrary raw TCP port to the internet for it; the only
way in is Cloudflare's own tunneling protocol. `cloudflared access tcp`
speaks that protocol on the client's behalf: it opens a plain TCP listener
on `127.0.0.1:<local-port>` on the Grafana host, and for every connection
it accepts there, it tunnels the bytes through Cloudflare to the origin's
`cloudflared`, which forwards them to `tcp://localhost:<POSTGRES_PORT>` on
the Docker host. Point Grafana's datasource at `127.0.0.1:<local-port>`
(not at the public hostname) -- to Grafana it just looks like a normal local
Postgres. Run it as a systemd service on the Grafana host so it survives
reboots; if the Cloudflare Access application has a policy attached, add
`--service-token-id`/`--service-token-secret` (a Service Token, not
interactive login, since this needs to stay running unattended).

**2. Add the datasource in Grafana, with a matching UID.**

The bundled dashboard JSON files reference the datasource by a fixed UID
(`backuptrace-postgres`) rather than by name, so the easiest way to make
them work unmodified is to create the datasource with that same UID via
Grafana's HTTP API (the web UI doesn't let you set a UID directly). Set
`url` to `<postgres-host>:<POSTGRES_PORT>`, or `127.0.0.1:<local-port>`
instead if you're going through the Cloudflare Tunnel from step 1b:

```bash
curl -X POST http://<your-grafana-host>:3000/api/datasources \
  -u <grafana_admin_user>:<grafana_admin_password> \
  -H "Content-Type: application/json" \
  -d '{
    "name": "BackupTrace Postgres",
    "uid": "backuptrace-postgres",
    "type": "postgres",
    "access": "proxy",
    "url": "<postgres-host>:<POSTGRES_PORT>",
    "database": "<POSTGRES_DB>",
    "user": "<POSTGRES_USER>",
    "secureJsonData": { "password": "<POSTGRES_PASSWORD>" },
    "jsonData": { "sslmode": "disable", "postgresVersion": 1600, "timescaledb": false }
  }'
```

(If you'd rather use the UI: Connections -> Data sources -> Add data source
-> PostgreSQL, fill in the same host/db/user/password, and leave the UID
whatever Grafana assigns -- you'll just need to manually re-point each
panel's and each template variable's datasource after importing the
dashboards, in step 3.)

**3. Import the dashboards.**

Dashboards -> New -> Import -> Upload JSON file, for each file in
[`grafana/provisioning/dashboards/json/`](grafana/provisioning/dashboards/json/).
If the datasource UID matches (step 2's curl approach), they work
immediately. If not, open each dashboard's Settings -> Variables (for
`source_name` and `job_name`) and each panel's query editor, and reselect
your datasource from the dropdown.

Either way, the dashboards and datasource are just Postgres queries against
`backup_events` / `backup_sources` / `latest_backup_status` -- nothing about
them is specific to the bundled Grafana container.

The main dashboard also carries a `DS` (datasource) variable, so on import you
can simply pick your Postgres datasource from its dropdown instead of matching
UIDs at all.

### The main dashboard

[`backuptrace-overview.json`](grafana/provisioning/dashboards/json/backuptrace-overview.json)
is the one dashboard meant for daily use. Layout:

- **Overview row** -- aggregates every selected source: success rate, failed
  and warning counts, event count, distinct-file count, jobs tracked,
  stale-job count, source count; a table of the current status of *every* job
  (most overdue first, so whatever is broken floats to the top); a
  success/warning/failed donut; runs-per-day stacked bars; a success-rate bar
  per source; and two histograms (distribution of backup age, and of reported
  run times).
- **One row per source, repeated automatically** -- the row's `repeat` is bound
  to `$source_name`, so every registered source gets an identical block with
  no dashboard edits: last run status, success rate, failed/warning counts,
  event count, time since last backup, a per-job status table, runs-per-day
  bars, and a backup-size histogram.
- **Event history row** (at the bottom) -- every individual event inside the
  time picker's range, newest first, paginated. The tables above answer "what
  is the state now"; this one answers "what happened during this period".

Everything that grows is query-driven (`GROUP BY` or a repeated row), so a new
source or job appears on its own. Toolbar variables:

| Variable | Meaning |
|---|---|
| `DS` | Which Postgres datasource to query (lets the JSON import anywhere) |
| `Source` | Which sources to include; also controls which per-source rows render |
| `Job` | Narrows every panel to specific jobs; `All` by default |
| `Stale after (hours)` | Fallback staleness threshold, used only for jobs whose source reports no `stale_after_hours` (default 168 = 7 days) |

Three things worth knowing when reading it:

- **Current-state panels ignore the time range.** "Last run", "Last backup",
  "Jobs tracked", "Stale jobs" and both status tables always show how things
  stand right now; the rate/percentage panels, both histograms and the event
  history follow the time picker. Each panel's description says which it is.
- **Staleness is per job, declared by the source.** Each event may carry
  `stale_after_hours` (see [API.md](API.md)), so a nightly job can be "late
  after 2.5 days" while a weekly one is fine until day 8 -- the dashboard
  compares every job against its own window and shows the result as `Due`
  (age as a percentage of that window; 100% = exactly at the limit). Jobs
  whose source reports nothing fall back to the `Stale after (hours)`
  variable. An earlier attempt to *infer* each job's cadence from its event
  history was tried and dropped: with only a handful of cycles recorded it
  produced confident nonsense, such as flagging a 20-hour-old backup as
  "8x overdue". Declared beats inferred.
- **"Events" counts API calls, not backups.** One event is one POST. A source
  that re-reports the same artifact on every poll, or reports twice per run
  (as the Oxidized hook does, on `node_success` and again on `post_store`),
  raises this number without any new backup existing. The "Distinct files"
  tile next to it counts distinct `(job, file_name)` pairs instead, so a large
  gap between the two means a source is over-reporting. For the same reason the
  per-source size histogram counts each artifact once, not once per report.

### Extending dashboards / building new ones

Every dashboard here is built on the same two template variables:

- `$source_name` -- populated by `SELECT source_name FROM backup_sources WHERE is_active ORDER BY 1;`
- `$job_name` -- populated by `SELECT DISTINCT job_name FROM backup_events WHERE source_name IN ($source_name) AND job_name IS NOT NULL ORDER BY 1;` (dependent on `$source_name`)

This is the whole point of the JSONB/wide-table design: when a brand-new
source starts sending events, it appears in these dropdowns automatically --
no dashboard edits required. When you build a new panel, reuse the same two
variables and filter with `source_name IN ($source_name)` / `job_name IN
($job_name) OR job_name IS NULL` (the `OR job_name IS NULL` clause keeps
sources that don't use sub-jobs visible even when a specific job is
selected).

To query fields inside `extra` (e.g. a Proxmox `vmid` or an Oxidized
`git_commit`), use Postgres's JSONB operators directly in a panel's SQL,
e.g. `extra->>'vmid'` or `extra @> '{"changed": true}'` -- the GIN index on
`extra` keeps these fast. No schema change needed.

To duplicate a starter dashboard: open it, use Grafana's "Save As" to copy
it, then edit panels/queries as needed. If you want your copy to also be
auto-provisioned (survive a Grafana restart without re-creating it by hand),
export its JSON and drop it into
[`grafana/provisioning/dashboards/json/`](grafana/provisioning/dashboards/json/).

## Database schema

See [`db/init/01_schema.sql`](db/init/01_schema.sql), which runs
automatically on first Postgres start via
`docker-entrypoint-initdb.d`. Summary:

- **`backup_sources`**: registry of who is allowed to report data
  (`source_name`, `display_name`, `api_key_hash`, `is_active`). Rows are
  never deleted, only deactivated.
- **`backup_events`**: the single generic facts table for every source
  (`source_name`, `job_name`, `status`, `file_name`, `file_size_bytes`,
  `duration_seconds`, `stale_after_hours`, `event_timestamp`, `received_at`,
  `extra` JSONB).
  Indexed on `(source_name, job_name, event_timestamp DESC)` for fast
  "latest per job" lookups, on `event_timestamp` and `status` for
  time/status filtering, and with a GIN index on `extra` for flexible
  querying against source-specific fields.
- **`latest_backup_status`** (view): most recent event per
  `(source_name, job_name)`, using `DISTINCT ON`, with a computed
  `hours_since_backup` column and the `stale_after_hours` threshold that job
  last reported. This is the base for the dashboards and for future staleness
  alerting.

Note: retention/cleanup of old `backup_events` rows and Grafana alerting are
explicitly out of scope for this build -- nothing here assumes the table
stays small, so both can be added later without a redesign.

### Migrations

`db/init/` only runs when Postgres initialises an empty data directory, so
changes to the schema of an **already running** stack live in
[`db/migrations/`](db/migrations/) and are applied by hand. Each file is
idempotent and safe to re-run:

```bash
source .env
docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -p "$POSTGRES_PORT" -v ON_ERROR_STOP=1 \
  -f /dev/stdin < db/migrations/001_add_stale_after_hours.sql
```

`db/init/01_schema.sql` always reflects the current schema, so a fresh
`docker compose up` needs no migrations at all.

To set a per-job staleness threshold on rows that already exist (sources will
send it themselves from then on -- see `stale_after_hours` in
[API.md](API.md)):

```sql
UPDATE backup_events SET stale_after_hours = 60    -- 2.5 days
 WHERE source_name = 'my-source' AND job_name ILIKE '%(DailyBackups)%';
```

## Local development (without Docker)

The API can also run directly against a Postgres instance for development:

```bash
cd api
pip install -r requirements.txt
export POSTGRES_HOST=localhost POSTGRES_PORT=5432 POSTGRES_DB=backuptrace \
       POSTGRES_USER=backuptrace POSTGRES_PASSWORD=...
uvicorn app.main:app --reload
```

## Repository layout

```
docker-compose.yml              # Postgres + API (+ optional Grafana, commented out)
.env.example                    # All configurable variables, documented
db/init/01_schema.sql           # Schema: backup_sources, backup_events, latest_backup_status view
db/migrations/                  # Schema changes for an already-running stack (applied by hand)
api/                            # FastAPI service
  app/main.py                   # Endpoints: /health, POST+GET /api/v1/backup-events
  app/auth.py                   # API key generation/hashing/verification
  app/models.py                 # Request/response validation
  manage_sources.py             # Source provisioning CLI
API.md                          # Full API contract + example curl requests
grafana/provisioning/           # Datasource + dashboard provisioning (used if built-in Grafana is enabled)
```
