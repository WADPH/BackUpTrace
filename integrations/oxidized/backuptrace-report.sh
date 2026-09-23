#!/bin/sh
# Oxidized hook -> BackUpTrace (centralized backup monitoring).
# Registered on THREE events in Oxidized's config, all pointing at this one
# script:
#
#   node_success  - fires on EVERY successful poll, whether the config
#                   changed or not. This is what keeps an unchanged-but-
#                   healthy device from looking "stale" in BackUpTrace's
#                   hours_since_backup (Oxidized itself only stores/commits
#                   on a real diff - see README.md "How it works overall" -
#                   so relying on post_store alone would miss all the
#                   "checked, nothing changed" polls). Reports ONE event:
#                   job_name = the device.
#   node_fail     - all retries exhausted, no backup happened this run.
#                   Reports ONE event: job_name = the device.
#   post_store    - fires in addition to node_success, only when a new
#                   version was actually committed. Reports TWO separate
#                   events for this run, so a device's own backup and its
#                   SharePoint export are tracked independently rather than
#                   collapsed into one status:
#                     1. job_name = the device        -> the backup itself
#                        (always "success" here - we only reach post_store
#                        once the commit already happened).
#                     2. job_name = "<device> (sharepoint-sync)" -> the
#                        rclone export outcome, read from the state file
#                        export-backup.sh leaves behind. Reported "success"/
#                        "failed"/"warning" (skipped = rclone not configured
#                        yet, not a real failure). Per-device because
#                        export-backup.sh syncs each device to its own
#                        SharePoint subfolder independently, not as one
#                        combined job.
#                   Because this hook is registered AFTER export-backup.sh
#                   on the same event in config.yml, Oxidized runs it right
#                   after (hooks run in sequence per event unless async), so
#                   the state file is always fresh when we read it.
#
# Net effect for a given run: one plain "success" event for the device right
# after every successful poll (node_success), optionally followed moments
# later by two more events once post_store fires - one confirming the
# backup, one for the SharePoint sync specifically. BackUpTrace just stores
# all of them - the dashboards key off the latest event per
# (source_name, job_name), so each job_name always reflects its own most
# recent, most accurate status.
#
# Config: /home/oxidized/.config/oxidized/backuptrace/backuptrace.env
#   BACKUPTRACE_API_URL   base URL of the API, no trailing slash. If Oxidized
#                         runs in a container on the same host as BackUpTrace,
#                         this is the docker bridge gateway, e.g.
#                         http://172.17.0.1:8000
#   BACKUPTRACE_API_KEY   from `manage_sources.py create --source-name oxidized`
set -eu

ENV_FILE="/home/oxidized/.config/oxidized/backuptrace/backuptrace.env"
STATE_DIR="/home/oxidized/.config/oxidized/backuptrace/state"

if [ ! -s "$ENV_FILE" ]; then
  echo "backuptrace-report: $ENV_FILE missing or empty, skipping" >&2
  exit 0
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
if [ -z "${BACKUPTRACE_API_KEY:-}" ]; then
  echo "backuptrace-report: BACKUPTRACE_API_KEY not set in $ENV_FILE, skipping" >&2
  exit 0
fi

EVENT="${OX_EVENT:-}"
NODE="${OX_NODE_NAME:-unknown}"
REPO="${OX_REPO_NAME:-}"
REF="${OX_REPO_COMMITREF:-}"
JOB_STATUS_RAW="${OX_JOB_STATUS:-unknown}"
JOB_TIME="${OX_JOB_TIME:-}"

EVENT_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Minimal JSON string escaping (backslash, double quote) for a value.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Sends one event to BackUpTrace. Never aborts the hook on failure -- a
# reporting hiccup must not affect Oxidized's own backup process.
send_event() {
  _job_name=$(json_escape "$1")
  _status="$2"
  _file_name=$(json_escape "$3")
  _file_size="${4:-null}"

  _payload=$(cat <<JSON
{
  "source_name": "oxidized",
  "job_name": "${_job_name}",
  "status": "${_status}",
  "file_name": "${_file_name}",
  "file_size_bytes": ${_file_size},
  "duration_seconds": ${JOB_TIME:-null},
  "event_timestamp": "${EVENT_TS}"
}
JSON
)

  if ! curl -fsS -X POST "${BACKUPTRACE_API_URL:-http://localhost:8000}/api/v1/backup-events" \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${BACKUPTRACE_API_KEY}" \
    -d "$_payload" -o /dev/null; then
    echo "backuptrace-report: failed to report event for job '$1' (event=$EVENT status=$_status)" >&2
  fi
}

case "$EVENT" in
  node_fail)
    # Oxidized job statuses: success, no_connection, failure, timelimit.
    case "$JOB_STATUS_RAW" in
      no_connection) STATUS="warning" ;;
      *)             STATUS="failed"  ;;
    esac
    send_event "$NODE" "$STATUS" "$NODE"
    ;;

  post_store)
    # Event 1: the backup itself. We only reach post_store after a
    # successful commit, so this is always "success".
    BACKUP_SIZE=""
    if [ -n "$REPO" ] && [ -n "$REF" ]; then
      BACKUP_SIZE=$(git --git-dir="$REPO" show "${REF}:${NODE}" 2>/dev/null | wc -c | tr -d ' ')
    fi
    send_event "$NODE" "success" "$NODE" "${BACKUP_SIZE:-null}"

    # Event 2: the export of this same device to external storage, reported as
    # its own job so a failed sync never gets confused with a failed backup.
    # Only relevant if a second hook writes ok/failed/skipped markers into
    # STATE_DIR (see integrations/README.md). With no STATE_DIR at all there is
    # no export step on this host, and reporting a job for it would leave a
    # permanent "warning" in BackUpTrace for something that does not exist.
    if [ ! -d "$STATE_DIR" ]; then
      exit 0
    fi

    RCLONE_STATE=""
    [ -f "$STATE_DIR/$NODE" ] && RCLONE_STATE=$(cat "$STATE_DIR/$NODE" 2>/dev/null || true)
    case "$RCLONE_STATE" in
      ok)      SYNC_STATUS="success" ;;
      failed)  SYNC_STATUS="failed"  ;;
      skipped) SYNC_STATUS="warning" ;;  # rclone not configured yet -- not a hard failure
      *)       SYNC_STATUS="warning" ;;  # no marker yet / unexpected content
    esac
    # Same size as the backup event above: this is the size of the exact
    # file rclone was asked to copy to SharePoint, not a size read back from
    # SharePoint itself (rclone's own logs would be needed for that, and
    # export-backup.sh only records ok/failed/skipped, not a byte count).
    # On "failed", still reporting the attempted size is useful context: it
    # confirms there really was something to sync, rather than the sync
    # "succeeding" trivially on an empty file.
    send_event "${NODE} (sharepoint-sync)" "$SYNC_STATUS" "$NODE" "${BACKUP_SIZE:-null}"
    ;;

  node_success | *)
    BACKUP_SIZE=""
    if [ -n "$REPO" ]; then
      BACKUP_SIZE=$(git --git-dir="$REPO" show "HEAD:${NODE}" 2>/dev/null | wc -c | tr -d ' ')
    fi
    send_event "$NODE" "success" "$NODE" "${BACKUP_SIZE:-null}"
    ;;
esac