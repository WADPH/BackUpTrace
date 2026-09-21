#!/usr/bin/env bash
set -euo pipefail

# Directory of this script, used to locate the .env file relative to the project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/../.env"

SOURCE_NAME=""

usage() {
  cat <<EOF
Usage: $(basename "$0") -s SOURCE_NAME [-h]

Delete rows from backup_events for a given source_name.

Options:
  -s SOURCE_NAME   Value of source_name to delete (required)
  -h               Show this help message and exit

Environment:
  Reads POSTGRES_PASSWORD, POSTGRES_DB, POSTGRES_PORT, POSTGRES_USER from
  $ENV_FILE
EOF
}

# Parse flags
while getopts ":s:h" opt; do
  case "$opt" in
    s) SOURCE_NAME="$OPTARG" ;;
    h) usage; exit 0 ;;
    \?) echo "Error: unknown option -$OPTARG" >&2; usage; exit 1 ;;
    :) echo "Error: option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
  esac
done

# -s is mandatory: refuse to run without an explicit source_name
if [[ -z "$SOURCE_NAME" ]]; then
  echo "Error: -s SOURCE_NAME is required" >&2
  usage
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

# Load variables from .env, ignoring comments and blank lines
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Ensure required variables are present
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set in .env}"
: "${POSTGRES_DB:?POSTGRES_DB is not set in .env}"
: "${POSTGRES_PORT:?POSTGRES_PORT is not set in .env}"
: "${POSTGRES_USER:?POSTGRES_USER is not set in .env}"

echo "Deleting backup_events where source_name = '$SOURCE_NAME'..."

docker compose exec -e PGPASSWORD="$POSTGRES_PASSWORD" postgres psql \
  -h 127.0.0.1 \
  -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  -c "DELETE FROM backup_events WHERE source_name = '$SOURCE_NAME';"
