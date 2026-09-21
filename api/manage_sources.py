#!/usr/bin/env python3
"""BackUpTrace source provisioning CLI.

Manage rows in backup_sources: create new sources (generating and printing a
one-time plaintext API key), list existing sources, and activate/deactivate
sources without deleting them (preserving FK integrity and history).

Run it against the running stack with:

    docker compose run --rm api python manage_sources.py create --source-name oxidized

or interactively (prompts for everything):

    docker compose run --rm api python manage_sources.py create

It reads DB connection details from the same environment as the API
container (POSTGRES_HOST/PORT/DB/USER/PASSWORD), i.e. the project's .env
file when run via `docker compose run`.
"""

import argparse
import os
import re
import sys

import psycopg

from app import config
from app.auth import generate_api_key, hash_api_key

NAME_RE = re.compile(r"^[a-zA-Z0-9_.-]{1,100}$")


def get_connection() -> psycopg.Connection:
    return psycopg.connect(config.DATABASE_URL, autocommit=True)


def prompt(text: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default else ""
    value = input(f"{text}{suffix}: ").strip()
    return value or (default or "")


def validate_source_name(name: str) -> None:
    if not NAME_RE.match(name):
        print(
            f"error: invalid source_name '{name}'. Must match {NAME_RE.pattern} "
            "(letters, digits, '_', '.', '-', max 100 chars).",
            file=sys.stderr,
        )
        sys.exit(1)


def cmd_create(args: argparse.Namespace) -> None:
    source_name = args.source_name or prompt("Source name (e.g. oxidized, proxmox-host-2)")
    validate_source_name(source_name)

    display_name = args.display_name
    if display_name is None and not args.non_interactive:
        display_name = prompt("Display name (optional)", default="") or None

    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT 1 FROM backup_sources WHERE source_name = %s", (source_name,)
            )
            if cur.fetchone():
                print(f"error: source_name '{source_name}' already exists", file=sys.stderr)
                sys.exit(1)

            plaintext_key = generate_api_key()
            cur.execute(
                """
                INSERT INTO backup_sources (source_name, display_name, api_key_hash)
                VALUES (%s, %s, %s)
                """,
                (source_name, display_name, hash_api_key(plaintext_key)),
            )

    print("Source created successfully.\n")
    print(f"  source_name:  {source_name}")
    print(f"  display_name: {display_name or '(none)'}\n")
    print(f"  API key: {plaintext_key}")
    print(
        "\n  WARNING: this key will not be shown again. Store it securely and "
        "hand it to whoever is integrating this source.\n"
    )
    api_port = os.environ.get("API_PORT", "8000")
    print("Example curl request for this source:\n")
    print(
        f"""  curl -X POST http://localhost:{api_port}/api/v1/backup-events \\
    -H "Content-Type: application/json" \\
    -H "X-API-Key: {plaintext_key}" \\
    -d '{{
      "source_name": "{source_name}",
      "job_name": "example-job",
      "status": "success",
      "file_name": "backup-2026-01-01.tar.gz",
      "file_size_bytes": 104857600,
      "duration_seconds": 42.5,
      "extra": {{}}
    }}'
"""
    )


def cmd_list(args: argparse.Namespace) -> None:
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT source_name, display_name, is_active, created_at
                FROM backup_sources
                ORDER BY source_name
                """
            )
            rows = cur.fetchall()

    if not rows:
        print("No sources registered yet.")
        return

    print(f"{'SOURCE_NAME':<30} {'DISPLAY_NAME':<25} {'ACTIVE':<8} CREATED_AT")
    for source_name, display_name, is_active, created_at in rows:
        print(
            f"{source_name:<30} {(display_name or ''):<25} "
            f"{'yes' if is_active else 'no':<8} {created_at}"
        )


def _set_active(source_name: str, is_active: bool) -> None:
    validate_source_name(source_name)
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE backup_sources SET is_active = %s WHERE source_name = %s "
                "RETURNING source_name",
                (is_active, source_name),
            )
            row = cur.fetchone()

    if row is None:
        print(f"error: unknown source_name '{source_name}'", file=sys.stderr)
        sys.exit(1)

    state = "activated" if is_active else "deactivated"
    print(f"Source '{source_name}' {state}.")


def cmd_deactivate(args: argparse.Namespace) -> None:
    source_name = args.source_name or prompt("Source name to deactivate")
    _set_active(source_name, False)


def cmd_activate(args: argparse.Namespace) -> None:
    source_name = args.source_name or prompt("Source name to activate")
    _set_active(source_name, True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Manage BackUpTrace backup sources")
    sub = parser.add_subparsers(dest="command", required=True)

    p_create = sub.add_parser("create", help="Register a new backup source")
    p_create.add_argument("--source-name")
    p_create.add_argument("--display-name")
    p_create.add_argument(
        "--non-interactive",
        action="store_true",
        help="Do not prompt for missing optional fields (CI/scripted use)",
    )
    p_create.set_defaults(func=cmd_create)

    p_list = sub.add_parser("list", help="List all registered sources")
    p_list.set_defaults(func=cmd_list)

    p_deactivate = sub.add_parser("deactivate", help="Deactivate a source (soft disable)")
    p_deactivate.add_argument("--source-name")
    p_deactivate.set_defaults(func=cmd_deactivate)

    p_activate = sub.add_parser("activate", help="Re-activate a previously deactivated source")
    p_activate.add_argument("--source-name")
    p_activate.set_defaults(func=cmd_activate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
