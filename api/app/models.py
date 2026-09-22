import json
from datetime import datetime
from typing import Any, Literal, Optional

from pydantic import BaseModel, Field, field_validator

from . import config

NAME_PATTERN = r"^[a-zA-Z0-9_.-]{1,100}$"
STATUS_VALUES = ("success", "failed", "warning")


class BackupEventIn(BaseModel):
    source_name: str = Field(
        ...,
        pattern=NAME_PATTERN,
        description="Registered source identifier, e.g. 'oxidized', 'proxmox-host-2'.",
    )
    job_name: Optional[str] = Field(
        None,
        max_length=200,
        description="The specific thing within a source, e.g. a VM name or device hostname.",
    )
    status: Literal["success", "failed", "warning"]
    file_name: Optional[str] = Field(None, max_length=500)
    file_size_bytes: Optional[int] = Field(None, ge=0)
    duration_seconds: Optional[float] = Field(None, ge=0)
    stale_after_hours: Optional[float] = Field(
        None,
        gt=0,
        description=(
            "How many hours this specific job may go without a new backup "
            "before it should be considered stale. Optional: omit it and "
            "consumers fall back to their own default (e.g. the Grafana "
            "dashboard's global threshold). Send it per job_name -- two jobs "
            "of the same source can have different schedules."
        ),
    )
    event_timestamp: Optional[datetime] = Field(
        None, description="ISO 8601. Defaults to now() if omitted."
    )
    extra: dict[str, Any] = Field(default_factory=dict)

    @field_validator("extra")
    @classmethod
    def validate_extra_size(cls, value: dict[str, Any]) -> dict[str, Any]:
        size = len(json.dumps(value).encode("utf-8"))
        if size > config.MAX_EXTRA_BYTES:
            raise ValueError(
                f"extra payload is {size} bytes, exceeds the {config.MAX_EXTRA_BYTES} byte limit"
            )
        return value

    @field_validator("job_name", "file_name")
    @classmethod
    def strip_blank(cls, value: Optional[str]) -> Optional[str]:
        if value is not None and value.strip() == "":
            return None
        return value


class BackupEventOut(BaseModel):
    id: int
    source_name: str
    job_name: Optional[str]
    status: str
    file_name: Optional[str]
    file_size_bytes: Optional[int]
    duration_seconds: Optional[float]
    stale_after_hours: Optional[float]
    event_timestamp: datetime
    received_at: datetime
    extra: dict[str, Any]


class HealthOut(BaseModel):
    status: str = "ok"
