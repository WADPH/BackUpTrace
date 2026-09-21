import os
from urllib.parse import quote


def _env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        raise RuntimeError(f"Required environment variable {name} is not set")
    return value


POSTGRES_HOST = _env("POSTGRES_HOST", "postgres")
POSTGRES_PORT = _env("POSTGRES_PORT", "5432")
POSTGRES_DB = _env("POSTGRES_DB", "backuptrace")
POSTGRES_USER = _env("POSTGRES_USER", "backuptrace")
POSTGRES_PASSWORD = _env("POSTGRES_PASSWORD", required=True)

# User/password are percent-encoded (safe='') before being embedded in the
# connection URL -- otherwise a password containing '@', ':', '/', '#', '?'
# etc would corrupt the URL (e.g. an '@' inside the password gets parsed as
# the userinfo/host separator, breaking hostname resolution entirely).
DATABASE_URL = (
    f"postgresql://{quote(POSTGRES_USER, safe='')}:{quote(POSTGRES_PASSWORD, safe='')}"
    f"@{POSTGRES_HOST}:{POSTGRES_PORT}/{quote(POSTGRES_DB, safe='')}"
)

# Optional: grants read-only access to GET /api/v1/backup-events across ALL
# sources (e.g. for an admin poking around with curl). Per-source API keys
# can only read/write their own source_name. Leave unset to disable.
ADMIN_API_KEY = os.environ.get("ADMIN_API_KEY") or None

# Hard limit on the serialized size of the `extra` JSONB payload, to keep
# the generic ingestion endpoint from being used to smuggle arbitrary blobs.
MAX_EXTRA_BYTES = int(os.environ.get("MAX_EXTRA_BYTES", "16384"))
