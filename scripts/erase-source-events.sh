#!/usr/bin/env bash
set -euo pipefail

# Delete rows from backup_events, either for a whole source or for individual
# jobs of that source.
#
# The usual reason to need this: a machine was decommissioned. It will never
# report again, so its last event sits in latest_backup_status forever, the job
# counts as permanently stale, and the alert rule reminds you about it at every
# repeat interval. Removing its events takes the job out of the view entirely,
# and Grafana resolves the alert on its own within a couple of evaluations.
#
# Deleting is irreversible and loses that job's backup history. If you need the
# history kept, silence the alert in Grafana instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

# Fallback window for jobs whose source reports no stale_after_hours, used only
# to label rows STALE in the listing below. Keep it in sync with the alert rule
# in grafana/provisioning/alerting/alert-rules.yaml.
STALE_FALLBACK_HOURS=2160

SOURCE_NAME=""
SELECT_ALL=0
DRY_RUN=0
ASSUME_YES=0
declare -a CLI_JOBS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [-s SOURCE_NAME] [-j JOB_NAME]... [-a] [-n] [-y] [-h]

Delete events from backup_events for a source, or for individual jobs of it.

Options:
  -s SOURCE_NAME   Source to work on. Omit to list the available sources.
  -j JOB_NAME      Job to delete; repeatable. Use '' for events with no
                   job_name. Skips the interactive menu.
  -a               Delete every job of the source.
  -n               Dry run: show what would be deleted, change nothing.
  -y               Skip the confirmation prompt (for scripted use).
  -h               Show this help and exit.

With -s and neither -j nor -a, the script lists the source's jobs and asks
which ones to delete.

Examples:
  $(basename "$0")
  $(basename "$0") -s local-proxmox-vzdump
  $(basename "$0") -s local-proxmox-vzdump -j 'Joget (DailyBackups)' -n
  $(basename "$0") -s oxidized -a -y

Environment:
  Reads POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB and POSTGRES_PORT from
  $ENV_FILE
EOF
}

while getopts ":s:j:anyh" opt; do
  case "$opt" in
    s) SOURCE_NAME="$OPTARG" ;;
    j) CLI_JOBS+=("$OPTARG") ;;
    a) SELECT_ALL=1 ;;
    n) DRY_RUN=1 ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    \?) echo "Error: unknown option -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Error: option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
  esac
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB is not set in .env}"
: "${POSTGRES_PORT:?POSTGRES_PORT is not set in .env}"
: "${POSTGRES_USER:?POSTGRES_USER is not set in .env}"

# Unit separator: job names may contain almost anything, but not this.
SEP=$'\x1f'

# psql wrapper. The SQL is read from stdin (-f -), never passed with -c: psql
# expands :'variables' only while reading a script, so with -c the placeholders
# would reach the server verbatim and fail. Passing values as variables rather
# than pasting them into the SQL is what makes a quote in a job name harmless.
#
# -T is required as well -- with a TTY every returned line carries a trailing
# \r and nothing parses correctly.
psql_script() {
  docker compose exec -T -e PGPASSWORD="$POSTGRES_PASSWORD" postgres psql \
    -h 127.0.0.1 -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v ON_ERROR_STOP=1 "$@" -f -
}

# --- no source given: list what there is ------------------------------------
if [[ -z "$SOURCE_NAME" ]]; then
  echo "Sources with events:"
  echo
  psql_script -P pager=off <<'SQL'
    SELECT
        be.source_name                                         AS source,
        count(*)                                               AS events,
        count(DISTINCT be.job_name)                            AS jobs,
        to_char(max(be.event_timestamp), 'YYYY-MM-DD HH24:MI') AS last_event
    FROM backup_events be
    GROUP BY be.source_name
    ORDER BY 1;
SQL
  echo
  echo "Run again with -s SOURCE_NAME to choose jobs to delete."
  exit 0
fi

# --- collect the source's jobs ----------------------------------------------
# NULL job_name comes back as an empty field, which is exactly how it is passed
# back into the DELETE below.
mapfile -t JOB_ROWS < <(psql_script -At -F "$SEP" \
  -v v_src="$SOURCE_NAME" -v v_stale="$STALE_FALLBACK_HOURS" <<'SQL'
  SELECT
      be.job_name,
      count(*),
      to_char(max(be.event_timestamp), 'YYYY-MM-DD HH24:MI'),
      round((EXTRACT(EPOCH FROM (now() - max(be.event_timestamp))) / 86400.0)::numeric, 1),
      CASE
        WHEN l.hours_since_backup > COALESCE(l.stale_after_hours, :v_stale)
        THEN 'STALE' ELSE 'ok'
      END
  FROM backup_events be
  LEFT JOIN latest_backup_status l
         ON l.source_name = be.source_name
        AND l.job_name IS NOT DISTINCT FROM be.job_name
  WHERE be.source_name = :'v_src'
  GROUP BY be.job_name, l.hours_since_backup, l.stale_after_hours
  ORDER BY 4 DESC;
SQL
)

if [[ ${#JOB_ROWS[@]} -eq 0 ]]; then
  echo "No events found for source '$SOURCE_NAME'." >&2
  echo "Run without -s to see the sources that do have events." >&2
  exit 1
fi

declare -a J_NAME=() J_COUNT=() J_LAST=() J_AGE=() J_STATE=()
for row in "${JOB_ROWS[@]}"; do
  IFS="$SEP" read -r name cnt last age state <<<"$row"
  J_NAME+=("$name"); J_COUNT+=("$cnt"); J_LAST+=("$last")
  J_AGE+=("$age");   J_STATE+=("$state")
done

label_for() { [[ -z "$1" ]] && echo "(no job_name)" || echo "$1"; }

print_table() {
  printf '  %-4s %8s  %-16s %9s  %-6s %s\n' "#" "EVENTS" "LAST EVENT" "AGE" "STATE" "JOB"
  for i in "${!J_NAME[@]}"; do
    printf '  %-4s %8s  %-16s %8sd  %-6s %s\n' \
      "$((i + 1))" "${J_COUNT[$i]}" "${J_LAST[$i]}" "${J_AGE[$i]}" \
      "${J_STATE[$i]}" "$(label_for "${J_NAME[$i]}")"
  done
}

# --- decide which jobs to delete --------------------------------------------
declare -a SELECTED=()

if [[ $SELECT_ALL -eq 1 ]]; then
  SELECTED=("${!J_NAME[@]}")
elif [[ ${#CLI_JOBS[@]} -gt 0 ]]; then
  for want in "${CLI_JOBS[@]}"; do
    found=0
    for i in "${!J_NAME[@]}"; do
      if [[ "${J_NAME[$i]}" == "$want" ]]; then SELECTED+=("$i"); found=1; break; fi
    done
    if [[ $found -eq 0 ]]; then
      echo "Error: job '$want' has no events under source '$SOURCE_NAME'." >&2
      echo "Available jobs:" >&2
      print_table >&2
      exit 1
    fi
  done
else
  echo "Jobs for source '$SOURCE_NAME':"
  echo
  print_table
  echo
  echo "Select what to delete:"
  echo "  numbers   e.g. '1 3 5'"
  echo "  stale     every job marked STALE"
  echo "  all       every job of this source"
  echo "  q         quit without changing anything"
  echo
  read -r -p "> " answer

  case "${answer,,}" in
    q|quit|"") echo "Nothing deleted."; exit 0 ;;
    all) SELECTED=("${!J_NAME[@]}") ;;
    stale)
      for i in "${!J_NAME[@]}"; do
        [[ "${J_STATE[$i]}" == "STALE" ]] && SELECTED+=("$i")
      done
      if [[ ${#SELECTED[@]} -eq 0 ]]; then
        echo "No stale jobs under this source. Nothing deleted."
        exit 0
      fi
      ;;
    *)
      for tok in $answer; do
        if ! [[ "$tok" =~ ^[0-9]+$ ]] || (( tok < 1 || tok > ${#J_NAME[@]} )); then
          echo "Error: '$tok' is not a number between 1 and ${#J_NAME[@]}." >&2
          exit 1
        fi
        SELECTED+=("$((tok - 1))")
      done
      ;;
  esac
fi

# Deduplicate, keeping the listed order.
declare -a UNIQUE=()
for i in "${SELECTED[@]}"; do
  seen=0
  for j in "${UNIQUE[@]:-}"; do [[ "$j" == "$i" ]] && seen=1 && break; done
  [[ $seen -eq 0 ]] && UNIQUE+=("$i")
done
SELECTED=("${UNIQUE[@]}")

# --- confirm -----------------------------------------------------------------
total=0
echo
echo "About to delete from source '$SOURCE_NAME':"
for i in "${SELECTED[@]}"; do
  printf '  %-45s %6s events\n' "$(label_for "${J_NAME[$i]}")" "${J_COUNT[$i]}"
  total=$((total + J_COUNT[i]))
done
echo "  ${#SELECTED[@]} job(s), $total event(s) in total."

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "Dry run -- nothing was deleted."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  echo
  echo "This is irreversible and removes the backup history of those jobs."
  read -r -p "Type 'yes' to proceed: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted. Nothing deleted."
    exit 0
  fi
fi

# --- delete ------------------------------------------------------------------
# One statement per job, with the values passed as psql variables rather than
# interpolated into the SQL, so quotes in a job name cannot break it.
echo
for i in "${SELECTED[@]}"; do
  name="${J_NAME[$i]}"
  if [[ -z "$name" ]]; then
    out=$(psql_script -v v_src="$SOURCE_NAME" \
      <<<"DELETE FROM backup_events WHERE source_name = :'v_src' AND job_name IS NULL;")
  else
    out=$(psql_script -v v_src="$SOURCE_NAME" -v v_job="$name" \
      <<<"DELETE FROM backup_events WHERE source_name = :'v_src' AND job_name = :'v_job';")
  fi
  printf '  deleted %-45s %s\n' "$(label_for "$name")" "${out:-ok}"
done

echo
echo "Done. Those jobs are gone from latest_backup_status, so any Grafana alert"
echo "for them resolves itself within a couple of evaluation intervals."
