# Integrations

Ready-to-deploy reporters for the backup mechanisms BackUpTrace is used with
today. Each one is a single self-contained script that runs on the machine
doing the backups and POSTs to `/api/v1/backup-events`.

| Integration | Script | Reports |
|---|---|---|
| [Proxmox VE — vzdump](proxmox-vzdump/) | [`backuptrace-vzdump.sh`](proxmox-vzdump/backuptrace-vzdump.sh) | One job per (VM/CT, backup storage), with the real on-disk archive size |
| [Oxidized](oxidized/) | [`backuptrace-report.sh`](oxidized/backuptrace-report.sh) | One job per network device, plus an optional job per device for exporting its config elsewhere |

Nothing on the server side is specific to either of them. They use the same
generic endpoint any future source will use, so this folder grows without the
API, the schema or the dashboards changing — see
[Writing a new integration](#writing-a-new-integration).

## Before either one: register the source

Every reporter needs its own `source_name` and API key. On the BackUpTrace
host:

```bash
docker compose run --rm api python manage_sources.py create \
  --source-name proxmox-host-1-vzdump \
  --display-name "Proxmox host 1 — VM backups"
```

The key is printed once and stored only as a SHA-256 hash. A key is valid for
its own source and nothing else, so a compromised Proxmox host cannot write
events pretending to be another one.

---

## Proxmox VE — vzdump

[`proxmox-vzdump/backuptrace-vzdump.sh`](proxmox-vzdump/backuptrace-vzdump.sh)

Reports every `vzdump` archive that exists, one event per (VM/CT, storage). A
VM backed up to both `DailyBackups` and `WeeklyBackups` produces two separate
jobs, judged against two separate staleness windows.

**It scans files, not task logs.** Storage names and their on-disk paths come
from `pvesh get /storage`, and the script looks at the newest archive per guest
in each `dump/` directory. That means the size reported is the real one from
`stat()`, a backup pruned by retention stops being reported, and nothing
depends on vzdump's log wording. Nothing is hardcoded — the same file works on
any host.

**It remembers what it already reported.** BackUpTrace is an append-only log:
every POST is a permanent row. The script runs on a 15-minute timer, so without
a state file (`/var/lib/backuptrace-vzdump/reported.tsv`, keyed by
storage + path, fingerprinted by mtime + size) one nightly backup would become
~96 identical rows a day. It stays silent when nothing changed.

### Installing

```bash
# on the Proxmox host, as root
vi backuptrace-vzdump.sh          # edit the config block at the top
chmod 700 backuptrace-vzdump.sh
./backuptrace-vzdump.sh --install
```

`--install` checks for `jq`, copies the script to `/usr/local/bin`, writes a
systemd service and a 15-minute timer, and starts it. To move to another host,
copy this one file, edit the block, run `--install` there.

| Flag | |
|---|---|
| `--status` | Is the timer running, when did it last fire |
| `--dry-run` | Print the JSON that would be sent; POST nothing, touch no state |
| `--force` | Ignore the state file and report everything found once |
| `--reset-state` | Forget what was reported; the next run re-reports everything once |
| `--uninstall` | Remove the service and timer, keep the script and state |

### The config block

Everything host-specific is at the top of the file and nothing below it needs
editing:

| Variable | |
|---|---|
| `BACKUPTRACE_URL`, `BACKUPTRACE_API_KEY`, `SOURCE_NAME` | from the registration step above |
| `MIN_EXPECTED_SIZE_BYTES` | archives smaller than this are reported `warning` rather than `success` |
| `STALE_AFTER_DAILY_DAYS` / `WEEKLY` / `DEFAULT` | how long each class of job may go without a new backup |
| `DAILY_MATCH` / `WEEKLY_MATCH` | case-insensitive substrings matched against the storage name, then its path, to decide which of the three windows applies. Set either to `""` to disable that class |
| `SETTLE_SECONDS` | ignore archives modified this recently, so a backup still being written is not reported at its partial size |

If a host has just one generic backup target, leave `DAILY_MATCH` and
`WEEKLY_MATCH` alone and set `STALE_AFTER_DEFAULT_DAYS` — unmatched storages
fall through to it.

---

## Oxidized

[`oxidized/backuptrace-report.sh`](oxidized/backuptrace-report.sh)

Reports one job per network device. Install it as an `exec` hook on three
events:

```yaml
hooks:
  backuptrace_report:
    type: exec
    events: [node_success, node_fail, post_store]
    cmd: /home/oxidized/.config/oxidized/hooks/backuptrace-report.sh
    async: false
    timeout: 30
```

Why all three:

- **`node_success`** fires on every successful poll, changed or not. This is
  the important one. Oxidized only stores and commits when a config actually
  differs, so a device that is healthy but unchanged for months would never
  reach `post_store` — and would look stale in BackUpTrace while being
  perfectly fine.
- **`node_fail`** fires once all retries are exhausted. `no_connection` is
  reported as `warning`, everything else as `failed`.
- **`post_store`** fires in addition to `node_success`, only when a new version
  was committed. It reports the device's backup again, this time with the
  committed file's size read out of the git repo.

Credentials go in an env file the hook sources, not in the script:

```bash
install -d -o oxidized -g oxidized -m 700 /home/oxidized/.config/oxidized/backuptrace
cat > /home/oxidized/.config/oxidized/backuptrace/backuptrace.env <<'EOF'
BACKUPTRACE_API_URL=http://172.17.0.1:8000
BACKUPTRACE_API_KEY=bkt_...
EOF
chown oxidized:oxidized /home/oxidized/.config/oxidized/backuptrace/backuptrace.env
chmod 600 /home/oxidized/.config/oxidized/backuptrace/backuptrace.env
```

If the env file is missing or the key is unset, the hook logs one line and
exits 0. A monitoring problem must never break the backup it is monitoring.

### Optional: reporting an export step separately

If a second hook copies each device's config somewhere else (rclone to
SharePoint, S3, a file share), have that hook write one word —
`ok`, `failed` or `skipped` — into
`/home/oxidized/.config/oxidized/backuptrace/state/<node>`:

```sh
# at the end of your export hook, per node
mkdir -p "$STATE_DIR"
printf '%s' "ok" > "$STATE_DIR/$OX_NODE_NAME"
```

`backuptrace-report.sh` then reports a second job per device,
`"<device> (sharepoint-sync)"`, so a failing export never gets mistaken for a
failing backup. Rename that label in the script if you export somewhere else.

Register your export hook **before** this one on `post_store`: Oxidized runs
the hooks of an event in order, so the marker is guaranteed fresh when it is
read.

With no `state/` directory the export job is not reported at all — which is
correct for a host that has no export step.

### Optional: declaring a staleness window

The hook does not send `stale_after_hours`, so its jobs fall back to the global
threshold in the dashboard and the alert rule. To declare a window per device
instead, add the field to the payload in `send_event`:

```sh
  "duration_seconds": ${JOB_TIME:-null},
  "stale_after_hours": ${BACKUPTRACE_STALE_AFTER_HOURS:-72},
```

and the polling interval becomes visible to BackUpTrace instead of assumed.

---

## Writing a new integration

The server needs no changes — no table, no column, no endpoint, no dashboard
edit. Register a source, POST to `/api/v1/backup-events`, and it appears
everywhere on its own. See [API.md](../API.md) for the full contract.

Four things worth copying from the two scripts here, all of them learned the
hard way:

1. **One event per backup run, not per artifact.** The number of events is a
   signal in itself; a source that re-reports the same file on every poll
   inflates every count in the dashboard. If your reporter runs on a timer,
   give it a state file.
2. **Declare `stale_after_hours`.** It is what lets a nightly job and a weekly
   one be judged correctly by the same dashboard and the same alert rule.
   Without it, everything is compared against one global number that cannot be
   right for both.
3. **Never let reporting break the backup.** Use connect and total timeouts on
   the HTTP call, and swallow its failure. A hung API must not hang a cron job.
4. **Escape free text.** Error output from another tool goes into the payload;
   a backslash or a stray control character is enough to make the JSON invalid
   and lose the event — usually the one reporting the failure you cared about.
   Build the body with `jq` if it is available, or escape by hand.
