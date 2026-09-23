#!/bin/bash
# backuptrace-vzdump.sh
#
# All-in-one BackUpTrace monitor for Proxmox VE vzdump backups.
#
# This single file does two jobs:
#   1) --install   Installs itself as a systemd service + 15-minute timer
#                   (checks/installs the "jq" dependency, copies itself to
#                   /usr/local/bin, writes the unit files, enables + starts
#                   the timer). Run this once per host (as root).
#   2) (no args)   Runs the actual scan: for every "dir"-type storage that
#                   holds backups (content=backup), scans its dump/
#                   directory on disk and finds the most recent vzdump
#                   archive per VM/CT, then reports it to BackUpTrace with
#                   its REAL, current file size -- but only if that archive
#                   has not been reported already. This is what the timer
#                   calls every 15 minutes.
#
# Design choice: we scan the actual files on disk rather than parsing vzdump
# task logs. This guarantees BackUpTrace only ever reflects backups that
# ACTUALLY EXIST right now, with an exact size from stat() -- no stale
# history from tasks whose files were since pruned by retention, and no
# dependency on vzdump's log text format (which varies and is easy to
# mis-parse, especially across multiple VMs per job).
#
# BackUpTrace is an append-only event log, not a state store: every POST
# becomes a permanent row. So this script remembers what it has already
# reported (see STATE_FILE) and stays silent on runs where nothing changed.
# Without that, a 15-minute timer turns one backup into ~96 identical rows
# per day, which inflates every count in the dashboards and grows the table
# without bound.
#
# Zero hardcoded paths: storage names and their on-disk paths are read from
# Proxmox itself via `pvesh get /storage`, not hardcoded in this script.
# Each storage is reported as its own "job" (e.g. a VM backed up under both
# "DailyBackups" and "WeeklyBackups" storages produces two separate,
# clearly labeled events).
#
# Portable by design: to run this on a different Proxmox host, copy this
# ONE file, edit the "BackUpTrace configuration" block below, then run
# `./backuptrace-vzdump.sh --install`. Nothing else needs to change.

set -uo pipefail
# NOTE: intentionally not using `set -e` in the scan logic -- a single
# malformed task (e.g. unexpected log format) must not abort processing
# of the rest of the batch.

# ============================================================================
# BackUpTrace configuration -- EDIT THESE PER HOST, nothing else
# ============================================================================
BACKUPTRACE_URL="https://backuptrace.example.com/api/v1/backup-events"
BACKUPTRACE_API_KEY="CHANGE_ME"                 # from manage_sources.py create
SOURCE_NAME="CHANGE_ME"                         # e.g. proxmox-host-1-vzdump
MIN_EXPECTED_SIZE_BYTES=1048576  # 1 MiB -- archives smaller than this are reported as "warning"

# --- How long each kind of job may go without a new backup ------------------
# Sent to BackUpTrace as `stale_after_hours`, per job, on every event. The
# dashboard then judges each job against its own schedule instead of one
# global number: a nightly VM is late after 2.5 days while a weekly one is
# still fine on day 5. Values are in DAYS; fractions are allowed.
STALE_AFTER_DAILY_DAYS=2.5      # storages recognised as daily  (2.5 d = 60 h)
STALE_AFTER_WEEKLY_DAYS=8       # storages recognised as weekly (8 d  = 192 h)
STALE_AFTER_DEFAULT_DAYS=8      # everything else -- use this when the Proxmox
                                # host has no separate daily/weekly backup
                                # storages and just one generic backup target

# How a storage is classified: case-insensitive substring match, tried
# against the Proxmox storage NAME first and then its PATH. With the usual
# setup ("DailyBackups" / "WeeklyBackups", or /mnt/.../daily/, /weekly/)
# these defaults already work. Set either to "" to disable that class, in
# which case its storages fall through to STALE_AFTER_DEFAULT_DAYS.
DAILY_MATCH="daily"
WEEKLY_MATCH="weekly"

# Ignore archives modified within this many seconds. A backup that is still
# being written would otherwise be reported at its partial size.
SETTLE_SECONDS=120

# ============================================================================
# Internal configuration -- should not need editing
# ============================================================================
INSTALL_PATH="/usr/local/bin/backuptrace-vzdump.sh"
SERVICE_PATH="/etc/systemd/system/backuptrace-vzdump.service"
TIMER_PATH="/etc/systemd/system/backuptrace-vzdump.timer"
STATE_DIR="/var/lib/backuptrace-vzdump"
STATE_FILE="$STATE_DIR/reported.tsv"
NODE="$(hostname)"

DRY_RUN=0       # --dry-run : print what would be sent, POST nothing, keep state untouched
FORCE=0         # --force   : ignore the state file and report everything found once

# ============================================================================
# validate_config : catch mistakes before they become 422s or silent gaps
# ============================================================================
validate_config() {
    if [ "$BACKUPTRACE_API_KEY" = "CHANGE_ME" ] || [ "$SOURCE_NAME" = "CHANGE_ME" ]; then
        echo "ERROR: edit BACKUPTRACE_API_KEY and SOURCE_NAME at the top of this script first." >&2
        exit 1
    fi
    local name value
    for name in STALE_AFTER_DAILY_DAYS STALE_AFTER_WEEKLY_DAYS STALE_AFTER_DEFAULT_DAYS; do
        value="${!name}"
        if ! awk -v v="$value" 'BEGIN { exit !(v + 0 > 0) }' 2>/dev/null; then
            echo "ERROR: $name must be a positive number of days (got '$value')." >&2
            exit 1
        fi
    done
}

# ============================================================================
# stale_after_hours_for : classify a storage and return its threshold in hours
# ============================================================================
stale_after_hours_for() {
    local storage_name="$1" storage_path="$2"
    local haystack="${storage_name} ${storage_path}"
    local days="$STALE_AFTER_DEFAULT_DAYS"

    shopt -s nocasematch
    if [ -n "$DAILY_MATCH" ] && [[ "$haystack" == *"$DAILY_MATCH"* ]]; then
        days="$STALE_AFTER_DAILY_DAYS"
    elif [ -n "$WEEKLY_MATCH" ] && [[ "$haystack" == *"$WEEKLY_MATCH"* ]]; then
        days="$STALE_AFTER_WEEKLY_DAYS"
    fi
    shopt -u nocasematch

    awk -v d="$days" 'BEGIN { printf "%.6g", d * 24 }'
}

# ============================================================================
# --install : install this script as a systemd service + 15-minute timer
# ============================================================================
install_self() {
    echo "=== BackUpTrace vzdump monitor -- installation ==="

    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: --install must be run as root." >&2
        exit 1
    fi

    validate_config

    # --- Dependency check: jq is required for reliable JSON parsing of pvesh output ---
    if ! command -v jq >/dev/null 2>&1; then
        echo "Dependency 'jq' not found -- installing..."
        if command -v apt >/dev/null 2>&1; then
            apt update -qq && apt install -y jq
        else
            echo "ERROR: 'apt' not found and 'jq' is missing. Install jq manually, then re-run --install." >&2
            exit 1
        fi
    else
        echo "Dependency 'jq' already present."
    fi

    # --- Copy this script to a stable, permanent location ---
    # Mode 700: this file contains an API key.
    echo "Installing script to $INSTALL_PATH ..."
    cp -f "$(readlink -f "$0")" "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"

    echo "Creating state directory $STATE_DIR ..."
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    # --- Write the systemd service unit ---
    echo "Writing $SERVICE_PATH ..."
    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=BackUpTrace vzdump scan (reports new Proxmox backup archives)
After=network-online.target pve-cluster.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH
User=root

[Install]
WantedBy=multi-user.target
EOF

    # --- Write the systemd timer unit (every 15 minutes) ---
    echo "Writing $TIMER_PATH ..."
    cat > "$TIMER_PATH" <<EOF
[Unit]
Description=Run BackUpTrace vzdump scan every 15 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # --- Enable and start ---
    systemctl daemon-reload
    systemctl enable --now backuptrace-vzdump.timer

    echo ""
    echo "=== Installation complete ==="
    echo "Timer status:"
    systemctl list-timers backuptrace-vzdump.timer --no-pager
    echo ""
    echo "Running an initial scan now. Every backup currently on disk is"
    echo "reported ONCE; after that, only new or replaced archives are sent."
    systemctl start backuptrace-vzdump.service
    sleep 2
    journalctl -u backuptrace-vzdump.service -n 30 --no-pager
    echo ""
    echo "To watch future runs live: journalctl -u backuptrace-vzdump.service -f"
    echo "To move to another host: copy THIS file, edit the config block, run --install there."
}

# ============================================================================
# --status : quick health check of the installed timer/service + last state
# ============================================================================
show_status() {
    echo "=== BackUpTrace vzdump monitor -- status ==="
    if [ ! -f "$TIMER_PATH" ]; then
        echo "Not installed. Run: $0 --install"
        exit 1
    fi
    systemctl status backuptrace-vzdump.timer --no-pager
    echo ""
    systemctl list-timers backuptrace-vzdump.timer --no-pager
    echo ""
    if [ -f "$STATE_FILE" ]; then
        echo "Already-reported archives tracked in $STATE_FILE: $(wc -l < "$STATE_FILE")"
    else
        echo "No state file yet ($STATE_FILE) -- the next run reports everything once."
    fi
    echo ""
    echo "Thresholds sent to BackUpTrace: daily=${STALE_AFTER_DAILY_DAYS}d, weekly=${STALE_AFTER_WEEKLY_DAYS}d, default=${STALE_AFTER_DEFAULT_DAYS}d"
    echo ""
    echo "Recent log:"
    journalctl -u backuptrace-vzdump.service -n 30 --no-pager
}

# ============================================================================
# report_backuptrace : POST one event. Returns 0 only when it was accepted,
# so the caller knows whether it may record the archive as reported. Never
# aborts the run.
# ============================================================================
report_backuptrace() {
    local job_name="$1"
    local status="$2"
    local file_name="$3"
    local file_size="$4"
    local event_timestamp="$5"      # ISO 8601, may be empty -> API defaults to now()
    local stale_after_hours="$6"
    local extra_json="$7"

    # Built with jq, not string concatenation: VM names and paths are free
    # text and a single quote or backslash would otherwise produce invalid
    # JSON that the API rejects (or worse, silently mangles).
    local payload
    payload=$(jq -n \
        --arg   source_name "$SOURCE_NAME" \
        --arg   job_name "$job_name" \
        --arg   status "$status" \
        --arg   file_name "$file_name" \
        --argjson file_size_bytes "$file_size" \
        --argjson stale_after_hours "$stale_after_hours" \
        --arg   event_timestamp "$event_timestamp" \
        --argjson extra "$extra_json" \
        '{
            source_name: $source_name,
            job_name: $job_name,
            status: $status,
            file_name: $file_name,
            file_size_bytes: $file_size_bytes,
            stale_after_hours: $stale_after_hours,
            extra: $extra
         }
         + (if $event_timestamp == "" then {} else {event_timestamp: $event_timestamp} end)')

    if [ -z "$payload" ]; then
        echo "WARNING: could not build JSON payload for job '$job_name'" >&2
        return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "--- would POST:"
        echo "$payload"
        return 1    # nothing was actually reported, so never record it as such
    fi

    local response http_code body
    response=$(curl -s -w "\n%{http_code}" -X POST "$BACKUPTRACE_URL" \
        -H "Content-Type: application/json" \
        -H "X-API-Key: $BACKUPTRACE_API_KEY" \
        -d "$payload" 2>/dev/null || echo -e "\n000")

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
        # Deliberately NOT recorded as reported, so the next run retries it.
        echo "WARNING: BackUpTrace reporting failed for job '$job_name' (HTTP $http_code): $body" >&2
        return 1
    fi
    return 0
}

# ============================================================================
# run_scan : the actual monitoring logic (what the timer calls every 15 min)
#
# Strategy: scan the actual backup storage directories on disk (via `pvesh`
# to discover storage paths -- zero hardcoding) rather than parsing vzdump
# task logs. This guarantees we only ever report backups that ACTUALLY EXIST
# right now, with their real file size from stat() -- no stale/pruned
# history, no log-format guessing. For each VM/CT, we look at its single most
# recent backup file per storage (i.e. per Daily/Weekly job) and report it
# only if it is new or has changed since the last run.
# ============================================================================
run_scan() {
    validate_config
    if ! command -v jq >/dev/null 2>&1; then
        echo "ERROR: 'jq' is required but not installed. Run with --install to set it up, or 'apt install jq' manually." >&2
        exit 1
    fi

    # --- What we reported previously: realpath -> "<mtime>:<size>" ---------
    # The fingerprint includes mtime and size, so a replaced archive that
    # happens to reuse a filename, or one that was still growing when first
    # seen, is reported again; an untouched one is not.
    declare -A PREVIOUSLY_REPORTED=()
    if [ "$FORCE" -eq 0 ] && [ -f "$STATE_FILE" ]; then
        while IFS=$'\t' read -r state_key state_fingerprint; do
            [ -n "$state_key" ] && PREVIOUSLY_REPORTED["$state_key"]="$state_fingerprint"
        done < "$STATE_FILE"
    fi
    declare -A STILL_PRESENT=()   # rebuilt every run, so pruned archives drop out

    # --- Discover backup storages and their real on-disk paths from Proxmox
    # itself -- no hardcoded paths. Only "dir"-type storages have a usable
    # local filesystem path here; other storage types (PBS, NFS-backed, etc.)
    # would need a different listing method and are out of scope for this
    # simple on-disk scan.
    STORAGES_JSON=$(pvesh get /storage --output-format json 2>/dev/null)
    if [ -z "$STORAGES_JSON" ] || [ "$STORAGES_JSON" = "[]" ]; then
        echo "ERROR: could not fetch storage list via pvesh." >&2
        exit 1
    fi

    # storage_name<TAB>path, only for storages that actually hold backups and have a local dir path
    BACKUP_STORAGES=$(echo "$STORAGES_JSON" | jq -r '
        .[] | select(.content | contains("backup")) | select(.path != null) |
        [.storage, .path] | @tsv
    ')

    if [ -z "$BACKUP_STORAGES" ]; then
        echo "No backup-capable storages with a local path found."
        exit 0
    fi

    local reported=0 skipped=0 now_epoch
    now_epoch=$(date +%s)

    # --- For each backup storage, find the single most recent vzdump archive
    # per VMID under <path>/dump/. We dedupe by vmid+storage so if BOTH a
    # parent storage (e.g. "backup-disk") and a more specific subdirectory
    # storage (e.g. "DailyBackups") point at overlapping paths, each real
    # file is still only counted once per storage entry Proxmox itself
    # defines (Proxmox's own config is the source of truth for what counts
    # as a distinct storage/job, so we trust it rather than trying to detect
    # path overlap ourselves).
    declare -A SEEN_FILES

    while IFS=$'\t' read -r STORAGE_NAME STORAGE_PATH; do
        [ -z "$STORAGE_NAME" ] && continue
        DUMP_DIR="${STORAGE_PATH%/}/dump"

        if [ ! -d "$DUMP_DIR" ]; then
            continue
        fi

        STALE_AFTER_HOURS=$(stale_after_hours_for "$STORAGE_NAME" "$STORAGE_PATH")

        # List archive files (vma/tar, any compression), newest first, and
        # keep only the first (most recent) occurrence of each vmid.
        # Filenames look like: vzdump-qemu-100-2026_09_18-23_00_00.vma.zst
        #                       vzdump-lxc-105-2026_09_18-23_15_00.tar.zst
        while read -r FILE_PATH; do
            [ -z "$FILE_PATH" ] && continue

            REAL_PATH=$(readlink -f "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")
            if [ -n "${SEEN_FILES[$REAL_PATH]+x}" ]; then
                continue
            fi

            FILE_BASENAME=$(basename "$FILE_PATH")
            VMID=$(echo "$FILE_BASENAME" | grep -oP 'vzdump-(qemu|lxc)-\K[0-9]+')
            [ -z "$VMID" ] && continue

            DEDUPE_KEY="${STORAGE_NAME}:${VMID}"
            if [ -n "${SEEN_FILES[$DEDUPE_KEY]+x}" ]; then
                # Already have a newer file for this vmid+storage (list is newest-first)
                continue
            fi
            SEEN_FILES[$DEDUPE_KEY]=1
            SEEN_FILES[$REAL_PATH]=1

            FILE_SIZE_BYTES=$(stat -c%s "$FILE_PATH" 2>/dev/null || echo 0)
            FILE_MTIME_EPOCH=$(stat -c%Y "$FILE_PATH" 2>/dev/null || echo 0)

            # Still being written? Leave it for a later run rather than
            # reporting a partial size.
            if [ "$SETTLE_SECONDS" -gt 0 ] && [ $((now_epoch - FILE_MTIME_EPOCH)) -lt "$SETTLE_SECONDS" ]; then
                echo "Skipping (still settling, modified $((now_epoch - FILE_MTIME_EPOCH))s ago): $FILE_BASENAME"
                continue
            fi

            # Have we already reported exactly this archive?
            STATE_KEY="${STORAGE_NAME}|${REAL_PATH}"
            FINGERPRINT="${FILE_MTIME_EPOCH}:${FILE_SIZE_BYTES}"
            if [ "${PREVIOUSLY_REPORTED[$STATE_KEY]:-}" = "$FINGERPRINT" ]; then
                STILL_PRESENT["$STATE_KEY"]="$FINGERPRINT"
                skipped=$((skipped + 1))
                continue
            fi

            # Parse the real backup timestamp from the filename itself
            # (e.g. vzdump-qemu-100-2026_09_17-23_00_00.vma.zst -> 2026-09-17 23:00:00),
            # rather than using the file's mtime or "now" -- this is when the
            # backup actually ran, not when this script happened to scan it.
            # Falls back to the file's mtime if the filename doesn't match
            # the expected pattern (e.g. a manually renamed file).
            FILE_TIMESTAMP_RAW=$(echo "$FILE_BASENAME" | grep -oP '\K[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}')
            if [ -n "$FILE_TIMESTAMP_RAW" ]; then
                EVENT_TIMESTAMP=$(echo "$FILE_TIMESTAMP_RAW" | sed -E 's/([0-9]{4})_([0-9]{2})_([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})/\1-\2-\3T\4:\5:\6/')
                # Validate it actually parses as a real date; otherwise fall back.
                if ! date -d "$EVENT_TIMESTAMP" >/dev/null 2>&1; then
                    EVENT_TIMESTAMP=""
                fi
            else
                EVENT_TIMESTAMP=""
            fi
            if [ -z "$EVENT_TIMESTAMP" ]; then
                EVENT_TIMESTAMP=$(date -u -d "@$FILE_MTIME_EPOCH" +%Y-%m-%dT%H:%M:%S)
            fi

            VMNAME=$(qm config "$VMID" 2>/dev/null | grep -oP '^name:\s*\K.*')
            if [ -z "$VMNAME" ]; then
                VMNAME=$(pct config "$VMID" 2>/dev/null | grep -oP '^hostname:\s*\K.*')
            fi
            VM_LABEL="${VMNAME:-vm-${VMID}}"
            JOB_NAME="${VM_LABEL} (${STORAGE_NAME})"

            STATUS="success"
            if [ "$FILE_SIZE_BYTES" -lt "$MIN_EXPECTED_SIZE_BYTES" ]; then
                STATUS="warning"
            fi

            EXTRA_JSON=$(jq -n \
                --arg vmid "$VMID" --arg node "$NODE" \
                --arg storage "$STORAGE_NAME" --arg path "$FILE_PATH" \
                '{vmid: $vmid, node: $node, storage: $storage, path: $path}')

            echo "Reporting: job='$JOB_NAME' status='$STATUS' file='$FILE_BASENAME' size=$FILE_SIZE_BYTES event_time=$EVENT_TIMESTAMP stale_after=${STALE_AFTER_HOURS}h"
            if report_backuptrace "$JOB_NAME" "$STATUS" "$FILE_BASENAME" "$FILE_SIZE_BYTES" \
                                  "$EVENT_TIMESTAMP" "$STALE_AFTER_HOURS" "$EXTRA_JSON"; then
                STILL_PRESENT["$STATE_KEY"]="$FINGERPRINT"
                reported=$((reported + 1))
            fi
        done < <(find "$DUMP_DIR" -maxdepth 1 -type f \
                    \( -name 'vzdump-*.vma.zst' -o -name 'vzdump-*.vma.gz' -o -name 'vzdump-*.vma.lzo' -o -name 'vzdump-*.vma' \
                    -o -name 'vzdump-*.tar.zst' -o -name 'vzdump-*.tar.gz' -o -name 'vzdump-*.tar.lzo' -o -name 'vzdump-*.tar' \) \
                    -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
    done <<< "$BACKUP_STORAGES"

    # --- Persist state (only what still exists on disk, so entries for
    # retention-pruned archives disappear on their own). A failed POST is
    # absent from STILL_PRESENT and therefore retried next run.
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
        local tmp_state="${STATE_FILE}.tmp.$$"
        : > "$tmp_state"
        local key
        for key in "${!STILL_PRESENT[@]}"; do
            printf '%s\t%s\n' "$key" "${STILL_PRESENT[$key]}" >> "$tmp_state"
        done
        mv -f "$tmp_state" "$STATE_FILE"
        chmod 600 "$STATE_FILE"
    fi

    echo "Scan complete: $reported reported, $skipped unchanged (already reported)."
}

# ============================================================================
# Entry point
# ============================================================================
while [ $# -gt 0 ]; do
    case "$1" in
        --install)
            install_self
            exit 0
            ;;
        --status)
            show_status
            exit 0
            ;;
        --uninstall)
            echo "Stopping and removing timer/service..."
            systemctl disable --now backuptrace-vzdump.timer 2>/dev/null || true
            rm -f "$SERVICE_PATH" "$TIMER_PATH"
            systemctl daemon-reload
            echo "Removed. Script left at $INSTALL_PATH and state in $STATE_DIR (delete manually if desired)."
            exit 0
            ;;
        --reset-state)
            rm -f "$STATE_FILE"
            echo "State cleared ($STATE_FILE). The next run reports every archive on disk once."
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        *)
            echo "Usage: $0 [--install|--status|--uninstall|--reset-state] [--dry-run] [--force]" >&2
            echo "  (no args)      Run one scan pass -- this is what the timer calls." >&2
            echo "  --install      Install as a systemd service + 15-minute timer on this host." >&2
            echo "  --status       Show timer status, how many archives are tracked, and recent log." >&2
            echo "  --uninstall    Remove the systemd service + timer (keeps the script and state)." >&2
            echo "  --reset-state  Forget what was already reported (next run re-reports everything once)." >&2
            echo "  --dry-run      Print the JSON that would be sent; POST nothing, touch no state." >&2
            echo "  --force        Ignore the state file and report everything found this run." >&2
            exit 1
            ;;
    esac
done

run_scan
